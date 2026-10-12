import CanopyPhone
import SwiftUI

struct RootView: View {
    @Environment(PhoneApp.self) private var app

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
        .overlay {
            if app.lock.isLocked || app.lock.isCovered {
                LockView(locked: app.lock.isLocked)
            }
        }
    }
}
