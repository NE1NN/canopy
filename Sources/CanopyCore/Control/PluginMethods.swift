public enum PluginMethod {
    public static let list = "plugin.list"
    public static let enable = "plugin.enable"
    public static let disable = "plugin.disable"
    public static let items = "plugin.items"
    public static let new = "plugin.new"
}

public struct PluginEnableParams: Codable, Sendable {
    public var plugin: String
    /// Merged into the plugin's section of config.json.
    public var fields: [String: JSONValue]

    public init(plugin: String, fields: [String: JSONValue] = [:]) {
        self.plugin = plugin
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(String.self, forKey: .plugin)
        fields = try container.decodeIfPresent([String: JSONValue].self, forKey: .fields) ?? [:]
    }
}

public struct PluginDisableParams: Codable, Sendable {
    public var plugin: String
    /// Closes the terminals in its rows even while programs run in them.
    public var force: Bool

    public init(plugin: String, force: Bool = false) {
        self.plugin = plugin
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(String.self, forKey: .plugin)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

public struct PluginItemsParams: Codable, Sendable {
    public var plugin: String
    public var query: String?
    /// Ids of the plugin's filters: at most one of its choices, and any of its toggles.
    public var filters: [String]

    public init(plugin: String, query: String? = nil, filters: [String] = []) {
        self.plugin = plugin
        self.query = query
        self.filters = filters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(String.self, forKey: .plugin)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        filters = try container.decodeIfPresent([String].self, forKey: .filters) ?? []
    }
}

public struct PluginNewParams: Codable, Sendable {
    public var plugin: String
    /// What names the item, such as its id.
    public var reference: String
    /// A command to type into a new terminal in the row once its folder is filled.
    public var run: String?
    public var select: Bool

    public init(plugin: String, reference: String, run: String? = nil, select: Bool = false) {
        self.plugin = plugin
        self.reference = reference
        self.run = run
        self.select = select
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(String.self, forKey: .plugin)
        reference = try container.decode(String.self, forKey: .reference)
        run = try container.decodeIfPresent(String.self, forKey: .run)
        select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
    }
}

/// `row.new`'s link: a plugin and a reference to one of its items, which the plugin resolves before any git work.
public struct RowLinkParams: Codable, Sendable, Equatable {
    public var plugin: String
    public var reference: String
    /// Taken from the plugin row the CLI ran in, rather than asked for.
    public var fromEnvironment: Bool

    public init(plugin: String, reference: String, fromEnvironment: Bool = false) {
        self.plugin = plugin
        self.reference = reference
        self.fromEnvironment = fromEnvironment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(String.self, forKey: .plugin)
        reference = try container.decode(String.self, forKey: .reference)
        fromEnvironment = try container.decodeIfPresent(Bool.self, forKey: .fromEnvironment) ?? false
    }
    /// The item of the plugin row a command runs in, from CANOPY_PLUGIN and CANOPY_ITEM, so a fix row started from a
    /// ticket row's terminal is linked to its ticket.
    public init?(environment: [String: String]) {
        guard let plugin = environment["CANOPY_PLUGIN"], !plugin.isEmpty, let item = environment["CANOPY_ITEM"],
            !item.isEmpty
        else { return nil }
        self.init(plugin: plugin, reference: item, fromEnvironment: true)
    }
}

extension PluginFilters {
    /// The query `filters` ask for: at most one choice, the default when none, and any toggles.
    public func query(text: String?, filters ids: [String], plugin name: String) throws -> PluginQuery {
        let choiceIDs = Set(choices.map(\.id))
        let toggleIDs = Set(toggles.map(\.id))
        let unknown = ids.filter { !choiceIDs.contains($0) && !toggleIDs.contains($0) }
        guard unknown.isEmpty else {
            let known = (choices + toggles).map(\.id)
            let list = known.isEmpty ? "It has none." : "Its filters are \(known.joined(separator: ", "))."
            throw ControlError(code: "bad_params", message: "\(name) has no filter \(unknown[0]). \(list)")
        }
        let picked = ids.filter(choiceIDs.contains)
        guard picked.count <= 1 else {
            throw ControlError(
                code: "bad_params",
                message:
                    "Pick one of \(choices.map(\.id).joined(separator: ", ")), not \(picked.joined(separator: " and "))."
            )
        }
        return PluginQuery(
            text: text ?? "", choice: picked.first ?? defaultChoice, toggles: Set(ids.filter(toggleIDs.contains)),
            fresh: true)
    }
}
