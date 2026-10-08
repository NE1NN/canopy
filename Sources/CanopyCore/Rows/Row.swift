public enum RowClass: String, Sendable, Codable {
    case main
    case canopy
    case adopted
    case external
    /// A worktree on a host, made by Canopy, whose stand-in folder on this Mac is its path.
    case remote
}

public enum ExternalTag: String, Sendable, Codable {
    case superset
    case conductor
    case other

    public var label: String {
        switch self {
        case .superset: "Superset"
        case .conductor: "Conductor"
        case .other: "other"
        }
    }
}

public struct Row: Sendable, Equatable, Identifiable, Codable {
    public var repoPath: String
    public var path: String
    public var branch: String?
    public var head: String?
    public var rowClass: RowClass
    public var externalTag: ExternalTag?
    public var isMissing: Bool
    /// Looked up only for Canopy and adopted rows on a branch.
    public var pullRequest: PullRequest?
    /// The name of the group holding the row, nil while it is ungrouped.
    public var group: String?
    /// The plugin item the row was made for, such as a ticket.
    public var link: PluginLink?
    /// The ssh alias of the host a remote row's worktree is on.
    public var host: String?
    /// A remote row's worktree on its host.
    public var remotePath: String?

    public var id: String { path }

    /// Rows Canopy manages, which can be reordered and grouped. The main row and other tools' worktrees stay put.
    public var isMovable: Bool {
        rowClass == .canopy || rowClass == .adopted || rowClass == .remote
    }

    public var displayName: String {
        if let branch { return branch }
        if let head { return String(head.prefix(7)) }
        return "(unknown)"
    }

    public init(
        repoPath: String,
        path: String,
        branch: String?,
        head: String?,
        rowClass: RowClass,
        externalTag: ExternalTag? = nil,
        isMissing: Bool = false
    ) {
        self.repoPath = repoPath
        self.path = path
        self.branch = branch
        self.head = head
        self.rowClass = rowClass
        self.externalTag = externalTag
        self.isMissing = isMissing
    }

    enum CodingKeys: String, CodingKey {
        case repoPath, path, branch, head
        case rowClass = "class"
        case externalTag = "tag"
        case isMissing = "missing"
        case pullRequest = "pr"
        case group
        case link
        case host
        case remotePath
    }
}
