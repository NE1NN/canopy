import CanopyWire
import Foundation
import Synchronization

@testable import CanopyPhone

/// A channel whose other end is the test: it reads what the client sent and writes what the Mac would.
final class PipeChannel: PhoneChannel {
    let lines: AsyncThrowingStream<Data, any Error>
    private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
    private let sent = Mutex<[Data]>([])
    private let isClosed = Mutex(false)

    init() {
        (lines, incoming) = AsyncThrowingStream.makeStream()
    }

    func send(_ line: Data) async throws {
        guard !isClosed.withLock({ $0 }) else { throw PhoneTransportError.closed }
        sent.withLock { $0.append(line) }
    }

    func close() {
        isClosed.withLock { $0 = true }
        incoming.finish()
    }

    /// What the client sent, as requests.
    var requests: [ControlRequest] {
        sent.withLock { $0 }.compactMap { try? ControlCodec.decode(ControlRequest.self, from: $0) }
    }

    func request(_ method: String) async -> ControlRequest? {
        _ = await eventually { requests.contains { $0.method == method } }
        return requests.last { $0.method == method }
    }

    func respond(to request: ControlRequest, _ result: some Encodable) throws {
        try write(ControlResponse.success(id: request.id, result: .from(result)))
    }

    func fail(_ request: ControlRequest, code: String) throws {
        try write(ControlResponse.failure(id: request.id, error: ControlError(code: code, message: "\(code) message")))
    }

    func emit(_ event: String, subscription: String, _ data: some Encodable) throws {
        try write(PhoneEvent(event: event, subscription: subscription, data: .from(data)))
    }

    func write(_ message: some Encodable) throws {
        incoming.yield(try ControlCodec.encodeLine(message).dropLast())
    }

    func writeRaw(_ text: String) {
        incoming.yield(Data(text.utf8))
    }

    /// The Mac goes away.
    func drop(_ error: (any Error)? = nil) {
        incoming.finish(throwing: error)
    }
}
