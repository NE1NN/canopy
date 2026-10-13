import CanopyWire
import Foundation
import Security
import Synchronization

/// A server this phone paired with, a Mac or a host's canopy-box, and the device token that proves it.
public struct PairedServer: Codable, Sendable, Equatable, Identifiable {
    /// Made at pairing, so two servers with the same name stay apart.
    public var id: String
    /// `PhoneServerKind`'s.
    public var kind: String
    /// The server's name, as it says in hello: the Mac's, or the host's alias there.
    public var name: String
    /// The server's MagicDNS name, or its Tailscale address when it has none.
    public var host: String
    public var port: UInt16
    /// The server's Tailscale address, tried when the name does not resolve.
    public var address: String?
    public var token: String
    /// The name the server knows this phone by.
    public var phone: String
    /// Canopy's version on the server, as of the last hello.
    public var version: String?
    /// When it was paired, which orders the servers, since the Keychain keeps no order.
    public var pairedAt: Date
    /// Why the server no longer counts as paired, once it forgot this phone, so it stays that way after a relaunch.
    public var unpairedNotice: String?

    public init(
        id: String = UUID().uuidString, kind: String = PhoneServerKind.mac, name: String, host: String, port: UInt16,
        address: String?, token: String, phone: String, version: String? = nil, pairedAt: Date = Date(),
        unpairedNotice: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.address = address
        self.token = token
        self.phone = phone
        self.version = version
        self.pairedAt = pairedAt
        self.unpairedNotice = unpairedNotice
    }

    public var isBox: Bool { kind == PhoneServerKind.box }

    /// The hosts to try, in order.
    public var hosts: [String] {
        guard let address, address != host else { return [host] }
        return [host, address]
    }

    /// Whether a pairing link is for this server again, by where it listens.
    public func isServer(of link: PairingLink) -> Bool {
        port == link.port && !Set(hosts).isDisjoint(with: link.hosts)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, host, port, address, token, phone, version, pairedAt, unpairedNotice
        /// The name's key from before several servers, when the one server was always the Mac.
        case mac
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? PhoneServerKind.mac
        name =
            try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .mac)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        token = try container.decode(String.self, forKey: .token)
        phone = try container.decode(String.self, forKey: .phone)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        pairedAt = try container.decodeIfPresent(Date.self, forKey: .pairedAt) ?? .distantPast
        unpairedNotice = try container.decodeIfPresent(String.self, forKey: .unpairedNotice)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(token, forKey: .token)
        try container.encode(phone, forKey: .phone)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(pairedAt, forKey: .pairedAt)
        try container.encodeIfPresent(unpairedNotice, forKey: .unpairedNotice)
    }
}

/// Where the paired servers and their tokens live between launches.
public protocol CredentialStore: Sendable {
    /// Every paired server, in the order they were paired.
    func loadAll() -> [PairedServer]
    func save(_ server: PairedServer) throws
    func remove(id: String)
}

extension [PairedServer] {
    /// In pairing order, the first paired first.
    func inPairingOrder() -> [PairedServer] {
        sorted { $0.pairedAt == $1.pairedAt ? $0.id < $1.id : $0.pairedAt < $1.pairedAt }
    }
}

/// The Keychain's generic passwords for one service, by account.
public protocol KeychainItems: Sendable {
    func all() -> [(account: String, data: Data)]
    /// Replaces the account's item in place, or adds it.
    func write(_ data: Data, account: String) -> OSStatus
    func delete(account: String)
}

/// This device's own Keychain. Items never go into a backup another device can restore.
public struct SystemKeychain: KeychainItems {
    public var service: String

    public init(service: String) {
        self.service = service
    }

    private func query(account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func all() -> [(account: String, data: Data)] {
        var search = query(account: nil)
        search[kSecReturnData as String] = true
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess,
            let items = found as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                let data = item[kSecValueData as String] as? Data
            else { return nil }
            return (account, data)
        }
    }

    public func write(_ data: Data, account: String) -> OSStatus {
        let item = query(account: account)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var added = item
        added[kSecValueData as String] = data
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(added as CFDictionary, nil)
    }

    public func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// Each server's token in the Keychain, one item each.
public struct KeychainCredentialStore: CredentialStore {
    let items: any KeychainItems

    public init(service: String = "com.ne1nn.Canopy.Phone") {
        items = SystemKeychain(service: service)
    }

    init(items: any KeychainItems) {
        self.items = items
    }

    /// The one item from before several servers, always the Mac's, which the first load moves to its own.
    static let legacyAccount = "mac"
    /// The moved server's id, the same however many launches the move takes, so it is never there twice.
    static let legacyID = "mac"

    private static func account(_ id: String) -> String { "server.\(id)" }

    public func loadAll() -> [PairedServer] {
        let stored = items.all()
        var servers = stored.compactMap { item -> PairedServer? in
            guard item.account != Self.legacyAccount else { return nil }
            return try? JSONDecoder().decode(PairedServer.self, from: item.data)
        }
        if let legacy = stored.first(where: { $0.account == Self.legacyAccount }),
            var server = try? JSONDecoder().decode(PairedServer.self, from: legacy.data)
        {
            server.id = Self.legacyID
            if servers.contains(where: { $0.id == server.id }) {
                // Moved on an earlier launch whose delete failed.
                items.delete(account: Self.legacyAccount)
            } else {
                // The legacy item goes only once its server is safe in its own.
                if (try? save(server)) != nil { items.delete(account: Self.legacyAccount) }
                servers.append(server)
            }
        }
        return servers.inPairingOrder()
    }

    /// Replaces the server's item in place, so a save that fails leaves the one before it.
    public func save(_ server: PairedServer) throws {
        let status = items.write(try JSONEncoder().encode(server), account: Self.account(server.id))
        guard status == errSecSuccess else {
            throw PhoneProblem(
                title: "This iPhone could not keep its pairing.", detail: "The Keychain said \(status). Pair again.")
        }
    }

    public func remove(id: String) {
        items.delete(account: Self.account(id))
    }
}

/// Keeps the pairings in memory only, for tests and previews.
public final class MemoryCredentialStore: CredentialStore {
    private let stored: Mutex<[String: PairedServer]>

    public init(_ servers: [PairedServer]) {
        stored = Mutex(Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }))
    }

    public convenience init(_ servers: PairedServer...) {
        self.init(servers)
    }

    public func loadAll() -> [PairedServer] { stored.withLock { Array($0.values) }.inPairingOrder() }
    public func save(_ server: PairedServer) throws { stored.withLock { $0[server.id] = server } }
    public func remove(id: String) { _ = stored.withLock { $0.removeValue(forKey: id) } }
}
