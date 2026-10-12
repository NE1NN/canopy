import Foundation
import Network
import Synchronization

/// Canopy's side of the iPhone app: the paired phones, the listener they reach, and what they may call.
public final class PhoneService: Sendable {
    public let registry: PhoneRegistry
    private let listener: PhoneListener
    private let hub: PhoneHub
    private let activity: ActivityLog
    private let listen: PhoneListenAddress
    private let tailscaleAddresses: @Sendable () -> [String]
    private let dnsName: @Sendable () async -> String?
    private let monitor = Mutex<NWPathMonitor?>(nil)
    private let lastRefreshError = Mutex<String?>(nil)
    /// Each connection's inbox subscription, so a second `phone.subscribe` replaces the first.
    private let subscriptions = Mutex<[ObjectIdentifier: UUID]>([:])
    /// Lets the listener's handler reach the service until `stop`.
    private let handle: ServiceHandle

    public init(
        home: CanopyHome, hub: PhoneHub, activity: ActivityLog, listen: PhoneListenAddress, macName: String,
        tailscaleAddresses: @escaping @Sendable () -> [String] = TailscaleAddresses.current,
        dnsName: @escaping @Sendable () async -> String? = TailscaleStatus.dnsName
    ) {
        let registry = PhoneRegistry(file: home.phonesFile)
        self.registry = registry
        self.hub = hub
        self.activity = activity
        self.listen = listen
        self.tailscaleAddresses = tailscaleAddresses
        self.dnsName = dnsName
        let handle = ServiceHandle()
        listener = PhoneListener(
            port: listen.port,
            addresses: {
                switch listen {
                case .tailscale: tailscaleAddresses()
                case .address(let address, _): [address]
                case .closed: []
                }
            },
            gate: PhoneGate(
                registry: registry, macName: macName,
                handler: { request, session in
                    guard let service = handle.service.withLock({ $0 }) else {
                        return PhoneReply(
                            .failure(
                                id: request.id, error: ControlError(code: "internal", message: "Canopy is quitting.")))
                    }
                    return await service.handle(request, session)
                },
                onPaired: { phone in
                    activity.record(ActivityType.phonePaired, source: .phone, data: ["phone": .string(phone.name)])
                }))
        self.handle = handle
        handle.service.withLock { $0 = self }
    }

    /// Listens, and follows network changes so the listener opens when Tailscale comes up and closes when it goes.
    public func start() async {
        await refresh()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "canopy.phone-network"))
        self.monitor.withLock { $0 = monitor }
    }

    public func stop() {
        monitor.withLock {
            $0?.cancel()
            $0 = nil
        }
        listener.stop()
        handle.service.withLock { $0 = nil }
    }

    public func refresh() async {
        do {
            try await listener.refresh()
            lastRefreshError.withLock { $0 = nil }
        } catch {
            lastRefreshError.withLock { $0 = "\(error)" }
        }
    }

    // MARK: The phone's methods

    private func handle(_ request: ControlRequest, _ session: PhoneSession) async -> PhoneReply {
        switch request.method {
        case PhoneMethod.subscribe:
            let inbox = await hub.inbox
            let connection = ObjectIdentifier(session.connection)
            let reply = ControlResponse.success(id: request.id, result: (try? .from(inbox)) ?? .null)
            // Runs after the response, in the connection's order, so two subscribes never interleave here.
            return PhoneReply(reply) { [self] in
                let previous = subscriptions.withLock { $0[connection] }
                let id = await hub.subscribe(after: inbox, replacing: previous) { inbox in
                    guard let data = try? JSONValue.from(inbox) else { return }
                    session.send(PhoneEvent(event: PhoneEvent.inbox, subscription: request.id, data: data))
                }
                subscriptions.withLock { $0[connection] = id }
                guard previous == nil else { return }
                session.onClose { [self] in
                    let current = subscriptions.withLock { $0.removeValue(forKey: connection) }
                    if let current { Task { await hub.unsubscribe(current) } }
                }
            }
        case PhoneMethod.rows:
            let rows = await hub.rows
            return PhoneReply(.success(id: request.id, result: (try? .from(rows)) ?? .null))
        default:
            let error = ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
            return PhoneReply(.failure(id: request.id, error: error))
        }
    }

    // MARK: What `canopy phone` calls

    public func pair() async throws -> PhonesPairResult {
        guard let endpoint = preferred(listener.endpoints) else {
            throw ControlError(
                code: "phone_listener_closed",
                message: "Canopy is not listening for phones. \(closedReason) canopy phone status says more.")
        }
        let name = listen.isTailscale ? await dnsName() : nil
        let code = await registry.newCode()
        let link = PairingLink(
            host: name ?? endpoint.address, port: endpoint.port, code: code.code, address: endpoint.address)
        return PhonesPairResult(
            code: code.code, link: link.url.absoluteString, expires: code.expires.timeIntervalSince1970)
    }

    public func waitForPairing(code: String) async -> PhoneInfo? {
        guard let phone = await registry.waitForPairing(code: code) else { return nil }
        return PhoneInfo(phone, connected: listener.connectedPhoneIDs.contains(phone.id))
    }

    public func list() async -> [PhoneInfo] {
        let connected = listener.connectedPhoneIDs
        return await registry.phones.map { PhoneInfo($0, connected: connected.contains($0.id)) }
    }

    public func remove(name: String) async throws -> PhoneInfo {
        let phone = try await registry.remove(name: name)
        let connected = listener.connectedPhoneIDs.contains(phone.id)
        listener.disconnect(phoneID: phone.id)
        activity.record(ActivityType.phoneRemoved, data: ["phone": .string(phone.name)])
        return PhoneInfo(phone, connected: connected)
    }

    public func status() async -> PhonesStatusResult {
        let endpoints = listener.endpoints
        var problem: String?
        if case .tailscale(_, let ignored?) = listen {
            problem = "CANOPY_PHONE_LISTEN=\(ignored) is ignored: release builds listen only on Tailscale."
        }
        if endpoints.isEmpty {
            problem = [closedReason, problem].compactMap { $0 }.joined(separator: " ")
        }
        let name = !endpoints.isEmpty && listen.isTailscale ? await dnsName() : nil
        return PhonesStatusResult(
            listening: !endpoints.isEmpty, endpoints: endpoints, host: name, problem: problem, phones: await list(),
            notifications: PhonesStatusResult.noPushKey)
    }

    private var closedReason: String {
        if let error = lastRefreshError.withLock({ $0 }) {
            return "It could not listen: \(error)."
        }
        switch listen {
        case .tailscale:
            return "Tailscale is not running on this Mac, or is signed out, so the Mac has no Tailscale address."
        case .address(let address, _):
            return "It could not listen on \(address)."
        case .closed(let malformed?):
            return "CANOPY_PHONE_LISTEN=\(malformed) is not an address and port, such as 127.0.0.1:7123."
        case .closed(nil):
            return
                "This dev build listens for phones only where CANOPY_PHONE_LISTEN says, such as 127.0.0.1:7123, so it never takes the tailnet port from the release app."
        }
    }

    /// IPv4 first, since every phone's network reaches it.
    private func preferred(_ endpoints: [PhoneEndpoint]) -> PhoneEndpoint? {
        endpoints.first { IPv4Address($0.address) != nil } ?? endpoints.first
    }
}

private final class ServiceHandle: Sendable {
    let service = Mutex<PhoneService?>(nil)
}

extension PhoneListenAddress {
    var isTailscale: Bool {
        if case .tailscale = self { true } else { false }
    }
}

extension CanopyHome {
    /// Paired phones, by name, with hashes of their tokens.
    public var phonesFile: URL { root.appending(path: "phones.json") }
}

/// What the Tailscale app says about this Mac.
public enum TailscaleStatus {
    /// The Tailscale CLI, from the Mac App Store or standalone app, then Homebrew.
    static let executables = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// This Mac's MagicDNS name, such as `studio.tail1234.ts.net`, or nil when Tailscale cannot say.
    @Sendable public static func dnsName() async -> String? {
        guard let executable = executables.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        let result = await onOwnThread {
            try? Subprocess.run(
                executable, ["status", "--json"], environment: [:], directory: nil,
                timeout: .seconds(3))
        }
        guard let result, result.status == 0 else { return nil }
        return dnsName(fromStatusJSON: result.stdout)
    }

    static func dnsName(fromStatusJSON data: Data) -> String? {
        struct Status: Decodable {
            struct Node: Decodable {
                var dnsName: String?

                enum CodingKeys: String, CodingKey {
                    case dnsName = "DNSName"
                }
            }
            var node: Node?

            enum CodingKeys: String, CodingKey {
                case node = "Self"
            }
        }
        guard let name = (try? JSONDecoder().decode(Status.self, from: data))?.node?.dnsName else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
