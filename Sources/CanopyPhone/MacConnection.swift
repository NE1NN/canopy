import CanopyWire
import Foundation
import Observation

public typealias Sleep = @Sendable (Duration) async throws -> Void

/// The phone's one connection to its Mac: pairing, hello, the inbox, and connecting again whenever it drops.
@MainActor @Observable
public final class MacConnection {
    public enum Status: Equatable, Sendable {
        case connecting
        case connected
        /// The Mac could not be reached, or the connection dropped. The phone keeps trying.
        case unreachable(PhoneProblem)
    }

    public private(set) var paired: PairedMac?
    public private(set) var status: Status = .connecting
    /// The last inbox the Mac sent, kept while the Mac is out of reach.
    public private(set) var inbox: PhoneInbox?
    public private(set) var inboxAsOf: Date?
    /// Why the phone is back at Pairing, when the Mac forgot it.
    public private(set) var pairingNotice: String?
    /// Counts connections, so a stream knows to start again on a new one.
    public private(set) var generation = 0

    /// Waits between attempts, from the first retry on.
    static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]

    private let transport: any PhoneTransport
    private let credentials: any CredentialStore
    private let phoneName: String
    private let timeout: Duration
    private let sleep: Sleep
    private let now: @Sendable () -> Date

    private var client: PhoneClient?
    private var loop: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var failures = 0
    private var clientWaiters: [UUID: CheckedContinuation<PhoneClient, any Error>] = [:]

    public init(
        transport: any PhoneTransport, credentials: any CredentialStore, phoneName: String,
        timeout: Duration = .seconds(10), sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.credentials = credentials
        self.phoneName = phoneName
        self.timeout = timeout
        self.sleep = sleep
        self.now = now
        paired = credentials.load()
    }

    public var isConnected: Bool { status == .connected }

    public var isUnreachable: Bool {
        if case .unreachable = status { return true }
        return false
    }

    /// Connects, when paired, and keeps connecting.
    public func start() {
        guard paired != nil, loop == nil else { return }
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

    /// Trades the link's one-time code for a token, then says hello on the same connection and subscribes.
    public func pair(_ link: PairingLink) async throws {
        stop()
        var lastError: (any Error)?
        for host in link.hosts {
            do {
                let channel = try await within(timeout) { [transport] in
                    try await transport.connect(host: host, port: link.port)
                }
                let client = PhoneClient(channel: channel)
                do {
                    let result = try await within(timeout) { [phoneName] in
                        try await client.call(
                            PhoneMethod.pair, PhonePairParams(code: link.code, name: phoneName),
                            as: PhonePairResult.self)
                    }
                    let mac = PairedMac(
                        host: link.host, port: link.port, address: link.address, token: result.token, mac: result.mac,
                        phone: result.phone)
                    try credentials.save(mac)
                    paired = mac
                    pairingNotice = nil
                    inbox = nil
                    inboxAsOf = nil
                    status = .connecting
                    loop = Task { await self.run(opened: client) }
                    return
                } catch {
                    await client.close()
                    throw error
                }
            } catch let error as ControlError {
                throw PhoneProblem(error, mac: host)
            } catch {
                lastError = error
            }
        }
        throw PhoneProblem(lastError ?? PhoneTransportError.closed, mac: link.host)
    }

    /// Forgets the Mac. It still lists this phone until `canopy phone remove`.
    public func unpair() {
        forget(notice: nil)
    }

    /// The live connection, waiting for one when there is none yet.
    public func client() async throws -> PhoneClient {
        if let client, status == .connected { return client }
        guard paired != nil else { throw PhoneTransportError.closed }
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

    private func forget(notice: String?) {
        stop()
        credentials.clear()
        paired = nil
        inbox = nil
        inboxAsOf = nil
        pairingNotice = notice
        status = .connecting
        for waiter in clientWaiters.values {
            waiter.resume(throwing: PhoneTransportError.closed)
        }
        clientWaiters = [:]
    }

    private func run(opened: PhoneClient?) async {
        var opened = opened
        while !Task.isCancelled, let paired {
            do {
                let client: PhoneClient
                if let opened {
                    client = opened
                } else {
                    client = try await open(paired)
                }
                opened = nil
                try await serve(client, paired: paired)
                failures = 0
                // The connection was good until now, so the first try after a drop goes at once.
                if !Task.isCancelled {
                    status = .unreachable(PhoneProblem(PhoneTransportError.closed, mac: paired.mac))
                }
                continue
            } catch let error as ControlError where error.code == "unpaired" {
                forget(notice: PhoneProblem(error, mac: paired.mac).title)
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = .unreachable(PhoneProblem(error, mac: paired.mac))
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
    private func open(_ paired: PairedMac) async throws -> PhoneClient {
        var lastError: any Error = PhoneTransportError.closed
        for host in paired.hosts {
            do {
                let channel = try await within(timeout) { [transport] in
                    try await transport.connect(host: host, port: paired.port)
                }
                return PhoneClient(channel: channel)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Says hello, subscribes, and keeps the inbox until the connection ends.
    private func serve(_ client: PhoneClient, paired: PairedMac) async throws {
        defer { Task { await client.close() } }
        let hello = try await within(timeout) { [paired] in
            try await client.call(PhoneMethod.hello, PhoneHelloParams(token: paired.token), as: PhoneHelloResult.self)
        }
        let subscription = try await within(timeout) {
            try await client.stream(PhoneMethod.subscribe, as: PhoneInbox.self)
        }
        try Task.checkCancellation()
        var updated = paired
        updated.mac = hello.mac
        updated.phone = hello.phone
        updated.version = hello.version
        if updated != paired {
            try? credentials.save(updated)
            self.paired = updated
        }
        self.client = client
        receive(subscription.result)
        status = .connected
        generation += 1
        for waiter in clientWaiters.values {
            waiter.resume(returning: client)
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
