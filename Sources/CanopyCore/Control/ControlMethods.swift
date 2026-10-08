import Foundation

public enum ControlMethod {
    public static let status = "status"
    public static let repoAdd = "repo.add"
    public static let repoList = "repo.list"
    public static let repoRemove = "repo.remove"
    public static let repoClone = "repo.clone"
    public static let repoCollapse = "repo.collapse"
    public static let repoExpand = "repo.expand"
    public static let rowList = "row.list"
    public static let rowNew = "row.new"
    public static let rowRemove = "row.remove"
    public static let rowSelect = "row.select"
    public static let rowAdopt = "row.adopt"
    public static let rowMove = "row.move"
    public static let prShow = "pr.show"
    public static let prList = "pr.list"
    public static let branchList = "branch.list"

    /// Methods that only read, which the activity log leaves out: agents poll some of them every few seconds.
    public static let readOnly: Set<String> = [
        status, repoList, rowList, prShow, prList, branchList, TermMethod.list, TermMethod.read, TermMethod.wait,
        PortMethod.list, GroupMethod.list, PluginMethod.list, PluginMethod.items, WebMethod.list,
    ]

    /// Methods left out of `cli.call`: the read-only ones, and `term.state`, which hooks send on every tool call and
    /// which records its own `agent.*` events.
    public static let notLogged = readOnly.union([TermMethod.state])

    /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo, so they
    /// can take minutes. Creating and removing rows also wait for setup or teardown, which can run for as long as
    /// a build does and cannot be cancelled, so the CLI waits for them without a limit, and so does a clone, which
    /// takes as long as the repo is big. A PR lookup can queue behind one already asking GitHub, and each may take
    /// 30 seconds. Listing branches fetches in the repo's git queue. `term.wait` has its own timeout, which the CLI
    /// waits out. Other reads answer from memory.
    /// A plugin's new row waits for its plugin to fill the folder, which may take the network, then for `run`. Listing a
    /// plugin's items and starting one may reach the network too.
    public static func replyTimeout(for method: String) -> TimeInterval? {
        if [rowNew, rowRemove, repoClone, PluginMethod.new].contains(method) { return nil }
        if [prShow, prList, PluginMethod.items, PluginMethod.enable].contains(method) { return 90 }
        if method == TermMethod.wait { return nil }
        return [repoAdd, repoRemove, rowAdopt, branchList].contains(method) ? 900 : 30
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
    /// Whether the sidebar folds the repo.
    public var collapsed: Bool

    public init(_ repo: RepoSnapshot) {
        name = repo.name
        path = repo.path
        rows = repo.rows.count
        external = repo.external.count
        missing = repo.isMissing
        collapsed = repo.collapsed
    }
}

/// The repo `repo.collapse` or `repo.expand` folds, resolved the usual way.
public struct RepoFoldParams: Codable, Sendable {
    public var target: TargetHint

    public init(target: TargetHint = TargetHint()) {
        self.target = target
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
    }
}

public struct RepoAddParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct RepoCloneParams: Codable, Sendable {
    /// `owner/repo`, or a URL git can clone.
    public var source: String
    /// An absolute path to clone into. CANOPY_HOME/repos/<owner>/<name> when nil.
    public var into: String?

    public init(source: String, into: String? = nil) {
        self.source = source
        self.into = into
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
    /// The branch to check out or create. With `pr`, the local name for the PR's branch.
    public var branch: String?
    /// A pull request to start from: its number, `#number`, or URL. JSON may send the number as a number.
    public var pr: String?
    public var base: String?
    /// Fails with branch_not_found rather than create a branch that is neither local nor on origin.
    public var existing: Bool
    public var select: Bool
    /// Runs the repo's setup commands. Off with `--no-setup`.
    public var setup: Bool
    /// A command to type into a new terminal once setup succeeds.
    public var run: String?
    /// A group of the repo to put the row in, which must exist.
    public var group: String?
    /// A plugin's item to tie the row to, such as the ticket it fixes.
    public var link: RowLinkParams?

    public init(
        target: TargetHint = TargetHint(), branch: String? = nil, pr: String? = nil, base: String? = nil,
        existing: Bool = false, select: Bool = false, setup: Bool = true, run: String? = nil, group: String? = nil,
        link: RowLinkParams? = nil
    ) {
        self.target = target
        self.branch = branch
        self.pr = pr
        self.base = base
        self.existing = existing
        self.select = select
        self.setup = setup
        self.run = run
        self.group = group
        self.link = link
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        if let number = try? container.decodeIfPresent(Int.self, forKey: .pr) {
            pr = String(number)
        } else {
            pr = try container.decodeIfPresent(String.self, forKey: .pr)
        }
        base = try container.decodeIfPresent(String.self, forKey: .base)
        existing = try container.decodeIfPresent(Bool.self, forKey: .existing) ?? false
        select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
        setup = try container.decodeIfPresent(Bool.self, forKey: .setup) ?? true
        run = try container.decodeIfPresent(String.self, forKey: .run)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        link = try container.decodeIfPresent(RowLinkParams.self, forKey: .link)
    }
}

public struct RowNewResult: Codable, Sendable {
    public var row: Row
    public var source: BranchSource
    /// Where a new branch started, such as origin/main.
    public var base: String?
    /// The pull request the row was started from.
    public var pr: PullRequest?
    /// What Canopy did along the way, such as fast-forwarding the branch.
    public var notes: [String]
    /// What may need fixing, such as a branch that has diverged from origin.
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

public struct RowRemoveResult: Codable, Sendable {
    public var row: SidebarRow
    /// Things that went wrong after the row was already gone, such as a branch that could not be deleted.
    public var warnings: [String]
    /// Where a plugin row's folder went in the Trash.
    public var trashedTo: String?

    public init(row: SidebarRow, warnings: [String] = [], trashedTo: String? = nil) {
        self.row = row
        self.warnings = warnings
        self.trashedTo = trashedTo
    }
}

public struct RowAdoptParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct PRShowParams: Codable, Sendable {
    public var target: TargetHint
    /// Asks GitHub now instead of answering with the last lookup.
    public var refresh: Bool

    public init(target: TargetHint = TargetHint(), refresh: Bool = false) {
        self.target = target
        self.refresh = refresh
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        refresh = try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
    }
}

public struct PRShowResult: Codable, Sendable {
    public var repo: String
    public var branch: String
    public var path: String
    /// Nil when the branch has no PR.
    public var pr: PullRequest?

    /// Writes `"pr": null` rather than leaving the key out, so "no PR" reads plainly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repo, forKey: .repo)
        try container.encode(branch, forKey: .branch)
        try container.encode(path, forKey: .path)
        try container.encode(pr, forKey: .pr)
    }
}

public struct PRListParams: Codable, Sendable {
    public var target: TargetHint
    /// Keeps the PRs whose number, title, head branch, or author holds each word. A PR number, `#number`, or URL looks
    /// that PR up in any state.
    public var query: String?
    /// Lists closed and merged PRs too.
    public var closed: Bool

    public init(target: TargetHint = TargetHint(), query: String? = nil, closed: Bool = false) {
        self.target = target
        self.query = query
        self.closed = closed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        query = try container.decodeIfPresent(String.self, forKey: .query)
        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }
}

public struct BranchListParams: Codable, Sendable {
    public var target: TargetHint
    /// Keeps the branches whose name holds each word.
    public var query: String?
    /// Fetches origin first. Off to list only what the repo already has.
    public var fetch: Bool

    public init(target: TargetHint = TargetHint(), query: String? = nil, fetch: Bool = true) {
        self.target = target
        self.query = query
        self.fetch = fetch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        query = try container.decodeIfPresent(String.self, forKey: .query)
        fetch = try container.decodeIfPresent(Bool.self, forKey: .fetch) ?? true
    }
}
