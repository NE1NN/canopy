import CanopyPhone
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PhoneApp.self) private var app
    @State private var scene: UIWindowScene?
    @State private var lockWindow = LockWindow()

    var body: some View {
        Group {
            if app.connection.paired == nil {
                PairingView()
            } else {
                TabView {
                    Tab("Inbox", systemImage: "tray") {
                        InboxView()
                    }
                    .badge(app.inbox.waitingCount)
                    .accessibilityIdentifier("tab-inbox")
                    Tab("Rows", systemImage: "line.3.horizontal") {
                        RowsView()
                    }
                    .accessibilityIdentifier("tab-rows")
                }
            }
        }
        .background(SceneReader { scene = $0 })
        .onChange(of: covered, initial: true) { _, covered in
            lockWindow.show(covered, in: scene, app: app)
        }
        .onChange(of: scene) { _, scene in
            lockWindow.show(covered, in: scene, app: app)
        }
    }

    private var covered: Bool {
        app.lock.isLocked || app.lock.isCovered
    }
}
