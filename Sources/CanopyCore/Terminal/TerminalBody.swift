import Foundation
import Observation

/// A terminal pane's body: a process in a pseudo-terminal, shown by an emulator. A remote pane's process attaches to
/// its tmux session on the row's host.
@MainActor
@Observable
public final class TerminalBody {
    public let emulator: any TerminalEmulator
    /// What the pane started with.
    public private(set) var command: PaneCommand
    /// The folder the shell starts in, when restored into one other than the row's.
    public let startDirectory: String?
    /// A remote pane's tmux session on its host, named after the pane that first made it.
    public let remoteSession: String?
    /// Where a remote pane's session starts when the host has none: the folder it was last in, or the row's.
    public let remoteFolder: String?
    /// What the host last said the session is doing. Nil until it has, and while it has no such session.
    public var remoteActivity: SessionActivity? {
        didSet { if remoteActivity != oldValue { pane?.refreshTitle() } }
    }
    /// Types a command into a remote pane's session through its host.
    @ObservationIgnored var runRemotely: ((Pane, String) async -> Void)?
    /// Called with a link the author ⌘-clicked in the terminal.
    @ObservationIgnored public var onOpenLink: ((Pane, String) -> Void)?
    /// How long Return waits for a program that is not reading, before it goes in behind the text anyway.
    @ObservationIgnored var returnPatience = Duration.seconds(2)
    /// How long Return waits after a reply's paste has been read.
    @ObservationIgnored var replyPause = TerminalBody.returnPause
    /// Runs between a reply's paste and its Return, so a test can open a dialog there without racing a clock.
    @ObservationIgnored var beforeReplyReturn: (@MainActor () async -> Void)?

    /// How long Return waits after the program has read the text. Codex takes an Enter that comes within 120 ms of a
    /// burst of typed characters for part of a paste.
    static let returnPause = Duration.milliseconds(200)

    @ObservationIgnored private weak var pane: Pane?
    @ObservationIgnored private let settings: ShellSettings
    @ObservationIgnored private var process: PtyProcess?
    @ObservationIgnored private var programTitle: ProgramTitle?
    @ObservationIgnored private var isScript = false
    /// Reads the shell's command reports, while commands are logged.
    @ObservationIgnored private var commandMarks: CommandMarkScanner?

    init(
        emulator: any TerminalEmulator, command: PaneCommand, isRemote: Bool, settings: ShellSettings,
        directory: String?, session: String?, paneID: PaneID, rowPath: String
    ) {
        self.emulator = emulator
        self.command = command
        self.settings = settings
        remoteSession = isRemote ? session ?? paneID.description : nil
        remoteFolder = isRemote ? directory ?? rowPath : nil
        startDirectory = isRemote ? nil : directory
    }

    /// Joins the body to its pane and starts the process.
    func attach(to pane: Pane) {
        self.pane = pane
        emulator.onInput = { [weak self] in self?.input($0) }
        emulator.onResize = { [weak self] in self?.process?.resize($0) }
        emulator.onTitle = { [weak self] in self?.setProgramTitle($0) }
        emulator.onOpenLink = { [weak self] link in
            guard let self, let pane = self.pane else { return }
            self.onOpenLink?(pane, link)
        }
        start(command)
    }

    private var isRemote: Bool { remoteSession != nil }

    /// The shell's pid while it runs.
    public var pid: pid_t? { process?.pid }

    public var foreground: ForegroundProcess? {
        guard !isRemote else {
            return remoteActivity.flatMap { $0.busy ? ForegroundProcess(pid: 0, name: $0.foreground ?? "") : nil }
        }
        return process?.foreground
    }

    /// True while something other than the shell holds the terminal, such as `claude` or `bun dev`.
    public var isBusy: Bool {
        guard case .running? = pane?.status else { return false }
        if isRemote { return remoteActivity?.busy ?? false }
        // A setup or teardown script is busy until it ends, even though zsh runs its last command in its own place.
        if isScript { return true }
        guard let process, let foreground = process.foreground else { return false }
        return foreground.pid != process.pid
    }

    /// The shell waits for a line, ready for typing.
    var isAtPrompt: Bool { process?.isAtPrompt ?? false }

    /// Types `command` and Return once the shell's line editor is ready, so the shell does not echo it twice.
    /// Shells without a line editor never report ready, so it types anyway after `timeout`.
    public func run(_ command: String, timeout: Duration = .seconds(10)) async {
        if isRemote {
            if let pane { await runRemotely?(pane, command) }
            return
        }
        let deadline = ContinuousClock.now + timeout
        while process != nil, !isAtPrompt, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        process?.write(command + "\r")
    }

    /// Sends text as if typed, for `canopy term send`. An exited pane ignores it.
    /// With `enter`, Return follows as a keystroke of its own, in a later read than the text and `returnPause` after
    /// it, and this returns once Return is in. Programs such as Claude Code and Codex take text and a Return that
    /// arrive together for a paste, where Return adds a new line instead of submitting.
    public func type(_ text: String, enter: Bool = false) async {
        guard case .running? = pane?.status, let process else { return }
        pane?.typed(Data(text.utf8))
        guard enter else {
            process.write(text)
            return
        }
        await process.write(Data(text.utf8), then: Data("\r".utf8), pause: Self.returnPause, patience: returnPatience)
        // Return reaches the key rules as the key of its own that the program gets.
        pane?.typed(Data("\r".utf8))
    }

    /// Pastes text as one bracketed paste, then presses Return as a keystroke of its own, as `type(_:enter:)` does, so
    /// a long reply reaches a busy Claude Code whole. Newlines go in as Return, as a terminal pastes them, and escape
    /// characters are left out, so the text cannot end its own paste.
    /// Return goes only if `returnIf` still holds once the paste is read, checked in the same turn of the main actor
    /// that writes it, so a dialog that opened meanwhile is never answered by it. Returns whether Return went.
    public func paste(_ text: String, returnIf: () -> Bool) async -> Bool {
        guard case .running? = pane?.status, let process else { return false }
        let clean = Self.pasteable(text)
        await process.write(
            Data("\u{1b}[200~\(clean)\u{1b}[201~".utf8), then: Data(), pause: replyPause, patience: returnPatience)
        await beforeReplyReturn?()
        guard case .running? = pane?.status, returnIf() else { return false }
        process.write(Data("\r".utf8))
        pane?.typed(Data("\r".utf8))
        return true
    }

    static func pasteable(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
            .filter { $0 != "\u{1b}" }
    }

    /// Presses keys one at a time, each in a read of its own, as the author would.
    public func press(_ keys: [String], pause: Duration = .milliseconds(150)) async {
        for (index, key) in keys.enumerated() {
            if index > 0 { try? await Task.sleep(for: pause) }
            guard case .running? = pane?.status, let process else { return }
            process.write(key)
            pane?.typed(Data(key.utf8))
        }
    }

    /// Starts a new shell in the same folder after the last one exited.
    public func restart() {
        guard let pane, case .exited = pane.status, !pane.isClosed else { return }
        programTitle = nil
        // DECSTR undoes modes the last program left on, such as a hidden cursor, then start on a fresh line.
        emulator.feed(Data("\u{1b}[!p\r\n".utf8))
        start(isRemote ? .remoteAttach : .shell)
    }

    /// Hangs up the terminal for good.
    func terminate() {
        process?.terminate()
        process = nil
    }

    /// The title the program set, or else what runs in the foreground. Nil keeps the title the pane has.
    func resolvedTitle() -> String? {
        if let remote = pane?.context.remote {
            // The host says what the session's program titled it, or else which program runs. Until it has, the title
            // tmux passed on stands in.
            let candidates = [remoteActivity?.title, remoteActivity?.foreground, programTitle?.text, remote.host]
            return candidates.lazy.compactMap { $0 }.first { !$0.isEmpty } ?? remote.host
        }
        guard let process else { return nil }
        let resolved = PaneTitle.resolve(programTitle, foreground: process.foreground)
        return resolved.isEmpty ? nil : resolved
    }

    /// The shell's working folder now, so a `cd` is remembered across relaunches. A remote pane's is on its host.
    public var currentDirectory: String? {
        if isRemote { return remoteActivity?.folder }
        return process.flatMap { ProcessTable.folder(of: $0.pid) }
    }

    /// The folder it was restored into, or the row's folder, or the home folder if both are gone.
    private var directory: String {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        if let startDirectory, exists(startDirectory) { return startDirectory }
        let rowPath = pane?.context.rowPath ?? ""
        return exists(rowPath) ? rowPath : settings.baseEnvironment["HOME"] ?? NSHomeDirectory()
    }

    private func start(_ command: PaneCommand) {
        guard let pane else { return }
        self.command = command
        if case .script = command { isScript = true } else { isScript = false }
        let environment = PaneEnvironment.build(settings: settings, context: pane.context, pane: pane.id)
        // A new secret for each shell, so only reports this shell prints count.
        let token = settings.reportsCommands ? UUID().uuidString : nil
        let launch =
            switch command {
            case .shell:
                settings.interactiveShell(environment: environment, directory: directory, commandToken: token)
            case .script(let script): settings.script(script, environment: environment, directory: directory)
            case .remoteAttach: settings.remoteAttach(environment: environment, directory: directory)
            }
        commandMarks = launch.environment["CANOPY_COMMAND_TOKEN"].map(CommandMarkScanner.init(token:))
        do {
            process = try PtyProcess(
                launch, size: emulator.size,
                onOutput: { [weak self] in self?.output($0) },
                onExit: { [weak self] in self?.exited($0) }
            )
            pane.started(title: (launch.executable as NSString).lastPathComponent)
        } catch {
            emulator.feed(Data("\(error)\r\n".utf8))
            exited(127)
        }
    }

    private func output(_ data: Data) {
        guard let pane else { return }
        // A closed pane already logged its exit, and output still on its way from before then comes after it.
        let marks = pane.isClosed ? [] : commandMarks?.scan(data) ?? []
        for mark in marks {
            var report: [String: JSONValue] = [
                "cmd": .string(mark.command), "cwd": .string(mark.directory), "exit": .number(Double(mark.exitCode)),
            ]
            if let duration = mark.durationMs {
                report["durationMs"] = .number(Double(duration))
            }
            pane.record(ActivityType.termCommand, report, source: .ui)
        }
        emulator.feed(data)
    }

    private func input(_ data: Data) {
        guard let pane else { return }
        switch pane.status {
        case .running:
            process?.write(data)
            if !PaneAgent.isTerminalReport(data) {
                pane.typed(data)
            }
        case .exited:
            if data == Data("\r".utf8) { restart() }
        }
    }

    private func setProgramTitle(_ text: String) {
        programTitle = ProgramTitle(text: text, group: process?.foreground?.pid)
        pane?.refreshTitle()
    }

    private func exited(_ code: Int32) {
        // A closed pane already reported its exit. An exit status that was on its way when it closed changes nothing.
        if let pane, pane.isClosed, case .exited = pane.status { return }
        process = nil
        pane?.exited(code)
        // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
        emulator.feed(Data("\u{1b}[?25l".utf8))
    }
}
