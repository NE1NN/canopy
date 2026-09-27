/// A pane as saved: only its folder. Restoring starts a fresh shell there and never re-runs old commands.
public struct SavedPane: Codable, Hashable, Sendable {
    public var folder: String

    public init(folder: String) {
        self.folder = folder
    }
}

public struct SavedTab: Codable, Equatable, Sendable {
    public var name: String
    public var layout: Layout<SavedPane>
    /// The focused pane's position in layout order.
    public var focused: Int?

    public init(name: String, layout: Layout<SavedPane>, focused: Int?) {
        self.name = name
        self.layout = layout
        self.focused = focused
    }
}

/// A row's tabs as saved in state.json.
public struct SavedRowTerminals: Codable, Equatable, Sendable {
    public var tabs: [SavedTab]
    public var selectedTab: Int

    public init(tabs: [SavedTab], selectedTab: Int) {
        self.tabs = tabs
        self.selectedTab = selectedTab
    }
}
