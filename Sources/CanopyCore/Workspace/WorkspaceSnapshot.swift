public struct RepoSnapshot: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    /// The main row first, then Canopy and adopted rows in saved order.
    public var rows: [Row]
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
        external: [Row] = [],
        isMissing: Bool = false,
        error: String? = nil
    ) {
        self.path = path
        self.name = name
        self.rows = rows
        self.external = external
        self.isMissing = isMissing
        self.error = error
    }

    public var allRows: [Row] { rows + external }
}

public struct WorkspaceSnapshot: Sendable, Equatable {
    public var repos: [RepoSnapshot]
    public var selectedRowPath: String?

    public init(repos: [RepoSnapshot] = [], selectedRowPath: String? = nil) {
        self.repos = repos
        self.selectedRowPath = selectedRowPath
    }

    /// Rows that get ⌘1 to ⌘9, in sidebar order. External rows are excluded.
    public var visibleRows: [Row] { repos.flatMap(\.rows) }

    public func row(path: String) -> Row? {
        repos.lazy.flatMap(\.allRows).first { $0.path == path }
    }

    public func repo(path: String) -> RepoSnapshot? {
        repos.first { $0.path == path }
    }
}
