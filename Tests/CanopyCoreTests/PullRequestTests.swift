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

    @Test func readsTheHostAnSSHAliasConnectsTo() throws {
        let dir = try TempDir()
        try "Host github-work\n  HostName github.com\n".write(
            toFile: dir.sub("ssh_config"), atomically: true, encoding: .utf8)

        #expect(SSHConfig.hostName(for: "github-work", configFile: dir.sub("ssh_config")) == "github.com")
        #expect(SSHConfig.hostName(for: "elsewhere", configFile: dir.sub("ssh_config")) == "elsewhere")
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
}
