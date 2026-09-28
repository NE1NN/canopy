/// The pull request a branch was started from with `row new --pr`.
public struct PRBinding: Codable, Sendable, Equatable {
    public var number: Int
    /// origin's GitHub repo, as owner/name, when the branch was made. The number means nothing in another repo.
    public var repo: String

    public init(number: Int, repo: String) {
        self.number = number
        self.repo = repo
    }
}

public struct RepoEntry: Codable, Sendable, Equatable {
    public var path: String
    public var dirName: String
    public var adopted: [String]
    /// The ungrouped Canopy and adopted rows, in sidebar order. Grouped rows are in `groups`.
    public var rowOrder: [String]
    public var groups: [RowGroup]
    /// PRs keyed by local branch, for branches whose name cannot find their PR: a fork's, or one checked out under
    /// another name.
    public var prBindings: [String: PRBinding]

    public init(
        path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = [], groups: [RowGroup] = [],
        prBindings: [String: PRBinding] = [:]
    ) {
        self.path = path
        self.dirName = dirName
        self.adopted = adopted
        self.rowOrder = rowOrder
        self.groups = groups
        self.prBindings = prBindings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        dirName = try container.decode(String.self, forKey: .dirName)
        adopted = try container.decodeIfPresent([String].self, forKey: .adopted) ?? []
        rowOrder = try container.decodeIfPresent([String].self, forKey: .rowOrder) ?? []
        // Bindings that cannot be read only cost fork rows their badges, so the repo still loads.
        prBindings = (try? container.decodeIfPresent([String: PRBinding].self, forKey: .prBindings)) ?? [:]
        // Groups that cannot be read are dropped on their own, so the repo, its rows, and its other groups still load.
        let decoded = try? container.decodeIfPresent([Lenient<RowGroup>].self, forKey: .groups)
        groups = decoded?.compactMap(\.value) ?? []
        cleanGroups()
    }
}

/// A value that decodes to nil rather than failing the list it is in.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Everything Canopy persists. New fields must decode with decodeIfPresent so older files still load.
public struct AppState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var repos: [RepoEntry]
    public var selectedRowPath: String?
    /// Each row's tabs and layouts, keyed by row path, rebuilt with fresh shells on launch.
    public var terminals: [String: SavedRowTerminals]
    /// The next pane number, so a pane ID an agent kept never names a different terminal after a relaunch.
    public var nextPane = 1
    public var portsCollapsed = false

    public init(
        version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil,
        terminals: [String: SavedRowTerminals] = [:]
    ) {
        self.version = version
        self.repos = repos
        self.selectedRowPath = selectedRowPath
        self.terminals = terminals
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        repos = try container.decodeIfPresent([RepoEntry].self, forKey: .repos) ?? []
        selectedRowPath = try container.decodeIfPresent(String.self, forKey: .selectedRowPath)
        // Layouts that cannot be read are dropped on their own, so repos and rows still load.
        nextPane = try container.decodeIfPresent(Int.self, forKey: .nextPane) ?? 1
        portsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .portsCollapsed) ?? false
        terminals = (try? container.decodeIfPresent([String: SavedRowTerminals].self, forKey: .terminals)) ?? [:]
    }
}
