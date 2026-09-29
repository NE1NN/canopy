import AppKit
import CanopyCore
import SwiftUI

/// The bar in the title bar row: a row's tabs, and the Split Pane and New Tab buttons. Its empty space moves the window
/// like a title bar. Double-click a tab to rename it.
struct TopBarView: View {
    @Environment(AppModel.self) private var model
    let row: Row
    /// While the sidebar is hidden, the bar names the row.
    let isSidebarHidden: Bool
    let leadingInset: Double
    @State private var stripWidth = 0.0

    var body: some View {
        let tabs = model.terminals.tabs(inRow: row.path)
        let selected = model.terminals.selectedTab(inRow: row.path)?.id
        HStack(spacing: 2) {
            if isSidebarHidden {
                RowCrumb(row: row)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tab.id == selected,
                            onSelect: { model.terminals.selectTab(tab.id, inRow: row.path) },
                            onClose: { model.requestCloseTab(tab, inRow: row.path) },
                            onRename: { name in
                                model.terminals.renameTab(tab.id, inRow: row.path, to: name)
                                model.focusSelectedTerminal()
                            }
                        )
                    }
                }
                // Fills the strip, so the space after the last tab still moves the window.
                .frame(minWidth: stripWidth, maxHeight: .infinity, alignment: .leading)
                .background(TitleBarArea())
            }
            .onGeometryChange(for: Double.self) {
                $0.size.width
            } action: {
                stripWidth = $0
            }
            IconButton(
                title: "Split Pane", systemImage: "rectangle.split.2x1", shortcut: "⌘D", size: 26, imageSize: 13,
                action: model.splitPane)
            IconButton(
                title: "New Tab", systemImage: "plus", shortcut: "⌘T", size: 26, imageSize: 13, action: model.newTab)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, TopBarPlacement.edge)
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

/// Empty title bar space: dragging it moves the window, and double-clicking it does what the system setting says.
struct TitleBarArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { Self.doubleClick(NSApp.keyWindow) })
    }

    static func doubleClick(_ window: NSWindow?) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }
}

/// The row's repo and branch, for when the sidebar is hidden.
struct RowCrumb: View {
    @Environment(AppModel.self) private var model
    let row: Row

    var body: some View {
        HStack(spacing: 6) {
            if let repo = model.snapshot.repo(path: row.repoPath) {
                RepoTile(mark: repo.mark)
                Text(repo.name)
                    .foregroundStyle(.secondary)
                Text(verbatim: "/")
                    .foregroundStyle(.tertiary)
            }
            Text(row.displayName)
                .fontWeight(.semibold)
                .truncationMode(.middle)
        }
        .font(Style.body)
        .lineLimit(1)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 6)
        // It only names the row, so drags and double-clicks on it reach the title bar area behind it.
        .allowsHitTesting(false)
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 16)
            .padding(.trailing, 6)
    }
}

struct TabItemView: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.layout.shape.symbolName)
                .font(.system(size: 12))
                .frame(width: 14)
            if isRenaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .fixedSize()
                    .onAppear { isFieldFocused = true }
                    .onSubmit(finishRenaming)
                    .onExitCommand {
                        draft = tab.name
                        finishRenaming()
                    }
                    .onChange(of: isFieldFocused) {
                        if !isFieldFocused { finishRenaming() }
                    }
            } else {
                Text(tab.name)
                    .lineLimit(1)
            }
            // The close button and the agent dot share a slot, so hovering does not shift the tab.
            ZStack {
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close Tab")
                } else if let dot = tab.agentDot {
                    AgentDotView(dot: dot, size: 5)
                }
            }
            .frame(width: 14, height: 14)
        }
        .font(Style.body.weight(isSelected ? .medium : .regular))
        .foregroundStyle(isSelected || isHovering ? .primary : .secondary)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: Style.tabHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                draft = tab.name
                isRenaming = true
            }
        )
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        onRename(draft)
    }
}

extension LayoutShape {
    var symbolName: String {
        switch self {
        case .single: "terminal"
        case .columns(let count): count > 2 ? "rectangle.split.3x1" : "rectangle.split.2x1"
        case .rows: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        }
    }
}
