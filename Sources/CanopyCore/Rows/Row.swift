public enum RowClass: String, Sendable, Codable {
    case main
    case canopy
    case adopted
    case external
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

    public var id: String { path }

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
    }
}
