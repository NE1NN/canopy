import CanopyPhone
import Network
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
            // The screen tour starts each run unpaired, on settings of its own, with a stand-in Face ID, and locks as soon
            // as it comes back, so it can check the lock without waiting 5 minutes.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ScreenTour") {
                let defaults = UserDefaults(suiteName: "ScreenTour")!
                if arguments.contains("-ScreenTourReset") { defaults.removePersistentDomain(forName: "ScreenTour") }
                // The fake EC2 the fixture runs on the Mac, over plain HTTP, which only the tour talks to.
                let ec2 = ProcessInfo.processInfo.environment["CANOPY_TOUR_EC2"].flatMap(URL.init(string:))
                return PhoneApp(
                    credentials: TourCredentialStore(defaults: defaults), defaults: defaults,
                    authenticator: TourAuthenticator(), lockGrace: 0, phoneName: "iPhone",
                    http: ec2 == nil ? URLSessionPoster() : TourPoster(),
                    ec2Endpoint: { region in ec2 ?? EC2Start.endpoint(region: region) })
            }
        #endif
        return PhoneApp(phoneName: UIDevice.current.name)
    }
}

#if DEBUG
    /// The screen tour's pairings, kept in its own settings rather than the Keychain, so a run starts clean.
    struct TourCredentialStore: CredentialStore, @unchecked Sendable {
        var defaults: UserDefaults

        private var stored: [PairedServer] {
            defaults.data(forKey: "servers").flatMap { try? JSONDecoder().decode([PairedServer].self, from: $0) } ?? []
        }

        private func store(_ servers: [PairedServer]) {
            defaults.set(try? JSONEncoder().encode(servers), forKey: "servers")
        }

        func loadAll() -> [PairedServer] {
            stored.sorted { $0.pairedAt < $1.pairedAt }
        }

        func save(_ server: PairedServer) throws {
            store(stored.filter { $0.id != server.id } + [server])
        }

        func remove(id: String) {
            store(stored.filter { $0.id != id })
        }
    }

    /// Plain HTTP over a socket for the screen tour's fake EC2 on the Mac, so the app's own requests keep App Transport
    /// Security.
    struct TourPoster: HTTPPosting {
        func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
            let connection = NWConnection(
                host: NWEndpoint.Host(url.host() ?? "127.0.0.1"),
                port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) ?? .http, using: .tcp)
            defer { connection.cancel() }
            connection.start(queue: .global())
            let head =
                [
                    "POST \(url.path().isEmpty ? "/" : url.path()) HTTP/1.1", "Connection: close",
                    "Content-Length: \(body.count)",
                ]
                + headers.map { "\($0.key): \($0.value)" }
            let request = Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: request,
                    completion: .contentProcessed { error in
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    })
            }
            var received = Data()
            while true {
                let (chunk, finished): (Data?, Bool) = try await withCheckedThrowingContinuation { done in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                        if let error { done.resume(throwing: error) } else { done.resume(returning: (data, complete)) }
                    }
                }
                if let chunk { received.append(chunk) }
                if finished || chunk == nil { break }
            }
            let text = String(decoding: received, as: UTF8.self)
            let parts = text.components(separatedBy: "\r\n\r\n")
            let status = parts.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            return (status, Data(parts.dropFirst().joined(separator: "\r\n\r\n").utf8))
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
