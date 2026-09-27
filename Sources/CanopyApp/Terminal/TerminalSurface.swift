import AppKit
import CanopyCore
import SwiftUI

/// Shows a pane's terminal with inner padding, since the terminal draws right up to its edges.
/// The terminal view belongs to the pane, so it keeps its screen while its tab or row is out of view.
struct TerminalSurface: NSViewRepresentable {
    let pane: Pane
    var takesFocus = true
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSizeChange: (TerminalSize) -> Void = { _ in }

    func makeNSView(context: Context) -> TerminalContainerView {
        // Only SwiftTermEngine makes the app's panes.
        TerminalContainerView(emulator: pane.emulator as! SwiftTermEmulator)
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.takesFocus = takesFocus
        container.onFocusChange = onFocusChange
        container.onSizeChange = onSizeChange
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.releaseTerminal()
    }
}

final class TerminalContainerView: NSView {
    static let padding = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)

    private let emulator: SwiftTermEmulator
    var takesFocus = true
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSizeChange: (TerminalSize) -> Void = { _ in }
    private var focusObservation: NSKeyValueObservation?

    init(emulator: SwiftTermEmulator) {
        self.emulator = emulator
        super.init(frame: .zero)
        wantsLayer = true
        emulator.view.removeFromSuperview()
        addSubview(emulator.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func releaseTerminal() {
        focusObservation = nil
        if emulator.view.superview === self {
            emulator.view.removeFromSuperview()
        }
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        emulator.view.frame = NSRect(
            x: padding.left, y: padding.bottom,
            width: max(bounds.width - padding.left - padding.right, 0),
            height: max(bounds.height - padding.top - padding.bottom, 0))
        onSizeChange(emulator.size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onFocusChange(window.firstResponder === self.emulator.view)
            }
        }
        // The tab's focused terminal takes the keyboard when it comes into view.
        if takesFocus {
            window?.makeFirstResponder(emulator.view)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        emulator.applyAppearance(effectiveAppearance)
        layer?.backgroundColor = emulator.background.cgColor
    }

    override func updateLayer() {
        layer?.backgroundColor = emulator.background.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Clicks on the padding focus the terminal too.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(emulator.view)
    }
}
