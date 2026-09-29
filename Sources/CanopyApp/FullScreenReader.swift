import AppKit
import SwiftUI

/// Whether the view's window is in full screen. It flips as a transition starts, so the layout moves with the window,
/// and reads the window again once it settles, since a transition can fail and a window can reopen in full screen.
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
            let center = NotificationCenter.default
            let starts: [(Notification.Name, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false),
            ]
            observers = starts.map { name, value in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(value) }
                }
            }
            let settles = [
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didResizeNotification,
            ]
            observers += settles.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readWindow() }
                }
            }
            // Not during the view update that attached this view.
            Task { @MainActor [weak self] in self?.readWindow() }
        }

        private func readWindow() {
            guard let window else { return }
            onChange(window.styleMask.contains(.fullScreen))
        }
    }
}
