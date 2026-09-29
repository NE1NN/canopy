import CanopyFixturePlugin
import Foundation
import Testing

@testable import CanopyCore

/// The fixture plugin that dev builds, the end-to-end tests, and the UI fixture turn on.
@MainActor
struct FixturePluginTests {
    func start(_ dir: TempDir, config: String = #"{"plugins": {"fixture": {}}}"#) async throws -> PluginHost {
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        try config.write(to: home.configFile, atomically: true, encoding: .utf8)
        let workspace = Workspace(home: home, git: Fixture.git)
        try await workspace.start()
        let host = PluginHost(
            workspace: workspace, terminals: Fixture.terminals(dir), plugins: [FixturePlugin()],
            secrets: MemorySecretStore(), bundleID: "test", trash: FolderMovingTrash(into: dir.sub("trash")))
        await host.start()
        return host
    }

    func items(_ host: PluginHost, _ text: String = "", _ filters: [String] = []) async throws -> [String] {
        let query = try FixturePlugin().filters.query(text: text, filters: filters, plugin: "Fixture")
        return try await host.items("fixture", matching: query).map(\.id)
    }

    func section(_ host: PluginHost) async -> PluginSection? {
        await host.workspace.snapshot.section("fixture")
    }

    @Test func listsItemsByChoiceToggleAndSearch() async throws {
        let dir = try TempDir()
        let host = try await start(dir)

        #expect(try await items(host) == ["fx-1", "fx-4", "fx-2", "fx-3", "fx-5"])
        #expect(try await items(host, "", ["waiting"]) == ["fx-1", "fx-4"])
        #expect(try await items(host, "", ["closed"]) == ["fx-6", "fx-7"])
        #expect(try await items(host, "EXPORT") == ["fx-2"])
        #expect(try await items(host, "same") == ["fx-4", "fx-5"])
        let listed = await host.list()
        #expect(listed.first?.status == "7 made-up items, 0 rows")
    }

    @Test func aPluginNamesItsItemInThePickersTitle() {
        #expect(
            PluginInfo(id: "t", name: "Tickets", symbol: "ticket", itemName: "Ticket").newRowTitle == "New Ticket Row")
        #expect(FixturePlugin().info.newRowTitle == "New Fixture Row")
    }

    @Test func resolvesIdsNumbersAndSlugs() async throws {
        let dir = try TempDir()
        let host = try await start(dir)

        for reference in ["fx-2", "FX-2", "2", "02", "beta", "Beta"] {
            #expect(try await host.resolveLink(plugin: "fixture", reference: reference).item == "fx-2", "\(reference)")
        }
        await #expect { try await host.resolveLink(plugin: "fixture", reference: "same") } throws: {
            ($0 as? ControlError)?.code == "item_ambiguous" && ($0 as? ControlError)?.message.contains("fx-5") == true
        }
        await #expect { try await host.resolveLink(plugin: "fixture", reference: "nope") } throws: {
            ($0 as? ControlError)?.code == "item_not_found"
        }
    }

    @Test func seedsAndFillsARow() async throws {
        let dir = try TempDir()
        let host = try await start(dir)

        let row = try await host.createRow("fixture", reference: "beta", run: nil, select: false).row

        #expect(row.title == "beta")
        #expect(row.path.hasSuffix("/plugins/fixture/beta"))
        let text = try String(contentsOfFile: row.path + "/item.md", encoding: .utf8)
        #expect(text.hasPrefix("# Beta: export stops at 10,000 rows\n"))
        let second = try await host.createRow("fixture", reference: "fx-5", run: nil, select: false).row
        let first = try await host.createRow("fixture", reference: "fx-4", run: nil, select: false).row
        #expect(second.path.hasSuffix("/same") && first.path.hasSuffix("/same-2"))
    }

    @Test func setsEveryKindOfAccessoryAndALabel() async throws {
        let dir = try TempDir()
        let host = try await start(dir)

        let waiting = try await host.createRow("fixture", reference: "1", run: nil, select: false).row
        let closed = try await host.createRow("fixture", reference: "6", run: nil, select: false).row

        #expect(
            await eventually {
                await section(host)?.rows.map(\.look.accessories.count) == [2, 2]
            })
        let rows = try #require(await section(host)?.rows)
        #expect(rows.map(\.look.label) == ["#1", "#6"])
        #expect(rows[0].look.accessories.map(\.kind) == [.dot, .initials])
        #expect(rows[0].look.accessories.first?.color == .orange)
        #expect(rows[1].look.accessories.first == .tag("closed", help: "Closed"))
        #expect(rows.map(\.path) == [waiting.path, closed.path])
    }

    @Test func showsItsConfigsWarningAndCanFailToStart() async throws {
        let dir = try TempDir()
        let warned = try await start(
            dir, config: #"{"plugins": {"fixture": {"warning": "Pretend `canopy x` fixes it."}}}"#)
        #expect(await section(warned)?.warning == "Pretend `canopy x` fixes it.")

        let other = try TempDir()
        let failed = try await start(other, config: #"{"plugins": {"fixture": {"failStart": "It did not start."}}}"#)
        #expect(await section(failed)?.warning == "It did not start.")
        #expect(await section(failed)?.isOn == true)
    }

    @Test func marksItemsMissingFromConfigAndOnRequest() async throws {
        let dir = try TempDir()
        let host = try await start(dir, config: #"{"plugins": {"fixture": {"missing": ["fx-3"]}}}"#)
        _ = try await host.createRow("fixture", reference: "3", run: nil, select: false)
        _ = try await host.createRow("fixture", reference: "2", run: nil, select: false)
        #expect(await eventually { await section(host)?.rows.map(\.isMissing) == [true, false] })

        let answer = try await host.call(
            "fixture.missing", params: .object(["item": "fx-2", "missing": true]), target: TargetHint(), row: nil)

        #expect(answer == .object(["missing": .array(["fx-2", "fx-3"])]))
        #expect(await eventually { await section(host)?.rows.map(\.isMissing) == [true, true] })
    }

    @Test func remembersATokenInItsSecrets() async throws {
        let dir = try TempDir()
        let host = try await start(dir)
        let call = { (method: String, params: JSONValue) in
            try await host.call(method, params: params, target: TargetHint(), row: nil)
        }

        #expect(try await call("fixture.remember", .object(["token": "s3cret"])) == .object(["stored": true]))
        #expect(try await call("fixture.recall", .null) == .object(["token": "s3cret"]))
        #expect(try host.context("fixture")?.secrets.read("token") == "s3cret")
        #expect(try await call("fixture.forget", .null) == .object(["forgotten": true]))
        #expect(try await call("fixture.recall", .null) == .object(["token": .null]))
        #expect(host.readOnlyMethods == ["fixture.recall", "fixture.where"])
    }

    @Test func whereAnswersWithTheTargetsRowAndWarnSetsTheWarning() async throws {
        let dir = try TempDir()
        let host = try await start(dir)
        let row = try await host.createRow("fixture", reference: "2", run: nil, select: false).row

        let inRow = try await host.call("fixture.where", params: .null, target: TargetHint(cwd: row.path), row: row)
        let outside = try await host.call("fixture.where", params: .null, target: TargetHint(), row: nil)
        _ = try await host.call(
            "fixture.warn", params: .object(["text": "Now warned."]), target: TargetHint(), row: nil)

        #expect(inRow == .object(["item": "fx-2", "title": "beta"]))
        #expect(outside == .object(["item": .null, "title": .null]))
        #expect(await section(host)?.warning == "Now warned.")
    }
}
