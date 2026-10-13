import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation

/// The Mac's end of `app.sock`, as the relay server answers: an acknowledgement, heartbeats, then a reply.
final class FakeMac: Sendable {
    enum Behaviour: Sendable {
        /// Acknowledges, beats once, and replies.
        case reply(RelayReply)
        /// Takes the connection and never answers, as sshd does while the Mac sleeps.
        case silent
    }

    let listener: UnixListener
    let requests = Shared<[RelayRequest]>([])
    private let held = Shared<[UnixConnection]>([])

    init(at path: String, _ behaviour: Behaviour) throws {
        let requests = requests
        let held = held
        listener = try UnixListener(path: path) { connection in
            held.withLock { $0.append(connection) }
            guard let line = try? connection.readLine(deadline: .now + .seconds(10)),
                let request = try? JSONDecoder().decode(RelayRequest.self, from: line)
            else { return }
            requests.withLock { $0.append(request) }
            guard case .reply(let reply) = behaviour else { return }
            try? connection.write(Data("{\"ack\": true}\n{\"alive\": true}\n".utf8), deadline: .now + .seconds(5))
            if var data = try? JSONEncoder().encode(reply) {
                data.append(0x0A)
                try? connection.write(data, deadline: .now + .seconds(5))
            }
            connection.close()
        }
    }

    var count: Int { requests.withLock { $0.count } }

    deinit {
        listener.close()
        held.withLock { $0.forEach { $0.close() } }
    }
}
