import Foundation
import Observation

public struct ChatImage: Equatable, Sendable {
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
}

/// A tool call waiting for the author's permission.
public struct ChatPermission: Identifiable, Equatable, Sendable {
    public var id: String
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
        self.asked = asked
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
    public private(set) var permission: ChatPermission?
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
    public private(set) var needsTrust: Bool
    public private(set) var hasOlder = false
    public private(set) var isLoadingOlder = false
    /// Commands running now, by tool call ID, as Claude Code's task events say.
    public private(set) var runningCommands: Set<String> = []
    public var title: String {
        didSet {
            guard title != oldValue else { return }
            onTitle()
            onChange()
        }
    }
    /// What the composer holds, kept here so it survives the view.
    public var draft = ""

    /// Called when something worth saving changes: the session, the title.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// Called when Claude Code is gone, by closing or by exiting.
    @ObservationIgnored public var onEnded: () -> Void = {}
    /// Called with the key each of the author's actions stands for, Return to send or allow and Escape to deny or
    /// stop, so the pane's agent state follows them as it follows a terminal's keys.
    @ObservationIgnored public var onInput: (Data) -> Void = { _ in }
    @ObservationIgnored public var onTitle: () -> Void = {}
    /// When `streaming` changed, for tests.
    @ObservationIgnored private(set) var streamingPublishes: [ContinuousClock.Instant] = []

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
        transcript: @escaping (String) -> URL?, trust: ChatTrust
    ) {
        self.model = model
        self.mode = mode
        self.sessionID = sessionID
        self.title = title
        self.launcher = launcher
        self.transcript = transcript
        self.trust = trust
        needsTrust = !trust.isTrusted()
    }

    /// Reads the newest page of a saved session's history, once, when the chat first shows, so restored chats that
    /// stay out of view cost nothing.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        if let sessionID { loadHistory(sessionID) }
    }

    public var isRunning: Bool { stream?.isRunning ?? false }

    public var pid: pid_t? { stream?.pid }

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
        deny()
        guard !needsTrust else { return }
        if !isWorking {
            turnStarted = Date()
            turnTokens = 0
            lastTurn = nil
        }
        queued.append(
            QueuedPrompt(
                id: UUID().uuidString, prompt: ChatPrompt(text: text, images: images.count),
                waitsForStep: isWorking))
        isWorking = true
        if title.isEmpty, let line = text.split(whereSeparator: \.isNewline).first {
            title = String(line.prefix(80))
        }
        if !isRunning {
            start()
            guard isRunning else { return }
        }
        onInput(Self.returnKey)
        stream?.send(images.map { .image(mediaType: $0.mediaType, data: $0.data) } + [.text(text)])
    }

    public func allow() {
        guard let permission else { return }
        stream?.answer(ClaudeInput.allow(request: permission.id, input: permission.input))
        self.permission = nil
        onInput(Self.returnKey)
    }

    /// Allows it and saves Claude Code's suggested rule, so it is not asked again.
    public func alwaysAllow() {
        guard let permission else { return }
        stream?.answer(
            ClaudeInput.allow(request: permission.id, input: permission.input, permissions: permission.rules))
        self.permission = nil
        onInput(Self.returnKey)
    }

    /// Denies the open prompt and stops the turn, as Esc does in the TUI.
    public func deny() {
        guard let permission else { return }
        stream?.answer(
            ClaudeInput.deny(
                request: permission.id, message: "The user doesn't want to proceed with this tool use.",
                interrupt: true))
        self.permission = nil
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
        flush?.cancel()
        let stream = stream
        self.stream = nil
        stream?.stop()
        if stream != nil { onEnded() }
        isWorking = false
        permission = nil
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
            queued = []
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
            interrupting = false
            runningCommands = []
            if let window = result.contextWindow { contextWindow = window }
            if result.isError, result.kind != "error_during_execution", let text = result.text, !text.isEmpty {
                builder.addNotice(text)
            }
            permission = nil
            activity = .idle
            if queued.isEmpty {
                isWorking = false
                lastTurn = turnStarted.map { Date().timeIntervalSince($0) }
            }
        case .rateLimit(let allowed, let resetsAt):
            rateLimitedUntil = allowed ? nil : resetsAt
        case .toolRequest(let request):
            received(request)
        case .taskStarted(_, let toolUse?, false):
            runningCommands.insert(toolUse)
        case .taskEnded(_, let toolUse?, _):
            runningCommands.remove(toolUse)
        case .taskStarted, .taskEnded, .unknownRequest, .controlResponse:
            break
        }
    }

    private func received(_ message: ClaudeMessage) {
        // A subagent's own messages fold under its call, which comes with a later milestone.
        guard message.parentToolUse == nil else { return }
        if message.role == "assistant" {
            endStreaming()
            if let tokens = message.contextTokens { contextTokens = tokens }
        }
        if message.isReplay { taken(message.line) }
        builder.add(line: message.line)
    }

    /// Claude Code echoes the messages it takes, and messages that queued up during a turn come back as one.
    private func taken(_ line: Data) {
        guard !queued.isEmpty else { return }
        let blocks = TranscriptParser.Record(line: line)?.blocks ?? []
        let texts = blocks.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var matched = false
        for text in texts {
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
        switch request.tool {
        case "AskUserQuestion":
            stream?.answer(
                ClaudeInput.deny(
                    request: request.id,
                    message: "This chat cannot show questions yet. Ask the question in plain text instead."))
        case "ExitPlanMode":
            stream?.answer(
                ClaudeInput.deny(
                    request: request.id,
                    message: "This chat cannot show plans yet. Write the plan as text and ask the author to approve it."
                ))
        default:
            permission = ChatPermission(request)
        }
    }

    private func exited(_ code: Int32, _ errors: [String]) {
        stream = nil
        flush?.cancel()
        endStreaming()
        if failure == nil { failure = .exited(code: code, errors: errors) }
        isWorking = false
        activity = .idle
        permission = nil
        queued = []
        runningCommands = []
        interrupting = false
        onEnded()
    }

    /// Draws the new text now if the last draw was at least `streamingInterval` ago, or else once it is.
    private func publishStreamingSoon() {
        let now = ContinuousClock.now
        guard let last = streamingPublishes.last, now - last < Self.streamingInterval else {
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
        streamingPublishes.append(.now)
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
