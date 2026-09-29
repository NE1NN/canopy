/// A pane's ID, such as `p12`. Agents see it as CANOPY_PANE.
public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "p\(number)" }

    /// Reads "p12" back, as dragged panes and `canopy term` carry it.
    public init?(_ text: String) {
        guard text.hasPrefix("p"), let number = Int(text.dropFirst()), number > 0 else { return nil }
        self.number = number
    }
}

public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "t\(number)" }
}

/// The row a terminal belongs to.
public struct PaneContext: Sendable, Equatable {
    /// What the row belongs to: a repo, or a plugin's item.
    public enum Owner: Sendable, Equatable {
        case repo(name: String, path: String)
        case plugin(id: String, item: String)
    }

    public var owner: Owner
    public var rowName: String
    public var rowPath: String

    public init(row: Row, repoName: String) {
        owner = .repo(name: repoName, path: row.repoPath)
        rowName = row.displayName
        rowPath = row.path
    }

    /// A plugin row's terminals are named by its saved title, which never changes.
    public init(pluginRow row: PluginRow) {
        owner = .plugin(id: row.plugin, item: row.item)
        rowName = row.title
        rowPath = row.path
    }

    public init(_ row: SidebarRow, repoName: String) {
        switch row {
        case .worktree(let row): self.init(row: row, repoName: repoName)
        case .plugin(let row): self.init(pluginRow: row)
        }
    }

    public var repoName: String? {
        if case .repo(let name, _) = owner { name } else { nil }
    }

    public var repoPath: String? {
        if case .repo(_, let path) = owner { path } else { nil }
    }
}
