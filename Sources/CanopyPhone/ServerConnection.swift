import CanopyWire
import Foundation
import Observation

public typealias Sleep = @Sendable (Duration) async throws -> Void

/// The phone's connection to one server: hello, the inbox, and connecting again whenever it drops.
@MainActor @Observable
public final class ServerConnection: Identifiable {
    /// The server forgot this phone, or it was removed here, so nothing will connect until it pairs again.
    public struct NotPaired: Error, Equatable {}

    public enum Status: Equatable, Sendable {
        case connecting
        case connected
        /// The server could not be reached, or the connection dropped. The phone keeps trying.
        case unreachable(PhoneProblem)
        /// The server no longer knows this phone's token, as after `canopy phone remove`. It says why.
        case unpaired(String)
    }

    public nonisolated let id: String
    public private(set) var server: PairedServer
    public private(set) var status: Status = .connecting
    /// The last inbox the server sent, kept while it is out of reach.
    public private(set) var inbox: PhoneInbox?
    public private(set) var inboxAsOf: Date?
    /// Counts connections, so a stream knows to start again on a new one.
    public private(set) var generation = 0

    /// Waits between attempts, from the first retry on.
    static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]

    private let transport: any PhoneTransport
    private let credentials: any CredentialStore
    private let timeout: Duration
    private let sleep: Sleep
    private let now: @Sendable () -> Date

    private var client: PhoneClient?
    private var loop: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var failures = 0
    private var clientWaiters: [UUID: CheckedContinuation<(client: PhoneClient, generation: Int), any Error>] = [:]

    public init(
        server: PairedServer, transport: any PhoneTransport, credentials: any CredentialStore,
        timeout: Duration = .seconds(10), sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        id = server.id
        self.server = server
        if let notice = server.unpairedNotice { status = .unpaired(notice) }
        self.transport = transport
        self.credentials = credentials
        self.timeout = timeout
        self.sleep = sleep
        self.now = now
    }

    public var name: String { server.name }
    public var isBox: Bool { server.isBox }

    public var isConnected: Bool { status == .connected }

    public var isUnreachable: Bool {
        if case .unreachable = status { return true }
        return false
    }

    /// Whether the server still knows this phone, as far as the phone knows.
    public var isPaired: Bool {
        if case .unpaired = status { return false }
        return true
    }

    /// Connects, and keeps connecting.
    public func start() {
        guard isPaired, loop == nil else { return }
        loop = Task { await self.run(opened: nil) }
    }

    /// Back on screen: try at once rather than waiting out the backoff.
    public func foreground() {
        failures = 0
        if loop == nil {
            start()
        } else {
            nap?.cancel()
        }
    }

    /// iOS suspends an app in the background, so the connection closes now and opens again on the way back.
    public func background() {
        stop()
    }

    /// Takes a new pairing with this server, already open on `opened`, in place of the old one.
    func pairAgain(with server: PairedServer, opened: PhoneClient) {
        stop()
        self.server = server
        inbox = nil
        inboxAsOf = nil
        status = .connecting
        loop = Task { await self.run(opened: opened) }
    }

    /// Starts on a connection pairing just opened.
    func start(opened: PhoneClient) {
        guard isPaired, loop == nil else { return }
        loop = Task { await self.run(opened: opened) }
    }

    /// Stops for good, as when the server is removed here, so nothing waits for it again.
    func end() {
        stop()
        status = .unpaired("\(name) was removed from this iPhone.")
        failWaiters()
    }

    /// The live connection, for something the author just did, which should fail at once rather than wait.
    public func liveClient() throws -> PhoneClient {
        guard let client, status == .connected else {
            switch status {
            case .unreachable(let problem):
                throw PhoneProblem(title: "Can't reach \(name).", detail: problem.detail)
            case .unpaired(let notice):
                throw PhoneProblem(title: notice, detail: "Pair it again with \(pairCommand) on the Mac.")
            case .connecting, .connected:
                throw PhoneProblem(title: "Can't reach \(name).", detail: PhoneProblem.checkTailscale)
            }
        }
        return client
    }

    /// An error as the app says it, naming this server.
    public func problem(_ error: any Error) -> PhoneProblem {
        PhoneProblem(error, server: name, pairCommand: pairCommand)
    }

    /// What pairs this server again, run on the Mac.
    public var pairCommand: String { isBox ? "canopy phone pair --on \(name)" : "canopy phone pair" }

    /// The live connection, waiting for one when there is none yet.
    public func client() async throws -> PhoneClient {
        try await client(after: 0).client
    }

    /// The first connection newer than `generation`, waiting for one. A stream whose connection dropped passes the
    /// generation it had, so it never gets that connection back.
    public func client(after generation: Int) async throws -> (client: PhoneClient, generation: Int) {
        if let client, status == .connected, self.generation > generation { return (client, self.generation) }
        guard isPaired else { throw NotPaired() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    clientWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.clientWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        nap?.cancel()
        let client = client
        self.client = nil
        Task { await client?.close() }
        if status == .connected { status = .connecting }
    }

    private func failWaiters() {
        for waiter in clientWaiters.values {
            waiter.resume(throwing: NotPaired())
        }
        clientWaiters = [:]
    }

    private func forgotten(notice: String) {
        stop()
        inbox = nil
        inboxAsOf = nil
        status = .unpaired(notice)
        server.unpairedNotice = notice
        try? credentials.save(server)
        failWaiters()
    }

    private func run(opened: PhoneClient?) async {
        var opened = opened
        while !Task.isCancelled, isPaired {
            let server = server
            do {
                let client: PhoneClient
                if let opened {
                    client = opened
                } else {
                    client = try await open(server)
                }
                opened = nil
                try await serve(client, server: server)
                failures = 0
                // The connection was good until now, so the first try after a drop goes at once.
                if !Task.isCancelled {
                    status = .unreachable(PhoneProblem(PhoneTransportError.closed, server: server.name))
                }
                continue
            } catch let error as ControlError where error.code == "unpaired" {
                // A loop that pairing again replaced may still hear its old token refused; only the current one counts.
                guard !Task.isCancelled, self.server.token == server.token else { return }
                forgotten(notice: problem(error).title)
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = .unreachable(PhoneProblem(error, server: server.name))
            }
            let wait = Self.backoff[min(failures, Self.backoff.count - 1)]
            failures += 1
            let sleep = self.sleep
            nap = Task { try? await sleep(wait) }
            await nap?.value
            nap = nil
        }
    }

    /// Connects to the first host that answers.
    private func open(_ server: PairedServer) async throws -> PhoneClient {
        var lastError: any Error = PhoneTransportError.closed
        for host in server.hosts {
            do {
                let channel = try await within(timeout) { [transport] in
                    try await transport.connect(host: host, port: server.port)
                }
                return PhoneClient(channel: channel)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Says hello, subscribes, and keeps the inbox until the connection ends.
    private func serve(_ client: PhoneClient, server: PairedServer) async throws {
        defer { Task { await client.close() } }
        let hello = try await within(timeout) { [server] in
            try await client.call(PhoneMethod.hello, PhoneHelloParams(token: server.token), as: PhoneHelloResult.self)
        }
        let subscription = try await within(timeout) {
            try await client.stream(PhoneMethod.subscribe, as: PhoneInbox.self)
        }
        try Task.checkCancellation()
        var updated = server
        updated.name = hello.mac
        updated.phone = hello.phone
        updated.version = hello.version
        if let kind = hello.kind { updated.kind = kind }
        // A box with no key now, as after `host wake-key --clear`, takes the phone's away too.
        updated.wake = hello.wake
        if updated != server {
            try? credentials.save(updated)
            self.server = updated
        }
        self.client = client
        receive(subscription.result)
        status = .connected
        generation += 1
        for waiter in clientWaiters.values {
            waiter.resume(returning: (client, generation))
        }
        clientWaiters = [:]
        for await event in subscription.events where event.event == PhoneEvent.inbox {
            if let inbox = try? event.data.decode(PhoneInbox.self) {
                receive(inbox)
            }
        }
        if self.client === client { self.client = nil }
    }

    private func receive(_ inbox: PhoneInbox) {
        self.inbox = inbox
        inboxAsOf = now()
    }
}

/// Runs the work, giving up with `PhoneTransportError.timedOut` after the timeout.
func within<Value: Sendable>(
    _ timeout: Duration, _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw PhoneTransportError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw PhoneTransportError.timedOut }
        return value
    }
}
