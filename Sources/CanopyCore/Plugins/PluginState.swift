/// A plugin row as state.json keeps it. How it looks comes from its plugin while it runs.
public struct PluginRowEntry: Codable, Sendable, Equatable {
    public var item: String
    public var title: String
    public var path: String

    public init(item: String, title: String, path: String) {
        self.item = item
        self.title = title
        self.path = path
    }
}

/// A plugin's part of state.json. It stays while the plugin is off, so turning it back on brings its rows back.
public struct PluginEntry: Codable, Sendable, Equatable {
    /// In sidebar order.
    public var rows: [PluginRowEntry]
    /// The item each linked worktree row is for, keyed by the worktree row's path.
    public var links: [String: String]
    public var panelWidth: Double?
    /// Whether the sidebar folds the plugin's section under its header.
    public var collapsed: Bool

    public init(
        rows: [PluginRowEntry] = [], links: [String: String] = [:], panelWidth: Double? = nil, collapsed: Bool = false
    ) {
        self.rows = rows
        self.links = links
        self.panelWidth = panelWidth
        self.collapsed = collapsed
    }

    /// A row or a field that cannot be read is dropped on its own, so the rest still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try? container.decodeIfPresent([Lenient<PluginRowEntry>].self, forKey: .rows)
        self.rows = rows?.compactMap(\.value) ?? []
        links = (try? container.decodeIfPresent([String: String].self, forKey: .links)) ?? [:]
        panelWidth = try? container.decodeIfPresent(Double.self, forKey: .panelWidth)
        collapsed = (try? container.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
    }
}
