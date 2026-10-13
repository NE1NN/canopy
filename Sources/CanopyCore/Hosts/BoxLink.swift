import Foundation

/// The Mac's line to `canopy-box` on one host, through a socket the host's ssh master forwards to `box.sock`.
/// While started, it connects, says hello, sends the Mac's settings, subscribes, and answers calls, and connects again a
/// second after it loses the daemon, as when it restarts or the master drops, each time with a fresh snapshot.
public actor BoxLink {
    public nonisolated let alias: String
    let socketPath: String
    private let config: @Sendable () -> BoxConfig
    private var connection: UnixConnection?
    private var pending: [String: CheckedContinuation<ControlResponse, any Error>] = [:]
    /// Each call's timeout, cancelled once it is answered.
    private var timers: [String: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<BoxSnapshot>.Continuation] = [:]
    private var latest: BoxSnapshot?
    private var running: Task<Void, Never>?
    private var connectedWaiters: [CheckedContinuation<Void, Never>] = []
    /// Said hello, configured, and subscribed.
    private var ready = false

    /// How long a call waits for its answer, except `box.wait`, which takes as long as its own timeout.
    static let callWait = Duration.seconds(120)

    /// `config` gives the Mac's settings for the host each time the link connects.
    public init(alias: String, socketPath: String, config: @escaping @Sendable () -> BoxConfig) {
        self.alias = alias
        self.socketPath = socketPath
        self.config = config
    }

    public var isConnected: Bool { ready }

    /// The latest snapshot, if the link has had one.
    public var snapshot: BoxSnapshot? { latest }

    public func start() {
        guard running == nil else { return }
        running = Task { await self.keepConnected() }
    }

    public func stop() {
        running?.cancel()
        running = nil
        drop()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    /// The latest snapshot at once, if there is one, then each new one.
    public func snapshots() -> AsyncStream<BoxSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: BoxSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.forget(id) } }
        if let latest { continuation.yield(latest) }
        return stream
    }

    /// Returns once the link is connected, or after `limit`. Returns whether it is.
    public func waitUntilConnected(within limit: Duration) async -> Bool {
        if ready { return true }
        let timer = Task {
            try? await Task.sleep(for: limit)
            self.wakeConnectedWaiters()
        }
        await withCheckedContinuation { connectedWaiters.append($0) }
        timer.cancel()
        return ready
    }

    /// Calls a method and decodes its result. Fails as `host_unreachable` without a link, and with the daemon's own
    /// error when it refuses.
    public func call<Result: Decodable>(
        _ method: String, _ params: some Encodable, as: Result.Type = Result.self
    ) async throws -> Result {
        let response = try await send(method, params: try JSONValue.from(params))
        if let error = response.error { throw error }
        return try (response.result ?? .null).decode(Result.self)
    }

    private func send(_ method: String, params: JSONValue) async throws -> ControlResponse {
        guard let connection else { throw notConnected() }
        let request = ControlRequest(method: method, params: params)
        let line = try ControlCodec.encodeLine(request)
        let id = request.id
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                let written = await onOwnThread { (try? connection.write(line, deadline: .now + .seconds(10))) != nil }
                if !written { self.fail(id, with: self.notConnected()) }
            }
            // A wait and a pairing take as long as they take: a pairing code lasts five minutes.
            if method != BoxMethod.wait, method != BoxMethod.phonesPaired {
                timers[id] = Task {
                    try? await Task.sleep(for: Self.callWait)
                    guard !Task.isCancelled else { return }
                    self.fail(
                        id, with: WorkspaceError.hostUnreachable(self.alias, reason: "canopy-box did not answer."))
                }
            }
        }
    }

    private nonisolated func notConnected() -> WorkspaceError {
        .hostUnreachable(alias, reason: "Canopy on \(alias) is not connected.")
    }

    private func fail(_ id: String, with error: any Error) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func keepConnected() async {
        while !Task.isCancelled {
            if let connection = try? UnixConnection.connect(path: socketPath) {
                await session(on: connection)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// One connection, from hello to its end.
    private func session(on connection: UnixConnection) async {
        let (lines, sink) = AsyncStream.makeStream(of: Data.self)
        let reader = Thread {
            while let line = try? connection.readLine(deadline: nil) {
                if !line.isEmpty { sink.yield(line) }
            }
            sink.finish()
        }
        reader.name = "canopy.box-link"
        reader.start()
        self.connection = connection
        let handling = Task {
            for await line in lines { self.received(line) }
            // The daemon went, so calls waiting on it fail now rather than at their timeout.
            self.ended(connection)
        }
        do {
            let hello: BoxHelloResult = try await call(BoxMethod.hello, BoxHelloParams(version: CanopyVersion.current))
            guard hello.protocolVersion == BoxProtocol.version else { throw notConnected() }
            let _: Bool = try await call(BoxMethod.configure, config())
            let _: Bool = try await call(BoxMethod.subscribe, JSONValue.object([:]))
            ready = true
            wakeConnectedWaiters()
        } catch {
            connection.close()
        }
        await handling.value
        if self.connection === connection { drop() }
    }

    private func received(_ line: Data) {
        guard let message = try? BoxMessage(line: line) else { return }
        switch message {
        case .response(let response):
            timers.removeValue(forKey: response.id)?.cancel()
            pending.removeValue(forKey: response.id)?.resume(returning: response)
        case .event(let event) where event.event == BoxEvent.snapshot:
            guard let snapshot = try? event.data.decode(BoxSnapshot.self) else { return }
            latest = snapshot
            for observer in observers.values { observer.yield(snapshot) }
        case .event:
            break
        }
    }

    private func ended(_ ended: UnixConnection) {
        if connection === ended { drop() }
    }

    private func drop() {
        ready = false
        connection?.close()
        connection = nil
        let failed = pending
        pending.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for continuation in failed.values { continuation.resume(throwing: notConnected()) }
    }

    private func wakeConnectedWaiters() {
        let waiters = connectedWaiters
        connectedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }
}
