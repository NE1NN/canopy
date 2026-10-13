import Foundation

/// Shows upgraded hosts' panes and agents as canopy-box reports them: a tab for each pane of its rows the Mac has no
/// terminal for, and each pane's agent on its terminal. Keys typed at the Mac that move an agent go back to the box,
/// so its key rules see them too.
@MainActor
public final class BoxMirror {
    let workspace: Workspace
    let terminals: TerminalStore
    /// Panes closed at the Mac, by session, until a snapshot taken after the box closed them comes.
    private var closed: [String: Date] = [:]
    private var watching: Task<Void, Never>?
    private var observer: UUID?

    /// How long a pane closed at the Mac is kept from coming back as a tab.
    static let closedFor: TimeInterval = 10

    public init(workspace: Workspace, terminals: TerminalStore) {
        self.workspace = workspace
        self.terminals = terminals
    }

    public func start() {
        guard watching == nil else { return }
        let workspace = workspace
        watching = Task { [weak self] in
            for await update in await workspace.boxUpdates() {
                await self?.apply(update)
            }
        }
        observer = terminals.observeAgents { [weak self] event in
            guard case .changed(let pane, let change) = event, change.via == "key" else { return }
            self?.typed(change, in: pane)
        }
    }

    public func stop() {
        watching?.cancel()
        watching = nil
        if let observer { terminals.stopObservingAgents(observer) }
        observer = nil
    }

    /// The author closed a pane at the Mac, so a snapshot from before the box closed it does not reopen it.
    func closedAtTheMac(_ session: String, host: String) {
        closed[host + "/" + session] = Date()
    }

    func apply(_ update: BoxUpdate) async {
        for standIn in update.goneRows { terminals.closeRowQuietly(path: standIn) }
        let now = Date()
        closed = closed.filter { now.timeIntervalSince($0.value) < Self.closedFor }
        let panes = terminals.panes.filter { $0.context.remote?.host == update.host }
        for boxPane in update.snapshot.panes {
            if let pane = panes.first(where: { $0.remoteSession == boxPane.id }) {
                pane.mirror(PaneAgent(mirroring: boxPane))
                continue
            }
            guard closed[update.host + "/" + boxPane.id] == nil,
                let entry = await workspace.remoteRow(host: update.host, path: boxPane.rowPath),
                let repo = await workspace.state.repos.first(where: {
                    $0.remote.contains { $0.standIn == entry.standIn }
                })
            else { continue }
            // Another apply may have opened it while this one waited on the workspace.
            if terminals.panes.contains(where: {
                $0.context.remote?.host == update.host && $0.remoteSession == boxPane.id
            }) {
                continue
            }
            let row = Row(remote: entry, repoPath: repo.path)
            let context = PaneContext(row: row, repoName: await workspace.repoName(repo.path))
            let opened = terminals.openTab(for: context, select: false, session: boxPane.id)
            opened.pane.mirror(PaneAgent(mirroring: boxPane))
        }
    }

    /// Escape or Control-C that cleared an agent, or Return that answered it, at the Mac.
    private func typed(_ change: AgentChange, in pane: Pane) {
        guard let host = pane.context.remote?.host, let session = pane.remoteSession else { return }
        let key: String? =
            switch change.to {
            case .none: "\u{1b}"
            case .working: "\r"
            default: nil
            }
        guard let key else { return }
        let workspace = workspace
        Task {
            guard let link = await workspace.boxLink(for: host) else { return }
            let _: Bool? = try? await link.call(BoxMethod.typed, BoxKeysParams(pane: session, keys: [key]))
        }
    }
}
