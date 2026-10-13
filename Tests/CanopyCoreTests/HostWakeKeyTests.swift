import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// `canopy host wake-key`: the key phones start a host with, kept here and handed to its canopy-box.
struct HostWakeKeyTests {
    static let key = BoxWakeKey(accessKeyID: "AKIAEXAMPLE", secretAccessKey: "s3cret-wake")

    func setUp(_ dir: TempDir, upgraded: Bool = true) async throws -> PluginControlTests.Setup {
        let setup = try await PluginControlTests().start(dir)
        try HostsConfigFile(url: setup.home.configFile).save("box", HostEntry(repos: [:], box: upgraded))
        return setup
    }

    @Test func aWakeKeyIsKeptAndGoesToTheBoxOnEveryConnect() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }

        let result = try await PluginControlTests().call(
            setup, HostMethod.wakeKey, HostWakeKeyParams(alias: "box", key: Self.key), as: HostWakeKeyResult.self)

        // No link is up in the test, so canopy-box gets it when the host next connects.
        #expect(result == HostWakeKeyResult(alias: "box", isSet: true, sent: false))
        #expect(setup.workspace.boxConfig(for: "box").wake == Self.key)
    }

    @Test func clearingTheKeyForgetsIt() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }
        _ = try await setup.workspace.setWakeKey(Self.key, for: "box")

        let result = try await PluginControlTests().call(
            setup, HostMethod.wakeKey, HostWakeKeyParams(alias: "box", key: nil), as: HostWakeKeyResult.self)

        #expect(!result.isSet)
        #expect(setup.workspace.boxConfig(for: "box").wake == nil)
    }

    @Test func removingAHostForgetsItsKey() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }
        _ = try await setup.workspace.setWakeKey(Self.key, for: "box")

        try await setup.workspace.removeHost(alias: "box")
        try HostsConfigFile(url: setup.home.configFile).save("box", HostEntry(repos: [:], box: true))

        #expect(setup.workspace.boxConfig(for: "box").wake == nil)
    }

    /// A Keychain that would not say must not take the key from the box and every phone.
    @Test func aKeychainThatWillNotSayKeepsTheBoxsKey() throws {
        struct Locked: SecretStore {
            func read(service: String, account: String) throws -> String? {
                throw SecretStoreError(status: -25308, description: "User interaction is not allowed.")
            }
            func write(_ value: String, service: String, account: String) throws {}
            func delete(service: String, account: String) throws {}
        }
        let dir = try TempDir()
        let workspace = Workspace(
            home: CanopyHome(path: dir.sub("home")), git: Fixture.git,
            hostTooling: HostTooling(wakeKeys: HostWakeKeys(store: Locked(), bundleID: "test")))

        let config = workspace.boxConfig(for: "box")

        #expect(config.wake == nil && config.keepsWake == true)
    }

    @Test func aHostNotUpgradedRefusesAWakeKey() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir, upgraded: false)
        defer { PluginControlTests().stop(setup) }

        let code = try await PluginControlTests().errorCode(
            setup, HostMethod.wakeKey, HostWakeKeyParams(alias: "box", key: Self.key))

        #expect(code == "host_not_upgraded")
        #expect(setup.workspace.boxConfig(for: "box").wake == nil)
    }

    @Test func theWakeKeyIsNotLogged() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }

        _ = try await PluginControlTests().call(
            setup, HostMethod.wakeKey, HostWakeKeyParams(alias: "box", key: Self.key), as: HostWakeKeyResult.self)

        await setup.workspace.activity.flush()
        let calls = activityEvents(setup.workspace.activity.folder).filter { $0.type == ActivityType.cliCall }
        #expect(calls.compactMap { $0.data["method"] } == [.string(HostMethod.wakeKey)])
        for file in try FileManager.default.contentsOfDirectory(atPath: setup.workspace.activity.folder.path) {
            let text = try String(contentsOf: setup.workspace.activity.folder.appending(path: file), encoding: .utf8)
            #expect(!text.contains("s3cret-wake"))
        }
    }
}
