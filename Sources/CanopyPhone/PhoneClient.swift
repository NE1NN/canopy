import CanopyWire
import Foundation

/// A stream a request started: its first answer, and the events that follow it.
public struct PhoneStream<Result: Sendable>: Sendable {
    public let result: Result
    /// The request's ID, which names the stream to `phone.unsubscribe`.
    public let subscription: String
    public let events: AsyncStream<PhoneEvent>
}

/// Requests and their responses, and events by the stream they belong to, over one connection to the Mac.
public actor PhoneClient {
    private let channel: any PhoneChannel
    private var waiting: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var streams: [String: AsyncStream<PhoneEvent>.Continuation] = [:]
    private var closedWaiters: [CheckedContinuation<Void, Never>] = []
    /// Lines go out through one writer, in the order they were sent, so keys never pass each other.
    private let outgoing: AsyncStream<Data>.Continuation
    public private(set) var isClosed = false

    public init(channel: any PhoneChannel) {
        self.channel = channel
        let (lines, outgoing) = AsyncStream<Data>.makeStream()
        self.outgoing = outgoing
        Task { await self.read() }
        Task { await self.write(lines) }
    }

    public func call<Result: Decodable & Sendable>(_ method: String, as type: Result.Type) async throws -> Result {
        try await send(ControlRequest(method: method)).decode(type)
    }

    public func call<Result: Decodable & Sendable>(
        _ method: String, _ params: some Encodable & Sendable, as type: Result.Type
    ) async throws -> Result {
        try await send(ControlRequest(method: method, params: .from(params))).decode(type)
    }

    public func stream<Result: Decodable & Sendable>(_ method: String, as type: Result.Type) async throws
        -> PhoneStream<Result>
    {
        try await stream(ControlRequest(method: method), as: type)
    }

    public func stream<Result: Decodable & Sendable>(
        _ method: String, _ params: some Encodable & Sendable, as type: Result.Type
    ) async throws -> PhoneStream<Result> {
        try await stream(ControlRequest(method: method, params: .from(params)), as: type)
    }

    /// Asks the Mac to stop a stream, and ends it here.
    public func unsubscribe(_ subscription: String) async throws {
        forget(subscription)
        _ = try await send(
            ControlRequest(
                method: PhoneMethod.unsubscribe, params: .from(PhoneUnsubscribeParams(subscription: subscription))))
    }

    /// Ends a stream here only, for one the Mac ends by itself, such as a reply's Delivered.
    public func forget(_ subscription: String) {
        streams.removeValue(forKey: subscription)?.finish()
    }

    public func close() {
        channel.close()
        closeDown()
    }

    /// Returns once the connection has closed, from either end.
    public func closed() async {
        guard !isClosed else { return }
        await withCheckedContinuation { closedWaiters.append($0) }
    }

    var streamCount: Int { streams.count }
    var waitingCount: Int { waiting.count }

    private func stream<Result: Decodable & Sendable>(_ request: ControlRequest, as type: Result.Type) async throws
        -> PhoneStream<Result>
    {
        // Registered before the request goes, so an event right behind the response has somewhere to wait.
        let (events, continuation) = AsyncStream<PhoneEvent>.makeStream()
        streams[request.id] = continuation
        do {
            let result = try await send(request).decode(type)
            return PhoneStream(result: result, subscription: request.id, events: events)
        } catch {
            forget(request.id)
            throw error
        }
    }

    private func send(_ request: ControlRequest) async throws -> JSONValue {
        guard !isClosed else { throw PhoneTransportError.closed }
        let line = try ControlCodec.encodeLine(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                waiting[request.id] = continuation
                outgoing.yield(line)
            }
        } onCancel: {
            Task { await self.resume(request.id, with: .failure(CancellationError())) }
        }
    }

    private func resume(_ id: String, with result: Result<JSONValue, any Error>) {
        waiting.removeValue(forKey: id)?.resume(with: result)
    }

    private func read() async {
        do {
            for try await line in channel.lines {
                receive(line)
            }
        } catch {}
        closeDown()
    }

    private func write(_ lines: AsyncStream<Data>) async {
        for await line in lines {
            do {
                try await channel.send(line)
            } catch {
                close()
                return
            }
        }
    }

    private func receive(_ line: Data) {
        // A line this phone cannot read, as from a newer Mac, is skipped rather than ending the connection.
        switch try? PhoneMessage(line: line) {
        case .response(let response):
            if let error = response.error {
                resume(response.id, with: .failure(error))
            } else {
                resume(response.id, with: .success(response.result ?? .null))
            }
        case .event(let event):
            streams[event.subscription]?.yield(event)
        case nil:
            break
        }
    }

    private func closeDown() {
        guard !isClosed else { return }
        isClosed = true
        outgoing.finish()
        for continuation in waiting.values {
            continuation.resume(throwing: PhoneTransportError.closed)
        }
        waiting = [:]
        for continuation in streams.values {
            continuation.finish()
        }
        streams = [:]
        for waiter in closedWaiters {
            waiter.resume()
        }
        closedWaiters = []
    }
}
