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

        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }
        terminals.closeTab(tabs[0].id, inRow: dir.path)
        terminals.openTab(for: context)

        #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal 2", "Terminal 3", "Terminal"])
        #expect(Set(terminals.panes.map(\.id)).count == 3)
        #expect(terminals.pane(tabs[1].pane.id) === tabs[1].pane)
    }

    @Test func closingTheSelectedTabSelectsItsRightNeighbor() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }

        terminals.selectTab(tabs[1].id, inRow: dir.path)
        terminals.closeTab(tabs[1].id, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)

        terminals.closeTab(tabs[2].id, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)

        terminals.closePane(tabs[0].pane.id)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(terminals.selectedTab(inRow: dir.path) == nil)
    }

    @Test func closingAnotherTabKeepsTheSelection() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }

        terminals.selectTab(tabs[2].id, inRow: dir.path)
        terminals.closeTab(tabs[0].id, inRow: dir.path)

        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)
    }

    @Test func tabSwitchingWrapsAround() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }

        terminals.selectTab(offset: 1, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)
        terminals.selectTab(offset: -1, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)
    }

    @Test func renameTrimsAndIgnoresBlankNames() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let tab = terminals.openTab(for: Fixture.context(dir.path))

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

    @Test func newTerminalsStartAtThePreferredSize() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        terminals.preferredSize = TerminalSize(columns: 150, rows: 45)

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane

        #expect(pane.emulator.size == TerminalSize(columns: 150, rows: 45))
    }
}
