import CanopyCore
import SwiftUI

/// A row's tabs. Double-click a tab to rename it.
struct TabBarView: View {
    @Environment(AppModel.self) private var model
    let row: Row

    var body: some View {
        let tabs = model.terminals.tabs(inRow: row.path)
        let selected = model.terminals.selectedTab(inRow: row.path)?.id
        HStack(spacing: 0) {
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
                .padding(.horizontal, 6)
            }
            HStack(spacing: 2) {
                TabBarButton(
                    title: "Split Pane", systemImage: "rectangle.split.2x1", shortcut: "⌘D", action: model.splitPane)
                TabBarButton(title: "New Tab", systemImage: "plus", shortcut: "⌘T", action: model.newTab)
            }
            .padding(.trailing, 6)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

struct TabBarButton: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
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
        HStack(spacing: 4) {
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
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close Tab")
            .opacity(isHovering ? 1 : 0)
        }
        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.1) : isHovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                draft = tab.name
                isRenaming = true
            }
        )
        .simultaneousGesture(TapGesture().onEnded(onSelect))
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        onRename(draft)
    }
}
