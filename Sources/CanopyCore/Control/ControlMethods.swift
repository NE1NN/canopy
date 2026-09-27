import Foundation

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

    /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo,
    /// so parallel `row new` calls can take minutes; reads answer from memory.
    public static func replyTimeout(for method: String) -> TimeInterval {
        [repoAdd, repoRemove, rowNew, rowRemove, rowAdopt].contains(method) ? 900 : 30
    }
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
    /// Always true here. The CLI prints `"running": false` itself when it cannot connect.
    public var running = true
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

// Params decode with defaults for everything but what a method cannot do without, so agents can send
// short requests such as {"branch": "fix/x", "run": "claude"}.

public struct RowListParams: Codable, Sendable {
    /// Limits the list to one repo. Lists every repo when nil.
    public var repo: String?
    /// Includes external worktrees.
    public var all: Bool

    public init(repo: String? = nil, all: Bool = false) {
        self.repo = repo
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct RowNewParams: Codable, Sendable {
    public var target: TargetHint
    public var branch: String
    public var base: String?
    public var select: Bool
    /// Runs the repo's setup commands. Off with `--no-setup`.
    public var setup: Bool
    /// A command to type into a new terminal once setup succeeds.
    public var run: String?

    public init(
        target: TargetHint = TargetHint(), branch: String, base: String? = nil, select: Bool = false,
        setup: Bool = true, run: String? = nil
    ) {
        self.target = target
        self.branch = branch
        self.base = base
        self.select = select
        self.setup = setup
        self.run = run
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        branch = try container.decode(String.self, forKey: .branch)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
        setup = try container.decodeIfPresent(Bool.self, forKey: .setup) ?? true
        run = try container.decodeIfPresent(String.self, forKey: .run)
    }
}

public struct RowNewResult: Codable, Sendable {
    public var row: Row
    public var warnings: [String]
    public var setup: SetupReport
    /// The terminal started for `run`, such as "p12".
    public var pane: String?
}

public struct RowRefParams: Codable, Sendable {
    public var target: TargetHint

    public init(target: TargetHint = TargetHint()) {
        self.target = target
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
    }
}

public struct RowRemoveParams: Codable, Sendable {
    public var target: TargetHint
    /// Removes the row even with uncommitted changes or a failing teardown.
    public var force: Bool
    public var deleteBranch: Bool

    public init(target: TargetHint = TargetHint(), force: Bool = false, deleteBranch: Bool = false) {
        self.target = target
        self.force = force
        self.deleteBranch = deleteBranch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        deleteBranch = try container.decodeIfPresent(Bool.self, forKey: .deleteBranch) ?? false
    }
}

public struct RowAdoptParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}
