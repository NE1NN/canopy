public enum ControlMethod {
    public static let status = "status"
    public static let repoAdd = "repo.add"
    public static let repoList = "repo.list"
    public static let repoRemove = "repo.remove"
    public static let rowList = "row.list"
    public static let rowNew = "row.new"
    public static let rowRemove = "row.remove"
    public static let rowSelect = "row.select"
    public static let rowAdopt = "row.adopt"
}

/// What the CLI knows about where it runs. The app resolves it against registered repos.
public struct TargetHint: Codable, Sendable, Equatable {
    /// `--repo`: a repo display name or path.
    public var repo: String?
    /// A row argument: a branch name or a path.
    public var row: String?
    /// CANOPY_REPO from the environment.
    public var envRepo: String?
    /// CANOPY_ROW_PATH from the environment.
    public var envRowPath: String?
    public var cwd: String?

    public init(
        repo: String? = nil,
        row: String? = nil,
        envRepo: String? = nil,
        envRowPath: String? = nil,
        cwd: String? = nil
    ) {
        self.repo = repo
        self.row = row
        self.envRepo = envRepo
        self.envRowPath = envRowPath
        self.cwd = cwd
    }
}

public struct StatusResult: Codable, Sendable, Equatable {
    public var version: String
    public var home: String
    public var pid: Int32
}

public struct RepoInfo: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var rows: Int
    public var external: Int
    public var missing: Bool

    public init(_ repo: RepoSnapshot) {
        name = repo.name
        path = repo.path
        rows = repo.rows.count
        external = repo.external.count
        missing = repo.isMissing
    }
}

public struct RepoAddParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct RepoRemoveParams: Codable, Sendable {
    /// A repo display name or path.
    public var repo: String

    public init(repo: String) {
        self.repo = repo
    }
}

public struct RowListParams: Codable, Sendable {
    /// Limits the list to one repo. Lists every repo when nil.
    public var repo: String?
    /// Includes external worktrees.
    public var all: Bool

    public init(repo: String?, all: Bool) {
        self.repo = repo
        self.all = all
    }
}

public struct RowNewParams: Codable, Sendable {
    public var target: TargetHint
    public var branch: String
    public var base: String?
    public var select: Bool

    public init(target: TargetHint, branch: String, base: String?, select: Bool) {
        self.target = target
        self.branch = branch
        self.base = base
        self.select = select
    }
}

public struct RowNewResult: Codable, Sendable {
    public var row: Row
    public var warnings: [String]
}

public struct RowRefParams: Codable, Sendable {
    public var target: TargetHint

    public init(target: TargetHint) {
        self.target = target
    }
}

public struct RowRemoveParams: Codable, Sendable {
    public var target: TargetHint
    public var force: Bool
    public var deleteBranch: Bool

    public init(target: TargetHint, force: Bool, deleteBranch: Bool) {
        self.target = target
        self.force = force
        self.deleteBranch = deleteBranch
    }
}

public struct RowAdoptParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}
