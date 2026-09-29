import AppKit
import SwiftUI

/// Whether the view's window is in full screen. It flips as a transition starts, so the layout moves with the window,
/// and it reads the window once attached, since a window can reopen in full screen.
struct FullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
    }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [
                (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false),
            ].map { name, value in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(value) }
                }
            }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            // Not during the view update that attached this view.
            Task { @MainActor [weak self] in self?.onChange(isFullScreen) }
        }
    }
}
