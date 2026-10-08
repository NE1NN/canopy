import Foundation
import Testing

@testable import CanopyCore

/// Terminals in a plugin's row work like any row's, with the plugin and item in place of the repo.
@MainActor
struct PluginTerminalTests {
    func pluginRow(_ dir: TempDir) throws -> PluginRow {
        let path = dir.sub("home/plugins/p/one")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return PluginRow(plugin: "p", item: "i1", title: "one", path: path)
    }

    @Test func aShellInAPluginRowStartsInItsFolderWithItsVariables() async throws {
        let dir = try TempDir()
        let row = try pluginRow(dir)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).pane
        await pane.run(
            #"printf 'ready:%s:%s:%s:%s\n' "$CANOPY_PLUGIN" "$CANOPY_ITEM" "${CANOPY_REPO-unset}" "$(pwd -P)""#)

        #expect(await eventually { pane.screen.text.contains("ready:p:i1:unset:\(row.path)") })
    }

    @Test func eventsAboutAPluginRowNameItsPluginAndItem() async throws {
        let dir = try TempDir()
        let row = try pluginRow(dir)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).pane
        pane.report(AgentReport(state: .working))
        terminals.closePane(pane.id)

        let events = await logged(terminals, "term") + (await logged(terminals, "agent"))
        #expect(events.map(\.type) == ["term.opened", "term.exited", "agent.working", "agent.cleared"])
        #expect(events.allSatisfy { $0.repo == nil && $0.row == "one" && $0.path == row.path })
        #expect(events.allSatisfy { $0.data["plugin"] == "p" && $0.data["item"] == "i1" })
        #expect(events.first?.data["pane"] == "p1")
    }

    @Test func pluginRowsAreLeftAloneWhenReposChange() throws {
        let dir = try TempDir()
        let row = try pluginRow(dir)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        terminals.openTab(for: PaneContext(pluginRow: row))
        let worktree = Row(repoPath: "/r/demo", path: dir.sub("w"), branch: "feat/x", head: nil, rowClass: .canopy)
        let snapshot = WorkspaceSnapshot(repos: [RepoSnapshot(path: "/r/demo", name: "demo", rows: [worktree])])

        terminals.closeRowsGone(from: snapshot)
        terminals.followRowNames(in: snapshot)
        terminals.moveRows(ofRepo: "/r/demo", to: "/r/moved")

        #expect(terminals.tabs(inRow: row.path).count == 1)
        #expect(terminals.panes.first?.context == PaneContext(pluginRow: row))
    }

    @Test func termListNamesThePluginNotARepo() throws {
        let dir = try TempDir()
        let row = try pluginRow(dir)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let lifecycle = RowLifecycle(
            workspace: Workspace(home: CanopyHome(path: dir.sub("home"))), terminals: terminals)
        terminals.openTab(for: PaneContext(pluginRow: row))

        let info = try #require(lifecycle.terminalInfo(rowPath: row.path, repoNames: [:]).first)

        #expect(info.repo == nil)
        #expect(info.plugin == "p")
        #expect(info.row == "one")
        #expect(try JSONValue.from(info).decode([String: JSONValue].self)["repo"] == nil)
    }
}
