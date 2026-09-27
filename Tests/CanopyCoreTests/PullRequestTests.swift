import Foundation
import Testing

@testable import CanopyCore

struct PullRequestTests {
    let repo = GitHubRepo(remoteURL: "git@github.com:NE1NN/canopy.git")!

    @Test func readsGitHubRemotes() {
        for url in [
            "git@github.com:NE1NN/canopy.git", "https://github.com/NE1NN/canopy",
            "https://github.com/NE1NN/canopy.git/",
            "ssh://git@github.com/NE1NN/canopy.git",
        ] {
            #expect(GitHubRepo(remoteURL: url)?.nameWithOwner == "NE1NN/canopy")
        }
        #expect(GitHubRepo(remoteURL: "git@gitlab.com:a/b.git") == nil)
        #expect(GitHubRepo(remoteURL: "/local/path") == nil)
    }

    @Test func queryAliasesEachBranchAndEscapesNames() {
        let query = PRQuery.build(repo: repo, branches: ["feat/x", #"weird"name"#])

        #expect(query.contains(#"b0: pullRequests(headRefName: "feat/x""#))
        #expect(query.contains(#"b1: pullRequests(headRefName: "weird\"name""#))
        #expect(query.contains(#"repository(owner: "NE1NN", name: "canopy")"#))
    }

    @Test func picksOpenFirstThenLatestAndIgnoresForks() throws {
        func node(_ number: Int, _ state: String, draft: Bool = false, updated: String, from owner: String = "NE1NN")
            -> String
        {
            #"{"number": \#(number), "title": "t\#(number)", "url": "u\#(number)", "state": "\#(state)", "isDraft": \#(draft), "updatedAt": "\#(updated)", "headRepository": {"nameWithOwner": "\#(owner)/canopy"}}"#
        }
        let json = """
            {"data": {"repository": {
              "b0": {"nodes": [\(node(9, "CLOSED", updated: "2026-09-27")), \(node(8, "OPEN", draft: true, updated: "2026-09-01"))]},
              "b1": {"nodes": [\(node(7, "MERGED", updated: "2026-09-02")), \(node(6, "CLOSED", updated: "2026-09-20"))]},
              "b2": {"nodes": [\(node(5, "OPEN", updated: "2026-09-27", from: "someone"))]}
            }}}
            """

        let found = try PRQuery.parse(Data(json.utf8), repo: repo, branches: ["a", "b", "c"])

        #expect(found["a"]?.number == 8)
        #expect(found["a"]?.state == .draft)
        #expect(found["b"]?.number == 6)
        #expect(found["b"]?.state == .closed)
        #expect(found["c"] == nil)
    }
}
