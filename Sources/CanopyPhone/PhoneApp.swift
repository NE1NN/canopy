import CanopyWire
import Foundation
import Observation

/// Everything the app's screens share, and what happens as the app comes and goes.
@MainActor @Observable
public final class PhoneApp {
    public let connection: MacConnection
    public let pins: PinStore
    public let lock: AppLock
    public let inbox: InboxModel
    public let rows: RowsModel
    public let pairing: PairingModel

    public init(
        transport: any PhoneTransport = TCPTransport(), credentials: any CredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = .standard, authenticator: any Authenticator = LocalAuthenticator(),
        phoneName: String
    ) {
        connection = MacConnection(transport: transport, credentials: credentials, phoneName: phoneName)
        pins = PinStore(defaults: defaults)
        lock = AppLock(defaults: defaults, authenticator: authenticator)
        inbox = InboxModel(connection: connection, pins: pins)
        rows = RowsModel(connection: connection)
        pairing = PairingModel(connection: connection)
    }

    public func launch() {
        lock.isGuarding = connection.paired != nil
        lock.launch()
        connection.start()
        inbox.start()
        rows.start()
    }

    public func open(_ url: URL) {
        guard url.scheme == PairingLink.scheme else { return }
        Task { await pairing.pair(url) }
    }

    public func phaseChanged(to phase: AppLock.Phase) {
        lock.isGuarding = connection.paired != nil
        lock.phaseChanged(to: phase)
        switch phase {
        case .background: connection.background()
        case .active: connection.foreground()
        case .inactive: break
        }
    }
}
