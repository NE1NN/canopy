import Foundation

/// Folding is how the sidebar looks, so each fold is saved but not logged. Groups fold in `Workspace+Groups.swift`.
extension Workspace {
    public func setRepoCollapsed(repoPath: String, collapsed: Bool) throws {
        try changeEntry(repoPath: repoPath) { entry, _ in entry.collapsed = collapsed }
    }

    /// A plugin's fold is kept while it is off, like its rows.
    public func setPluginCollapsed(_ id: String, collapsed: Bool) throws {
        guard pluginInfos.contains(where: { $0.id == id }) else { throw WorkspaceError.pluginNotFound(id) }
        guard (state.plugins[id]?.collapsed ?? false) != collapsed else { return }
        state.plugins[id, default: PluginEntry()].collapsed = collapsed
        try save()
        publish()
    }

    /// Unfolds whatever hides a row, its repo and its group or its plugin's section, so selecting the row shows it.
    /// A repo and its group unfold in one change, so the sidebar gets both back in one snapshot.
    public func revealRow(path: String) throws {
        let folds = snapshot.folds(hiding: path)
        if case .plugin(let id) = folds.first {
            return try setPluginCollapsed(id, collapsed: false)
        }
        guard !folds.isEmpty, let row = snapshot.row(path: path) else { return }
        try changeEntry(repoPath: row.repoPath) { entry, repo in
            for fold in folds {
                switch fold {
                case .repo: entry.collapsed = false
                case .group(_, let name): entry.groups[try entry.requireGroup(name, repo: repo)].collapsed = false
                case .plugin: break
                }
            }
        }
    }
}
