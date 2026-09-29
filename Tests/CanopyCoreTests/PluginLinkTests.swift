import Foundation
import Testing

@testable import CanopyCore

/// Worktree rows linked to a plugin's item, such as a fix row for a ticket.
struct PluginLinkTests {
    static let link = PluginLink(plugin: "p", item: "i1")

    func setUp(_ dir: TempDir) async throws -> (Workspace, String) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        await workspace.registerPlugins([PluginInfo(id: "p", name: "P", symbol: "star")])
        try await workspace.addRepo(path: repo)
        return (workspace, repo)
    }

    func links(_ workspace: Workspace) async -> [String: String] {
        await workspace.pluginEntry("p")?.links ?? [:]
    }

    @Test func aLinkedRowCarriesItsLinkAndLogsIt() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)

        let created = try await workspace.createRow(repoPath: repo, branch: "fix/a", link: Self.link)
        let plain = try await workspace.createRow(repoPath: repo, branch: "fix/b")

        #expect(created.row.link == Self.link)
        #expect(plain.row.link == nil)
        #expect(await workspace.snapshot.row(path: created.row.path)?.link == Self.link)
        #expect(await workspace.snapshot.linkedRows(plugin: "p", item: "i1").map(\.path) == [created.row.path])
        #expect(await links(workspace) == [created.row.path: "i1"])
        let events = await logged(workspace, "row")
        #expect(events.map(\.data["link"]) == [.object(["plugin": "p", "item": "i1"]), nil])
        #expect(try JSONValue.from(created.row).decode([String: JSONValue].self)["link"] != nil)
        #expect(try JSONValue.from(plain.row).decode([String: JSONValue].self)["link"] == nil)
    }

    @Test func aPullRequestRowCanBeLinkedToo() async throws {
        let dir = try TempDir()
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")

        let created = try await workspace.createRow(
            repoPath: repo, pullRequest: PRReference(number: 7), link: Self.link)

        #expect(created.row.link == Self.link)
        #expect(await logged(workspace, "row").first?.data["link"] == .object(["plugin": "p", "item": "i1"]))
    }

    @Test func theLinkGoesWhenTheRowGoes() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let removed = try await workspace.createRow(repoPath: repo, branch: "fix/a", link: Self.link).row
        let gone = try await workspace.createRow(repoPath: repo, branch: "fix/b", link: Self.link).row
        let kept = try await workspace.createRow(repoPath: repo, branch: "fix/c", link: Self.link).row

        try await workspace.removeRow(path: removed.path)
        try await Fixture.git.run(["worktree", "remove", gone.path], in: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await links(workspace) == [kept.path: "i1"])
        #expect(await workspace.snapshot.linkedRows(plugin: "p", item: "i1").map(\.path) == [kept.path])
    }

    @Test func aRowWhoseFolderIsMissingKeepsItsLink() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let row = try await workspace.createRow(repoPath: repo, branch: "fix/a", link: Self.link).row

        try FileManager.default.removeItem(atPath: row.path)
        await workspace.refresh(repoPath: repo)

        #expect(await workspace.snapshot.row(path: row.path)?.isMissing == true)
        #expect(await links(workspace) == [row.path: "i1"])
    }

    @Test func aLinkWhoseRowWentAwayWhileCanopyWasClosedGoesAtTheNextStart() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let row = try await workspace.createRow(repoPath: repo, branch: "fix/a", link: Self.link).row
        await workspace.stop()

        try await Fixture.git.run(["worktree", "remove", row.path], in: repo)
        let relaunched = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await relaunched.start()

        #expect(await relaunched.pluginEntry("p")?.links == [:])
    }

    @Test func aMissingRepoKeepsItsLinks() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let row = try await workspace.createRow(repoPath: repo, branch: "fix/a", link: Self.link).row

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)

        #expect(await workspace.snapshot.repo(path: repo)?.isMissing == true)
        #expect(await links(workspace) == [row.path: "i1"])
    }

    @Test func unadoptingDropsTheLinkAndSoDoesRemovingTheRepo() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let elsewhere = dir.sub("elsewhere/fix-x")
        try await Fixture.worktree(repo: repo, branch: "fix/x", at: elsewhere)
        let adopted = try await workspace.adopt(path: elsewhere)
        try await workspace.setPluginLink(Self.link, forRow: adopted.path)
        let canopy = try await workspace.createRow(repoPath: repo, branch: "fix/a", link: Self.link).row
        #expect(await workspace.snapshot.row(path: adopted.path)?.link == Self.link)

        try await workspace.unadopt(path: adopted.path)
        #expect(await links(workspace) == [canopy.path: "i1"])

        try await workspace.removeRepo(path: repo)
        #expect(await links(workspace) == [:])
    }
}
