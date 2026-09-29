import CanopyCore
import SwiftUI

/// A plugin's header, then, unless the section is folded, its warning and its rows, below the repos.
struct PluginSectionView: View {
    @Environment(AppModel.self) private var model
    let section: PluginSection
    let isFocused: Bool
    let onNewRow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PluginHeaderView(section: section, isFocused: isFocused, onNewRow: onNewRow)
            if !section.collapsed {
                if let warning = section.warning {
                    RepoWarningView(text: warning)
                }
                ForEach(section.rows) { row in
                    PluginRowLineView(
                        row: row, info: section.info, isSelected: row.path == model.selectedRowPath,
                        isFocused: isFocused, shortcut: model.shortcut(for: row.path)
                    )
                    .pluginDropSlot(PluginDropSlot(plugin: section.id, path: row.path, minY: 0, maxY: 0))
                    .id(row.path)
                }
            }
        }
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.15), value: section.collapsed)
    }
}

/// The plugin's tile, name, and chevron, then its row count, which gives way on hover to `…` and `+`. Clicking it
/// anywhere else folds or unfolds the section.
struct PluginHeaderView: View {
    @Environment(AppModel.self) private var model
    let section: PluginSection
    let isFocused: Bool
    let onNewRow: () -> Void
    @State private var isHovering = false

    /// A folded section shows the most urgent agent dot among the rows it hides.
    private var agentDot: AgentDot? {
        guard section.collapsed else { return nil }
        return model.terminals.agentDot(inRows: section.rows.map(\.path))
    }

    var body: some View {
        HStack(spacing: 8) {
            summary
            Spacer(minLength: 4)
            if let agentDot {
                AgentDotView(dot: agentDot)
                    .accessibilityHidden(true)
            }
            if isHovering {
                IconMenu(title: "More for \(section.info.name)", systemImage: "ellipsis") {
                    PluginMenuItems(section: section, onNewRow: onNewRow)
                }
                IconButton(title: "\(section.info.newRowTitle)…", systemImage: "plus", action: onNewRow)
            } else {
                Text(verbatim: "\(section.rows.count)")
                    .font(Style.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Style.leadingInset(.header))
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .contextMenu { PluginMenuItems(section: section, onNewRow: onNewRow) }
    }

    /// The tile and name, which VoiceOver reads as one button that folds the section, its label saying the row count and
    /// agent dot too. The header's buttons stay controls of their own: combined into it, they would make it a menu
    /// button.
    private var summary: some View {
        HStack(spacing: 8) {
            PluginTile(info: section.info)
            HStack(spacing: 0) {
                Text(section.info.name)
                    .font(Style.body.weight(.semibold))
                    .lineLimit(1)
                DisclosureChevron(isExpanded: !section.collapsed)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(section.collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(holdsSelection ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
        .accessibilityActions {
            Button("\(section.info.newRowTitle)…", action: onNewRow)
        }
    }

    /// A folded section holding the selected row shows the selection, so the sidebar always says where the window is.
    private var holdsSelection: Bool { model.selectionFold == .plugin(section.id) }

    private var fill: Color {
        if holdsSelection { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private var accessibilityLabel: String {
        var parts = [
            section.info.name, "plugin", section.rows.count == 1 ? "1 row" : "\(section.rows.count) rows",
        ]
        if let agentDot { parts.append(agentDot.label.lowercased()) }
        return parts.joined(separator: ", ")
    }

    private func toggle() {
        model.setCollapsed(section, !section.collapsed)
    }
}

struct PluginMenuItems: View {
    @Environment(AppModel.self) private var model
    let section: PluginSection
    let onNewRow: () -> Void

    var body: some View {
        Button("New Row…", action: onNewRow)
        Divider()
        Button("Turn Off \(section.info.name)") { model.turnOff(section) }
        ForEach(model.builtIn(section.id)?.menuActions ?? []) { action in
            Button(action.title) { model.ask(action, in: section) }
        }
    }
}
