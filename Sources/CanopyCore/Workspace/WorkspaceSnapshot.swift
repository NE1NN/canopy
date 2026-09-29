public struct GroupSnapshot: Sendable, Equatable, Identifiable {
    public var name: String
    public var collapsed: Bool

    public init(name: String, collapsed: Bool) {
        self.name = name
        self.collapsed = collapsed
    }

    public var id: String { GroupName.key(name) }
}

public struct RepoSnapshot: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    /// The main row, then the Canopy and adopted rows in sidebar order: the ungrouped ones, then each group's.
    public var rows: [Row]
    /// The repo's groups in sidebar order, empty ones included. Each row names its group.
    public var groups: [GroupSnapshot]
    /// Worktrees made by other tools, shown collapsed.
    public var external: [Row]
    public var isMissing: Bool
    public var error: String?
    /// Why PR badges are hidden or stale, with the fix, such as running `gh auth login`.
    public var pullRequestWarning: String?
    /// Whether the sidebar folds the repo under its header, hiding all its rows.
    public var collapsed: Bool

    public var id: String { path }

    public init(
        path: String,
        name: String,
        rows: [Row] = [],
        groups: [GroupSnapshot] = [],
        external: [Row] = [],
        isMissing: Bool = false,
        error: String? = nil,
        collapsed: Bool = false
    ) {
        self.path = path
        self.name = name
        self.rows = rows
        self.groups = groups
        self.external = external
        self.isMissing = isMissing
        self.error = error
        self.collapsed = collapsed
    }

    public var allRows: [Row] { rows + external }

    public func rows(inGroup name: String) -> [Row] {
        rows.filter { $0.group == name }
    }

    /// The rows the sidebar shows: none while the repo is folded, and otherwise all but those in collapsed groups and
    /// other tools' worktrees.
    public var visibleRows: [Row] {
        guard !collapsed else { return [] }
        let collapsed = Set(groups.filter(\.collapsed).map(\.name))
        return rows.filter { $0.group.map { !collapsed.contains($0) } ?? true }
    }

    /// The same rows in sidebar order for `entry`: the main row, the ungrouped rows, then each group's rows, each
    /// row naming its group. A row the entry does not place yet stays among the ungrouped rows.
    public func arranged(by entry: RepoEntry) -> RepoSnapshot {
        var unplaced = Dictionary(
            rows.filter { $0.rowClass != .main }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        func take(_ path: String, into group: String?) -> Row? {
            guard var row = unplaced.removeValue(forKey: path) else { return nil }
            row.group = group
            return row
        }
        var ordered = rows.filter { $0.rowClass == .main }
        ordered += entry.rowOrder.compactMap { take($0, into: nil) }
        let grouped = entry.groups.flatMap { group in group.rows.compactMap { take($0, into: group.name) } }
        ordered += rows.compactMap { take($0.path, into: nil) }
        var arranged = self
        arranged.rows = ordered + grouped
        arranged.groups = entry.groups.map { GroupSnapshot(name: $0.name, collapsed: $0.collapsed) }
        return arranged
    }
}

public struct WorkspaceSnapshot: Sendable, Equatable {
    public var repos: [RepoSnapshot]
    /// Every built-in plugin's section in built-in order, on or off.
    public var plugins: [PluginSection]
    public var selectedRowPath: String?

    public init(repos: [RepoSnapshot] = [], plugins: [PluginSection] = [], selectedRowPath: String? = nil) {
        self.repos = repos
        self.plugins = plugins
        self.selectedRowPath = selectedRowPath
    }

    /// The sections the sidebar shows.
    public var activePlugins: [PluginSection] { plugins.filter(\.isOn) }

    /// Rows that get ⌘1 to ⌘9, in sidebar order: the rows of every repo that is not folded, but those in collapsed
    /// groups and external ones, then the rows of each plugin that is on and not folded.
    public var visibleRows: [SidebarRow] {
        repos.flatMap(\.visibleRows).map(SidebarRow.worktree)
            + activePlugins.filter { !$0.collapsed }.flatMap(\.rows).map(SidebarRow.plugin)
    }

    /// The row `↑` or `↓` picks. From a row hidden in a folded repo, group, or plugin section, the next visible row
    /// after the fold or the last before it, and nil if there is none. From no row, or one the sidebar does not step
    /// through, the first or the last.
    public func steppingRow(from path: String?, offset: Int) -> SidebarRow? {
        let visible = visibleRows
        guard !visible.isEmpty else { return nil }
        let all = repos.flatMap(\.rows).map(SidebarRow.worktree) + pluginRows
        guard let path, let position = all.firstIndex(where: { $0.path == path }) else {
            return offset > 0 ? visible.first : visible.last
        }
        if let index = visible.firstIndex(where: { $0.path == path }) {
            return visible[min(max(index + offset, 0), visible.count - 1)]
        }
        let shown = Set(visible.map(\.path))
        if offset > 0 {
            let after = all[(position + 1)...].filter { shown.contains($0.path) }
            return after.isEmpty ? nil : after[min(offset - 1, after.count - 1)]
        }
        let before = all[..<position].filter { shown.contains($0.path) }
        return before.isEmpty ? nil : before[max(before.count + offset, 0)]
    }

    /// A worktree row, other tools' included.
    public func row(path: String) -> Row? {
        repos.lazy.flatMap(\.allRows).first { $0.path == path }
    }

    /// A worktree row, or a row of a plugin that is on.
    public func sidebarRow(path: String) -> SidebarRow? {
        row(path: path).map(SidebarRow.worktree) ?? pluginRow(path: path).map(SidebarRow.plugin)
    }

    /// A row of a plugin that is on.
    public func pluginRow(path: String) -> PluginRow? {
        activePlugins.lazy.flatMap(\.rows).first { $0.path == path }
    }

    /// The row a plugin that is on has for one of its items.
    public func pluginRow(plugin: String, item: String) -> PluginRow? {
        activePlugins.first { $0.id == plugin }?.rows.first { $0.item == item }
    }

    /// The worktree rows made for one of a plugin's items, in sidebar order.
    public func linkedRows(plugin: String, item: String) -> [Row] {
        let link = PluginLink(plugin: plugin, item: item)
        return repos.flatMap(\.allRows).filter { $0.link == link }
    }

    public func section(_ plugin: String) -> PluginSection? {
        plugins.first { $0.id == plugin }
    }

    public func repo(path: String) -> RepoSnapshot? {
        repos.first { $0.path == path }
    }

    private var pluginRows: [SidebarRow] {
        activePlugins.flatMap(\.rows).map(SidebarRow.plugin)
    }
}
