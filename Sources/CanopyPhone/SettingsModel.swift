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

    /// What New task runs there, or nil from a server older than New task.
    public var agentCommand: String? { connection.server.agentCommand }

    /// How the command changes, from the Mac, or why there is none.
    public var agentHint: String {
        guard agentCommand != nil else { return "Update Canopy on \(name) to start tasks on it from here." }
        let command = isBox ? "canopy phone agent --on \(name) \"<command>\"" : "canopy phone agent \"<command>\""
        return "New task runs this with the brief. Change it with \(command) on the Mac."
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
