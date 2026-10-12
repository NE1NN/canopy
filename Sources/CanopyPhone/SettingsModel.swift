import Foundation
import Observation

/// Settings: the paired Mac and unpairing. The lock's switch binds to `AppLock` itself.
@MainActor @Observable
public final class SettingsModel {
    public let connection: MacConnection

    public init(connection: MacConnection) {
        self.connection = connection
    }

    public var mac: String { connection.macName }
    public var host: String? { connection.paired?.host }
    public var address: String? { connection.paired?.address.flatMap { $0 == host ? nil : $0 } }
    public var phone: String? { connection.paired?.phone }
    public var version: String? { connection.paired?.version }

    public var statusText: String {
        switch connection.status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .unreachable: "Can't reach \(mac)"
        }
    }

    /// Unpairing forgets the Mac here. Only the Mac can revoke the token.
    public var removeHint: String {
        "\(mac) still lists this iPhone until you run canopy phone remove \"\(phone ?? "iPhone")\" there."
    }

    public func unpair() {
        connection.unpair()
    }
}
