import CanopySystem
import Foundation
import Synchronization

/// The EC2 instance metadata service, version 2, on loopback: a token for a PUT, then the instance id and region
/// only to requests that carry it.
final class FakeIMDS: Sendable {
    static let token = "imds-token"
    let instanceID: String
    let region: String
    private let listener: Mutex<TCPListener?> = Mutex(nil)
    private let requestLines = Mutex<[String]>([])

    init(instanceID: String = "i-0123456789abcdef0", region: String = "ap-southeast-2") throws {
        self.instanceID = instanceID
        self.region = region
        let started = try TCPListener(address: "127.0.0.1", port: 0) { [weak self] connection in
            self?.serve(connection)
        }
        listener.withLock { $0 = started }
    }

    var port: UInt16 { listener.withLock { $0?.port ?? 0 } }

    /// Each request's first line, in order.
    var requests: [String] { requestLines.withLock { $0 } }

    private func serve(_ connection: TCPConnection) {
        let received = Mutex(Data())
        connection.receive { [weak self] data, _ in
            guard let self, let data else { return }
            let request = received.withLock { buffer -> String? in
                buffer.append(data)
                let text = String(decoding: buffer, as: UTF8.self)
                return text.contains("\r\n\r\n") ? text : nil
            }
            guard let request else { return }
            let reply = self.reply(to: request)
            Task {
                try? await connection.send(Data(reply.utf8))
                connection.close()
            }
        }
    }

    private func reply(to request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        requestLines.withLock { $0.append(first) }
        let hasToken = lines.contains { $0.lowercased() == "x-aws-ec2-metadata-token: \(Self.token)" }
        let body: String?
        switch first {
        case "PUT /latest/api/token HTTP/1.1": body = Self.token
        case "GET /latest/meta-data/instance-id HTTP/1.1" where hasToken: body = instanceID
        case "GET /latest/meta-data/placement/region HTTP/1.1" where hasToken: body = region
        default: body = nil
        }
        guard let body else { return "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n" }
        return "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    deinit {
        listener.withLock { $0?.close() }
    }
}
