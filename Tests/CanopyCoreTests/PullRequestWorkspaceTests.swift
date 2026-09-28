import Foundation
import Testing

@testable import CanopyCore

/// A fake gh that records each query and answers from files the test writes.
struct FakeGH {
    let cli: GitHubCLI
    private let callsFile: String
    private let replyFile: String
    private let failureFile: String

    init(_ dir: TempDir, sshConfigFile: String? = nil) throws {
        callsFile = dir.sub("gh-calls")
        replyFile = dir.sub("gh-reply")
        failureFile = dir.sub("gh-failure")
        cli = try Fixture.gh(
            in: dir, sshConfigFile: sshConfigFile,
            """
            printf '%s\\n' "$4" >> "\(callsFile)"
            if [[ -f "\(failureFile)" ]]; then { read -r code; cat >&2; } < "\(failureFile)"; exit "$code"; fi
            cat "\(replyFile)" 2>/dev/null || echo '{"data": {"repository": {}}}'
            """)
    }

    /// Answers with these PRs, keyed by the position of their branch in the query.
    func answer(_ prs: [Int: (number: Int, state: String)]) {
        let fields = prs.map { index, pr in
            #""b\#(index)": {"nodes": [{"number": \#(pr.number), "title": "PR \#(pr.number)", "url": "https://github.com/NE1NN/canopy/pull/\#(pr.number)", "state": "\#(pr.state)", "isDraft": false, "updatedAt": "2026-09-28T00:00:00Z", "isCrossRepository": false}]}"#
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

    @Test func originsThroughAnSSHAliasAreLookedUp() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.git.run(["remote", "add", "origin", "git@github-work:NE1NN/canopy.git"], in: repo)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        try "Host github-work\n  HostName github.com\n".write(
            toFile: dir.sub("ssh_config"), atomically: true, encoding: .utf8)
        let gh = try FakeGH(dir, sshConfigFile: dir.sub("ssh_config"))
        gh.answer([0: (5, "OPEN")])
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git, github: gh.cli)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        await workspace.refreshPullRequests(repoPath: repo)

        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-a"))?.number == 5)
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

    @Test func aMissingRepoOnlySaysItIsMissing() async throws {
        let dir = try TempDir()
        let (workspace, gh, repo) = try await setUp(dir)
        gh.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")
        await workspace.refreshPullRequests(repoPath: repo)

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)

        #expect(await workspace.snapshot.repos.first?.isMissing == true)
        #expect(await workspace.snapshot.repos.first?.pullRequestWarning == nil)
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

        let lookedUp = await eventually {
            gh.calls.last?.contains(#"headRefName: "feat/c""#) == true
        }
        #expect(lookedUp)
        _ = workspace
    }

    @Test func aPushRefreshesOftenForAWhile() async throws {
        let dir = try TempDir()
        // A loaded CI runner fits only a few lookups into a second, so the window is long and the waits generous.
        let timing = PRTiming(
            interval: .seconds(3600), focusGap: .seconds(3600), afterPushInterval: .milliseconds(50),
            afterPushDuration: .seconds(4))
        let (workspace, gh, repo) = try await setUp(dir, timing: timing)
        try await Fixture.git.run(["init", "--quiet", "--bare", dir.sub("mirror.git")])
        try await Fixture.git.run(["remote", "add", "mirror", dir.sub("mirror.git")], in: repo)
        await workspace.refreshPullRequests(repoPath: repo)
        let before = gh.calls.count
        // FSEvents only reports writes made after its stream starts.
        try await Task.sleep(for: .milliseconds(300))

        try await Fixture.git.run(["push", "--quiet", "mirror", "feat/a"], in: repo)

        let refreshed = await eventually { gh.calls.count >= before + 3 }
        #expect(refreshed, "\(gh.calls.count - before) lookups after the push")
        let ended = await eventually { await workspace.afterPush[repo] == nil }
        #expect(ended)
        let settled = gh.calls.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(gh.calls.count == settled)
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

        #expect(refreshed, "\(gh.calls.count - before) lookups on the timer")
        await workspace.stop()
        await workspace.prQueues[repo]?.value
        let stopped = gh.calls.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(gh.calls.count == stopped)
    }

    @Test func nothingIsLookedUpAfterStop() async throws {
        let dir = try TempDir()
        let (workspace, gh, repo) = try await setUp(dir)
        await workspace.refreshPullRequests(repoPath: repo)
        let before = gh.calls.count

        await workspace.stop()
        await workspace.refreshOftenAfterPush(repoPath: repo)
        try await Fixture.worktree(repo: repo, branch: "feat/c", at: dir.sub("home/worktrees/demo/feat-c"))
        await workspace.refresh(repoPath: repo)
        await workspace.refreshPullRequests(repoPath: repo)
        await workspace.prQueues[repo]?.value

        #expect(await workspace.afterPush[repo] == nil)
        #expect(gh.calls.count == before)
    }

    @Test func anAnswerForARepoRemovedMeanwhileIsDropped() async throws {
        let dir = try TempDir()
        let ghDir = try TempDir()
        let started = ghDir.sub("started")
        let release = ghDir.sub("release")
        let github = try Fixture.gh(
            in: ghDir,
            """
            touch "\(started)"
            while [[ ! -f "\(release)" ]]; do sleep 0.05; done
            echo '{"data": {"repository": {"b0": {"nodes": [{"number": 5, "title": "t", "url": "u", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28", "isCrossRepository": false}]}}}}'
            """)
        let (workspace, _, repo) = try await setUp(dir, github: github)
        let lookup = Task { await workspace.refreshPullRequests(repoPath: repo) }
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })

        try await workspace.removeRepo(path: repo)
        FileManager.default.createFile(atPath: release, contents: nil)
        await lookup.value

        #expect(await workspace.pullRequests[repo] == nil)
    }

    @Test func removingARepoForgetsItsPullRequests() async throws {
        let dir = try TempDir()
        let (workspace, _, repo) = try await setUp(dir)
        await workspace.refreshPullRequests(repoPath: repo)

        try await workspace.removeRepo(path: repo)

        #expect(await workspace.pullRequests[repo] == nil)
    }

    @Test func askingForARowsPullRequestLooksItUpIfNeeded() async throws {
        let dir = try TempDir()
        let (workspace, gh, _) = try await setUp(dir)
        let row = try #require(await workspace.snapshot.row(path: dir.sub("home/worktrees/demo/feat-a")))

        #expect(try await workspace.pullRequest(for: row, refresh: false)?.number == 5)

        gh.answer([0: (5, "MERGED")])
        #expect(try await workspace.pullRequest(for: row, refresh: false)?.state == .open)
        #expect(try await workspace.pullRequest(for: row, refresh: true)?.state == .merged)
    }

    @Test func mainRowsHaveNoPullRequestLookup() async throws {
        let dir = try TempDir()
        let (workspace, _, repo) = try await setUp(dir)
        let main = try #require(await workspace.snapshot.row(path: repo))

        await #expect(throws: WorkspaceError.noPullRequestLookup("main")) {
            try await workspace.pullRequest(for: main, refresh: false)
        }
    }

    @Test func lookupsSayWhyTheyCannotAnswer() async throws {
        let dir = try TempDir()
        let (workspace, gh, _) = try await setUp(dir)
        let row = try #require(await workspace.snapshot.row(path: dir.sub("home/worktrees/demo/feat-a")))
        _ = try await workspace.pullRequest(for: row, refresh: true)

        gh.fail(exitCode: 1, "gh: error connecting to api.github.com")
        #expect(try await workspace.pullRequest(for: row, refresh: false)?.number == 5)
        await #expect(throws: WorkspaceError.ghFailed("error connecting to api.github.com")) {
            try await workspace.pullRequest(for: row, refresh: true)
        }

        gh.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")
        await #expect {
            try await workspace.pullRequest(for: row, refresh: true)
        } throws: { error in
            guard case WorkspaceError.ghUnavailable(let message) = error else { return false }
            return message.contains("gh auth login")
        }
    }

    @Test func reposOffGitHubSaySo() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        let workspace = Workspace(
            home: CanopyHome(path: dir.sub("home")), git: Fixture.git, github: try FakeGH(dir).cli)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let row = try #require(await workspace.snapshot.row(path: dir.sub("home/worktrees/demo/feat-a")))

        await #expect(throws: WorkspaceError.notOnGitHub("demo")) {
            try await workspace.pullRequest(for: row, refresh: false)
        }
    }
}
