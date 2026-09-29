/// A line of the sidebar that can be selected: a worktree row or a plugin's row. Both are keyed by their folder.
public enum SidebarRow: Sendable, Equatable, Identifiable, Codable {
    case worktree(Row)
    case plugin(PluginRow)

    public var id: String { path }

    public var path: String {
        switch self {
        case .worktree(let row): row.path
        case .plugin(let row): row.path
        }
    }

    public var displayName: String {
        switch self {
        case .worktree(let row): row.displayName
        case .plugin(let row): row.displayName
        }
    }

    public var worktree: Row? {
        if case .worktree(let row) = self { row } else { nil }
    }

    public var pluginRow: PluginRow? {
        if case .plugin(let row) = self { row } else { nil }
    }

    private enum Key: String, CodingKey {
        case plugin
    }

    /// A plugin row is the one that names its plugin.
    public init(from decoder: any Decoder) throws {
        if try decoder.container(keyedBy: Key.self).contains(.plugin) {
            self = .plugin(try PluginRow(from: decoder))
        } else {
            self = .worktree(try Row(from: decoder))
        }
    }

    /// Written as the row it holds, so a list of both reads like `row list` always has.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .worktree(let row): try row.encode(to: encoder)
        case .plugin(let row): try row.encode(to: encoder)
        }
    }
}
