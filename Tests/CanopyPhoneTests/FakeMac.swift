import CanopyWire
import Foundation
import Synchronization

@testable import CanopyPhone

/// A Mac a test scripts: it pairs, says hello, and serves the inbox and rows as Canopy does, and answers other
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

    struct State {
        var reachable: Set<String> = [FakeMac.host, FakeMac.address]
        var refused: Set<String> = []
        var hanging: Set<String> = []
        var codes: Set<String> = [FakeMac.code]
        var tokens: [String: String] = [:]
        var inbox = PhoneInbox()
        var rows = PhoneRowsResult(sections: [])
        var handlers: [String: @Sendable (ControlRequest) -> Reply] = [:]
        var links: [Link] = []
        var connects: [String] = []
    }

    let state = Mutex(State())

    var link: PairingLink {
        PairingLink(host: Self.host, port: PhonePort.standard, code: Self.code, address: Self.address)
    }

    /// A phone this Mac already paired, for tests that start paired.
    func paired(phone: String = "iPhone") -> PairedMac {
        let token = "token-\(phone)"
        state.withLock { $0.tokens[token] = phone }
        return PairedMac(
            host: Self.host, port: PhonePort.standard, address: Self.address, token: token, mac: Self.name,
            phone: phone, version: "0.9")
    }

    func connect(host: String, port: UInt16) async throws -> any PhoneChannel {
        let (reachable, refused, hanging) = state.withLock { state in
            state.connects.append(host)
            return (state.reachable.contains(host), state.refused.contains(host), state.hanging.contains(host))
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
        state.withLock { $0.reachable = [Self.host, Self.address] }
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
                    (try? .from(PhonePairResult(token: token, phone: params.name, mac: Self.name))) ?? .null)
            }
        case PhoneMethod.hello:
            guard let params = try? request.decodeParams(PhoneHelloParams.self),
                let phone = state.withLock({ $0.tokens[params.token] })
            else { return .error("unpaired") }
            link.authenticated()
            return .result((try? .from(PhoneHelloResult(mac: Self.name, version: "0.9", phone: phone))) ?? .null)
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
