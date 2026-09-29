import Foundation
import Testing

@testable import CanopyCore

struct PullRequestTests {
    let repo = GitHubRepo(remoteURL: "git@github.com:NE1NN/canopy.git")!

    @Test func readsGitHubRemotes() {
        for url in [
            "git@github.com:NE1NN/canopy.git", "https://github.com/NE1NN/canopy",
            "https://github.com/NE1NN/canopy.git/",
            "ssh://git@github.com/NE1NN/canopy.git", "https://someone@github.com/NE1NN/canopy.git",
            "ssh://git@github.com:22/NE1NN/canopy.git", "ssh://git@ssh.github.com:443/NE1NN/canopy.git",
            "HTTPS://GitHub.com/NE1NN/canopy.git",
        ] {
            #expect(GitHubRepo(remoteURL: url)?.nameWithOwner == "NE1NN/canopy", "\(url)")
        }
        #expect(GitHubRepo(remoteURL: "git@gitlab.com:a/b.git") == nil)
        #expect(GitHubRepo(remoteURL: "/local/path") == nil)
        #expect(GitHubRepo(remoteURL: "./relative:path/x") == nil)
        #expect(GitHubRepo(remoteURL: "https://github.com/only-owner") == nil)
    }

    @Test func followsSSHHostAliasesToGitHub() {
        let aliases = ["github-work": "github.com", "gitlab-alias": "gitlab.com"]
        func resolve(_ host: String) -> String? { aliases[host] }

        #expect(
            GitHubRepo(remoteURL: "git@github-work:NE1NN/canopy.git", sshHostName: resolve)?.nameWithOwner
                == "NE1NN/canopy")
        #expect(
            GitHubRepo(remoteURL: "ssh://git@github-work/NE1NN/canopy.git", sshHostName: resolve)?.nameWithOwner
                == "NE1NN/canopy")
        #expect(GitHubRepo(remoteURL: "git@gitlab-alias:a/b.git", sshHostName: resolve) == nil)
        #expect(GitHubRepo(remoteURL: "git@github-work:NE1NN/canopy.git") == nil)
        // Only SSH goes through ssh's config. An https host is what it says.
        #expect(GitHubRepo(remoteURL: "https://github-work/NE1NN/canopy.git", sshHostName: resolve) == nil)
    }

    @Test func readsTheHostAnSSHAliasConnectsTo() async throws {
        let dir = try TempDir()
        let config = dir.sub("ssh_config")
        try "Host github-work\n  HostName github.com\n".write(toFile: config, atomically: true, encoding: .utf8)

        #expect(try await offPool { SSHConfig.hostName(for: "github-work", configFile: config) } == "github.com")
        #expect(try await offPool { SSHConfig.hostName(for: "elsewhere", configFile: config) } == "elsewhere")
    }

    @Test func queryAliasesEachBranchAndEscapesNames() {
        let query = PRQuery.build(repo: repo, branches: ["feat/x", #"weird"name"#])

        #expect(query.contains(#"b0: pullRequests(headRefName: "feat/x""#))
        #expect(query.contains(#"b1: pullRequests(headRefName: "weird\"name""#))
        #expect(query.contains(#"repository(owner: "NE1NN", name: "canopy")"#))
        // Forks can fill a busy branch name's first page before the repo's own PR shows up.
        #expect(query.contains("first: 100"))
        #expect(query.contains("isCrossRepository"))
    }

    @Test func picksOpenFirstThenLatestAndIgnoresForks() throws {
        func node(_ number: Int, _ state: String, draft: Bool = false, updated: String, fork: Bool = false)
            -> String
        {
            #"{"number": \#(number), "title": "t\#(number)", "url": "u\#(number)", "state": "\#(state)", "isDraft": \#(draft), "updatedAt": "\#(updated)", "isCrossRepository": \#(fork)}"#
        }
        let json = """
            {"data": {"repository": {
              "b0": {"nodes": [\(node(9, "CLOSED", updated: "2026-09-27")), \(node(8, "OPEN", draft: true, updated: "2026-09-01"))]},
              "b1": {"nodes": [\(node(7, "MERGED", updated: "2026-09-02")), \(node(6, "CLOSED", updated: "2026-09-20"))]},
              "b2": {"nodes": [\(node(5, "OPEN", updated: "2026-09-27", fork: true))]},
              "b3": {"nodes": [\(node(4, "OPEN", updated: "2026-09-27", fork: true)), \(node(3, "CLOSED", updated: "2026-09-01"))]}
            }}}
            """

        let found = try PRQuery.parse(Data(json.utf8), branches: ["a", "b", "c", "d"])

        #expect(found["a"]?.number == 8)
        #expect(found["a"]?.state == .draft)
        #expect(found["b"]?.number == 6)
        #expect(found["b"]?.state == .closed)
        #expect(found["c"] == nil)
        #expect(found["d"]?.number == 3)
    }

    @Test func asksForABoundBranchByItsNumber() throws {
        let query = PRQuery.build(repo: repo, branches: ["feat/a", "someone/feat"], numbers: ["someone/feat": 7])

        #expect(query.contains(#"b0: pullRequests(headRefName: "feat/a""#))
        #expect(query.contains("b1: pullRequest(number: 7) { number title url state isDraft updatedAt"))
        #expect(!query.contains(#"headRefName: "someone/feat""#))
    }

    @Test func aBoundBranchGetsItsPullRequestEvenFromAFork() throws {
        let json = """
            {"data": {"repository": {
              "b0": {"nodes": []},
              "b1": {"number": 7, "title": "t7", "url": "u7", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-27", "isCrossRepository": true},
              "b2": null
            }}}
            """

        let found = try PRQuery.parse(Data(json.utf8), branches: ["feat/a", "someone/feat", "gone"])

        #expect(found.keys.sorted() == ["someone/feat"])
        #expect(found["someone/feat"]?.number == 7)
    }

    @Test func comparesReposWithoutCase() {
        #expect(GitHubRepo(owner: "NE1NN", name: "Canopy").matches(repo))
        #expect(!GitHubRepo(owner: "NE1NN", name: "canopy-2").matches(repo))
    }

    @Test func reachesAForkTheWayOriginIsReached() {
        let fork = GitHubRepo(owner: "someone", name: "canopy-fork")
        let cases = [
            "https://github.com/NE1NN/canopy.git": "https://github.com/someone/canopy-fork.git",
            "https://github.com/NE1NN/canopy": "https://github.com/someone/canopy-fork",
            "https://token@github.com/NE1NN/canopy.git/": "https://token@github.com/someone/canopy-fork.git",
            "git@github.com:NE1NN/canopy.git": "git@github.com:someone/canopy-fork.git",
            "git@github-work:NE1NN/canopy": "git@github-work:someone/canopy-fork",
            "ssh://git@ssh.github.com:443/NE1NN/canopy.git": "ssh://git@ssh.github.com:443/someone/canopy-fork.git",
        ]
        for (origin, expected) in cases {
            #expect(fork.url(replacingRepoIn: origin) == expected, "\(origin)")
        }
        #expect(fork.url(replacingRepoIn: "/local/path") == nil)
    }

    @Test func readsAPullRequestsHead() throws {
        let json = """
            {"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": {
              "number": 7, "title": "Split checkout", "url": "https://github.com/NE1NN/canopy/pull/7", "state": "OPEN",
              "isDraft": true, "updatedAt": "2026-09-28T01:00:00Z", "headRefName": "feat/split",
              "headRefOid": "abc123", "headRef": {"name": "feat/split"}, "baseRefName": "main",
              "isCrossRepository": true, "maintainerCanModify": true,
              "headRepository": {"name": "canopy-fork"}, "headRepositoryOwner": {"login": "someone"},
              "author": {"login": "someone"}}}}}
            """

        let head = try #require(try PRHeadQuery.parse(Data(json.utf8)))

        #expect(
            head.pullRequest
                == PullRequest(
                    number: 7, title: "Split checkout", url: "https://github.com/NE1NN/canopy/pull/7", state: .draft,
                    updatedAt: "2026-09-28T01:00:00Z"))
        #expect(head.branch == "feat/split")
        #expect(head.commit == "abc123")
        #expect(head.branchExists)
        #expect(head.isCrossRepository)
        #expect(head.headRepo == GitHubRepo(owner: "someone", name: "canopy-fork"))
        #expect(head.maintainerCanModify)
        #expect(head.defaultBranch == "main")
        #expect(head.author == "someone")
    }

    @Test func readsAMergedHeadWhoseBranchAndForkAreGone() throws {
        let json = """
            {"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": {
              "number": 7, "title": "t", "url": "u", "state": "MERGED", "isDraft": false, "updatedAt": "2026-09-28",
              "headRefName": "feat/split", "headRefOid": "abc123", "headRef": null, "baseRefName": "main",
              "isCrossRepository": true, "maintainerCanModify": false, "headRepository": null,
              "headRepositoryOwner": null}}}}
            """

        let head = try #require(try PRHeadQuery.parse(Data(json.utf8)))

        #expect(head.pullRequest.state == .merged)
        #expect(!head.branchExists)
        #expect(head.headRepo == nil)
    }

    @Test func aMissingPullRequestReadsAsNone() throws {
        let json = #"{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": null}}}"#

        #expect(try PRHeadQuery.parse(Data(json.utf8)) == nil)
    }

    @Test func headQueryAsksForOnePullRequest() {
        let query = PRHeadQuery.build(repo: repo, number: 7)

        #expect(query.contains(#"repository(owner: "NE1NN", name: "canopy")"#))
        #expect(query.contains("pullRequest(number: 7)"))
        for field in ["headRefOid", "headRef { name }", "maintainerCanModify", "headRepositoryOwner { login }"] {
            #expect(query.contains(field), "\(field)")
        }
    }

    @Test func readsAListOfPullRequests() throws {
        let json = """
            {"data": {"repository": {"pullRequests": {"nodes": [
              {"number": 9, "title": "From a fork", "url": "https://github.com/NE1NN/canopy/pull/9", "state": "OPEN",
               "isDraft": true, "updatedAt": "2026-09-28T02:00:00Z", "headRefName": "feat/x",
               "isCrossRepository": true, "author": {"login": "someone"}},
              {"number": 4, "title": "Old", "url": "https://github.com/NE1NN/canopy/pull/4", "state": "MERGED",
               "isDraft": false, "updatedAt": "2026-09-27T02:00:00Z", "headRefName": "fix/y",
               "isCrossRepository": false, "author": null}
            ]}}}}
            """

        let listed = try PRListQuery.parse(Data(json.utf8))

        #expect(
            listed == [
                ListedPullRequest(
                    number: 9, title: "From a fork", url: "https://github.com/NE1NN/canopy/pull/9", state: .draft,
                    author: "someone", headBranch: "feat/x", isFork: true, updatedAt: "2026-09-28T02:00:00Z"),
                ListedPullRequest(
                    number: 4, title: "Old", url: "https://github.com/NE1NN/canopy/pull/4", state: .merged,
                    author: nil, headBranch: "fix/y", isFork: false, updatedAt: "2026-09-27T02:00:00Z"),
            ])
    }

    @Test func listQueryAsksForTheNewestPullRequests() {
        let open = PRListQuery.build(repo: repo, includeClosed: false)
        let all = PRListQuery.build(repo: repo, includeClosed: true)

        #expect(open.contains(#"repository(owner: "NE1NN", name: "canopy")"#))
        #expect(
            open.contains("pullRequests(states: [OPEN], first: 100, orderBy: {field: UPDATED_AT, direction: DESC})"))
        #expect(all.contains("pullRequests(states: [OPEN, CLOSED, MERGED], first: 100,"))
        for field in ["headRefName", "isCrossRepository", "author { login }"] {
            #expect(open.contains(field), "\(field)")
        }
    }

    @Test func aListedPullRequestNamesItsRowForAgents() throws {
        var listed = ListedPullRequest(
            number: 9, title: "t", url: "u", state: .open, author: nil, headBranch: "feat/x", isFork: true,
            updatedAt: "2026-09-28T02:00:00Z")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        #expect(
            String(decoding: try encoder.encode(listed), as: UTF8.self)
                == #"{"author":null,"fork":true,"headBranch":"feat\/x","number":9,"row":null,"state":"open","#
                + #""title":"t","updatedAt":"2026-09-28T02:00:00Z","url":"u"}"#)
        listed.row = BranchHolder(path: "/w/someone-feat-x", branch: "someone/feat/x", rowClass: .canopy)
        let json = String(decoding: try encoder.encode(listed), as: UTF8.self)
        #expect(json.contains(#""row":{"branch":"someone\/feat\/x","class":"canopy","path":"\/w\/someone-feat-x"}"#))
        #expect(try JSONDecoder().decode(ListedPullRequest.self, from: Data(json.utf8)) == listed)
    }

    @Test func aLookedUpPullRequestListsLikeTheRest() throws {
        let head = PullRequestHead(
            pullRequest: PullRequest(number: 7, title: "t", url: "u", state: .closed, updatedAt: "2026-09-28"),
            branch: "feat/split", commit: "abc", branchExists: true, isCrossRepository: false, headRepo: nil,
            maintainerCanModify: false, defaultBranch: "main", author: "me")

        #expect(
            ListedPullRequest(head)
                == ListedPullRequest(
                    number: 7, title: "t", url: "u", state: .closed, author: "me", headBranch: "feat/split",
                    isFork: false, updatedAt: "2026-09-28"))
    }
}
