# Canopy New Row Sheet as a PR and Branch Picker (PR B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The New Row sheet becomes one search list of open PRs and branches, and `canopy pr list` and `canopy branch list` give agents the same lists.

**Architecture:** CanopyCore gains a PR list query through gh, `Workspace.listPullRequests` and `Workspace.listBranches`, which say which row has each item, and a main-actor `NewRowPicker` that turns typed text and those lists into the sheet's items, selection, and actions.
The control API and CLI expose the two lists, and `canopy pr` becomes `canopy pr show` by default.
The sheet in CanopyApp only draws the picker and runs the action it picks through the same `Workspace` calls the CLI makes.

**Tech Stack:** Swift 6.2 in Swift 6 language mode, SwiftUI, Swift Testing, git, gh, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md` ("Listing PRs and branches", "The New Row sheet", "Control API", and "Delivery"), and PR A's plan `docs/superpowers/plans/2026-09-28-canopy-pull-branches.md`.

## Global Constraints

- Every action in the sheet maps to exactly one command: a PR is `canopy row new --pr 123`, a branch is `canopy row new feat/x --existing`, the new branch line is `canopy row new feat/x --from <base>`, an item that has a row is `canopy row select feat/x`, and one in another tool's worktree is `canopy row adopt <path>`.
- The two lists are `canopy pr list --json` and `canopy branch list --json`, backed by the `pr.list` and `branch.list` control methods, which call the same `Workspace` methods the sheet calls.
- `canopy pr [row]` keeps working as the default subcommand, `canopy pr show [row]`.
- `row new` with no argument stays an error.
- The field's placeholder is "Branch, PR number, or new branch name".
- PRs show the sidebar's PR glyph in its state color, then `#123` with `Text(verbatim:)`, then the title, and a second line `head · author · 2h ago` with `draft` and `fork` tags, or "In row".
- Branches show their name and commit age, with `origin`, `local`, `local, 3 behind`, or `local ≠ origin`, plus "In row" or "Other worktree".
- The last line is "New branch ‘<typed text>’ from <base>", shown when the text is not an exact match.
- The list shows local refs at once, then refreshes after a background `git fetch --prune origin` through the fetch freshness guard, so typing never fetches.
- While gh is unavailable, the PR section shows the sidebar's warning.
- Arrows move, Return runs the selected item, and Esc cancels.
  A selected item that has a row shows "Open Row" in place of Create Row, and one in another tool's worktree offers Adopt.
- The Group picker stays, and every row the sheet creates goes into the picked group.
- Tests never reach the network: local bare remotes with `refs/pull/<n>/head`, and a stand-in gh.
  A stand-in that waits gives up after a time limit.
- Swift 6 strict concurrency with no warnings, `swift format lint --strict` clean.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. Typing `#12`, then `#123` before the first lookup answers: the older answer never replaces the newer one, and a lookup a later keystroke made unnecessary never starts.
   `anOlderLookupNeverReplacesANewerOne` and `aLookupAKeystrokeMadeUnnecessaryNeverStarts` in Task 5 pin it.
2. A name typed in another case than an existing branch, such as `Feat/X` for `feat/x`: there is no "New branch" line, since `row new` would use the existing branch anyway.
   `aNameInAnotherCaseIsNotNew` in Task 5.
3. No network, or a fetch that times out: the list shows local refs at once and says the fetch failed, and nothing in the sheet waits on the network before showing something.
   `aFailedFetchStillListsLocalBranches` in Task 3, and `showsLocalBranchesBeforeTheFetchFinishes` and `aFailedFetchSaysSoAndKeepsLocalBranches` in Task 5.
4. A fork PR checked out as `someone/feat-x`, or any PR checked out under another name: it shows "In row" through the saved PR binding, so picking it opens the row instead of failing.
   `saysWhichRowHasEachPullRequest` and `aForkPullRequestIsNotHeldByASameNamedBranch` in Task 2.
5. A repo whose origin is not on GitHub, or that has no origin: the sheet still lists local branches and the new branch line, and `canopy pr list` fails with `not_github`.
   `aRepoNotOnGitHubHasNoPullRequests` in Task 2, `aRepoWithoutOriginListsLocalBranches` in Task 3, and `aRepoNotOnGitHubHidesThePullRequests` in Task 5.

## File Structure

- Create `Sources/CanopyCore/PullRequests/PullRequestList.swift`: `ListedPullRequest`, `BranchHolder`, and the GraphQL query that lists a repo's PRs.
- Modify `Sources/CanopyCore/PullRequests/GitHubCLI.swift`: `pullRequestList(repo:includeClosed:)`.
- Modify `Sources/CanopyCore/PullRequests/PullRequestHead.swift`: the PR's author.
- Create `Sources/CanopyCore/Rows/SearchText.swift`: how typed text matches an item.
- Create `Sources/CanopyCore/Workspace/Workspace+Listing.swift`: `listPullRequests` and `listBranches`, and which row holds each item.
- Create `Sources/CanopyCore/Rows/ListedBranch.swift`: `ListedBranch`, `BranchLocation`, and `BranchListing`.
- Modify `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`: `fetchUnlessFresh` becomes callable from the listing.
- Modify `Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`: gh failures map to errors in one place.
- Create `Sources/CanopyCore/Support/ShortAge.swift`: "2h ago", for the sheet and the CLI tables.
- Create `Sources/CanopyCore/Rows/BranchName.swift`: git's branch name rules, without running git on every keystroke.
- Create `Sources/CanopyCore/Rows/NewRowPicker.swift`: the sheet's state, items, selection, and actions.
- Modify `Sources/CanopyCore/Control/ControlMethods.swift` and `WorkspaceControlHandler.swift`: `pr.list` and `branch.list`.
- Modify `Sources/CanopyCLI/PRCommand.swift`, create `Sources/CanopyCLI/BranchCommand.swift`, and modify `CanopyCLI.swift`, `Client.swift`, and `AgentGuide.swift`.
- Create `Sources/CanopyApp/Sidebar/NewRowSheet.swift`, and move the old sheet out of `RowActionViews.swift`.
- Modify `Sources/CanopyApp/AppModel.swift` and `Sidebar/SidebarView.swift`: the sheet's lists, and running a picked action.
- Modify `scripts/ui-fixture.sh`, `scripts/ui.swift`, and `scripts/e2e.sh`.
- Modify `docs/superpowers/specs/2026-09-27-canopy-design.md` and `docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md`.
- Tests: `PullRequestTests`, `GitHubCLITests`, `SearchTextTests`, `PullRequestListTests`, `BranchListTests`, `ControlProtocolTests`, `ControlServerTests`, `ShortAgeTests`, `BranchNameTests`, `NewRowPickerTests`, and `Support/LocalGitHub.swift` and `Support/Fixtures.swift`.

---

## Task 1: A repo's pull requests from gh

**Files:**
- Create: `Sources/CanopyCore/PullRequests/PullRequestList.swift`
- Modify: `Sources/CanopyCore/PullRequests/GitHubCLI.swift`, `Sources/CanopyCore/PullRequests/PullRequestHead.swift`
- Test: `Tests/CanopyCoreTests/PullRequestTests.swift`, `Tests/CanopyCoreTests/GitHubCLITests.swift`

**Interfaces:**
- Produces: `BranchHolder` (`path`, `branch`, `rowClass` coded as `class`, `isRow`, and `init(_ row: Row)`), the row or worktree that has a branch checked out.
- Produces: `ListedPullRequest` (`number`, `title`, `url`, `state`, `author: String?`, `headBranch`, `isFork` coded as `fork`, `updatedAt`, `row: BranchHolder?`), and `ListedPullRequest(_ head: PullRequestHead)`.
  It writes `"author": null` and `"row": null` rather than leaving the keys out.
- Produces: `PRListQuery.build(repo:includeClosed:)` and `parse(_:)`, and `GitHubCLI.pullRequestList(repo:includeClosed:) async -> Result<[ListedPullRequest], GHFailure>`: the 100 most recently updated PRs, open ones only unless `includeClosed`.
- Produces: `PullRequestHead.author: String?`.

- [ ] **Step 1: Write the failing tests**

`readsAListOfPullRequests` decodes GitHub's reply, including a PR whose author's account is gone (`author` is null) and a fork's.
`listQueryAsksForTheNewestPullRequests` checks the states and order the query asks for, and `aListedPullRequestNamesItsRowForAgents` pins the JSON agents read.
`listsPullRequestsWithOneCall` and `aPullRequestListSaysWhyGHCannotAnswer` cover the gh call.

`Tests/CanopyCoreTests/GitHubCLITests.swift`:

```diff
@@ -221,4 +221,37 @@ struct GitHubCLITests {
         #expect(await loggedOut.pullRequest(repo: repo, number: 7) == .failure(.notLoggedIn))
         #expect(await missing.pullRequest(repo: repo, number: 7) == .failure(.ghMissing))
     }
+
+    @Test func listsPullRequestsWithOneCall() async throws {
+        let dir = try TempDir()
+        let gh = try Fixture.gh(
+            in: dir,
+            """
+            printf '%s\\n' "$@" > "\(dir.sub("args"))"
+            echo '{"data": {"repository": {"pullRequests": {"nodes": [{"number": 3, "title": "Fix it", "url": "https://x/3", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28T01:00:00Z", "headRefName": "fix/it", "isCrossRepository": false, "author": {"login": "me"}}]}}}}'
+            """)
+
+        let listed = try await gh.pullRequestList(repo: repo, includeClosed: true).get()
+
+        #expect(listed.map(\.number) == [3])
+        #expect(listed.first?.author == "me")
+        let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8).split(separator: "\n")
+        #expect(Array(args.prefix(3)) == ["api", "graphql", "-f"])
+        #expect(args.dropFirst(3).first?.contains("states: [OPEN, CLOSED, MERGED]") == true)
+    }
+
+    @Test func aPullRequestListSaysWhyGHCannotAnswer() async throws {
+        let dir = try TempDir()
+        let loggedOut = try Fixture.gh(
+            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
+        let missing = GitHubCLI(environment: ["PATH": dir.path, "HOME": dir.path], fallbackFolders: [])
+        let garbledDir = try TempDir()
+        let garbled = try Fixture.gh(in: garbledDir, "echo 'not json'")
+
+        #expect(await loggedOut.pullRequestList(repo: repo, includeClosed: false) == .failure(.notLoggedIn))
+        #expect(await missing.pullRequestList(repo: repo, includeClosed: false) == .failure(.ghMissing))
+        #expect(
+            await garbled.pullRequestList(repo: repo, includeClosed: false)
+                == .failure(.failed("gh returned a reply Canopy could not read.")))
+    }
 }
```

`Tests/CanopyCoreTests/PullRequestTests.swift`:

```diff
@@ -134,7 +134,8 @@ struct PullRequestTests {
               "isDraft": true, "updatedAt": "2026-09-28T01:00:00Z", "headRefName": "feat/split",
               "headRefOid": "abc123", "headRef": {"name": "feat/split"}, "baseRefName": "main",
               "isCrossRepository": true, "maintainerCanModify": true,
-              "headRepository": {"name": "canopy-fork"}, "headRepositoryOwner": {"login": "someone"}}}}}
+              "headRepository": {"name": "canopy-fork"}, "headRepositoryOwner": {"login": "someone"},
+              "author": {"login": "someone"}}}}}
             """
 
         let head = try #require(try PRHeadQuery.parse(Data(json.utf8)))
@@ -151,6 +152,7 @@ struct PullRequestTests {
         #expect(head.headRepo == GitHubRepo(owner: "someone", name: "canopy-fork"))
         #expect(head.maintainerCanModify)
         #expect(head.defaultBranch == "main")
+        #expect(head.author == "someone")
     }
 
     @Test func readsAMergedHeadWhoseBranchAndForkAreGone() throws {
@@ -184,4 +186,72 @@ struct PullRequestTests {
             #expect(query.contains(field), "\(field)")
         }
     }
+
+    @Test func readsAListOfPullRequests() throws {
+        let json = """
+            {"data": {"repository": {"pullRequests": {"nodes": [
+              {"number": 9, "title": "From a fork", "url": "https://github.com/NE1NN/canopy/pull/9", "state": "OPEN",
+               "isDraft": true, "updatedAt": "2026-09-28T02:00:00Z", "headRefName": "feat/x",
+               "isCrossRepository": true, "author": {"login": "someone"}},
+              {"number": 4, "title": "Old", "url": "https://github.com/NE1NN/canopy/pull/4", "state": "MERGED",
+               "isDraft": false, "updatedAt": "2026-09-27T02:00:00Z", "headRefName": "fix/y",
+               "isCrossRepository": false, "author": null}
+            ]}}}}
+            """
+
+        let listed = try PRListQuery.parse(Data(json.utf8))
+
+        #expect(
+            listed == [
+                ListedPullRequest(
+                    number: 9, title: "From a fork", url: "https://github.com/NE1NN/canopy/pull/9", state: .draft,
+                    author: "someone", headBranch: "feat/x", isFork: true, updatedAt: "2026-09-28T02:00:00Z"),
+                ListedPullRequest(
+                    number: 4, title: "Old", url: "https://github.com/NE1NN/canopy/pull/4", state: .merged,
+                    author: nil, headBranch: "fix/y", isFork: false, updatedAt: "2026-09-27T02:00:00Z"),
+            ])
+    }
+
+    @Test func listQueryAsksForTheNewestPullRequests() {
+        let open = PRListQuery.build(repo: repo, includeClosed: false)
+        let all = PRListQuery.build(repo: repo, includeClosed: true)
+
+        #expect(open.contains(#"repository(owner: "NE1NN", name: "canopy")"#))
+        #expect(
+            open.contains("pullRequests(states: [OPEN], first: 100, orderBy: {field: UPDATED_AT, direction: DESC})"))
+        #expect(all.contains("pullRequests(states: [OPEN, CLOSED, MERGED], first: 100,"))
+        for field in ["headRefName", "isCrossRepository", "author { login }"] {
+            #expect(open.contains(field), "\(field)")
+        }
+    }
+
+    @Test func aListedPullRequestNamesItsRowForAgents() throws {
+        var listed = ListedPullRequest(
+            number: 9, title: "t", url: "u", state: .open, author: nil, headBranch: "feat/x", isFork: true,
+            updatedAt: "2026-09-28T02:00:00Z")
+        let encoder = JSONEncoder()
+        encoder.outputFormatting = .sortedKeys
+
+        #expect(
+            String(decoding: try encoder.encode(listed), as: UTF8.self)
+                == #"{"author":null,"fork":true,"headBranch":"feat\/x","number":9,"row":null,"state":"open","#
+                + #""title":"t","updatedAt":"2026-09-28T02:00:00Z","url":"u"}"#)
+        listed.row = BranchHolder(path: "/w/someone-feat-x", branch: "someone/feat/x", rowClass: .canopy)
+        let json = String(decoding: try encoder.encode(listed), as: UTF8.self)
+        #expect(json.contains(#""row":{"branch":"someone\/feat\/x","class":"canopy","path":"\/w\/someone-feat-x"}"#))
+        #expect(try JSONDecoder().decode(ListedPullRequest.self, from: Data(json.utf8)) == listed)
+    }
+
+    @Test func aLookedUpPullRequestListsLikeTheRest() throws {
+        let head = PullRequestHead(
+            pullRequest: PullRequest(number: 7, title: "t", url: "u", state: .closed, updatedAt: "2026-09-28"),
+            branch: "feat/split", commit: "abc", branchExists: true, isCrossRepository: false, headRepo: nil,
+            maintainerCanModify: false, defaultBranch: "main", author: "me")
+
+        #expect(
+            ListedPullRequest(head)
+                == ListedPullRequest(
+                    number: 7, title: "t", url: "u", state: .closed, author: "me", headBranch: "feat/split",
+                    isFork: false, updatedAt: "2026-09-28"))
+    }
 }
```


- [ ] **Step 2: Run the tests and see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: build errors for `ListedPullRequest`, `PRListQuery`, and `author`.

- [ ] **Step 3: Write the code**

`Sources/CanopyCore/PullRequests/GitHubCLI.swift`:

```diff
@@ -73,6 +73,17 @@ public struct GitHubCLI: Sendable {
         }
     }
 
+    /// The repo's 100 most recently updated pull requests, only the open ones unless `includeClosed`.
+    public func pullRequestList(repo: GitHubRepo, includeClosed: Bool) async -> Result<[ListedPullRequest], GHFailure> {
+        let query = PRListQuery.build(repo: repo, includeClosed: includeClosed)
+        switch await run(["api", "graphql", "-f", "query=\(query)"], timeout: timeout) {
+        case .failure(let failure): return .failure(failure)
+        case .success(let reply):
+            guard let listed = try? PRListQuery.parse(reply) else { return .failure(.failed(Self.unreadable)) }
+            return .success(listed)
+        }
+    }
+
     /// Clones with `gh repo clone`, which uses the user's login and preferred git protocol, into `folder`, which must
     /// not exist yet. git reports progress to stderr, which `handle` reads. Nil when it cloned.
     public func clone(_ repo: String, into folder: String, handle: SubprocessHandle) async -> GHFailure? {
```

`Sources/CanopyCore/PullRequests/PullRequestHead.swift`:

```diff
@@ -16,6 +16,8 @@ public struct PullRequestHead: Sendable, Equatable {
     public var maintainerCanModify: Bool
     /// The base repo's default branch.
     public var defaultBranch: String?
+    /// Nil once GitHub no longer has the author's account.
+    public var author: String? = nil
 }
 
 /// One GraphQL request for one pull request and its repo's default branch.
@@ -24,7 +26,7 @@ public enum PRHeadQuery {
         "query { repository(owner: \(PRQuery.literal(repo.owner)), name: \(PRQuery.literal(repo.name))) { "
             + "defaultBranchRef { name } pullRequest(number: \(number)) { number title url state isDraft updatedAt "
             + "headRefName headRefOid headRef { name } baseRefName isCrossRepository maintainerCanModify "
-            + "headRepository { name } headRepositoryOwner { login } } } }"
+            + "headRepository { name } headRepositoryOwner { login } author { login } } } }"
     }
 
     /// Nil when the repo has no such pull request.
@@ -45,6 +47,7 @@ public enum PRHeadQuery {
             var maintainerCanModify: Bool
             var headRepository: Name?
             var headRepositoryOwner: Login?
+            var author: Login?
         }
         struct Repository: Decodable {
             var defaultBranchRef: Name?
@@ -66,6 +69,7 @@ public enum PRHeadQuery {
                 state: PRState(gitHub: node.state, isDraft: node.isDraft), updatedAt: node.updatedAt),
             branch: node.headRefName, commit: node.headRefOid, branchExists: node.headRef != nil,
             isCrossRepository: node.isCrossRepository, headRepo: headRepo,
-            maintainerCanModify: node.maintainerCanModify, defaultBranch: repository?.defaultBranchRef?.name)
+            maintainerCanModify: node.maintainerCanModify, defaultBranch: repository?.defaultBranchRef?.name,
+            author: node.author?.login)
     }
 }
```

`Sources/CanopyCore/PullRequests/PullRequestList.swift` (new):

```swift
import Foundation

/// The row or worktree that has a branch checked out.
public struct BranchHolder: Codable, Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var rowClass: RowClass

    public init(path: String, branch: String?, rowClass: RowClass) {
        self.path = path
        self.branch = branch
        self.rowClass = rowClass
    }

    public init(_ row: Row) {
        self.init(path: row.path, branch: row.branch, rowClass: row.rowClass)
    }

    /// A row Canopy shows, rather than another tool's worktree, which it can only adopt.
    public var isRow: Bool { rowClass != .external }

    enum CodingKeys: String, CodingKey {
        case path, branch
        case rowClass = "class"
    }
}

/// A pull request as `canopy pr list` and the New Row sheet show it.
public struct ListedPullRequest: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: PRState
    /// Nil once GitHub no longer has the author's account.
    public var author: String?
    /// The head branch's name, in the repo the PR comes from.
    public var headBranch: String
    public var isFork: Bool
    public var updatedAt: String
    /// The row or worktree that has the PR's branch checked out.
    public var row: BranchHolder?

    public var id: Int { number }

    public init(
        number: Int, title: String, url: String, state: PRState, author: String?, headBranch: String, isFork: Bool,
        updatedAt: String, row: BranchHolder? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.author = author
        self.headBranch = headBranch
        self.isFork = isFork
        self.updatedAt = updatedAt
        self.row = row
    }

    /// A PR looked up by its number.
    public init(_ head: PullRequestHead) {
        self.init(
            number: head.pullRequest.number, title: head.pullRequest.title, url: head.pullRequest.url,
            state: head.pullRequest.state, author: head.author, headBranch: head.branch,
            isFork: head.isCrossRepository, updatedAt: head.pullRequest.updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case number, title, url, state, author, headBranch, updatedAt, row
        case isFork = "fork"
    }

    /// Writes `"row": null` and `"author": null` rather than leaving the keys out, so agents can test for them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(state, forKey: .state)
        try container.encode(author, forKey: .author)
        try container.encode(headBranch, forKey: .headBranch)
        try container.encode(isFork, forKey: .isFork)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(row, forKey: .row)
    }
}

/// One GraphQL request for a repo's most recently updated pull requests.
public enum PRListQuery {
    public static func build(repo: GitHubRepo, includeClosed: Bool) -> String {
        let states = includeClosed ? "[OPEN, CLOSED, MERGED]" : "[OPEN]"
        return "query { repository(owner: \(PRQuery.literal(repo.owner)), name: \(PRQuery.literal(repo.name))) { "
            + "pullRequests(states: \(states), first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { "
            + "nodes { number title url state isDraft updatedAt headRefName isCrossRepository author { login } } } } }"
    }

    public static func parse(_ data: Data) throws -> [ListedPullRequest] {
        struct Login: Decodable { var login: String }
        struct Node: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var headRefName: String
            var isCrossRepository: Bool
            var author: Login?
        }
        struct Response: Decodable {
            struct Connection: Decodable { var nodes: [Node] }
            struct Repository: Decodable { var pullRequests: Connection }
            struct Payload: Decodable { var repository: Repository }
            var data: Payload
        }
        return try JSONDecoder().decode(Response.self, from: data).data.repository.pullRequests.nodes.map {
            ListedPullRequest(
                number: $0.number, title: $0.title, url: $0.url, state: PRState(gitHub: $0.state, isDraft: $0.isDraft),
                author: $0.author?.login, headBranch: $0.headRefName, isFork: $0.isCrossRepository,
                updatedAt: $0.updatedAt)
        }
    }
}
```


- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PullRequestTests|GitHubCLITests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: list a repo's pull requests through gh"
```

## Task 2: `Workspace.listPullRequests`, with the row that has each

**Files:**
- Create: `Sources/CanopyCore/Rows/SearchText.swift`, `Sources/CanopyCore/Workspace/Workspace+Listing.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`
- Test: `Tests/CanopyCoreTests/SearchTextTests.swift`, `Tests/CanopyCoreTests/PullRequestListTests.swift`, `Tests/CanopyCoreTests/Support/LocalGitHub.swift`

**Interfaces:**
- Consumes: `GitHubCLI.pullRequestList`, `GitHubCLI.pullRequest(repo:number:)`, `Workspace.gitHubRemote`, and `Workspace.boundPullRequests`.
- Produces: `SearchText(_ text: String?)` with `words`, `isEmpty`, and `matches(_ fields: [String]) -> Bool`: every word is in one of the fields, ignoring case.
- Produces: `ListedPullRequest.matches(_ search: SearchText)`, over its `#number`, title, head branch, and author.
- Produces: `WorkspaceError(_ failure: GHFailure)`, the sidebar's words for gh that is missing or logged out, which `createRow(repoPath:pullRequest:)` now uses too.
- Produces: `Workspace.listPullRequests(repoPath: String, query: String? = nil, includeClosed: Bool = false) async throws -> [ListedPullRequest]`.
  A query that is a PR number, `#number`, or PR URL looks that one PR up in any state, and a URL of another repo fails with `invalid_pr`.
- Produces: `Workspace.pullRequestHolders(repoPath:repo:) -> (ListedPullRequest) -> BranchHolder?`: the row on a branch bound to the PR, or for a PR from the repo itself, the row on its head branch.
  These are how the badges find a row's PR, so a row's badge and its "In row" agree.

The local GitHub gains a list of its PRs, most recently updated first, which `openPR` and `deletePR` rewrite, and `openPR` takes a title, author, draft flag, and update time.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PullRequestListTests.swift` (new):

```swift
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
```

`Tests/CanopyCoreTests/SearchTextTests.swift` (new):

```swift
import Testing

@testable import CanopyCore

struct SearchTextTests {
    @Test func everyWordMustAppearInSomeField() {
        let fields = ["#12", "Keep the page after logging in", "fix/login-redirect", "alice"]

        #expect(SearchText("login").matches(fields))
        #expect(SearchText("PAGE Alice").matches(fields))
        #expect(SearchText("  redirect   keep ").matches(fields))
        #expect(SearchText("#12").matches(fields))
        #expect(!SearchText("login bob").matches(fields))
    }

    @Test func noWordsMatchEverything() {
        #expect(SearchText("").matches([]))
        #expect(SearchText(" \t").matches(["x"]))
        #expect(SearchText(nil).isEmpty)
        #expect(!SearchText("x").isEmpty)
    }
}
```

`Tests/CanopyCoreTests/Support/LocalGitHub.swift`:

```diff
@@ -4,8 +4,8 @@ import Foundation
 
 /// A GitHub on this machine, so PR tests never reach the network. Repos are bare repos at
 /// `<dir>/remotes/<owner>/<name>.git`, and `git` reaches them at https://github.com/<owner>/<name>.git through a URL
-/// rewrite. `gh` answers a PR's lookup from what `openPR` wrote, and records every other query and answers it from
-/// `reply`.
+/// rewrite. `gh` answers a PR's lookup and the list of PRs from what `openPR` wrote, and records every other query and
+/// answers it from `reply`.
 struct LocalGitHub {
     let dir: TempDir
     let git: GitRunner
@@ -36,6 +36,8 @@ struct LocalGitHub {
                 echo "gh: Could not resolve to a PullRequest with the number of $number." >&2
                 exit 1
             fi
+            if [[ "$query" == *"pullRequests(states: [OPEN],"* ]]; then cat "\(dir.sub("gh-list-open"))"; exit 0; fi
+            if [[ "$query" == *"pullRequests(states:"* ]]; then cat "\(dir.sub("gh-list-all"))"; exit 0; fi
             printf '%s\\n' "$query" >> "\(dir.sub("gh-calls"))"
             for number in $(grep -oE 'pullRequest\\(number: [0-9]+\\)' <<< "$query" | grep -oE '[0-9]+'); do
                 if [[ ! -f "\(dir.sub("gh-prs"))/$number.json" ]]; then
@@ -46,6 +48,7 @@ struct LocalGitHub {
             done
             cat "\(dir.sub("gh-reply"))" 2>/dev/null || echo '{"data": {"repository": {}}}'
             """)
+        try writeLists()
     }
 
     /// The tests' environment, with https://github.com/ rewritten to `remotes`.
@@ -104,7 +107,8 @@ struct LocalGitHub {
     /// `refs/pull/<number>/head` of the base repo, so that ref is pointed at the branch's tip.
     func openPR(
         _ number: Int, on base: String, from branch: String, of head: String? = nil, state: String = "OPEN",
-        maintainerCanModify: Bool = false, deleteBranch: Bool = false, forkGone: Bool = false
+        maintainerCanModify: Bool = false, deleteBranch: Bool = false, forkGone: Bool = false, title: String? = nil,
+        author: String? = "author", isDraft: Bool = false, updatedAt: String = "2026-09-28T00:00:00Z"
     ) async throws {
         let headRepo = head ?? base
         let tip = try await Fixture.git.run(["rev-parse", "refs/heads/\(branch)"], in: bare(headRepo))
@@ -116,19 +120,42 @@ struct LocalGitHub {
         }
         let parts = headRepo.split(separator: "/")
         let json: [String: Any] = [
-            "number": number, "title": "PR \(number)", "url": "https://github.com/\(base)/pull/\(number)",
-            "state": state, "isDraft": false, "updatedAt": "2026-09-28T00:00:00Z", "headRefName": branch,
+            "number": number, "title": title ?? "PR \(number)", "url": "https://github.com/\(base)/pull/\(number)",
+            "state": state, "isDraft": isDraft, "updatedAt": updatedAt, "headRefName": branch,
             "headRefOid": tip, "headRef": deleteBranch ? NSNull() : ["name": branch], "baseRefName": "main",
             "isCrossRepository": headRepo != base, "maintainerCanModify": maintainerCanModify,
             "headRepository": forkGone ? NSNull() : ["name": String(parts[1])],
             "headRepositoryOwner": forkGone ? NSNull() : ["login": String(parts[0])],
+            "author": author.map { ["login": $0] } ?? NSNull(),
         ]
         try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: "\(prs)/\(number).json"))
+        try writeLists()
     }
 
     /// Makes GitHub forget PR `number`, as when it removes a spam PR.
     func deletePR(_ number: Int) {
         try? FileManager.default.removeItem(atPath: "\(prs)/\(number).json")
+        try? writeLists()
+    }
+
+    /// What gh answers for the list of open PRs and of all PRs, most recently updated first.
+    private func writeLists() throws {
+        let names = try FileManager.default.contentsOfDirectory(atPath: prs).filter { $0.hasSuffix(".json") }
+        let all = try names.compactMap {
+            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(prs)/\($0)")))
+                as? [String: Any]
+        }
+        .sorted { ($0["updatedAt"] as? String ?? "") > ($1["updatedAt"] as? String ?? "") }
+        let fields = [
+            "number", "title", "url", "state", "isDraft", "updatedAt", "headRefName", "isCrossRepository", "author",
+        ]
+        for (file, states) in [("gh-list-open", ["OPEN"]), ("gh-list-all", ["OPEN", "CLOSED", "MERGED"])] {
+            let nodes = all.filter { states.contains($0["state"] as? String ?? "") }.map {
+                $0.filter { fields.contains($0.key) }
+            }
+            let reply = ["data": ["repository": ["pullRequests": ["nodes": nodes]]]]
+            try JSONSerialization.data(withJSONObject: reply).write(to: URL(fileURLWithPath: dir.sub(file)))
+        }
     }
 
     /// What gh answers every query that is not a PR's lookup.
```


- [ ] **Step 2: Run the tests and see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: build errors for `SearchText` and `listPullRequests`.

- [ ] **Step 3: Write the code**

A first version also matched a row by its badge.
That finds nothing the binding and the head name do not, since those are how the badge lookup asks, so it went, and a mutation check showed the binding clause is what `saysWhichRowHasEachPullRequest` needs.

`Sources/CanopyCore/Rows/SearchText.swift` (new):

```swift
import Foundation

/// Text typed to narrow a list: an item matches when each word appears in one of its fields, ignoring case.
public struct SearchText: Sendable, Equatable {
    public let words: [String]

    public init(_ text: String?) {
        words = (text ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { words.isEmpty }

    public func matches(_ fields: [String]) -> Bool {
        words.allSatisfy { word in fields.contains { $0.range(of: word, options: .caseInsensitive) != nil } }
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+Listing.swift` (new):

```swift
import Foundation

extension WorkspaceError {
    /// Why gh could not answer, in the sidebar's words.
    init(_ failure: GHFailure) {
        switch failure {
        case .ghMissing: self = .ghUnavailable(RepoPullRequests(source: .ghMissing).warning ?? "")
        case .notLoggedIn: self = .ghUnavailable(RepoPullRequests(source: .notLoggedIn).warning ?? "")
        case .failed(let message): self = .ghFailed(message)
        }
    }
}

extension ListedPullRequest {
    public func matches(_ search: SearchText) -> Bool {
        search.matches(["#\(number)", title, headBranch, author ?? ""])
    }
}

extension Workspace {
    /// The repo's open PRs, most recently updated first, or its 100 most recently updated in any state with
    /// `includeClosed`, each with the row that has it. A query that is a PR number, `#number`, or PR URL looks that PR
    /// up in any state. Other text keeps the PRs whose number, title, head branch, or author holds each of its words.
    public func listPullRequests(
        repoPath: String, query: String? = nil, includeClosed: Bool = false
    ) async throws -> [ListedPullRequest] {
        _ = try entryIndex(repoPath: repoPath)
        guard let origin = await gitHubRemote("origin", repoPath: repoPath) else {
            throw WorkspaceError.notOnGitHub(repoName(repoPath))
        }
        var listed: [ListedPullRequest]
        if let reference = query.flatMap(PRReference.init) {
            if let repo = reference.repo, !repo.matches(origin.repo) {
                throw WorkspaceError.pullRequestInOtherRepo(repo.nameWithOwner, origin: origin.repo.nameWithOwner)
            }
            switch await github.pullRequest(repo: origin.repo, number: reference.number) {
            case .success(let head): listed = head.map { [ListedPullRequest($0)] } ?? []
            case .failure(let failure): throw WorkspaceError(failure)
            }
        } else {
            switch await github.pullRequestList(repo: origin.repo, includeClosed: includeClosed) {
            case .success(let all): listed = all.filter { $0.matches(SearchText(query)) }
            case .failure(let failure): throw WorkspaceError(failure)
            }
        }
        let holders = pullRequestHolders(repoPath: repoPath, repo: origin.repo)
        for index in listed.indices {
            listed[index].row = holders(listed[index])
        }
        return listed
    }

    /// Finds the row or worktree that has a PR's branch: one on a branch bound to the PR, or for a PR from the repo
    /// itself, one on its head branch. These are also how the PR badges find a row's PR. A worktree whose folder is
    /// gone holds nothing, since `row new` takes its branch back.
    func pullRequestHolders(repoPath: String, repo: GitHubRepo) -> (ListedPullRequest) -> BranchHolder? {
        let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing && $0.branch != nil } ?? []
        let bound = boundPullRequests(repoPath: repoPath, branches: rows.compactMap(\.branch), repo: repo)
        return { pr in
            let row =
                rows.first { $0.branch.flatMap { bound[$0] } == pr.number }
                ?? (pr.isFork ? nil : rows.first { $0.branch == pr.headBranch })
            return row.map(BranchHolder.init)
        }
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`:

```diff
@@ -30,12 +30,8 @@ extension Workspace {
             head = found
         case .success(nil):
             throw WorkspaceError.pullRequestNotFound(reference.number, repo: origin.repo.nameWithOwner)
-        case .failure(.ghMissing):
-            throw WorkspaceError.ghUnavailable(RepoPullRequests(source: .ghMissing).warning ?? "")
-        case .failure(.notLoggedIn):
-            throw WorkspaceError.ghUnavailable(RepoPullRequests(source: .notLoggedIn).warning ?? "")
-        case .failure(.failed(let message)):
-            throw WorkspaceError.ghFailed(message)
+        case .failure(let failure):
+            throw WorkspaceError(failure)
         }
         return try await createRow(repoPath: repoPath, joining: group) {
             try await self.createPullRequestRowNow(
```


- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'SearchTextTests|PullRequestListTests|PullRequestRowTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: list a repo's pull requests with the row that has each"
```

## Task 3: `Workspace.listBranches`

**Files:**
- Create: `Sources/CanopyCore/Rows/ListedBranch.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace+Listing.swift`, `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`
- Test: `Tests/CanopyCoreTests/BranchListTests.swift`, `Tests/CanopyCoreTests/Support/Fixtures.swift`, `Tests/CanopyCoreTests/Support/LocalGitHub.swift`

**Interfaces:**
- Consumes: `SearchText`, `BranchHolder`, `Workspace.fetchUnlessFresh(repoPath:since:)`, `Workspace.defaultBase(repoPath:hasOrigin:)`, and `Workspace.serialized(repoPath:_:)`.
- Produces: `BranchLocation` (`local`, `origin`, `both`), `ListedBranch` (`name`, `location` coded as `where`, `ahead: Int?`, `behind: Int?`, `committedAt` in ISO 8601, `row: BranchHolder?`, `label`, and `matches(_:)`), and `BranchListing` (`branches`, `defaultBase`, `warnings`).
- Produces: `Workspace.listBranches(repoPath: String, query: String? = nil, fetch: Bool = true) async throws -> BranchListing`.
  With `fetch`, it first runs `git fetch --prune origin` in the repo's git queue, unless a fetch that finished after the call was made covers it, since pruning rewrites refs that creating a row may be writing.
  A local branch is compared with `origin/<name>` by name, as `row new` does, not with its configured upstream.
  Branches come newest commit first, the newer of a branch's two commits dating it, and one named exactly the query, in any case, comes first.
- Produces: `Fixture.git(committingAt:)` and `LocalGitHub.push(_:to:of:date:)`, for commits at a given time.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/BranchListTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// `branch list`: a repo's local and origin branches, each with the row or worktree that has it.
struct BranchListTests {
    /// acme/app, whose main was committed on 2026-09-01, with a clone at <dir>/demo registered in a workspace.
    /// `before` runs ahead of each git command the workspace runs, as `LocalGitHub.git(before:)` describes.
    func setUp(_ dir: TempDir, before: String? = nil) async throws -> (LocalGitHub, String, Workspace) {
        let github = try LocalGitHub(dir)
        let git = try before.map { try github.git(before: $0) }
        try await github.createRepo("acme/app")
        try await github.push(to: "main", of: "acme/app", date: "2026-09-01T00:00:00Z")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git ?? github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (github, repo, workspace)
    }

    /// Commits on the checked-out branch of `path`, made at `date`.
    func commit(_ path: String, date: String, count: Int = 1) async throws {
        for index in 1...count {
            try await Fixture.git(committingAt: date).run(
                ["commit", "--quiet", "--allow-empty", "-m", "local \(index)"], in: path)
        }
    }

    @Test func listsLocalAndOriginBranchesNewestFirst() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/old", of: "acme/app", date: "2026-09-10T00:00:00Z")
        try await github.push(to: "feat/new", of: "acme/app", date: "2026-09-20T00:00:00Z")
        try await github.git.run(["switch", "--quiet", "-c", "local/only"], in: repo)
        try await commit(repo, date: "2026-09-15T00:00:00Z")
        try await github.git.run(["switch", "--quiet", "main"], in: repo)

        let listing = try await workspace.listBranches(repoPath: repo)

        #expect(listing.branches.map(\.name) == ["feat/new", "local/only", "feat/old", "main"])
        #expect(listing.branches.map(\.location) == [.origin, .local, .origin, .both])
        #expect(listing.branches.map(\.committedAt).first == "2026-09-20T00:00:00Z")
        #expect(listing.warnings.isEmpty)
    }

    @Test func comparesALocalBranchWithOriginsByName() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        for branch in ["feat/behind", "feat/ahead", "feat/diverged", "feat/same"] {
            try await github.push(2, to: branch, of: "acme/app", date: "2026-09-02T00:00:00Z")
        }
        try await github.git.run(["fetch", "--quiet", "origin"], in: repo)
        try await github.git.run(["branch", "feat/behind", "origin/feat/behind~2"], in: repo)
        try await github.git.run(["branch", "feat/same", "origin/feat/same"], in: repo)
        for (branch, start) in [("feat/ahead", "origin/feat/ahead"), ("feat/diverged", "origin/feat/diverged~1")] {
            try await github.git.run(["switch", "--quiet", "-c", branch, start], in: repo)
            try await commit(repo, date: "2026-09-03T00:00:00Z")
        }
        // Tracking origin/main does not make it origin's feat/tracks-main.
        try await github.git.run(["switch", "--quiet", "--track", "-c", "feat/tracks-main", "origin/main"], in: repo)
        try await github.git.run(["switch", "--quiet", "main"], in: repo)

        let branches = Dictionary(
            uniqueKeysWithValues: try await workspace.listBranches(repoPath: repo, fetch: false).branches.map {
                ($0.name, $0)
            })

        #expect(branches["feat/behind"]?.behind == 2 && branches["feat/behind"]?.ahead == 0)
        #expect(branches["feat/ahead"]?.ahead == 1 && branches["feat/ahead"]?.behind == 0)
        #expect(branches["feat/diverged"]?.ahead == 1 && branches["feat/diverged"]?.behind == 1)
        #expect(branches["feat/same"]?.ahead == 0 && branches["feat/same"]?.behind == 0)
        #expect(branches["feat/tracks-main"]?.location == .local)
        #expect(branches["feat/tracks-main"]?.ahead == nil)
        #expect(branches["feat/behind"]?.label == "local, 2 behind")
        #expect(branches["feat/ahead"]?.label == "local, 1 ahead")
        #expect(branches["feat/diverged"]?.label == "local ≠ origin")
        #expect(branches["feat/same"]?.label == "local")
        #expect(branches["feat/tracks-main"]?.label == "local")
        // The newer of the two commits dates it.
        #expect(branches["feat/diverged"]?.committedAt == "2026-09-03T00:00:00Z")
        #expect(branches["feat/behind"]?.committedAt == "2026-09-02T00:00:00Z")
    }

    @Test func labelsSayWhereABranchIs() {
        func label(_ location: BranchLocation, _ ahead: Int? = nil, _ behind: Int? = nil) -> String {
            ListedBranch(name: "x", location: location, ahead: ahead, behind: behind, committedAt: "").label
        }

        #expect(label(.origin) == "origin")
        #expect(label(.local) == "local")
        #expect(label(.both, 0, 0) == "local")
        #expect(label(.both, 0, 3) == "local, 3 behind")
        #expect(label(.both, 2, 0) == "local, 2 ahead")
        #expect(label(.both, 1, 1) == "local ≠ origin")
    }

    @Test func aListedBranchReadsPlainlyForAgents() throws {
        let branch = ListedBranch(
            name: "feat/x", location: .origin, ahead: nil, behind: nil, committedAt: "2026-09-02T00:00:00Z")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let json = String(decoding: try encoder.encode(branch), as: UTF8.self)

        #expect(
            json
                == #"{"ahead":null,"behind":null,"committedAt":"2026-09-02T00:00:00Z","name":"feat/x","row":null,"#
                + #""where":"origin"}"#)
        #expect(try JSONDecoder().decode(ListedBranch.self, from: Data(json.utf8)) == branch)
    }

    @Test func saysWhichRowOrWorktreeHasEachBranch() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        for branch in ["feat/row", "feat/elsewhere", "feat/gone", "feat/free"] {
            try await github.push(to: branch, of: "acme/app")
        }
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/row", existing: true).row
        try await github.git.run(
            [
                "worktree", "add", "--quiet", "--track", "-b", "feat/elsewhere", dir.sub("elsewhere"),
                "origin/feat/elsewhere",
            ],
            in: repo)
        let gone = try await workspace.createRow(repoPath: repo, branch: "feat/gone", existing: true).row
        try FileManager.default.removeItem(atPath: gone.path)
        await workspace.refresh(repoPath: repo)

        let holders = Dictionary(
            uniqueKeysWithValues: try await workspace.listBranches(repoPath: repo).branches.map { ($0.name, $0.row) })

        #expect(holders["feat/row"] == BranchHolder(row))
        #expect(holders["main"] == BranchHolder(path: repo, branch: "main", rowClass: .main))
        #expect(
            holders["feat/elsewhere"]
                == BranchHolder(
                    path: Paths.canonical(dir.sub("elsewhere")), branch: "feat/elsewhere", rowClass: .external))
        #expect(holders["feat/gone"] == .some(nil))
        #expect(holders["feat/free"] == .some(nil))
    }

    @Test func fetchesFirstUnlessAFetchCoversIt() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(
            dir, before: #"[[ "$1" == fetch ]] && echo fetch >> "\#(dir.sub("fetches"))""#)
        func fetches() -> Int {
            ((try? String(contentsOfFile: dir.sub("fetches"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        try await github.push(to: "feat/pushed", of: "acme/app")

        let local = try await workspace.listBranches(repoPath: repo, fetch: false)
        #expect(!local.branches.map(\.name).contains("feat/pushed"))
        #expect(fetches() == 0)

        async let first = workspace.listBranches(repoPath: repo)
        async let second = workspace.listBranches(repoPath: repo)
        let both = try await [first, second]

        #expect(both.allSatisfy { $0.branches.map(\.name).contains("feat/pushed") })
        #expect(fetches() == 1)
        _ = try await workspace.listBranches(repoPath: repo)
        #expect(fetches() == 2)
    }

    @Test func aFailedFetchStillListsLocalBranches() async throws {
        let dir = try TempDir()
        let (_, repo, workspace) = try await setUp(
            dir,
            before: #"""
                [[ "$1" == fetch ]] && { echo "fatal: unable to access 'https://github.com/acme/app.git/'" >&2; exit 128; }
                """#)

        let listing = try await workspace.listBranches(repoPath: repo)

        #expect(listing.branches.map(\.name) == ["main"])
        #expect(
            listing.warnings == [
                "git fetch failed: fatal: unable to access 'https://github.com/acme/app.git/', so the list shows "
                    + "what Canopy last saw of origin."
            ])
    }

    @Test func aRepoWithoutOriginListsLocalBranches() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let git = try Fixture.git(in: dir, before: #"[[ "$1" == fetch ]] && exit 1"#)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git, github: Fixture.noGH(in: dir))
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        let listing = try await workspace.listBranches(repoPath: repo)

        #expect(listing.branches.map(\.name) == ["main"])
        #expect(listing.branches.first?.location == .local)
        #expect(listing.defaultBase == "HEAD")
        #expect(listing.warnings.isEmpty)
    }

    @Test func filtersByQueryWithAnExactNameFirst() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/login", of: "acme/app", date: "2026-09-02T00:00:00Z")
        try await github.push(to: "feat/login-page", of: "acme/app", date: "2026-09-05T00:00:00Z")
        try await github.push(to: "fix/logout", of: "acme/app", date: "2026-09-04T00:00:00Z")

        func names(_ query: String) async throws -> [String] {
            try await workspace.listBranches(repoPath: repo, query: query).branches.map(\.name)
        }

        #expect(try await names("LOGIN") == ["feat/login-page", "feat/login"])
        #expect(try await names("Feat/Login") == ["feat/login", "feat/login-page"])
        #expect(try await names("log fix") == ["fix/logout"])
        #expect(try await names("nothing") == [])
    }

    @Test func theDefaultBaseIsOriginsDefaultBranch() async throws {
        let dir = try TempDir()
        let (_, repo, workspace) = try await setUp(dir)

        #expect(try await workspace.listBranches(repoPath: repo, fetch: false).defaultBase == "origin/main")
    }
}
```

`Tests/CanopyCoreTests/Support/Fixtures.swift`:

```diff
@@ -22,6 +22,14 @@ enum Fixture {
     /// Tests pass an explicit environment so they never depend on the login shell of whoever runs them.
     static let git = GitRunner(executable: gitPath, environment: environment)
 
+    /// A GitRunner whose commits are made at `date`, such as 2026-09-01T10:00:00Z, or now when it is nil.
+    static func git(committingAt date: String?) -> GitRunner {
+        guard let date else { return git }
+        return GitRunner(
+            executable: gitPath,
+            environment: environment.merging(["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) { $1 })
+    }
+
     /// Creates `<dir>/<name>` with one commit on `main`. With `origin`, also creates a bare
     /// `<dir>/<name>-origin.git`, pushes to it, and sets origin/HEAD.
     @discardableResult
```

`Tests/CanopyCoreTests/Support/LocalGitHub.swift`:

```diff
@@ -82,9 +82,12 @@ struct LocalGitHub {
         return Paths.canonical(path)
     }
 
-    /// Pushes `count` new commits on `branch` of `nameWithOwner`, starting it from main if it is new. Returns its tip.
+    /// Pushes `count` new commits on `branch` of `nameWithOwner`, starting it from main if it is new, made at `date`
+    /// (default: now). Returns its tip.
     @discardableResult
-    func push(_ count: Int = 1, to branch: String, of nameWithOwner: String) async throws -> String {
+    func push(
+        _ count: Int = 1, to branch: String, of nameWithOwner: String, date: String? = nil
+    ) async throws -> String {
         let work = dir.sub("work/\(nameWithOwner)")
         if !FileManager.default.fileExists(atPath: work) {
             try await Fixture.git.run(["clone", "--quiet", bare(nameWithOwner), work])
@@ -96,7 +99,8 @@ struct LocalGitHub {
         try await Fixture.git.run(
             ["switch", "--quiet", "--force-create", branch, start ? "origin/\(branch)" : "origin/main"], in: work)
         for index in 1...count {
-            try await Fixture.git.run(["commit", "--quiet", "--allow-empty", "-m", "\(branch) \(index)"], in: work)
+            try await Fixture.git(committingAt: date).run(
+                ["commit", "--quiet", "--allow-empty", "-m", "\(branch) \(index)"], in: work)
         }
         try await Fixture.git.run(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], in: work)
         return try await Fixture.git.run(["rev-parse", "HEAD"], in: work).trimmingCharacters(
```


- [ ] **Step 2: Run the tests and see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: build errors for `ListedBranch` and `listBranches`.

- [ ] **Step 3: Write the code**

`Sources/CanopyCore/Rows/ListedBranch.swift` (new):

```swift
import Foundation

/// Where a branch exists: here, on origin, or both.
public enum BranchLocation: String, Codable, Sendable {
    case local, origin, both
}

/// A branch as `canopy branch list` and the New Row sheet show it.
public struct ListedBranch: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var location: BranchLocation
    /// Commits the local branch has that origin's does not, when the branch is in both places.
    public var ahead: Int?
    /// Commits origin's branch has that the local one does not, when the branch is in both places.
    public var behind: Int?
    /// When the newer of its local and origin commits was made, in ISO 8601.
    public var committedAt: String
    /// The row or worktree that has the branch checked out.
    public var row: BranchHolder?

    public var id: String { name }

    public init(
        name: String, location: BranchLocation, ahead: Int? = nil, behind: Int? = nil, committedAt: String,
        row: BranchHolder? = nil
    ) {
        self.name = name
        self.location = location
        self.ahead = ahead
        self.behind = behind
        self.committedAt = committedAt
        self.row = row
    }

    /// Where the branch is, and how the local branch compares with origin's.
    public var label: String {
        switch (location, ahead ?? 0, behind ?? 0) {
        case (.origin, _, _): "origin"
        case (.local, _, _), (.both, 0, 0): "local"
        case (.both, 0, let behind): "local, \(behind) behind"
        case (.both, let ahead, 0): "local, \(ahead) ahead"
        case (.both, _, _): "local ≠ origin"
        }
    }

    public func matches(_ search: SearchText) -> Bool {
        search.matches([name])
    }

    enum CodingKeys: String, CodingKey {
        case name, ahead, behind, committedAt, row
        case location = "where"
    }

    /// Writes nulls rather than leaving keys out, so every branch has the same fields.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(location, forKey: .location)
        try container.encode(ahead, forKey: .ahead)
        try container.encode(behind, forKey: .behind)
        try container.encode(committedAt, forKey: .committedAt)
        try container.encode(row, forKey: .row)
    }
}

/// A repo's branches, and what a new branch starts from.
public struct BranchListing: Codable, Sendable, Equatable {
    public var branches: [ListedBranch]
    /// Where a new branch starts when no start point is given, such as origin/main.
    public var defaultBase: String
    /// Why the list may be out of date, such as a failed fetch.
    public var warnings: [String]

    public init(branches: [ListedBranch], defaultBase: String, warnings: [String] = []) {
        self.branches = branches
        self.defaultBase = defaultBase
        self.warnings = warnings
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+Listing.swift`:

```diff
@@ -63,4 +63,83 @@ extension Workspace {
             return row.map(BranchHolder.init)
         }
     }
+
+    /// The repo's local branches and origin's, newest commit first, each with the row or worktree that has it. With
+    /// `fetch`, origin is fetched first, unless a fetch that finished after this call was made covers it. A query keeps
+    /// the branches whose name holds each of its words, with one named exactly that, in any case, first.
+    public func listBranches(repoPath: String, query: String? = nil, fetch: Bool = true) async throws -> BranchListing {
+        let requestedAt = ContinuousClock.now
+        _ = try entryIndex(repoPath: repoPath)
+        guard FileManager.default.fileExists(atPath: repoPath) else { throw WorkspaceError.pathNotFound(repoPath) }
+        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
+        var warnings: [String] = []
+        if fetch, hasOrigin {
+            // In the repo's git queue, since pruning rewrites refs that creating a row may be writing too.
+            let failure = try await serialized(repoPath: repoPath) {
+                await self.fetchUnlessFresh(repoPath: repoPath, since: requestedAt)
+            }
+            if let failure { warnings.append("\(failure), so the list shows what Canopy last saw of origin.") }
+        }
+
+        let output: String
+        do {
+            output = try await git.run(
+                ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(committerdate:unix)", "refs/heads/"]
+                    + (hasOrigin ? ["refs/remotes/origin/"] : []),
+                in: repoPath)
+        } catch let error as GitError {
+            throw WorkspaceError.git(error)
+        }
+        var local: [String: (commit: String, date: Date)] = [:]
+        var origin: [String: (commit: String, date: Date)] = [:]
+        for line in output.split(separator: "\n") {
+            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
+            guard fields.count == 3, let seconds = TimeInterval(fields[2]) else { continue }
+            let tip = (commit: fields[1], date: Date(timeIntervalSince1970: seconds))
+            if fields[0].hasPrefix("refs/heads/") {
+                local[String(fields[0].dropFirst("refs/heads/".count))] = tip
+            } else if fields[0] != "refs/remotes/origin/HEAD" {
+                origin[String(fields[0].dropFirst("refs/remotes/origin/".count))] = tip
+            }
+        }
+
+        let search = SearchText(query)
+        let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing } ?? []
+        var branches: [ListedBranch] = []
+        for name in Set(local.keys).union(origin.keys) where search.matches([name]) {
+            let here = local[name]
+            let there = origin[name]
+            var branch = ListedBranch(
+                name: name, location: here == nil ? .origin : there == nil ? .local : .both,
+                committedAt: max(here?.date ?? .distantPast, there?.date ?? .distantPast).formatted(.iso8601),
+                row: rows.first { $0.branch == name }.map(BranchHolder.init))
+            if let here, let there {
+                (branch.ahead, branch.behind) =
+                    here.commit == there.commit
+                    ? (0, 0) : await aheadBehind(here.commit, there.commit, repoPath: repoPath)
+            }
+            branches.append(branch)
+        }
+        let typed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
+        branches.sort { a, b in
+            let aExact = a.name.caseInsensitiveCompare(typed) == .orderedSame
+            let bExact = b.name.caseInsensitiveCompare(typed) == .orderedSame
+            if aExact != bExact { return aExact }
+            if a.committedAt != b.committedAt { return a.committedAt > b.committedAt }
+            return a.name < b.name
+        }
+        return BranchListing(
+            branches: branches, defaultBase: await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin),
+            warnings: warnings)
+    }
+
+    /// How many commits `local` has that `other` does not, and the other way round. Nil when git cannot say.
+    private func aheadBehind(_ local: String, _ other: String, repoPath: String) async -> (Int?, Int?) {
+        guard
+            let counts = try? await git.run(
+                ["rev-list", "--left-right", "--count", "\(local)...\(other)"], in: repoPath)
+        else { return (nil, nil) }
+        let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
+        return parts.count == 2 ? (parts[0], parts[1]) : (nil, nil)
+    }
 }
```

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`:

```diff
@@ -300,7 +300,7 @@ extension Workspace {
     /// Parallel creates queue behind each other, so a fetch that finished after this request was made
     /// already covers it. Its outcome, including a failure, is reused rather than waiting on the network again.
     /// Returns why the fetch failed, or nil. Pruning drops branches deleted on origin, which are no longer on it.
-    private func fetchUnlessFresh(repoPath: String, since requestedAt: ContinuousClock.Instant) async -> String? {
+    func fetchUnlessFresh(repoPath: String, since requestedAt: ContinuousClock.Instant) async -> String? {
         if let attempt = lastFetch[repoPath], attempt.finishedAt > requestedAt {
             return attempt.failure
         }
```


- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter BranchListTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: list a repo's local and origin branches with the row that has each"
```

## Task 4: `canopy pr list`, `canopy pr show`, and `canopy branch list`

**Files:**
- Create: `Sources/CanopyCLI/BranchCommand.swift`, `Sources/CanopyCore/Support/ShortAge.swift`
- Modify: `Sources/CanopyCore/Control/ControlMethods.swift`, `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, `Sources/CanopyCLI/PRCommand.swift`, `Sources/CanopyCLI/CanopyCLI.swift`, `Sources/CanopyCLI/Client.swift`, `Sources/CanopyCLI/AgentGuide.swift`
- Test: `Tests/CanopyCoreTests/ControlProtocolTests.swift`, `Tests/CanopyCoreTests/ControlServerTests.swift`, `Tests/CanopyCoreTests/ShortAgeTests.swift`

**Interfaces:**
- Consumes: `Workspace.listPullRequests` and `Workspace.listBranches`.
- Produces: `ControlMethod.prList` (`pr.list`) and `ControlMethod.branchList` (`branch.list`), both read-only, so the activity log leaves them out.
  `PRListParams(target:query:closed:)` and `BranchListParams(target:query:fetch:)` decode with defaults, and their results are `[ListedPullRequest]` and `BranchListing`.
  `pr.list` waits 90 seconds like `pr.show`, and `branch.list` 900, since its fetch queues behind other git work in the repo.
- Produces: `canopy pr show [row] [--refresh]` as the default of `canopy pr`, `canopy pr list [--query <text>] [--closed] [--json]`, and `canopy branch list [--query <text>] [--no-fetch] [--json]`, whose `--json` prints the branches and whose warnings go to stderr.
- Produces: `ShortAge.text(_:now:)`, "2h ago" from a date or an ISO 8601 time, and `Table.holder(_:for:)` for the ROW column.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlProtocolTests.swift`:

```diff
@@ -62,6 +62,21 @@ struct JSONValueTests {
         #expect(String(decoding: try JSONEncoder().encode(shown), as: UTF8.self).contains(#""pr":null"#))
     }
 
+    @Test func listParamsDefaultWhatIsLeftOut() throws {
+        let prs = try JSONValue.object([:]).decode(PRListParams.self)
+        #expect(prs.target == TargetHint() && prs.query == nil && !prs.closed)
+        let branches = try JSONValue.object([:]).decode(BranchListParams.self)
+        #expect(branches.target == TargetHint() && branches.query == nil && branches.fetch)
+
+        let asked = try JSONValue.object(["query": .string("#7"), "closed": .bool(true)]).decode(PRListParams.self)
+        #expect(asked.query == "#7" && asked.closed)
+        #expect(try JSONValue.object(["fetch": .bool(false)]).decode(BranchListParams.self).fetch == false)
+    }
+
+    @Test func listsOnlyRead() {
+        #expect(ControlMethod.readOnly.isSuperset(of: [ControlMethod.prList, ControlMethod.branchList]))
+    }
+
     @Test func keepsIntegersIntegral() throws {
         let data = try JSONEncoder().encode(JSONValue.number(42))
         #expect(String(decoding: data, as: UTF8.self) == "42")
@@ -82,6 +97,9 @@ struct JSONValueTests {
         #expect(ControlMethod.replyTimeout(for: ControlMethod.rowList).map { $0 <= 60 } == true)
         // A refresh can wait behind a lookup already asking GitHub, and each gets 30 seconds.
         #expect(ControlMethod.replyTimeout(for: ControlMethod.prShow).map { $0 >= 60 } == true)
+        #expect(ControlMethod.replyTimeout(for: ControlMethod.prList).map { $0 >= 60 } == true)
+        // A fetch waits behind other git work in the repo, as creating rows does.
+        #expect(ControlMethod.replyTimeout(for: ControlMethod.branchList).map { $0 >= 600 } == true)
     }
 
     @Test func clientFailuresMapToStableCodes() {
```

`Tests/CanopyCoreTests/ControlServerTests.swift`:

```diff
@@ -449,6 +449,39 @@ struct ControlServerTests {
         #expect(created.pr?.number == 7)
     }
 
+    @Test func pullRequestAndBranchListsAnswerOverTheSocket() async throws {
+        let dir = try TempDir()
+        let github = try LocalGitHub(dir)
+        try await github.createRepo("acme/app")
+        try await github.push(to: "feat/split", of: "acme/app")
+        try await github.push(to: "feat/other", of: "acme/app")
+        try await github.openPR(7, on: "acme/app", from: "feat/split", title: "Split checkout")
+        try await github.openPR(8, on: "acme/app", from: "feat/other", state: "MERGED")
+        let repo = try await github.clone("acme/app")
+        let (workspace, server, client, _) = try await startServer(dir, git: github.git, github: github.gh)
+        defer { server.stop() }
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+        let row = try await workspace.createRow(repoPath: repo, branch: "feat/split", existing: true).row
+        let target = TargetHint(repo: "demo")
+
+        let open = try await call(
+            client, ControlMethod.prList, PRListParams(target: target), as: [ListedPullRequest].self)
+        let all = try await call(
+            client, ControlMethod.prList, PRListParams(target: target, closed: true), as: [ListedPullRequest].self)
+        let merged = try await call(
+            client, ControlMethod.prList, PRListParams(target: target, query: "#8"), as: [ListedPullRequest].self)
+        let branches = try await call(
+            client, ControlMethod.branchList, BranchListParams(target: target, query: "feat"), as: BranchListing.self)
+
+        #expect(open.map(\.number) == [7])
+        #expect(open.first?.row == BranchHolder(row))
+        #expect(Set(all.map(\.number)) == [7, 8])
+        #expect(merged.map(\.state) == [.merged])
+        #expect(Set(branches.branches.map(\.name)) == ["feat/split", "feat/other"])
+        #expect(branches.branches.first { $0.name == "feat/split" }?.row == BranchHolder(row))
+        #expect(branches.defaultBase == "origin/main")
+    }
+
     @Test func rowNewRefusesOptionsThatDoNotGoTogether() async throws {
         let dir = try TempDir()
         let repo = try await Fixture.repo(in: dir, origin: true)
```

`Tests/CanopyCoreTests/ShortAgeTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

struct ShortAgeTests {
    @Test func saysHowLongAgoInOneUnit() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(TimeInterval, String)] = [
            (-30, "now"), (0, "now"), (59, "now"), (60, "1m ago"), (59 * 60, "59m ago"), (3600, "1h ago"),
            (23 * 3600 + 3599, "23h ago"), (86400, "1d ago"), (6 * 86400, "6d ago"), (7 * 86400, "1w ago"),
            (29 * 86400, "4w ago"), (30 * 86400, "1mo ago"), (364 * 86400, "12mo ago"), (365 * 86400, "1y ago"),
            (800 * 86400, "2y ago"),
        ]
        for (seconds, text) in cases {
            #expect(ShortAge.text(now.addingTimeInterval(-seconds), now: now) == text, "\(seconds)")
        }
    }

    @Test func readsISOTimes() {
        let now = Date(timeIntervalSince1970: 1_789_869_600)
        #expect(ShortAge.text("2026-09-20T00:00:00Z", now: now) == "2h ago")
        #expect(ShortAge.text("yesterday", now: now) == "yesterday")
    }
}
```


- [ ] **Step 2: Run the tests and see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: build errors for `PRListParams`, `BranchListParams`, `ControlMethod.prList`, and `ShortAge`.

- [ ] **Step 3: Write the code**

The tables started with Foundation's "2 hours ago", and the sheet's first shots showed "1 hr ago".
The spec's rows read `2h ago`, so both use `ShortAge`.

`Sources/CanopyCLI/AgentGuide.swift`:

```diff
@@ -49,6 +49,7 @@ struct AgentGuide: ParsableCommand {
         `row new --pr` checks out a pull request's branch, including one from a fork, with gh pr checkout's names and
         tracking, and "pr" in the result is the PR. Pick the local name with `--branch`. A branch another row has
         fails with branch_checked_out, which names that row; use `canopy row select` or `canopy term` there instead.
+        To find what to start from, list the repo's PRs and branches (see Pull requests and branches below).
 
         ## Groups
 
@@ -106,13 +107,23 @@ struct AgentGuide: ParsableCommand {
         works in. `ports stop` only stops your row's ports, or any row's with --all, never a port no row owns.
         Ports the system picks at random (49152 and up) are left out: they are tools like MCP servers.
 
-        ## Pull requests
+        ## Pull requests and branches
 
-            canopy pr [<branch>] [--refresh]              the row's PR: number, state, title, and URL
+            canopy pr show [<branch>] [--refresh]         the row's PR: number, state, title, and URL
+            canopy pr list [--query <text>] [--closed]    the repo's open PRs, most recently updated first
+            canopy branch list [--query <text>]           local and origin branches, newest commit first
 
-        Canopy looks up PRs with your `gh` login for its own and adopted rows, about once a minute and more often
-        right after a push. `--refresh` asks GitHub now, for example right after `gh pr create`.
-        `row list --json` also carries each row's PR as "pr" when it has one.
+        `canopy pr` alone is `pr show`. Canopy looks up PRs with your `gh` login for its own and adopted rows, about
+        once a minute and more often right after a push. `--refresh` asks GitHub now, for example right after
+        `gh pr create`. `row list --json` also carries each row's PR as "pr" when it has one.
+
+        `pr list` shows the 100 most recently updated PRs. `--query` keeps those whose number, title, head branch, or
+        author holds each word, and a number, #number, or URL looks that PR up even when it is closed. `branch list`
+        fetches origin first, unless you pass `--no-fetch`. It says where each branch is ("where": local, origin, or
+        both) and how many commits the local branch is "ahead" of or "behind" origin's. In both lists "row" is the
+        row or worktree that has the item checked out, or null. Start a row on an item without one with `row new --pr <n>` or
+        `row new <branch> --existing`, show one that has a row with `row select`, and adopt one in another tool's
+        worktree ("class": "external") with `row adopt <path>`. These are the lists the New Row sheet shows.
 
         ## Activity
 
@@ -137,6 +148,11 @@ struct AgentGuide: ParsableCommand {
 
             canopy row new --pr 123 --run 'claude "review this PR"'
 
+        Review every open PR that has no row yet:
+
+            canopy pr list --json | jq -r '.[] | select(.row == null) | .number' |
+                while read -r n; do canopy row new --pr "$n" --run 'claude "review this PR"'; done
+
         Run a dev server in its own tab of your row and watch it:
 
             pane=$(canopy term new --tab Server --run 'bun dev' --title 'dev server' --json | jq -r .pane)
```

`Sources/CanopyCLI/BranchCommand.swift` (new):

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct BranchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "List a repo's branches.",
        subcommands: [List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the repo's local and origin branches, newest commit first.",
            discussion: """
                Fetches origin first, so a branch pushed a moment ago is listed. --no-fetch lists what the repo \
                already has. Each branch says where it is (local, origin, or both), how the local branch compares \
                with origin's, and the row or worktree that has it checked out. Start a row on one with \
                canopy row new <branch> --existing.
                """
        )

        @Option(help: "Only branches whose name holds each word.")
        var query: String?
        @Flag(name: .customLong("no-fetch"), help: "List what the repo already has, without fetching origin.")
        var noFetch = false
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.branchList,
                BranchListParams(target: Client.hint(repo: repo), query: query, fetch: !noFetch))
            let listing = try result.decode(BranchListing.self)
            for warning in listing.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(try .from(listing.branches)) {
                guard !listing.branches.isEmpty else { return "No branches match." }
                return Table.render(
                    ["BRANCH", "WHERE", "COMMITTED", "ROW"],
                    listing.branches.map { branch in
                        [branch.name, branch.label, ShortAge.text(branch.committedAt), Table.holder(branch.row)]
                    }
                )
            }
        }
    }
}
```

`Sources/CanopyCLI/CanopyCLI.swift`:

```diff
@@ -10,7 +10,8 @@ struct CanopyCLI: AsyncParsableCommand {
         version: CanopyVersion.current,
         subcommands: [
             Status.self, RepoCommand.self, RowCommand.self, GroupCommand.self, TermCommand.self, PortsCommand.self,
-            PRCommand.self, LogCommand.self, HooksCommand.self, AgentGuide.self, AgentHookCommand.self,
+            PRCommand.self, BranchCommand.self, LogCommand.self, HooksCommand.self, AgentGuide.self,
+            AgentHookCommand.self,
         ]
     )
 }
```

`Sources/CanopyCLI/Client.swift`:

```diff
@@ -181,4 +181,16 @@ enum Table {
         }
         .joined(separator: "\n")
     }
+
+    /// Where a listed PR or branch is checked out. A PR's row can be on a branch named other than its head.
+    static func holder(_ holder: BranchHolder?, for head: String? = nil) -> String {
+        guard let holder else { return "-" }
+        switch holder.rowClass {
+        case .main: return "main checkout"
+        case .external: return "other worktree"
+        case .canopy, .adopted:
+            guard let branch = holder.branch, let head, branch != head else { return "in row" }
+            return "in row \(branch)"
+        }
+    }
 }
```

`Sources/CanopyCLI/PRCommand.swift`:

```diff
@@ -1,32 +1,83 @@
 import ArgumentParser
 import CanopyCore
+import Foundation
 
 struct PRCommand: AsyncParsableCommand {
     static let configuration = CommandConfiguration(
         commandName: "pr",
-        abstract: "Show a row's pull request.",
-        discussion: """
-            Canopy looks up PRs with your gh login for its own and adopted rows, about once a minute and more \
-            often right after a push. --refresh asks GitHub now, for example right after gh pr create.
-            """
+        abstract: "Show a row's pull request, or list the repo's.",
+        subcommands: [Show.self, List.self],
+        defaultSubcommand: Show.self
     )
 
-    @Argument(help: "Branch or path. Defaults to the row you are in.")
-    var row: String?
-    @Option(help: "Repo name or path, when the branch exists in several repos.")
-    var repo: String?
-    @Flag(help: "Ask GitHub now instead of using the last lookup.")
-    var refresh = false
-    @OptionGroup var output: OutputOptions
+    struct Show: AsyncParsableCommand {
+        static let configuration = CommandConfiguration(
+            abstract: "Show a row's pull request.",
+            discussion: """
+                Canopy looks up PRs with your gh login for its own and adopted rows, about once a minute and more \
+                often right after a push. --refresh asks GitHub now, for example right after gh pr create.
+                """
+        )
 
-    func run() async throws {
-        let client = Client(json: output.json)
-        let result = client.call(
-            ControlMethod.prShow, PRShowParams(target: Client.hint(repo: repo, row: row), refresh: refresh))
-        try client.print(result) {
-            let shown = try result.decode(PRShowResult.self)
-            guard let pr = shown.pr else { return "\(shown.branch) has no pull request." }
-            return "#\(pr.number) \(pr.state.rawValue): \(pr.title)\n\(pr.url)"
+        @Argument(help: "Branch or path. Defaults to the row you are in.")
+        var row: String?
+        @Option(help: "Repo name or path, when the branch exists in several repos.")
+        var repo: String?
+        @Flag(help: "Ask GitHub now instead of using the last lookup.")
+        var refresh = false
+        @OptionGroup var output: OutputOptions
+
+        func run() async throws {
+            let client = Client(json: output.json)
+            let result = client.call(
+                ControlMethod.prShow, PRShowParams(target: Client.hint(repo: repo, row: row), refresh: refresh))
+            try client.print(result) {
+                let shown = try result.decode(PRShowResult.self)
+                guard let pr = shown.pr else { return "\(shown.branch) has no pull request." }
+                return "#\(pr.number) \(pr.state.rawValue): \(pr.title)\n\(pr.url)"
+            }
+        }
+    }
+
+    struct List: AsyncParsableCommand {
+        static let configuration = CommandConfiguration(
+            abstract: "List the repo's open pull requests, most recently updated first.",
+            discussion: """
+                Lists the 100 most recently updated, asking GitHub with your gh login. --query keeps the PRs whose \
+                number, title, head branch, or author holds each word, and a PR number, #number, or URL looks that PR \
+                up even when it is closed. Each PR names the row or worktree that has its branch: show a row with \
+                canopy row select, and start one on a PR that has none with canopy row new --pr <number>.
+                """
+        )
+
+        @Option(help: "Only PRs whose number, title, head branch, or author holds each word, or one PR by number.")
+        var query: String?
+        @Flag(help: "Include closed and merged PRs.")
+        var closed = false
+        @Option(help: "Repo name or path. Defaults to the repo you are in.")
+        var repo: String?
+        @OptionGroup var output: OutputOptions
+
+        func run() async throws {
+            let client = Client(json: output.json)
+            let result = client.call(
+                ControlMethod.prList, PRListParams(target: Client.hint(repo: repo), query: query, closed: closed))
+            try client.print(result) {
+                let listed = try result.decode([ListedPullRequest].self)
+                guard !listed.isEmpty else {
+                    return query == nil ? "No \(closed ? "" : "open ")pull requests." : "No pull requests match."
+                }
+                return Table.render(
+                    ["PR", "STATE", "UPDATED", "AUTHOR", "HEAD", "ROW", "TITLE"],
+                    listed.map { pr in
+                        [
+                            "#\(pr.number)", pr.state.rawValue, ShortAge.text(pr.updatedAt), pr.author ?? "-",
+                            pr.headBranch + (pr.isFork ? " (fork)" : ""), Table.holder(pr.row, for: pr.headBranch),
+                            pr.title,
+                        ]
+                    }
+                )
+            }
         }
     }
 }
```

`Sources/CanopyCore/Control/ControlMethods.swift`:

```diff
@@ -13,11 +13,13 @@ public enum ControlMethod {
     public static let rowAdopt = "row.adopt"
     public static let rowMove = "row.move"
     public static let prShow = "pr.show"
+    public static let prList = "pr.list"
+    public static let branchList = "branch.list"
 
     /// Methods that only read, which the activity log leaves out: agents poll some of them every few seconds.
     public static let readOnly: Set<String> = [
-        status, repoList, rowList, prShow, TermMethod.list, TermMethod.read, TermMethod.wait, PortMethod.list,
-        GroupMethod.list,
+        status, repoList, rowList, prShow, prList, branchList, TermMethod.list, TermMethod.read, TermMethod.wait,
+        PortMethod.list, GroupMethod.list,
     ]
 
     /// Methods left out of `cli.call`: the read-only ones, and `term.state`, which hooks send on every tool call and
@@ -28,12 +30,13 @@ public enum ControlMethod {
     /// can take minutes. Creating and removing rows also wait for setup or teardown, which can run for as long as
     /// a build does and cannot be cancelled, so the CLI waits for them without a limit, and so does a clone, which
     /// takes as long as the repo is big. A PR lookup can queue behind one already asking GitHub, and each may take
-    /// 30 seconds. `term.wait` has its own timeout, which the CLI waits out. Other reads answer from memory.
+    /// 30 seconds. Listing branches fetches in the repo's git queue. `term.wait` has its own timeout, which the CLI
+    /// waits out. Other reads answer from memory.
     public static func replyTimeout(for method: String) -> TimeInterval? {
         if [rowNew, rowRemove, repoClone].contains(method) { return nil }
-        if method == prShow { return 90 }
+        if [prShow, prList].contains(method) { return 90 }
         if method == TermMethod.wait { return nil }
-        return [repoAdd, repoRemove, rowAdopt].contains(method) ? 900 : 30
+        return [repoAdd, repoRemove, rowAdopt, branchList].contains(method) ? 900 : 30
     }
 }
 
@@ -284,3 +287,46 @@ public struct PRShowResult: Codable, Sendable {
         try container.encode(pr, forKey: .pr)
     }
 }
+
+public struct PRListParams: Codable, Sendable {
+    public var target: TargetHint
+    /// Keeps the PRs whose number, title, head branch, or author holds each word. A PR number, `#number`, or URL looks
+    /// that PR up in any state.
+    public var query: String?
+    /// Lists closed and merged PRs too.
+    public var closed: Bool
+
+    public init(target: TargetHint = TargetHint(), query: String? = nil, closed: Bool = false) {
+        self.target = target
+        self.query = query
+        self.closed = closed
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
+        query = try container.decodeIfPresent(String.self, forKey: .query)
+        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
+    }
+}
+
+public struct BranchListParams: Codable, Sendable {
+    public var target: TargetHint
+    /// Keeps the branches whose name holds each word.
+    public var query: String?
+    /// Fetches origin first. Off to list only what the repo already has.
+    public var fetch: Bool
+
+    public init(target: TargetHint = TargetHint(), query: String? = nil, fetch: Bool = true) {
+        self.target = target
+        self.query = query
+        self.fetch = fetch
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
+        query = try container.decodeIfPresent(String.self, forKey: .query)
+        fetch = try container.decodeIfPresent(Bool.self, forKey: .fetch) ?? true
+    }
+}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`:

```diff
@@ -203,6 +203,19 @@ public struct WorkspaceControlHandler: Sendable {
                     repo: snapshot.repo(path: row.repoPath)?.name ?? "", branch: row.displayName, path: row.path,
                     pr: pr))
 
+        case ControlMethod.prList:
+            let params = try request.decodeParams(PRListParams.self)
+            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
+            return try .from(
+                try await workspace.listPullRequests(
+                    repoPath: repo.path, query: params.query, includeClosed: params.closed))
+
+        case ControlMethod.branchList:
+            let params = try request.decodeParams(BranchListParams.self)
+            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
+            return try .from(
+                try await workspace.listBranches(repoPath: repo.path, query: params.query, fetch: params.fetch))
+
         case PortMethod.list:
             let params = try request.decodeParams(PortsListParams.self)
             let row = try await rowUnlessAll(params.target, all: params.all)
```

`Sources/CanopyCore/Support/ShortAge.swift` (new):

```swift
import Foundation

/// How long ago something happened, in its largest whole unit, such as "2h ago", for lists where space is short.
public enum ShortAge {
    public static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        let day = 86400
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<day: return "\(seconds / 3600)h ago"
        case ..<(7 * day): return "\(seconds / day)d ago"
        case ..<(30 * day): return "\(seconds / (7 * day))w ago"
        case ..<(365 * day): return "\(seconds / (30 * day))mo ago"
        default: return "\(seconds / (365 * day))y ago"
        }
    }

    /// An ISO 8601 time, or the text as it is when it is not one.
    public static func text(_ iso: String, now: Date = .now) -> String {
        guard let date = try? Date(iso, strategy: .iso8601) else { return iso }
        return text(date, now: now)
    }
}
```


- [ ] **Step 4: Run the tests and see them pass, then try the CLI**

Run: `swift test $(scripts/test-flags.sh) --filter 'JSONValueTests|ControlServerTests|ShortAgeTests'`
Expected: PASS.

Run, in bash: `for args in "pr feat/x" "pr --refresh" "pr show feat/x" "pr list --closed" "branch list --no-fetch"; do CANOPY_APP=/nonexistent CANOPY_HOME=$(mktemp -d) .build/debug/canopy $args --json; done`
Expected: each parses and fails only because the app cannot launch, so `canopy pr <row>` still reaches `pr show`.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: canopy pr list, canopy pr show, and canopy branch list"
```

## Task 5: The picker behind the sheet

**Files:**
- Create: `Sources/CanopyCore/Rows/BranchName.swift`, `Sources/CanopyCore/Rows/NewRowPicker.swift`
- Test: `Tests/CanopyCoreTests/BranchNameTests.swift`, `Tests/CanopyCoreTests/NewRowPickerTests.swift`

**Interfaces:**
- Consumes: `ListedPullRequest`, `ListedBranch`, `BranchListing`, `SearchText`, `PRReference`, `RepoPullRequests.warning`, and `WorkspaceError`.
- Produces: `BranchName.isValid(_:) -> Bool`: git's rules for a name under `refs/heads/`, which `row new` checks with git, plus Canopy's own: no leading `-`, and neither `HEAD` nor `@`.
- Produces: `NewRowAction` (`pullRequest(Int)`, `branch(String)`, `newBranch(String, base: String?)`, `selectRow(BranchHolder)`, `adopt(BranchHolder)`), with `command`, the CLI equivalent quoted for a shell, and `createsRow`.
- Produces: `NewRowItem` (`pullRequest(ListedPullRequest)`, `branch(ListedBranch)`, `newBranch(String)`), with `id`, `holder`, and `action(base:)`.
- Produces: `@MainActor @Observable final class NewRowPicker`, made with `NewRowPicker.Sources` and a lookup delay, 250 ms by default.
  `Sources` holds `pullRequests: (String?) async throws -> [ListedPullRequest]` and `branches: (Bool) async throws -> BranchListing`, and `Sources.workspace(_:repoPath:)` makes them from a `Workspace`.
  The picker has `text`, `base`, `load()`, `isFetching`, `showsPullRequests`, `pullRequestItems`, `pullRequestNote`, `branchItems`, `branchNote`, `defaultBase`, `newBranchItem`, `items`, `selectedItem`, `selectedAction`, `select(_:)`, and `moveSelection(by:)`.

Rules the tests pin:

- Nothing is selected until something is typed, and then the first item is.
  A selected item stays selected while answers that arrive later list it, and only when it goes does the first item take over.
- A PR number, `#number`, or URL shows only that PR.
  One not among the open PRs is looked up once typing has stopped for the delay, and a URL always is, since only the lookup says whether it names this repo.
  A lookup that has started finishes and is kept by the text that asked, so an older answer never stands in for newer text.
- The "New branch" line needs a valid branch name that no listed branch has in any case, and text starting with `#` means a PR.
- A repo not on GitHub hides the PR section, and gh that cannot answer shows the sidebar's warning there.

- [ ] **Step 1: Write the failing tests**

`BranchNameTests` compares `BranchName.isValid` with `git check-ref-format refs/heads/<name>` over names that break each rule.
`NewRowPickerTests` drives the picker with `FakeLists`, whose answers wait on a `Gate` that opens on its own after 20 seconds, and `listsAWorkspacesPullRequestsAndBranches` drives it with a real `Workspace` on the local GitHub.

`Tests/CanopyCoreTests/BranchNameTests.swift` (new):

```swift
import Testing

@testable import CanopyCore

struct BranchNameTests {
    /// Names that break each of git's rules, and some that keep them.
    static let names = [
        "feat/x", "fix/login-redirect", "v1.2", "café", "a@b", "12", "#12", "feat/x.y", "UPPER/Case",
        "", " ", "a b", "a\tb", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a..b", ".a", "a/.b", "a.",
        "a.lock", "a/b.lock/c", "/a", "a/", "a//b", "@", "a@{b", "a\u{7F}b", "a\u{01}b", "-a", "HEAD", "feat/HEAD",
    ]

    /// The check `row new` makes with git, plus the names Canopy refuses itself.
    @Test(arguments: names) func agreesWithGit(_ name: String) async {
        let git = await Fixture.git.succeeds(["check-ref-format", "refs/heads/\(name)"])
        let expected = git && !name.hasPrefix("-") && !["HEAD", "@", ""].contains(name)
        #expect(BranchName.isValid(name) == expected, "\(name)")
    }
}
```

`Tests/CanopyCoreTests/NewRowPickerTests.swift` (new):

```swift
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// Opens once `open()` is called, or after 20 seconds, so a test that fails first never leaves a task waiting forever.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.open()
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Lists for the picker, with gates that hold back an answer until the test opens them.
final class FakeLists: Sendable {
    struct State {
        var pullRequests: Result<[ListedPullRequest], WorkspaceError> = .success([])
        var lookups: [String: [ListedPullRequest]] = [:]
        var lookupGates: [String: Gate] = [:]
        var local = BranchListing(branches: [], defaultBase: "origin/main")
        var fetched: BranchListing?
        var fetchGate: Gate?
        var pullRequestGate: Gate?
        var queries: [String?] = []
    }

    let state = Mutex(State())

    var sources: NewRowPicker.Sources {
        NewRowPicker.Sources(
            pullRequests: { query in
                let (gate, result) = self.state.withLock { state in
                    state.queries.append(query)
                    guard let query else { return (state.pullRequestGate, state.pullRequests) }
                    let found = state.lookups[query.trimmingCharacters(in: .whitespaces)] ?? []
                    return (state.lookupGates[query], state.pullRequests.map { _ in found })
                }
                await gate?.wait()
                return try result.get()
            },
            branches: { fetch in
                let (gate, listing) = self.state.withLock { state in
                    fetch ? (state.fetchGate, state.fetched ?? state.local) : (nil, state.local)
                }
                await gate?.wait()
                return listing
            })
    }

    var queries: [String?] { state.withLock { $0.queries } }
}

@MainActor
struct NewRowPickerTests {
    func pr(
        _ number: Int, _ title: String = "PR", head: String, author: String? = "alice", state: PRState = .open,
        row: BranchHolder? = nil
    ) -> ListedPullRequest {
        ListedPullRequest(
            number: number, title: title, url: "https://github.com/acme/app/pull/\(number)", state: state,
            author: author, headBranch: head, isFork: false, updatedAt: "2026-09-28T00:00:00Z", row: row)
    }

    func branch(_ name: String, _ location: BranchLocation = .both, row: BranchHolder? = nil) -> ListedBranch {
        ListedBranch(
            name: name, location: location, ahead: location == .both ? 0 : nil, behind: location == .both ? 0 : nil,
            committedAt: "2026-09-28T00:00:00Z", row: row)
    }

    func listing(_ branches: [ListedBranch], warnings: [String] = []) -> BranchListing {
        BranchListing(branches: branches, defaultBase: "origin/main", warnings: warnings)
    }

    func makePicker(_ lists: FakeLists) -> NewRowPicker {
        NewRowPicker(sources: lists.sources, lookupDelay: .zero)
    }

    func ids(_ items: [NewRowItem]) -> [String] {
        items.map(\.id)
    }

    @Test func showsLocalBranchesBeforeTheFetchFinishes() async throws {
        let lists = FakeLists()
        let gate = Gate()
        lists.state.withLock {
            $0.local = listing([branch("main")])
            $0.fetched = listing([branch("feat/pushed", .origin), branch("main")])
            $0.fetchGate = gate
        }
        let picker = makePicker(lists)

        let loading = Task { await picker.load() }

        #expect(await eventually { picker.isFetching })
        #expect(ids(picker.branchItems) == ["branch/main"])
        await gate.open()
        await loading.value
        #expect(!picker.isFetching)
        #expect(ids(picker.branchItems) == ["branch/feat/pushed", "branch/main"])
    }

    @Test func filtersBothSectionsAsYouType() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([
                pr(12, "Round cart totals", head: "fix/cart"), pr(7, "Keep the page", head: "feat/login"),
            ])
            $0.local = listing([branch("fix/cart"), branch("feat/login"), branch("main")])
        }
        let picker = makePicker(lists)
        await picker.load()

        #expect(ids(picker.pullRequestItems) == ["pr/12", "pr/7"])
        #expect(ids(picker.branchItems) == ["branch/fix/cart", "branch/feat/login", "branch/main"])
        #expect(picker.newBranchItem == nil)

        picker.text = "cart"
        #expect(ids(picker.pullRequestItems) == ["pr/12"])
        #expect(ids(picker.branchItems) == ["branch/fix/cart"])
        #expect(picker.newBranchItem == .newBranch("cart"))
        #expect(ids(picker.items) == ["pr/12", "branch/fix/cart", "new"])

        picker.text = "alice page"
        #expect(ids(picker.pullRequestItems) == ["pr/7"])
        #expect(picker.branchItems.isEmpty)
        #expect(picker.branchNote == .init(kind: .info, text: "No branches match."))
    }

    @Test func aPullRequestNumberIsLookedUpWhenItIsNotListed() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([pr(12, head: "fix/cart")])
            $0.lookups = [
                "#40": [pr(40, head: "feat/old", state: .closed)],
                "https://github.com/acme/app/pull/12": [pr(12, head: "fix/cart")],
            ]
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#12"
        #expect(ids(picker.pullRequestItems) == ["pr/12"])
        #expect(lists.queries == [nil])

        picker.text = "#40"
        #expect(picker.pullRequestNote == .init(kind: .loading, text: "Looking up #40…"))
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/40"] })
        #expect(picker.pullRequestNote == nil)

        picker.text = "41"
        #expect(await eventually { picker.pullRequestNote == .init(kind: .info, text: "No pull request #41.") })
        #expect(picker.pullRequestItems.isEmpty)

        picker.text = "https://github.com/acme/app/pull/12"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/12"] })
        #expect(lists.queries == [nil, "#40", "41", "https://github.com/acme/app/pull/12"])
    }

    @Test func anOlderLookupNeverReplacesANewerOne() async throws {
        let lists = FakeLists()
        let gate = Gate()
        lists.state.withLock {
            $0.lookups = ["#1": [pr(1, head: "feat/one")], "#12": [pr(12, head: "feat/twelve")]]
            $0.lookupGates = ["#1": gate]
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#1"
        #expect(await eventually { lists.queries.contains("#1") })
        picker.text = "#12"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/12"] })
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ids(picker.pullRequestItems) == ["pr/12"])

        picker.text = "#1"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/1"] })
        #expect(lists.queries.filter { $0 == "#1" }.count == 1)
    }

    @Test func aLookupAKeystrokeMadeUnnecessaryNeverStarts() async throws {
        let lists = FakeLists()
        let picker = NewRowPicker(sources: lists.sources, lookupDelay: .milliseconds(300))
        await picker.load()

        picker.text = "#1"
        picker.text = "#12"
        picker.text = "#123"

        #expect(await eventually { lists.queries.count == 2 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(lists.queries == [nil, "#123"])
    }

    @Test func theNewBranchLineOnlyShowsForAnUnmatchedValidName() async throws {
        let lists = FakeLists()
        lists.state.withLock { $0.local = listing([branch("feat/login")]) }
        let picker = makePicker(lists)
        await picker.load()

        for (text, shown) in [
            ("feat/new", true), (" feat/new ", true), ("12", true), ("feat/login", false), ("", false),
            ("bad name", false), ("#12", false), ("feat/x.lock", false), ("https://github.com/acme/app/pull/1", false),
        ] {
            picker.text = text
            #expect((picker.newBranchItem != nil) == shown, "\(text)")
        }
        picker.text = " feat/new "
        #expect(picker.newBranchItem == .newBranch("feat/new"))
    }

    @Test func aNameInAnotherCaseIsNotNew() async throws {
        let lists = FakeLists()
        lists.state.withLock { $0.local = listing([branch("feat/login-page"), branch("feat/login")]) }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "Feat/Login"

        #expect(picker.newBranchItem == nil)
        #expect(ids(picker.branchItems) == ["branch/feat/login", "branch/feat/login-page"])
        #expect(picker.selectedItem?.id == "branch/feat/login")
    }

    @Test func nothingIsSelectedUntilYouType() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([pr(12, head: "fix/cart")])
            $0.local = listing([branch("main")])
        }
        let picker = makePicker(lists)
        await picker.load()

        #expect(picker.selectedItem == nil)
        #expect(picker.selectedAction == nil)
        picker.text = "m"
        #expect(picker.selectedItem?.id == "branch/main")
        picker.text = ""
        #expect(picker.selectedItem == nil)
        picker.moveSelection(by: 1)
        #expect(picker.selectedItem?.id == "pr/12")
    }

    @Test func arrowsMoveTheSelectionAndStopAtTheEnds() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([pr(12, head: "fix/cart")])
            $0.local = listing([branch("feat/a"), branch("feat/b")])
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.moveSelection(by: -1)
        #expect(picker.selectedItem?.id == "branch/feat/b")
        picker.text = "f"
        #expect(picker.selectedItem?.id == "pr/12")
        picker.moveSelection(by: 1)
        #expect(picker.selectedItem?.id == "branch/feat/a")
        picker.moveSelection(by: 10)
        #expect(picker.selectedItem?.id == "new")
        picker.moveSelection(by: -10)
        #expect(picker.selectedItem?.id == "pr/12")
        picker.select("branch/feat/b")
        #expect(picker.selectedItem?.id == "branch/feat/b")
    }

    @Test func theSelectionStaysPutWhenTheListRefreshes() async throws {
        let lists = FakeLists()
        let prGate = Gate()
        let fetchGate = Gate()
        lists.state.withLock {
            $0.pullRequests = .success([pr(3, head: "feat/c")])
            $0.pullRequestGate = prGate
            $0.local = listing([branch("feat/a"), branch("feat/b")])
            $0.fetched = listing([branch("feat/new", .origin), branch("feat/a"), branch("feat/b")])
            $0.fetchGate = fetchGate
        }
        let picker = makePicker(lists)
        let loading = Task { await picker.load() }
        #expect(await eventually { picker.isFetching })

        picker.text = "feat"
        #expect(picker.selectedItem?.id == "branch/feat/a")
        await prGate.open()
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/3"] })
        #expect(picker.selectedItem?.id == "branch/feat/a")
        await fetchGate.open()
        await loading.value
        #expect(ids(picker.branchItems).first == "branch/feat/new")
        #expect(picker.selectedItem?.id == "branch/feat/a")

        picker.text = "feat/b"
        lists.state.withLock { $0.fetched = listing([branch("feat/a")]) }
        await picker.refreshBranches()
        #expect(picker.selectedItem?.id == "new")
    }

    @Test func eachItemMapsToOneCommand() {
        let row = BranchHolder(path: "/w/feat-x", branch: "feat/x", rowClass: .canopy)
        let main = BranchHolder(path: "/r/app", branch: "main", rowClass: .main)
        let other = BranchHolder(path: "/tmp/my worktree", branch: "feat/z", rowClass: .external)
        let cases: [(NewRowItem, String?, NewRowAction, String)] = [
            (.pullRequest(pr(12, head: "fix/cart")), nil, .pullRequest(12), "canopy row new --pr 12"),
            (.branch(branch("feat/y")), nil, .branch("feat/y"), "canopy row new feat/y --existing"),
            (.newBranch("feat/n"), nil, .newBranch("feat/n", base: nil), "canopy row new feat/n"),
            (
                .newBranch("feat/n"), "origin/dev", .newBranch("feat/n", base: "origin/dev"),
                "canopy row new feat/n --from origin/dev"
            ),
            (.branch(branch("feat/x", row: row)), nil, .selectRow(row), "canopy row select feat/x"),
            (.pullRequest(pr(9, head: "feat/x", row: row)), nil, .selectRow(row), "canopy row select feat/x"),
            (.branch(branch("main", row: main)), nil, .selectRow(main), "canopy row select main"),
            (.branch(branch("feat/z", row: other)), nil, .adopt(other), "canopy row adopt '/tmp/my worktree'"),
        ]
        for (item, base, action, command) in cases {
            #expect(item.action(base: base) == action, "\(item.id)")
            #expect(action.command == command)
        }
        #expect(NewRowAction.pullRequest(1).createsRow && NewRowAction.newBranch("x", base: nil).createsRow)
        #expect(!NewRowAction.selectRow(row).createsRow && !NewRowAction.adopt(other).createsRow)
        #expect(NewRowAction.branch("it's").command == #"canopy row new 'it'\''s' --existing"#)
    }

    @Test func theNewBranchLineStartsFromTheTypedBase() async throws {
        let lists = FakeLists()
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "feat/n"
        #expect(picker.defaultBase == "origin/main")
        #expect(picker.selectedAction == .newBranch("feat/n", base: nil))
        picker.base = " origin/dev "
        #expect(picker.selectedAction == .newBranch("feat/n", base: "origin/dev"))
    }

    @Test func ghUnavailableShowsTheSidebarsWarning() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .failure(.ghUnavailable("Run `gh auth login` to see pull requests."))
            $0.local = listing([branch("main")])
        }
        let picker = makePicker(lists)
        await picker.load()

        let warning = NewRowPicker.Note(kind: .warning, text: "Run `gh auth login` to see pull requests.")
        #expect(picker.showsPullRequests)
        #expect(picker.pullRequestNote == warning)
        #expect(ids(picker.branchItems) == ["branch/main"])
        picker.text = "#12"
        try await Task.sleep(for: .milliseconds(100))
        #expect(picker.pullRequestNote == warning)
        #expect(lists.queries == [nil])

        lists.state.withLock { $0.pullRequests = .failure(.ghFailed("HTTP 502")) }
        let failed = makePicker(lists)
        await failed.load()
        #expect(failed.pullRequestNote == .init(kind: .warning, text: "Pull requests did not load: HTTP 502"))
    }

    @Test func aRepoNotOnGitHubHidesThePullRequests() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .failure(.notOnGitHub("demo"))
            $0.local = BranchListing(branches: [branch("main", .local)], defaultBase: "HEAD")
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#12"
        #expect(!picker.showsPullRequests)
        #expect(picker.pullRequestItems.isEmpty && picker.pullRequestNote == nil)
        picker.text = "feat/new"
        #expect(ids(picker.items) == ["new"])
        #expect(picker.defaultBase == "HEAD")
    }

    @Test func aFailedFetchSaysSoAndKeepsLocalBranches() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.local = listing([branch("main")])
            $0.fetched = listing(
                [branch("main")],
                warnings: [
                    "git fetch timed out, so the list shows what Canopy "
                        + "last saw of origin."
                ])
        }
        let picker = makePicker(lists)
        await picker.load()

        #expect(ids(picker.branchItems) == ["branch/main"])
        #expect(
            picker.branchNote
                == .init(kind: .warning, text: "git fetch timed out, so the list shows what Canopy last saw of origin.")
        )
    }

    @Test func listsAWorkspacesPullRequestsAndBranches() async throws {
        let dir = try TempDir()
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.push(to: "feat/taken", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split", title: "Split checkout")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/taken", existing: true).row
        let picker = NewRowPicker(sources: .workspace(workspace, repoPath: repo))

        await picker.load()

        #expect(ids(picker.pullRequestItems) == ["pr/7"])
        #expect(Set(ids(picker.branchItems)) == ["branch/feat/split", "branch/feat/taken", "branch/main"])
        picker.text = "taken"
        #expect(picker.selectedAction == .selectRow(BranchHolder(row)))
        picker.text = "split"
        #expect(picker.selectedAction == .pullRequest(7))
    }
}
```


- [ ] **Step 2: Run the tests and see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: build errors for `BranchName` and `NewRowPicker`.

- [ ] **Step 3: Write the code**

`Sources/CanopyCore/Rows/BranchName.swift` (new):

```swift
import Foundation

/// Branch names as git allows them, checked without running git, so the New Row sheet can check each keystroke.
public enum BranchName {
    /// git's rules for a name under refs/heads/, and Canopy's own: no leading `-`, which would read as an option, and
    /// neither `HEAD` nor `@`, which git reads as HEAD.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", name != "HEAD", !name.hasPrefix("-"), !name.hasPrefix("/"),
            !name.hasSuffix("/"), !name.hasSuffix("."), !name.contains(".."), !name.contains("//"),
            !name.contains("@{")
        else { return false }
        let forbidden = Set(" ~^:?*[\\".unicodeScalars)
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || forbidden.contains($0) })
        else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
}
```

`Sources/CanopyCore/Rows/NewRowPicker.swift` (new):

```swift
import Foundation
import Observation

/// What picking an item in the New Row sheet does. Each is one `canopy` command, which `command` spells out.
public enum NewRowAction: Equatable, Sendable {
    /// `canopy row new --pr <number>`
    case pullRequest(Int)
    /// `canopy row new <branch> --existing`
    case branch(String)
    /// `canopy row new <branch> [--from <base>]`
    case newBranch(String, base: String?)
    /// `canopy row select <branch>`
    case selectRow(BranchHolder)
    /// `canopy row adopt <path>`
    case adopt(BranchHolder)

    public var createsRow: Bool {
        switch self {
        case .pullRequest, .branch, .newBranch: true
        case .selectRow, .adopt: false
        }
    }

    public var command: String {
        let words: [String] =
            switch self {
            case .pullRequest(let number): ["row", "new", "--pr", "\(number)"]
            case .branch(let name): ["row", "new", name, "--existing"]
            case .newBranch(let name, let base): ["row", "new", name] + (base.map { ["--from", $0] } ?? [])
            case .selectRow(let row): ["row", "select", row.branch ?? row.path]
            case .adopt(let worktree): ["row", "adopt", worktree.path]
            }
        return (["canopy"] + words.map(Self.quoted)).joined(separator: " ")
    }

    /// `word` as a shell reads it back.
    static func quoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-#@+=")
        guard word.isEmpty || !word.unicodeScalars.allSatisfy(plain.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// One line of the New Row sheet's list.
public enum NewRowItem: Equatable, Sendable, Identifiable {
    case pullRequest(ListedPullRequest)
    case branch(ListedBranch)
    /// "New branch ‘<name>’ from <base>".
    case newBranch(String)

    public var id: String {
        switch self {
        case .pullRequest(let pr): "pr/\(pr.number)"
        case .branch(let branch): "branch/\(branch.name)"
        case .newBranch: "new"
        }
    }

    /// The row or worktree that already has the item checked out.
    public var holder: BranchHolder? {
        switch self {
        case .pullRequest(let pr): pr.row
        case .branch(let branch): branch.row
        case .newBranch: nil
        }
    }

    /// An item that already has a row opens it, and one in another tool's worktree adopts it. `base` is where a new
    /// branch starts, or nil for the repo's default.
    public func action(base: String?) -> NewRowAction {
        if let holder { return holder.isRow ? .selectRow(holder) : .adopt(holder) }
        switch self {
        case .pullRequest(let pr): return .pullRequest(pr.number)
        case .branch(let branch): return .branch(branch.name)
        case .newBranch(let name): return .newBranch(name, base: base)
        }
    }
}

/// The New Row sheet's state: the typed text, the PRs and branches it matches, and which one is selected.
/// Branches show from local refs at once and again after origin is fetched. PRs come from gh, and a PR number not in
/// the list is looked up on its own, a moment after typing stops.
@MainActor
@Observable
public final class NewRowPicker {
    /// Where the lists come from. `pullRequests` gets nil for the open PRs, or text to look one PR up by.
    /// `branches` gets whether to fetch origin first.
    public struct Sources: Sendable {
        public var pullRequests: @Sendable (String?) async throws -> [ListedPullRequest]
        public var branches: @Sendable (Bool) async throws -> BranchListing

        public init(
            pullRequests: @escaping @Sendable (String?) async throws -> [ListedPullRequest],
            branches: @escaping @Sendable (Bool) async throws -> BranchListing
        ) {
            self.pullRequests = pullRequests
            self.branches = branches
        }

        /// The same lists `canopy pr list` and `canopy branch list` give.
        public static func workspace(_ workspace: Workspace, repoPath: String) -> Sources {
            Sources(
                pullRequests: { try await workspace.listPullRequests(repoPath: repoPath, query: $0) },
                branches: { try await workspace.listBranches(repoPath: repoPath, fetch: $0) })
        }
    }

    /// A line in a section in place of, or above, its items.
    public struct Note: Equatable, Sendable {
        public enum Kind: Sendable {
            case loading, info, warning
        }

        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            selection = nil
            settleSelection()
            scheduleLookup()
        }
    }
    /// Where a new branch starts. Empty for `defaultBase`.
    public var base = ""
    /// Whether origin is being fetched, after which the branches show again.
    public private(set) var isFetching = false
    /// False once the repo's origin turns out not to be on GitHub.
    public private(set) var showsPullRequests = true

    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private let lookupDelay: Duration
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var lookingUp: Set<String> = []
    /// Nil while the open PRs load.
    private var openPullRequests: Result<[ListedPullRequest], WorkspaceError>?
    /// PRs looked up by what was typed, nil where GitHub has none.
    private var lookups: [String: Result<ListedPullRequest?, WorkspaceError>] = [:]
    private var branchListing: Result<BranchListing, WorkspaceError>?
    private var selection: String?

    public init(sources: Sources, lookupDelay: Duration = .milliseconds(250)) {
        self.sources = sources
        self.lookupDelay = lookupDelay
    }

    /// Loads the open PRs and the local branches together, then fetches origin and lists the branches again.
    public func load() async {
        async let pullRequests: Void = loadPullRequests()
        await loadBranches(fetch: false)
        await refreshBranches()
        await pullRequests
    }

    func refreshBranches() async {
        isFetching = true
        await loadBranches(fetch: true)
        isFetching = false
    }

    private func loadPullRequests() async {
        do {
            openPullRequests = .success(try await sources.pullRequests(nil))
        } catch WorkspaceError.notOnGitHub {
            showsPullRequests = false
            openPullRequests = .success([])
        } catch {
            openPullRequests = .failure(Self.workspaceError(error))
        }
        settleSelection()
        scheduleLookup()
    }

    private func loadBranches(fetch: Bool) async {
        do {
            branchListing = .success(try await sources.branches(fetch))
        } catch {
            // A failed refresh keeps what the first listing showed.
            if case .success = branchListing, fetch { return }
            branchListing = .failure(Self.workspaceError(error))
        }
        settleSelection()
    }

    // MARK: What the sheet shows

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The PR the typed text names, when it is a number, `#number`, or URL.
    private var reference: PRReference? { PRReference(typed) }

    /// A PR the typed text names that is not in the open list, and so is looked up on its own. URLs are always looked
    /// up, since only the lookup says whether they name this repo.
    private var lookupKey: String? {
        guard showsPullRequests, let reference, case .success(let open) = openPullRequests else { return nil }
        guard reference.repo != nil || !open.contains(where: { $0.number == reference.number }) else { return nil }
        return typed
    }

    public var pullRequestItems: [NewRowItem] {
        guard showsPullRequests, case .success(let open) = openPullRequests else { return [] }
        if let key = lookupKey {
            guard case .success(let found?) = lookups[key] else { return [] }
            return [.pullRequest(found)]
        }
        if let reference {
            return open.filter { $0.number == reference.number }.map(NewRowItem.pullRequest)
        }
        let search = SearchText(typed)
        return open.filter { $0.matches(search) }.map(NewRowItem.pullRequest)
    }

    public var pullRequestNote: Note? {
        guard showsPullRequests else { return nil }
        switch openPullRequests {
        case nil: return Note(kind: .loading, text: "Loading pull requests…")
        case .failure(let error): return Note(kind: .warning, text: Self.pullRequestWarning(error))
        case .success(let open):
            if let key = lookupKey, let number = reference?.number {
                switch lookups[key] {
                case nil: return Note(kind: .loading, text: "Looking up #\(number)…")
                case .success(nil): return Note(kind: .info, text: "No pull request #\(number).")
                case .failure(let error): return Note(kind: .warning, text: Self.pullRequestWarning(error))
                case .success: return nil
                }
            }
            guard pullRequestItems.isEmpty else { return nil }
            if open.isEmpty { return Note(kind: .info, text: "No open pull requests.") }
            return Note(kind: .info, text: "No open pull requests match.")
        }
    }

    public var branchItems: [NewRowItem] {
        guard case .success(let listing) = branchListing else { return [] }
        let search = SearchText(typed)
        let matching = listing.branches.filter { $0.matches(search) }
        // An exact name, in any case, first. The listing is already newest first.
        let exact = matching.filter { $0.name.caseInsensitiveCompare(typed) == .orderedSame }
        let others = matching.filter { $0.name.caseInsensitiveCompare(typed) != .orderedSame }
        return (exact + others).map(NewRowItem.branch)
    }

    public var branchNote: Note? {
        switch branchListing {
        case nil: return Note(kind: .loading, text: "Loading branches…")
        case .failure(let error): return Note(kind: .warning, text: error.message)
        case .success(let listing):
            if !listing.warnings.isEmpty { return Note(kind: .warning, text: listing.warnings.joined(separator: " ")) }
            return branchItems.isEmpty ? Note(kind: .info, text: "No branches match.") : nil
        }
    }

    /// Where a new branch starts by default, such as origin/main, once the branches are listed.
    public var defaultBase: String? {
        guard case .success(let listing) = branchListing else { return nil }
        return listing.defaultBase
    }

    /// "New branch ‘<name>’", shown for a valid branch name that no branch has in any case, since `row new` would use
    /// that branch. Text starting with `#` means a PR.
    public var newBranchItem: NewRowItem? {
        let name = typed
        guard BranchName.isValid(name), !name.hasPrefix("#") else { return nil }
        if case .success(let listing) = branchListing,
            listing.branches.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        {
            return nil
        }
        return .newBranch(name)
    }

    /// Every item in list order: PRs, branches, then the new branch line.
    public var items: [NewRowItem] {
        pullRequestItems + branchItems + (newBranchItem.map { [$0] } ?? [])
    }

    public var selectedItem: NewRowItem? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    public var selectedAction: NewRowAction? {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedItem?.action(base: base.isEmpty ? nil : base)
    }

    // MARK: Selection

    public func select(_ id: String?) {
        selection = id
    }

    /// Moves by `offset` items, stopping at the ends. With nothing selected, down picks the first and up the last.
    public func moveSelection(by offset: Int) {
        let items = items
        guard !items.isEmpty else { return }
        guard let index = items.firstIndex(where: { $0.id == selection }) else {
            selection = (offset > 0 ? items.first : items.last)?.id
            return
        }
        selection = items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// Keeps the selected item while it is listed, so answers arriving later never move it. Otherwise the first item
    /// is selected once something is typed, and nothing before.
    private func settleSelection() {
        let items = items
        if let selection, items.contains(where: { $0.id == selection }) { return }
        selection = typed.isEmpty ? nil : items.first?.id
    }

    // MARK: Looking up one PR

    /// Waits for typing to stop, then asks GitHub. A lookup that has started finishes and is kept, so an older answer
    /// can never stand in for what is typed now.
    private func scheduleLookup() {
        lookupTask?.cancel()
        guard let key = lookupKey, lookups[key] == nil, !lookingUp.contains(key) else { return }
        lookupTask = Task { [weak self, lookupDelay] in
            if lookupDelay > .zero { try? await Task.sleep(for: lookupDelay) }
            guard !Task.isCancelled else { return }
            await self?.lookUp(key)
        }
    }

    private func lookUp(_ key: String) async {
        lookingUp.insert(key)
        defer { lookingUp.remove(key) }
        let result: Result<ListedPullRequest?, WorkspaceError>
        do {
            result = .success(try await sources.pullRequests(key).first)
        } catch {
            result = .failure(Self.workspaceError(error))
        }
        lookups[key] = result
        settleSelection()
    }

    // MARK: Errors

    private static func workspaceError(_ error: any Error) -> WorkspaceError {
        error as? WorkspaceError ?? .ghFailed("\(error)")
    }

    /// The sidebar's words for why PRs cannot be shown.
    private static func pullRequestWarning(_ error: WorkspaceError) -> String {
        switch error {
        case .ghUnavailable(let fix): fix
        case .ghFailed(let message): RepoPullRequests(source: .failed(message)).warning ?? message
        default: error.message
        }
    }
}
```


- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'BranchNameTests|NewRowPickerTests'`
Expected: PASS.
Removing the line in `settleSelection` that keeps a listed selection fails `theSelectionStaysPutWhenTheListRefreshes`.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: the picker behind the New Row sheet"
```

## Task 6: The New Row sheet

**Files:**
- Create: `Sources/CanopyApp/Sidebar/NewRowSheet.swift`
- Modify: `Sources/CanopyApp/Sidebar/RowActionViews.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/AppModel.swift`

**Interfaces:**
- Consumes: `NewRowPicker`, `NewRowAction`, `NewRowItem`, `ShortAge`, `Workspace.createRow`, `Workspace.adopt`, and `Workspace.revealRow`.
- Produces: `AppModel.newRowSources(for:) -> NewRowPicker.Sources`.
- Produces: `AppModel.run(_ action: NewRowAction, in repo: RepoSnapshot, group: String?) async -> String?`, which creates, opens, or adopts the row, selects it, and returns an error for the sheet.
  A created row starts its setup and goes into `group`.
  When the branch turns out to have a row after all, it opens that row, since `branch_checked_out` names it.
- Produces: `NewRowSheet(repo:group:sources:)`.

The sheet is one focused field over one scrolling list: a Pull requests section, a Branches section, and the new branch line, whose start point is a small field of its own.
Sections show their count, or a note in its place while they load, fail, or match nothing, and the Branches header shows a spinner while origin is fetched.
Up and Down on the field move the selection, Return in either field runs it, a click selects an item, and a double click runs it.
The primary button says Create Row, Open Row, or Adopt, its help is the item's command, and the Group picker is off when the selected item opens or adopts a row.
The run guard keeps Return from running twice through both the field's submit and the default button.

- [ ] **Step 1: Build the sheet**

`Sources/CanopyApp/AppModel.swift`:

```diff
@@ -180,28 +180,53 @@ final class AppModel {
     /// A row the sidebar should scroll to even though the selection did not change.
     private(set) var scrollRequest: ScrollRequest?
 
-    /// Creates a row, starts its setup, and selects it. Returns an error message for the sheet to show, or nil.
-    func createRow(in repo: RepoSnapshot, branch: String, base: String?, group: String? = nil) async -> String? {
+    /// The New Row sheet's lists, which `canopy pr list` and `canopy branch list` give too.
+    func newRowSources(for repo: RepoSnapshot) -> NewRowPicker.Sources {
+        .workspace(workspace, repoPath: repo.path)
+    }
+
+    /// Does what the New Row sheet picked, as `action.command` would, and selects the row. A row it creates goes into
+    /// `group` and starts its setup. Returns an error message for the sheet to show, or nil.
+    func run(_ action: NewRowAction, in repo: RepoSnapshot, group: String?) async -> String? {
+        let created: CreatedRow
         do {
-            let created = try await workspace.createRow(
-                repoPath: repo.path, branch: branch, base: base, group: group)
-            let preparing = rows.prepare(created.row, repoName: repo.name, setup: true, run: nil)
-            // A row created into a collapsed group unfolds it, since the new row is selected.
-            try? await workspace.revealRow(path: created.row.path)
-            await select(created.row.path)
-            if let warning = created.warnings.first {
-                show(warning)
-            }
-            Task {
-                let ready = await preparing.value
-                if ready.setup.status == .failed, let message = ready.setup.message {
-                    show(message)
-                }
+            switch action {
+            case .selectRow(let row):
+                reveal(row.path)
+                return nil
+            case .adopt(let worktree):
+                let row = try await workspace.adopt(path: worktree.path)
+                await select(row.path)
+                return nil
+            case .pullRequest(let number):
+                created = try await workspace.createRow(
+                    repoPath: repo.path, pullRequest: PRReference(number: number), group: group)
+            case .branch(let name):
+                created = try await workspace.createRow(repoPath: repo.path, branch: name, existing: true, group: group)
+            case .newBranch(let name, let base):
+                created = try await workspace.createRow(repoPath: repo.path, branch: name, base: base, group: group)
             }
+        } catch WorkspaceError.branchCheckedOut(_, let row?) where row.rowClass != .external {
+            // The branch got a row after the list was made, and the list would have opened it.
+            reveal(row.path)
             return nil
         } catch {
             return (error as? WorkspaceError)?.message ?? "\(error)"
         }
+        let preparing = rows.prepare(created.row, repoName: repo.name, setup: true, run: nil)
+        // A row created into a collapsed group unfolds it, since the new row is selected.
+        try? await workspace.revealRow(path: created.row.path)
+        await select(created.row.path)
+        if let warning = created.warnings.first {
+            show(warning)
+        }
+        Task {
+            let ready = await preparing.value
+            if ready.setup.status == .failed, let message = ready.setup.message {
+                show(message)
+            }
+        }
+        return nil
     }
 
     enum RemoveOutcome {
```

`Sources/CanopyApp/Sidebar/NewRowSheet.swift` (new):

```swift
import CanopyCore
import SwiftUI

/// One field over one list of the repo's open PRs and branches, ending in a line that makes a new branch. Picking an
/// item does what `canopy` would for it, which the primary button's help spells out.
struct NewRowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: RepoSnapshot
    @State var group: String?
    @State private var picker: NewRowPicker
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var isFieldFocused: Bool

    init(repo: RepoSnapshot, group: String?, sources: NewRowPicker.Sources) {
        self.repo = repo
        _group = State(initialValue: group)
        _picker = State(initialValue: NewRowPicker(sources: sources))
    }

    var body: some View {
        @Bindable var picker = picker
        VStack(alignment: .leading, spacing: 12) {
            Text("New Row in \(repo.name)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField("Branch", text: $picker.text, prompt: Text("Branch, PR number, or new branch name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($isFieldFocused)
                .onKeyPress(.downArrow) {
                    picker.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    picker.moveSelection(by: -1)
                    return .handled
                }
                .onSubmit(runSelected)
            NewRowList(picker: picker, run: runSelected)
                .frame(maxHeight: .infinity)
                .disabled(isWorking)
            if let error {
                Text((try? AttributedString(markdown: error)) ?? AttributedString(error))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if !repo.groups.isEmpty {
                    Picker("Group", selection: $group) {
                        Text("No Group").tag(String?.none)
                        Divider()
                        ForEach(repo.groups) { group in
                            Text(group.name).tag(Optional(group.name))
                        }
                    }
                    .fixedSize()
                    // Opening or adopting a row leaves it where it is.
                    .disabled(picker.selectedAction.map { !$0.createsRow } ?? false)
                }
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: runSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picker.selectedAction == nil || isWorking)
                    .help(picker.selectedAction?.command ?? "")
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task { await picker.load() }
        .onAppear { isFieldFocused = true }
    }

    private var primaryTitle: String {
        switch picker.selectedAction {
        case .selectRow?: "Open Row"
        case .adopt?: "Adopt"
        default: "Create Row"
        }
    }

    private func runSelected() {
        guard !isWorking, let action = picker.selectedAction else { return }
        isWorking = true
        error = nil
        Task {
            error = await model.run(action, in: repo, group: action.createsRow ? group : nil)
            isWorking = false
            if error == nil {
                dismiss()
            }
        }
    }
}

/// The two sections and the new branch line, in one scrolling list that follows the selection.
private struct NewRowList: View {
    @Bindable var picker: NewRowPicker
    let run: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if picker.showsPullRequests {
                        SectionLabel(title: "Pull requests", count: count(picker.pullRequestItems)) {}
                        if let note = picker.pullRequestNote {
                            NoteRow(note: note)
                        }
                        ForEach(picker.pullRequestItems) { line(for: $0) }
                    }
                    SectionLabel(title: "Branches", count: count(picker.branchItems)) {
                        if picker.isFetching {
                            ProgressView()
                                .controlSize(.mini)
                                .help("Fetching origin")
                                .padding(.trailing, 5)
                        }
                    }
                    if let note = picker.branchNote {
                        NoteRow(note: note)
                    }
                    ForEach(picker.branchItems) { line(for: $0) }
                    if let item = picker.newBranchItem {
                        Divider().padding(.vertical, 4)
                        line(for: item)
                    }
                }
                .padding(4)
            }
            .onChange(of: picker.selectedItem?.id) {
                guard let id = picker.selectedItem?.id else { return }
                proxy.scrollTo(id)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    /// Sections say how many items they show, and nothing while they show only a note.
    private func count(_ items: [NewRowItem]) -> Int? {
        items.isEmpty ? nil : items.count
    }

    private func line(for item: NewRowItem) -> some View {
        ItemLine(
            item: item, isSelected: picker.selectedItem?.id == item.id, base: $picker.base,
            defaultBase: picker.defaultBase, select: { picker.select(item.id) }, run: run
        )
        .id(item.id)
    }
}

/// One PR, branch, or the new branch line. A click selects it and a double click picks it.
private struct ItemLine: View {
    let item: NewRowItem
    let isSelected: Bool
    @Binding var base: String
    let defaultBase: String?
    let select: () -> Void
    let run: () -> Void
    @State private var isHovering = false
    @FocusState private var isBaseFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            content
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded(run))
        .onHover { isHovering = $0 }
        // The new branch line keeps its start point field reachable on its own.
        .accessibilityElement(children: isNewBranch ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, run)
    }

    private var isNewBranch: Bool {
        if case .newBranch = item { return true }
        return false
    }

    private var height: Double {
        if case .pullRequest = item { return 42 }
        return 28
    }

    private var fill: Color {
        if isSelected { return Style.focusedSelectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .pullRequest(let pr):
            PullRequestGlyph()
                .stroke(pr.state.color, style: ItemLine.stroke)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)")
                        .font(Style.row.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(Style.row)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(pullRequestDetail(pr))
                        .font(Style.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pr.state == .draft {
                        TagView(text: "draft")
                    }
                    if pr.isFork {
                        TagView(text: "fork")
                    }
                }
            }
            Spacer(minLength: 8)
            if let holder = pr.row {
                HolderTag(holder: holder)
            }
        case .branch(let branch):
            BranchGlyph()
                .stroke(.secondary, style: ItemLine.stroke)
                .frame(width: 14, height: 14)
            Text(branch.name)
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
            TagView(text: branch.label)
            Spacer(minLength: 8)
            if let holder = branch.row {
                HolderTag(holder: holder)
            }
            Text(ShortAge.text(branch.committedAt))
                .font(Style.meta)
                .foregroundStyle(.tertiary)
        case .newBranch(let name):
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            (Text("New branch ") + Text(verbatim: "‘\(name)’").fontWeight(.medium) + Text(" from"))
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            TextField("Start from", text: $base, prompt: Text(verbatim: defaultBase ?? "origin's default branch"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 200)
                .focused($isBaseFocused)
                .onChange(of: isBaseFocused) {
                    if isBaseFocused { select() }
                }
                .onSubmit(run)
            Spacer(minLength: 0)
        }
    }

    /// `head · author · 2h ago`.
    private func pullRequestDetail(_ pr: ListedPullRequest) -> String {
        var parts = [pr.headBranch]
        if let author = pr.author { parts.append(author) }
        parts.append(ShortAge.text(pr.updatedAt))
        return parts.joined(separator: " · ")
    }

    private static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
}

/// "In row" for an item a row already has, which picking opens, or "Other worktree" for one another tool made.
private struct HolderTag: View {
    let holder: BranchHolder

    var body: some View {
        if holder.isRow {
            Text("In row")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Style.tagRadius))
        } else {
            TagView(text: "Other worktree")
        }
    }
}

/// Why a section is empty or may be out of date, or that it is loading.
private struct NoteRow: View {
    let note: NewRowPicker.Note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch note.kind {
            case .loading:
                ProgressView().controlSize(.mini)
                    .frame(width: 14)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 14)
            case .info:
                Color.clear.frame(width: 14, height: 1)
            }
            Text((try? AttributedString(markdown: note.text)) ?? AttributedString(note.text))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Style.meta)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
```

`Sources/CanopyApp/Sidebar/RowActionViews.swift`:

```diff
@@ -1,76 +1,6 @@
 import CanopyCore
 import SwiftUI
 
-struct NewRowSheet: View {
-    @Environment(AppModel.self) private var model
-    @Environment(\.dismiss) private var dismiss
-    let repo: RepoSnapshot
-    @State var group: String?
-    @State private var branch = ""
-    @State private var base = ""
-    @State private var isCreating = false
-    @State private var error: String?
-
-    var body: some View {
-        VStack(alignment: .leading, spacing: 14) {
-            Text("New Row in \(repo.name)")
-                .font(.headline)
-            Form {
-                TextField("Branch", text: $branch, prompt: Text("feat/my-change"))
-                TextField("Start from", text: $base, prompt: Text("origin's default branch"))
-                if !repo.groups.isEmpty {
-                    Picker("Group", selection: $group) {
-                        Text("No Group").tag(String?.none)
-                        Divider()
-                        ForEach(repo.groups) { group in
-                            Text(group.name).tag(Optional(group.name))
-                        }
-                    }
-                }
-            }
-            .formStyle(.columns)
-            .disabled(isCreating)
-            if let error {
-                Text(error)
-                    .font(.callout)
-                    .foregroundStyle(.red)
-                    .fixedSize(horizontal: false, vertical: true)
-            }
-            HStack {
-                if isCreating {
-                    ProgressView().controlSize(.small)
-                }
-                Spacer()
-                Button("Cancel", role: .cancel) { dismiss() }
-                    .keyboardShortcut(.cancelAction)
-                Button("Create Row", action: create)
-                    .keyboardShortcut(.defaultAction)
-                    .disabled(trimmedBranch.isEmpty || isCreating)
-            }
-        }
-        .padding(20)
-        .frame(width: 420)
-    }
-
-    private var trimmedBranch: String {
-        branch.trimmingCharacters(in: .whitespaces)
-    }
-
-    private func create() {
-        isCreating = true
-        error = nil
-        let base = base.trimmingCharacters(in: .whitespaces)
-        Task {
-            error = await model.createRow(
-                in: repo, branch: trimmedBranch, base: base.isEmpty ? nil : base, group: group)
-            isCreating = false
-            if error == nil {
-                dismiss()
-            }
-        }
-    }
-}
-
 struct RemoveRowPopover: View {
     @Environment(AppModel.self) private var model
     let row: Row
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```diff
@@ -25,7 +25,7 @@ struct SidebarView: View {
             }
         }
         .sheet(item: $newRow) { request in
-            NewRowSheet(repo: request.repo, group: request.group)
+            NewRowSheet(repo: request.repo, group: request.group, sources: model.newRowSources(for: request.repo))
         }
     }
 
```


- [ ] **Step 2: Build with no warnings**

Run: `swift build 2>&1 | grep -E 'warning:|error:'`
Expected: nothing.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: pick a PR or branch in the New Row sheet"
```

## Task 7: The fixture, end-to-end cases, and the specs

**Files:**
- Modify: `scripts/ui-fixture.sh`, `scripts/ui.swift`, `scripts/e2e.sh`, `docs/superpowers/specs/2026-09-27-canopy-design.md`, `docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md`

- [ ] **Step 1: A local GitHub in the UI fixture, end-to-end cases, and a driver that can bring the app forward**

web-app and api-server get bare origins in `$work/remotes`, which the app's git reaches at `https://github.com/` through a URL rewrite it is launched with.
web-app's origin has open PRs with and without rows, a fork PR from `jordan/web-app`, and branches that are only on origin, only here, behind, ahead, and diverged, dated hours and days ago so the ages read naturally.
The stand-in gh answers the badge query, the list query, and a PR's lookup from one table per repo.

In `e2e.sh` the PR stand-in answers the list query too, and new steps cover `pr list` with and without `--query` and `--closed`, a closed PR looked up by number, `pr show` and `pr` alone, and `branch list` with and without `--no-fetch` and `--query`.

Since macOS 14 an app in the background cannot hand the front to another, so `ui activate` could not bring the dev build forward from an agent's terminal.
It now clicks the window's empty title strip when asking is not enough, and only when the dev build's window is the frontmost window at that point, so a click never lands on another app or on the lock screen.

`scripts/e2e.sh`:

```diff
@@ -560,15 +560,16 @@ author switch -q -c feat/fork main
 author commit -q --allow-empty -m "a fix from a fork"
 author push -q "$work/remotes/someone/shop.git" feat/fork
 author push -q origin feat/fork:refs/pull/22/head
-write_pr() { # number, head branch, head owner, maintainerCanModify
-    /usr/bin/python3 - "$work/prs/$1.json" "$1" "$2" "$3" "$4" "$(author rev-parse "$2")" <<'EOF'
+write_pr() { # number, head branch, head owner, maintainerCanModify, state (default OPEN)
+    /usr/bin/python3 - "$work/prs/$1.json" "$1" "$2" "$3" "$4" "${5:-OPEN}" "$(author rev-parse "$2")" <<'EOF'
 import json, sys
-path, number, branch, owner, editable, oid = sys.argv[1:]
+path, number, branch, owner, editable, state, oid = sys.argv[1:]
 json.dump({"number": int(number), "title": f"PR {number}", "url": f"https://github.com/acme/shop/pull/{number}",
-           "state": "OPEN", "isDraft": False, "updatedAt": "2026-09-28T00:00:00Z", "headRefName": branch,
+           "state": state, "isDraft": False, "updatedAt": f"2026-09-28T00:00:{number}Z", "headRefName": branch,
            "headRefOid": oid, "headRef": {"name": branch}, "baseRefName": "main",
            "isCrossRepository": owner != "acme", "maintainerCanModify": editable == "true",
-           "headRepository": {"name": "shop"}, "headRepositoryOwner": {"login": owner}}, open(path, "w"))
+           "headRepository": {"name": "shop"}, "headRepositoryOwner": {"login": owner},
+           "author": {"login": owner}}, open(path, "w"))
 EOF
 }
 write_pr 21 feat/checkout acme false
@@ -592,6 +593,13 @@ if "maintainerCanModify" in query:
 def node(pr):
     return {key: pr[key] for key in ("number", "title", "url", "state", "isDraft", "updatedAt", "isCrossRepository")}
 everything = [load(name[:-5]) for name in os.listdir(prs)]
+if "pullRequests(states:" in query:
+    states = re.search(r"pullRequests\(states: \[([A-Z, ]*)\]", query).group(1).split(", ")
+    nodes = [dict(node(pr), headRefName=pr["headRefName"], author=pr["author"])
+             for pr in everything if pr["state"] in states]
+    nodes.sort(key=lambda n: n["updatedAt"], reverse=True)
+    print(json.dumps({"data": {"repository": {"pullRequests": {"nodes": nodes}}}}))
+    sys.exit(0)
 repo = {}
 for alias, number in re.findall(r"(b\d+): pullRequest\(number: (\d+)\)", query):
     if load(number) is None:
@@ -619,7 +627,7 @@ git clone -q "$work/remotes/acme/shop.git" "$work/shop"
 git -C "$work/shop" remote set-url origin https://github.com/acme/shop.git
 "$cli" repo add "$work/shop" >/dev/null
 field() { /usr/bin/python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))
-for key in sys.argv[2].split("."): v = v[key]
+for key in sys.argv[2].split("."): v = v[int(key)] if isinstance(v, list) else v[key]
 print(v)' "$@"; }
 "$cli" group new Review --repo shop >/dev/null
 "$cli" row new --pr 21 --repo shop --group Review --no-setup --json > "$work/pr21.json"
@@ -652,5 +660,49 @@ grep -q '"branch_not_found"' "$work/typo.json" || fail "missing branch_not_found
 if git -C "$work/shop" show-ref --verify --quiet refs/heads/feat/typo; then fail "--existing created a branch"; fi
 "$cli" agent-guide | grep -q "row new --pr" || fail "agent-guide is missing row new --pr"
 
+step "pr list shows the repo's PRs and the row that has each"
+author switch -q -c fix/old main
+author commit -q --allow-empty -m "an old fix"
+author push -q origin fix/old fix/old:refs/pull/23/head
+write_pr 23 fix/old acme false CLOSED
+"$cli" pr list --repo shop --json > "$work/prs.json"
+/usr/bin/python3 - "$work/prs.json" "$row21" <<'EOF' || fail "pr list is wrong"
+import json, sys
+prs, row21 = json.load(open(sys.argv[1])), sys.argv[2]
+assert [pr["number"] for pr in prs] == [22, 21], prs
+assert prs[1]["row"]["path"] == row21 and prs[1]["row"]["class"] == "canopy", prs[1]
+assert prs[0]["fork"] and prs[0]["row"]["branch"] == "feat/fork" and prs[0]["author"] == "someone", prs[0]
+EOF
+"$cli" pr list --repo shop | grep -Eq '^#21 +open .* in row +PR 21$' || fail "pr list printed $("$cli" pr list --repo shop)"
+"$cli" pr list --repo shop --query SOMEONE --json > "$work/someone.json"
+[[ "$(field "$work/someone.json" 0.number)" == 22 ]] || fail "pr list --query did not find PR 22 by its author"
+"$cli" pr list --repo shop --closed --json | grep -q '"number" : 23' || fail "pr list --closed is missing PR 23"
+if "$cli" pr list --repo shop --json | grep -q '"number" : 23'; then fail "pr list shows the closed PR 23"; fi
+"$cli" pr list --repo shop --query '#23' --json > "$work/pr23.json"
+[[ "$(field "$work/pr23.json" 0.state)" == closed && "$(field "$work/pr23.json" 0.row)" == None ]] ||
+    fail "pr list --query '#23' did not look up the closed PR"
+
+step "pr show is the default of canopy pr"
+"$cli" pr show feat/checkout --repo shop --json > "$work/show.json"
+[[ "$(field "$work/show.json" pr.number)" == 21 ]] || fail "pr show did not show PR 21"
+"$cli" pr feat/checkout --repo shop --json > "$work/show-default.json"
+[[ "$(field "$work/show-default.json" pr.number)" == 21 ]] || fail "canopy pr alone did not show PR 21"
+
+step "branch list shows local and origin branches, and fetches first"
+author push -q origin main:refs/heads/feat/just-pushed
+if "$cli" branch list --repo shop --no-fetch | grep -q feat/just-pushed; then fail "branch list --no-fetch fetched"; fi
+"$cli" branch list --repo shop --json > "$work/branches.json"
+/usr/bin/python3 - "$work/branches.json" "$row21" <<'EOF' || fail "branch list is wrong"
+import json, sys
+branches, row21 = {b["name"]: b for b in json.load(open(sys.argv[1]))}, sys.argv[2]
+assert branches["feat/just-pushed"]["where"] == "origin" and branches["feat/just-pushed"]["row"] is None, branches
+assert branches["feat/checkout"]["where"] == "both" and branches["feat/checkout"]["row"]["path"] == row21, branches
+assert branches["feat/local"]["where"] == "local" and branches["feat/local"]["row"]["class"] == "canopy", branches
+assert branches["main"]["row"]["class"] == "main", branches
+EOF
+"$cli" branch list --repo shop --query "just push" | grep -Eq '^feat/just-pushed +origin ' ||
+    fail "branch list --query printed $("$cli" branch list --repo shop --query "just push")"
+"$cli" agent-guide | grep -q "canopy branch list" || fail "agent-guide is missing branch list"
+
 echo
 echo "e2e passed"
```

`scripts/ui-fixture.sh`:

```diff
@@ -6,10 +6,13 @@
 #   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
 #   scripts/ui-fixture.sh stop           quit it and delete its folder
 #
-# PR badges and the clone sheet's repo list come from a stand-in gh, which the app finds first on its login PATH through
-# a fixture ZDOTDIR. It clones acme/billing and acme/design-system from local bare repos in $work/remotes, and fails
-# like gh for any other repo. Writing "logged-out" to $work/bin/gh-mode makes it answer like a gh with no login, and
-# writing a number of seconds to $work/bin/clone-seconds makes clones show git's progress for that long.
+# PR badges, the New Row sheet's PRs, and the clone sheet's repo list come from a stand-in gh, which the app finds first
+# on its login PATH through a fixture ZDOTDIR. It clones acme/billing and acme/design-system from local bare repos in
+# $work/remotes, and fails like gh for any other repo. Writing "logged-out" to $work/bin/gh-mode makes it answer like a
+# gh with no login, and writing a number of seconds to $work/bin/clone-seconds makes clones show git's progress for that
+# long. web-app and api-server have origins on GitHub, which the app's git reaches in $work/remotes through a URL
+# rewrite: web-app's has open PRs with and without rows, one from a fork, and branches that are only on origin, only
+# here, behind, ahead, and diverged.
 #
 # UI_FIXTURE_HOOKS_OFFER=1 gives it a Claude Code config folder of its own, so it offers to install its hooks.
 set -euo pipefail
@@ -89,21 +92,58 @@ if "viewer" in query:
     nodes = [{"nameWithOwner": n, "description": d, "isPrivate": p, "pushedAt": pushed(h)} for n, d, p, h in repos]
     print(json.dumps({"data": {"viewer": {"repositories": {"nodes": nodes}}}}))
     sys.exit(0)
-prs = {
-    "feat/onboarding-flow": (142, "Onboarding in three steps", "OPEN", True),
-    "fix/login-redirect": (139, "Keep the page after logging in", "MERGED", False),
-    "feat/checkout-redesign": (145, "Split checkout into steps", "OPEN", False),
-    "spike/new-parser": (131, "Try a new parser", "CLOSED", False),
-}
+from datetime import datetime, timedelta, timezone
+def ago(hours):
+    return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
+# number, title, state, draft, head branch, author, the fork it comes from, and hours since it was updated.
+PRS = {"acme/web-app": [
+    (145, "Split checkout into steps", "OPEN", False, "feat/checkout-redesign", "maya", None, 1),
+    (147, "Filter search results by price", "OPEN", False, "feat/search-filters", "priya", None, 3),
+    (142, "Onboarding in three steps", "OPEN", True, "feat/onboarding-flow", "sam", None, 5),
+    (148, "Round cart totals to the cent", "OPEN", False, "fix/cart-rounding", "jordan", "jordan", 20),
+    (150, "Refresh the README", "OPEN", True, "docs/readme-refresh", "alex", None, 50),
+    (139, "Keep the page after logging in", "MERGED", False, "fix/login-redirect", "sam", None, 30),
+    (131, "Try a new parser", "CLOSED", False, "spike/new-parser", "maya", None, 200),
+]}
+owner, name = re.search(r'repository\(owner: "([^"]*)", name: "([^"]*)"\)', query).groups()
+prs = PRS.get(f"{owner}/{name}", [])
+def node(pr):
+    number, title, state, draft, head, author, fork, hours = pr
+    return {"number": number, "title": title, "url": f"https://github.com/{owner}/{name}/pull/{number}",
+            "state": state, "isDraft": draft, "updatedAt": ago(hours), "headRefName": head,
+            "isCrossRepository": fork is not None, "author": {"login": author}}
+def find(number):
+    return next((pr for pr in prs if pr[0] == int(number)), None)
+def unresolved(number):
+    sys.stderr.write(f"gh: Could not resolve to a PullRequest with the number of {number}.\n")
+    sys.exit(1)
+if "maintainerCanModify" in query:
+    import subprocess
+    number = re.search(r"pullRequest\(number: (\d+)\)", query).group(1)
+    pr = find(number)
+    if pr is None:
+        print(json.dumps({"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": None}}}))
+        unresolved(number)
+    bare = os.path.join(here, "..", "remotes", owner, name + ".git")
+    oid = subprocess.run(["git", "--git-dir", bare, "rev-parse", f"refs/pull/{number}/head"],
+                         capture_output=True, text=True).stdout.strip()
+    fork = pr[6]
+    head = dict(node(pr), headRefOid=oid, headRef={"name": pr[4]}, baseRefName="main", maintainerCanModify=True,
+                headRepository={"name": name}, headRepositoryOwner={"login": fork or owner})
+    print(json.dumps({"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": head}}}))
+    sys.exit(0)
+if "pullRequests(states:" in query:
+    states = re.search(r"pullRequests\(states: \[([A-Z, ]*)\]", query).group(1).split(", ")
+    nodes = sorted((node(pr) for pr in prs if pr[2] in states), key=lambda n: n["updatedAt"], reverse=True)
+    print(json.dumps({"data": {"repository": {"pullRequests": {"nodes": nodes}}}}))
+    sys.exit(0)
 repo = {}
 for key, branch in re.findall(r'(b\d+): pullRequests\(headRefName: "([^"]*)"', query):
-    nodes = []
-    if branch in prs:
-        number, title, state, draft = prs[branch]
-        nodes.append({"number": number, "title": title, "url": f"https://github.com/acme/web-app/pull/{number}",
-                      "state": state, "isDraft": draft, "updatedAt": "2026-09-28T01:00:00Z",
-                      "isCrossRepository": False})
-    repo[key] = {"nodes": nodes}
+    repo[key] = {"nodes": [node(pr) for pr in prs if pr[4] == branch and pr[6] is None]}
+for key, number in re.findall(r"(b\d+): pullRequest\(number: (\d+)\)", query):
+    if find(number) is None:
+        unresolved(number)
+    repo[key] = node(find(number))
 print(json.dumps({"data": {"repository": repo}}))
 GH
 chmod +x "$work/bin/gh"
@@ -111,9 +151,12 @@ cat > "$work/zdot/.zshrc" <<ZSHRC
 export PATH="$work/bin:\$PATH"
 ZSHRC
 
+# A time some hours or days ago, such as 3H or 2d, for commits.
+ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }
 for repo in web-app api-server docs; do
     git init -q -b main "$work/$repo"
-    git -C "$work/$repo" -c user.email=ui@example.com -c user.name=ui commit -q --allow-empty -m init
+    GIT_AUTHOR_DATE=$(ago 6d) GIT_COMMITTER_DATE=$(ago 6d) \
+        git -C "$work/$repo" -c user.email=ui@example.com -c user.name=ui commit -q --allow-empty -m init
 done
 for repo in billing design-system; do
     git clone -q --bare "$work/web-app" "$work/remotes/acme/$repo.git"
@@ -122,7 +165,9 @@ done
 # Either appearance, whatever the Mac is set to.
 if [[ "${1:-dark}" == light ]]; then args=(-NSRequiresAquaSystemAppearance YES); else args=(-AppleInterfaceStyle Dark); fi
 # git may only use local repos, so a clone that falls back to plain git fails instead of reaching the network.
-(ZDOTDIR="$work/zdot" SHELL=/bin/zsh GIT_ALLOW_PROTOCOL=file \
+# The URL rewrite sends the app's git for https://github.com/ to the bare repos in $work/remotes.
+(ZDOTDIR="$work/zdot" SHELL=/bin/zsh GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=1 \
+    GIT_CONFIG_KEY_0="url.$work/remotes/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ \
     exec "$app/Contents/MacOS/Canopy" "${args[@]}" </dev/null >/dev/null 2>&1) &
 # Written at once, so `stop` can clean up even if a later step fails. The subshell execs, so $! is the app.
 printf 'pid=%s\nwork=%s\n' "$!" "$work" > "$state"
@@ -144,9 +189,51 @@ for repo in web-app api-server docs; do "$cli" repo add "$work/$repo" >/dev/null
 "$cli" row move chore/bump-deps --repo web-app --group Later >/dev/null
 git -C "$work/web-app" worktree add -q -b hotfix/cart-total "$work/elsewhere/cart-total"
 git -C "$work/web-app" worktree add -q -b spike/new-parser "$work/elsewhere/new-parser"
-# Remotes come after the rows, so creating the rows does not fetch. The stand-in gh answers for them.
+# Remotes come after the rows, so creating the rows does not fetch. Origins start as copies of the repos, rows and
+# all, and the stand-in gh answers for them.
+git clone -q --bare "$work/web-app" "$work/remotes/acme/web-app.git"
+git clone -q --bare "$work/api-server" "$work/remotes/acme/api-server.git"
+git clone -q --bare "$work/web-app" "$work/remotes/jordan/web-app.git"
+git clone -q "$work/remotes/acme/web-app.git" "$work/seed" 2>/dev/null
+seed() { git -C "$work/seed" -c user.email=ui@example.com -c user.name=ui "$@"; }
+# Pushes a branch of commits made at the times given, such as 3H or 2d, to acme/web-app, or to another repo.
+push_branch() { # branch, remote, times...
+    local branch=$1 remote=$2 when
+    shift 2
+    seed switch -q -c "$branch" origin/main
+    for when in "$@"; do
+        GIT_AUTHOR_DATE=$(ago "$when") GIT_COMMITTER_DATE=$(ago "$when") seed commit -q --allow-empty -m "$branch"
+    done
+    seed push -q "$remote" "$branch"
+}
+push_branch feat/search-filters origin 9H 6H 4H
+push_branch docs/readme-refresh origin 2d
+push_branch chore/ci-cache origin 26H
+push_branch refactor/cart-state origin 3d 30H
+push_branch feat/dark-mode origin 4d
+push_branch fix/cart-rounding "$work/remotes/jordan/web-app.git" 21H
+# GitHub keeps every PR's head at refs/pull/<number>/head of the base repo.
+for pr in 145:feat/checkout-redesign 147:feat/search-filters 142:feat/onboarding-flow 150:docs/readme-refresh \
+    139:fix/login-redirect 131:spike/new-parser 148:fix/cart-rounding; do
+    branch=${pr#*:}
+    tip=$(seed rev-parse --verify -q "refs/heads/$branch" || seed rev-parse "refs/remotes/origin/$branch")
+    seed push -q origin "$tip:refs/pull/${pr%%:*}/head"
+done
 git -C "$work/web-app" remote add origin https://github.com/acme/web-app.git
 git -C "$work/api-server" remote add origin https://github.com/acme/api-server.git
+for repo in web-app api-server; do
+    git -C "$work/$repo" -c "url.$work/remotes/.insteadOf=https://github.com/" fetch -q origin
+    git -C "$work/$repo" remote set-head origin main
+done
+# Local branches that are behind origin's, ahead, diverged, and only here, made without checking them out.
+local_commit() { # parent, time, message
+    GIT_AUTHOR_DATE=$(ago "$2") GIT_COMMITTER_DATE=$(ago "$2") \
+        git -C "$work/web-app" -c user.email=ui@example.com -c user.name=ui commit-tree -p "$1" -m "$3" "$1^{tree}"
+}
+git -C "$work/web-app" branch feat/search-filters origin/feat/search-filters~2
+git -C "$work/web-app" branch feat/dark-mode "$(local_commit origin/feat/dark-mode 2H "Dark mode toggle")"
+git -C "$work/web-app" branch refactor/cart-state "$(local_commit origin/refactor/cart-state~1 7H "Cart state")"
+git -C "$work/web-app" branch fix/typo-footer "$(local_commit main 45M "Footer typo")"
 "$cli" pr feat/onboarding-flow --repo web-app --refresh >/dev/null
 "$cli" pr feat/rate-limits --repo api-server --refresh >/dev/null || true
 "$cli" row select feat/checkout-redesign --repo web-app >/dev/null
```

`scripts/ui.swift`:

```diff
@@ -1,7 +1,8 @@
 // Drives a running Canopy for UI checks, alongside window-shot.swift. Build it once, since `swift` takes seconds to
 // start: swiftc -O -o build/ui scripts/ui.swift
 //
-//   ui activate <pid>                       bring the app to the front
+//   ui activate <pid>                       bring the app to the front, clicking its window's empty title strip
+//                                           when asking is not enough
 //   ui frame <pid>                          print the main window's frame in screen points
 //   ui key <pid> <keycode> [cmd] [shift] [opt] [ctrl]
 //   ui type <pid> <text>
@@ -55,6 +56,19 @@ func windowPoint(_ xIndex: Int) -> CGPoint {
     return CGPoint(x: frame.minX + number(xIndex), y: frame.minY + number(xIndex + 1))
 }
 
+/// The app whose window a click at `point` would land on: the frontmost on-screen window there, of any layer.
+func windowOwner(at point: CGPoint) -> pid_t? {
+    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
+    for window in windows {
+        guard let bounds = window[kCGWindowBounds as String],
+            let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary), frame.contains(point),
+            (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
+        else { continue }
+        return window[kCGWindowOwnerPID as String] as? pid_t
+    }
+    return nil
+}
+
 func requireFrontmost() {
     guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
         FileHandle.standardError.write(Data("refusing to \(args[0]): the app is not frontmost\n".utf8))
@@ -92,6 +106,18 @@ switch args[0] {
 case "activate":
     NSRunningApplication(processIdentifier: pid)?.activate()
     usleep(300_000)
+    // Since macOS 14 an app in the background cannot hand the front to another, but a click on a window still brings
+    // its app forward. The sidebar's title strip, right of the window buttons, does nothing else when clicked.
+    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
+        let frame = windowFrame()
+        let point = CGPoint(x: frame.minX + 200, y: frame.minY + 12)
+        if windowOwner(at: point) == pid {
+            mouse(.mouseMoved, at: point)
+            mouse(.leftMouseDown, at: point)
+            mouse(.leftMouseUp, at: point)
+            usleep(300_000)
+        }
+    }
     print(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? "front" : "not front")
 case "frame":
     print(windowFrame())
```


- [ ] **Step 2: Run them**

Run: `make e2e`
Expected: `e2e passed`.

- [ ] **Step 3: Update the specs**

The pull branches spec gains what building settled: the 100 PRs `pr list` shows, what `--query` matches, `--no-fetch`, the JSON fields, how a PR's row is found, the sheet's selection and lookup rules, and the `pr.list` and `branch.list` params.
The main spec's command table and "Creating a row" point at them.

- [ ] **Step 4: Commit**

```bash
git commit -m "test: pr list and branch list end to end, and a fixture for the New Row sheet"
git commit -m "docs: the list commands and the New Row sheet in the specs"
```

## UI Checks

All on `scripts/ui-fixture.sh` with `scripts/ui.swift` and window-only shots, each result checked with `canopy row list --json`.

In dark, against the dev build:

1. Opened the sheet from web-app's `+`: the five open PRs, two of them "In row", and thirteen branches with every tag.
2. Typed `search`: PR #147 and branch `feat/search-filters` (`local, 2 behind`), with the first selected.
   A click on the branch selected it.
3. Picked PR #147 by clicking it and Create Row: the row `feat/search-filters` appeared with badge #147 and was selected, and its branch was fast-forwarded to origin's commit.
4. Set the Group picker to Later, typed `ci-cache`, and double-clicked `chore/ci-cache` (`origin`): the row went into Later and tracks `origin/chore/ci-cache`.
5. Typed `onboarding`: PR #142 "In row", the button said Open Row and the Group picker was off.
   Return selected `feat/onboarding-flow` and created nothing.
6. Typed `feat/brand-new`, clicked the start point field, typed `origin/feat/dark-mode`, and pressed Return: a new branch at that commit, with no upstream.
7. Typed `zzz` and pressed Esc: the sheet closed and nothing changed.
8. Typed `cart-total`: `hotfix/cart-total` "Other worktree", and the button said Adopt.
   Adopt made it an adopted row.
9. Typed `#148` and pressed Return: the fork PR's row `fix/cart-rounding`, with badge #148, pushing to `https://github.com/jordan/web-app.git`.

In light, the sheet as it opens and loads, then `feat` and three presses of Down, which moved from #145 through #147 and #142 to `feat/dark-mode`, and Return created that row.

While the Mac was locked, the sheet was also rendered offscreen from the same `NewRowSheet.swift` with the fixture's own `pr list` and `branch list` output and real key events, for the loading state, the gh logged out warning, a repo not on GitHub, a PR looked up by number, and each note.

## After Review

An independent reviewer (opus) read `git diff main...feat/new-row-picker` against the spec and this plan.
It found three Important and eleven Minor issues, and nothing Critical.
Each was checked in the code before it was fixed, and each change in behavior has a test that failed first.
The fixes are one commit after Task 7, so the task code above is as first built.

1. **Important: Return could run a different item than the one the user meant.**
   Typing selected the first item, and the picker kept it while it stayed listed, even though the picker had chosen it rather than the user.
   Typing `139` for a closed PR selected "New branch ‘139’" until the lookup answered, and the PR then appeared above it with the new branch line still selected, so Return made a branch named 139.
   Typing `main` selected a PR that mentioned main rather than the branch named main.
   The picker now tells an item the user picked, with the arrows, a click, or the start point field, from the best match, and only a picked item stays put.
   The best match follows the answers as they arrive: the PR a number names, then a branch named exactly the text in any case, then the first item.
   A PR number no longer offers the new branch line at all.
   `theAutomaticSelectionFollowsTheBestMatch` reproduces both cases, and `anExplicitSelectionStaysPutWhenTheListRefreshes` replaces `theSelectionStaysPutWhenTheListRefreshes`.
2. **Important: VoiceOver's default action ran the selected item, not the line it was on.**
   It now selects that line first.
3. **Important: the local list was not shown at once in a repo with many branches.**
   Each branch on both sides with different commits ran its own `git rev-list`, one after another, before the sheet showed any branch.
   The listing now reads `%(upstream)` and `%(upstream:track,nobracket)` in its one `for-each-ref` call, and only a branch whose upstream is not its namesake on origin runs `rev-list`.
   `aBranchTrackingItsNamesakeNeedsNoProcessOfItsOwn` counts the processes.
4. **Minor: a lookup that failed stayed failed for as long as the sheet was open.**
   Failures are dropped when the text changes, so asking again tries again.
   `aFailedLookupIsTriedAgain` covers it.
5. **Minor: `12`, `#12`, and the PR's URL each asked gh.**
   Lookups are keyed by number, and by repo too for a URL.
   `aNumberIsLookedUpOnceHoweverItIsTyped` covers it.
6. **Minor: the primary button's command could be wrong.**
   A branch starting with `#` read as a shell comment, and `canopy row select main` named no repo.
   Commands now quote `#` and carry `--repo`.
7. **Minor: a PR could show another PR's row as "In row".**
   A same-repo PR from `fix` matched a row whose `fix` is bound to a fork's PR, whose badge that row shows.
   The head name match now skips a branch bound to another PR.
   `aBranchBoundToOnePullRequestIsNotAnothersRow` covers it.
8. **Minor: a repo whose folder is gone read as `not_github`.**
   `listPullRequests` now checks the folder first, as `listBranches` does, and fails with `path_not_found`.
   `aMissingRepoFolderSaysSo` covers it.
9. **Minor: the agent guide** said "the 100 most recently updated PRs" without saying open ones, and one of its lines ran wider than the rest.
10. **Minor: two e2e checks that something is absent** would pass if `canopy` itself failed.
    The output is now saved first, so a failing command fails the run.
11. **Minor: the local GitHub answered every repo's list query with the same PRs.**
    It now keeps a list per repo, and `listsOpenPullRequestsNewestFirst` opens a PR on another repo that must not show.
    `listsPullRequestsWithOneCall` also checks the order the query asks for.
12. **Minor: the sheet made a throwaway picker on every sidebar update**, since `State(initialValue:)` builds its value each time.
    The request that opens the sheet now makes the picker once.
13. **Minor: the line's tap gestures wrapped the start point field**, so a double click that selects a word there could run the line.
    The gestures now sit on the line's fill, behind its content, and only the field takes clicks itself.
    Checked live: a double click in the field selected a word and created nothing, while a click and a double click on a PR still selected it and created its row.
14. **Minor: the plan** had two sentences on some lines.

The reviewer confirmed that an older lookup never shows under newer text, the any-case check for the new branch line, how each PR's row is found, the branch listing's parsing and order, that the fetch in the git queue cannot deadlock, that Return cannot run twice, the Group picker, opening a row named by `branch_checked_out`, the JSON's nulls, that no test reaches the network, the scripts' quoting, and that the spec edits match the code.

The fix commit's tests:

`Tests/CanopyCoreTests/BranchListTests.swift`:

```diff
@@ -82,6 +82,30 @@ struct BranchListTests {
         #expect(branches["feat/behind"]?.committedAt == "2026-09-02T00:00:00Z")
     }
 
+    /// A branch tracking its namesake on origin is compared in the one listing git call, so a repo with many branches
+    /// behind origin does not start a process for each.
+    @Test func aBranchTrackingItsNamesakeNeedsNoProcessOfItsOwn() async throws {
+        let dir = try TempDir()
+        let (github, repo, workspace) = try await setUp(
+            dir, before: #"[[ "$1" == rev-list ]] && echo "$@" >> "\#(dir.sub("counts"))""#)
+        for branch in ["feat/one", "feat/two", "feat/three", "feat/untracked"] {
+            try await github.push(3, to: branch, of: "acme/app", date: "2026-09-02T00:00:00Z")
+        }
+        try await github.git.run(["fetch", "--quiet", "origin"], in: repo)
+        for branch in ["feat/one", "feat/two", "feat/three"] {
+            try await github.git.run(["branch", "--no-track", branch, "origin/\(branch)~1"], in: repo)
+            try await github.git.run(["branch", "--quiet", "--set-upstream-to", "origin/\(branch)", branch], in: repo)
+        }
+        try await github.git.run(["branch", "--no-track", "feat/untracked", "origin/feat/untracked~2"], in: repo)
+
+        let branches = try await workspace.listBranches(repoPath: repo, fetch: false).branches
+
+        #expect(branches.filter { $0.behind == 1 }.map(\.name).sorted() == ["feat/one", "feat/three", "feat/two"])
+        #expect(branches.first { $0.name == "feat/untracked" }?.behind == 2)
+        let counts = (try? String(contentsOfFile: dir.sub("counts"), encoding: .utf8)) ?? ""
+        #expect(counts.split(separator: "\n").count == 1)
+    }
+
     @Test func labelsSayWhereABranchIs() {
         func label(_ location: BranchLocation, _ ahead: Int? = nil, _ behind: Int? = nil) -> String {
             ListedBranch(name: "x", location: location, ahead: ahead, behind: behind, committedAt: "").label
```

`Tests/CanopyCoreTests/GitHubCLITests.swift`:

```diff
@@ -238,6 +238,7 @@ struct GitHubCLITests {
         let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8).split(separator: "\n")
         #expect(Array(args.prefix(3)) == ["api", "graphql", "-f"])
         #expect(args.dropFirst(3).first?.contains("states: [OPEN, CLOSED, MERGED]") == true)
+        #expect(args.dropFirst(3).first?.contains("orderBy: {field: UPDATED_AT, direction: DESC}") == true)
     }
 
     @Test func aPullRequestListSaysWhyGHCannotAnswer() async throws {
```

`Tests/CanopyCoreTests/NewRowPickerTests.swift`:

```diff
@@ -33,6 +33,8 @@ final class FakeLists: Sendable {
         var pullRequests: Result<[ListedPullRequest], WorkspaceError> = .success([])
         var lookups: [String: [ListedPullRequest]] = [:]
         var lookupGates: [String: Gate] = [:]
+        /// Lookups that fail once, then answer from `lookups`.
+        var lookupFailures: [String: WorkspaceError] = [:]
         var local = BranchListing(branches: [], defaultBase: "origin/main")
         var fetched: BranchListing?
         var fetchGate: Gate?
@@ -48,6 +50,9 @@ final class FakeLists: Sendable {
                 let (gate, result) = self.state.withLock { state in
                     state.queries.append(query)
                     guard let query else { return (state.pullRequestGate, state.pullRequests) }
+                    if let failure = state.lookupFailures.removeValue(forKey: query) {
+                        return (state.lookupGates[query], .failure(failure))
+                    }
                     let found = state.lookups[query.trimmingCharacters(in: .whitespaces)] ?? []
                     return (state.lookupGates[query], state.pullRequests.map { _ in found })
                 }
@@ -216,7 +221,7 @@ struct NewRowPickerTests {
         await picker.load()
 
         for (text, shown) in [
-            ("feat/new", true), (" feat/new ", true), ("12", true), ("feat/login", false), ("", false),
+            ("feat/new", true), (" feat/new ", true), ("12", false), ("feat/login", false), ("", false),
             ("bad name", false), ("#12", false), ("feat/x.lock", false), ("https://github.com/acme/app/pull/1", false),
         ] {
             picker.text = text
@@ -281,7 +286,7 @@ struct NewRowPickerTests {
         #expect(picker.selectedItem?.id == "branch/feat/b")
     }
 
-    @Test func theSelectionStaysPutWhenTheListRefreshes() async throws {
+    @Test func anExplicitSelectionStaysPutWhenTheListRefreshes() async throws {
         let lists = FakeLists()
         let prGate = Gate()
         let fetchGate = Gate()
@@ -298,18 +303,94 @@ struct NewRowPickerTests {
 
         picker.text = "feat"
         #expect(picker.selectedItem?.id == "branch/feat/a")
+        picker.moveSelection(by: 1)
+        #expect(picker.selectedItem?.id == "branch/feat/b")
         await prGate.open()
         #expect(await eventually { ids(picker.pullRequestItems) == ["pr/3"] })
-        #expect(picker.selectedItem?.id == "branch/feat/a")
+        #expect(picker.selectedItem?.id == "branch/feat/b")
         await fetchGate.open()
         await loading.value
         #expect(ids(picker.branchItems).first == "branch/feat/new")
-        #expect(picker.selectedItem?.id == "branch/feat/a")
+        #expect(picker.selectedItem?.id == "branch/feat/b")
 
-        picker.text = "feat/b"
+        // A picked item that goes away gives way to the best match.
         lists.state.withLock { $0.fetched = listing([branch("feat/a")]) }
         await picker.refreshBranches()
-        #expect(picker.selectedItem?.id == "new")
+        #expect(picker.selectedItem?.id == "pr/3")
+    }
+
+    @Test func theAutomaticSelectionFollowsTheBestMatch() async throws {
+        let lists = FakeLists()
+        let prGate = Gate()
+        let lookupGate = Gate()
+        lists.state.withLock {
+            $0.pullRequests = .success([pr(145, "Fix the main menu", head: "feat/menu"), pr(3, head: "feat/c")])
+            $0.pullRequestGate = prGate
+            $0.lookups = ["139": [pr(139, head: "fix/old", state: .closed)]]
+            $0.lookupGates = ["139": lookupGate]
+            $0.local = listing([branch("feat/menu"), branch("main")])
+        }
+        let picker = makePicker(lists)
+        let loading = Task { await picker.load() }
+        #expect(await eventually { !picker.branchItems.isEmpty })
+
+        // Partial text selects the first item, and follows the first item as answers arrive.
+        picker.text = "feat"
+        #expect(picker.selectedItem?.id == "branch/feat/menu")
+        // A PR number typed before the open PRs arrive offers nothing to create by mistake.
+        picker.text = "145"
+        #expect(picker.items.isEmpty && picker.selectedItem == nil)
+        await prGate.open()
+        await loading.value
+        #expect(picker.selectedItem?.id == "pr/145")
+        picker.text = "feat"
+        #expect(picker.selectedItem?.id == "pr/145")
+
+        // A closed PR's number, whose lookup answers late.
+        picker.text = "139"
+        #expect(picker.items.isEmpty && picker.selectedItem == nil)
+        await lookupGate.open()
+        #expect(await eventually { picker.selectedItem?.id == "pr/139" })
+
+        // A branch named exactly what was typed, in any case, beats a PR that only mentions it.
+        picker.text = "MAIN"
+        #expect(ids(picker.items).first == "pr/145")
+        #expect(picker.selectedItem?.id == "branch/main")
+    }
+
+    @Test func aNumberIsLookedUpOnceHoweverItIsTyped() async throws {
+        let lists = FakeLists()
+        lists.state.withLock { $0.lookups = ["40": [pr(40, head: "feat/old", state: .closed)]] }
+        let picker = makePicker(lists)
+        await picker.load()
+
+        picker.text = "40"
+        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/40"] })
+        picker.text = "#40"
+        #expect(ids(picker.pullRequestItems) == ["pr/40"])
+        try await Task.sleep(for: .milliseconds(100))
+        #expect(lists.queries == [nil, "40"])
+    }
+
+    @Test func aFailedLookupIsTriedAgain() async throws {
+        let lists = FakeLists()
+        lists.state.withLock {
+            $0.lookups = ["#40": [pr(40, head: "feat/old", state: .closed)]]
+            $0.lookupFailures = ["#40": .ghFailed("gh did not answer in time.")]
+        }
+        let picker = makePicker(lists)
+        await picker.load()
+
+        picker.text = "#40"
+        #expect(
+            await eventually {
+                picker.pullRequestNote
+                    == .init(kind: .warning, text: "Pull requests did not load: gh did not answer in time.")
+            })
+        picker.text = "#4"
+        picker.text = "#40"
+        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/40"] })
+        #expect(lists.queries.filter { $0 == "#40" }.count == 2)
     }
 
     @Test func eachItemMapsToOneCommand() {
@@ -317,25 +398,31 @@ struct NewRowPickerTests {
         let main = BranchHolder(path: "/r/app", branch: "main", rowClass: .main)
         let other = BranchHolder(path: "/tmp/my worktree", branch: "feat/z", rowClass: .external)
         let cases: [(NewRowItem, String?, NewRowAction, String)] = [
-            (.pullRequest(pr(12, head: "fix/cart")), nil, .pullRequest(12), "canopy row new --pr 12"),
-            (.branch(branch("feat/y")), nil, .branch("feat/y"), "canopy row new feat/y --existing"),
-            (.newBranch("feat/n"), nil, .newBranch("feat/n", base: nil), "canopy row new feat/n"),
+            (.pullRequest(pr(12, head: "fix/cart")), nil, .pullRequest(12), "canopy row new --pr 12 --repo web-app"),
+            (.branch(branch("feat/y")), nil, .branch("feat/y"), "canopy row new feat/y --existing --repo web-app"),
+            (.newBranch("feat/n"), nil, .newBranch("feat/n", base: nil), "canopy row new feat/n --repo web-app"),
             (
                 .newBranch("feat/n"), "origin/dev", .newBranch("feat/n", base: "origin/dev"),
-                "canopy row new feat/n --from origin/dev"
+                "canopy row new feat/n --from origin/dev --repo web-app"
             ),
-            (.branch(branch("feat/x", row: row)), nil, .selectRow(row), "canopy row select feat/x"),
-            (.pullRequest(pr(9, head: "feat/x", row: row)), nil, .selectRow(row), "canopy row select feat/x"),
-            (.branch(branch("main", row: main)), nil, .selectRow(main), "canopy row select main"),
+            (.branch(branch("feat/x", row: row)), nil, .selectRow(row), "canopy row select feat/x --repo web-app"),
+            (
+                .pullRequest(pr(9, head: "feat/x", row: row)), nil, .selectRow(row),
+                "canopy row select feat/x --repo web-app"
+            ),
+            (.branch(branch("main", row: main)), nil, .selectRow(main), "canopy row select main --repo web-app"),
             (.branch(branch("feat/z", row: other)), nil, .adopt(other), "canopy row adopt '/tmp/my worktree'"),
         ]
         for (item, base, action, command) in cases {
             #expect(item.action(base: base) == action, "\(item.id)")
-            #expect(action.command == command)
+            #expect(action.command(repo: "web-app") == command)
         }
         #expect(NewRowAction.pullRequest(1).createsRow && NewRowAction.newBranch("x", base: nil).createsRow)
         #expect(!NewRowAction.selectRow(row).createsRow && !NewRowAction.adopt(other).createsRow)
-        #expect(NewRowAction.branch("it's").command == #"canopy row new 'it'\''s' --existing"#)
+        #expect(
+            NewRowAction.branch("it's").command(repo: "a b") == #"canopy row new 'it'\''s' --existing --repo 'a b'"#)
+        // A word starting with # would read as a comment.
+        #expect(NewRowAction.branch("#hotfix").command(repo: "app") == "canopy row new '#hotfix' --existing --repo app")
     }
 
     @Test func theNewBranchLineStartsFromTheTypedBase() async throws {
```

`Tests/CanopyCoreTests/PullRequestListTests.swift`:

```diff
@@ -25,6 +25,10 @@ struct PullRequestListTests {
         try await github.openPR(1, on: "acme/app", from: "feat/a", updatedAt: "2026-09-28T01:00:00Z")
         try await github.openPR(2, on: "acme/app", from: "feat/b", author: nil, updatedAt: "2026-09-28T03:00:00Z")
         try await github.openPR(3, on: "acme/app", from: "feat/c", state: "MERGED", updatedAt: "2026-09-28T02:00:00Z")
+        // Another repo's PR is not this repo's.
+        try await github.createRepo("acme/other")
+        try await github.push(to: "feat/elsewhere", of: "acme/other")
+        try await github.openPR(4, on: "acme/other", from: "feat/elsewhere", updatedAt: "2026-09-28T04:00:00Z")
 
         let open = try await workspace.listPullRequests(repoPath: repo)
         let all = try await workspace.listPullRequests(repoPath: repo, includeClosed: true)
@@ -141,6 +145,34 @@ struct PullRequestListTests {
         #expect(try await workspace.listPullRequests(repoPath: repo).first?.row == nil)
     }
 
+    @Test func aBranchBoundToOnePullRequestIsNotAnothersRow() async throws {
+        let dir = try TempDir()
+        let (github, repo, workspace) = try await setUp(dir)
+        try await github.fork("acme/app", as: "someone/app")
+        try await github.push(to: "fix", of: "someone/app")
+        try await github.openPR(7, on: "acme/app", from: "fix", of: "someone/app")
+        let row = try await workspace.createRow(repoPath: repo, pullRequest: PRReference(number: 7)).row
+        try await github.push(to: "fix", of: "acme/app")
+        try await github.openPR(9, on: "acme/app", from: "fix")
+
+        let holders = Dictionary(
+            uniqueKeysWithValues: try await workspace.listPullRequests(repoPath: repo).map { ($0.number, $0.row) })
+
+        #expect(row.branch == "fix")
+        #expect(holders[7] == BranchHolder(row))
+        #expect(holders[9] == .some(nil))
+    }
+
+    @Test func aMissingRepoFolderSaysSo() async throws {
+        let dir = try TempDir()
+        let (_, repo, workspace) = try await setUp(dir)
+        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
+
+        await #expect(throws: WorkspaceError.pathNotFound(repo)) {
+            try await workspace.listPullRequests(repoPath: repo)
+        }
+    }
+
     @Test func ghProblemsAreTheSidebarsErrors() async throws {
         let dir = try TempDir()
         let (github, repo, workspace) = try await setUp(dir)
```

`Tests/CanopyCoreTests/Support/LocalGitHub.swift`:

```diff
@@ -36,8 +36,15 @@ struct LocalGitHub {
                 echo "gh: Could not resolve to a PullRequest with the number of $number." >&2
                 exit 1
             fi
-            if [[ "$query" == *"pullRequests(states: [OPEN],"* ]]; then cat "\(dir.sub("gh-list-open"))"; exit 0; fi
-            if [[ "$query" == *"pullRequests(states:"* ]]; then cat "\(dir.sub("gh-list-all"))"; exit 0; fi
+            repo=$(sed -nE 's/.*repository\\(owner: "([^"]*)", name: "([^"]*)"\\).*/\\1\\/\\2/p' <<< "$query")
+            if [[ "$query" == *"pullRequests(states: [OPEN],"* ]]; then list=open
+            elif [[ "$query" == *"pullRequests(states:"* ]]; then list=all
+            fi
+            if [[ -n "${list:-}" ]]; then
+                cat "\(dir.sub("gh-lists"))/$repo/$list.json" 2>/dev/null ||
+                    echo '{"data": {"repository": {"pullRequests": {"nodes": []}}}}'
+                exit 0
+            fi
             printf '%s\\n' "$query" >> "\(dir.sub("gh-calls"))"
             for number in $(grep -oE 'pullRequest\\(number: [0-9]+\\)' <<< "$query" | grep -oE '[0-9]+'); do
                 if [[ ! -f "\(dir.sub("gh-prs"))/$number.json" ]]; then
@@ -142,7 +149,7 @@ struct LocalGitHub {
         try? writeLists()
     }
 
-    /// What gh answers for the list of open PRs and of all PRs, most recently updated first.
+    /// What gh answers for each repo's list of open PRs and of all its PRs, most recently updated first.
     private func writeLists() throws {
         let names = try FileManager.default.contentsOfDirectory(atPath: prs).filter { $0.hasSuffix(".json") }
         let all = try names.compactMap {
@@ -153,12 +160,22 @@ struct LocalGitHub {
         let fields = [
             "number", "title", "url", "state", "isDraft", "updatedAt", "headRefName", "isCrossRepository", "author",
         ]
-        for (file, states) in [("gh-list-open", ["OPEN"]), ("gh-list-all", ["OPEN", "CLOSED", "MERGED"])] {
-            let nodes = all.filter { states.contains($0["state"] as? String ?? "") }.map {
-                $0.filter { fields.contains($0.key) }
+        // A PR's URL names the repo it was opened on: https://github.com/<owner>/<name>/pull/<number>.
+        func base(_ pr: [String: Any]) -> String {
+            ((pr["url"] as? String) ?? "").split(separator: "/").dropFirst(2).prefix(2).joined(separator: "/")
+        }
+        try? FileManager.default.removeItem(atPath: dir.sub("gh-lists"))
+        for repo in Set(all.map(base)) {
+            let folder = dir.sub("gh-lists/\(repo)")
+            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
+            for (file, states) in [("open", ["OPEN"]), ("all", ["OPEN", "CLOSED", "MERGED"])] {
+                let nodes = all.filter { base($0) == repo && states.contains($0["state"] as? String ?? "") }.map {
+                    $0.filter { fields.contains($0.key) }
+                }
+                let reply = ["data": ["repository": ["pullRequests": ["nodes": nodes]]]]
+                try JSONSerialization.data(withJSONObject: reply).write(
+                    to: URL(fileURLWithPath: "\(folder)/\(file).json"))
             }
-            let reply = ["data": ["repository": ["pullRequests": ["nodes": nodes]]]]
-            try JSONSerialization.data(withJSONObject: reply).write(to: URL(fileURLWithPath: dir.sub(file)))
         }
     }
 
```


Its code:

`Sources/CanopyApp/Sidebar/NewRowSheet.swift`:

```diff
@@ -8,15 +8,15 @@ struct NewRowSheet: View {
     @Environment(\.dismiss) private var dismiss
     let repo: RepoSnapshot
     @State var group: String?
-    @State private var picker: NewRowPicker
+    let picker: NewRowPicker
     @State private var isWorking = false
     @State private var error: String?
     @FocusState private var isFieldFocused: Bool
 
-    init(repo: RepoSnapshot, group: String?, sources: NewRowPicker.Sources) {
+    init(repo: RepoSnapshot, group: String?, picker: NewRowPicker) {
         self.repo = repo
         _group = State(initialValue: group)
-        _picker = State(initialValue: NewRowPicker(sources: sources))
+        self.picker = picker
     }
 
     var body: some View {
@@ -70,7 +70,7 @@ struct NewRowSheet: View {
                 Button(primaryTitle, action: runSelected)
                     .keyboardShortcut(.defaultAction)
                     .disabled(picker.selectedAction == nil || isWorking)
-                    .help(picker.selectedAction?.command ?? "")
+                    .help(picker.selectedAction?.command(repo: repo.name) ?? "")
             }
         }
         .padding(20)
@@ -174,17 +174,27 @@ private struct ItemLine: View {
         HStack(alignment: .center, spacing: 8) {
             content
         }
+        // Only the start point field takes clicks itself. Everything else lets them through to the fill below.
+        .allowsHitTesting(isNewBranch)
         .padding(.horizontal, 8)
         .frame(height: height)
-        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
-        .contentShape(Rectangle())
-        .onTapGesture(perform: select)
-        .simultaneousGesture(TapGesture(count: 2).onEnded(run))
+        // Clicks select and double clicks run from the fill, which sits behind the start point field rather than
+        // around it, so a double click that selects a word there never runs the line.
+        .background {
+            RoundedRectangle(cornerRadius: Style.cornerRadius)
+                .fill(fill)
+                .contentShape(Rectangle())
+                .onTapGesture(perform: select)
+                .simultaneousGesture(TapGesture(count: 2).onEnded(run))
+        }
         .onHover { isHovering = $0 }
         // The new branch line keeps its start point field reachable on its own.
         .accessibilityElement(children: isNewBranch ? .contain : .combine)
         .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
-        .accessibilityAction(.default, run)
+        .accessibilityAction {
+            select()
+            run()
+        }
     }
 
     private var isNewBranch: Bool {
@@ -257,11 +267,13 @@ private struct ItemLine: View {
                 .font(.system(size: 11, weight: .semibold))
                 .foregroundStyle(.secondary)
                 .frame(width: 14)
+                .allowsHitTesting(false)
             (Text("New branch ") + Text(verbatim: "‘\(name)’").fontWeight(.medium) + Text(" from"))
                 .font(Style.row)
                 .lineLimit(1)
                 .truncationMode(.middle)
                 .layoutPriority(1)
+                .allowsHitTesting(false)
             TextField("Start from", text: $base, prompt: Text(verbatim: defaultBase ?? "origin's default branch"))
                 .textFieldStyle(.roundedBorder)
                 .controlSize(.small)
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```diff
@@ -25,7 +25,7 @@ struct SidebarView: View {
             }
         }
         .sheet(item: $newRow) { request in
-            NewRowSheet(repo: request.repo, group: request.group, sources: model.newRowSources(for: request.repo))
+            NewRowSheet(repo: request.repo, group: request.group, picker: request.picker)
         }
     }
 
@@ -63,7 +63,10 @@ struct SidebarView: View {
                             get: { expanded.contains(repo.path) },
                             set: { if $0 { expanded.insert(repo.path) } else { expanded.remove(repo.path) } }),
                         isFocused: isFocused,
-                        onNewRow: { newRow = NewRowRequest(repo: repo, group: $0) }
+                        onNewRow: {
+                            newRow = NewRowRequest(
+                                repo: repo, group: $0, picker: NewRowPicker(sources: model.newRowSources(for: repo)))
+                        }
                     )
                 }
             }
@@ -113,6 +116,8 @@ struct SidebarView: View {
 struct NewRowRequest: Identifiable {
     let repo: RepoSnapshot
     let group: String?
+    /// Made here, once per sheet, since the sheet's view is made again whenever the sidebar updates.
+    let picker: NewRowPicker
 
     var id: String { repo.path }
 }
```

`Sources/CanopyCLI/AgentGuide.swift`:

```diff
@@ -117,13 +117,14 @@ struct AgentGuide: ParsableCommand {
         once a minute and more often right after a push. `--refresh` asks GitHub now, for example right after
         `gh pr create`. `row list --json` also carries each row's PR as "pr" when it has one.
 
-        `pr list` shows the 100 most recently updated PRs. `--query` keeps those whose number, title, head branch, or
-        author holds each word, and a number, #number, or URL looks that PR up even when it is closed. `branch list`
-        fetches origin first, unless you pass `--no-fetch`. It says where each branch is ("where": local, origin, or
-        both) and how many commits the local branch is "ahead" of or "behind" origin's. In both lists "row" is the
-        row or worktree that has the item checked out, or null. Start a row on an item without one with `row new --pr <n>` or
-        `row new <branch> --existing`, show one that has a row with `row select`, and adopt one in another tool's
-        worktree ("class": "external") with `row adopt <path>`. These are the lists the New Row sheet shows.
+        `pr list` shows the 100 most recently updated open PRs, or PRs in any state with `--closed`. `--query` keeps
+        those whose number, title, head branch, or author holds each word, and a number, #number, or URL looks that PR
+        up even when it is closed. `branch list` fetches origin first, unless you pass `--no-fetch`. It says where each
+        branch is ("where": local, origin, or both) and how many commits the local branch is "ahead" of or "behind"
+        origin's. In both lists "row" is the row or worktree that has the item checked out, or null. Start a row on an
+        item without one with `row new --pr <n>` or `row new <branch> --existing`, show one that has a row with
+        `row select`, and adopt one in another tool's worktree ("class": "external") with `row adopt <path>`. These
+        are the lists the New Row sheet shows.
 
         ## Activity
 
```

`Sources/CanopyCore/Rows/NewRowPicker.swift`:

```diff
@@ -21,13 +21,16 @@ public enum NewRowAction: Equatable, Sendable {
         }
     }
 
-    public var command: String {
+    /// The command that does the same in `repo`, quoted for a shell. Adopting names the worktree by its path, which
+    /// needs no repo.
+    public func command(repo: String) -> String {
         let words: [String] =
             switch self {
-            case .pullRequest(let number): ["row", "new", "--pr", "\(number)"]
-            case .branch(let name): ["row", "new", name, "--existing"]
-            case .newBranch(let name, let base): ["row", "new", name] + (base.map { ["--from", $0] } ?? [])
-            case .selectRow(let row): ["row", "select", row.branch ?? row.path]
+            case .pullRequest(let number): ["row", "new", "--pr", "\(number)", "--repo", repo]
+            case .branch(let name): ["row", "new", name, "--existing", "--repo", repo]
+            case .newBranch(let name, let base):
+                ["row", "new", name] + (base.map { ["--from", $0] } ?? []) + ["--repo", repo]
+            case .selectRow(let row): ["row", "select", row.branch ?? row.path, "--repo", repo]
             case .adopt(let worktree): ["row", "adopt", worktree.path]
             }
         return (["canopy"] + words.map(Self.quoted)).joined(separator: " ")
@@ -35,7 +38,7 @@ public enum NewRowAction: Equatable, Sendable {
 
     /// `word` as a shell reads it back.
     static func quoted(_ word: String) -> String {
-        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-#@+=")
+        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-@+=")
         guard word.isEmpty || !word.unicodeScalars.allSatisfy(plain.contains) else { return word }
         return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
     }
@@ -124,6 +127,9 @@ public final class NewRowPicker {
         didSet {
             guard text != oldValue else { return }
             selection = nil
+            isSelectionPicked = false
+            // A lookup that failed, such as one gh did not answer in time, is tried again when asked for again.
+            lookups = lookups.filter { if case .failure = $0.value { false } else { true } }
             settleSelection()
             scheduleLookup()
         }
@@ -141,10 +147,13 @@ public final class NewRowPicker {
     @ObservationIgnored private var lookingUp: Set<String> = []
     /// Nil while the open PRs load.
     private var openPullRequests: Result<[ListedPullRequest], WorkspaceError>?
-    /// PRs looked up by what was typed, nil where GitHub has none.
+    /// PRs looked up by number, and by repo too for a URL, nil where GitHub has none.
     private var lookups: [String: Result<ListedPullRequest?, WorkspaceError>] = [:]
     private var branchListing: Result<BranchListing, WorkspaceError>?
     private var selection: String?
+    /// Whether the selected item was picked with the arrows, a click, or the start point field, rather than being the
+    /// best match for the typed text.
+    @ObservationIgnored private var isSelectionPicked = false
 
     public init(sources: Sources, lookupDelay: Duration = .milliseconds(250)) {
         self.sources = sources
@@ -197,11 +206,11 @@ public final class NewRowPicker {
     private var reference: PRReference? { PRReference(typed) }
 
     /// A PR the typed text names that is not in the open list, and so is looked up on its own. URLs are always looked
-    /// up, since only the lookup says whether they name this repo.
+    /// up, since only the lookup says whether they name this repo. `12` and `#12` share one lookup.
     private var lookupKey: String? {
         guard showsPullRequests, let reference, case .success(let open) = openPullRequests else { return nil }
         guard reference.repo != nil || !open.contains(where: { $0.number == reference.number }) else { return nil }
-        return typed
+        return (reference.repo.map { $0.nameWithOwner.lowercased() } ?? "") + "#\(reference.number)"
     }
 
     public var pullRequestItems: [NewRowItem] {
@@ -264,10 +273,11 @@ public final class NewRowPicker {
     }
 
     /// "New branch ‘<name>’", shown for a valid branch name that no branch has in any case, since `row new` would use
-    /// that branch. Text starting with `#` means a PR.
+    /// that branch. A PR number, and any text starting with `#`, means a PR, so it never offers a branch to create by
+    /// mistake while the PR is on its way.
     public var newBranchItem: NewRowItem? {
         let name = typed
-        guard BranchName.isValid(name), !name.hasPrefix("#") else { return nil }
+        guard BranchName.isValid(name), !name.hasPrefix("#"), reference == nil else { return nil }
         if case .success(let listing) = branchListing,
             listing.branches.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
         {
@@ -294,12 +304,14 @@ public final class NewRowPicker {
 
     public func select(_ id: String?) {
         selection = id
+        isSelectionPicked = id != nil
     }
 
     /// Moves by `offset` items, stopping at the ends. With nothing selected, down picks the first and up the last.
     public func moveSelection(by offset: Int) {
         let items = items
         guard !items.isEmpty else { return }
+        isSelectionPicked = true
         guard let index = items.firstIndex(where: { $0.id == selection }) else {
             selection = (offset > 0 ? items.first : items.last)?.id
             return
@@ -307,12 +319,24 @@ public final class NewRowPicker {
         selection = items[min(max(index + offset, 0), items.count - 1)].id
     }
 
-    /// Keeps the selected item while it is listed, so answers arriving later never move it. Otherwise the first item
-    /// is selected once something is typed, and nothing before.
+    /// Keeps a picked item selected while it is listed, so answers arriving later never move it. Otherwise the best
+    /// match is selected once something is typed, and nothing before, and it follows the answers as they arrive.
     private func settleSelection() {
         let items = items
-        if let selection, items.contains(where: { $0.id == selection }) { return }
-        selection = typed.isEmpty ? nil : items.first?.id
+        if isSelectionPicked, let selection, items.contains(where: { $0.id == selection }) { return }
+        isSelectionPicked = false
+        selection = typed.isEmpty ? nil : bestMatch(in: items)?.id
+    }
+
+    /// The PR a number names, then a branch named exactly what was typed, in any case, then the first item.
+    private func bestMatch(in items: [NewRowItem]) -> NewRowItem? {
+        if reference != nil, let pullRequest = pullRequestItems.first { return pullRequest }
+        if let branch = branchItems.first, case .branch(let listed) = branch,
+            listed.name.caseInsensitiveCompare(typed) == .orderedSame
+        {
+            return branch
+        }
+        return items.first
     }
 
     // MARK: Looking up one PR
@@ -322,19 +346,19 @@ public final class NewRowPicker {
     private func scheduleLookup() {
         lookupTask?.cancel()
         guard let key = lookupKey, lookups[key] == nil, !lookingUp.contains(key) else { return }
-        lookupTask = Task { [weak self, lookupDelay] in
+        lookupTask = Task { [weak self, lookupDelay, query = typed] in
             if lookupDelay > .zero { try? await Task.sleep(for: lookupDelay) }
             guard !Task.isCancelled else { return }
-            await self?.lookUp(key)
+            await self?.lookUp(key, query: query)
         }
     }
 
-    private func lookUp(_ key: String) async {
+    private func lookUp(_ key: String, query: String) async {
         lookingUp.insert(key)
         defer { lookingUp.remove(key) }
         let result: Result<ListedPullRequest?, WorkspaceError>
         do {
-            result = .success(try await sources.pullRequests(key).first)
+            result = .success(try await sources.pullRequests(query).first)
         } catch {
             result = .failure(Self.workspaceError(error))
         }
```

`Sources/CanopyCore/Workspace/Workspace+Listing.swift`:

```diff
@@ -25,6 +25,7 @@ extension Workspace {
         repoPath: String, query: String? = nil, includeClosed: Bool = false
     ) async throws -> [ListedPullRequest] {
         _ = try entryIndex(repoPath: repoPath)
+        guard FileManager.default.fileExists(atPath: repoPath) else { throw WorkspaceError.pathNotFound(repoPath) }
         guard let origin = await gitHubRemote("origin", repoPath: repoPath) else {
             throw WorkspaceError.notOnGitHub(repoName(repoPath))
         }
@@ -51,15 +52,15 @@ extension Workspace {
     }
 
     /// Finds the row or worktree that has a PR's branch: one on a branch bound to the PR, or for a PR from the repo
-    /// itself, one on its head branch. These are also how the PR badges find a row's PR. A worktree whose folder is
-    /// gone holds nothing, since `row new` takes its branch back.
+    /// itself, one on its head branch that is not bound to another PR. These are also how the PR badges find a row's
+    /// PR. A worktree whose folder is gone holds nothing, since `row new` takes its branch back.
     func pullRequestHolders(repoPath: String, repo: GitHubRepo) -> (ListedPullRequest) -> BranchHolder? {
         let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing && $0.branch != nil } ?? []
         let bound = boundPullRequests(repoPath: repoPath, branches: rows.compactMap(\.branch), repo: repo)
         return { pr in
             let row =
                 rows.first { $0.branch.flatMap { bound[$0] } == pr.number }
-                ?? (pr.isFork ? nil : rows.first { $0.branch == pr.headBranch })
+                ?? (pr.isFork ? nil : rows.first { $0.branch == pr.headBranch && bound[pr.headBranch] == nil })
             return row.map(BranchHolder.init)
         }
     }
@@ -81,23 +82,31 @@ extension Workspace {
             if let failure { warnings.append("\(failure), so the list shows what Canopy last saw of origin.") }
         }
 
+        // A local branch whose upstream is its namesake on origin, as most are, gets its counts from this one call.
         let output: String
         do {
             output = try await git.run(
-                ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(committerdate:unix)", "refs/heads/"]
-                    + (hasOrigin ? ["refs/remotes/origin/"] : []),
+                [
+                    "for-each-ref",
+                    "--format=%(refname)%00%(objectname)%00%(committerdate:unix)%00%(upstream)%00"
+                        + "%(upstream:track,nobracket)",
+                    "refs/heads/",
+                ] + (hasOrigin ? ["refs/remotes/origin/"] : []),
                 in: repoPath)
         } catch let error as GitError {
             throw WorkspaceError.git(error)
         }
         var local: [String: (commit: String, date: Date)] = [:]
         var origin: [String: (commit: String, date: Date)] = [:]
+        var tracked: [String: (ahead: Int, behind: Int)] = [:]
         for line in output.split(separator: "\n") {
             let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
-            guard fields.count == 3, let seconds = TimeInterval(fields[2]) else { continue }
+            guard fields.count == 5, let seconds = TimeInterval(fields[2]) else { continue }
             let tip = (commit: fields[1], date: Date(timeIntervalSince1970: seconds))
             if fields[0].hasPrefix("refs/heads/") {
-                local[String(fields[0].dropFirst("refs/heads/".count))] = tip
+                let name = String(fields[0].dropFirst("refs/heads/".count))
+                local[name] = tip
+                if fields[3] == "refs/remotes/origin/\(name)" { tracked[name] = Self.counts(fields[4]) }
             } else if fields[0] != "refs/remotes/origin/HEAD" {
                 origin[String(fields[0].dropFirst("refs/remotes/origin/".count))] = tip
             }
@@ -114,9 +123,13 @@ extension Workspace {
                 committedAt: max(here?.date ?? .distantPast, there?.date ?? .distantPast).formatted(.iso8601),
                 row: rows.first { $0.branch == name }.map(BranchHolder.init))
             if let here, let there {
-                (branch.ahead, branch.behind) =
-                    here.commit == there.commit
-                    ? (0, 0) : await aheadBehind(here.commit, there.commit, repoPath: repoPath)
+                if here.commit == there.commit {
+                    (branch.ahead, branch.behind) = (0, 0)
+                } else if let counts = tracked[name] {
+                    (branch.ahead, branch.behind) = counts
+                } else {
+                    (branch.ahead, branch.behind) = await aheadBehind(here.commit, there.commit, repoPath: repoPath)
+                }
             }
             branches.append(branch)
         }
@@ -133,6 +146,22 @@ extension Workspace {
             warnings: warnings)
     }
 
+    /// Reads `ahead 1, behind 2`, `ahead 1`, `behind 2`, or nothing, as `%(upstream:track,nobracket)` writes them.
+    static func counts(_ track: String) -> (ahead: Int, behind: Int)? {
+        guard track != "gone" else { return nil }
+        var counts = (ahead: 0, behind: 0)
+        for part in track.split(separator: ",") {
+            let words = part.split(separator: " ")
+            guard words.count == 2, let count = Int(words[1]) else { return nil }
+            switch words[0] {
+            case "ahead": counts.ahead = count
+            case "behind": counts.behind = count
+            default: return nil
+            }
+        }
+        return counts
+    }
+
     /// How many commits `local` has that `other` does not, and the other way round. Nil when git cannot say.
     private func aheadBehind(_ local: String, _ other: String, repoPath: String) async -> (Int?, Int?) {
         guard
```

`scripts/e2e.sh`:

```diff
@@ -677,7 +677,9 @@ EOF
 "$cli" pr list --repo shop --query SOMEONE --json > "$work/someone.json"
 [[ "$(field "$work/someone.json" 0.number)" == 22 ]] || fail "pr list --query did not find PR 22 by its author"
 "$cli" pr list --repo shop --closed --json | grep -q '"number" : 23' || fail "pr list --closed is missing PR 23"
-if "$cli" pr list --repo shop --json | grep -q '"number" : 23'; then fail "pr list shows the closed PR 23"; fi
+# Saved first, so a failing canopy fails the run rather than passing a check that something is absent.
+"$cli" pr list --repo shop --json > "$work/open.json"
+if grep -q '"number" : 23' "$work/open.json"; then fail "pr list shows the closed PR 23"; fi
 "$cli" pr list --repo shop --query '#23' --json > "$work/pr23.json"
 [[ "$(field "$work/pr23.json" 0.state)" == closed && "$(field "$work/pr23.json" 0.row)" == None ]] ||
     fail "pr list --query '#23' did not look up the closed PR"
@@ -690,7 +692,8 @@ step "pr show is the default of canopy pr"
 
 step "branch list shows local and origin branches, and fetches first"
 author push -q origin main:refs/heads/feat/just-pushed
-if "$cli" branch list --repo shop --no-fetch | grep -q feat/just-pushed; then fail "branch list --no-fetch fetched"; fi
+"$cli" branch list --repo shop --no-fetch > "$work/no-fetch.txt"
+if grep -q feat/just-pushed "$work/no-fetch.txt"; then fail "branch list --no-fetch fetched"; fi
 "$cli" branch list --repo shop --json > "$work/branches.json"
 /usr/bin/python3 - "$work/branches.json" "$row21" <<'EOF' || fail "branch list is wrong"
 import json, sys
```

