import Foundation
import Observation

/// A `!` command the author ran here, before Claude has it.
public struct ChatShellRun: Identifiable, Equatable, Sendable {
    public let id: String
    public var shell: ChatShell
}

public struct ChatImage: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public var mediaType: String
    public var data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
}

/// Why a chat cannot go on until the author does something.
public enum ChatFailure: Equatable, Sendable {
    /// Claude Code exited on its own, with its last lines of stderr.
    case exited(code: Int32, errors: [String])
    case couldNotStart(String)
    case tooOld(version: String)
    /// The saved session's transcript is gone.
    case transcriptMissing
    /// A terminal pane runs this conversation, so a second Claude Code must not.
    case heldElsewhere(pane: String)
}

/// What Claude is doing in a turn, for the status line.
public enum ChatActivity: Equatable, Sendable {
    case idle, working, thinking, compacting
}

/// A message the author sent that Claude has not taken yet.
public struct QueuedPrompt: Identifiable, Equatable, Sendable {
    public let id: String
    public var prompt: ChatPrompt
    /// Sent while Claude worked, so it reads it when the current step ends.
    public var waitsForStep: Bool
    /// `!` commands that go to Claude with it.
    public var shellRuns: [ChatShellRun] = []
}

/// A tool call waiting for the author: a permission, Claude's questions, or a plan to approve.
public struct ChatPermission: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case permission
        case question([PromptQuestion])
        case plan(String)
    }

    public var id: String
    public var kind: Kind
    /// The tool call it is about, whose item its card stands in for while it waits.
    public var toolUse: String?
    public var tool: String
    public var input: [String: JSONValue]
    /// What it wants: a command, a file, a URL, or the tool's name.
    public var subject: String
    public var description: String?
    /// What Always allow saves, such as "canopy row new:*", or nil when Claude Code offers no rule.
    public var rule: String?
    /// When Claude asked.
    public var asked: Date
    var rules: [JSONValue]

    init(_ request: ClaudeToolRequest, asked: Date = Date()) {
        id = request.id
        toolUse = request.toolUse
        self.asked = asked
        switch request.tool {
        case "AskUserQuestion":
            let questions = TranscriptParser.Builder.questions(request.input)
            kind = questions.isEmpty ? .permission : .question(questions)
        case "ExitPlanMode": kind = .plan(request.input["plan"]?.text ?? "")
        default: kind = .permission
        }
        tool = request.tool
        input = request.input
        description = request.description.flatMap { $0.isEmpty ? nil : $0 }
        let input = request.input
        let subject = ["command", "file_path", "notebook_path", "url", "pattern", "query"].lazy
            .compactMap { input[$0]?.text }.first
        self.subject = subject ?? request.blockedPath ?? request.tool
        rules = request.suggestions.filter { $0.fields?["type"]?.text == "addRules" }
        rule = rules.first?.fields?["rules"].flatMap {
            if case .array(let items) = $0 { items.first?.fields?["ruleContent"]?.text } else { nil }
        }
    }
}

/// Whether Claude Code trusts the chat's folder, and how to trust it.
public struct ChatTrust {
    public var isTrusted: @MainActor () -> Bool
    public var grant: @MainActor () async throws -> Void

    public init(isTrusted: @escaping @MainActor () -> Bool, grant: @escaping @MainActor () async throws -> Void) {
        self.isTrusted = isTrusted
        self.grant = grant
    }
}

/// A chat's conversation with one Claude Code session, run headless. Claude starts when the author first sends
/// something, resuming the session if there is one, and runs until the chat closes.
@MainActor
@Observable
public final class ChatSession {
    public typealias Launcher = (_ model: String?, _ mode: String, _ resume: String?) -> TerminalLaunch

    /// The oldest Claude Code chats were checked against.
    public static let minimumVersion = "2.1.296"
    /// The shortest time between two draws of the text being written, about 30 a second.
    static let streamingInterval = Duration.milliseconds(33)
    static let returnKey = Data("\r".utf8)
    static let escapeKey = Data("\u{1b}".utf8)
    /// How many transcript lines the first page reads at least.
    static let pageLines = 400
    /// How many an older page reads at least.
    nonisolated static let olderPageLines = 150

    public var items: [ChatItem] { builder.items }
    /// The text Claude is writing, redrawn at most about 30 times a second.
    public private(set) var streaming: ChatStreamText?
    public private(set) var queued: [QueuedPrompt] = []
    /// The permission prompt shown: the oldest of those waiting.
    public var permission: ChatPermission? { pendingPermissions.first }
    /// Claude can ask several at once, as parallel subagents do. Each needs its own answer.
    public private(set) var pendingPermissions: [ChatPermission] = []
    /// Which of the open question's questions is being answered, and what was answered so far.
    public private(set) var questionStep = 0
    public private(set) var questionAnswers: [String: String] = [:]
    /// A multiple choice's ticked options, by index.
    public private(set) var questionSelection: Set<Int> = []
    public private(set) var sessionID: String?
    /// Nil until Claude Code says, for a chat that leaves the choice to its settings.
    public private(set) var model: String?
    public private(set) var mode: String
    public private(set) var isWorking = false
    public private(set) var activity = ChatActivity.idle
    public private(set) var turnStarted: Date?
    /// How long the last turn took, once it ended.
    public private(set) var lastTurn: TimeInterval?
    public private(set) var turnTokens = 0
    public private(set) var contextTokens: Int?
    public private(set) var contextWindow: Int?
    public private(set) var rateLimitedUntil: Date?
    public private(set) var failure: ChatFailure?
    /// Read when the chat first shows, not for every restored chat at launch.
    public private(set) var needsTrust = false
    public private(set) var hasOlder = false
    public private(set) var isLoadingOlder = false
    /// Commands running now, by tool call ID, as Claude Code's task events say.
    public private(set) var runningCommands: Set<String> = []
    /// Items the author opened, such as a tool line's list of calls or a diff card's whole diff.
    public private(set) var expanded: Set<String> = []

    public func toggle(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    /// The last lines of each running command's output, by tool call ID.
    public private(set) var tails: [String: [String]] = [:]
    /// How many lines a tail keeps.
    public static let tailLines = 5
    /// How far from a task file's end a read starts at most.
    static let tailWindow: UInt64 = 16 * 1024
    @ObservationIgnored private var tasks: [String: String] = [:]
    @ObservationIgnored private var tailOffsets: [String: UInt64] = [:]
    @ObservationIgnored private var tailPartial: [String: Data] = [:]
    /// When each running command started, and how many lines it has printed, for its card.
    public private(set) var taskStarts: [String: Date] = [:]
    public private(set) var tailCounts: [String: Int] = [:]
    @ObservationIgnored private var tailPoll: Task<Void, Never>?
    @ObservationIgnored private var cwd: String?
    /// Where Claude Code writes running commands' output: `<root>/<folder>/<session>/tasks/<task>.output`.
    @ObservationIgnored private let tasksRoot: URL
    public var title: String {
        didSet {
            guard title != oldValue else { return }
            onTitle()
            onChange()
        }
    }
    /// What the composer holds, kept here so it survives the view.
    public var draft = ""
    /// Images pasted or dropped into the composer, sent with the next message.
    public var draftImages: [ChatImage] = []
    /// `!` commands run since the last message, which Claude reads with the next one.
    public private(set) var shellRuns: [ChatShellRun] = []
    @ObservationIgnored private let shell: ((String) -> TerminalLaunch)?
    @ObservationIgnored private var shellProcess: PipeProcess?

    /// Called when something worth saving changes: the session, the title.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// Called when Claude Code is gone, by closing or by exiting.
    @ObservationIgnored public var onEnded: () -> Void = {}
    /// Called with the key each of the author's actions stands for, Return to send or allow and Escape to deny or
    /// stop, so the pane's agent state follows them as it follows a terminal's keys.
    @ObservationIgnored public var onInput: (Data) -> Void = { _ in }
    @ObservationIgnored public var onTitle: () -> Void = {}
    /// Called with the model and mode when the author picks either, so new chats start with them.
    /// Called with what the author picked, nil for what they left alone.
    @ObservationIgnored public var onPick: (String?, String?) -> Void = { _, _ in }
    /// Commands Claude runs in the background, by task ID.
    @ObservationIgnored private var backgroundTasks: Set<String> = []
    @ObservationIgnored private var lastStreamingPublish: ContinuousClock.Instant?
    /// How many times `streaming` changed, and the shortest time between two changes, for tests.
    @ObservationIgnored private(set) var streamingPublishCount = 0
    @ObservationIgnored private(set) var shortestStreamingGap: Duration?

    private var builder = ChatBuilder()
    @ObservationIgnored private var stream: ClaudeStream?
    @ObservationIgnored private let launcher: Launcher
    @ObservationIgnored private let transcript: (String) -> URL?
    @ObservationIgnored private let trust: ChatTrust
    @ObservationIgnored private var olderCursor: Int?
    @ObservationIgnored private var transcriptURL: URL?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var tokensBeforeMessage = 0
    /// An interrupt went out this turn, so a permission request still on its way is turned down.
    @ObservationIgnored private var interrupting = false
    @ObservationIgnored private var isOpen = false

    public init(
        model: String?, mode: String, sessionID: String?, title: String, launcher: @escaping Launcher,
        transcript: @escaping (String) -> URL?, trust: ChatTrust,
        tasksRoot: URL = URL(fileURLWithPath: "/tmp/claude-\(getuid())"),
        shell: ((String) -> TerminalLaunch)? = nil
    ) {
        self.shell = shell
        self.tasksRoot = tasksRoot
        self.model = model
        self.mode = mode
        self.sessionID = sessionID
        self.title = title
        self.launcher = launcher
        self.transcript = transcript
        self.trust = trust
    }

    /// Reads the newest page of a saved session's history, once, when the chat first shows, so restored chats that
    /// stay out of view cost nothing.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        needsTrust = !trust.isTrusted()
        if let sessionID { loadHistory(sessionID) }
    }

    public var isRunning: Bool { stream?.isRunning ?? false }

    public var pid: pid_t? { stream?.pid }

    /// Commands that need Claude Code's full screen, from `init`.
    public private(set) var terminalCommands: [String] = []

    /// The commands Claude Code offers, once it has started.
    public var commands: [ClaudeCommand] { stream?.commands ?? [] }

    // MARK: The author

    /// Sends a message, starting Claude if it is not running. While a permission prompt is open, it denies the prompt
    /// first, so the message tells Claude what to do instead. That is how the TUI's "No, and tell Claude what to do
    /// differently" works: a denial's own message reaches Claude as the tool's output, which it may distrust.
    public func send(_ text: String, images: [ChatImage] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        open()
        if text.hasPrefix("!"), images.isEmpty {
            runShell(String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        if failure == .transcriptMissing { startFresh() }
        if needsTrust { needsTrust = !trust.isTrusted() }
        // Text typed at a question answers it in the author's own words.
        if case .question? = permission?.kind, images.isEmpty {
            record(answer: text)
            return
        }
        deny()
        guard !needsTrust else { return }
        if !isWorking {
            turnStarted = Date()
            turnTokens = 0
            lastTurn = nil
        }
        // A slash command must start its message, so `!` output waits for the next plain one.
        let ran = text.hasPrefix("/") ? [] : shellRuns.filter { $0.shell.exitCode != nil }
        shellRuns.removeAll { run in ran.contains { $0.id == run.id } }
        queued.append(
            QueuedPrompt(
                id: UUID().uuidString, prompt: ChatPrompt(text: text, images: images.count),
                waitsForStep: isWorking, shellRuns: ran))
        isWorking = true
        if title.isEmpty, let line = text.split(whereSeparator: \.isNewline).first {
            title = String(line.prefix(80))
        }
        if !isRunning {
            start()
            guard isRunning else { return }
        }
        onInput(Self.returnKey)
        stream?.send(
            Self.shellBlocks(ran) + images.map { .image(mediaType: $0.mediaType, data: $0.data) } + [.text(text)])
    }

    /// Whether `send` takes `text` now. A `!` command waits for the one running, and a bare `!` is not one.
    public func takes(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("!") else { return true }
        return !isRunningShell && !text.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `!` commands as Claude Code's TUI sends them, with a failure's exit code where stderr goes.
    static func shellBlocks(_ runs: [ChatShellRun]) -> [ClaudeInput.Content] {
        runs.flatMap { run -> [ClaudeInput.Content] in
            let code = run.shell.exitCode ?? 0
            return [
                .text("<bash-input>\(run.shell.command)</bash-input>"),
                .text(
                    "<bash-stdout>\(run.shell.outputForClaude)</bash-stdout>"
                        + "<bash-stderr>\(code == 0 ? "" : "Exit code \(code)")</bash-stderr>"),
            ]
        }
    }

    public func allow() {
        guard let permission else { return }
        stream?.answer(ClaudeInput.allow(request: permission.id, input: permission.input))
        pendingPermissions.removeFirst()
        onInput(Self.returnKey)
    }

    /// Allows it and saves Claude Code's suggested rule, so it is not asked again.
    public func alwaysAllow() {
        guard let permission else { return }
        stream?.answer(
            ClaudeInput.allow(request: permission.id, input: permission.input, permissions: permission.rules))
        pendingPermissions.removeFirst()
        onInput(Self.returnKey)
    }

    /// Switches the permission mode, at once if Claude Code runs, or for when it starts.
    public func setMode(_ mode: String) {
        self.mode = mode
        // Bypass and Plan are for one chat; a new chat never starts in them.
        onPick(nil, ["default", "acceptEdits", "auto"].contains(mode) ? mode : nil)
        onChange()
        guard let stream, stream.isRunning else { return }
        Task { try? await stream.request("set_permission_mode", ["mode": .string(mode)]) }
    }

    /// Switches the model. Claude Code 2.1.296 takes `set_model` only after the next turn has started on the old
    /// model, so an idle chat ends its Claude Code instead and the next message resumes the session on the new one.
    public func setModel(_ model: String) {
        self.model = model
        onPick(model, nil)
        onChange()
        guard let stream, stream.isRunning else { return }
        if isWorking || !backgroundTasks.isEmpty {
            // A background command dies with the process, so it keeps running and switches as it can.
            Task { try? await stream.request("set_model", ["model": .string(model)]) }
        } else {
            self.stream = nil
            stream.stop()
            onEnded()
        }
    }

    /// The models Claude Code offers once it runs, or its aliases before.
    public var models: [ClaudeModel] {
        let offered = stream?.models ?? []
        return offered.isEmpty ? ClaudeModel.aliases : offered
    }

    /// Picks an option of the open question by index: the answer for a single choice, a tick for a multiple choice.
    public func pick(_ index: Int) {
        guard let questions = openQuestions, questionStep < questions.count else { return }
        let question = questions[questionStep]
        guard question.options.indices.contains(index) else { return }
        if question.multiSelect {
            if questionSelection.remove(index) == nil { questionSelection.insert(index) }
        } else {
            record(answer: question.options[index].label)
        }
    }

    /// Runs a `!` command in the row, as the author's login shell would, and keeps what it prints for Claude. Its
    /// stderr joins stdout in order, and it reads no input, so a command that asks for some ends instead of waiting.
    private func runShell(_ command: String) {
        guard !command.isEmpty, shellProcess == nil, let shell else { return }
        let id = UUID().uuidString
        shellRuns.append(ChatShellRun(id: id, shell: ChatShell(command: command, output: "", exitCode: nil)))
        do {
            let process = try PipeProcess(
                shell("{ \(command)\n} </dev/null 2>&1"), keepsBlankLines: true,
                onLines: { [weak self] lines in
                    let text = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
                    self?.updateShell(id) { $0.append(text) }
                },
                onExit: { [weak self] code in
                    guard let self else { return }
                    self.updateShell(id) { $0.exitCode = code }
                    self.shellProcess = nil
                })
            // The login shell's own startup reads nothing either.
            process.closeInput()
            shellProcess = process
        } catch {
            updateShell(id) {
                $0.output = "\(error)"
                $0.exitCode = 127
            }
        }
    }

    private func updateShell(_ id: String, _ change: (inout ChatShell) -> Void) {
        guard let index = shellRuns.firstIndex(where: { $0.id == id }) else { return }
        change(&shellRuns[index].shell)
    }

    /// Stops a `!` command still running.
    public func stopShell() {
        shellProcess?.terminate()
    }

    public var isRunningShell: Bool { shellProcess != nil }

    /// The name of another pane holding a session, so this chat does not start a second Claude Code on it.
    @ObservationIgnored public var heldBy: (String) -> String? = { _ in nil }
    /// Shows the pane that holds this chat's session.
    @ObservationIgnored public var showHolder: () -> Void = {}

    /// Ends the chat so a terminal can take its conversation over. A turn under way is interrupted first, so the
    /// transcript ends where Claude stopped. Returns what Claude has not read yet, the draft and finished `!` commands,
    /// as one message for the terminal to send.
    public func handOff() async -> String? {
        if isWorking {
            interrupt()
            let deadline = Date().addingTimeInterval(5)
            while isWorking, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        returnQueuedToDraft()
        let runs = shellRuns.filter { $0.shell.exitCode != nil }.map { run in
            "I ran `\(run.shell.command)`" + (run.shell.exitCode == 0 ? "" : " (exit \(run.shell.exitCode ?? 0))")
                + ":\n```\n\(run.shell.outputForClaude)\n```"
        }
        let parts = runs + (draft.isEmpty ? [] : [draft])
        close()
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Whether `index` is one of the current question's options, so a digit typed past them stays text.
    public func canPick(_ index: Int) -> Bool {
        guard let questions = openQuestions, questionStep < questions.count else { return false }
        return questions[questionStep].options.indices.contains(index)
    }

    /// Sends a multiple choice's ticked options.
    public func submitSelection() {
        guard let questions = openQuestions, questionStep < questions.count, !questionSelection.isEmpty else { return }
        let options = questions[questionStep].options
        record(answer: questionSelection.sorted().map { options[$0].label }.joined(separator: ", "))
    }

    /// Approves the open plan, switching to accepting edits or to asking before them.
    public func approvePlan(acceptingEdits: Bool) {
        guard let permission, case .plan = permission.kind else { return }
        let mode: JSONValue = .object([
            "type": "setMode", "mode": .string(acceptingEdits ? "acceptEdits" : "default"), "destination": "session",
        ])
        stream?.answer(ClaudeInput.allow(request: permission.id, input: permission.input, permissions: [mode]))
        pendingPermissions.removeFirst()
        onInput(Self.returnKey)
    }

    private var openQuestions: [PromptQuestion]? {
        if case .question(let questions)? = permission?.kind { questions } else { nil }
    }

    /// Takes the answer to the current question, and sends them all once the last is answered.
    private func record(answer: String) {
        guard let permission, let questions = openQuestions, questionStep < questions.count else { return }
        questionAnswers[questions[questionStep].question] = answer
        questionStep += 1
        questionSelection = []
        guard questionStep >= questions.count else { return }
        var input = permission.input
        input["answers"] = .object(questionAnswers.mapValues(JSONValue.string))
        stream?.answer(ClaudeInput.allow(request: permission.id, input: input))
        pendingPermissions.removeFirst()
        resetQuestion()
        onInput(Self.returnKey)
    }

    /// Drops every open prompt and any half-answered question with them.
    private func clearPrompts() {
        pendingPermissions = []
        resetQuestion()
    }

    private func resetQuestion() {
        questionStep = 0
        questionAnswers = [:]
        questionSelection = []
    }

    /// Denies every open prompt and stops the turn, as Esc does in the TUI.
    public func deny() {
        guard !pendingPermissions.isEmpty else { return }
        for permission in pendingPermissions {
            stream?.answer(
                ClaudeInput.deny(
                    request: permission.id, message: "The user doesn't want to proceed with this tool use.",
                    interrupt: true))
        }
        pendingPermissions = []
        resetQuestion()
        onInput(Self.escapeKey)
    }

    /// Stops what Claude is doing, as Esc does. Claude Code acknowledges an interrupt but goes on waiting for an open
    /// permission prompt, so a prompt open now or arriving later in the turn is denied, which stops the turn.
    public func interrupt() {
        guard isWorking, let stream else { return }
        interrupting = true
        if permission != nil {
            deny()
        } else {
            onInput(Self.escapeKey)
            Task { try? await stream.request("interrupt") }
        }
    }

    /// Puts a failure away, so the next message starts Claude Code again where it left off.
    public func dismissFailure() {
        failure = nil
    }

    /// Leaves a session whose transcript is gone and starts a new conversation with the next message.
    public func startFresh() {
        sessionID = nil
        failure = nil
        onChange()
    }

    public func grantTrust() async throws {
        try await trust.grant()
        needsTrust = !trust.isTrusted()
    }

    /// Ends Claude Code for good.
    public func close() {
        stopShell()
        flush?.cancel()
        let stream = stream
        self.stream = nil
        stream?.stop()
        if stream != nil { onEnded() }
        isWorking = false
        clearPrompts()
        endTails()
    }

    /// Reads the next older page off the main actor and puts it in front. Older pages are smaller than the first, so
    /// measuring their rows while the author scrolls stays short.
    public func loadOlder() {
        guard !isLoadingOlder, let url = transcriptURL, let before = olderCursor else { return }
        isLoadingOlder = true
        let snapshot = builder
        Task {
            let loaded = await Task.detached { () -> (ChatBuilder, Int?)? in
                guard
                    let page = try? TranscriptReader.linePage(
                        of: url, before: before, minimumLines: Self.olderPageLines)
                else { return nil }
                return (snapshot.olderPage(lines: page.lines), page.older)
            }.value
            isLoadingOlder = false
            // A /clear or a new session since then makes the page belong to another conversation.
            guard let (older, cursor) = loaded, olderCursor == before, transcriptURL == url else { return }
            builder.prepend(older)
            olderCursor = cursor
            hasOlder = cursor != nil
        }
    }

    // MARK: Claude

    private func loadHistory(_ session: String) {
        guard let url = transcript(session),
            let page = try? TranscriptReader.linePage(of: url, before: nil, minimumLines: Self.pageLines)
        else {
            failure = .transcriptMissing
            return
        }
        transcriptURL = url
        for line in page.lines { builder.add(line: line) }
        olderCursor = page.older
        hasOlder = page.older != nil
    }

    private func start() {
        failure = nil
        if let sessionID, let holder = heldBy(sessionID) {
            failure = .heldElsewhere(pane: holder)
            returnQueuedToDraft()
            isWorking = false
            return
        }
        let stream = ClaudeStream()
        stream.onEvent = { [weak self] in self?.received($0) }
        stream.onExit = { [weak self, weak stream] code, errors in
            guard let self, let stream, self.stream === stream else { return }
            self.exited(code, errors)
        }
        do {
            try stream.start(launcher(model, mode, sessionID))
            self.stream = stream
        } catch {
            failure = .couldNotStart("\(error)")
            returnQueuedToDraft()
            isWorking = false
        }
    }

    private func received(_ event: ClaudeEvent) {
        switch event {
        case .initialized(let info):
            if let version = info.version, !Self.isSupported(version) {
                failure = .tooOld(version: version)
                close()
                return
            }
            if sessionID != info.session {
                sessionID = info.session
                onChange()
            }
            model = info.model
            mode = info.mode
            cwd = info.cwd
            if !info.terminalCommands.isEmpty { terminalCommands = info.terminalCommands }
        case .status(let status):
            if let mode = status.mode { self.mode = mode }
            switch status.activity {
            case "compacting": activity = .compacting
            case "requesting": activity = .working
            default: if activity == .compacting { activity = .working }
            }
        case .conversationReset:
            builder = ChatBuilder()
            transcriptURL = nil
            olderCursor = nil
            hasOlder = false
            endStreaming()
        case .messageStarted:
            tokensBeforeMessage = turnTokens
            endStreaming()
        case .blockStarted(_, let kind):
            activity = kind == "thinking" ? .thinking : .working
        case .textDelta(_, let text):
            pendingText += text
            publishStreamingSoon()
        case .outputTokens(let tokens):
            turnTokens = tokensBeforeMessage + tokens
        case .message(let message):
            received(message)
        case .result(let result):
            endStreaming()
            // Claude Code drops what was queued when a turn is interrupted, so it goes back to the composer.
            if interrupting { returnQueuedToDraft() }
            interrupting = false
            runningCommands = []
            endTails()
            if let window = result.contextWindow { contextWindow = window }
            if result.isError, result.kind != "error_during_execution", let text = result.text, !text.isEmpty {
                builder.addNotice(text)
            }
            clearPrompts()
            activity = .idle
            if queued.isEmpty {
                isWorking = false
                lastTurn = turnStarted.map { Date().timeIntervalSince($0) }
            }
        case .rateLimit(let allowed, let resetsAt):
            rateLimitedUntil = allowed ? nil : resetsAt
        case .toolRequest(let request):
            received(request)
        case .taskStarted(let task, _, true):
            backgroundTasks.insert(task)
        case .taskStarted(let task, let toolUse?, false):
            runningCommands.insert(toolUse)
            tasks[toolUse] = task
            taskStarts[toolUse] = Date()
            startTailing()
        case .taskEnded(let task, let toolUse, _):
            backgroundTasks.remove(task)
            guard let toolUse else { break }
            runningCommands.remove(toolUse)
            endTail(toolUse)
        case .taskStarted, .unknownRequest, .controlResponse:
            break
        }
    }

    private func received(_ message: ClaudeMessage) {
        // A subagent's own messages count under the call that started it.
        if let parent = message.parentToolUse {
            builder.add(subagentLine: message.line, parent: parent)
            return
        }
        if message.role == "assistant" {
            endStreaming()
            if let tokens = message.contextTokens { contextTokens = tokens }
        }
        if message.isReplay { taken(message.line) }
        builder.add(line: message.line)
    }

    /// Puts messages Claude never took back in the composer, so nothing the author wrote is lost.
    private func returnQueuedToDraft() {
        guard !queued.isEmpty else { return }
        let texts = queued.map(\.prompt.text) + (draft.isEmpty ? [] : [draft])
        draft = texts.joined(separator: "\n\n")
        shellRuns = queued.flatMap(\.shellRuns) + shellRuns
        queued = []
    }

    /// Claude Code echoes the messages it takes, and messages that queued up during a turn come back as one.
    private func taken(_ line: Data) {
        guard !queued.isEmpty else { return }
        let blocks = TranscriptParser.Record(line: line)?.blocks ?? []
        let texts = blocks.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // An echo with no text of its own, or a local command's output such as "Set model to …", takes nothing.
        guard !texts.isEmpty, !texts.contains(where: { $0.hasPrefix("<local-command-") || $0.hasPrefix("<command-") })
        else { return }
        var matched = false
        for text in texts + (texts.count > 1 ? [texts.joined(separator: "\n")] : []) {
            if let index = queued.firstIndex(where: { $0.prompt.text == text }) {
                queued.remove(at: index)
                matched = true
            }
        }
        if !matched { queued.removeFirst() }
    }

    private func received(_ request: ClaudeToolRequest) {
        if interrupting {
            stream?.answer(
                ClaudeInput.deny(
                    request: request.id, message: "The user doesn't want to proceed with this tool use.",
                    interrupt: true))
            return
        }
        pendingPermissions.append(ChatPermission(request))
    }

    private func exited(_ code: Int32, _ errors: [String]) {
        stream = nil
        flush?.cancel()
        endStreaming()
        if failure == nil { failure = .exited(code: code, errors: errors) }
        isWorking = false
        activity = .idle
        clearPrompts()
        returnQueuedToDraft()
        runningCommands = []
        endTails()
        interrupting = false
        onEnded()
    }

    private func startTailing() {
        guard tailPoll == nil else { return }
        tailPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readTails()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Reads what each running command wrote since the last read.
    func readTails() {
        guard let cwd, let sessionID else { return }
        let folder = tasksRoot.appending(path: ClaudeProjects.folderName(for: cwd)).appending(path: sessionID)
            .appending(path: "tasks")
        for (toolUse, task) in tasks {
            guard let handle = try? FileHandle(forReadingFrom: folder.appending(path: task + ".output")) else {
                continue
            }
            defer { try? handle.close() }
            // Only the end matters: a noisy command can write megabytes between reads.
            guard let size = try? handle.seekToEnd() else { continue }
            let offset = max(tailOffsets[toolUse] ?? 0, size > Self.tailWindow ? size - Self.tailWindow : 0)
            guard size > offset, (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd()
            else { continue }
            tailOffsets[toolUse] = size
            // Kept as bytes until a line ends, so a character split across reads stays whole; `\r` ends a line too,
            // as a progress bar redraws it.
            var pending = (tailPartial[toolUse] ?? Data()) + data
            var lines: [String] = []
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                pending = Data(pending[pending.index(after: end)...])
            }
            tailPartial[toolUse] = Data(pending.suffix(Int(Self.tailWindow)))
            lines = lines.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            tailCounts[toolUse, default: 0] += lines.count
            tails[toolUse] = Array(((tails[toolUse] ?? []) + lines).suffix(Self.tailLines))
        }
    }

    private func endTail(_ toolUse: String) {
        tasks[toolUse] = nil
        tails[toolUse] = nil
        tailOffsets[toolUse] = nil
        tailPartial[toolUse] = nil
        taskStarts[toolUse] = nil
        tailCounts[toolUse] = nil
        if tasks.isEmpty {
            tailPoll?.cancel()
            tailPoll = nil
        }
    }

    private func endTails() {
        for toolUse in Array(tasks.keys) { endTail(toolUse) }
    }

    /// Draws the new text now if the last draw was at least `streamingInterval` ago, or else once it is.
    private func publishStreamingSoon() {
        let now = ContinuousClock.now
        guard let last = lastStreamingPublish, now - last < Self.streamingInterval else {
            publishStreaming()
            return
        }
        guard flush == nil else { return }
        let wait = Self.streamingInterval - (now - last)
        flush = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.flush = nil
            self.publishStreaming()
        }
    }

    private func publishStreaming() {
        flush?.cancel()
        flush = nil
        guard !pendingText.isEmpty else { return }
        var text = streaming ?? ChatStreamText()
        text.append(pendingText)
        pendingText = ""
        streaming = text
        let now = ContinuousClock.now
        if let last = lastStreamingPublish {
            shortestStreamingGap = min(shortestStreamingGap ?? now - last, now - last)
        }
        lastStreamingPublish = now
        streamingPublishCount += 1
    }

    private func endStreaming() {
        flush?.cancel()
        flush = nil
        pendingText = ""
        if streaming != nil { streaming = nil }
    }

    /// Whether `version` is at least `minimumVersion`.
    static func isSupported(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return false }
        let found = parts.compactMap { $0 }
        let needed = minimumVersion.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(found.count, needed.count) {
            let have = index < found.count ? found[index] : 0
            let need = index < needed.count ? needed[index] : 0
            if have != need { return have > need }
        }
        return true
    }
}
