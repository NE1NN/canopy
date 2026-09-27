public struct RepoEntry: Codable, Sendable, Equatable {
    public var path: String
    public var dirName: String
    public var adopted: [String]
    public var rowOrder: [String]

    public init(path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = []) {
        self.path = path
        self.dirName = dirName
        self.adopted = adopted
        self.rowOrder = rowOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        dirName = try container.decode(String.self, forKey: .dirName)
        adopted = try container.decodeIfPresent([String].self, forKey: .adopted) ?? []
        rowOrder = try container.decodeIfPresent([String].self, forKey: .rowOrder) ?? []
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
        terminals = (try? container.decodeIfPresent([String: SavedRowTerminals].self, forKey: .terminals)) ?? [:]
    }
}
