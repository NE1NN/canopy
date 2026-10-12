import CanopyPhone
import SwiftUI
import UIKit

/// Shows the lock, or the cover while the app is away, in a window of its own above everything the app shows, sheets
/// such as Settings included, so nothing under it can be read or used.
@MainActor
final class LockWindow {
    private var window: UIWindow?

    func show(_ shown: Bool, in scene: UIWindowScene?, app: PhoneApp) {
        guard shown else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil, let scene else { return }
        // A keyboard would stay above the lock.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: LockView().environment(app))
        window.isHidden = false
        self.window = window
    }
}

/// Reports the window scene a view is shown in.
struct SceneReader: UIViewRepresentable {
    var found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneView {
        SceneView(found: found)
    }

    func updateUIView(_ view: SceneView, context: Context) {}

    final class SceneView: UIView {
        let found: (UIWindowScene) -> Void

        init(found: @escaping (UIWindowScene) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found(scene) }
        }
    }
}
