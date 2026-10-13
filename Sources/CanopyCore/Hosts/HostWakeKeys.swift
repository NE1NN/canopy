import CanopyAgents
import Foundation

/// Each host's wake key, in the Mac's login Keychain. The service names the app, and the account names the host and
/// CANOPY_HOME, so a dev build and each test home keep their own.
public struct HostWakeKeys: Sendable {
    private let store: any SecretStore
    public let service: String

    public init(store: any SecretStore, bundleID: String) {
        self.store = store
        service = "\(bundleID).hosts.wake"
    }

    /// Kept in memory only, for tests.
    public static func inMemory() -> HostWakeKeys {
        HostWakeKeys(store: MemorySecretStore(), bundleID: "test")
    }

    private func account(_ alias: String, home: CanopyHome) -> String {
        "\(alias)@\(home.root.path)"
    }

    /// The host's key, nil when none is set, or an error when the Keychain would not say, as when it is locked.
    public func read(_ alias: String, home: CanopyHome) throws -> BoxWakeKey? {
        guard let text = try store.read(service: service, account: account(alias, home: home)) else { return nil }
        return try JSONDecoder().decode(BoxWakeKey.self, from: Data(text.utf8))
    }

    public func write(_ key: BoxWakeKey, for alias: String, home: CanopyHome) throws {
        let text = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        try store.write(text, service: service, account: account(alias, home: home))
    }

    public func delete(_ alias: String, home: CanopyHome) throws {
        try store.delete(service: service, account: account(alias, home: home))
    }
}
