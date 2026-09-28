import CanopyCore
import SwiftUI

/// One terminal with its header, and a strip below it once its shell has exited.
struct PaneView: View {
    let pane: Pane
    /// Whether it is its tab's focused pane, which takes the keyboard when the tab comes into view.
    var isFocusedPane = true
    let onClose: () -> Void
    var onFocus: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onSizeChange: (TerminalSize) -> Void = { _ in }
    @State private var isFocused = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, isFocused: isFocused, onClose: onClose)
                // The header is the handle for dragging the pane onto another one.
                .onDrag {
                    onDragStart()
                    return NSItemProvider(object: pane.id.description as NSString)
                }
            TerminalSurface(
                pane: pane,
                takesFocus: isFocusedPane,
                onFocusChange: { focused in
                    isFocused = focused
                    if focused { onFocus() }
                },
                onSizeChange: onSizeChange
            )
            if case .exited(let code) = pane.status {
                ExitStrip(pane: pane, code: code)
            }
        }
        .task(id: pane.id) {
            // Titles fall back to the foreground program, which changes without any event to watch.
            while !Task.isCancelled {
                pane.refreshTitle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct PaneHeader: View {
    static let height = Style.paneHeaderHeight

    let pane: Pane
    let isFocused: Bool
    let onClose: () -> Void
    @Environment(\.controlActiveState) private var activeState
    @State private var isHovering = false

    private var isHighlighted: Bool { isFocused && activeState == .key }

    var body: some View {
        HStack(spacing: 7) {
            PaneStatusMark(pane: pane)
                .frame(width: 12)
            Text(pane.title.isEmpty ? "Terminal" : pane.title)
                .font(Style.meta.weight(isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Terminal (⌘W)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: Self.height)
        .background {
            Style.chrome
                .overlay(isHighlighted ? Color.accentColor.opacity(0.14) : .clear)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Close Terminal", onClose)
    }
}

/// What a pane is doing: an idle shell, a running program, or an exit, with its code.
struct PaneStatusMark: View {
    let pane: Pane
    var size = 11.0

    var body: some View {
        switch pane.status {
        case .exited(let code):
            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(code == 0 ? .green : .red)
                .accessibilityLabel(code == 0 ? "Exited" : "Exited with code \(code)")
        case .running where pane.isRunningProgram:
            RunningDot()
        case .running:
            Image(systemName: "terminal")
                .font(.system(size: size))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

struct ExitStrip: View {
    let pane: Pane
    let code: Int32

    var body: some View {
        HStack(spacing: 8) {
            PaneStatusMark(pane: pane, size: 13)
            Text(code == 0 ? "Exited" : "Exited with code \(code)")
                .font(Style.body.weight(.semibold))
            Text("Return restarts the shell. ⌘W closes it.")
                .font(Style.meta)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Style.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}
