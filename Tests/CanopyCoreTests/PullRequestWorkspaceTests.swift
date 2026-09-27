import Foundation
import Testing

@testable import CanopyCore

/// A fake gh that records each query and answers from files the test writes.
struct FakeGH {
    let cli: GitHubCLI
    private let callsFile: String
    private let replyFile: String
    private let failureFile: String

    init(_ dir: TempDir) throws {
        callsFile = dir.sub("gh-calls")
        replyFile = dir.sub("gh-reply")
        failureFile = dir.sub("gh-failure")
        cli = try Fixture.gh(
            in: dir,
            """
            printf '%s\\n' "$4" >> "\(callsFile)"
            if [[ -f "\(failureFile)" ]]; then { read -r code; cat >&2; } < "\(failureFile)"; exit "$code"; fi
            cat "\(replyFile)" 2>/dev/null || echo '{"data": {"repository": {}}}'
            """)
    }

    /// Answers with these PRs, keyed by the position of their branch in the query.
    func answer(_ prs: [Int: (number: Int, state: String)]) {
        let fields = prs.map { index, pr in
            #""b\#(index)": {"nodes": [{"number": \#(pr.number), "title": "PR \#(pr.number)", "url": "https://github.com/NE1NN/canopy/pull/\#(pr.number)", "state": "\#(pr.state)", "isDraft": false, "updatedAt": "2026-09-28T00:00:00Z", "headRepository": {"nameWithOwner": "NE1NN/canopy"}}]}"#
        }
        let json = #"{"data": {"repository": {"# + fields.joined(separator: ", ") + "}}}"
        try? FileManager.default.removeItem(atPath: failureFile)
        try? json.write(toFile: replyFile, atomically: true, encoding: .utf8)
    }

    func fail(exitCode: Int, _ message: String) {
        try? "\(exitCode)\n\(message)\n".write(toFile: failureFile, atomically: true, encoding: .utf8)
    }

    /// The query of every call so far.
    var calls: [String] {
        ((try? String(contentsOfFile: callsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

struct PullRequestWorkspaceTests {
    /// A repo whose origin is on GitHub, with rows feat/a and feat/b. feat/a has PR 5.
    func setUp(_ dir: TempDir, github: GitHubCLI? = nil, timing: PRTiming = .standard) async throws
        -> (Workspace, FakeGH, String)
    {
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.git.run(["remote", "add", "origin", "git@github.com:NE1NN/canopy.git"], in: repo)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        try await Fixture.worktree(repo: repo, branch: "feat/b", at: dir.sub("home/worktrees/demo/feat-b"))
        let gh = try FakeGH(dir)
        gh.answer([0: (5, "OPEN")])
        let workspace = Workspace(
            home: CanopyHome(path: dir.sub("home")), git: Fixture.git, github: github ?? gh.cli, prTiming: timing)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (workspace, gh, repo)
    }

    func pullRequest(_ workspace: Workspace, _ path: String) async -> PullRequest? {
        await workspace.snapshot.row(path: path)?.pullRequest
    }

    @Test func rowsShowTheirPullRequest() async throws {
        let dir = try TempDir()
        let (workspace, gh, repo) = try await setUp(dir)

        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-a"))?.number == 5)
        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-a"))?.state == .open)
        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-b")) == nil)
        #expect(await pullRequest(workspace, repo) == nil)
        #expect(await workspace.snapshot.repos.first?.pullRequestWarning == nil)
        let query = try #require(gh.calls.last)
        #expect(query.contains(#"b0: pullRequests(headRefName: "feat/a""#))
        #expect(query.contains(#"b1: pullRequests(headRefName: "feat/b""#))
        #expect(!query.contains(#"headRefName: "main""#))
    }

    @Test func reposOffGitHubAreNotLookedUp() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        let gh = try FakeGH(dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git, github: gh.cli)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        await workspace.refreshPullRequests(repoPath: repo)

        #expect(gh.calls.isEmpty)
        #expect(await workspace.snapshot.repos.first?.pullRequestWarning == nil)
    }

    @Test func loggedOutGHHidesBadgesAndSaysHowToFixIt() async throws {
        let dir = try TempDir()
        let (workspace, gh, repo) = try await setUp(dir)
        await workspace.refreshPullRequests(repoPath: repo)

        gh.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")
        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-a")) == nil)
        #expect(await workspace.snapshot.repos.first?.pullRequestWarning?.contains("gh auth login") == true)
    }

    @Test func missingGHSaysHowToInstallIt() async throws {
        let dir = try TempDir()
        let github = GitHubCLI(environment: ["PATH": dir.path, "HOME": dir.path], fallbackFolders: [])
        let (workspace, _, repo) = try await setUp(dir, github: github)

        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await workspace.snapshot.repos.first?.pullRequestWarning?.contains("brew install gh") == true)
    }

    @Test func aFailedLookupKeepsTheLastBadges() async throws {
        let dir = try TempDir()
        let (workspace, gh, repo) = try await setUp(dir)
        await workspace.refreshPullRequests(repoPath: repo)

        gh.fail(exitCode: 1, "gh: error connecting to api.github.com")
        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-a"))?.number == 5)
        #expect(
            await workspace.snapshot.repos.first?.pullRequestWarning?.contains("error connecting to api.github.com")
                == true)

        gh.answer([0: (5, "MERGED")])
        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-a"))?.state == .merged)
        #expect(await workspace.snapshot.repos.first?.pullRequestWarning == nil)
    }

    @Test func newRowsAreLookedUp() async throws {
        let dir = try TempDir()
        let (workspace, gh, repo) = try await setUp(dir)

        try await Fixture.worktree(repo: repo, branch: "feat/c", at: dir.sub("home/worktrees/demo/feat-c"))
        await workspace.refresh(repoPath: repo)

        let lookedUp = await eventually { gh.calls.last?.contains(#"headRefName: "feat/c""#) == true }
        #expect(lookedUp)
        _ = workspace
    }

    @Test func aPushRefreshesOftenForAWhile() async throws {
        let dir = try TempDir()
        let timing = PRTiming(
            interval: .seconds(3600), focusGap: .seconds(3600), afterPushInterval: .milliseconds(100),
            afterPushDuration: .milliseconds(800))
        let (workspace, gh, repo) = try await setUp(dir, timing: timing)
        await workspace.refreshPullRequests(repoPath: repo)
        let before = gh.calls.count
        try await Task.sleep(for: .milliseconds(300))

        try await Fixture.git.run(["update-ref", "refs/remotes/origin/feat/a", "HEAD"], in: repo)

        let refreshed = await eventually { gh.calls.count >= before + 3 }
        #expect(refreshed)
        try await Task.sleep(for: .milliseconds(1200))
        let settled = gh.calls.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(gh.calls.count == settled)
        _ = workspace
    }

    @Test func focusRefreshesAtMostOncePerGap() async throws {
        let dir = try TempDir()
        let timing = PRTiming(
            interval: .seconds(3600), focusGap: .seconds(3600), afterPushInterval: .seconds(10),
            afterPushDuration: .seconds(120))
        let (workspace, gh, repo) = try await setUp(dir, timing: timing)
        await workspace.refreshPullRequests(repoPath: repo)
        let before = gh.calls.count

        await workspace.applicationBecameActive()
        await workspace.applicationBecameActive()

        #expect(gh.calls.count == before + 1)
    }

    @Test func refreshesOnATimer() async throws {
        let dir = try TempDir()
        let timing = PRTiming(
            interval: .milliseconds(150), focusGap: .seconds(3600), afterPushInterval: .seconds(10),
            afterPushDuration: .seconds(120))
        let (workspace, gh, repo) = try await setUp(dir, timing: timing)
        await workspace.refreshPullRequests(repoPath: repo)
        let before = gh.calls.count

        let refreshed = await eventually { gh.calls.count >= before + 3 }

        #expect(refreshed)
        await workspace.stop()
        try await Task.sleep(for: .milliseconds(300))
        let stopped = gh.calls.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(gh.calls.count == stopped)
    }

    @Test func removingARepoForgetsItsPullRequests() async throws {
        let dir = try TempDir()
        let (workspace, _, repo) = try await setUp(dir)
        await workspace.refreshPullRequests(repoPath: repo)

        try await workspace.removeRepo(path: repo)

        #expect(await workspace.pullRequests[repo] == nil)
    }
}
