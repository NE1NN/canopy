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

    public var id: String { path }

    public init(
        path: String,
        name: String,
        rows: [Row] = [],
        groups: [GroupSnapshot] = [],
        external: [Row] = [],
        isMissing: Bool = false,
        error: String? = nil
    ) {
        self.path = path
        self.name = name
        self.rows = rows
        self.groups = groups
        self.external = external
        self.isMissing = isMissing
        self.error = error
    }

    public var allRows: [Row] { rows + external }

    public func rows(inGroup name: String) -> [Row] {
        rows.filter { $0.group == name }
    }

    /// The rows the sidebar shows: all but those in collapsed groups and other tools' worktrees.
    public var visibleRows: [Row] {
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
    public var selectedRowPath: String?

    public init(repos: [RepoSnapshot] = [], selectedRowPath: String? = nil) {
        self.repos = repos
        self.selectedRowPath = selectedRowPath
    }

    /// Rows that get ⌘1 to ⌘9, in sidebar order. Rows in collapsed groups and external rows are excluded.
    public var visibleRows: [Row] { repos.flatMap(\.visibleRows) }

    /// The row `↑` or `↓` picks. From a row hidden in a collapsed group, the next visible row after the group or the
    /// last before it, and nil if there is none. From no row, or one the sidebar does not step through, the first
    /// or the last.
    public func steppingRow(from path: String?, offset: Int) -> Row? {
        let visible = visibleRows
        guard !visible.isEmpty else { return nil }
        let all = repos.flatMap(\.rows)
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

    public func row(path: String) -> Row? {
        repos.lazy.flatMap(\.allRows).first { $0.path == path }
    }

    public func repo(path: String) -> RepoSnapshot? {
        repos.first { $0.path == path }
    }
}
