import CanopyWire
import Foundation
import Observation

/// Every server this phone paired with, in pairing order, each with its own connection, and pairing with more.
@MainActor @Observable
public final class Servers {
    public private(set) var connections: [ServerConnection]

    private let transport: any PhoneTransport
    private let credentials: any CredentialStore
    private let phoneName: String
    private let timeout: Duration
    private let sleep: Sleep
    private let now: @Sendable () -> Date

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
        connections = []
        connections = credentials.loadAll().map(connection(for:))
    }

    private func connection(for server: PairedServer) -> ServerConnection {
        ServerConnection(
            server: server, transport: transport, credentials: credentials, timeout: timeout, sleep: sleep, now: now)
    }

    /// The servers that still know this phone.
    public var paired: [ServerConnection] { connections.filter(\.isPaired) }

    /// Whether any server still knows this phone. Without one the app is back at Pairing.
    public var isPaired: Bool { connections.contains(where: \.isPaired) }

    /// Why the phone is back at Pairing, when the last server that knew it forgot it.
    public var pairingNotice: String? {
        guard !isPaired else { return nil }
        let last = connections.filter { $0.forgottenAt != nil }.max { $0.forgottenAt! < $1.forgottenAt! }
        guard case .unpaired(let notice) = last?.status else { return nil }
        return notice
    }

    /// Whether a row a server sent shows here: not the Mac's copy of a row on a box this phone pairs with, which the
    /// box serves itself, reachable or not.
    public func shows(_ row: PhoneRow, from connection: ServerConnection) -> Bool {
        guard !connection.isBox, let host = row.host else { return true }
        return !connections.contains { $0.isBox && $0.isPaired && $0.name == host }
    }

    public func connection(id: String) -> ServerConnection? {
        connections.first { $0.id == id }
    }

    public func start() {
        for connection in connections { connection.start() }
    }

    public func foreground() {
        for connection in connections { connection.foreground() }
    }

    public func background() {
        for connection in connections { connection.background() }
    }

    /// Trades the link's one-time code for a token, then says hello on the same connection and subscribes. A server
    /// paired before, by where it listens, takes the new pairing in its old place and keeps its connection until the
    /// new pairing works; any other is added after the rest.
    @discardableResult
    public func pair(_ link: PairingLink) async throws -> ServerConnection {
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
                    let existing = connections.first { $0.server.isServer(of: link) }
                    let server = PairedServer(
                        id: existing?.id ?? UUID().uuidString,
                        kind: result.kind ?? link.kind ?? PhoneServerKind.mac, name: result.mac, host: link.host,
                        port: link.port, address: link.address, token: result.token, phone: result.phone,
                        pairedAt: existing?.server.pairedAt ?? now())
                    do {
                        try credentials.save(server)
                    } catch {
                        // The server took the one-time code, so no other host can use it again.
                        throw PairingKept(problem: PhoneProblem(error, server: link.host))
                    }
                    if let existing {
                        existing.pairAgain(with: server, opened: client)
                        return existing
                    }
                    let added = connection(for: server)
                    connections.append(added)
                    added.start(opened: client)
                    return added
                } catch {
                    await client.close()
                    throw error
                }
            } catch let error as ControlError {
                throw PhoneProblem(error, server: host)
            } catch let kept as PairingKept {
                throw kept.problem
            } catch {
                lastError = error
            }
        }
        throw PhoneProblem(lastError ?? PhoneTransportError.closed, server: link.host)
    }

    /// Forgets the server here. It still lists this phone until `canopy phone remove`.
    public func remove(id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections.remove(at: index).end()
        credentials.remove(id: id)
    }
}

/// A pairing the server granted but the phone could not keep, which no other host may try again.
private struct PairingKept: Error {
    var problem: PhoneProblem
}
