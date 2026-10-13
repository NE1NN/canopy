import CanopySystem
import Foundation
import Synchronization

/// Where the listener took its port, once it is listening.
public struct PhoneEndpoint: Codable, Sendable, Equatable {
    public var address: String
    public var port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// Listens for phones on TCP, on each address `addresses` gives and nowhere else. `refresh` binds new addresses and
/// closes those that went away, with their connections. An address that cannot be had now, as when another program
/// holds the port, fails this refresh and is tried again on the next.
public final class PhoneListener: Sendable {
    private let port: UInt16
    private let addresses: @Sendable () -> [String]
    private let gate: PhoneGate
    private let listeners = Mutex<[String: Bound]>([:])
    private let connections = Mutex<[ObjectIdentifier: PhoneConnection]>([:])
    /// Set by `stop`, after which a refresh already queued binds nothing.
    private let stopped = Mutex(false)
    /// Serializes `refresh` calls, which network changes can start close together.
    private let refreshing = Mutex<Task<Void, any Error>?>(nil)

    private struct Bound: Sendable {
        let listener: TCPListener
        let port: UInt16
    }

    /// `port` 0 takes any free port on each address, for tests.
    public init(port: UInt16, addresses: @escaping @Sendable () -> [String], gate: PhoneGate) {
        self.port = port
        self.addresses = addresses
        self.gate = gate
    }

    public var endpoints: [PhoneEndpoint] {
        listeners.withLock { $0.map { PhoneEndpoint(address: $0.key, port: $0.value.port) } }
            .sorted { $0.address < $1.address }
    }

    /// Phones with a connection that said hello, by ID.
    public var connectedPhoneIDs: Set<String> {
        Set(connections.withLock { Array($0.values) }.compactMap(\.phoneID))
    }

    /// Binds to the addresses there are now and lets go of the rest. Throws the first bind that failed, after trying
    /// every address.
    public func refresh() async throws {
        let task = refreshing.withLock { last in
            let previous = last
            let next = Task {
                _ = await previous?.result
                try await self.reconcile()
            }
            last = next
            return next
        }
        try await task.value
    }

    private func reconcile() async throws {
        let wanted = stopped.withLock { $0 } ? [] : Set(addresses())
        let gone = listeners.withLock { bound in
            let gone = bound.filter { !wanted.contains($0.key) }
            for address in gone.keys { bound[address] = nil }
            return gone
        }
        for (address, bound) in gone {
            bound.listener.close()
            closeConnections(on: address)
        }
        var failure: (any Error)?
        for address in wanted.sorted() where listeners.withLock({ $0[address] == nil }) {
            do {
                let bound = try await bind(address)
                listeners.withLock { $0[address] = bound }
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    public func stop() {
        stopped.withLock { $0 = true }
        let bound = listeners.withLock { bound in
            defer { bound = [:] }
            return bound
        }
        for listener in bound.values { listener.listener.close() }
        for connection in connections.withLock({ Array($0.values) }) { connection.close() }
    }

    /// Closes every connection of a phone that was removed.
    public func disconnect(phoneID: String) {
        for connection in connections.withLock({ Array($0.values) }) where connection.phoneID == phoneID {
            connection.close()
        }
    }

    private func closeConnections(on address: String) {
        for connection in connections.withLock({ Array($0.values) }) where connection.localAddress == address {
            connection.close()
        }
    }

    private func bind(_ address: String) async throws -> Bound {
        // A phone that vanishes without closing, as when it sleeps or leaves Wi-Fi, is noticed within a minute.
        let options = TCPOptions(keepalive: TCPOptions.Keepalive(idle: 30, interval: 10, count: 3))
        let listener = try TCPListener(address: address, port: port, options: options) { [weak self] connection in
            self?.accept(connection, on: address)
        }
        return Bound(listener: listener, port: listener.port)
    }

    private func accept(_ tcp: TCPConnection, on address: String) {
        let connection = PhoneConnection(connection: tcp, localAddress: address, gate: gate)
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        connection.onClosed = { [weak self] in
            self?.connections.withLock { $0[key] = nil }
        }
        connection.start()
    }
}
