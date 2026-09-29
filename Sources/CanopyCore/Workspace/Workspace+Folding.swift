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
    public func revealRow(path: String) throws {
        for fold in snapshot.folds(hiding: path) {
            switch fold {
            case .repo(let repoPath):
                try setRepoCollapsed(repoPath: repoPath, collapsed: false)
            case .group(let repoPath, let name):
                try setGroupCollapsed(repoPath: repoPath, name: name, collapsed: false)
            case .plugin(let id):
                try setPluginCollapsed(id, collapsed: false)
            }
        }
    }
}
