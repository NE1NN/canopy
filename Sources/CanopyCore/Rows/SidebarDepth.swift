/// How many steps in from its section's header a sidebar line sits. Each step is the same size, so the sidebar reads
/// repo, then group, then row.
public enum SidebarDepth: Int, Sendable {
    /// A repo's or a plugin's header.
    case header
    /// What a header holds: the main row, ungrouped rows, group headers, the PR warning, the other worktrees fold, and
    /// a plugin's rows.
    case section
    /// What a group or the other worktrees fold holds.
    case group
}

extension Row {
    public var sidebarDepth: SidebarDepth {
        group != nil || rowClass == .external ? .group : .section
    }
}

extension DropSlot.Kind {
    /// The depth of the row this slot is, where a row dropped beside it lands. A group's header has none, since a drop
    /// there shows as its fill.
    public var sidebarDepth: SidebarDepth? {
        switch self {
        case .main: .section
        case .row(_, let group): group == nil ? .section : .group
        case .header: nil
        }
    }
}
