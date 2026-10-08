import CoreGraphics
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct GridStoreTests {
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func addingPanesFollowsTheAddRuleAndFocusesTheNewOne() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context).tab

        let second = terminals.addPane(for: context, fits: { $0 <= 2 })!
        let third = terminals.addPane(for: context, fits: { $0 <= 2 })!

        #expect(tab.paneList.count == 3)
        #expect(tab.grid?.focusedPaneID == third.id)
        #expect(
            tab.grid?.layout
                == .split(
                    .column,
                    [.split(.row, [.leaf(tab.paneList[0].id), .leaf(second.id)], [0.5, 0.5]), .leaf(third.id)],
                    [0.5, 0.5]))
    }

    @Test func closingAPaneFocusesItsNeighborAndTheLastClosesTheTab() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context).tab
        let first = try #require(tab.focused)
        let second = terminals.addPane(for: context, fits: { _ in true })!

        terminals.closePane(second.id)
        #expect(tab.grid?.focusedPaneID == first.id)
        #expect(tab.grid?.layout == .leaf(first.id))
        #expect(second.status == .exited(Pane.closedExitCode))

        terminals.closePane(first.id)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
    }

    @Test func movingSwappingAndFocusingNeighbors() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context).tab
        let a = try #require(tab.focused).id
        let b = terminals.addPane(for: context, fits: { _ in true })!.id

        terminals.movePane(a, to: .edge(.bottom), of: b)
        #expect(tab.grid?.layout == .split(.column, [.leaf(b), .leaf(a)], [0.5, 0.5]))
        terminals.movePane(a, to: .center, of: b)
        #expect(tab.grid?.layout == .split(.column, [.leaf(a), .leaf(b)], [0.5, 0.5]))

        terminals.focus(a)
        #expect(terminals.focusNeighbor(inRow: dir.path, toward: .down, in: rect)?.id == b)
        #expect(tab.grid?.focusedPaneID == b)
        #expect(terminals.focusNeighbor(inRow: dir.path, toward: .down, in: rect) == nil)
    }

    @Test func resizingGoesThroughTheLayoutClamps() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context).tab
        terminals.addPane(for: context, fits: { _ in true })

        terminals.resize(
            try #require(tab.grid), divider: DividerID(path: [], index: 0), to: 10, in: rect,
            minimum: CGSize(width: 300, height: 100))

        #expect(tab.grid?.layout.frames(in: rect)[tab.paneList[0].id]?.width == 300)
    }

    @Test func savedTabsRestoreWithFreshShellsInTheirFolders() async throws {
        let dir = try TempDir()
        let sub = dir.sub("sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let server = terminals.openTab(for: context).tab
        terminals.renameTab(server.id, inRow: dir.path, to: "Server")
        let moved = terminals.addPane(for: context, fits: { _ in true })!
        terminals.openTab(for: context)
        terminals.selectTab(server.id, inRow: dir.path)
        await moved.run("cd sub")
        #expect(await eventually { moved.currentDirectory == sub })

        let saved = try #require(terminals.saved()[dir.path])
        terminals.closeAll()
        let restored = Fixture.terminals(dir)
        defer { restored.closeAll() }
        restored.restore(saved, for: context)

        let tabs = restored.tabs(inRow: dir.path)
        #expect(tabs.map(\.name) == ["Server", "Terminal"])
        #expect(restored.selectedTab(inRow: dir.path)?.name == "Server")
        let panes = tabs[0].paneList
        #expect(panes.count == 2)
        #expect(tabs[0].grid?.focusedPaneID == panes[1].id)
        #expect(await eventually { panes[1].currentDirectory == sub })
        #expect(await eventually { panes[0].currentDirectory == dir.path })
    }

    @Test func restoringIntoAFolderThatIsGoneUsesTheRowsFolder() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let saved = SavedRowTerminals(
            tabs: [SavedTab(name: "Terminal", layout: .leaf(SavedPane(folder: dir.sub("gone"))), focused: 0)],
            selectedTab: 3)

        terminals.restore(saved, for: Fixture.context(dir.path))

        let pane = try #require(terminals.selectedTab(inRow: dir.path)?.focused)
        #expect(await eventually { pane.currentDirectory == dir.path })
    }

    @Test func paneNumbersContinueFromWhereTheyLeftOff() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        terminals.continueNumbering(from: 40)

        #expect(terminals.openTab(for: Fixture.context(dir.path)).pane.id == PaneID(40))
        #expect(terminals.nextPaneNumber == 41)
        terminals.continueNumbering(from: 5)
        #expect(terminals.nextPaneNumber == 41)
    }

    @Test func changesAreReported() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        var changes = 0
        terminals.onChange = { changes += 1 }

        let tab = terminals.openTab(for: Fixture.context(dir.path)).tab
        terminals.renameTab(tab.id, inRow: dir.path, to: "Build")
        terminals.closeTab(tab.id, inRow: dir.path)

        #expect(changes == 3)
    }

    @Test func stateFileKeepsTerminalsAndOldFilesStillLoad() throws {
        let saved = SavedRowTerminals(
            tabs: [SavedTab(name: "T", layout: .leaf(SavedPane(folder: "/w")), focused: 0)], selectedTab: 0)
        let state = AppState(terminals: ["/w": saved])

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(decoded.terminals == ["/w": saved])
        let old = try JSONDecoder().decode(AppState.self, from: Data(#"{"version": 1, "repos": []}"#.utf8))
        #expect(old.terminals.isEmpty)
        let broken = #"{"version": 1, "repos": [{"path": "/r", "dirName": "r"}], "terminals": {"/w": {"tabs": 3}}}"#
        let kept = try JSONDecoder().decode(AppState.self, from: Data(broken.utf8))
        #expect(kept.repos.map(\.path) == ["/r"])
        #expect(kept.terminals.isEmpty)
    }
}

struct GridSettingsTests {
    @Test func paneIDsReadBack() {
        #expect(PaneID("p12") == PaneID(12))
        #expect(PaneID("12") == nil)
        #expect(PaneID("p0") == nil)
        #expect(PaneID("px") == nil)
    }

    @Test func globalConfigDefaultsAndBounds() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("config.json"))
        #expect(GlobalConfig.load(from: url).minPaneColumns == 80)
        try #"{"minPaneColumns": 100}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 100)
        try #"{"minPaneColumns": 3}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 20)
        try "{".write(to: url, atomically: true, encoding: .utf8)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 80)
    }
}

struct CloseWarningTests {
    @Test func tabCloseWarningCountsTerminals() {
        #expect(BusyTerminals.closeWarning(["bun"]) == "A terminal in it is running a program: bun.")
        #expect(
            BusyTerminals.closeWarning(["bun", "claude"]) == "2 terminals in it are running programs: bun, claude.")
    }
}
