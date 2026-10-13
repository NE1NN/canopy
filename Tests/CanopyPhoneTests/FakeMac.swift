import CanopyWire
import Foundation
import Synchronization

@testable import CanopyPhone

/// A server a test scripts, a Mac unless it is made a box: it pairs, says hello, and serves the inbox and rows as Canopy does, and answers other
/// methods with what the test sets in `on(_:)`. Every connection the phone opens is a `Link`.
final class FakeMac: PhoneTransport, Sendable {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(String)
        /// No answer at all, as from a Mac that hung.
        case silent
    }

    static let name = "Studio"
    static let host = "studio.tail1234.ts.net"
    static let address = "100.101.5.9"
    static let code = "K7QX-M2PD"

    let name: String
    let host: String
    let address: String
    let code: String
    let kind: String

    init(
        name: String = FakeMac.name, host: String = FakeMac.host, address: String = FakeMac.address,
        code: String = FakeMac.code, kind: String = PhoneServerKind.mac
    ) {
        self.name = name
        self.host = host
        self.address = address
        self.code = code
        self.kind = kind
        state = Mutex(State(reachable: [host, address], codes: [code]))
    }

    /// A box on the tailnet, as `canopy-box` on hindie-box.
    static func box(name: String = "hindie-box") -> FakeMac {
        FakeMac(
            name: name, host: "\(name).tail1234.ts.net", address: "100.101.5.20", code: "B0XC-0DE1",
            kind: PhoneServerKind.box)
    }

    struct State {
        var reachable: Set<String>
        var refused: Set<String> = []
        var hanging: Set<String> = []
        var codes: Set<String>
        /// What hello hands the phone to start this box with.
        var wake: PhoneWake?
        /// What hello says a task from the phone runs.
        var agentCommand: String?
        var tokens: [String: String] = [:]
        var inbox = PhoneInbox()
        var rows = PhoneRowsResult(sections: [])
        var handlers: [String: @Sendable (ControlRequest) -> Reply] = [:]
        var links: [Link] = []
        var connects: [String] = []
        /// How many connects fail before they go through again.
        var failingConnects = 0
    }

    let state: Mutex<State>

    var link: PairingLink {
        PairingLink(host: host, port: PhonePort.standard, code: code, address: address, kind: kind)
    }

    /// A phone this server already paired, for tests that start paired. Servers paired earlier sort first.
    func paired(phone: String = "iPhone", at pairedAt: Double = 0) -> PairedServer {
        let token = "token-\(phone)"
        state.withLock { $0.tokens[token] = phone }
        return PairedServer(
            id: "server-\(name)", kind: kind, name: name, host: host, port: PhonePort.standard, address: address,
            token: token, phone: phone, version: "0.9", pairedAt: Date(timeIntervalSince1970: pairedAt))
    }

    /// A code for pairing again, as a new `canopy phone pair` makes.
    func newCode(_ code: String) -> PairingLink {
        state.withLock { _ = $0.codes.insert(code) }
        return PairingLink(host: host, port: PhonePort.standard, code: code, address: address, kind: kind)
    }

    func connect(host: String, port: UInt16) async throws -> any PhoneChannel {
        let (reachable, refused, hanging) = state.withLock { state in
            state.connects.append(host)
            let failing = state.failingConnects > 0
            if failing { state.failingConnects -= 1 }
            return (
                state.reachable.contains(host) && !failing, state.refused.contains(host), state.hanging.contains(host)
            )
        }
        if hanging {
            try await Task.sleep(for: .seconds(3600))
        }
        if refused { throw PhoneTransportError.refused }
        guard reachable else { throw PhoneTransportError.unreachable("no route to \(host)") }
        let link = Link(mac: self)
        state.withLock { $0.links.append(link) }
        return link
    }

    func on(_ method: String, _ handler: @escaping @Sendable (ControlRequest) -> Reply) {
        state.withLock { $0.handlers[method] = handler }
    }

    func setInbox(_ inbox: PhoneInbox) {
        let links = state.withLock { state in
            state.inbox = inbox
            return state.links
        }
        for link in links {
            if let subscription = link.inboxSubscription {
                link.emit(PhoneEvent.inbox, subscription: subscription, inbox)
            }
        }
    }

    /// Sends an event to whichever connection started the stream.
    func emit(_ event: String, subscription: String, _ data: some Encodable) {
        for link in state.withLock({ $0.links }) where link.requests.contains(where: { $0.id == subscription }) {
            link.emit(event, subscription: subscription, data)
        }
    }

    /// Every connection closes, as when the Mac sleeps or Canopy quits.
    func dropAll() {
        for link in state.withLock({ $0.links }) {
            link.drop()
        }
    }

    /// The Mac stops answering connections.
    func goAway() {
        state.withLock { $0.reachable = [] }
        dropAll()
    }

    func comeBack() {
        state.withLock { [host, address] in $0.reachable = [host, address] }
    }

    func forget(phone: String) {
        state.withLock { state in state.tokens = state.tokens.filter { $0.value != phone } }
    }

    var requests: [ControlRequest] {
        state.withLock { $0.links }.flatMap(\.requests)
    }

    var openLinks: [Link] {
        state.withLock { $0.links }.filter { !$0.isClosed }
    }

    var connects: [String] {
        state.withLock { $0.connects }
    }

    /// The `number`th request for the method, counted from 1, once the phone has sent it.
    func request(_ method: String, number: Int = 1) async -> ControlRequest? {
        _ = await eventually { requests.filter { $0.method == method }.count >= number }
        let matching = requests.filter { $0.method == method }
        return matching.count >= number ? matching[number - 1] : nil
    }

    fileprivate func reply(to request: ControlRequest, on link: Link) -> Reply {
        if let handler = state.withLock({ $0.handlers[request.method] }) {
            return handler(request)
        }
        switch request.method {
        case PhoneMethod.pair:
            guard let params = try? request.decodeParams(PhonePairParams.self) else { return .error("bad_params") }
            return state.withLock { state in
                guard state.codes.remove(params.code) != nil else { return .error("bad_pairing_code") }
                let token = "token-\(state.tokens.count + 1)"
                state.tokens[token] = params.name
                return .result(
                    (try? .from(PhonePairResult(token: token, phone: params.name, mac: name, kind: kind))) ?? .null)
            }
        case PhoneMethod.hello:
            guard let params = try? request.decodeParams(PhoneHelloParams.self),
                let phone = state.withLock({ $0.tokens[params.token] })
            else { return .error("unpaired") }
            link.authenticated()
            return .result(
                (try? .from(
                    PhoneHelloResult(
                        mac: name, version: "0.9", phone: phone, kind: kind, wake: state.withLock { $0.wake },
                        agentCommand: state.withLock { $0.agentCommand })))
                    ?? .null)
        case PhoneMethod.subscribe:
            link.inboxSubscription = request.id
            return .result((try? .from(state.withLock { $0.inbox })) ?? .null)
        case PhoneMethod.rows:
            return .result((try? .from(state.withLock { $0.rows })) ?? .null)
        case PhoneMethod.unsubscribe:
            return .result(request.params ?? .null)
        default:
            return .error("unknown_method")
        }
    }

    final class Link: PhoneChannel, @unchecked Sendable {
        let lines: AsyncThrowingStream<Data, any Error>
        private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
        private weak var mac: FakeMac?
        private let lock = Mutex(LinkState())

        private struct LinkState {
            var requests: [ControlRequest] = []
            var isClosed = false
            var isAuthenticated = false
            var inboxSubscription: String?
        }

        init(mac: FakeMac) {
            self.mac = mac
            (lines, incoming) = AsyncThrowingStream.makeStream()
        }

        var requests: [ControlRequest] { lock.withLock { $0.requests } }
        var isClosed: Bool { lock.withLock { $0.isClosed } }
        var isAuthenticated: Bool { lock.withLock { $0.isAuthenticated } }

        var inboxSubscription: String? {
            get { lock.withLock { $0.inboxSubscription } }
            set { lock.withLock { $0.inboxSubscription = newValue } }
        }

        func authenticated() {
            lock.withLock { $0.isAuthenticated = true }
        }

        func send(_ line: Data) async throws {
            guard !isClosed else { throw PhoneTransportError.closed }
            guard let request = try? ControlCodec.decode(ControlRequest.self, from: line) else { return }
            lock.withLock { $0.requests.append(request) }
            guard let mac else { return }
            switch mac.reply(to: request, on: self) {
            case .result(let result):
                write(ControlResponse.success(id: request.id, result: result))
            case .error(let code):
                write(
                    ControlResponse.failure(id: request.id, error: ControlError(code: code, message: "\(code) message"))
                )
            case .silent:
                break
            }
        }

        func emit(_ event: String, subscription: String, _ data: some Encodable) {
            guard let data = try? JSONValue.from(data) else { return }
            write(PhoneEvent(event: event, subscription: subscription, data: data))
        }

        private func write(_ message: some Encodable) {
            guard !isClosed, let line = try? ControlCodec.encodeLine(message) else { return }
            incoming.yield(line.dropLast())
        }

        func close() {
            drop()
        }

        func drop() {
            lock.withLock { $0.isClosed = true }
            incoming.finish()
        }
    }
}

/// Several servers on one tailnet: each connection goes to the server listening on its host.
final class FakeNetwork: PhoneTransport, Sendable {
    let servers: [FakeMac]

    init(_ servers: [FakeMac]) {
        self.servers = servers
    }

    convenience init(_ servers: FakeMac...) {
        self.init(servers)
    }

    func connect(host: String, port: UInt16) async throws -> any PhoneChannel {
        guard let server = servers.first(where: { $0.host == host || $0.address == host }) else {
            throw PhoneTransportError.unreachable("no route to \(host)")
        }
        return try await server.connect(host: host, port: port)
    }
}

/// Sleeps that a test ends by hand, so backoff can be checked without waiting for it. Cancelling the sleeping task
/// ends its sleep, as `Task.sleep` does.
final class ManualSleeper: Sendable {
    private struct Sleeper {
        var id: UUID
        var duration: Duration
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
        var asked: [Duration] = []
    }

    private let state = Mutex(State())

    var sleep: Sleep {
        { duration in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let cancelled = self.state.withLock { state in
                        state.asked.append(duration)
                        if state.cancelled.remove(id) != nil { return true }
                        state.sleepers.append(Sleeper(id: id, duration: duration, continuation: continuation))
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let sleeper = self.state.withLock { state in
                    guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                        state.cancelled.insert(id)
                        return Sleeper?.none
                    }
                    return state.sleepers.remove(at: index)
                }
                sleeper?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Every sleep asked for so far, in order, cancelled ones included.
    var durations: [Duration] { state.withLock { $0.asked } }

    var sleeping: Int { state.withLock { $0.sleepers.count } }

    /// Ends the oldest sleep, once there is one.
    func wake() async {
        _ = await eventually { sleeping > 0 }
        let first = state.withLock { $0.sleepers.isEmpty ? nil : $0.sleepers.removeFirst() }
        first?.continuation.resume()
    }
}
