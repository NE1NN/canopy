import Foundation
import Testing

@testable import CanopyCore

struct GitHubCLITests {
    let repo = GitHubRepo(remoteURL: "https://github.com/NE1NN/canopy")!

    @Test func readsPullRequestsWithOneGraphQLCall() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(
            in: dir,
            """
            printf '%s\\n' "$@" > "\(dir.sub("args"))"
            echo '{"data": {"repository": {"b0": {"nodes": [{"number": 3, "title": "Fix it", "url": "https://x/3", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28T01:00:00Z", "isCrossRepository": false}]}}}}'
            """)

        let lookup = await gh.pullRequests(repo: repo, branches: ["fix/it"])

        #expect(
            lookup
                == .found([
                    "fix/it": PullRequest(
                        number: 3, title: "Fix it", url: "https://x/3", state: .open, updatedAt: "2026-09-28T01:00:00Z")
                ]))
        let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8).split(separator: "\n")
        #expect(Array(args.prefix(3)) == ["api", "graphql", "-f"])
        #expect(args.dropFirst(3).first?.hasPrefix("query=query { repository(") == true)
    }

    @Test func reportsMissingGH() async throws {
        let dir = try TempDir()
        let gh = GitHubCLI(environment: ["PATH": dir.path, "HOME": dir.path], fallbackFolders: [])

        #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .ghMissing)
    }

    @Test func findsGHInHomebrewWhenPATHLacksIt() async throws {
        let dir = try TempDir()
        _ = try Fixture.gh(in: dir, #"echo '{"data": {"repository": {}}}'"#)
        let gh = GitHubCLI(
            environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path], fallbackFolders: [dir.sub("gh-bin")])

        #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .found([:]))
    }

    @Test func reportsLoggedOutGH() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(
            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")

        #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .notLoggedIn)
    }

    @Test func treatsARejectedTokenAsLoggedOut() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(in: dir, "echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1")

        #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .notLoggedIn)
    }

    @Test func passesOnOtherFailuresWithGHsMessage() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(
            in: dir,
            "echo 'gh: Could not resolve to a Repository with the name NE1NN/canopy.' >&2; exit 1")

        #expect(
            await gh.pullRequests(repo: repo, branches: ["a"])
                == .failed("Could not resolve to a Repository with the name NE1NN/canopy."))
    }

    @Test func stopsAHungGH() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(in: dir, "sleep 30", timeout: .milliseconds(300))

        #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .failed("gh did not answer in time."))
    }

    @Test func stopsAHungGHOnTimeWhenDispatchHasNoThreadsLeft() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(in: dir, "sleep 30", timeout: .milliseconds(300))
        let clock = ContinuousClock()

        let (lookup, elapsed) = try await withEveryDispatchThreadBusy {
            let start = clock.now
            let lookup = await gh.pullRequests(repo: repo, branches: ["a"])
            return (lookup, clock.now - start)
        }

        #expect(lookup == .failed("gh did not answer in time."))
        #expect(elapsed < .seconds(5))
    }

    @Test func followsAnSSHAliasWhenDispatchHasNoThreadsLeft() async throws {
        let dir = try TempDir()
        try "Host github-work\n  HostName github.com\n".write(
            toFile: dir.sub("ssh_config"), atomically: true, encoding: .utf8)
        let gh = GitHubCLI(sshConfigFile: dir.sub("ssh_config"))
        let clock = ContinuousClock()

        let (found, elapsed) = try await withEveryDispatchThreadBusy {
            let start = clock.now
            let found = await gh.repo(forRemote: "git@github-work:NE1NN/canopy.git")
            return (found, clock.now - start)
        }

        #expect(found == repo)
        #expect(elapsed < .seconds(5))
    }

    @Test func looksUpOnePullRequest() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(
            in: dir,
            """
            printf '%s\\n' "$@" > "\(dir.sub("args"))"
            echo '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": {"number": 7, "title": "t", "url": "u", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28", "headRefName": "feat/x", "headRefOid": "abc", "headRef": {"name": "feat/x"}, "baseRefName": "main", "isCrossRepository": false, "maintainerCanModify": false, "headRepository": {"name": "canopy"}, "headRepositoryOwner": {"login": "NE1NN"}}}}}'
            """)

        let head = try await gh.pullRequest(repo: repo, number: 7).get()

        #expect(head?.branch == "feat/x")
        let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8).split(separator: "\n")
        #expect(Array(args.prefix(3)) == ["api", "graphql", "-f"])
        #expect(args.dropFirst(3).first?.contains("pullRequest(number: 7)") == true)
    }

    @Test func aPullRequestGitHubDoesNotHaveIsNone() async throws {
        let dir = try TempDir()
        let gh = try Fixture.gh(
            in: dir,
            """
            echo '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": null}}}'
            echo 'gh: Could not resolve to a PullRequest with the number of 7.' >&2
            exit 1
            """)

        #expect(try await gh.pullRequest(repo: repo, number: 7).get() == nil)
    }

    @Test func aPullRequestLookupSaysWhyGHCannotAnswer() async throws {
        let dir = try TempDir()
        let loggedOut = try Fixture.gh(
            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
        let missing = GitHubCLI(environment: ["PATH": dir.path, "HOME": dir.path], fallbackFolders: [])

        #expect(await loggedOut.pullRequest(repo: repo, number: 7) == .failure(.notLoggedIn))
        #expect(await missing.pullRequest(repo: repo, number: 7) == .failure(.ghMissing))
    }
}
