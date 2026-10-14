import Foundation
import Network
import Synchronization

/// Lines over TCP. Keepalive notices a Mac that vanished without closing, such as one that went to sleep.
public struct TCPTransport: PhoneTransport {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    public func connect(host: String, port: UInt16) async throws -> any PhoneChannel {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw PhoneTransportError.refused }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 4
        tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: nil, tcp: tcp))
        let channel = TCPChannel(connection: connection)
        try await channel.open(timeout: timeout)
        return channel
    }
}

final class TCPChannel: PhoneChannel {
    let lines: AsyncThrowingStream<Data, any Error>
    private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.ne1nn.Canopy.Phone.tcp")
    /// Set once the connection opened or failed to, so its state changes resume the opener only once.
    private let opening = Mutex<CheckedContinuation<Void, any Error>?>(nil)
    private let isClosed = Mutex(false)

    init(connection: NWConnection) {
        self.connection = connection
        (lines, incoming) = AsyncThrowingStream.makeStream()
    }

    func open(timeout: Duration) async throws {
        // An abandoned attempt closes now, rather than at its timeout or never, should it connect after all.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                opening.withLock { $0 = continuation }
                if Task.isCancelled {
                    finishOpening(.failure(CancellationError()))
                    return
                }
                connection.stateUpdateHandler = { [weak self] state in self?.changed(to: state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
                    self?.finishOpening(.failure(PhoneTransportError.timedOut))
                }
            }
        } onCancel: {
            finishOpening(.failure(CancellationError()))
        }
        receive(after: Data())
    }

    private func changed(to state: NWConnection.State) {
        switch state {
        case .ready:
            finishOpening(.success(()))
        // A connection that cannot be made yet waits for the network to change; the phone retries on its own instead.
        case .waiting(let error), .failed(let error):
            if finishOpening(.failure(Self.transportError(error))) { return }
            end(throwing: nil)
        case .cancelled:
            finishOpening(.failure(PhoneTransportError.closed))
            end(throwing: nil)
        default:
            break
        }
    }

    /// Whether this resumed the opener, which happens once.
    @discardableResult
    private func finishOpening(_ result: Result<Void, any Error>) -> Bool {
        guard
            let continuation = opening.withLock({ continuation in
                defer { continuation = nil }; return continuation
            })
        else { return false }
        if case .failure = result { connection.cancel() }
        continuation.resume(with: result)
        return true
    }

    private static func transportError(_ error: NWError) -> PhoneTransportError {
        switch error {
        case .posix(.ECONNREFUSED): .refused
        case .posix(.ETIMEDOUT): .timedOut
        default: .unreachable(error.localizedDescription)
        }
    }

    private func receive(after pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = pending
            if let data { buffer.append(data) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { incoming.yield(Data(line)) }
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
            if isComplete || error != nil {
                end(throwing: nil)
            } else {
                receive(after: buffer)
            }
        }
    }

    private func end(throwing error: (any Error)?) {
        isClosed.withLock { $0 = true }
        incoming.finish(throwing: error)
    }

    func send(_ line: Data) async throws {
        guard !isClosed.withLock({ $0 }) else { throw PhoneTransportError.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: line,
                completion: .contentProcessed { error in
                    if error != nil {
                        continuation.resume(throwing: PhoneTransportError.closed)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    func close() {
        connection.cancel()
        end(throwing: nil)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
