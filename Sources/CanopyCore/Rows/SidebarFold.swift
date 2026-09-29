/// A header the sidebar folds, hiding the rows under it.
public enum SidebarFold: Sendable, Equatable {
    /// A repo, by path.
    case repo(String)
    case group(repoPath: String, name: String)
    /// A plugin's section, by the plugin's id.
    case plugin(String)
}

extension WorkspaceSnapshot {
    /// The folded headers hiding a row, outermost first: its repo, then its group, or its plugin's section. Empty for
    /// a row the sidebar shows, and for one it does not have.
    public func folds(hiding path: String) -> [SidebarFold] {
        if let row = row(path: path), let repo = repo(path: row.repoPath) {
            var folds: [SidebarFold] = repo.collapsed ? [.repo(repo.path)] : []
            if let group = row.group, repo.groups.contains(where: { $0.name == group && $0.collapsed }) {
                folds.append(.group(repoPath: repo.path, name: group))
            }
            return folds
        }
        if let row = pluginRow(path: path), section(row.plugin)?.collapsed == true {
            return [.plugin(row.plugin)]
        }
        return []
    }
}
