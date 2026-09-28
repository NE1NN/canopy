import Foundation
import Observation

/// One terminal: a process in a pseudo-terminal, shown by an emulator.
@MainActor
@Observable
public final class Pane: Identifiable {
    public enum Status: Sendable, Equatable {
        case running
        case exited(Int32)
    }

    /// What `waitForExit` reports for a pane closed while its process ran, as for SIGHUP.
    public static let closedExitCode: Int32 = 129

    public let id: PaneID
    /// The row it belongs to. Updated if the repo moves.
    public internal(set) var context: PaneContext
    public let emulator: any TerminalEmulator
    public private(set) var status = Status.running
    public private(set) var title = ""
    /// A title given with `canopy term new --title`. It wins over what the program sets.
    public var fixedTitle: String? {
        didSet { refreshTitle() }
    }
    @ObservationIgnored private let settings: ShellSettings
    @ObservationIgnored private let activity: ActivityLog
    @ObservationIgnored private var process: PtyProcess?
    @ObservationIgnored private var programTitle: ProgramTitle?
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var isScript = false
    /// Reads the shell's command reports, while commands are logged.
    @ObservationIgnored private var commandMarks: CommandMarkScanner?

    /// What the agent in it is doing, as its hooks or `canopy term state` report it.
    public private(set) var agent = PaneAgent()
    /// Called after each change to `agent`.
    @ObservationIgnored public var onAgentChange: ((Pane, AgentChange) -> Void)?
    /// Called when the pane closes for good, before its agent state clears.
    @ObservationIgnored public var onClose: ((Pane) -> Void)?
    /// When a key was last typed or text sent. Kept out of observation, so typing redraws no dot.
    @ObservationIgnored public private(set) var lastInput = Date.distantPast

    /// Whether the agent reached its state after the last input, so a done from before a new prompt does not count.
    public var agentIsFresh: Bool {
        agent.isFresh(after: lastInput)
    }

    /// The folder the shell starts in, when restored into one other than the row's.
    public let startDirectory: String?

    init(
        id: PaneID, context: PaneContext, command: PaneCommand, settings: ShellSettings,
        emulator: any TerminalEmulator, activity: ActivityLog, directory: String? = nil
    ) {
        self.id = id
        self.context = context
        self.startDirectory = directory
        self.settings = settings
        self.activity = activity
        self.emulator = emulator
        emulator.onInput = { [weak self] in self?.input($0) }
        emulator.onResize = { [weak self] in self?.process?.resize($0) }
        emulator.onTitle = { [weak self] in self?.setProgramTitle($0) }
        start(command)
    }

    /// The shell's pid while it runs.
    public var pid: pid_t? { process?.pid }

    public var foreground: ForegroundProcess? { process?.foreground }

    /// True while something other than the shell holds the terminal, such as `claude` or `bun dev`.
    public var isBusy: Bool {
        // A setup or teardown script is busy until it ends, even though zsh runs its last command in its own place.
        if isScript, case .running = status { return true }
        guard let process, let foreground = process.foreground else { return false }
        return foreground.pid != process.pid
    }

    /// Resolves to the exit code once the process exits. A pane closed first reports `closedExitCode`.
    public func waitForExit() async -> Int32 {
        if case .exited(let code) = status { return code }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// `isBusy` as of the last `refreshActivity`, for views to observe. Exiting clears it at once.
    public private(set) var isRunningProgram = false

    /// Reads the foreground process again. The app calls it every second for every pane, shown or not.
    /// The shell coming back to the foreground means the agent's program exited, so its state clears.
    public func refreshActivity() {
        let busy = isBusy
        if busy != isRunningProgram {
            isRunningProgram = busy
            if !busy { agentChanged(agent.ended(at: Date())) }
        }
    }

    /// Applies a report of the agent's state. Returns the change, or nil when it was ignored or changed nothing.
    @discardableResult
    public func report(_ report: AgentReport, now: Date = Date()) -> AgentChange? {
        let change = agent.apply(report, now: now)
        // Takes note of the program now, so its exit clears the state even if no refresh saw it running.
        if agent.state != .none, isBusy, !isRunningProgram {
            isRunningProgram = true
        }
        agentChanged(change)
        return change
    }

    /// The author saw the pane. Returns whether a green dot went away.
    @discardableResult
    public func markSeen() -> Bool {
        agent.seen()
    }

    /// Types `command` and Return once the shell's line editor is ready, so the shell does not echo it twice.
    /// Shells without a line editor never report ready, so it types anyway after `timeout`.
    public func run(_ command: String, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while let process, !process.isAtPrompt, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        process?.write(command + "\r")
    }

    /// How long Return waits after the program has read the text. Codex takes an Enter that comes within 120 ms of a
    /// burst of typed characters for part of a paste.
    static let returnPause = Duration.milliseconds(200)
    /// How long Return waits for a program that is not reading, before it goes in behind the text anyway.
    @ObservationIgnored var returnPatience = Duration.seconds(2)

    /// Sends text as if typed, for `canopy term send`. An exited pane ignores it.
    /// With `enter`, Return follows as a keystroke of its own, in a later read than the text and `returnPause` after
    /// it, and this returns once Return is in. Programs such as Claude Code and Codex take text and a Return that
    /// arrive together for a paste, where Return adds a new line instead of submitting.
    public func type(_ text: String, enter: Bool = false) async {
        guard case .running = status, let process else { return }
        typed(Data(text.utf8))
        guard enter else {
            process.write(text)
            return
        }
        await process.write(Data(text.utf8), then: Data("\r".utf8), pause: Self.returnPause, patience: returnPatience)
        // Return reaches the key rules as the key of its own that the program gets.
        typed(Data("\r".utf8))
    }

    /// Starts a new shell in the same folder after the last one exited.
    public func restart() {
        guard case .exited = status, !isClosed else { return }
        programTitle = nil
        // DECSTR undoes modes the last program left on, such as a hidden cursor, then start on a fresh line.
        emulator.feed(Data("\u{1b}[!p\r\n".utf8))
        start(.shell)
    }

    /// Ends the process for good.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose?(self)
        process?.terminate()
        if case .running = status {
            processExited(Self.closedExitCode)
        }
    }

    /// Reads the foreground process again. The app calls it while the pane is on screen.
    /// A pane whose process exited keeps its last title.
    public func refreshTitle() {
        if let fixedTitle {
            title = fixedTitle
            return
        }
        guard let process else { return }
        let resolved = PaneTitle.resolve(programTitle, foreground: process.foreground)
        if !resolved.isEmpty {
            title = resolved
        }
    }

    /// The shell's working folder now, so a `cd` is remembered across relaunches.
    public var currentDirectory: String? {
        process.flatMap { ProcessTable.folder(of: $0.pid) }
    }

    /// The folder it was restored into, or the row's folder, or the home folder if both are gone.
    private var directory: String {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        if let startDirectory, exists(startDirectory) { return startDirectory }
        return exists(context.rowPath) ? context.rowPath : settings.baseEnvironment["HOME"] ?? NSHomeDirectory()
    }

    private func start(_ command: PaneCommand) {
        if case .script = command { isScript = true } else { isScript = false }
        let environment = PaneEnvironment.build(settings: settings, context: context, pane: id)
        // A new secret for each shell, so only reports this shell prints count.
        let token = settings.reportsCommands ? UUID().uuidString : nil
        let launch =
            switch command {
            case .shell:
                settings.interactiveShell(environment: environment, directory: directory, commandToken: token)
            case .script(let script): settings.script(script, environment: environment, directory: directory)
            }
        commandMarks = launch.environment["CANOPY_COMMAND_TOKEN"].map(CommandMarkScanner.init(token:))
        do {
            process = try PtyProcess(
                launch, size: emulator.size,
                onOutput: { [weak self] in self?.output($0) },
                onExit: { [weak self] in self?.processExited($0) }
            )
            status = .running
            record(ActivityType.termOpened)
            // Name the pane after what was launched. Reading the foreground now could catch the child
            // between fork and exec, still named after Canopy.
            title = (launch.executable as NSString).lastPathComponent
        } catch {
            emulator.feed(Data("\(error)\r\n".utf8))
            processExited(127)
        }
    }

    private func output(_ data: Data) {
        // A closed pane already logged its exit, and output still on its way from before then comes after it.
        let marks = isClosed ? [] : commandMarks?.scan(data) ?? []
        for mark in marks {
            var report: [String: JSONValue] = [
                "cmd": .string(mark.command), "cwd": .string(mark.directory), "exit": .number(Double(mark.exitCode)),
            ]
            if let duration = mark.durationMs {
                report["durationMs"] = .number(Double(duration))
            }
            record(ActivityType.termCommand, report, source: .ui)
        }
        emulator.feed(data)
    }

    private func input(_ data: Data) {
        switch status {
        case .running:
            process?.write(data)
            if !PaneAgent.isTerminalReport(data) {
                typed(data)
            }
        case .exited:
            if data == Data("\r".utf8) { restart() }
        }
    }

    private func setProgramTitle(_ text: String) {
        programTitle = ProgramTitle(text: text, group: process?.foreground?.pid)
        refreshTitle()
    }

    private func record(_ type: String, _ data: [String: JSONValue] = [:], source: ActivitySource = .current) {
        activity.record(
            type, repo: context.repoName, row: context.rowName, path: context.rowPath, source: source,
            data: data.merging(["pane": .string(id.description)]) { value, _ in value })
    }

    private func typed(_ data: Data) {
        let now = Date()
        lastInput = now
        agentChanged(agent.typed(data, at: now))
    }

    private func agentChanged(_ change: AgentChange?) {
        guard let change else { return }
        var data: [String: JSONValue] = [
            "from": change.from == .none ? .null : .string(change.from.rawValue), "via": .string(change.via),
        ]
        if let session = change.session {
            data["session"] = .string(session)
        }
        record(ActivityType.agent(change.to), data)
        onAgentChange?(self, change)
    }

    private func processExited(_ code: Int32) {
        // A closed pane already reported its exit. An exit status that was on its way when it closed changes nothing.
        if isClosed, case .exited = status { return }
        process = nil
        status = .exited(code)
        isRunningProgram = false
        record(ActivityType.termExited, ["code": .number(Double(code))])
        agentChanged(agent.ended(at: Date()))
        // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
        emulator.feed(Data("\u{1b}[?25l".utf8))
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: code)
        }
    }
}
