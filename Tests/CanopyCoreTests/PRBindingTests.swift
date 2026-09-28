import Foundation
import Testing

@testable import CanopyCore

/// Rows started from a PR their branch name cannot find, and how they keep its badge.
struct PRBindingTests {
    /// acme/app cloned at <dir>/demo, and a row on someone/app's PR 9, whose badge lookups answer with PR 9.
    func setUp(_ dir: TempDir) async throws -> (LocalGitHub, String, Workspace, CreatedRow) {
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app")
        github.reply(
            #"{"data": {"repository": {"b0": {"number": 9, "title": "PR 9", "url": "https://github.com/acme/app/pull/9", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28T00:00:00Z", "isCrossRepository": true}}}}"#
        )
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))
        return (github, repo, workspace, created)
    }

    func bindings(_ workspace: Workspace) async -> [String: PRBinding] {
        await workspace.state.repos.first?.prBindings ?? [:]
    }

    @Test func aForkRowShowsItsPullRequest() async throws {
        let dir = try TempDir()
        let (github, repo, workspace, created) = try await setUp(dir)

        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await workspace.snapshot.row(path: created.row.path)?.pullRequest?.number == 9)
        #expect(github.calls.last?.contains("b0: pullRequest(number: 9)") == true)
    }

    @Test func aBindingForAnotherRepoIsIgnored() async throws {
        let dir = try TempDir()
        let (github, repo, workspace, _) = try await setUp(dir)
        try await github.git.run(["remote", "set-url", "origin", "https://github.com/acme/renamed.git"], in: repo)

        await workspace.refreshPullRequests(repoPath: repo)

        let query = try #require(github.calls.last)
        #expect(query.contains(#"b0: pullRequests(headRefName: "feat/fork""#))
        #expect(!query.contains("pullRequest(number:"))
    }

    @Test func aRowRemovedWithItsBranchForgetsThePullRequest() async throws {
        let dir = try TempDir()
        let (_, _, workspace, created) = try await setUp(dir)

        try await workspace.removeRow(path: created.row.path, deleteBranch: true)

        #expect(await bindings(workspace).isEmpty)
    }

    @Test func aBranchCheckedOutAgainKeepsItsPullRequest() async throws {
        let dir = try TempDir()
        let (github, repo, workspace, created) = try await setUp(dir)
        try await workspace.removeRow(path: created.row.path)

        let again = try await workspace.createRow(repoPath: repo, branch: "feat/fork", existing: true)
        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await bindings(workspace) == ["feat/fork": PRBinding(number: 9, repo: "acme/app")])
        #expect(await workspace.snapshot.row(path: again.row.path)?.pullRequest?.number == 9)
        #expect(github.calls.last?.contains("b0: pullRequest(number: 9)") == true)
    }

    @Test func aNewBranchWithTheSameNameForgetsThePullRequest() async throws {
        let dir = try TempDir()
        let (github, repo, workspace, created) = try await setUp(dir)
        try await workspace.removeRow(path: created.row.path)
        try await github.git.run(["branch", "-D", "feat/fork"], in: repo)

        let new = try await workspace.createRow(repoPath: repo, branch: "feat/fork")

        #expect(new.source == .new)
        #expect(await bindings(workspace).isEmpty)
    }
}
