import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct SavedWebTests {
    let artifact = URL(string: "https://claude.ai/artifact/a1")!
    let other = URL(string: "http://localhost:5173/")!

    @Test func webTabsAndPanelsComeBackWhereTheyWere() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        terminals.openTab(for: context)
        let tabPage = terminals.openPage(other, for: context, placement: .tab).page
        terminals.pageNavigated(tabPage.id, url: nil, title: "Dev server")
        terminals.openTab(for: context, select: false)
        let panelPage = terminals.openPage(artifact, for: context).page
        terminals.pageNavigated(panelPage.id, url: nil, title: "Launch plan")
        terminals.setPanelHidden(true, inRow: dir.path)

        let saved = try #require(terminals.saved()[dir.path])
        #expect(saved.tabs.map(\.web) == [nil, SavedWebPage(url: other.absoluteString, title: "Dev server"), nil])
        #expect(saved.tabs[1].layout == nil)
        #expect(saved.selectedTab == 1)
        #expect(
            saved.panel
                == SavedWebPanel(page: SavedWebPage(url: artifact.absoluteString, title: "Launch plan"), hidden: true))

        let restored = Fixture.terminals(dir)
        defer { restored.closeAll() }
        restored.continueWebNumbering(from: terminals.nextWebPageNumber)
        restored.restore(saved, for: context)

        let tabs = restored.tabs(inRow: dir.path)
        #expect(tabs.map(\.name) == ["Terminal", "Dev server", "Terminal 2"])
        #expect(tabs[1].page?.url == other)
        #expect(tabs[1].page?.id == WebPageID(3))
        #expect(restored.selectedTab(inRow: dir.path)?.id == tabs[1].id)
        #expect(restored.panel(inRow: dir.path)?.page.url == artifact)
        #expect(restored.panel(inRow: dir.path)?.page.displayTitle == "Launch plan")
        #expect(restored.panel(inRow: dir.path)?.isHidden == true)
    }

    @Test func aRowWithOnlyPagesRestoresThemAndNoTerminal() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        terminals.openPage(other, for: context, placement: .tab)
        terminals.openPage(artifact, for: context)
        let saved = try #require(terminals.saved()[dir.path])

        let restored = Fixture.terminals(dir)
        restored.restore(saved, for: context)

        #expect(restored.tabs(inRow: dir.path).map { $0.page?.url } == [other])
        #expect(restored.panes.isEmpty)
        #expect(restored.shownPanel(inRow: dir.path)?.url == artifact)
    }

    @Test func aPanelAloneIsSavedForItsRow() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        terminals.openPage(artifact, for: Fixture.context(dir.path))

        let saved = try #require(terminals.saved()[dir.path])
        #expect(saved.tabs.isEmpty && saved.panel?.page.url == artifact.absoluteString)

        let restored = Fixture.terminals(dir)
        restored.restore(saved, for: Fixture.context(dir.path))
        #expect(restored.shownPanel(inRow: dir.path)?.url == artifact)
    }

    @Test func pagesThatAreNotWebAddressesAreDropped() throws {
        let dir = try TempDir()
        let saved = SavedRowTerminals(
            tabs: [
                SavedTab(name: "x", web: SavedWebPage(url: "file:///etc/hosts", title: "x")),
                SavedTab(name: "y", web: SavedWebPage(url: other.absoluteString, title: "")),
            ],
            selectedTab: 1,
            panel: SavedWebPanel(page: SavedWebPage(url: "javascript:alert(1)", title: ""), hidden: false))
        let terminals = Fixture.terminals(dir)

        terminals.restore(saved, for: Fixture.context(dir.path))

        #expect(terminals.tabs(inRow: dir.path).map { $0.page?.url } == [other])
        #expect(terminals.panel(inRow: dir.path) == nil)
    }

    @Test func savedTabsReadAsJSON() throws {
        let json = """
            {"tabs": [
                {"name": "Terminal", "layout": {"pane": {"folder": "/r"}}, "focused": 0},
                {"name": "Plan", "web": {"url": "https://claude.ai/artifact/a1", "title": "Plan"}}
            ], "selectedTab": 1, "panel": {"page": {"url": "http://localhost:5173/", "title": ""}, "hidden": false}}
            """

        let row = try JSONDecoder().decode(SavedRowTerminals.self, from: Data(json.utf8))

        #expect(row.tabs.map(\.web?.title) == [nil, "Plan"])
        #expect(row.tabs[0].layout == .leaf(SavedPane(folder: "/r")))
        #expect(row.panel?.page.url == "http://localhost:5173/")
        #expect(try JSONDecoder().decode(SavedRowTerminals.self, from: try JSONEncoder().encode(row)) == row)
        // A tab with neither a layout nor a page is dropped.
        let tabWithNothing = #"{"tabs": [{"name": "x"}], "selectedTab": 0}"#
        #expect(try JSONDecoder().decode(SavedRowTerminals.self, from: Data(tabWithNothing.utf8)).tabs.isEmpty)
    }

    @Test func anOlderStateFileHasNoPages() throws {
        let json = """
            {"version": 1, "repos": [], "terminals": {"/r": {"tabs": [
                {"name": "Terminal", "layout": {"pane": {"folder": "/r"}}, "focused": 0}
            ], "selectedTab": 0}}}
            """

        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))

        #expect(state.terminals["/r"]?.tabs.count == 1)
        #expect(state.terminals["/r"]?.panel == nil)
        #expect(state.webPlacement == .panel)
        #expect(state.webPanelWidth == nil)
        #expect(state.nextWebPage == 1)
    }

    @Test func webSettingsRoundTripAndAnUnknownPlacementFallsBack() throws {
        var state = AppState()
        state.webPlacement = .tab
        state.webPanelWidth = 612
        state.nextWebPage = 9
        #expect(try JSONDecoder().decode(AppState.self, from: try JSONEncoder().encode(state)) == state)

        let odd = #"{"version": 1, "webPlacement": "window", "webPanelWidth": "wide", "nextWebPage": 4}"#
        let decoded = try JSONDecoder().decode(AppState.self, from: Data(odd.utf8))
        #expect(decoded.webPlacement == .panel && decoded.webPanelWidth == nil && decoded.nextWebPage == 4)
    }

    @Test func theWorkspaceKeepsWebSettings() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home)
        try await workspace.start()

        try await workspace.setSavedTerminals([:], nextPane: 4, nextWebPage: 6, webPlacement: .tab)
        try await workspace.setWebPanelWidth(555)
        await workspace.stop()

        let reloaded = Workspace(home: home)
        try await reloaded.start()
        #expect(await reloaded.savedNextWebPage == 6)
        #expect(await reloaded.savedWebPlacement == .tab)
        #expect(await reloaded.webPanelWidth == 555)
        await reloaded.stop()
    }
}

@MainActor
struct SavedWebReviewTests {
    @Test func aPageKeepsTheAddressItOpenedWithAcrossARelaunch() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        let opened = URL(string: "http://localhost:5173/")!
        let page = terminals.openPage(opened, for: context).page
        terminals.pageNavigated(page.id, url: URL(string: "https://login.auth.example/authorize")!, title: nil)
        let saved = try #require(terminals.saved()[dir.path])
        #expect(saved.panel?.page.opened == opened.absoluteString)

        let restored = Fixture.terminals(dir)
        restored.restore(saved, for: context)

        let back = try #require(restored.panel(inRow: dir.path)?.page)
        #expect(back.url.absoluteString == "https://login.auth.example/authorize")
        #expect(back.site == "localhost")
        #expect(restored.openPage(opened, for: context).page === back)
    }

    @Test func aBrokenPageOrTabCostsOnlyItself() throws {
        let json = """
            {"version": 1, "terminals": {
                "/a": {"tabs": [
                    {"name": "Terminal", "layout": {"pane": {"folder": "/a"}}},
                    {"name": "Broken"},
                    {"name": "Plan", "web": {"url": "https://claude.ai/artifact/a1"}}
                ], "selectedTab": 2, "panel": {"page": {"url": "http://localhost:5173/"}}},
                "/b": {"tabs": "not a list"},
                "/c": {"tabs": [{"name": "Terminal", "layout": {"pane": {"folder": "/c"}}}], "selectedTab": 0,
                    "panel": {"hidden": true}}
            }}
            """

        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))

        let a = try #require(state.terminals["/a"])
        #expect(a.tabs.map(\.name) == ["Terminal", "Plan"])
        #expect(a.tabs[1].web == SavedWebPage(url: "https://claude.ai/artifact/a1", title: ""))
        #expect(a.panel == SavedWebPanel(page: SavedWebPage(url: "http://localhost:5173/", title: ""), hidden: false))
        #expect(state.terminals["/b"] == nil)
        #expect(state.terminals["/c"]?.tabs.count == 1 && state.terminals["/c"]?.panel == nil)
    }
}
