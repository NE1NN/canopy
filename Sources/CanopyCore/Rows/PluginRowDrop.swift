/// One plugin row in the sidebar, as a dragged plugin row sees it, with its extent down the list.
public struct PluginDropSlot: Sendable, Equatable {
    public var plugin: String
    public var path: String
    public var minY: Double
    public var maxY: Double

    public init(plugin: String, path: String, minY: Double, maxY: Double) {
        self.plugin = plugin
        self.path = path
        self.minY = minY
        self.maxY = maxY
    }
}

public enum PluginRowDrop {
    /// A plugin row lands next to another row of its own plugin: before it over that row's upper half, after it over
    /// the lower half. Nothing else, the dragged row itself included, is a target.
    public static func target(dragging row: PluginRow, at y: Double, in slots: [PluginDropSlot]) -> RowDropTarget? {
        guard let slot = slots.first(where: { $0.minY <= y && y < $0.maxY }), slot.plugin == row.plugin,
            slot.path != row.path
        else { return nil }
        return y < (slot.minY + slot.maxY) / 2
            ? RowDropTarget(placement: .before(slot.path), indicator: .above(slot.path))
            : RowDropTarget(placement: .after(slot.path), indicator: .below(slot.path))
    }
}
