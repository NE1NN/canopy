import CanopyAgents
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation

/// The Mac's end of `box.sock`, for tests: requests and the events a subscription sends.
final class BoxClient: Sendable {
    let connection: UnixConnection
    private let events = Shared<[BoxEvent]>([])

    init(path: String) throws {
        connection = try UnixConnection.connect(path: path)
    }

    deinit { connection.close() }

    /// Sends a request and reads lines until its response, keeping events that come first.
    func call(_ method: String, _ params: (some Encodable)? = nil as Bool?) async throws -> ControlResponse {
        let request = ControlRequest(method: method, params: try params.map { try JSONValue.from($0) })
        let connection = connection
        let events = events
        return try await offPool {
            try connection.write(try ControlCodec.encodeLine(request), deadline: .now + .seconds(10))
            while true {
                guard let line = try connection.readLine(deadline: .now + .seconds(20)) else {
                    throw UnixSocketError.closed
                }
                switch try BoxMessage(line: line) {
                case .response(let response) where response.id == request.id: return response
                case .response: continue
                case .event(let event): events.withLock { $0.append(event) }
                }
            }
        }
    }

    /// The next snapshot event, from those kept or the connection, within `timeout`.
    func nextSnapshot(timeout: Duration = .seconds(20)) async throws -> BoxSnapshot? {
        if let kept = events.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            return try kept.data.decode(BoxSnapshot.self)
        }
        let connection = connection
        return try await offPool {
            guard let line = try connection.readLine(deadline: .now + timeout),
                case .event(let event) = try BoxMessage(line: line)
            else { return nil }
            return try event.data.decode(BoxSnapshot.self)
        }
    }

    /// Sends a raw line and reads the next one.
    func exchange(_ line: String) async throws -> String? {
        let connection = connection
        return try await offPool {
            try connection.write(Data((line + "\n").utf8), deadline: .now + .seconds(10))
            return try connection.readLine(deadline: .now + .seconds(20)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func readLine() async throws -> String? {
        let connection = connection
        return try await offPool {
            try connection.readLine(deadline: .now + .seconds(20)).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}
