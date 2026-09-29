import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A row being dragged within the sidebar. Only Canopy can read it, so a drop in another app does nothing.
    static let canopyRow = UTType(exportedAs: "com.ne1nn.canopy.row", conformingTo: .data)
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The repo list, where rows report their frames and drops are placed.
    static var rowList: NamedCoordinateSpace { .named("rowList") }
}

/// Every line a dragged row can land on, with its frame in the repo list.
struct DropSlotsKey: PreferenceKey {
    static let defaultValue: [DropSlot] = []

    static func reduce(value: inout [DropSlot], nextValue: () -> [DropSlot]) {
        value += nextValue()
    }
}

extension View {
    /// Reports this line's frame to the list's drop delegate.
    func dropSlot(repo: String, _ kind: DropSlot.Kind) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .rowList)
                Color.clear.preference(
                    key: DropSlotsKey.self,
                    value: [DropSlot(repoPath: repo, kind: kind, minY: frame.minY, maxY: frame.maxY)])
            }
        }
    }

    /// Lets a Canopy or adopted row be dragged within its repo. The main row and other tools' worktrees stay put.
    @ViewBuilder
    func rowDragSource(_ row: Row, model: AppModel) -> some View {
        if row.rowClass == .canopy || row.rowClass == .adopted {
            onDrag {
                model.draggedPluginRow = nil
                model.draggedRow = row
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.canopyRow.identifier, visibility: .ownProcess
                ) { completion in
                    completion(Data(row.path.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                RowDragPreview(row: row)
            }
        } else {
            self
        }
    }
}

/// What follows the pointer: the row's mark and name, without the hover hints the row itself shows.
struct RowDragPreview: View {
    let row: Row

    var body: some View {
        HStack(spacing: 8) {
            RowMark(row: row)
                .frame(width: 16)
            Text(row.displayName)
                .font(Style.row)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: Style.rowHeight)
        .background(Style.selectionFill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
    }
}

/// Follows a dragged row over the repo list, showing where it would land, and moves it on drop.
struct RowDropDelegate: DropDelegate {
    let model: AppModel
    let slots: [DropSlot]
    let pluginSlots: [PluginDropSlot]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.canopyRow]) && (model.draggedRow != nil || model.draggedPluginRow != nil)
    }

    func dropEntered(info: DropInfo) {
        model.isDraggingRowOverList = true
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: model.rowDropTarget == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        model.isDraggingRowOverList = false
        model.rowDropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            model.isDraggingRowOverList = false
            model.rowDropTarget = nil
            model.draggedRow = nil
            model.draggedPluginRow = nil
        }
        guard let target = target(info) else { return false }
        if let row = model.draggedRow {
            model.move(row, to: target.placement)
        } else if let row = model.draggedPluginRow {
            model.movePluginRow(row, to: target.placement)
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let target = target(info)
        if model.rowDropTarget != target {
            model.rowDropTarget = target
        }
    }

    private func target(_ info: DropInfo) -> RowDropTarget? {
        if let row = model.draggedRow {
            return RowDrop.target(dragging: row, at: info.location.y, in: slots.sorted { $0.minY < $1.minY })
        }
        if let row = model.draggedPluginRow {
            return PluginRowDrop.target(
                dragging: row, at: info.location.y, in: pluginSlots.sorted { $0.minY < $1.minY })
        }
        return nil
    }
}

/// The line showing where a dragged row would land: accent colored, with a ring at its start, indented to the depth
/// the row would take.
struct RowDropIndicator: View {
    let target: RowDropTarget
    let slots: [DropSlot]
    let pluginSlots: [PluginDropSlot]

    var body: some View {
        if let (y, depth) = placement {
            GeometryReader { geometry in
                let leading = Style.leadingInset(depth)
                let width = max(geometry.size.width - leading - 4, 0)
                HStack(spacing: 0) {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
                .frame(width: width, height: 7)
                .position(x: leading + width / 2, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    /// Where the line goes down the list, and how far in it starts. A header shows the drop itself instead.
    private var placement: (Double, SidebarDepth)? {
        let (path, below): (String, Bool)
        switch target.indicator {
        case .header: return nil
        case .above(let above): (path, below) = (above, false)
        case .below(let under): (path, below) = (under, true)
        }
        if let slot = pluginSlots.first(where: { $0.path == path }) {
            return (below ? slot.maxY : slot.minY, .section)
        }
        guard let slot = slots.first(where: { $0.kind.rowPath == path }), let depth = slot.kind.sidebarDepth else {
            return nil
        }
        return (below ? slot.maxY : slot.minY, depth)
    }
}

extension DropSlot.Kind {
    var rowPath: String? {
        switch self {
        case .main(let path), .row(let path, _): path
        case .header: nil
        }
    }
}
