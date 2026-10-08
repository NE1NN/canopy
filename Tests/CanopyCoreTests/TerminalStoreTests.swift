import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct TerminalStoreTests {
    @Test func rowOnScreenGetsExactlyOneTerminal() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        terminals.ensureTab(for: Fixture.context(dir.path))
        terminals.ensureTab(for: Fixture.context(dir.path))

        #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal"])
        #expect(terminals.selectedTab(inRow: dir.path)?.name == "Terminal")
    }

    @Test func missingRowGetsNoTerminal() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)

        terminals.ensureTab(for: Fixture.context(dir.sub("gone")))

        #expect(terminals.tabs(inRow: dir.sub("gone")).isEmpty)
    }

    @Test func newTabsAreNumberedAndPanesGetDistinctIDs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)

        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }
        terminals.closeTab(tabs[0].id, inRow: dir.path)
        terminals.openTab(for: context)

        #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal 2", "Terminal 3", "Terminal"])
        #expect(Set(terminals.panes.map(\.id)).count == 3)
        #expect(terminals.pane(try #require(tabs[1].focused).id) === tabs[1].focused)
    }

    @Test func closingTheSelectedTabSelectsItsRightNeighbor() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }

        terminals.selectTab(tabs[1].id, inRow: dir.path)
        terminals.closeTab(tabs[1].id, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)

        terminals.closeTab(tabs[2].id, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)

        terminals.closePane(try #require(tabs[0].focused).id)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(terminals.selectedTab(inRow: dir.path) == nil)
    }

    @Test func closingAnotherTabKeepsTheSelection() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }

        terminals.selectTab(tabs[2].id, inRow: dir.path)
        terminals.closeTab(tabs[0].id, inRow: dir.path)

        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)
    }

    @Test func tabSwitchingWrapsAround() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }

        terminals.selectTab(offset: 1, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)
        terminals.selectTab(offset: -1, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)
    }

    @Test func renameTrimsAndIgnoresBlankNames() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let tab = terminals.openTab(for: Fixture.context(dir.path)).tab

        terminals.renameTab(tab.id, inRow: dir.path, to: "  Server ")
        terminals.renameTab(tab.id, inRow: dir.path, to: "   ")

        #expect(tab.name == "Server")
    }

    @Test func closingARowEndsItsTerminalsOnly() async throws {
        let dir = try TempDir()
        let other = dir.sub("other")
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let groups = [
            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
        ].compactMap { $0 }
        let kept = terminals.openTab(for: Fixture.context(other)).pane

        terminals.closeRow(path: dir.path)

        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(await eventually { groups.allSatisfy(processGroupEnded) })
        #expect(kept.status == .running)
    }

    @Test func busyPanesAreThoseRunningAProgram() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let idle = terminals.openTab(for: Fixture.context(dir.path)).pane
        let busy = terminals.openTab(for: Fixture.context(dir.path)).pane

        await busy.run("sleep 30")

        #expect(await eventually { terminals.busyPanes.map(\.id) == [busy.id] })
        #expect(terminals.busyPanes(inRow: dir.path).map(\.id) == [busy.id])
        #expect(!idle.isBusy)
    }

    func snapshot(repo: String, rows: [String], error: String? = nil) -> WorkspaceSnapshot {
        let rows = rows.map { Row(repoPath: repo, path: $0, branch: "b", head: nil, rowClass: .canopy) }
        return WorkspaceSnapshot(repos: [RepoSnapshot(path: repo, name: "demo", rows: rows, error: error)])
    }

    @Test func rowsThatLeaveTheirRepoLoseTheirTerminals() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let (kept, gone, fresh) = (dir.sub("kept"), dir.sub("gone"), dir.sub("fresh"))
        for path in [kept, gone] {
            terminals.openTab(for: Fixture.context(path, repoPath: "/r/demo"))
        }
        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept, gone]))
        terminals.openTab(for: Fixture.context(fresh, repoPath: "/r/demo"))

        // A failed refresh proves nothing about which rows exist.
        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept], error: "git failed"))
        #expect(!terminals.tabs(inRow: gone).isEmpty)

        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept]))
        #expect(terminals.tabs(inRow: gone).isEmpty)
        #expect(!terminals.tabs(inRow: kept).isEmpty)
        // Not in any snapshot yet, as right after it was created, so it stays.
        #expect(!terminals.tabs(inRow: fresh).isEmpty)
    }

    @Test func movingARepoMovesItsRowsTerminals() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let main = terminals.openTab(for: Fixture.context("/old/demo", repoPath: "/old/demo")).pane
        let elsewhere = terminals.openTab(for: Fixture.context(dir.sub("wt"), repoPath: "/old/demo")).pane

        terminals.moveRows(ofRepo: "/old/demo", to: "/new/demo")

        #expect(terminals.tabs(inRow: "/new/demo").map(\.focused?.id) == [main.id])
        #expect(terminals.tabs(inRow: "/old/demo").isEmpty)
        #expect(main.context.rowPath == "/new/demo")
        #expect(elsewhere.context.rowPath == dir.sub("wt"))
        #expect(elsewhere.context.repoPath == "/new/demo")

        terminals.closeRows(ofRepo: "/new/demo")
        #expect(terminals.panes.isEmpty)
    }

    @Test func newTerminalsStartAtThePreferredSize() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        terminals.preferredSize = TerminalSize(columns: 150, rows: 45)

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane

        #expect(pane.emulator.size == TerminalSize(columns: 150, rows: 45))
    }
}
