import Foundation
import Testing

@testable import CanopyCore

struct PluginStateTests {
    static let info = PluginInfo(id: "p", name: "P", symbol: "star")

    func workspace(_ dir: TempDir, plugins: [PluginInfo] = [Self.info]) async throws -> Workspace {
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        await workspace.registerPlugins(plugins)
        return workspace
    }

    func add(_ workspace: Workspace, _ item: String, plugin: String = "p") async throws -> PluginRow {
        try await workspace.addPluginRow(
            PluginRowEntry(item: item, title: "row-\(item)", path: "/h/plugins/\(plugin)/\(item)"), plugin: plugin)
    }

    @Test func anOlderStateWithoutPluginsLoads() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 1, "repos": [{"path": "/r", "dirName": "r"}]}"#.write(
            to: url, atomically: true, encoding: .utf8)

        let state = StateStore(url: url).load().state

        #expect(state.plugins.isEmpty)
        #expect(state.repos.map(\.path) == ["/r"])
    }

    @Test func pluginsRoundTripAndUnknownOnesAreKept() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        var state = AppState()
        state.plugins = [
            "tickets": PluginEntry(
                rows: [PluginRowEntry(item: "k5", title: "0853-sam", path: "/h/plugins/tickets/0853-sam")],
                links: ["/h/worktrees/app/fix": "k5"], panelWidth: 300),
            "gone-plugin": PluginEntry(rows: [PluginRowEntry(item: "x", title: "x", path: "/h/plugins/gone-plugin/x")]),
        ]

        try store.save(state)

        #expect(store.load() == .loaded(state))
    }

    @Test func anUnreadablePluginsValueIsDroppedAlone() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 1, "repos": [{"path": "/r", "dirName": "r"}], "plugins": 7}"#.write(
            to: url, atomically: true, encoding: .utf8)
        #expect(StateStore(url: url).load() == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r")])))

        try #"""
        {"version": 1, "plugins": {
            "a": {"rows": [{"item": "1", "title": "one", "path": "/a/1"}, {"item": 2}], "links": {"/w": 3}},
            "b": "nonsense"
        }}
        """#.write(to: url, atomically: true, encoding: .utf8)
        let plugins = StateStore(url: url).load().state.plugins
        #expect(plugins == ["a": PluginEntry(rows: [PluginRowEntry(item: "1", title: "one", path: "/a/1")])])
    }

    @Test func aPluginThatIsOffShowsNothing() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)
        let row = try await add(workspace, "i1")

        var snapshot = await workspace.snapshot
        #expect(snapshot.plugins.map(\.rows) == [[row]])
        #expect(snapshot.plugins.map(\.isOn) == [false])
        #expect(snapshot.activePlugins.isEmpty)
        #expect(snapshot.sidebarRow(path: row.path) == nil)
        #expect(snapshot.pluginRow(plugin: "p", item: "i1") == nil)
        #expect(snapshot.visibleRows.isEmpty)

        await workspace.setPlugin("p", on: true)
        snapshot = await workspace.snapshot
        #expect(snapshot.sidebarRow(path: row.path) == .plugin(row))
        #expect(snapshot.pluginRow(plugin: "p", item: "i1") == row)
        #expect(snapshot.visibleRows == [.plugin(row)])
    }

    @Test func sectionsFollowTheRegisteredOrder() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(
            dir, plugins: [PluginInfo(id: "z", name: "Z", symbol: "a"), PluginInfo(id: "b", name: "B", symbol: "b")])
        _ = try await add(workspace, "1", plugin: "b")
        await workspace.setPlugin("b", on: true)
        await workspace.setPlugin("z", on: true)

        let snapshot = await workspace.snapshot
        #expect(snapshot.plugins.map(\.id) == ["z", "b"])
        #expect(snapshot.plugins.map(\.rows.count) == [0, 1])
    }

    @Test func rowsKeepTheirOrderAndLooks() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)
        let one = try await add(workspace, "1")
        let two = try await add(workspace, "2")
        let three = try await add(workspace, "3")

        #expect(try await workspace.movePluginRow(path: two.path, to: .before(one.path)))
        #expect(try await workspace.movePluginRow(path: two.path, to: .before(one.path)) == false)
        let look = PluginRowLook(label: "#1", accessories: [.tag("closed", help: "Closed")], isMissing: true)
        await workspace.setPluginLooks(
            [one.path: look, three.path: PluginRowLook(title: "Three"), "/elsewhere": look], plugin: "p")

        var rows = await workspace.snapshot.plugins[0].rows
        #expect(rows.map(\.item) == ["2", "1", "3"])
        #expect(rows.map(\.look) == [.plain, look, PluginRowLook(title: "Three")])
        #expect(rows.map(\.displayName) == ["row-2", "row-1", "Three"])
        await workspace.stop()

        let relaunched = try await self.workspace(dir)
        rows = await relaunched.snapshot.plugins[0].rows
        #expect(rows.map(\.item) == ["2", "1", "3"])
        #expect(rows.allSatisfy { $0.look == .plain })
    }

    @Test func aSecondRowForTheSameItemIsRefused() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)
        let row = try await add(workspace, "1")

        await #expect(throws: WorkspaceError.itemHasRow(row.path)) {
            try await workspace.addPluginRow(
                PluginRowEntry(item: "1", title: "again", path: "/h/plugins/p/again"), plugin: "p")
        }
        await #expect(throws: WorkspaceError.pluginNotFound("nope")) {
            try await workspace.addPluginRow(PluginRowEntry(item: "1", title: "t", path: "/h/x"), plugin: "nope")
        }
        #expect(await workspace.snapshot.plugins[0].rows.count == 1)
    }

    @Test func rowsMoveOnlyWithinTheirSection() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(
            dir, plugins: [Self.info, PluginInfo(id: "q", name: "Q", symbol: "star")])
        let one = try await add(workspace, "1")
        let two = try await add(workspace, "2")
        let other = try await add(workspace, "x", plugin: "q")

        #expect(try await workspace.movePluginRow(path: one.path, to: .after(two.path)))
        for placement in [RowPlacement.group("G"), .ungrouped, .before(one.path), .after(other.path), .before("/nope")]
        {
            await #expect(throws: WorkspaceError.self) {
                try await workspace.movePluginRow(path: one.path, to: placement)
            }
        }
        await #expect(throws: WorkspaceError.rowNotFound("/nope")) {
            try await workspace.movePluginRow(path: "/nope", to: .before(one.path))
        }
        #expect(await workspace.snapshot.plugins[0].rows.map(\.item) == ["2", "1"])
    }

    @Test func removingForgetsTheRowItsSelectionAndItsLookButKeepsLinks() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)
        let row = try await add(workspace, "1")
        await workspace.setPlugin("p", on: true)
        await workspace.setPluginLooks([row.path: PluginRowLook(label: "#1")], plugin: "p")
        try await workspace.setSelectedRow(path: row.path)
        try await workspace.setPluginLink(PluginLink(plugin: "p", item: "1"), forRow: "/w/fix")

        let removed = try await workspace.removePluginRow(path: row.path)

        #expect(removed.path == row.path)
        #expect(removed.look.label == "#1")
        let snapshot = await workspace.snapshot
        #expect(snapshot.plugins[0].rows.isEmpty)
        #expect(snapshot.selectedRowPath == nil)
        #expect(await workspace.pluginEntry("p")?.links == ["/w/fix": "1"])
        let readded = try await add(workspace, "1")
        #expect(readded.look == .plain)
        await #expect(throws: WorkspaceError.rowNotFound("/nope")) {
            try await workspace.removePluginRow(path: "/nope")
        }
    }

    @Test func warningsAndPanelWidthsArePerPlugin() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)

        await workspace.setPluginWarning("p", "Run `canopy plugin enable p`.")
        try await workspace.setPluginPanelWidth(300, plugin: "p")

        let section = try #require(await workspace.snapshot.section("p"))
        #expect(section.warning == "Run `canopy plugin enable p`.")
        #expect(section.panelWidth == 300)
        #expect(section.info == Self.info)
        await workspace.setPluginWarning("p", nil)
        #expect(await workspace.snapshot.section("p")?.warning == nil)
    }
}
