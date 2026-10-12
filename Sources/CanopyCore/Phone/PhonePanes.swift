import Foundation

/// What a phone does to panes: replies, answers, keys, marking agents seen, and reading screens. On the main actor,
/// where terminals live.
@MainActor
public final class PhonePanes {
    public static let promptGone = ControlError(
        code: "prompt_gone", message: "That prompt is no longer open: it was answered, or the agent moved on.")
    public static let noTranscript = ControlError(
        code: "no_transcript",
        message: "This pane has no Claude Code conversation on this Mac. Its terminal shows what it does.")

    private let terminals: TerminalStore
    /// Replies not yet delivered, oldest first, by pane.
    private var waitingReplies: [PaneID: [@Sendable () -> Void]] = [:]
    private var observer: UUID?

    public init(terminals: TerminalStore) {
        self.terminals = terminals
    }

    public func start() {
        guard observer == nil else { return }
        observer = terminals.observeAgents { [weak self] event in
            switch event {
            case .prompted(let pane):
                guard let self, var waiting = self.waitingReplies[pane.id], !waiting.isEmpty else { return }
                let delivered = waiting.removeFirst()
                self.waitingReplies[pane.id] = waiting.isEmpty ? nil : waiting
                delivered()
            case .closed(let pane):
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

    /// Pastes the reply and presses Return. `delivered` runs when the agent takes it, as its next prompt.
    public func reply(_ params: PhoneReplyParams, delivered: @escaping @Sendable () -> Void = {}) async throws
        -> PhoneReplyResult
    {
        let pane = try running(params.pane)
        let id = UUID().uuidString
        waitingReplies[pane.id, default: []].append(delivered)
        await pane.paste(params.text)
        return PhoneReplyResult(reply: id)
    }

    public func answer(_ params: PhoneAnswerParams) async throws {
        let pane = try running(params.pane)
        guard let prompt = pane.agent.prompt, prompt.id == params.prompt else { throw Self.promptGone }
        let keys = try PhoneAnswerKeys.keys(for: prompt, params.answer)
        guard pane.answerPrompt(id: prompt.id) else { throw Self.promptGone }
        await pane.press(keys)
    }

    public func keys(_ params: PhoneKeysParams) throws {
        let pane = try running(params.pane)
        Task { await pane.press([params.text]) }
    }

    public func seen(_ params: PhonePaneParams) throws {
        _ = try pane(params.pane).markSeen()
    }

    /// The visible screen, with up to `scrollback` lines above it.
    public func screen(_ params: PhonePaneParams, scrollback: Int?) throws -> PhoneScreen {
        let pane = try pane(params.pane)
        let size = pane.emulator.size
        let lines = pane.emulator.styledLines(size.rows + (scrollback ?? 0))
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

    private func running(_ id: String) throws -> Pane {
        let pane = try pane(id)
        guard case .running = pane.status else { throw WorkspaceError.paneExited(id) }
        return pane
    }
}
