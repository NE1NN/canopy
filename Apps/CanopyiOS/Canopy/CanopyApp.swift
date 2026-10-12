import CanopyPhone
import SwiftUI
import Synchronization
import UIKit

@main
struct CanopyApp: App {
    @State private var app = CanopyApp.makeApp()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { app.open($0) }
                .onChange(of: phase, initial: false) { _, phase in
                    switch phase {
                    case .active: app.phaseChanged(to: .active)
                    case .inactive: app.phaseChanged(to: .inactive)
                    case .background: app.phaseChanged(to: .background)
                    @unknown default: break
                    }
                }
                .onAppear { app.launch() }
        }
    }

    @MainActor
    private static func makeApp() -> PhoneApp {
        #if DEBUG
            // The screen tour starts each run unpaired, on settings of its own, and says how Face ID answers.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ScreenTour") {
                let defaults = UserDefaults(suiteName: "ScreenTour")!
                if arguments.contains("-ScreenTourReset") { defaults.removePersistentDomain(forName: "ScreenTour") }
                return PhoneApp(
                    credentials: TourCredentialStore(defaults: defaults), defaults: defaults,
                    authenticator: TourAuthenticator(), phoneName: "iPhone")
            }
        #endif
        return PhoneApp(phoneName: UIDevice.current.name)
    }
}

#if DEBUG
    /// The screen tour's pairing, kept in its own settings rather than the Keychain, so a run starts clean.
    struct TourCredentialStore: CredentialStore, @unchecked Sendable {
        var defaults: UserDefaults

        func load() -> PairedMac? {
            defaults.data(forKey: "paired").flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
        }

        func save(_ mac: PairedMac) throws {
            defaults.set(try JSONEncoder().encode(mac), forKey: "paired")
        }

        func clear() {
            defaults.removeObject(forKey: "paired")
        }
    }

    /// Face ID for the screen tour, which has none: the ask on launch is cancelled, as when the author looks away, so
    /// the lock screen shows, and tapping Unlock passes.
    final class TourAuthenticator: Authenticator {
        private let asked = Mutex(0)

        var isAvailable: Bool { true }

        func authenticate(reason: String) async -> AuthResult {
            asked.withLock { count in
                count += 1
                return count
            } == 1 ? .failed : .success
        }
    }
#endif
