import AppKit
import CanopyCore
import SwiftUI

/// A plugin row's detail: the plugin's panel at the left, a divider that resizes it, then the row's tabs and terminals.
/// The top bar starts at the panel's right edge, so the tabs stay above the terminals they switch.
struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.topBarFillsTitleBar) private var topBarFillsTitleBar
    let row: PluginRow

    static let dividerWidth = 1.0

    var body: some View {
        GeometryReader { geometry in
            let width = model.panelWidth(for: row.plugin, detailWidth: geometry.size.width)
            HStack(spacing: 0) {
                PluginPanelColumn(row: row)
                    .frame(width: width)
                PanelDivider(width: width) {
                    model.dragPanel(row.plugin, to: $0)
                } onEnd: {
                    model.endPanelDrag(row.plugin, detailWidth: geometry.size.width)
                }
                TerminalArea(path: row.path, name: row.displayName)
            }
        }
        // In a window the panel and the top bar take the title bar's row.
        .ignoresSafeArea(.container, edges: topBarFillsTitleBar ? .top : [])
    }
}

/// Room for the panel's title strip, which RootView draws beside the top bar, then the panel its plugin draws.
private struct PluginPanelColumn: View {
    @Environment(AppModel.self) private var model
    let row: PluginRow

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Style.topBarHeight)
            Group {
                if let panel = model.builtIn(row.plugin)?.panel {
                    panel(row)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Style.panelBackground)
    }
}

/// The panel's strip in the title bar's row, level with the top bar: the plugin and the row, over empty space that moves
/// the window like a title bar. RootView draws it over the window, since the detail column's title bar row covers
/// what the column draws there.
struct PanelTitleStrip: View {
    @Environment(AppModel.self) private var model
    let row: PluginRow
    /// The traffic lights and the sidebar toggle sit over the strip's leading end.
    let windowControlsOverStrip: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let info = model.snapshot.section(row.plugin)?.info {
                PluginTile(info: info)
                Text(info.name)
                    .foregroundStyle(.secondary)
                Text(verbatim: "/")
                    .foregroundStyle(.tertiary)
            }
            Text(row.displayName)
                .fontWeight(.semibold)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(Style.body)
        .lineLimit(1)
        // It only names the row, so drags and double-clicks reach the title bar area behind it.
        .allowsHitTesting(false)
        .padding(.leading, windowControlsOverStrip ? Style.windowControlsWidth : Style.topBarInset + 4)
        .padding(.trailing, Style.topBarInset)
        .frame(height: Style.topBarHeight)
        .background {
            TitleBarArea()
                .background(Style.chrome)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

/// The line between the panel and the terminals, with a wider grip that drags the panel's width.
private struct PanelDivider: View {
    let width: Double
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: PluginDetailView.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                onDrag(start + value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                onEnd()
                            }
                    )
            }
            .accessibilityHidden(true)
    }
}
