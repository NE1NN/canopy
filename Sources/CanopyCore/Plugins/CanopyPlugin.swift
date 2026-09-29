import Foundation

/// What names a plugin. Its id names its config section, its folder, its control methods, and its activity events.
public struct PluginInfo: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// An SF Symbol for its section's tile and its rows.
    public var symbol: String
    /// What one of its items is called, such as "Ticket", when the plugin's name does not read as one.
    public var itemName: String?

    public init(id: String, name: String, symbol: String, itemName: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.itemName = itemName
    }

    /// The picker's title, such as "New Ticket Row".
    public var newRowTitle: String { "New \(itemName ?? name) Row" }
}

/// One of the picker's chips.
public struct PluginFilter: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// The picker's chips. At most one choice narrows the list, such as Mine or Anyone, and each toggle that is on changes
/// which items are fetched, such as Closed.
public struct PluginFilters: Sendable, Equatable, Codable {
    public var choices: [PluginFilter]
    public var defaultChoice: String?
    public var toggles: [PluginFilter]

    public init(choices: [PluginFilter] = [], defaultChoice: String? = nil, toggles: [PluginFilter] = []) {
        self.choices = choices
        self.defaultChoice = defaultChoice
        self.toggles = toggles
    }

    public static let none = PluginFilters()
}

/// What the picker, or `canopy plugin items`, asks a plugin for.
public struct PluginQuery: Sendable, Equatable {
    public var text: String
    public var choice: String?
    public var toggles: Set<String>
    /// True when the picker opens or a toggle changes, so a plugin that keeps what it fetched fetches again.
    public var fresh: Bool

    public init(text: String = "", choice: String? = nil, toggles: Set<String> = [], fresh: Bool = true) {
        self.text = text
        self.choice = choice
        self.toggles = toggles
        self.fresh = fresh
    }
}

/// One of a plugin's items, as the picker and `canopy plugin items` list it.
public struct PluginItem: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var accessories: [PluginAccessory]
    /// The row the item already has, which the host fills in.
    public var row: PluginRow?

    public init(
        id: String, title: String, subtitle: String? = nil, accessories: [PluginAccessory] = [], row: PluginRow? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.accessories = accessories
        self.row = row
    }

    /// Writes `"row": null` rather than leaving the key out, so "no row" reads plainly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(accessories, forKey: .accessories)
        try container.encode(row, forKey: .row)
    }
}

/// A new row's title, fixed from then on, the name its folder starts from, and the command a new terminal in it runs
/// when the request names none, such as a plugin's configured `run`.
public struct PluginRowSeed: Sendable, Equatable {
    public var title: String
    public var folderName: String
    public var run: String?

    public init(title: String, folderName: String, run: String? = nil) {
        self.title = title
        self.folderName = folderName
        self.run = run
    }
}

/// A control method call routed to a plugin.
public struct PluginCall: Sendable {
    public var method: String
    public var params: JSONValue
    /// Where the CLI ran, from the params' `target`.
    public var target: TargetHint
    /// The plugin's row the target points at, when the command ran in one or named one.
    public var row: PluginRow?

    public init(method: String, params: JSONValue, target: TargetHint = TargetHint(), row: PluginRow? = nil) {
        self.method = method
        self.params = params
        self.target = target
        self.row = row
    }

    public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T {
        try ControlRequest(method: method, params: params).decodeParams(type)
    }
}

/// A plugin built into Canopy. It does nothing until config.json turns it on, and reaches Canopy only through the
/// `PluginContext` the host hands it.
public protocol CanopyPlugin: Sendable {
    var info: PluginInfo { get }
    var filters: PluginFilters { get }
    /// Control methods it answers, each its id and a dot first, such as `tickets.list`. They reach it while it is off
    /// too, so a method such as `tickets.connect` can turn it on.
    var methods: Set<String> { get }
    /// Those of `methods` that only read, which the activity log leaves out.
    var readOnlyMethods: Set<String> { get }

    /// Called when it turns on, at launch or later. A failure shows as its section's warning. Launching waits for it,
    /// so it must return promptly and leave network calls to tasks of its own.
    func start(_ context: PluginContext) async throws
    /// Called when it turns off, and when Canopy quits. It must stop its timers and network calls, and return promptly.
    func stop(_ context: PluginContext) async
    /// One line for `canopy plugin list`, such as "connected as me@example.com, updated 20 s ago".
    func status(_ context: PluginContext) async -> String?
    func items(matching query: PluginQuery, context: PluginContext) async throws -> [PluginItem]
    /// The item a reference an agent typed names, such as `853` for a ticket.
    func resolve(_ reference: String, context: PluginContext) async throws -> String
    /// A new row's title and folder name, or an error such as `ticket_not_found`, before anything is made.
    func seed(for item: String, context: PluginContext) async throws -> PluginRowSeed
    /// Writes the row's files into its folder, which exists when this is called.
    func fill(_ row: PluginRow, context: PluginContext) async throws
    /// The picker footer's command for an item without a row, or nil for `canopy plugin new <id> <item> --select`.
    func pickerCommand(for item: PluginItem) -> String?
    /// The command that turns it on, which errors while it is off name, such as `canopy ticket connect <url>`. `config`
    /// is its section of config.json.
    func turnOnCommand(config: JSONValue) -> String
    func handle(_ call: PluginCall, context: PluginContext) async throws -> JSONValue
}

extension CanopyPlugin {
    public var filters: PluginFilters { .none }
    public var methods: Set<String> { [] }
    public var readOnlyMethods: Set<String> { [] }

    public func stop(_ context: PluginContext) async {}

    public func status(_ context: PluginContext) async -> String? { nil }

    public func pickerCommand(for item: PluginItem) -> String? { nil }

    public func turnOnCommand(config: JSONValue) -> String { "canopy plugin enable \(info.id)" }

    public func handle(_ call: PluginCall, context: PluginContext) async throws -> JSONValue {
        throw ControlError(code: "unknown_method", message: "Unknown method \(call.method)")
    }
}
