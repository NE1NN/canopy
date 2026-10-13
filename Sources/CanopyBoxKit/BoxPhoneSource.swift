import CanopyAgents
import CanopyServer
import CanopyWire
import Foundation

/// The phone server's view of canopy-box: its rows and agents from the snapshot, and its panes through tmux, with the
/// rules the Mac's phone server follows for replies and answers.
public final class BoxPhoneSource: PhoneSource {
    let daemon: BoxDaemon
    private let subscriptions = Subscriptions()

    public init(daemon: BoxDaemon) {
        self.daemon = daemon
    }

    static let promptGone = ControlError(
        code: "prompt_gone", message: "That prompt is no longer open: it was answered, or the agent moved on.")
    static let promptOpen = ControlError(
        code: "prompt_open",
        message: "The agent is showing a dialog, which a reply's Return would answer. Answer the dialog first.")
    static let agentNotRunning = ControlError(
        code: "agent_not_running",
        message: "Claude Code is not running in this pane, so a reply would go to whatever is. Use the Terminal tab.")
    static let noTranscript = ControlError(
        code: "no_transcript", message: "This pane has no Claude Code conversation. Its terminal shows what it does.")
    /// How long a reply waits to be taken before it no longer counts as delivered.
    static let deliveryWindow = Duration.seconds(10 * 60)

    static func inbox(_ snapshot: BoxSnapshot) -> PhoneInbox {
        PhoneInbox(rows: phoneRows(snapshot))
    }

    static func phoneRows(_ snapshot: BoxSnapshot) -> [PhoneRow] {
        snapshot.rows.map { row in
            PhoneRow(
                path: row.path, name: row.branch ?? (row.path as NSString).lastPathComponent, repo: row.repo,
                isMain: row.isMain,
                agents: snapshot.panes.filter { $0.rowPath == row.path }.map { pane in
                    PhoneAgent(
                        pane: pane.id, state: pane.agent, unseen: pane.unseen, since: pane.since,
                        lastLine: pane.lastLine,
                        backgroundTasks: pane.backgroundTasks.isEmpty ? nil : pane.backgroundTasks,
                        prompt: pane.prompt, hasTranscript: pane.transcriptPath != nil)
                })
        }
    }

    public func inbox() async -> PhoneInbox {
        Self.inbox(await daemon.snapshot())
    }

    public func rows() async -> PhoneRowsResult {
        let rows = Self.phoneRows(await daemon.snapshot())
        var names: [String] = []
        for row in rows where !names.contains(row.repo ?? "") { names.append(row.repo ?? "") }
        return PhoneRowsResult(
            sections: names.map { name in
                PhoneRowsResult.Section(
                    name: name, isPlugin: false,
                    rows: rows.filter { $0.repo == name }.sorted { $0.isMain && !$1.isMain })
            })
    }

    public func subscribe(
        after lastSent: PhoneInbox, replacing previous: UUID?, _ send: @escaping @Sendable (PhoneInbox) -> Void
    ) async -> UUID {
        if let previous { await subscriptions.cancel(previous) }
        let id = UUID()
        let daemon = daemon
        let task = Task {
            var last = lastSent
            for await snapshot in await daemon.changes() {
                let inbox = Self.inbox(snapshot)
                if inbox != last {
                    last = inbox
                    send(inbox)
                }
            }
        }
        await subscriptions.add(id, task)
        return id
    }

    public func unsubscribe(_ id: UUID) async {
        await subscriptions.cancel(id)
    }

    public func transcriptURL(_ pane: String) async throws -> URL {
        guard let agent = await daemon.agent(of: pane) else { throw BoxErrors.paneNotFound(pane) }
        guard let path = agent.transcriptPath else { throw Self.noTranscript }
        return URL(fileURLWithPath: path)
    }

    /// Pastes the reply, then Return once the paste is read, unless a dialog opened meanwhile, which Return would
    /// answer. `delivered` runs once the agent takes it as its next prompt.
    public func reply(_ params: PhoneReplyParams, delivered: @escaping @Sendable () -> Void) async throws {
        guard let agent = await daemon.agent(of: params.pane) else { throw BoxErrors.paneNotFound(params.pane) }
        guard agent.session != nil else { throw Self.agentNotRunning }
        guard !Self.showsDialog(agent) else { throw Self.promptOpen }
        let sent = Date()
        try await daemon.paste(pane: params.pane, text: params.text)
        try await Task.sleep(for: BoxDaemon.returnPause)
        guard let now = await daemon.agent(of: params.pane), now.session != nil, !Self.showsDialog(now) else {
            throw Self.promptOpen
        }
        try await daemon.send(pane: params.pane, text: "", enter: true)
        let daemon = daemon
        let pane = params.pane
        Task {
            let deadline = ContinuousClock.now + Self.deliveryWindow
            for await snapshot in await daemon.changes() {
                guard ContinuousClock.now < deadline,
                    let shown = snapshot.panes.first(where: { $0.id == pane }), shown.agent != .none
                else { return }
                if shown.agent == .working, shown.since >= sent.timeIntervalSince1970 {
                    delivered()
                    return
                }
            }
        }
    }

    static func showsDialog(_ agent: PaneAgent) -> Bool {
        agent.state == .waiting && !agent.waitsOnQuestion
    }

    public func answer(_ params: PhoneAnswerParams) async throws {
        guard let agent = await daemon.agent(of: params.pane) else { throw BoxErrors.paneNotFound(params.pane) }
        guard let prompt = agent.prompt, prompt.id == params.prompt else { throw Self.promptGone }
        let keys = try PhoneAnswerKeys.keys(for: prompt, params.answer)
        guard await daemon.takeAnswer(pane: params.pane, promptID: prompt.id) != nil else { throw Self.promptGone }
        try await daemon.keys(BoxKeysParams(pane: params.pane, keys: keys))
    }

    public func keys(_ params: PhoneKeysParams) async throws {
        try await daemon.keys(BoxKeysParams(pane: params.pane, keys: [params.text]))
    }

    public func seen(_ params: PhonePaneParams) async throws {
        try await daemon.seen(pane: params.pane)
    }

    public func screen(_ params: PhonePaneParams, scrollback: Int?) async throws -> PhoneScreen {
        try await daemon.screen(pane: params.pane, scrollback: scrollback)
    }

    private actor Subscriptions {
        var tasks: [UUID: Task<Void, Never>] = [:]

        func add(_ id: UUID, _ task: Task<Void, Never>) {
            tasks[id] = task
        }

        func cancel(_ id: UUID) {
            tasks.removeValue(forKey: id)?.cancel()
        }
    }
}
