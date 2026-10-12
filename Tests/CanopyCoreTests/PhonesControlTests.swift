import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PhonesControlTests {
    func handler(_ dir: TempDir, phones: PhoneService?) async throws -> WorkspaceControlHandler {
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home, git: Fixture.git, activity: ActivityLog(folder: home.activityFolder))
        try await workspace.start()
        let terminals = Fixture.terminals(dir)
        let plugins = PluginHost(
            workspace: workspace, terminals: terminals, plugins: [], secrets: MemorySecretStore(), bundleID: "test",
            trash: FolderMovingTrash(into: dir.sub("trash")))
        return WorkspaceControlHandler(
            rows: RowLifecycle(workspace: workspace, terminals: terminals), plugins: plugins, ui: RecordingUI(),
            phones: phones)
    }

    @Test func theCLIPairsListsAndRemovesPhones() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("phone-home"))
        let terminals = Fixture.terminals(dir)
        let service = PhoneService(
            home: home,
            hub: PhoneHub(terminals: terminals, snapshot: WorkspaceSnapshot(), updates: AsyncStream { _ in }),
            activity: ActivityLog(folder: home.activityFolder),
            listen: PhoneListenAddress(override: "127.0.0.1", port: 0, ignoredOverride: nil), macName: "studio")
        await service.start()
        defer { service.stop() }
        let handler = try await handler(dir, phones: service)

        let paired = await handler.handle(ControlRequest(method: PhonesMethod.pair))
        let pairing = try #require(paired.result).decode(PhonesPairResult.self)
        #expect(pairing.link.hasPrefix("canopy-phone://pair?host=127.0.0.1&port="))
        _ = try await service.registry.redeem(code: pairing.code, name: "a")

        let waited = await handler.handle(
            ControlRequest(method: PhonesMethod.paired, params: try .from(PhonesPairedParams(code: pairing.code))))
        #expect(try #require(waited.result).decode(PhonesPairedResult.self).phone?.name == "a")
        let listed = await handler.handle(ControlRequest(method: PhonesMethod.list))
        #expect(try #require(listed.result).decode([PhoneInfo].self).map(\.name) == ["a"])
        let status = await handler.handle(ControlRequest(method: PhonesMethod.status))
        #expect(try #require(status.result).decode(PhonesStatusResult.self).listening)
        let removed = await handler.handle(
            ControlRequest(method: PhonesMethod.remove, params: try .from(PhonesRemoveParams(name: "a"))))
        #expect(try #require(removed.result).decode(PhoneInfo.self).name == "a")
        let missing = await handler.handle(
            ControlRequest(method: PhonesMethod.remove, params: try .from(PhonesRemoveParams(name: "a"))))
        #expect(missing.error?.code == "phone_not_found")
    }

    @Test func withoutPhonesTheMethodsSaySo() async throws {
        let dir = try TempDir()
        let handler = try await handler(dir, phones: nil)
        let response = await handler.handle(ControlRequest(method: PhonesMethod.status))
        #expect(response.error?.code == "phones_unavailable")
    }

    @Test func phonesOwnMethodsAreNotOnTheControlSocket() async throws {
        let dir = try TempDir()
        let handler = try await handler(dir, phones: nil)
        let response = await handler.handle(ControlRequest(method: PhoneMethod.rows))
        #expect(response.error?.code == "unknown_method")
    }
}
