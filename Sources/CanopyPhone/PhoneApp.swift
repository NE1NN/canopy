import CanopyWire
import Foundation
import Observation

/// Everything the app's screens share, and what happens as the app comes and goes.
@MainActor @Observable
public final class PhoneApp {
    public let servers: Servers
    public let lock: AppLock
    public let inbox: InboxModel
    public let rows: RowsModel
    public let pairing: PairingModel
    public let waker: Waker

    public init(
        transport: any PhoneTransport = TCPTransport(), credentials: any CredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = .standard, authenticator: any Authenticator = LocalAuthenticator(),
        lockGrace: TimeInterval = AppLock.standardGrace, phoneName: String,
        http: any HTTPPosting = URLSessionPoster(), ec2Endpoint: @escaping @Sendable (String) -> URL = EC2Start.endpoint
    ) {
        servers = Servers(transport: transport, credentials: credentials, phoneName: phoneName)
        lock = AppLock(defaults: defaults, authenticator: authenticator, grace: lockGrace)
        inbox = InboxModel(servers: servers)
        rows = RowsModel(servers: servers)
        pairing = PairingModel(servers: servers)
        waker = Waker(http: http, endpoint: ec2Endpoint)
    }

    public func launch() {
        lock.isGuarding = servers.isPaired
        lock.launch()
        servers.start()
        rows.start()
    }

    public func open(_ url: URL) {
        guard url.scheme == PairingLink.scheme else { return }
        Task { await pairing.pair(url) }
    }

    public func phaseChanged(to phase: AppLock.Phase) {
        lock.isGuarding = servers.isPaired
        lock.phaseChanged(to: phase)
        switch phase {
        case .background: servers.background()
        case .active: servers.foreground()
        case .inactive: break
        }
    }
}
