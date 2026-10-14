import Foundation

/// What a phone does to panes: replies, answers, keys, marking agents seen, and reading screens. On the main actor,
/// where terminals live.
@MainActor
public final class PhonePanes {
    public nonisolated static let promptGone = ControlError(
        code: "prompt_gone", message: "That prompt is no longer open: it was answered, or the agent moved on.")
    public nonisolated static let promptOpen = ControlError(
        code: "prompt_open",
        message: "The agent is showing a dialog, which a reply's Return would answer. Answer the dialog first.")
    public nonisolated static let agentNotRunning = ControlError(
        code: "agent_not_running",
        message: "Claude Code is not running in this pane, so a reply would go to whatever is. Use the Terminal tab.")
    /// How long a reply waits to be taken before it is forgotten.
    static let deliveryWindow: TimeInterval = 10 * 60
    public nonisolated static let chatWaits = ControlError(
        code: "chat_waiting",
        message: "The chat waits on the Mac, such as for its folder to be trusted. The reply waits in its composer.")
    public nonisolated static let noTranscript = ControlError(
        code: "no_transcript",
        message: "This pane has no Claude Code conversation on this Mac. Its terminal shows what it does.")

    private let terminals: TerminalStore
    /// Replies not yet delivered, oldest first, by pane.
    private var waitingReplies: [PaneID: [(sent: Date, delivered: @Sendable () -> Void)]] = [:]
    private var observer: UUID?

    public init(terminals: TerminalStore) {
        self.terminals = terminals
    }

    public func start() {
        guard observer == nil else { return }
        observer = terminals.observeAgents { [weak self] event in
            switch event {
            case .prompted(let pane):
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-Self.deliveryWindow)
                var waiting = (self.waitingReplies[pane.id] ?? []).filter { $0.sent > cutoff }
                guard !waiting.isEmpty else {
                    self.waitingReplies[pane.id] = nil
                    return
                }
                let reply = waiting.removeFirst()
                self.waitingReplies[pane.id] = waiting.isEmpty ? nil : waiting
                reply.delivered()
            case .closed(let pane):
                self?.waitingReplies[pane.id] = nil
            case .changed(let pane, let change) where change.to == .none:
                // The agent stopped or exited, so a reply it never took will not be its next prompt.
                self?.waitingReplies[pane.id] = nil
            case .changed:
                break
            }
        }
    }

    public func stop() {
        if let observer { terminals.stopObservingAgents(observer) }
        observer = nil
        waitingReplies = [:]
    }

    /// Pastes the reply into Claude Code and presses Return. `delivered` runs when the agent takes it, as its next
    /// prompt. A reply is refused while a dialog is open, and Return is held back if one opens during the paste.
    /// A chat takes it as a message, as its composer does: an open prompt is turned down first.
    public func reply(_ params: PhoneReplyParams, delivered: @escaping @Sendable () -> Void = {}) async throws {
        let pane = try running(params.pane)
        if let chat = pane.chat {
            switch chat.send(params.text, asMessage: true) {
            case .queued: waitingReplies[pane.id, default: []].append((Date(), delivered))
            case .drafted: throw Self.chatWaits
            case .answered, .ranShell, .ignored: break
            }
            return
        }
        let terminal = try Self.terminal(of: pane)
        guard pane.agent.session != nil else { throw Self.agentNotRunning }
        guard !Self.showsDialog(pane) else { throw Self.promptOpen }
        let returned = await terminal.paste(params.text) { pane.agent.session != nil && !Self.showsDialog(pane) }
        guard returned else { throw Self.promptOpen }
        waitingReplies[pane.id, default: []].append((Date(), delivered))
    }

    /// Waiting on a dialog that keys answer, rather than at its own input line after a question.
    private static func showsDialog(_ pane: Pane) -> Bool {
        pane.agent.state == .waiting && !pane.agent.waitsOnQuestion
    }

    public func answer(_ params: PhoneAnswerParams) async throws {
        let pane = try running(params.pane)
        // A chat answers its own open prompt, which the inbox shows by its request ID.
        if let chat = pane.chat {
            guard let prompt = chat.openPrompt, prompt.id == params.prompt else { throw Self.promptGone }
            _ = try PhoneAnswerKeys.keys(for: prompt, params.answer)
            guard chat.answer(prompt: prompt.id, allow: params.answer.allow, options: params.answer.options) else {
                throw Self.promptGone
            }
            return
        }
        guard let prompt = pane.agent.prompt, prompt.id == params.prompt else { throw Self.promptGone }
        let keys = try PhoneAnswerKeys.keys(for: prompt, params.answer)
        let terminal = try Self.terminal(of: pane)
        guard pane.answerPrompt(id: prompt.id) else { throw Self.promptGone }
        await terminal.press(keys)
    }

    public func keys(_ params: PhoneKeysParams) throws {
        let terminal = try Self.terminal(of: running(params.pane))
        Task { await terminal.press([params.text]) }
    }

    public func seen(_ params: PhonePaneParams) throws {
        _ = try pane(params.pane).markSeen()
    }

    /// The visible screen, with up to `scrollback` lines above it.
    public func screen(_ params: PhonePaneParams, scrollback: Int?) throws -> PhoneScreen {
        let emulator = try Self.terminal(of: pane(params.pane)).emulator
        let size = emulator.size
        let lines = emulator.styledLines(size.rows + (scrollback ?? 0))
        let screen = Array(lines.suffix(size.rows))
        return PhoneScreen(
            pane: params.pane, columns: size.columns, rows: size.rows,
            scrollback: scrollback.map { _ in Array(lines.dropLast(screen.count)) }, lines: screen)
    }

    /// The transcript of the pane's Claude Code session. A remote row's lives on its host.
    public func transcriptURL(_ id: String) throws -> URL {
        let pane = try pane(id)
        guard pane.context.remote == nil, let path = pane.agent.transcriptPath else { throw Self.noTranscript }
        return URL(fileURLWithPath: path)
    }

    func pane(_ id: String) throws -> Pane {
        guard let paneID = PaneID(id), let pane = terminals.pane(paneID) else { throw WorkspaceError.paneNotFound(id) }
        return pane
    }

    /// A chat has no screen or keys; it takes replies and answers through its session.
    private static func terminal(of pane: Pane) throws -> TerminalBody {
        guard let terminal = pane.terminal else { throw WorkspaceError.notATerminal(pane.id.description) }
        return terminal
    }

    private func running(_ id: String) throws -> Pane {
        let pane = try pane(id)
        guard case .running = pane.status else { throw WorkspaceError.paneExited(id) }
        return pane
    }
}
