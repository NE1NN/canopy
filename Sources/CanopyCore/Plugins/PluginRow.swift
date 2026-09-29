/// The colors plugins can mark things with. The app picks the shades, so they follow the appearance.
public enum PluginColor: String, Sendable, Codable, CaseIterable {
    case gray, red, orange, yellow, green, blue, purple, accent
}

/// A mark the sidebar and the picker know how to draw: a colored dot, a tag such as "closed", or initials on a colored
/// circle. Plugins never draw into the sidebar themselves.
public struct PluginAccessory: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case dot, tag, initials
    }

    public var kind: Kind
    /// The tag's text or the initials.
    public var text: String?
    public var color: PluginColor
    /// What it means, for hover and VoiceOver, such as "Customer waiting".
    public var help: String

    public init(kind: Kind, text: String? = nil, color: PluginColor, help: String) {
        self.kind = kind
        self.text = text
        self.color = color
        self.help = help
    }

    public static func dot(_ color: PluginColor, help: String) -> PluginAccessory {
        PluginAccessory(kind: .dot, color: color, help: help)
    }

    public static func tag(_ text: String, help: String) -> PluginAccessory {
        PluginAccessory(kind: .tag, text: text, color: .gray, help: help)
    }

    public static func initials(_ text: String, color: PluginColor, help: String) -> PluginAccessory {
        PluginAccessory(kind: .initials, text: text, color: color, help: help)
    }
}

/// How a plugin row looks, which its plugin sets while it runs.
public struct PluginRowLook: Sendable, Equatable {
    /// Shown in place of the saved title. CANOPY_ROW and the activity log keep the saved one.
    public var title: String?
    /// Such as `#0853`, which the item's linked worktree rows show.
    public var label: String?
    public var accessories: [PluginAccessory]
    /// The plugin no longer has the item.
    public var isMissing: Bool

    public init(
        title: String? = nil, label: String? = nil, accessories: [PluginAccessory] = [], isMissing: Bool = false
    ) {
        self.title = title
        self.label = label
        self.accessories = accessories
        self.isMissing = isMissing
    }

    public static let plain = PluginRowLook()
}

/// A row a plugin owns: a folder under CANOPY_HOME/plugins/<plugin>/ tied to one of the plugin's items, with its own
/// tabs and terminals, keyed by its path like any row.
public struct PluginRow: Sendable, Equatable, Identifiable, Codable {
    public var plugin: String
    public var item: String
    /// Fixed when the row is made.
    public var title: String
    public var path: String
    public var look: PluginRowLook

    public init(plugin: String, item: String, title: String, path: String, look: PluginRowLook = .plain) {
        self.plugin = plugin
        self.item = item
        self.title = title
        self.path = path
        self.look = look
    }

    public var id: String { path }
    public var displayName: String { look.title ?? title }
    public var isMissing: Bool { look.isMissing }

    enum CodingKeys: String, CodingKey {
        case plugin, item, title, path, label, missing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(String.self, forKey: .plugin)
        item = try container.decode(String.self, forKey: .item)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        look = PluginRowLook(
            label: try container.decodeIfPresent(String.self, forKey: .label),
            isMissing: try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(plugin, forKey: .plugin)
        try container.encode(item, forKey: .item)
        try container.encode(title, forKey: .title)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(look.label, forKey: .label)
        try container.encode(look.isMissing, forKey: .missing)
    }
}

/// A worktree row's tie to one of a plugin's items, such as the ticket a fix is for.
public struct PluginLink: Sendable, Equatable, Codable {
    public var plugin: String
    public var item: String

    public init(plugin: String, item: String) {
        self.plugin = plugin
        self.item = item
    }
}

/// A plugin's section of the sidebar, as the snapshot carries it. Plugins that are off are listed too, so their rows'
/// saved layouts wait for them.
public struct PluginSection: Sendable, Equatable, Identifiable {
    public var info: PluginInfo
    public var isOn: Bool
    /// Why the plugin is not working, with the fix, as markdown.
    public var warning: String?
    /// In sidebar order.
    public var rows: [PluginRow]
    public var panelWidth: Double?
    /// Whether the sidebar folds the section under its header.
    public var collapsed: Bool

    public init(
        info: PluginInfo, isOn: Bool, warning: String? = nil, rows: [PluginRow] = [], panelWidth: Double? = nil,
        collapsed: Bool = false
    ) {
        self.info = info
        self.isOn = isOn
        self.warning = warning
        self.rows = rows
        self.panelWidth = panelWidth
        self.collapsed = collapsed
    }

    public var id: String { info.id }
}
