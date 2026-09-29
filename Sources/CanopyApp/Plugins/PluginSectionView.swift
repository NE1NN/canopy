import CanopyCore
import SwiftUI

/// A plugin's header, its warning, and its rows, below the repos.
struct PluginSectionView: View {
    @Environment(AppModel.self) private var model
    let section: PluginSection
    let isFocused: Bool
    let onNewRow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PluginHeaderView(section: section, onNewRow: onNewRow)
            if let warning = section.warning {
                RepoWarningView(text: warning)
            }
            ForEach(section.rows) { row in
                PluginRowLineView(
                    row: row, info: section.info, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                    shortcut: model.shortcut(for: row.path)
                )
                .pluginDropSlot(PluginDropSlot(plugin: section.id, path: row.path, minY: 0, maxY: 0))
                .id(row.path)
            }
        }
        .padding(.top, 4)
    }
}

/// The plugin's tile, name, and row count, which give way on hover to `…` and `+`.
struct PluginHeaderView: View {
    @Environment(AppModel.self) private var model
    let section: PluginSection
    let onNewRow: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            PluginTile(info: section.info)
            Text(section.info.name)
                .font(Style.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
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
                    .accessibilityLabel(section.rows.count == 1 ? "1 row" : "\(section.rows.count) rows")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { PluginMenuItems(section: section, onNewRow: onNewRow) }
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
