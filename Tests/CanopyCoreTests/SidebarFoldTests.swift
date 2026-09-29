import Testing

@testable import CanopyCore

/// Folded repos and plugin sections in the sidebar order, on snapshots built by hand.
struct SidebarFoldTests {
    static func section(_ id: String, collapsed: Bool = false, _ items: [String]) -> PluginSection {
        PluginSection(
            info: PluginInfo(id: id, name: id, symbol: "star"), isOn: true,
            rows: items.map { PluginRow(plugin: id, item: $0, title: $0, path: "/h/\(id)/\($0)") },
            collapsed: collapsed)
    }

    /// The group tests' snapshot with web folded and holding another tool's worktree, then plugin p's section.
    /// web: main, a, Review (b, c) folded, Later (d), and ext. api: main, e, Hidden (f) folded.
    static var snapshot: WorkspaceSnapshot {
        var snapshot = GroupSnapshotTests.snapshot
        var external = GroupSnapshotTests.row("web", "ext")
        external.rowClass = .external
        snapshot.repos[0].external = [external]
        snapshot.repos[0].collapsed = true
        snapshot.plugins = [section("p", ["one"])]
        return snapshot
    }

    @Test func aFoldedRepoGivesNoRowANumber() {
        #expect(Self.snapshot.visibleRows.map(\.path) == ["/api", "/api/e", "/h/p/one"])
        #expect(Self.snapshot.repos[0].visibleRows.isEmpty)
    }

    @Test func aFoldedSectionGivesNoRowANumber() {
        var snapshot = Self.snapshot
        snapshot.plugins = [Self.section("p", collapsed: true, ["one"]), Self.section("q", ["two"])]

        #expect(snapshot.visibleRows.map(\.path) == ["/api", "/api/e", "/h/q/two"])
        #expect(snapshot.steppingRow(from: "/h/p/one", offset: 1)?.path == "/h/q/two")
        #expect(snapshot.steppingRow(from: "/h/p/one", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/h/q/two", offset: -1)?.path == "/api/e")
    }

    @Test func steppingFromAHiddenRowContinuesFromItsRepo() {
        var snapshot = Self.snapshot
        // api, then web folded, then the plugin's rows.
        snapshot.repos.swapAt(0, 1)

        #expect(snapshot.steppingRow(from: "/web/a", offset: 1)?.path == "/h/p/one")
        #expect(snapshot.steppingRow(from: "/web/b", offset: 1)?.path == "/h/p/one")
        #expect(snapshot.steppingRow(from: "/web/a", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/web", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/api/e", offset: 1)?.path == "/h/p/one")
        #expect(snapshot.steppingRow(from: "/h/p/one", offset: -1)?.path == "/api/e")
        snapshot.plugins = []
        #expect(snapshot.steppingRow(from: "/web/d", offset: 1) == nil)
    }

    @Test func foldsListTheRepoThenTheGroup() {
        let snapshot = Self.snapshot

        #expect(snapshot.folds(hiding: "/web/b") == [.repo("/web"), .group(repoPath: "/web", name: "Review")])
        #expect(snapshot.folds(hiding: "/web/d") == [.repo("/web")])
        #expect(snapshot.folds(hiding: "/web") == [.repo("/web")])
        #expect(snapshot.folds(hiding: "/web/ext") == [.repo("/web")])
        #expect(snapshot.folds(hiding: "/api/f") == [.group(repoPath: "/api", name: "Hidden")])
        #expect(snapshot.folds(hiding: "/api/e").isEmpty)
        #expect(snapshot.folds(hiding: "/h/p/one").isEmpty)
        #expect(snapshot.folds(hiding: "/nowhere").isEmpty)
        var folded = snapshot
        folded.plugins[0].collapsed = true
        #expect(folded.folds(hiding: "/h/p/one") == [.plugin("p")])
    }
}
