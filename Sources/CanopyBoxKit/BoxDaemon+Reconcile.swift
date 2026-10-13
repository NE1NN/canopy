import CanopyAgents
import CanopyGit
import CanopySystem
import CanopyWire
import Foundation

extension BoxDaemon {
    /// Brings the rows in line with each repo's `git worktree list` and the panes with the tmux server's sessions.
    /// A worktree under the repo's worktrees folder that it does not know becomes a row, a saved row git no longer
    /// lists is missing, a session it does not know becomes a pane of the row whose folder holds it, and a saved pane
    /// whose session is gone goes.
    func reconcile() async {
        await reconcileRows()
        await reconcilePanes()
    }

    private func reconcileRows() async {
        guard let config else {
            mainRows = [:]
            return
        }
        var mains: [String: StoredRow] = [:]
        // Rows made while git lists are not in its listing, so only rows from before it can be missing.
        let known = Set(state.rows.map(\.path))
        for (repo, clonePath) in config.repos {
            let clone = Paths.canonical(clonePath)
            guard let listed = try? await git(clone).run(["worktree", "list", "--porcelain", "-z"]) else {
                // A clone git cannot read is still the repo's main row, shown missing until it can.
                mains[repo] = StoredRow(path: clone, repo: repo, missing: true)
                continue
            }
            let worktrees = WorktreeListParser.parse(listed)
            let main = worktrees.first
            mains[repo] = StoredRow(path: clone, repo: repo, branch: main?.branch, head: main?.head)
            let folder = Paths.canonical(paths.worktrees(repo: repo))
            var seen = Set<String>()
            for worktree in worktrees.dropFirst() where !worktree.isBare {
                let path = Paths.canonical(worktree.path)
                seen.insert(path)
                guard !makingRows.contains(path) else { continue }
                if let index = state.rows.firstIndex(where: { $0.path == path }) {
                    state.rows[index].branch = worktree.branch
                    state.rows[index].head = worktree.head
                    state.rows[index].missing = worktree.isPrunable
                } else if Paths.isInside(path, folder), path != folder {
                    state.rows.append(
                        StoredRow(
                            path: path, repo: repo, branch: worktree.branch, head: worktree.head,
                            missing: worktree.isPrunable))
                }
            }
            for index in state.rows.indices
            where state.rows[index].repo == repo && known.contains(state.rows[index].path)
                && !seen.contains(state.rows[index].path) && !makingRows.contains(state.rows[index].path)
            {
                state.rows[index].missing = true
            }
        }
        mainRows = mains
    }

    private func reconcilePanes() async {
        // Panes made while tmux lists are not in its listing, so only panes from before it can be gone.
        let known = Set(state.panes.map(\.id))
        // A server that cannot be asked says nothing about which sessions run, so the saved panes stay.
        guard let sessions = try? await tmux.panes() else { return }
        let names = Set(sessions.map(\.session))
        state.panes.removeAll { known.contains($0.id) && !names.contains($0.id) && !makingPanes.contains($0.id) }
        for session in sessions
        where !state.panes.contains(where: { $0.id == session.session }) && !makingPanes.contains(session.session) {
            let folder = Paths.canonical(session.start)
            guard let row = row(holding: folder) else { continue }
            state.panes.append(StoredPane(id: session.session, rowPath: row.path, folder: folder, agent: PaneAgent()))
        }
        bumpNextPane()
    }

    /// Keeps the next `b<N>` above every `b<N>` the box has, as after a lost state file.
    func bumpNextPane() {
        let highest = state.panes.compactMap { Self.boxPaneNumber($0.id) }.max() ?? 0
        state.nextPane = max(state.nextPane, highest + 1)
    }

    static func boxPaneNumber(_ id: String) -> Int? {
        guard id.hasPrefix("b") else { return nil }
        return Int(id.dropFirst())
    }
}

extension BoxDaemon {
    /// Takes the rows and panes the Mac had for this host, as it upgrades. A pane whose session the server does not
    /// have is left out and named, and the next pane number goes past the Mac's.
    public func adopt(_ params: BoxAdoptParams) async -> BoxAdoptResult {
        var rows: [String] = []
        for adopted in params.rows {
            let path = Paths.canonical(adopted.path)
            if !allRows.contains(where: { $0.path == path }) {
                state.rows.append(StoredRow(path: path, repo: adopted.repo, branch: adopted.branch))
            }
            rows.append(path)
        }
        await reconcileRows()
        var panes: [String] = []
        var missing: [String] = []
        for adopted in params.panes {
            guard await tmux.hasSession(adopted.id) else {
                missing.append(adopted.id)
                continue
            }
            let pane = StoredPane(
                id: adopted.id, rowPath: Paths.canonical(adopted.rowPath), folder: adopted.folder,
                agent: adopted.agent)
            if let index = state.panes.firstIndex(where: { $0.id == adopted.id }) {
                state.panes[index] = pane
            } else {
                state.panes.append(pane)
            }
            panes.append(adopted.id)
        }
        state.nextPane = max(state.nextPane, params.nextPane)
        changed()
        return BoxAdoptResult(rows: rows, panes: panes, missing: missing)
    }

    /// Hands back every row and pane, as the host goes back to the Mac tracking it, and forgets them. Sessions keep
    /// running.
    public func release() -> BoxReleaseResult {
        let result = BoxReleaseResult(
            rows: state.rows.map { BoxAdoptedRow(repo: $0.repo, path: $0.path, branch: $0.branch) },
            panes: state.panes.map {
                BoxAdoptedPane(id: $0.id, rowPath: $0.rowPath, folder: $0.folder, agent: $0.agent)
            }, nextPane: state.nextPane)
        state.rows = []
        state.panes = []
        activity = [:]
        changed()
        return result
    }
}
