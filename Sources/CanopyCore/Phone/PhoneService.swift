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
    /// Each connection's inbox subscription, by the request that started it and the hub's ID, so a second
    /// `phone.subscribe` replaces the first.
    private let subscriptions = Mutex<[ObjectIdentifier: (request: String, hub: UUID)]>([:])
    /// Each connection's conversations and screens being followed.
    private let streams = PhoneStreams()
    private let panes: PhonePanes
    /// How much scrollback the first screen carries.
    static let screenScrollback = 500
    /// Lets the listener's handler reach the service until `stop`.
    private let handle: ServiceHandle

    public init(
        home: CanopyHome, hub: PhoneHub, panes: PhonePanes, activity: ActivityLog, listen: PhoneListenAddress,
        macName: String,
        tailscaleAddresses: @escaping @Sendable () -> [String] = TailscaleAddresses.current,
        dnsName: @escaping @Sendable () async -> String? = TailscaleStatus.dnsName
    ) {
        let registry = PhoneRegistry(file: home.phonesFile)
        self.registry = registry
        self.hub = hub
        self.panes = panes
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
        do {
            return try await respond(to: request, session)
        } catch let error as WorkspaceError {
            return PhoneReply(.failure(id: request.id, error: ControlError(error)))
        } catch let error as ControlError {
            return PhoneReply(.failure(id: request.id, error: error))
        } catch {
            return PhoneReply(.failure(id: request.id, error: ControlError(code: "internal", message: "\(error)")))
        }
    }

    private func respond(to request: ControlRequest, _ session: PhoneSession) async throws -> PhoneReply {
        func success(_ value: some Encodable) throws -> PhoneReply {
            PhoneReply(.success(id: request.id, result: try .from(value)))
        }
        switch request.method {
        case PhoneMethod.subscribe:
            return try subscribeToInbox(request, session, inbox: await hub.inbox)

        case PhoneMethod.rows:
            return try success(await hub.rows)

        case PhoneMethod.transcript:
            let params = try request.decodeParams(PhoneTranscriptParams.self)
            guard params.limit > 0, params.limit <= 500 else {
                throw ControlError(code: "bad_params", message: "limit must be from 1 to 500.")
            }
            let url = try await panes.transcriptURL(params.pane)
            let page: TranscriptReader.Page
            do {
                page = try TranscriptReader.page(of: url, before: params.before, limit: params.limit)
            } catch TranscriptReader.Failure.missing {
                throw PhonePanes.noTranscript
            }
            let result = PhoneTranscriptResult(pane: params.pane, entries: page.entries, older: page.older)
            guard params.follow else { return try success(result) }
            try streams.reserve(on: session)
            let panes = self.panes
            let follower = TranscriptFollower(
                pane: params.pane, following: url.path,
                path: { try? await panes.transcriptURL(params.pane).path }, sent: page.entries
            ) { update in
                guard let data = try? JSONValue.from(update) else { return }
                session.send(PhoneEvent(event: PhoneEvent.transcript, subscription: request.id, data: data))
            }
            return PhoneReply(.success(id: request.id, result: try .from(result))) { [streams] in
                streams.add(request.id, on: session) { follower.stop() }
                follower.start()
            }

        case PhoneMethod.screen:
            let params = try request.decodeParams(PhonePaneParams.self)
            let first = try await panes.screen(params, scrollback: PhoneService.screenScrollback)
            try streams.reserve(on: session)
            let watcher = await ScreenWatcher(panes: panes, pane: params.pane, after: first.lines) { screen in
                guard let data = try? JSONValue.from(screen) else { return }
                session.send(PhoneEvent(event: PhoneEvent.screen, subscription: request.id, data: data))
            }
            return PhoneReply(.success(id: request.id, result: try .from(first))) { [streams] in
                streams.add(request.id, on: session) { Task { await watcher.stop() } }
                await watcher.start()
            }

        case PhoneMethod.reply:
            let params = try request.decodeParams(PhoneReplyParams.self)
            try await panes.reply(params) {
                guard let data = try? JSONValue.from(PhoneDelivered(pane: params.pane, reply: request.id)) else {
                    return
                }
                session.send(PhoneEvent(event: PhoneEvent.delivered, subscription: request.id, data: data))
            }
            record(
                request, session, pane: params.pane, extra: activity.logsCommands ? ["text": .string(params.text)] : [:]
            )
            return try success(PhoneReplyResult(reply: request.id))

        case PhoneMethod.answer:
            let params = try request.decodeParams(PhoneAnswerParams.self)
            try await panes.answer(params)
            record(request, session, pane: params.pane, extra: ["answer": (try? .from(params.answer)) ?? .null])
            return try success(PhonePaneParams(pane: params.pane))

        case PhoneMethod.keys:
            let params = try request.decodeParams(PhoneKeysParams.self)
            try await panes.keys(params)
            record(request, session, pane: params.pane)
            return try success(PhonePaneParams(pane: params.pane))

        case PhoneMethod.seen:
            let params = try request.decodeParams(PhonePaneParams.self)
            try await panes.seen(params)
            return try success(params)

        case PhoneMethod.unsubscribe:
            let params = try request.decodeParams(PhoneUnsubscribeParams.self)
            if let hubID = inboxSubscription(session, id: params.subscription) {
                await hub.unsubscribe(hubID)
            } else {
                streams.remove(params.subscription, on: session)
            }
            return try success(params)

        default:
            throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
        }
    }

    /// The inbox, then its changes. A second subscribe on the connection replaces the first.
    private func subscribeToInbox(_ request: ControlRequest, _ session: PhoneSession, inbox: PhoneInbox) throws
        -> PhoneReply
    {
        let connection = ObjectIdentifier(session.connection)
        // Runs after the response, in the connection's order, so two subscribes never interleave here.
        return PhoneReply(.success(id: request.id, result: try .from(inbox))) { [self] in
            let previous = subscriptions.withLock { $0[connection]?.hub }
            let id = await hub.subscribe(after: inbox, replacing: previous) { inbox in
                guard let data = try? JSONValue.from(inbox) else { return }
                session.send(PhoneEvent(event: PhoneEvent.inbox, subscription: request.id, data: data))
            }
            subscriptions.withLock { $0[connection] = (request.id, id) }
            guard previous == nil else { return }
            session.onClose { [self] in
                let current = subscriptions.withLock { $0.removeValue(forKey: connection) }
                if let current { Task { await hub.unsubscribe(current.hub) } }
            }
        }
    }

    /// The hub's ID for the connection's inbox, when `id` names it, which it forgets.
    private func inboxSubscription(_ session: PhoneSession, id: String) -> UUID? {
        let connection = ObjectIdentifier(session.connection)
        return subscriptions.withLock { subscriptions in
            guard let current = subscriptions[connection], current.request == id else { return nil }
            subscriptions[connection] = nil
            return current.hub
        }
    }

    /// Logs a phone's call that changed something, with the phone's name, as CLI calls are logged.
    private func record(
        _ request: ControlRequest, _ session: PhoneSession, pane: String, extra: [String: JSONValue] = [:]
    ) {
        var data = extra
        data["method"] = .string(request.method)
        data["phone"] = .string(session.phone.name)
        data["pane"] = .string(pane)
        activity.record(ActivityType.phoneCall, source: .phone, data: data)
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
