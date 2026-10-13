import CanopyPhone
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PhoneApp.self) private var app
    @State private var scene: UIWindowScene?
    @State private var lockWindow = LockWindow()
    @State private var tab = AppTab.inbox

    var body: some View {
        Group {
            if app.connection.paired == nil {
                PairingView()
            } else {
                TabView(selection: $tab) {
                    Tab("Inbox", systemImage: "tray", value: AppTab.inbox) {
                        InboxView()
                    }
                    .badge(app.inbox.badgeCount)
                    .accessibilityIdentifier("tab-inbox")
                    Tab("Rows", systemImage: "line.3.horizontal", value: AppTab.rows) {
                        RowsView()
                    }
                    .accessibilityIdentifier("tab-rows")
                }
                .environment(\.showRows, ShowRowsAction { tab = .rows })
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

enum AppTab: Hashable {
    case inbox, rows
}

/// Switches to the Rows tab, for the Inbox's All caught up.
struct ShowRowsAction {
    var show: @MainActor () -> Void

    @MainActor func callAsFunction() {
        show()
    }
}

extension EnvironmentValues {
    @Entry var showRows = ShowRowsAction {}
}
