import CanopyWire
import Foundation
import Observation

/// Settings: the paired servers, and removing one. The lock's switch binds to `AppLock` itself.
@MainActor @Observable
public final class SettingsModel {
    public let servers: Servers

    public init(servers: Servers) {
        self.servers = servers
    }

    /// Every server, in pairing order, including any that forgot this phone.
    public var list: [ServerSettings] { servers.connections.map(ServerSettings.init) }

    public func remove(id: String) {
        servers.remove(id: id)
    }
}

/// One server as Settings shows it.
@MainActor
public struct ServerSettings: Identifiable {
    public let connection: ServerConnection

    public init(_ connection: ServerConnection) {
        self.connection = connection
    }

    public nonisolated var id: String { connection.id }
    public var name: String { connection.name }
    public var isBox: Bool { connection.isBox }
    public var kindText: String { isBox ? "Host" : "Mac" }
    public var host: String { connection.server.host }
    public var address: String? { connection.server.address.flatMap { $0 == host ? nil : $0 } }
    public var phone: String { connection.server.phone }
    public var version: String? { connection.server.version }
    /// The instance a box's wake key starts, and its region, or nil without a key.
    public var wakeInstance: String? {
        connection.server.wake.map { "\($0.instanceID) in \($0.region)" }
    }

    public var statusText: String {
        switch connection.status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .unreachable: "Can't reach \(name)"
        case .unpaired: "No longer paired"
        }
    }

    /// Removing forgets the server here. Only the Mac can revoke the token.
    public var removeHint: String {
        let command = isBox ? "canopy phone remove \"\(phone)\" --on \(name)" : "canopy phone remove \"\(phone)\""
        return isBox
            ? "\(name) still lists this iPhone until you run \(command) on the Mac."
            : "\(name) still lists this iPhone until you run \(command) there."
    }
}
