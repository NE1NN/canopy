import Foundation
import Testing

@testable import CanopyCore

/// `row new --pr`: PRs from the repo itself and from forks, fetched from a local GitHub.
struct PullRequestRowTests {
    /// acme/app with a clone at <dir>/demo registered in a workspace.
    func setUp(_ dir: TempDir, git: GitRunner? = nil) async throws -> (LocalGitHub, String, Workspace) {
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git ?? github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (github, repo, workspace)
    }

    func run(_ github: LocalGitHub, _ arguments: [String], in path: String) async throws -> String {
        try await github.git.run(arguments, in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func config(_ github: LocalGitHub, _ key: String, in path: String) async -> String? {
        try? await run(github, ["config", "--get", key], in: path)
    }

    func bindings(_ workspace: Workspace) async -> [String: PRBinding] {
        await workspace.state.repos.first?.prBindings ?? [:]
    }

    @Test func checksOutASameRepoPullRequestsBranch() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        let tip = try await github.push(to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7))

        #expect(created.row.branch == "feat/split")
        #expect(created.source == .origin)
        #expect(created.pullRequest?.number == 7)
        #expect(created.warnings.isEmpty && created.notes.isEmpty)
        #expect(try await run(github, ["rev-parse", "HEAD"], in: created.row.path) == tip)
        #expect(
            try await run(github, ["rev-parse", "--abbrev-ref", "@{upstream}"], in: created.row.path)
                == "origin/feat/split")
        #expect(await bindings(workspace).isEmpty)
    }

    @Test func aSameRepoPullRequestUnderAnotherName() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7), branch: "mine")

        #expect(created.row.branch == "mine")
        #expect(
            try await run(github, ["rev-parse", "--abbrev-ref", "@{upstream}"], in: created.row.path)
                == "origin/feat/split")
        #expect(created.warnings.count == 1 && created.warnings[0].contains("git push origin HEAD:feat/split"))
        #expect(await bindings(workspace) == ["mine": PRBinding(number: 7, repo: "acme/app")])
    }

    @Test func bringsTheLocalHeadUpToDate() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/split", of: "acme/app")
        try await run(github, ["fetch", "--quiet", "origin"], in: repo)
        try await run(github, ["branch", "--track", "feat/split", "origin/feat/split"], in: repo)
        let tip = try await github.push(2, to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7))

        #expect(created.source == .local)
        #expect(created.notes == ["Fast-forwarded feat/split by 2 commits to match origin/feat/split."])
        #expect(try await run(github, ["rev-parse", "HEAD"], in: created.row.path) == tip)
    }

    @Test func aMergedPullRequestWhoseBranchIsGone() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        let tip = try await github.push(to: "feat/done", of: "acme/app")
        try await github.openPR(8, on: "acme/app", from: "feat/done", state: "MERGED", deleteBranch: true)

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 8))

        #expect(created.row.branch == "feat/done")
        #expect(try await run(github, ["rev-parse", "HEAD"], in: created.row.path) == tip)
        #expect(await config(github, "branch.feat/done.remote", in: repo) == "origin")
        #expect(await config(github, "branch.feat/done.merge", in: repo) == "refs/pull/8/head")
        #expect(created.warnings.contains("PR #8 is merged, not open."))
        #expect(created.warnings.contains { $0.contains("gone from origin") })
        #expect(created.warnings.contains { $0.contains("git push -u origin HEAD:feat/done") })
        try await run(github, ["pull", "--quiet"], in: created.row.path)
        #expect(!(await github.git.succeeds(["show-ref", "--quiet", "refs/canopy/pr/8"], in: repo)))
    }

    @Test func aForkThatLetsMaintainersPush() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app", maintainerCanModify: true)

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))

        #expect(created.row.branch == "feat/fork")
        #expect(created.source == .origin)
        #expect(created.warnings.isEmpty)
        let fork = "https://github.com/someone/app.git"
        #expect(await config(github, "branch.feat/fork.remote", in: repo) == fork)
        #expect(await config(github, "branch.feat/fork.pushRemote", in: repo) == fork)
        #expect(await config(github, "branch.feat/fork.merge", in: repo) == "refs/heads/feat/fork")
        #expect(await bindings(workspace) == ["feat/fork": PRBinding(number: 9, repo: "acme/app")])
        #expect(!(await github.git.succeeds(["show-ref", "--quiet", "refs/canopy/pr/9"], in: repo)))

        let newer = try await github.push(to: "feat/fork", of: "someone/app")
        try await run(github, ["pull", "--quiet"], in: created.row.path)
        #expect(try await run(github, ["rev-parse", "HEAD"], in: created.row.path) == newer)
        try await run(github, ["commit", "--quiet", "--allow-empty", "-m", "review fix"], in: created.row.path)
        try await run(github, ["push", "--quiet"], in: created.row.path)
        #expect(
            try await Fixture.git.run(["rev-parse", "refs/heads/feat/fork"], in: github.bare("someone/app"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == (try await run(github, ["rev-parse", "HEAD"], in: created.row.path)))
    }

    @Test func aForkThatDoesNotLetMaintainersPush() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        let tip = try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app")

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))

        #expect(try await run(github, ["rev-parse", "HEAD"], in: created.row.path) == tip)
        #expect(await config(github, "branch.feat/fork.remote", in: repo) == "origin")
        #expect(await config(github, "branch.feat/fork.merge", in: repo) == "refs/pull/9/head")
        #expect(
            created.warnings.count == 1 && created.warnings[0].contains("someone's fork does not let maintainers push"))
        try await run(github, ["pull", "--quiet"], in: created.row.path)
    }

    @Test func aForkThatIsGone() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(
            9, on: "acme/app", from: "feat/fork", of: "someone/app", state: "CLOSED", maintainerCanModify: true,
            forkGone: true)

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))

        #expect(created.row.branch == "feat/fork")
        #expect(await config(github, "branch.feat/fork.merge", in: repo) == "refs/pull/9/head")
        #expect(created.warnings.contains("PR #9 is closed, not open."))
        #expect(created.warnings.contains { $0.contains("The fork PR #9 came from is gone") })
    }

    @Test func aForkBranchNamedLikeTheDefaultBranchGetsItsOwner() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "main", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "main", of: "someone/app", maintainerCanModify: true)

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))

        #expect(created.row.branch == "someone/main")
        #expect(
            created.warnings.count == 1
                && created.warnings[0].contains("git push https://github.com/someone/app.git HEAD:main"))
    }

    @Test func aForkBranchWhoseNameIsTakenGetsItsOwner() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app")
        try await run(github, ["branch", "feat/fork"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))

        #expect(created.row.branch == "someone/feat/fork")
        #expect(await bindings(workspace) == ["someone/feat/fork": PRBinding(number: 9, repo: "acme/app")])
    }

    @Test func reusesABranchThatTracksThePullRequest() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app", maintainerCanModify: true)
        let first = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))
        try await workspace.removeRow(path: first.row.path)
        let tip = try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app", maintainerCanModify: true)

        let again = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))

        #expect(again.row.branch == "feat/fork")
        #expect(again.source == .local)
        #expect(again.notes == ["Fast-forwarded feat/fork by 1 commit to match PR #9's head."])
        #expect(try await run(github, ["rev-parse", "HEAD"], in: again.row.path) == tip)
    }

    @Test func refusesABranchNameThatIsNotThePullRequests() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")
        try await run(github, ["branch", "mine"], in: repo)

        await #expect(throws: WorkspaceError.branchExists(["mine"], pr: 7)) {
            try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7), branch: "mine")
        }
    }

    @Test func aPullRequestAlreadyInARowNamesTheRow() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")

        func attempt() async -> Result<CreatedRow, any Error> {
            do {
                return .success(try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7)))
            } catch {
                return .failure(error)
            }
        }
        async let first = attempt()
        async let second = attempt()
        let results = await [first, second]

        let created = try #require(results.compactMap { try? $0.get() }.first)
        let failures = results.compactMap { result -> WorkspaceError? in
            guard case .failure(let error) = result else { return nil }
            return error as? WorkspaceError
        }
        #expect(failures == [.branchCheckedOut("feat/split", row: created.row)])
    }

    @Test func saysWhatIsWrongWithTheRequest() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)

        await #expect(throws: WorkspaceError.pullRequestNotFound(99, repo: "acme/app")) {
            try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 99))
        }
        let elsewhere = PRReference(number: 7, repo: GitHubRepo(owner: "other", name: "app"))
        await #expect(throws: WorkspaceError.pullRequestInOtherRepo("other/app", origin: "acme/app")) {
            try await workspace.createRow(repoPath: repo, pullRequest: elsewhere)
        }
        let sameRepo = PRReference(number: 99, repo: GitHubRepo(owner: "ACME", name: "App"))
        await #expect(throws: WorkspaceError.pullRequestNotFound(99, repo: "acme/app")) {
            try await workspace.createRow(repoPath: repo, pullRequest: sameRepo)
        }
        github.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")
        await #expect {
            try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7))
        } throws: { error in
            guard case WorkspaceError.ghUnavailable(let message) = error else { return false }
            return message.contains("gh auth login")
        }
    }

    @Test func needsOriginOnGitHub() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        await #expect(throws: WorkspaceError.notOnGitHub("demo")) {
            try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7))
        }
    }

    @Test func aFailedFetchLeavesNothingBehind() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app")
        try await Fixture.git.run(["update-ref", "-d", "refs/pull/9/head"], in: github.bare("acme/app"))

        await #expect {
            try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))
        } throws: { error in
            guard case WorkspaceError.pullRequestFetchFailed(9, let reason) = error else { return false }
            return reason.contains("refs/pull/9/head")
        }
        #expect(!(await github.git.succeeds(["show-ref", "--quiet", "refs/canopy/pr/9"], in: repo)))
        #expect(!(await github.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/fork"], in: repo)))
        #expect(await workspace.snapshot.repos.first?.rows.count == 1)
    }

    @Test func aFailedAddDeletesTheBranchItMade() async throws {
        let dir = try TempDir()
        let github = try LocalGitHub(dir)
        let git = try github.git(
            before: #"[[ "$1 $2" == "worktree add" ]] && { echo "fatal: simulated" >&2; exit 128; }"#)
        let (_, repo, workspace) = try await setUp(dir, git: git)
        try await github.fork("acme/app", as: "someone/app")
        try await github.push(to: "feat/fork", of: "someone/app")
        try await github.openPR(9, on: "acme/app", from: "feat/fork", of: "someone/app")

        await #expect(throws: WorkspaceError.self) {
            try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 9))
        }
        #expect(!(await github.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/fork"], in: repo)))
        #expect(await config(github, "branch.feat/fork.merge", in: repo) == nil)
        #expect(!(await github.git.succeeds(["show-ref", "--quiet", "refs/canopy/pr/9"], in: repo)))
    }
}
