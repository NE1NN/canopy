/// One line of the sidebar, as a dragged row sees it, with its extent down the list.
public struct DropSlot: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The repo's main row, by path.
        case main(String)
        /// A Canopy or adopted row, by path, and its group.
        case row(String, group: String?)
        /// A group's header, by the group's name.
        case header(String)
    }

    public var repoPath: String
    public var kind: Kind
    public var minY: Double
    public var maxY: Double

    public init(repoPath: String, kind: Kind, minY: Double, maxY: Double) {
        self.repoPath = repoPath
        self.kind = kind
        self.minY = minY
        self.maxY = maxY
    }
}

extension DropSlot.Kind {
    /// The row this slot is, by path. A group's header is none.
    public var rowPath: String? {
        switch self {
        case .main(let path), .row(let path, _): path
        case .header: nil
        }
    }
}

/// Where a dropped row goes, and how the sidebar shows it while the row hovers there.
public struct RowDropTarget: Sendable, Equatable {
    public enum Indicator: Sendable, Equatable {
        /// The group's header takes the accent fill.
        case header(String)
        /// A line above the row with this path.
        case above(String)
        /// A line below the row with this path.
        case below(String)
    }

    public var placement: RowPlacement
    public var indicator: Indicator

    public init(placement: RowPlacement, indicator: Indicator) {
        self.placement = placement
        self.indicator = indicator
    }
}

public enum RowDrop {
    /// A group header takes the row at its end. A row's upper half puts the dragged row before it and its lower half
    /// after it. The main row puts it first among the ungrouped rows. Nothing else, including another repo and the
    /// dragged row itself, is a target.
    public static func target(dragging row: Row, at y: Double, in slots: [DropSlot]) -> RowDropTarget? {
        guard let slot = slots.first(where: { $0.minY <= y && y < $0.maxY }), slot.repoPath == row.repoPath else {
            return nil
        }
        switch slot.kind {
        case .header(let name):
            return RowDropTarget(placement: .group(name), indicator: .header(name))
        case .main(let path):
            let firstUngrouped = slots.lazy.compactMap { other -> String? in
                guard other.repoPath == row.repoPath, case .row(let path, nil) = other.kind, path != row.path else {
                    return nil
                }
                return path
            }.first
            return RowDropTarget(placement: firstUngrouped.map { .before($0) } ?? .ungrouped, indicator: .below(path))
        case .row(let path, _):
            guard path != row.path else { return nil }
            return y < (slot.minY + slot.maxY) / 2
                ? RowDropTarget(placement: .before(path), indicator: .above(path))
                : RowDropTarget(placement: .after(path), indicator: .below(path))
        }
    }
}
