import SwiftUI
import UIKit

extension View {
    /// What the back button says on screens pushed from this one, which SwiftUI otherwise takes from the title.
    func backButtonTitle(_ title: String) -> some View {
        background(BackButtonTitleSetter(title: title).frame(width: 0, height: 0))
    }
}

private struct BackButtonTitleSetter: UIViewControllerRepresentable {
    var title: String

    func makeUIViewController(context: Context) -> Controller {
        Controller(title: title)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.backTitle = title
        controller.apply()
    }

    final class Controller: UIViewController {
        var backTitle: String

        init(title: String) {
            backTitle = title
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        /// The screen's own controller is the nearest ancestor a navigation controller holds.
        func apply() {
            var controller = parent
            while let current = controller, !(current.parent is UINavigationController) {
                controller = current.parent
            }
            controller?.navigationItem.backButtonTitle = backTitle
        }
    }
}
