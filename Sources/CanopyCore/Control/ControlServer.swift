import Foundation
import Network
import Synchronization

public enum ControlServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(String)
    case socketPathTooLong(String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path): "Another Canopy is already listening on \(path)."
        case .socketPathTooLong(let path): "Socket path is longer than macOS allows: \(path)"
        }
    }
}

/// Serves newline-delimited JSON requests on a Unix socket. Each connection may send many requests.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "canopy.control-server")
    private let listener: Mutex<NWListener?> = Mutex(nil)

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() async throws {
        // sockaddr_un holds 104 bytes including the terminator. A longer path would bind somewhere else.
        guard socketPath.utf8.count < 104 else { throw ControlServerError.socketPathTooLong(socketPath) }
        if FileManager.default.fileExists(atPath: socketPath) {
            if ControlClient.canConnect(socketPath: socketPath) {
                throw ControlServerError.alreadyRunning(socketPath)
            }
            unlink(socketPath)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        let listener = try NWListener(using: parameters)
        let handler = self.handler
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            ControlConnection(connection: connection, queue: queue, handler: handler).start()
        }
        self.listener.withLock { $0 = listener }

        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        chmod(socketPath, 0o600)
    }

    public func stop() {
        listener.withLock {
            $0?.cancel()
            $0 = nil
        }
        unlink(socketPath)
    }
}

private final class ResumeOnce: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

private final class ControlConnection: Sendable {
    /// A line longer than this is not a request anyone meant to send.
    static let maximumLine = 1 << 20

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: ControlServer.Handler
    private let buffer = Mutex(Data())
    /// The last reply in line. Requests are handled at once but answered in the order they came.
    private let lastReply = Mutex<Task<Void, Never>?>(nil)

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping ControlServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete || error != nil {
                // The client may close its side right after sending, so answer what came in before closing.
                let pending = self.lastReply.withLock { $0 }
                Task {
                    await pending?.value
                    self.connection.cancel()
                }
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        let lines = buffer.withLock { buffer -> [Data] in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
            return lines
        }
        if buffer.withLock({ $0.count > Self.maximumLine }) {
            reply(
                ControlResponse.failure(
                    id: "", error: ControlError(code: "bad_request", message: "Request is too long.")))
            let pending = lastReply.withLock { $0 }
            Task {
                await pending?.value
                self.connection.cancel()
            }
            return
        }
        for line in lines where !line.isEmpty {
            let response = Task { await self.response(to: line) }
            lastReply.withLock { last in
                let previous = last
                last = Task {
                    await previous?.value
                    await self.send(await response.value)
                }
            }
        }
    }

    private func reply(_ response: ControlResponse) {
        lastReply.withLock { last in
            let previous = last
            last = Task {
                await previous?.value
                await self.send(response)
            }
        }
    }

    private func response(to line: Data) async -> ControlResponse {
        guard let request = try? ControlCodec.decode(ControlRequest.self, from: line) else {
            return .failure(id: "", error: ControlError(code: "bad_request", message: "Request is not valid JSON."))
        }
        return await handler(request)
    }

    /// Returns once the reply has left, so closing the connection afterwards cannot drop it.
    private func send(_ response: ControlResponse) async {
        guard let data = try? ControlCodec.encodeLine(response) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
