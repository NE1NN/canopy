import Foundation
import Network
import Synchronization

/// Where the listener took its port, once it is listening.
public struct PhoneEndpoint: Codable, Sendable, Equatable {
    public var address: String
    public var port: UInt16
}

/// Listens for phones on TCP, on each address `addresses` gives and nowhere else. `refresh` binds new addresses and
/// closes those that went away, with their connections.
public final class PhoneListener: Sendable {
    private let port: UInt16
    private let addresses: @Sendable () -> [String]
    private let gate: PhoneGate
    private let queue = DispatchQueue(label: "canopy.phone-listener")
    private let listeners = Mutex<[String: Bound]>([:])
    private let connections = Mutex<[ObjectIdentifier: PhoneConnection]>([:])
    /// Serializes `refresh` calls, which network changes can start close together.
    private let refreshing = Mutex<Task<Void, any Error>?>(nil)

    private struct Bound: Sendable {
        let listener: NWListener
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
        let wanted = Set(addresses())
        let gone = listeners.withLock { bound in
            let gone = bound.filter { !wanted.contains($0.key) }
            for address in gone.keys { bound[address] = nil }
            return gone
        }
        for (address, bound) in gone {
            bound.listener.cancel()
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
        let bound = listeners.withLock { bound in
            defer { bound = [:] }
            return bound
        }
        for listener in bound.values { listener.listener.cancel() }
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
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, on: address)
        }
        let once = Mutex(false)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>? =
                    switch state {
                    case .ready: .success(listener.port?.rawValue ?? 0)
                    case .failed(let error): .failure(error)
                    case .cancelled: .failure(CancellationError())
                    default: nil
                    }
                guard let result,
                    once.withLock({ claimed in
                        defer { claimed = true }
                        return !claimed
                    })
                else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = { [weak self] state in
            // A listener that fails later, as when its address goes away, is bound again by the next refresh.
            if case .failed = state {
                listener.cancel()
                self?.listeners.withLock { bound in
                    if bound[address]?.listener === listener { bound[address] = nil }
                }
            }
        }
        return Bound(listener: listener, port: port)
    }

    private func accept(_ nw: NWConnection, on address: String) {
        let connection = PhoneConnection(connection: nw, localAddress: address, gate: gate, queue: queue)
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        connection.onClosed = { [weak self] in
            self?.connections.withLock { $0[key] = nil }
        }
        connection.start()
    }
}

/// An address on one of this Mac's network interfaces.
public struct NetworkInterfaceAddress: Sendable, Equatable {
    public var interface: String
    public var address: String

    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }

    /// Every IPv4 and IPv6 address on this Mac's interfaces, from getifaddrs(3).
    public static func current() -> [NetworkInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [NetworkInterfaceAddress] = []
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append(
                NetworkInterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: text))
        }
        return found
    }
}

/// Picks the Mac's Tailscale addresses: those in 100.64.0.0/10 or fd7a:115c:a1e0::/48 on a `utun` interface.
public enum TailscaleAddresses {
    public static func select(_ addresses: [NetworkInterfaceAddress]) -> [String] {
        addresses.filter { $0.interface.hasPrefix("utun") && isTailscale($0.address) }.map(\.address)
    }

    public static func current() -> [String] {
        select(NetworkInterfaceAddress.current())
    }

    static func isTailscale(_ address: String) -> Bool {
        if let v4 = IPv4Address(address) {
            let bytes = Array(v4.rawValue)
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        }
        if let v6 = IPv6Address(address) {
            return Array(v6.rawValue.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        }
        return false
    }
}

/// Where the phone listener listens. A dev build takes one address from `CANOPY_PHONE_LISTEN`, such as
/// `127.0.0.1:7123`, so tests and `make e2e` reach it over loopback on a Mac without Tailscale. A release build never
/// does, so nothing but the tailnet ever reaches it.
public struct PhoneListenAddress: Sendable, Equatable {
    public static let environmentKey = "CANOPY_PHONE_LISTEN"

    /// The one address to listen on in place of the Tailscale addresses.
    public var override: String?
    public var port: UInt16
    /// An override that was set but not used, because this build refuses it or it did not parse.
    public var ignoredOverride: String?

    public static func resolve(environment: [String: String], allowsOverride: Bool) -> PhoneListenAddress {
        let standard = PhoneListenAddress(override: nil, port: PhonePort.standard, ignoredOverride: nil)
        guard let text = environment[environmentKey], !text.isEmpty else { return standard }
        guard allowsOverride, let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...])
        else { return PhoneListenAddress(override: nil, port: PhonePort.standard, ignoredOverride: text) }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard IPv4Address(host) != nil || IPv6Address(host) != nil else {
            return PhoneListenAddress(override: nil, port: PhonePort.standard, ignoredOverride: text)
        }
        return PhoneListenAddress(override: host, port: port, ignoredOverride: nil)
    }
}
