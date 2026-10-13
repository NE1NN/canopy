import CanopyAgents
import CanopyServer
import CanopySystem
import CanopyWire
import Dispatch
import Foundation
import Synchronization

/// canopy-box's socket, `box.sock`, which the Mac reaches through its ssh master and the host's relay reaches locally.
/// A line with `method` is a control request: answered when done, with `box.subscribe` sending snapshots after.
/// A line with `args` is a relayed CLI call, framed as the Mac's relay server frames it: an acknowledgement at once,
/// a heartbeat every 15 seconds, then the reply, so the host's relay script works unchanged against either.
public final class BoxServer: Sendable {
    let daemon: BoxDaemon
    private let listener: UnixListener
    static let heartbeatEvery = Duration.seconds(15)
    /// How long a write may wait for a peer to read, before the connection is given up.
    public static let writeWait = Duration.seconds(60)

    /// The connections being served, which closing the server ends.
    private let open = OpenConnections()

    /// `phones` is the box's phone server, which the Mac's `phone ... --on` reaches through these methods.
    public init(
        daemon: BoxDaemon, socketPath: String, writeWait: Duration = writeWait, phones: PhoneServer? = nil
    ) throws {
        self.daemon = daemon
        let open = open
        listener = try UnixListener(path: socketPath) { connection in
            open.all.withLock { $0[ObjectIdentifier(connection)] = connection }
            defer { _ = open.all.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) } }
            Self.serve(
                connection, daemon: daemon, phones: phones, writer: ConnectionWriter(connection, wait: writeWait))
        }
    }

    /// Stops listening and ends every connection, as the daemon stopping does.
    public func close() {
        listener.close()
        for connection in open.all.withLock({ Array($0.values) }) { connection.close() }
    }

    private final class OpenConnections: Sendable {
        let all = Mutex<[ObjectIdentifier: UnixConnection]>([:])
    }

    /// Reads the connection's lines until it closes, on the connection's own thread. A client may stop sending right
    /// after its last request, as `printf ... | nc -U` does, so calls already under way still answer before the
    /// connection closes. A subscription ends with the client's sending, since its client keeps that open while it
    /// listens, and one that went away would otherwise hold this thread until the box next changed.
    private static func serve(
        _ connection: UnixConnection, daemon: BoxDaemon, phones: PhoneServer?, writer: ConnectionWriter
    ) {
        let work = Mutex<[Task<Void, Never>]>([])
        let subscriptions = Mutex<[Task<Void, Never>]>([])
        defer {
            for subscription in subscriptions.withLock({ $0 }) { subscription.cancel() }
            // A client gone altogether hears no answers, so its calls stop; one that only stopped sending still reads.
            if connection.peerClosed() {
                for task in work.withLock({ $0 }) { task.cancel() }
            }
            let finished = DispatchSemaphore(value: 0)
            let pending = work.withLock { $0 }
            Task {
                for task in pending { await task.value }
                finished.signal()
            }
            finished.wait()
            writer.flush()
            connection.close()
        }
        while let line = try? connection.readLine(deadline: nil) {
            guard !line.isEmpty else { continue }
            let keys = try? JSONDecoder().decode([String: JSONValue].self, from: line)
            if keys?["args"] != nil, let request = try? JSONDecoder().decode(RelayRequest.self, from: line) {
                relay(request, on: connection, daemon: daemon)
                return
            }
            guard let request = try? ControlCodec.decode(ControlRequest.self, from: line) else {
                send(
                    ControlResponse.failure(
                        id: "", error: ControlError(code: "bad_request", message: "Request is not valid JSON.")),
                    with: writer)
                continue
            }
            if request.method == BoxMethod.subscribe {
                let task = Task { await subscribe(request, with: writer, daemon: daemon) }
                subscriptions.withLock { $0.append(task) }
            } else {
                let task = Task { send(await handle(request, daemon: daemon, phones: phones), with: writer) }
                work.withLock { $0.append(task) }
            }
        }
    }

    /// Runs a relayed CLI call to its end, beating while it runs, and cancels it once the relay hangs up, except a
    /// hook's report, which is the box's from its acknowledgement on.
    private static func relay(_ request: RelayRequest, on connection: UnixConnection, daemon: BoxDaemon) {
        guard (try? connection.write(Data("{\"ack\": true}\n".utf8), deadline: .now + writeWait)) != nil else { return }
        let reply = Mutex<RelayReply?>(nil)
        let finished = Atomic(false)
        let task = Task {
            let answered = await BoxCommands.answer(request, on: daemon)
            reply.withLock { $0 = answered }
            finished.store(true, ordering: .releasing)
        }
        var nextBeat = ContinuousClock.now + heartbeatEvery
        let isHook = RelayInput.reading(request.args) == .hookReport
        while !finished.load(ordering: .acquiring) {
            if connection.hungUp(within: .milliseconds(100)) {
                if !isHook { task.cancel() }
                return
            }
            if ContinuousClock.now >= nextBeat {
                guard (try? connection.write(Data("{\"alive\": true}\n".utf8), deadline: .now + writeWait)) != nil
                else {
                    if !isHook { task.cancel() }
                    return
                }
                nextBeat = .now + heartbeatEvery
            }
        }
        guard let answered = reply.withLock({ $0 }), var data = try? JSONEncoder().encode(answered) else { return }
        data.append(0x0A)
        try? connection.write(data, deadline: .now + writeWait)
    }

    private static func subscribe(_ request: ControlRequest, with writer: ConnectionWriter, daemon: BoxDaemon) async {
        send(.success(id: request.id, result: .bool(true)), with: writer)
        for await snapshot in await daemon.changes() {
            guard !writer.failed, let data = try? JSONValue.from(snapshot),
                let line = try? ControlCodec.encodeLine(
                    BoxEvent(event: BoxEvent.snapshot, subscription: request.id, data: data))
            else { return }
            writer.send(line)
        }
    }

    private static func send(_ response: ControlResponse, with writer: ConnectionWriter) {
        guard let line = try? ControlCodec.encodeLine(response) else { return }
        writer.send(line)
    }

    /// The answer to one control request.
    static func handle(_ request: ControlRequest, daemon: BoxDaemon, phones: PhoneServer? = nil) async
        -> ControlResponse
    {
        do {
            if request.method.hasPrefix("box.phones.") {
                return .success(id: request.id, result: try await phonesResult(of: request, phones: phones))
            }
            return .success(id: request.id, result: try await result(of: request, daemon: daemon))
        } catch let error as ControlError {
            return .failure(id: request.id, error: error)
        } catch {
            return .failure(id: request.id, error: ControlError(code: "internal", message: "\(error)"))
        }
    }

    private static func phonesResult(of request: ControlRequest, phones: PhoneServer?) async throws -> JSONValue {
        guard let phones else {
            throw ControlError(code: "phones_off", message: "canopy-box on this host serves no phones.")
        }
        switch request.method {
        case BoxMethod.phonesPair: return try .from(try await phones.pair())
        case BoxMethod.phonesPaired:
            let params = try request.decodeParams(PhonesPairedParams.self)
            return try .from(PhonesPairedResult(phone: await phones.waitForPairing(code: params.code)))
        case BoxMethod.phonesList: return try .from(await phones.list())
        case BoxMethod.phonesRemove:
            return try .from(try await phones.remove(name: try request.decodeParams(PhonesRemoveParams.self).name))
        case BoxMethod.phonesStatus: return try .from(await phones.status())
        default: throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
        }
    }

    private static func result(of request: ControlRequest, daemon: BoxDaemon) async throws -> JSONValue {
        switch request.method {
        case BoxMethod.hello:
            return try .from(
                BoxHelloResult(
                    version: CanopyVersion.current, protocolVersion: BoxProtocol.version, homeID: daemon.paths.homeID,
                    configured: await daemon.isConfigured))
        case BoxMethod.configure:
            try await daemon.configure(request.decodeParams(BoxConfig.self))
            return .bool(true)
        case BoxMethod.rowNew:
            return try .from(try await daemon.rowNew(request.decodeParams(BoxRowNewParams.self)))
        case BoxMethod.rowRemove:
            let warnings = try await daemon.rowRemove(request.decodeParams(BoxRowRemoveParams.self))
            return try .from(BoxRowRemoveResult(warnings: warnings))
        case BoxMethod.paneNew:
            return try .from(
                BoxPaneNewResult(pane: try await daemon.paneNew(request.decodeParams(BoxPaneNewParams.self))))
        case BoxMethod.paneClose:
            try await daemon.paneClose(request.decodeParams(BoxPaneParams.self).pane)
            return .bool(true)
        case BoxMethod.send:
            let params = try request.decodeParams(TermSendParams.self)
            try await daemon.send(pane: params.pane, text: params.text, enter: params.enter)
            return .bool(true)
        case BoxMethod.keys:
            try await daemon.keys(request.decodeParams(BoxKeysParams.self))
            return .bool(true)
        case BoxMethod.typed:
            try await daemon.typedElsewhere(request.decodeParams(BoxKeysParams.self))
            return .bool(true)
        case BoxMethod.read:
            let params = try request.decodeParams(TermReadParams.self)
            return try .from(TermReadResult(text: try await daemon.read(pane: params.pane, lines: params.lines)))
        case BoxMethod.wait:
            let params = try request.decodeParams(TermWaitParams.self)
            guard params.timeout.isFinite, params.timeout >= 0 else {
                throw ControlError(code: "bad_params", message: "The timeout must be zero or more seconds.")
            }
            // A wait longer than a year is as good as forever, and a Duration that long would overflow.
            let reached = try await daemon.wait(
                panes: params.panes, for: params.target, timeout: .seconds(min(params.timeout, 366 * 86_400)))
            return try .from(TermWaitResult(pane: reached.pane, state: reached.state))
        case BoxMethod.seen:
            try await daemon.seen(pane: request.decodeParams(BoxPaneParams.self).pane)
            return .bool(true)
        case BoxMethod.prs:
            await daemon.setPRs(try request.decodeParams(BoxPRsParams.self).prs)
            return .bool(true)
        case BoxMethod.adopt:
            return try .from(await daemon.adopt(try request.decodeParams(BoxAdoptParams.self)))
        case BoxMethod.release:
            return try .from(await daemon.release())
        default:
            throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
        }
    }
}

/// Writes a connection's lines in order on a queue of its own, so a peer that stops reading holds up no thread of
/// Swift's pool. A write that fails or waits past `wait` closes the connection, rather than leaving half a line in it.
final class ConnectionWriter: Sendable {
    let connection: UnixConnection
    private let wait: Duration
    private let queue = DispatchQueue(label: "canopy.box-writer")
    private let broken = Atomic(false)

    init(_ connection: UnixConnection, wait: Duration) {
        self.connection = connection
        self.wait = wait
    }

    /// Whether a write failed, after which nothing more is sent.
    var failed: Bool { broken.load(ordering: .acquiring) }

    /// Returns once everything sent before has been written, or given up.
    func flush() {
        queue.sync {}
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                try connection.write(data, deadline: .now + wait)
            } catch {
                broken.store(true, ordering: .releasing)
                connection.close()
            }
        }
    }
}
