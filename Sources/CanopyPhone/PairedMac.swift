import Foundation
import Security
import Synchronization

/// The Mac this phone paired with, and the device token that proves it.
public struct PairedMac: Codable, Sendable, Equatable {
    /// The Mac's MagicDNS name, or its Tailscale address when it has none.
    public var host: String
    public var port: UInt16
    /// The Mac's Tailscale address, tried when the name does not resolve.
    public var address: String?
    public var token: String
    /// The Mac's name, as it says in hello.
    public var mac: String
    /// The name the Mac knows this phone by.
    public var phone: String
    /// Canopy's version on the Mac, as of the last hello.
    public var version: String?

    public init(
        host: String, port: UInt16, address: String?, token: String, mac: String, phone: String, version: String? = nil
    ) {
        self.host = host
        self.port = port
        self.address = address
        self.token = token
        self.mac = mac
        self.phone = phone
        self.version = version
    }

    /// The hosts to try, in order.
    public var hosts: [String] {
        guard let address, address != host else { return [host] }
        return [host, address]
    }
}

/// Where the paired Mac and its token live between launches.
public protocol CredentialStore: Sendable {
    func load() -> PairedMac?
    func save(_ mac: PairedMac) throws
    func clear()
}

/// The token stays in this phone's Keychain, never in a backup another device can restore.
public struct KeychainCredentialStore: CredentialStore {
    public var service: String

    public init(service: String = "com.ne1nn.Canopy.Phone") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "mac",
        ]
    }

    public func load() -> PairedMac? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    /// Replaces the pairing in place, so a save that fails leaves the one before it.
    public func save(_ mac: PairedMac) throws {
        let data = try JSONEncoder().encode(mac)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PhoneProblem(
                title: "This iPhone could not keep its pairing.", detail: "The Keychain said \(status). Pair again.")
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Keeps the pairing in memory only, for tests and previews.
public final class MemoryCredentialStore: CredentialStore {
    private let stored: Mutex<PairedMac?>

    public init(_ mac: PairedMac? = nil) {
        stored = Mutex(mac)
    }

    public func load() -> PairedMac? { stored.withLock { $0 } }
    public func save(_ mac: PairedMac) throws { stored.withLock { $0 = mac } }
    public func clear() { stored.withLock { $0 = nil } }
}
