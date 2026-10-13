import Foundation

/// What the QR code from `canopy phone pair` holds: where the Mac listens, and the one-time code.
public struct PairingLink: Sendable, Equatable {
    public static let scheme = "canopy-phone"

    /// The Mac's MagicDNS name, or its Tailscale address when it has no name.
    public var host: String
    public var port: UInt16
    public var code: String
    /// The Mac's Tailscale address, tried when the name does not resolve.
    public var address: String?
    /// `PhoneServerKind`'s; nil from a Mac older than several servers.
    public var kind: String?

    public init(host: String, port: UInt16, code: String, address: String?, kind: String? = nil) {
        self.host = host
        self.port = port
        self.code = code
        self.address = address
        self.kind = kind
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == Self.scheme,
            parts.host == "pair"
        else { return nil }
        let items = Dictionary(
            (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard let host = items["host"], !host.isEmpty, let code = items["code"], !code.isEmpty,
            let port = items["port"].flatMap(UInt16.init), port > 0
        else { return nil }
        self.init(
            host: host, port: port, code: code, address: items["addr"].flatMap { $0.isEmpty ? nil : $0 },
            kind: items["kind"].flatMap { $0.isEmpty ? nil : $0 })
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        parts.queryItems =
            [
                URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "code", value: code),
            ] + (address.map { [URLQueryItem(name: "addr", value: $0)] } ?? [])
            + (kind.map { [URLQueryItem(name: "kind", value: $0)] } ?? [])
        // Every value is plain ASCII, so the URL always forms.
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// The hosts to try, in order.
    public var hosts: [String] {
        guard let address, address != host else { return [host] }
        return [host, address]
    }
}
