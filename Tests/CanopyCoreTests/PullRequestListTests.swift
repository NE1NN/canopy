import Foundation
import Testing

@testable import CanopyCore

/// `pr list`: a repo's PRs from a local GitHub, each with the row that has it.
struct PullRequestListTests {
    /// acme/app with a clone at <dir>/demo registered in a workspace.
    func setUp(_ dir: TempDir, github gh: GitHubCLI? = nil) async throws -> (LocalGitHub, String, Workspace) {
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: github.git, github: gh ?? github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (github, repo, workspace)
    }

    @Test func listsOpenPullRequestsNewestFirst() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        for branch in ["feat/a", "feat/b", "feat/c"] {
            try await github.push(to: branch, of: "acme/app")
        }
        try await github.openPR(1, on: "acme/app", from: "feat/a", updatedAt: "2026-09-28T01:00:00Z")
        try await github.openPR(2, on: "acme/app", from: "feat/b", author: nil, updatedAt: "2026-09-28T03:00:00Z")
        try await github.openPR(3, on: "acme/app", from: "feat/c", state: "MERGED", updatedAt: "2026-09-28T02:00:00Z")

        let open = try await workspace.listPullRequests(repoPath: repo)
        let all = try await workspace.listPullRequests(repoPath: repo, includeClosed: true)

        #expect(open.map(\.number) == [2, 1])
        #expect(all.map(\.number) == [2, 3, 1])
        #expect(
            open.last
                == ListedPullRequest(
                    number: 1, title: "PR 1", url: "https://github.com/acme/app/pull/1", state: .open, author: "author",
                    headBranch: "feat/a", isFork: false, updatedAt: "2026-09-28T01:00:00Z"))
        #expect(open.first?.author == nil)
    }

    @Test func filtersByNumberTitleBranchAndAuthor() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "fix/login", of: "acme/app")
        try await github.push(to: "fix/cart", of: "acme/app")
        try await github.openPR(
            1, on: "acme/app", from: "fix/login", title: "Keep the page after logging in", author: "alice",
            updatedAt: "2026-09-28T02:00:00Z")
        try await github.openPR(
            2, on: "acme/app", from: "fix/cart", title: "Round cart totals", author: "bob",
            updatedAt: "2026-09-28T01:00:00Z")

        func numbers(_ query: String) async throws -> [Int] {
            try await workspace.listPullRequests(repoPath: repo, query: query).map(\.number)
        }

        #expect(try await numbers("CART") == [2])
        #expect(try await numbers("alice") == [1])
        #expect(try await numbers("page fix/login") == [1])
        #expect(try await numbers("#2 round") == [2])
        #expect(try await numbers("fix") == [1, 2])
        #expect(try await numbers("nothing") == [])
    }

    @Test func aNumberLooksUpThatPullRequestInAnyState() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/old", of: "acme/app")
        try await github.openPR(5, on: "acme/app", from: "feat/old", state: "CLOSED", author: "carol")

        for query in ["5", " #5 ", "https://github.com/ACME/app/pull/5/files"] {
            let listed = try await workspace.listPullRequests(repoPath: repo, query: query)
            #expect(listed.map(\.number) == [5], "\(query)")
            #expect(listed.first?.state == .closed)
            #expect(listed.first?.author == "carol")
        }
        #expect(try await workspace.listPullRequests(repoPath: repo, query: "#99").isEmpty)
    }

    @Test func aURLOfAnotherRepoIsRefused() async throws {
        let dir = try TempDir()
        let (_, repo, workspace) = try await setUp(dir)

        await #expect(throws: WorkspaceError.pullRequestInOtherRepo("other/app", origin: "acme/app")) {
            try await workspace.listPullRequests(repoPath: repo, query: "https://github.com/other/app/pull/5")
        }
    }

    @Test func saysWhichRowHasEachPullRequest() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        for branch in ["feat/named", "feat/renamed", "feat/elsewhere", "feat/free", "feat/gone"] {
            try await github.push(to: branch, of: "acme/app")
        }
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(1, on: "acme/app", from: "feat/named")
        try await github.openPR(2, on: "acme/app", from: "feat/fork", of: "someone/app")
        try await github.openPR(3, on: "acme/app", from: "feat/renamed")
        try await github.openPR(4, on: "acme/app", from: "feat/elsewhere")
        try await github.openPR(5, on: "acme/app", from: "feat/free")
        try await github.openPR(6, on: "acme/app", from: "feat/gone")
        let named = try await workspace.createRow(repoPath: repo, branch: "feat/named", existing: true).row
        let fork = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 2)).row
        let renamed = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 3), branch: "mine")
            .row
        try await github.git.run(
            [
                "worktree", "add", "--quiet", "--track", "-b", "feat/elsewhere", dir.sub("elsewhere"),
                "origin/feat/elsewhere",
            ], in: repo)
        let gone = try await workspace.createRow(repoPath: repo, branch: "feat/gone", existing: true).row
        try FileManager.default.removeItem(atPath: gone.path)
        await workspace.refresh(repoPath: repo)

        let holders = Dictionary(
            uniqueKeysWithValues: try await workspace.listPullRequests(repoPath: repo).map { ($0.number, $0.row) })

        #expect(holders[1] == BranchHolder(named))
        #expect(holders[2] == BranchHolder(fork))
        #expect(fork.branch == "feat/fork")
        #expect(holders[3] == BranchHolder(renamed))
        #expect(
            holders[4]
                == BranchHolder(
                    path: Paths.canonical(dir.sub("elsewhere")), branch: "feat/elsewhere", rowClass: .external))
        #expect(holders[5] == .some(nil))
        #expect(holders[6] == .some(nil))
    }

    @Test func aForkPullRequestIsNotHeldByASameNamedBranch() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/x", of: "acme/app")
        try await github.push(to: "feat/x", of: "someone/app")
        try await github.openPR(2, on: "acme/app", from: "feat/x", of: "someone/app")
        _ = try await workspace.createRow(repoPath: repo, branch: "feat/x", existing: true)

        #expect(try await workspace.listPullRequests(repoPath: repo).first?.row == nil)
    }

    @Test func ghProblemsAreTheSidebarsErrors() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        github.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")

        await #expect(throws: WorkspaceError.ghUnavailable("Run `gh auth login` to see pull requests.")) {
            try await workspace.listPullRequests(repoPath: repo)
        }
        await #expect(throws: WorkspaceError.ghUnavailable("Run `gh auth login` to see pull requests.")) {
            try await workspace.listPullRequests(repoPath: repo, query: "#1")
        }
        github.fail(exitCode: 1, "HTTP 502: Bad Gateway")
        await #expect(throws: WorkspaceError.ghFailed("HTTP 502: Bad Gateway")) {
            try await workspace.listPullRequests(repoPath: repo)
        }
    }

    @Test func withoutGHThereAreNoPullRequests() async throws {
        let dir = try TempDir()
        let (_, repo, workspace) = try await setUp(dir, github: Fixture.noGH(in: dir))

        await #expect(
            throws: WorkspaceError.ghUnavailable(
                "Install gh to see pull requests: `brew install gh`, then `gh auth login`.")
        ) {
            try await workspace.listPullRequests(repoPath: repo)
        }
    }

    @Test func aRepoNotOnGitHubHasNoPullRequests() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let workspace = Workspace(
            home: CanopyHome(path: dir.sub("home")), git: Fixture.git, github: Fixture.noGH(in: dir))
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        await #expect(throws: WorkspaceError.notOnGitHub("demo")) {
            try await workspace.listPullRequests(repoPath: repo)
        }
    }
}
