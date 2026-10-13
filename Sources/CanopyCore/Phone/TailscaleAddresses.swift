import Foundation
import Network

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

/// Where the phone listener listens. A release build listens on every Tailscale address and nowhere else. A dev build
/// listens only on the one address `CANOPY_PHONE_LISTEN` gives, such as `127.0.0.1:7123`, so tests and `make e2e` reach
/// it over loopback, and it never takes the tailnet port from the release app.
public enum PhoneListenAddress: Sendable, Equatable {
    public static let environmentKey = "CANOPY_PHONE_LISTEN"

    /// `ignored` is an override this build refused.
    case tailscale(port: UInt16, ignored: String?)
    case address(String, port: UInt16)
    /// A dev build without an override, or with one that is not an address and port.
    case closed(malformed: String?)

    public static func resolve(environment: [String: String], allowsOverride: Bool) -> PhoneListenAddress {
        let text = environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
        guard allowsOverride else { return .tailscale(port: PhonePort.standard, ignored: text) }
        guard let text else { return .closed(malformed: nil) }
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else {
            return .closed(malformed: text)
        }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard IPv4Address(host) != nil || IPv6Address(host) != nil else { return .closed(malformed: text) }
        return .address(host, port: port)
    }

    var port: UInt16 {
        switch self {
        case .tailscale(let port, _), .address(_, let port): port
        case .closed: 0
        }
    }
}
