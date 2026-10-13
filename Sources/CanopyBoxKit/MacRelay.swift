import CanopySystem
import CanopyWire
import Foundation

/// Passes a box CLI call the box does not answer to Canopy on the Mac, through the Mac's socket the ssh master forwards
/// to `app.sock`, as the host's relay would have sent it.
public enum MacRelay {
    public static let notConnected = "This needs Canopy on the Mac, which isn't connected."
    static let unreachable = "Canopy is not reachable from this host right now."
    /// sshd accepts a connection on the forwarded socket even while the Mac sleeps, so silence this long means the
    /// call never reached the app.
    public static let acknowledgementWait = Duration.seconds(10)
    /// The app beats every 15 seconds while a call runs, so a call that hears nothing for this long gives up.
    static let replySilence = Duration.seconds(45)

    /// The Mac's reply, or a failure saying it is not connected when nothing listens there or the app does not
    /// acknowledge the call in time. A cancelled task closes the call, which stops the CLI on the Mac.
    public static func forward(
        _ request: RelayRequest, appSocket: String, acknowledgementWait: Duration = acknowledgementWait
    ) async -> RelayReply {
        guard let connection = try? UnixConnection.connect(path: appSocket) else { return .failure(notConnected) }
        return await withTaskCancellationHandler {
            await onOwnThread { call(request, on: connection, acknowledgementWait: acknowledgementWait) }
        } onCancel: {
            connection.close()
        }
    }

    private static func call(_ request: RelayRequest, on connection: UnixConnection, acknowledgementWait: Duration)
        -> RelayReply
    {
        defer { connection.close() }
        guard var line = try? JSONEncoder().encode(request) else { return .failure(unreachable) }
        line.append(0x0A)
        let first: Data
        do {
            try connection.write(line, deadline: .now + acknowledgementWait)
            guard let read = try connection.readLine(deadline: .now + acknowledgementWait) else {
                return .failure(notConnected)
            }
            first = read
        } catch {
            return .failure(notConnected)
        }
        // A reply without an acknowledgement means the app ran nothing, as for a relay of another version.
        guard isAcknowledgement(first) else { return reply(from: first) }
        while true {
            guard let next = try? connection.readLine(deadline: .now + replySilence) else {
                return .failure(unreachable)
            }
            if !isHeartbeat(next) { return reply(from: next) }
        }
    }

    private static func isAcknowledgement(_ line: Data) -> Bool {
        flag(line) == "ack"
    }

    private static func isHeartbeat(_ line: Data) -> Bool {
        flag(line) == "alive"
    }

    /// The key of a one-key object whose value is true, such as `{"ack": true}`.
    private static func flag(_ line: Data) -> String? {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: line), object.count == 1,
            let (key, value) = object.first, value == .bool(true)
        else { return nil }
        return key
    }

    private static func reply(from line: Data) -> RelayReply {
        (try? JSONDecoder().decode(RelayReply.self, from: line)) ?? .failure(unreachable)
    }
}
