import CanopyAgents
import CanopyWire
import Foundation
import Synchronization

/// A phone server: the paired phones, the listener they reach, and what they may call, over a `PhoneSource`.
public final class PhoneServer: Sendable {
    public let registry: PhoneRegistry
    private let listener: PhoneListener
    private let source: any PhoneSource
    private let settings: PhoneServerSettings
    private let lastRefreshError = Mutex<String?>(nil)
    /// Each connection's inbox subscription, by the request that started it and the source's ID, so a second
    /// `phone.subscribe` replaces the first.
    private let subscriptions = Mutex<[ObjectIdentifier: (request: String, source: UUID)]>([:])
    /// Each connection's conversations and screens being followed.
    private let streams = PhoneStreams()
    /// How much scrollback the first screen carries.
    static let screenScrollback = 500
    /// Lets the listener's handler reach the server until `stop`.
    private let handle: ServerHandle

    public init(source: any PhoneSource, settings: PhoneServerSettings, helloTimeout: Duration = .seconds(10)) {
        let registry = PhoneRegistry(file: settings.registryFile)
        self.registry = registry
        self.source = source
        self.settings = settings
        let handle = ServerHandle()
        let record = settings.record
        listener = PhoneListener(
            port: settings.port, addresses: settings.addresses,
            gate: PhoneGate(
                registry: registry, name: settings.serverName, kind: settings.kind, wake: settings.wake,
                agentCommand: settings.agentCommand, version: settings.version,
                helloTimeout: helloTimeout,
                handler: { request, session in
                    guard let server = handle.server.withLock({ $0 }) else {
                        return PhoneReply(
                            .failure(
                                id: request.id, error: ControlError(code: "internal", message: "Canopy is quitting.")))
                    }
                    return await server.handle(request, session)
                },
                onPaired: { phone in record(.paired(phone: phone.name)) }))
        self.handle = handle
        handle.server.withLock { $0 = self }
    }

    public func stop() {
        listener.stop()
        handle.server.withLock { $0 = nil }
    }

    /// Listens on the addresses there are now and lets go of the rest.
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
            return try subscribeToInbox(request, session, inbox: await source.inbox())

        case PhoneMethod.rows:
            return try success(await source.rows())

        case PhoneMethod.transcript:
            let params = try request.decodeParams(PhoneTranscriptParams.self)
            guard params.limit > 0, params.limit <= 500 else {
                throw ControlError(code: "bad_params", message: "limit must be from 1 to 500.")
            }
            guard !(params.follow && params.before != nil) else {
                throw ControlError(code: "bad_params", message: "Follow the newest page, without before.")
            }
            let url = try await source.transcriptURL(params.pane)
            // A session that has not written its transcript yet has an empty conversation, which may still grow.
            let page =
                (try? TranscriptReader.page(of: url, before: params.before, limit: params.limit))
                ?? TranscriptReader.Page(entries: [], older: nil)
            let result = PhoneTranscriptResult(pane: params.pane, entries: page.entries, older: page.older)
            guard params.follow else { return try success(result) }
            try streams.reserve(on: session)
            let source = self.source
            let follower = TranscriptFollower(
                pane: params.pane, following: url.path,
                path: { try? await source.transcriptURL(params.pane).path }, sent: page.entries
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
            let first = try await source.screen(params, scrollback: Self.screenScrollback)
            try streams.reserve(on: session)
            let watcher = ScreenWatcher(source: source, pane: params.pane, after: first.lines) { screen in
                guard let data = try? JSONValue.from(screen) else { return }
                session.send(
                    PhoneEvent(event: PhoneEvent.screen, subscription: request.id, data: data), latestOnly: true)
            }
            return PhoneReply(.success(id: request.id, result: try .from(first))) { [streams] in
                streams.add(request.id, on: session) { Task { await watcher.stop() } }
                await watcher.start()
            }

        case PhoneMethod.reply:
            let params = try request.decodeParams(PhoneReplyParams.self)
            try await source.reply(params) {
                guard let data = try? JSONValue.from(PhoneDelivered(pane: params.pane, reply: request.id)) else {
                    return
                }
                session.send(PhoneEvent(event: PhoneEvent.delivered, subscription: request.id, data: data))
            }
            record(
                request, session, pane: params.pane,
                extra: settings.logsCommands() ? ["text": .string(params.text)] : [:])
            return try success(PhoneReplyResult(reply: request.id))

        case PhoneMethod.answer:
            let params = try request.decodeParams(PhoneAnswerParams.self)
            try await source.answer(params)
            record(request, session, pane: params.pane, extra: ["answer": (try? .from(params.answer)) ?? .null])
            return try success(PhonePaneParams(pane: params.pane))

        case PhoneMethod.keys:
            let params = try request.decodeParams(PhoneKeysParams.self)
            try await source.keys(params)
            record(request, session, pane: params.pane)
            return try success(PhonePaneParams(pane: params.pane))

        case PhoneMethod.seen:
            let params = try request.decodeParams(PhonePaneParams.self)
            try await source.seen(params)
            return try success(params)

        case PhoneMethod.unsubscribe:
            let params = try request.decodeParams(PhoneUnsubscribeParams.self)
            if let sourceID = inboxSubscription(session, id: params.subscription) {
                await source.unsubscribe(sourceID)
            } else {
                streams.remove(params.subscription, on: session)
            }
            return try success(params)

        case PhoneMethod.newRow:
            var params = try request.decodeParams(PhoneNewRowParams.self)
            params.repo = params.repo.trimmingCharacters(in: .whitespacesAndNewlines)
            params.branch = params.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            params.base = params.base?.trimmingCharacters(in: .whitespacesAndNewlines)
            if params.base?.isEmpty == true { params.base = nil }
            guard !params.repo.isEmpty, !params.branch.isEmpty else {
                throw ControlError(code: "bad_params", message: "A new task needs a repo and a branch.")
            }
            guard params.brief.utf8.count <= PhoneAgentCommand.briefLimit else {
                throw ControlError(
                    code: "bad_params",
                    message: "The brief is too long. Keep it under \(PhoneAgentCommand.briefLimit / 1024) KB.")
            }
            guard !params.brief.contains("\u{0}") else {
                throw ControlError(
                    code: "bad_params", message: "The brief holds a NUL character, which no shell can pass on.")
            }
            let line = PhoneAgentCommand.line(settings.agentCommand(), brief: params.brief)
            let made = try await source.newRow(params, line: line)
            var extra: [String: JSONValue] = ["repo": .string(params.repo), "branch": .string(made.branch)]
            if settings.logsCommands() { extra["brief"] = .string(params.brief) }
            record(request, session, pane: made.pane, extra: extra)
            return try success(made)

        default:
            throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
        }
    }

    /// The inbox, then its changes. A second subscribe on the connection replaces the first.
    private func subscribeToInbox(_ request: ControlRequest, _ session: PhoneSession, inbox: PhoneInbox) throws
        -> PhoneReply
    {
        let connection = session.connectionID
        // Runs after the response, in the connection's order, so two subscribes never interleave here.
        return PhoneReply(.success(id: request.id, result: try .from(inbox))) { [self] in
            let previous = subscriptions.withLock { $0[connection]?.source }
            let id = await source.subscribe(after: inbox, replacing: previous) { inbox in
                guard let data = try? JSONValue.from(inbox) else { return }
                session.send(
                    PhoneEvent(event: PhoneEvent.inbox, subscription: request.id, data: data), latestOnly: true)
            }
            subscriptions.withLock { $0[connection] = (request.id, id) }
            guard previous == nil else { return }
            session.onClose { [self] in
                let current = subscriptions.withLock { $0.removeValue(forKey: connection) }
                if let current { Task { await source.unsubscribe(current.source) } }
            }
        }
    }

    /// The source's ID for the connection's inbox, when `id` names it, which it forgets.
    private func inboxSubscription(_ session: PhoneSession, id: String) -> UUID? {
        let connection = session.connectionID
        return subscriptions.withLock { subscriptions in
            guard let current = subscriptions[connection], current.request == id else { return nil }
            subscriptions[connection] = nil
            return current.source
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
        settings.record(.call(data))
    }

    // MARK: What `canopy phone` calls

    public func pair() async throws -> PhonesPairResult {
        guard let endpoint = preferred(listener.endpoints) else {
            throw ControlError(
                code: "phone_listener_closed",
                message: "Canopy is not listening for phones. \(closedReason) canopy phone status says more.")
        }
        let name = await settings.tailnetName()
        let code = await registry.newCode()
        let link = PairingLink(
            host: name ?? endpoint.address, port: endpoint.port, code: code.code, address: endpoint.address,
            kind: settings.kind)
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
        settings.record(.removed(phone: phone.name))
        return PhoneInfo(phone, connected: connected)
    }

    public func status() async -> PhonesStatusResult {
        let endpoints = listener.endpoints
        var problem = settings.statusNote
        if endpoints.isEmpty {
            problem = [closedReason, problem].compactMap { $0 }.joined(separator: " ")
        }
        let name = endpoints.isEmpty ? nil : await settings.tailnetName()
        return PhonesStatusResult(
            listening: !endpoints.isEmpty, endpoints: endpoints, host: name, problem: problem, phones: await list(),
            notifications: PhonesStatusResult.noPushKey)
    }

    private var closedReason: String {
        if let error = lastRefreshError.withLock({ $0 }) {
            return "It could not listen: \(error)."
        }
        return settings.closedReason()
    }

    /// IPv4 first, since every phone's network reaches it.
    private func preferred(_ endpoints: [PhoneEndpoint]) -> PhoneEndpoint? {
        endpoints.first { !$0.address.contains(":") } ?? endpoints.first
    }
}

private final class ServerHandle: Sendable {
    let server = Mutex<PhoneServer?>(nil)
}
