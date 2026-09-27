import Foundation
import Network
import Synchronization

public enum ControlServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path): "Another Canopy is already listening on \(path)."
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
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: ControlServer.Handler
    private let buffer = Mutex(Data())

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
                self.connection.cancel()
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
        for line in lines where !line.isEmpty {
            Task { await self.respond(to: line) }
        }
    }

    private func respond(to line: Data) async {
        let response: ControlResponse
        if let request = try? ControlCodec.decode(ControlRequest.self, from: line) {
            response = await handler(request)
        } else {
            response = .failure(id: "", error: ControlError(code: "bad_request", message: "Request is not valid JSON."))
        }
        guard let data = try? ControlCodec.encodeLine(response) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
