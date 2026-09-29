import Foundation
import Testing

@testable import CanopyCore

struct WorkspaceFoldTests {
    static let plugin = PluginInfo(id: "p", name: "P", symbol: "star")

    func workspace(_ dir: TempDir) async throws -> Workspace {
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        await workspace.registerPlugins([Self.plugin])
        return workspace
    }

    @Test func aRepoFoldIsSavedAndLogsNothing() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await workspace(dir)
        try await workspace.addRepo(path: repo)

        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)
        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)

        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == true)
        #expect(await logged(workspace, "repo", "row", "group").map(\.type) == [ActivityType.repoAdded])
        await workspace.stop()
        let relaunched = try await self.workspace(dir)
        #expect(await relaunched.snapshot.repo(path: repo)?.collapsed == true)
        try await relaunched.setRepoCollapsed(repoPath: repo, collapsed: false)
        #expect(await relaunched.snapshot.repo(path: repo)?.collapsed == false)
    }

    @Test func anUnknownRepoCannotFold() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)

        await #expect(throws: WorkspaceError.repoNotFound("/nowhere")) {
            try await workspace.setRepoCollapsed(repoPath: "/nowhere", collapsed: true)
        }
    }

    @Test func revealingARowUnfoldsItsRepoAndGroup() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await workspace(dir)
        try await workspace.addRepo(path: repo)
        try await workspace.createGroup(repoPath: repo, name: "Review")
        let grouped = try await workspace.createRow(repoPath: repo, branch: "feat/a", group: "Review").row
        let plain = try await workspace.createRow(repoPath: repo, branch: "feat/b").row
        try await workspace.setGroupCollapsed(repoPath: repo, name: "Review", collapsed: true)
        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)
        #expect(
            await workspace.snapshot.folds(hiding: grouped.path) == [
                .repo(repo), .group(repoPath: repo, name: "Review"),
            ])

        try await workspace.revealRow(path: plain.path)
        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == false)
        #expect(await workspace.snapshot.repo(path: repo)?.groups.first?.collapsed == true)

        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)
        try await workspace.revealRow(path: grouped.path)
        let snapshot = await workspace.snapshot
        #expect(snapshot.folds(hiding: grouped.path).isEmpty)
        #expect(snapshot.repo(path: repo)?.collapsed == false)
        #expect(snapshot.repo(path: repo)?.groups.first?.collapsed == false)
        await workspace.stop()
        #expect(try await self.workspace(dir).snapshot.folds(hiding: grouped.path).isEmpty)
    }

    @Test func revealingARowTheSidebarShowsChangesNothing() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await workspace(dir)
        try await workspace.addRepo(path: repo)
        let saved = try Data(contentsOf: CanopyHome(path: dir.sub("home")).stateFile)

        try await workspace.revealRow(path: repo)
        try await workspace.revealRow(path: "/nowhere")

        #expect(try Data(contentsOf: CanopyHome(path: dir.sub("home")).stateFile) == saved)
    }

    @Test func aPluginFoldIsKeptWhileItIsOffAndUnknownPluginsFail() async throws {
        let dir = try TempDir()
        let workspace = try await workspace(dir)
        let row = try await workspace.addPluginRow(
            PluginRowEntry(item: "1", title: "one", path: "/h/plugins/p/one"), plugin: "p")

        try await workspace.setPluginCollapsed("p", collapsed: true)
        #expect(await workspace.snapshot.section("p")?.collapsed == true)
        // The plugin is off, so its rows are not in the sidebar and nothing hides them.
        #expect(await workspace.snapshot.folds(hiding: row.path).isEmpty)
        await workspace.setPlugin("p", on: true)
        #expect(await workspace.snapshot.folds(hiding: row.path) == [.plugin("p")])
        #expect(await workspace.snapshot.visibleRows.isEmpty)

        await workspace.stop()
        let relaunched = try await self.workspace(dir)
        await relaunched.setPlugin("p", on: true)
        #expect(await relaunched.snapshot.section("p")?.collapsed == true)
        try await relaunched.revealRow(path: row.path)
        #expect(await relaunched.snapshot.section("p")?.collapsed == false)
        #expect(await relaunched.snapshot.visibleRows.map(\.path) == [row.path])
        await #expect(throws: WorkspaceError.pluginNotFound("nope")) {
            try await relaunched.setPluginCollapsed("nope", collapsed: true)
        }
    }
}
