import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

/// A tab's panes, placed by its layout. Dividers resize, and a pane's header drags it onto another pane.
struct GridView: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab
    @State private var hover: DropHover?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = tab.layout.frames(in: rect)
            ZStack(alignment: .topLeading) {
                // Keyed by pane, so a terminal is never rebuilt when the layout around it changes.
                ForEach(tab.layout.leaves, id: \.self) { id in
                    if let pane = tab.panes[id], let frame = frames[id] {
                        PaneView(
                            pane: pane,
                            isFocusedPane: tab.focusedPaneID == id && !model.sidebarKeepsKeyboard,
                            onClose: { model.requestClose(pane) },
                            onFocus: { model.terminals.focus(id) },
                            onDragStart: { model.draggedPane = id },
                            onSizeChange: { model.terminals.preferredSize = $0 }
                        )
                        .onDrop(
                            of: [.plainText],
                            delegate: PaneDropDelegate(target: id, size: frame.size, model: model, hover: $hover)
                        )
                        .overlay { DropHighlight(zone: hover?.target == id ? hover?.zone : nil) }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(tab.layout.dividers(in: rect), id: \.id) { divider in
                    DividerHandle(divider: divider) { position in
                        model.resize(tab, divider: divider.id, to: position, in: rect)
                    }
                }
            }
            .coordinateSpace(.named(GridView.space))
            .onAppear { model.gridSize = geometry.size }
            .onChange(of: geometry.size) { model.gridSize = geometry.size }
        }
    }

    static let space = "grid"
}

struct DropHover: Equatable {
    var target: PaneID
    var zone: DropZone?
}

/// A thin line between panes with a wider grip to drag.
struct DividerHandle: View {
    let divider: LayoutDivider
    let onDrag: (Double) -> Void
    private let grip = 7.0
    /// Where the line was when the drag began, so grabbing the grip off center does not make it jump.
    @State private var startPosition: Double?

    var body: some View {
        let line = divider.line
        let isRow = divider.axis == .row
        Rectangle()
            .fill(.separator)
            .frame(width: isRow ? 1 : line.width, height: isRow ? line.height : 1)
            .frame(width: isRow ? grip : line.width, height: isRow ? line.height : grip)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: isRow ? .trailing : .bottom))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(GridView.space))
                    .onChanged { value in
                        let start = startPosition ?? Double(isRow ? line.minX : line.minY)
                        startPosition = start
                        onDrag(start + (isRow ? value.translation.width : value.translation.height))
                    }
                    .onEnded { _ in startPosition = nil }
            )
            .offset(x: isRow ? line.minX - grip / 2 : line.minX, y: isRow ? line.minY : line.minY - grip / 2)
    }
}

/// Shows where a dragged pane would land: half the target for an edge, all of it for a swap.
struct DropHighlight: View {
    let zone: DropZone?

    var body: some View {
        GeometryReader { geometry in
            if let zone {
                let size = geometry.size
                let area: CGRect =
                    switch zone {
                    case .center: CGRect(origin: .zero, size: size)
                    case .edge(.left): CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
                    case .edge(.right): CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
                    case .edge(.top): CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
                    case .edge(.bottom): CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
                    }
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    )
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.15), value: zone)
    }
}

struct PaneDropDelegate: DropDelegate {
    let target: PaneID
    let size: CGSize
    let model: AppModel
    @Binding var hover: DropHover?

    /// Only a pane dragged from this grid, and not onto itself.
    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = model.draggedPane else { return false }
        return dragged != target && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover = DropHover(target: target, zone: DropZone.at(info.location, in: CGRect(origin: .zero, size: size)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if hover?.target == target { hover = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = DropZone.at(info.location, in: CGRect(origin: .zero, size: size))
        hover = nil
        defer { model.draggedPane = nil }
        guard let zone, let moved = model.draggedPane else { return false }
        model.movePane(moved, to: zone, of: target)
        return true
    }
}
