import CanopySystem
import CanopyWire
import Foundation
import Synchronization

/// Answers a paired phone's call. It runs only for methods in `PhoneGate.allowedMethods`, after `phone.hello`.
public typealias PhoneHandler = @Sendable (ControlRequest, PhoneSession) async -> PhoneReply

/// A handler's answer, and what to do once it has been sent, such as starting the stream it promised.
public struct PhoneReply: Sendable {
    public var response: ControlResponse
    /// Runs once the response has left. Events it sends follow the response.
    public var after: (@Sendable () async -> Void)?

    public init(_ response: ControlResponse, after: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.after = after
    }
}

/// What the listener lets in, and how.
public struct PhoneGate: Sendable {
    /// What a phone may call after `phone.hello`. A lost phone must not remove rows, repos, or hooks.
    public static let allowedMethods: Set<String> = [
        PhoneMethod.subscribe, PhoneMethod.rows, PhoneMethod.transcript, PhoneMethod.reply, PhoneMethod.answer,
        PhoneMethod.screen, PhoneMethod.keys, PhoneMethod.seen, PhoneMethod.unsubscribe, PhoneMethod.newRow,
    ]

    /// Calls that may take minutes, as a new row waits for its setup. They run beside the connection's later calls
    /// rather than ahead of them, and answer when done; the phone matches answers by id.
    public static let lengthyMethods: Set<String> = [PhoneMethod.newRow]

    public var registry: PhoneRegistry
    /// The server's name, asked each time, as it can change while the server runs.
    public var name: @Sendable () -> String
    /// `PhoneServerKind`'s.
    public var kind: String
    /// How a phone starts the server, asked at each hello.
    public var wake: @Sendable () -> PhoneWake?
    /// What a task from a phone runs, asked at each hello.
    public var agentCommand: @Sendable () -> String
    /// Canopy's version, which `phone.hello` answers with.
    public var version: String
    /// Waits out the time a new connection has to say hello, counted again after a pairing.
    public var helloTimer: @Sendable () async -> Void
    public var handler: PhoneHandler
    /// Called when a code pairs a new phone, for the activity log.
    public var onPaired: @Sendable (PairedPhone) -> Void

    public init(
        registry: PhoneRegistry, name: @escaping @Sendable () -> String, kind: String = PhoneServerKind.mac,
        wake: @escaping @Sendable () -> PhoneWake? = { nil },
        agentCommand: @escaping @Sendable () -> String = { PhoneAgentCommand.standard }, version: String,
        helloTimeout: Duration = .seconds(10),
        helloTimer: (@Sendable () async -> Void)? = nil, handler: @escaping PhoneHandler,
        onPaired: @escaping @Sendable (PairedPhone) -> Void = { _ in }
    ) {
        self.registry = registry
        self.name = name
        self.kind = kind
        self.wake = wake
        self.agentCommand = agentCommand
        self.version = version
        self.helloTimer = helloTimer ?? { try? await Task.sleep(for: helloTimeout) }
        self.handler = handler
        self.onPaired = onPaired
    }
}

/// A phone's connection, as handlers see it.
public struct PhoneSession: Sendable {
    public let phone: PairedPhone
    let connection: PhoneConnection

    /// Tells this session's connection from others, for what a connection holds, such as its streams.
    public var connectionID: ObjectIdentifier { ObjectIdentifier(connection) }

    /// Queues an event after everything already queued. It is dropped once the connection has closed. With
    /// `latestOnly`, for events that each carry the whole of something, such as the inbox or a screen, a newer one
    /// replaces one still waiting, so a phone that stops reading holds one, not every one since.
    public func send(_ event: PhoneEvent, latestOnly: Bool = false) {
        connection.enqueue(event, latestOnly: latestOnly)
    }

    /// Runs `action` once the connection closes, or at once if it already has.
    public func onClose(_ action: @escaping @Sendable () -> Void) {
        connection.onClose(action)
    }

    public var isOpen: Bool { !connection.isClosed }
}

/// One phone's TCP connection: newline-delimited JSON, with `phone.hello` or `phone.pair` first.
final class PhoneConnection: Sendable {
    let localAddress: String
    private let connection: TCPConnection
    private let gate: PhoneGate
    private let buffer = Mutex(LineBuffer())
    private let state = Mutex(State())
    /// Lines are handled one at a time, in order, each answered before the next starts, so a hello sent with the next
    /// request counts for it, keys go in in the order sent, and an unsubscribe finds the stream it names.
    private let lastStep = Mutex<Task<Void, Never>?>(nil)
    /// The last write in line. Answers and events leave in the order they were queued.
    private let lastSend = Mutex<Task<Void, Never>?>(nil)
    private let closedHandler = Mutex<(@Sendable () -> Void)?>(nil)
    /// Latest-only events queued but not yet written, by event and subscription.
    private let waitingEvents = Mutex<[String: PhoneEvent]>([:])

    private struct State {
        var phone: PairedPhone?
        /// No more lines are read once the connection is closing.
        var closing = false
        var closed = false
        var closeActions: [@Sendable () -> Void] = []
        var helloTimer: Task<Void, Never>?
    }

    init(connection: TCPConnection, localAddress: String, gate: PhoneGate) {
        self.connection = connection
        self.localAddress = localAddress
        self.gate = gate
    }

    /// Set by the listener, which forgets the connection once it closes.
    var onClosed: (@Sendable () -> Void)? {
        get { closedHandler.withLock { $0 } }
        set { closedHandler.withLock { $0 = newValue } }
    }

    var phoneID: String? { state.withLock { $0.phone?.id } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func start() {
        startHelloTimer()
        receive()
    }

    func close() {
        let actions = state.withLock { state -> [@Sendable () -> Void]? in
            guard !state.closed else { return nil }
            state.closed = true
            state.closing = true
            state.helloTimer?.cancel()
            defer { state.closeActions = [] }
            return state.closeActions
        }
        guard let actions else { return }
        connection.close()
        for action in actions { action() }
        onClosed?()
    }

    func onClose(_ action: @escaping @Sendable () -> Void) {
        let ranAlready = state.withLock { state in
            if state.closed { return true }
            state.closeActions.append(action)
            return false
        }
        if ranAlready { action() }
    }

    func enqueue(_ event: PhoneEvent, latestOnly: Bool) {
        guard !isClosed else { return }
        guard latestOnly else {
            if let data = try? ControlCodec.encodeLine(event) { queueSend { await self.write(data) } }
            return
        }
        let key = event.event + "\u{0}" + event.subscription
        let alreadyQueued = waitingEvents.withLock { waiting in
            defer { waiting[key] = event }
            return waiting[key] != nil
        }
        guard !alreadyQueued else { return }
        queueSend {
            guard let event = self.waitingEvents.withLock({ $0.removeValue(forKey: key) }),
                let data = try? ControlCodec.encodeLine(event)
            else { return }
            await self.write(data)
        }
    }

    private func startHelloTimer() {
        let wait = gate.helloTimer
        let timer = Task { [weak self] in
            await wait()
            guard !Task.isCancelled, let self, self.phoneID == nil else { return }
            self.close()
        }
        state.withLock { state in
            state.helloTimer?.cancel()
            state.helloTimer = timer
        }
    }

    private func receive() {
        connection.receive { data, _ in
            if let data {
                guard !self.state.withLock({ $0.closing }) else { return }
                self.consume(data)
                return
            }
            // Answers what came in before the phone closed its side, or the connection failed, then closes.
            self.lastStep.withLock { last in
                let previous = last
                last = Task {
                    await previous?.value
                    self.closeWhenSent()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        guard let lines = buffer.withLock({ $0.append(data) }) else {
            refuse(id: "", ControlError(code: "bad_request", message: "Request is too long."), closing: true)
            return
        }
        for line in lines where !line.isEmpty {
            lastStep.withLock { last in
                let previous = last
                last = Task {
                    await previous?.value
                    await self.step(line)
                }
            }
        }
    }

    /// Lets one line through the gate, then queues its answer behind those before it.
    private func step(_ line: Data) async {
        guard !state.withLock({ $0.closing }) else { return }
        guard let request = try? ControlCodec.decode(ControlRequest.self, from: line) else {
            refuse(id: "", ControlError(code: "bad_request", message: "Request is not valid JSON."), closing: true)
            return
        }
        let phone = state.withLock { $0.phone }
        guard request.v == ControlCodec.version else {
            let error = ControlError(
                code: "version_mismatch",
                message:
                    "The Mac speaks protocol v\(ControlCodec.version) but the phone sent v\(request.v). Update the app."
            )
            refuse(id: request.id, error, closing: phone == nil)
            return
        }
        guard let phone else {
            await authenticate(request)
            return
        }
        if request.method == PhoneMethod.hello {
            queueReply(.success(id: request.id, result: (try? .from(greeting(phone))) ?? .null))
            return
        }
        guard PhoneGate.allowedMethods.contains(request.method) else {
            let error = ControlError(code: "method_not_allowed", message: "A phone cannot call \(request.method).")
            refuse(id: request.id, error, closing: false)
            return
        }
        let session = PhoneSession(phone: phone, connection: self)
        let handler = gate.handler
        if PhoneGate.lengthyMethods.contains(request.method) {
            Task {
                let reply = await handler(request, session)
                await self.queueSend {
                    if let data = try? ControlCodec.encodeLine(reply.response) { await self.write(data) }
                    await reply.after?()
                }.value
            }
            return
        }
        let reply = await handler(request, session)
        await queueSend {
            if let data = try? ControlCodec.encodeLine(reply.response) { await self.write(data) }
            await reply.after?()
        }.value
    }

    private func authenticate(_ request: ControlRequest) async {
        switch request.method {
        case PhoneMethod.pair:
            do {
                let params = try request.decodeParams(PhonePairParams.self)
                let paired = try await gate.registry.redeem(code: params.code, name: params.name)
                gate.onPaired(paired.phone)
                startHelloTimer()
                let result = PhonePairResult(
                    token: paired.token, phone: paired.phone.name, mac: gate.name(), kind: gate.kind)
                queueReply(.success(id: request.id, result: try .from(result)))
            } catch {
                refuse(
                    id: request.id,
                    error as? ControlError ?? ControlError(code: "internal", message: "\(error)"), closing: true)
            }
        case PhoneMethod.hello:
            let params = try? request.decodeParams(PhoneHelloParams.self)
            guard let token = params?.token, let phone = await gate.registry.authenticate(token: token) else {
                let error = ControlError(
                    code: "unpaired", message: "This phone is not paired with \(gate.name()). Pair it again.")
                refuse(id: request.id, error, closing: true)
                return
            }
            state.withLock { state in
                state.phone = phone
                state.helloTimer?.cancel()
            }
            // Checked again once the phone is set, so a removal between the two checks either sees this connection
            // or is seen here.
            guard await gate.registry.connected(phone.id) else {
                state.withLock { $0.phone = nil }
                let error = ControlError(
                    code: "unpaired", message: "This phone is not paired with \(gate.name()). Pair it again.")
                refuse(id: request.id, error, closing: true)
                return
            }
            queueReply(.success(id: request.id, result: (try? .from(greeting(phone))) ?? .null))
        default:
            let error = ControlError(code: "not_authenticated", message: "Send phone.hello first.")
            refuse(id: request.id, error, closing: true)
        }
    }

    private func greeting(_ phone: PairedPhone) -> PhoneHelloResult {
        PhoneHelloResult(
            mac: gate.name(), version: gate.version, phone: phone.name, kind: gate.kind, wake: gate.wake(),
            agentCommand: gate.agentCommand())
    }

    private func refuse(id: String, _ error: ControlError, closing: Bool) {
        if closing { state.withLock { $0.closing = true } }
        queueReply(.failure(id: id, error: error))
        if closing { closeWhenSent() }
    }

    private func queueReply(_ response: ControlResponse) {
        guard let data = try? ControlCodec.encodeLine(response) else { return }
        queueSend { await self.write(data) }
    }

    @discardableResult
    private func queueSend(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lastSend.withLock { last in
            let previous = last
            let next = Task {
                await previous?.value
                await work()
            }
            last = next
            return next
        }
    }

    private func closeWhenSent() {
        state.withLock { $0.closing = true }
        queueSend { self.close() }
    }

    /// Returns once the data has left, so closing afterwards cannot drop it.
    private func write(_ data: Data) async {
        guard !isClosed else { return }
        do {
            try await connection.send(data)
        } catch {
            close()
        }
    }
}
