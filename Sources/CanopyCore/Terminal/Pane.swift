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
    @ObservationIgnored private var process: PtyProcess?
    @ObservationIgnored private var programTitle: ProgramTitle?
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var isScript = false

    /// The folder the shell starts in, when restored into one other than the row's.
    public let startDirectory: String?

    init(
        id: PaneID, context: PaneContext, command: PaneCommand, settings: ShellSettings,
        emulator: any TerminalEmulator, directory: String? = nil
    ) {
        self.id = id
        self.context = context
        self.startDirectory = directory
        self.settings = settings
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

    /// Types `command` and Return once the shell's line editor is ready, so the shell does not echo it twice.
    /// Shells without a line editor never report ready, so it types anyway after `timeout`.
    public func run(_ command: String, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while let process, !process.isAtPrompt, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        process?.write(command + "\r")
    }

    /// Sends text as if typed, for `canopy term send`. An exited pane ignores it.
    public func type(_ text: String) {
        guard case .running = status else { return }
        process?.write(text)
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
        process.flatMap { PtyProcess.currentDirectory(of: $0.pid) }
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
        let launch =
            switch command {
            case .shell: settings.interactiveShell(environment: environment, directory: directory)
            case .script(let script): settings.script(script, environment: environment, directory: directory)
            }
        do {
            process = try PtyProcess(
                launch, size: emulator.size,
                onOutput: { [weak self] in self?.emulator.feed($0) },
                onExit: { [weak self] in self?.processExited($0) }
            )
            status = .running
            // Name the pane after what was launched. Reading the foreground now could catch the child
            // between fork and exec, still named after Canopy.
            title = (launch.executable as NSString).lastPathComponent
        } catch {
            emulator.feed(Data("\(error)\r\n".utf8))
            processExited(127)
        }
    }

    private func input(_ data: Data) {
        switch status {
        case .running:
            process?.write(data)
        case .exited:
            if data == Data("\r".utf8) { restart() }
        }
    }

    private func setProgramTitle(_ text: String) {
        programTitle = ProgramTitle(text: text, group: process?.foreground?.pid)
        refreshTitle()
    }

    private func processExited(_ code: Int32) {
        // A closed pane already reported its exit. An exit status that was on its way when it closed changes nothing.
        if isClosed, case .exited = status { return }
        process = nil
        status = .exited(code)
        // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
        emulator.feed(Data("\u{1b}[?25l".utf8))
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: code)
        }
    }
}
