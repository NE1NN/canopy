/// A pane as saved: only its folder. Restoring starts a fresh shell there and never re-runs old commands.
public struct SavedPane: Codable, Hashable, Sendable {
    public var folder: String

    public init(folder: String) {
        self.folder = folder
    }
}

/// A web page as saved: where it was and what it was called. Restoring loads it only once it shows.
public struct SavedWebPage: Codable, Hashable, Sendable {
    public var url: String
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

/// A terminal tab, with its layout, or a web tab, with its page.
public struct SavedTab: Codable, Equatable, Sendable {
    public var name: String
    /// Nil for a web tab.
    public var layout: Layout<SavedPane>?
    /// The focused pane's position in layout order.
    public var focused: Int?
    public var web: SavedWebPage?

    public init(name: String, layout: Layout<SavedPane>, focused: Int?) {
        self.name = name
        self.layout = layout
        self.focused = focused
    }

    public init(name: String, web: SavedWebPage) {
        self.name = name
        self.web = web
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        layout = try container.decodeIfPresent(Layout<SavedPane>.self, forKey: .layout)
        focused = try container.decodeIfPresent(Int.self, forKey: .focused)
        web = try container.decodeIfPresent(SavedWebPage.self, forKey: .web)
        guard layout != nil || web != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .layout, in: container, debugDescription: "A tab needs a layout or a web page.")
        }
    }
}

/// A row's panel as saved: its page, and whether the author hid it.
public struct SavedWebPanel: Codable, Equatable, Sendable {
    public var page: SavedWebPage
    public var hidden: Bool

    public init(page: SavedWebPage, hidden: Bool) {
        self.page = page
        self.hidden = hidden
    }
}

/// A row's tabs and panel as saved in state.json.
public struct SavedRowTerminals: Codable, Equatable, Sendable {
    public var tabs: [SavedTab]
    public var selectedTab: Int
    public var panel: SavedWebPanel?

    public init(tabs: [SavedTab], selectedTab: Int, panel: SavedWebPanel? = nil) {
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.panel = panel
    }
}
