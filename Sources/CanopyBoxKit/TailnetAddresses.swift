import CanopySystem
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The box's addresses on its tailnet, which phones reach it at: on `tailscale0`, in Tailscale's ranges
/// `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, as the Mac's rule has them.
public enum TailnetAddresses {
    /// The addresses among `interfaces`, by interface name, that are the tailnet's.
    public static func tailnet(_ interfaces: [(name: String, address: String)]) -> [String] {
        interfaces.filter { $0.name == "tailscale0" && isTailnet($0.address) }.map(\.address)
    }

    static func isTailnet(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// The tailnet addresses now, or `override`'s, a comma-separated list only tests set.
    public static func current(override: String? = ProcessInfo.processInfo.environment["CANOPY_BOX_PHONE_ADDRESS"])
        -> [String]
    {
        if let override, !override.isEmpty { return override.split(separator: ",").map(String.init) }
        return tailnet(interfaces())
    }

    /// Every interface's numeric addresses, from getifaddrs(3).
    static func interfaces() -> [(name: String, address: String)] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [(String, String)] = []
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let size = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append(
                (String(cString: entry.pointee.ifa_name), text.split(separator: "%").first.map(String.init) ?? text))
        }
        return found
    }

    /// This machine's name on the tailnet, from `tailscale status --json`, without its trailing dot.
    public static func name(fromStatus json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let me = object["Self"] as? [String: Any], let name = me["DNSName"] as? String, !name.isEmpty
        else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Asks Tailscale's CLI for the name, or nil when it does not answer.
    public static func name(environment: [String: String] = ProcessInfo.processInfo.environment) async -> String? {
        guard let tailscale = Tmux.find("tailscale", path: environment["PATH"]) else { return nil }
        let result = await onOwnThread {
            try? Subprocess.run(
                tailscale, ["status", "--json"], environment: environment, directory: nil, timeout: .seconds(5))
        }
        guard let result, result.status == 0 else { return nil }
        return name(fromStatus: result.stdout)
    }
}
