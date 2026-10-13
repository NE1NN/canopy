import CanopySystem
import Foundation
import Synchronization

/// Which EC2 instance the box is, and in which region.
public struct InstanceIdentity: Codable, Sendable, Equatable {
    public var instanceID: String
    public var region: String

    public init(instanceID: String, region: String) {
        self.instanceID = instanceID
        self.region = region
    }
}

/// The EC2 instance metadata service, version 2: a session token first, then each value with it. Plain HTTP on a
/// link-local address, so it needs nothing beyond a TCP socket.
public enum InstanceMetadata {
    public static let address = "169.254.169.254"
    public static let port: UInt16 = 80

    /// The instance, or nil off EC2 or when the service does not answer within `timeout` for each request.
    public static func identity(
        address: String = address, port: UInt16 = port, timeout: Duration = .seconds(2)
    ) async -> InstanceIdentity? {
        guard
            let token = try? await request(
                "PUT", "/latest/api/token", headers: ["X-aws-ec2-metadata-token-ttl-seconds": "60"],
                address: address, port: port, timeout: timeout),
            token.status == 200, !token.body.isEmpty
        else { return nil }
        let headers = ["X-aws-ec2-metadata-token": token.body]
        guard
            let instance = try? await request(
                "GET", "/latest/meta-data/instance-id", headers: headers, address: address, port: port,
                timeout: timeout),
            instance.status == 200,
            let region = try? await request(
                "GET", "/latest/meta-data/placement/region", headers: headers, address: address, port: port,
                timeout: timeout),
            region.status == 200
        else { return nil }
        let id = instance.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = region.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return InstanceIdentity(instanceID: id, region: name)
    }

    struct Response: Sendable, Equatable {
        var status: Int
        var body: String
    }

    struct TimedOut: Error {}

    /// One request on a connection of its own, read to its end. Gives up after `timeout`, without waiting for a
    /// connect() that hangs: that ends on its own thread, and its connection closes as soon as it has one.
    static func request(
        _ method: String, _ path: String, headers: [String: String], address: String, port: UInt16,
        timeout: Duration
    ) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let work = Task {
                answer.give(
                    await Result { try await exchange(method, path, headers: headers, address: address, port: port) })
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                work.cancel()
                answer.give(.failure(TimedOut()))
            }
            Task {
                _ = await work.value
                timer.cancel()
            }
        }
    }

    /// Resumes its continuation with the first result it is given, and ignores the rest.
    private final class FirstAnswer: Sendable {
        private let continuation: Mutex<CheckedContinuation<Response, any Error>?>

        init(_ continuation: CheckedContinuation<Response, any Error>) {
            self.continuation = Mutex(continuation)
        }

        func give(_ result: Result<Response, any Error>) {
            continuation.withLock { $0.take() }?.resume(with: result)
        }
    }

    private static func exchange(
        _ method: String, _ path: String, headers: [String: String], address: String, port: UInt16
    ) async throws -> Response {
        // connect() blocks, and off EC2 the address may never answer, so it runs on a thread of its own.
        let connection = try await onOwnThread {
            Result { try TCPConnection.connect(to: address, port: port) }
        }.get()
        guard !Task.isCancelled else {
            connection.close()
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            let (chunks, sink) = AsyncThrowingStream.makeStream(of: Data.self)
            connection.receive { data, error in
                if let data { sink.yield(data) } else { sink.finish(throwing: error) }
            }
            let lines =
                ["\(method) \(path) HTTP/1.1", "Host: \(address)", "Connection: close", "Content-Length: 0"]
                + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            try await connection.send(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
            var received = Data()
            for try await chunk in chunks {
                received.append(chunk)
                guard received.count < 64 * 1024 else { break }
            }
            connection.close()
            return try parse(received)
        } onCancel: {
            connection.close()
        }
    }

    struct Malformed: Error {}

    /// The status and body of an HTTP/1.1 response that ends when the connection does.
    static func parse(_ data: Data) throws -> Response {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { throw Malformed() }
        let head = text[..<split.lowerBound]
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { throw Malformed() }
        let fields = lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        // The service sends a length; a chunked body would read as its chunk sizes.
        if fields.contains(where: { $0.0 == "transfer-encoding" }) { throw Malformed() }
        var body = Substring(text[split.upperBound...])
        if let length = fields.first(where: { $0.0 == "content-length" }).flatMap({ Int($0.1) }) {
            body = Substring(String(decoding: Data(body.utf8).prefix(length), as: UTF8.self))
        }
        return Response(status: status, body: String(body))
    }
}
