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
            PaneHeader(title: pane.title, isFocused: isFocused, onClose: onClose)
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
                ExitStrip(code: code)
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
    static let height = 24.0

    let title: String
    let isFocused: Bool
    let onClose: () -> Void
    @Environment(\.controlActiveState) private var activeState

    private var isHighlighted: Bool { isFocused && activeState == .key }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.isEmpty ? "Terminal" : title)
                .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close Terminal (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

struct ExitStrip: View {
    let code: Int32

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(code == 0 ? .green : .red)
            Text("exited (code \(code))")
                .fontWeight(.medium)
            Text("Return restarts the shell. ⌘W closes the terminal.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}
