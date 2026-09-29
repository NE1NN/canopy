import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

/// A plugin row: its plugin's symbol, its title, its accessories, then the agent dot, with the shortcut and an `x` on
/// hover.
struct PluginRowLineView: View {
    @Environment(AppModel.self) private var model
    let row: PluginRow
    let info: PluginInfo
    let isSelected: Bool
    let isFocused: Bool
    let shortcut: Int?
    @State private var isHovering = false
    @State private var isConfirmingRemove = false

    private var agentDot: AgentDot? { model.terminals.agentDot(inRow: row.path) }

    private var isDragged: Bool { model.isDraggingRowOverList && model.draggedPluginRow?.path == row.path }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: info.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.isMissing ? .tertiary : .secondary)
                .frame(width: 16)
            Text(row.displayName)
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isMissing ? .secondary : .primary)
            if row.isMissing {
                TagView(text: "missing")
            }
            Spacer(minLength: 4)
            ForEach(Array(row.look.accessories.enumerated()), id: \.offset) { _, accessory in
                PluginAccessoryView(accessory: accessory)
            }
            if let agentDot {
                AgentDotView(dot: agentDot)
            }
            if (isHovering && !isDragged) || isConfirmingRemove || row.isMissing {
                if let shortcut, isHovering {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(Style.meta)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Button {
                    isConfirmingRemove = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove row")
                .popover(isPresented: $isConfirmingRemove, arrowEdge: .trailing) {
                    RemovePluginRowPopover(row: row, isPresented: $isConfirmingRemove)
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: Style.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRowPath = row.path }
        .pluginRowDragSource(row, info: info, model: model)
        .opacity(isDragged ? 0.4 : 1)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            }
            Divider()
            Button("Remove Row…") { isConfirmingRemove = true }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(row.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedRowPath = row.path }
    }

    private var fill: Color {
        if isSelected { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering && !isDragged ? Style.hoverFill : .clear
    }

    private var accessibilityLabel: String {
        var parts = [row.displayName, "in \(info.name)"]
        parts += row.look.accessories.map(\.help)
        if let agentDot { parts.append(agentDot.label.lowercased()) }
        if row.isMissing { parts.append("missing") }
        return parts.joined(separator: ", ")
    }
}

struct RemovePluginRowPopover: View {
    @Environment(AppModel.self) private var model
    let row: PluginRow
    @Binding var isPresented: Bool
    @State private var isWorking = false
    @State private var error: String?

    private var busyTerminals: Int { model.terminals.busyPanes(inRow: row.path).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove \(row.displayName)?")
                .font(.headline)
            Text("Its folder goes to the Trash. Rows linked to its item keep their link.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if busyTerminals > 0 {
                NoteLine(
                    systemImage: "apple.terminal",
                    text: busyTerminals == 1
                        ? "A terminal in this row is running a program. Removing stops it."
                        : "\(busyTerminals) terminals in this row are running programs. Removing stops them.",
                    color: .secondary)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive, action: remove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(14)
        .frame(width: 300)
        // The popover inherits the sidebar row's one-line limit.
        .lineLimit(nil)
    }

    private func remove() {
        isWorking = true
        Task {
            error = await model.removePluginRow(row)
            isWorking = false
            if error == nil { isPresented = false }
        }
    }
}

/// The item's short label on a worktree row linked to it, such as `#0853`. Clicking it selects the item's row.
struct LinkChip: View {
    @Environment(AppModel.self) private var model
    let row: PluginRow
    let label: String
    @State private var isHovering = false

    var body: some View {
        Button {
            model.reveal(row.path)
        } label: {
            Text(verbatim: label)
                .font(Style.meta.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Style.badgeFill, in: RoundedRectangle(cornerRadius: Style.tagRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show \(row.displayName)")
        .accessibilityLabel("Linked to \(row.displayName). Shows it.")
    }
}

/// Every plugin row a dragged plugin row can land next to, with its frame in the list.
struct PluginDropSlotsKey: PreferenceKey {
    static let defaultValue: [PluginDropSlot] = []

    static func reduce(value: inout [PluginDropSlot], nextValue: () -> [PluginDropSlot]) {
        value += nextValue()
    }
}

extension View {
    /// Reports this plugin row's frame to the list's drop delegate. `slot` gives its plugin and path.
    func pluginDropSlot(_ slot: PluginDropSlot) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .rowList)
                Color.clear.preference(
                    key: PluginDropSlotsKey.self,
                    value: [PluginDropSlot(plugin: slot.plugin, path: slot.path, minY: frame.minY, maxY: frame.maxY)])
            }
        }
    }

    /// Lets a plugin row be dragged within its section.
    func pluginRowDragSource(_ row: PluginRow, info: PluginInfo, model: AppModel) -> some View {
        onDrag {
            model.draggedRow = nil
            model.draggedPluginRow = row
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.canopyRow.identifier, visibility: .ownProcess
            ) { completion in
                completion(Data(row.path.utf8), nil)
                return nil
            }
            return provider
        } preview: {
            HStack(spacing: 8) {
                Image(systemName: info.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
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
}
