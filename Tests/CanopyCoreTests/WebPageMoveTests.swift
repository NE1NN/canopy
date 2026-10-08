import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct WebPageMoveTests {
    let artifact = URL(string: "https://claude.ai/artifact/a1")!
    let other = URL(string: "http://localhost:5173/")!

    @Test func movingThePanelsPageToATabKeepsThePageAndRemembersTabs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let terminal = terminals.openTab(for: context).tab
        let page = terminals.openPage(artifact, for: context).page

        terminals.movePanelPageToTab(inRow: dir.path)

        #expect(terminals.panel(inRow: dir.path) == nil)
        #expect(terminals.tabs(inRow: dir.path).map(\.id).first == terminal.id)
        #expect(terminals.selectedTab(inRow: dir.path)?.page === page)
        #expect(terminals.webPlacement == .tab)
        #expect(terminals.openPage(other, for: context).placement == .tab)
    }

    @Test func movingATabToThePanelSelectsItsNeighborAndRemembersThePanel() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let left = terminals.openTab(for: context).tab
        let page = terminals.openPage(artifact, for: context, placement: .tab).page
        let right = terminals.openTab(for: context).tab
        let web = try #require(terminals.tabs(inRow: dir.path).first { $0.page === page })
        terminals.selectTab(web.id, inRow: dir.path)
        terminals.webPlacement = .tab

        terminals.moveTabToPanel(web.id, inRow: dir.path)

        #expect(terminals.shownPanel(inRow: dir.path) === page)
        #expect(terminals.tabs(inRow: dir.path).map(\.id) == [left.id, right.id])
        #expect(terminals.selectedTab(inRow: dir.path)?.id == right.id)
        #expect(terminals.webPlacement == .panel)
    }

    @Test func movingToAPanelHoldingAnotherPageTurnsThatPageIntoATab() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let left = terminals.openTab(for: context).tab
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        let right = terminals.openTab(for: context).tab
        let web = try #require(terminals.tabs(inRow: dir.path).first { $0.page === inTab })
        var closed: [WebPageID] = []
        terminals.onPageClosed = { closed.append($0) }

        terminals.moveTabToPanel(web.id, inRow: dir.path)

        let tabs = terminals.tabs(inRow: dir.path)
        #expect(terminals.shownPanel(inRow: dir.path) === inTab)
        #expect(tabs.count == 3 && tabs[0].id == left.id && tabs[1].page === inPanel && tabs[2].id == right.id)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == right.id)
        #expect(closed.isEmpty)
    }

    @Test func closingPagesLogsThemAndLetsTheAppDropTheirViews() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        var closed: [WebPageID] = []
        terminals.onPageClosed = { closed.append($0) }

        terminals.closePanel(inRow: dir.path)
        let tab = try #require(terminals.selectedTab(inRow: dir.path))
        terminals.closeTab(tab.id, inRow: dir.path)

        #expect(terminals.panel(inRow: dir.path) == nil)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(closed == [inPanel.id, inTab.id])
        let events = await logged(terminals, "web").filter { $0.type == "web.closed" }
        #expect(
            events.map(\.data) == [
                ["page": "w1", "url": "https://claude.ai/artifact/a1"],
                ["page": "w2", "url": "http://localhost:5173/"],
            ])
    }

    @Test func closingAPageByItsIDFindsItInEitherPlace() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let inPanel = terminals.openPage(artifact, for: Fixture.context(dir.sub("a"))).page
        let inTab = terminals.openPage(other, for: Fixture.context(dir.sub("b")), placement: .tab).page

        #expect(terminals.page(inTab.id)?.placement == .tab)
        #expect(terminals.page(inPanel.id)?.path == dir.sub("a"))
        #expect(terminals.closePage(inTab.id))
        #expect(terminals.closePage(inPanel.id))
        #expect(!terminals.closePage(inPanel.id))
        #expect(terminals.page(inPanel.id) == nil)
    }

    @Test func aRowListsItsPanelPageThenItsTabs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let first = terminals.openPage(other, for: context, placement: .tab).page
        terminals.openTab(for: context)
        let panel = terminals.openPage(artifact, for: context).page

        #expect(terminals.pages(inRow: dir.path).map(\.page.id) == [panel.id, first.id])
        #expect(terminals.pages(inRow: dir.path).map(\.placement) == [.panel, .tab])
        #expect(terminals.pages(inRow: dir.sub("none")).isEmpty)
    }

    @Test func hidingThePanelKeepsItsPage() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path)).page

        terminals.setPanelHidden(true, inRow: dir.path)
        #expect(terminals.shownPanel(inRow: dir.path) == nil)
        #expect(terminals.panel(inRow: dir.path)?.page === page)
        terminals.setPanelHidden(false, inRow: dir.path)
        #expect(terminals.shownPanel(inRow: dir.path) === page)
    }

    @Test func navigatingUpdatesThePagesAddressAndTitle() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path)).page
        var changes = 0
        terminals.onChange = { changes += 1 }

        terminals.pageNavigated(page.id, url: URL(string: "https://claude.ai/login")!, title: "Sign in")
        terminals.pageNavigated(page.id, url: nil, title: "Sign in")

        #expect(page.url.absoluteString == "https://claude.ai/login")
        #expect(page.displayTitle == "Sign in")
        #expect(changes == 1)
    }

    @Test func closingARowDropsItsPagesWithoutLoggingThem() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        var closed: Set<WebPageID> = []
        terminals.onPageClosed = { closed.insert($0) }

        terminals.closeRow(path: dir.path)

        #expect(closed == [inPanel.id, inTab.id])
        #expect(terminals.panel(inRow: dir.path) == nil)
        #expect(await logged(terminals, "web").map(\.type) == ["web.opened", "web.opened"])
    }

    @Test func pagesFollowTheirRowWhenItsRepoMoves() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let old = Fixture.context("/old/demo", repoPath: "/old/demo")
        let page = terminals.openPage(artifact, for: old).page

        terminals.moveRows(ofRepo: "/old/demo", to: "/new/demo")

        #expect(terminals.panel(inRow: "/old/demo") == nil)
        #expect(terminals.shownPanel(inRow: "/new/demo") === page)
        #expect(page.context.rowPath == "/new/demo" && page.context.repoPath == "/new/demo")
    }

    @Test func aRowGoneFromItsRepoLosesItsPagesToo() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let (kept, gone) = (dir.sub("kept"), dir.sub("gone"))
        for path in [kept, gone] {
            terminals.openPage(artifact, for: Fixture.context(path, repoPath: "/r/demo"))
        }
        terminals.openPage(other, for: Fixture.context(gone, repoPath: "/r/demo"), placement: .tab)
        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept, gone]))

        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept]))

        #expect(terminals.panel(inRow: kept) != nil)
        #expect(terminals.panel(inRow: gone) == nil)
        #expect(terminals.tabs(inRow: gone).isEmpty)
    }

    @Test func pagesNameTheirRowAsItIsNow() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path, branch: "feat/old")).page
        let row = Row(repoPath: "/r/demo", path: dir.path, branch: "feat/new", head: nil, rowClass: .canopy)

        terminals.followRowNames(
            in: WorkspaceSnapshot(repos: [RepoSnapshot(path: "/r/demo", name: "renamed", rows: [row])]))

        #expect(page.context.rowName == "feat/new")
        #expect(page.context.repoName == "renamed")
    }

    func snapshot(repo: String, rows: [String]) -> WorkspaceSnapshot {
        let rows = rows.map { Row(repoPath: repo, path: $0, branch: "b", head: nil, rowClass: .canopy) }
        return WorkspaceSnapshot(repos: [RepoSnapshot(path: repo, name: "demo", rows: rows)])
    }
}
