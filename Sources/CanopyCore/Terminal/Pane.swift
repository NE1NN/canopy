import Foundation
import Observation

/// One pane in a row: a terminal, or a chat with Claude Code. Either way it has an ID that agents see as CANOPY_PANE,
/// the agent state its hooks report, and a title.
@MainActor
@Observable
public final class Pane: Identifiable {
    public enum Status: Sendable, Equatable {
        case running
        case exited(Int32)
    }

    public enum Body {
        case terminal(TerminalBody)
        case chat(ChatSession)
    }

    /// What `waitForExit` reports for a pane closed while its process ran, as for SIGHUP.
    public static let closedExitCode: Int32 = 129

    public let id: PaneID
    /// The row it belongs to. Updated if the repo moves.
    public internal(set) var context: PaneContext
    public let body: Body
    public private(set) var status = Status.running
    public private(set) var title = ""
    /// A title given with `canopy term new --title`. It wins over what the program sets.
    public var fixedTitle: String? {
        didSet { refreshTitle() }
    }
    @ObservationIgnored private let activity: ActivityLog
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    @ObservationIgnored private(set) var isClosed = false

    /// What the agent in it is doing, as its hooks or `canopy term state` report it.
    public private(set) var agent = PaneAgent()
    /// Called after each change to `agent`.
    @ObservationIgnored public var onAgentChange: ((Pane, AgentChange) -> Void)?
    /// Called when the pane closes for good, before its agent state clears.
    @ObservationIgnored public var onClose: ((Pane) -> Void)?
    /// Called when the pane's agent takes a prompt, as its `UserPromptSubmit` hook says.
    @ObservationIgnored public var onPrompted: ((Pane) -> Void)?
    /// When a key was last typed or text sent. Kept out of observation, so typing redraws no dot.
    @ObservationIgnored public private(set) var lastInput = Date.distantPast

    /// A terminal pane, whose process starts at once.
    init(
        id: PaneID, context: PaneContext, command: PaneCommand, settings: ShellSettings,
        emulator: any TerminalEmulator, activity: ActivityLog, directory: String? = nil, session: String? = nil
    ) {
        self.id = id
        self.context = context
        self.activity = activity
        let terminal = TerminalBody(
            emulator: emulator, command: command, isRemote: context.remote != nil, settings: settings,
            directory: directory, session: session, paneID: id, rowPath: context.rowPath)
        body = .terminal(terminal)
        terminal.attach(to: self)
    }

    /// A chat pane. Its Claude Code starts when the author first sends something.
    init(id: PaneID, context: PaneContext, chat: ChatSession, activity: ActivityLog) {
        self.id = id
        self.context = context
        self.activity = activity
        body = .chat(chat)
        chat.onInput = { [weak self] in self?.typed($0) }
        chat.onEnded = { [weak self] in self?.refreshActivity() }
        chat.onTitle = { [weak self] in self?.refreshTitle() }
        record(ActivityType.termOpened)
        refreshTitle()
    }

    public var terminal: TerminalBody? {
        if case .terminal(let terminal) = body { terminal } else { nil }
    }

    public var chat: ChatSession? {
        if case .chat(let chat) = body { chat } else { nil }
    }

    /// Whether the agent reached its state after the last input, so a done from before a new prompt does not count.
    public var agentIsFresh: Bool {
        agent.isFresh(after: lastInput)
    }

    /// The process the pane runs: a terminal's shell, or a chat's Claude Code while it runs.
    public var pid: pid_t? {
        switch body {
        case .terminal(let terminal): terminal.pid
        case .chat(let chat): chat.pid
        }
    }

    public var foreground: ForegroundProcess? {
        switch body {
        case .terminal(let terminal): terminal.foreground
        case .chat(let chat): chat.pid.map { ForegroundProcess(pid: $0, name: "claude") }
        }
    }

    /// True while a program other than the shell runs, such as `claude` or `bun dev`, or while a chat's Claude Code
    /// runs.
    public var isBusy: Bool {
        switch body {
        case .terminal(let terminal): terminal.isBusy
        case .chat(let chat): status == .running && chat.isRunning
        }
    }

    /// Whether closing it would stop work in progress: a program running in a terminal, or a turn Claude is working
    /// on in a chat. A chat whose Claude Code waits for the next message loses nothing by closing.
    public var hasRunningWork: Bool {
        switch body {
        case .terminal: isBusy
        case .chat(let chat): chat.isWorking
        }
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
        if report.event == "UserPromptSubmit", report.session == nil || report.session == agent.session {
            onPrompted?(self)
        }
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

    /// Takes the answer to the agent's open prompt, if `id` still names it.
    public func answerPrompt(id: String) -> Bool {
        agent.answer(promptID: id)
    }

    /// Ends the process for good.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose?(self)
        switch body {
        case .terminal(let terminal): terminal.terminate()
        case .chat(let chat): chat.close()
        }
        if case .running = status {
            exited(Self.closedExitCode)
        }
    }

    /// Reads the title again: the one given, a terminal's program's, or a chat's conversation's.
    /// A pane whose process exited keeps its last title.
    public func refreshTitle() {
        if let fixedTitle {
            title = fixedTitle
            return
        }
        switch body {
        case .terminal(let terminal):
            if let resolved = terminal.resolvedTitle() { title = resolved }
        case .chat(let chat):
            title = chat.title.isEmpty ? "Chat" : chat.title
        }
    }

    /// The shell's working folder now, so a `cd` is remembered across relaunches. A remote pane's is on its host.
    public var currentDirectory: String? {
        terminal?.currentDirectory
    }

    // MARK: From the body

    func started(title: String) {
        status = .running
        record(ActivityType.termOpened)
        // Name the pane after what was launched. Reading the foreground now could catch the child
        // between fork and exec, still named after Canopy.
        self.title = title
    }

    /// Events about a plugin row leave the repo out and name the plugin and item instead.
    func record(_ type: String, _ data: [String: JSONValue] = [:], source: ActivitySource = .current) {
        var data = data.merging(["pane": .string(id.description)]) { value, _ in value }
        if case .plugin(let plugin, let item) = context.owner {
            data["plugin"] = .string(plugin)
            data["item"] = .string(item)
        }
        activity.record(
            type, repo: context.repoName, row: context.rowName, path: context.rowPath, source: source, data: data)
    }

    /// Keys typed or text sent, which can answer or end what the agent waits on.
    func typed(_ data: Data) {
        let now = Date()
        lastInput = now
        agentChanged(agent.typed(data, at: now))
    }

    func exited(_ code: Int32) {
        status = .exited(code)
        isRunningProgram = false
        record(ActivityType.termExited, ["code": .number(Double(code))])
        agentChanged(agent.ended(at: Date()))
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: code)
        }
    }

    private func agentChanged(_ change: AgentChange?) {
        guard let change else { return }
        var data: [String: JSONValue] = [
            "from": change.from == .none ? .null : .string(change.from.rawValue), "via": .string(change.via),
        ]
        if let session = change.session {
            data["session"] = .string(session)
        }
        if change.to == .background {
            data["tasks"] = .array(agent.backgroundTasks.map(JSONValue.string))
        }
        record(ActivityType.agent(change.to), data)
        onAgentChange?(self, change)
    }
}
