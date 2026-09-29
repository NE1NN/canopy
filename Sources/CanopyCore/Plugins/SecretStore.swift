import Foundation
import Security
import Synchronization

/// Where plugins keep secrets such as tokens. The app uses the Keychain, and tests an in-memory store, so they never
/// touch it.
public protocol SecretStore: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    /// Deleting a secret that is not there succeeds.
    func delete(service: String, account: String) throws
}

public struct SecretStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int32
    /// The Keychain's own words, such as "User interaction is not allowed."
    public var description: String

    public init(status: Int32, description: String) {
        self.status = status
        self.description = description
    }

    init(_ status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        self.init(status: status, description: message)
    }
}

/// Generic passwords in the login Keychain. Only the app that wrote one reads it without asking.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func read(service: String, account: String) throws -> String? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, service: String, account: String) throws {
        let query = Self.query(service: service, account: account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError(status) }
        var item = query
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError(added) }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status) }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Secrets held only while the process runs, for tests and previews.
public final class MemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: String]>([:])

    public init() {}

    public func read(service: String, account: String) throws -> String? {
        secrets.withLock { $0[Self.key(service, account)] }
    }

    public func write(_ value: String, service: String, account: String) throws {
        secrets.withLock { $0[Self.key(service, account)] = value }
    }

    public func delete(service: String, account: String) throws {
        _ = secrets.withLock { $0.removeValue(forKey: Self.key(service, account)) }
    }

    private static func key(_ service: String, _ account: String) -> String {
        service + "\n" + account
    }
}

/// One plugin's secrets. The service names the app and the plugin, and the account names CANOPY_HOME, so a dev build
/// and each test home never read the release app's secrets.
public struct PluginSecrets: Sendable {
    public let service: String
    private let store: any SecretStore
    private let home: String

    public init(store: any SecretStore, bundleID: String, plugin: String, home: CanopyHome) {
        self.store = store
        self.service = "\(bundleID).plugins.\(plugin)"
        self.home = home.root.path
    }

    public func account(_ name: String) -> String {
        "\(name)@\(home)"
    }

    public func read(_ name: String) throws -> String? {
        try store.read(service: service, account: account(name))
    }

    public func write(_ value: String, for name: String) throws {
        try store.write(value, service: service, account: account(name))
    }

    public func delete(_ name: String) throws {
        try store.delete(service: service, account: account(name))
    }
}
