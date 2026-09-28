# Canopy Rows From a PR or an Existing Branch (PR A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `canopy row new --pr <n | #n | URL>` starts a row on a PR's branch, for PRs from the repo and from forks, and `canopy row new <branch>` says which branch it used and brings an existing branch up to date without losing commits.

**Architecture:** CanopyCore gains a PR reference parser, a one-call PR lookup through gh, and a `Workspace.createRow(repoPath:pullRequest:branch:)` that runs the git steps itself with gh's naming and tracking rules.
The existing `createRow(repoPath:branch:base:)` gains `existing`, reports a `BranchSource`, fast-forwards a branch that is only behind origin, and prunes a missing worktree that holds the branch.
A PR number saved per local branch in `state.json` lets the badge query find fork PRs by number in the same GraphQL call.
The control API and CLI pass the new options through, and PR B only adds list methods and the sheet on top of these calls.

**Tech Stack:** Swift 6.2 in Swift 6 language mode, Swift Testing, git, gh, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md`, and "Creating a row" and "PR badges" in `docs/superpowers/specs/2026-09-27-canopy-design.md`.

## Global Constraints

- Tests never reach the network: a local bare origin with `refs/pull/<n>/head` pushed into it, `GIT_CONFIG_COUNT` rewriting `https://github.com/` to that folder, and a stand-in gh.
- Canopy runs git itself and never calls `gh pr checkout`.
- Never reset a branch, and only fast-forward one that has no commits of its own.
- `source` is `local`, `origin`, or `new`.
- Error codes: `branch_not_found`, `branch_exists`, `invalid_pr`, `pr_not_found`, and `branch_checked_out` naming where the branch is.
- `state.json` fields decode with decodeIfPresent, so older files still load.
- Swift 6 strict concurrency with no warnings, `swift format lint --strict` clean.
- Markdown: one sentence per line, no em dashes.
- Other agents change `GitHubCLI` (repo clone, gh on its own thread) and `row new` (`--group`), so changes there stay small.

## Review Focus

1. A PR ref fetch that fails partway, such as a network drop: the temporary `refs/canopy/pr/<n>` ref and any branch Canopy made are gone afterwards, and the error says which PR could not be fetched.
2. Two `row new --pr 7` calls at once: the second fails with `branch_checked_out` naming the first row, never a half-made branch.
3. A PR URL pasted with a trailing `/files`, a query, a fragment, or surrounding spaces still parses, and an issue URL does not.
4. A binding whose origin now points at another repo is ignored rather than breaking the whole repo's badge lookup.
5. A row removed without deleting its branch keeps its binding, so checking the branch out again still shows the fork PR's badge.

## File Structure

- Create `Sources/CanopyCore/PullRequests/PRReference.swift`: parses `7`, `#7`, and PR URLs.
- Create `Sources/CanopyCore/PullRequests/PullRequestHead.swift`: what starting a row from a PR needs to know, and its GraphQL query.
- Modify `Sources/CanopyCore/PullRequests/GitHubCLI.swift`: one `run` helper for gh calls, and `pullRequest(repo:number:)`.
- Modify `Sources/CanopyCore/PullRequests/PullRequest.swift`: `GitHubRepo` gains `init(owner:name:)`, `matches(_:)`, and `url(replacingRepoIn:)`, and `PRQuery` looks bound branches up by number.
- Create `Sources/CanopyCore/Workspace/Workspace+Branches.swift`: a branch's own spelling, claiming a branch (with the prune), fast-forwarding, and comparing with origin.
- Modify `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`: `source`, `existing`, notes, and the shared worktree add.
- Create `Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`: `createRow(repoPath:pullRequest:branch:)`.
- Modify `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`: origin's GitHub repo with the configured-URL fallback, and bound numbers in lookups.
- Modify `Sources/CanopyCore/Workspace/Workspace.swift`: `pruneNow`, callable inside a repo's git queue.
- Modify `Sources/CanopyCore/Workspace/WorkspaceError.swift`: the new errors.
- Modify `Sources/CanopyCore/State/AppState.swift`: `PRBinding` and `RepoEntry.prBindings`.
- Modify `Sources/CanopyCore/Control/ControlMethods.swift` and `WorkspaceControlHandler.swift`: `pr`, `existing`, and the new result fields.
- Modify `Sources/CanopyCLI/RowCommand.swift` and `AgentGuide.swift`.
- Modify `scripts/e2e.sh`.
- Tests: `PRReferenceTests`, `PullRequestTests`, `GitHubCLITests`, `ExistingBranchTests`, `PullRequestRowTests`, `PRBindingTests`, `RowLifecycleTests`, `ControlProtocolTests`, `ControlServerTests`, `StateStoreTests`, and `Support/LocalGitHub.swift`.

---

## Task 1: PR references, and a PR's details from gh

**Files:**
- Create: `Sources/CanopyCore/PullRequests/PRReference.swift`, `Sources/CanopyCore/PullRequests/PullRequestHead.swift`, `Tests/CanopyCoreTests/PRReferenceTests.swift`
- Modify: `Sources/CanopyCore/PullRequests/GitHubCLI.swift`, `Sources/CanopyCore/PullRequests/PullRequest.swift`, `Tests/CanopyCoreTests/GitHubCLITests.swift`, `Tests/CanopyCoreTests/PullRequestTests.swift`

**Interfaces:**
- Produces: `PRReference(_ text: String)?` with `number: Int` and `repo: GitHubRepo?`, nil for anything but a PR number or URL.
- Produces: `PullRequestHead` with `pullRequest`, `branch`, `commit`, `branchExists`, `isCrossRepository`, `headRepo: GitHubRepo?`, `maintainerCanModify`, and `defaultBranch: String?`, and `PRHeadQuery.build(repo:number:)` and `parse(_:)`.
- Produces: `GHFailure` (`ghMissing`, `notLoggedIn`, `failed(String)`) and `GitHubCLI.pullRequest(repo:number:) async -> Result<PullRequestHead?, GHFailure>`, which is `.success(nil)` when GitHub has no such PR.
- Produces: `GitHubRepo(owner:name:)`, `matches(_:)`, and `url(replacingRepoIn:) -> String?`, and `PRState(gitHub:isDraft:)`.

- [ ] **Step 1: Write the failing tests**

Parsing covers numbers, `#number`, and pasted URLs with a path, query, or fragment after the number, and refuses issue URLs and other hosts.
The head query is read from GitHub's reply, including a merged PR whose branch and fork are gone (`headRef` and `headRepository` are null).
gh exits 1 with "Could not resolve to a PullRequest" for a PR that does not exist, and prints the partial reply, which the real gh 2.101.0 confirmed.

`Tests/CanopyCoreTests/GitHubCLITests.swift`:

```diff
@@ -76,4 +76,44 @@ struct GitHubCLITests {
 
         #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .failed("gh did not answer in time."))
     }
+
+    @Test func looksUpOnePullRequest() async throws {
+        let dir = try TempDir()
+        let gh = try Fixture.gh(
+            in: dir,
+            """
+            printf '%s\\n' "$@" > "\(dir.sub("args"))"
+            echo '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": {"number": 7, "title": "t", "url": "u", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28", "headRefName": "feat/x", "headRefOid": "abc", "headRef": {"name": "feat/x"}, "baseRefName": "main", "isCrossRepository": false, "maintainerCanModify": false, "headRepository": {"name": "canopy"}, "headRepositoryOwner": {"login": "NE1NN"}}}}}'
+            """)
+
+        let head = try await gh.pullRequest(repo: repo, number: 7).get()
+
+        #expect(head?.branch == "feat/x")
+        let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8).split(separator: "\n")
+        #expect(Array(args.prefix(3)) == ["api", "graphql", "-f"])
+        #expect(args.dropFirst(3).first?.contains("pullRequest(number: 7)") == true)
+    }
+
+    @Test func aPullRequestGitHubDoesNotHaveIsNone() async throws {
+        let dir = try TempDir()
+        let gh = try Fixture.gh(
+            in: dir,
+            """
+            echo '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": null}}}'
+            echo 'gh: Could not resolve to a PullRequest with the number of 7.' >&2
+            exit 1
+            """)
+
+        #expect(try await gh.pullRequest(repo: repo, number: 7).get() == nil)
+    }
+
+    @Test func aPullRequestLookupSaysWhyGHCannotAnswer() async throws {
+        let dir = try TempDir()
+        let loggedOut = try Fixture.gh(
+            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
+        let missing = GitHubCLI(environment: ["PATH": dir.path, "HOME": dir.path], fallbackFolders: [])
+
+        #expect(await loggedOut.pullRequest(repo: repo, number: 7) == .failure(.notLoggedIn))
+        #expect(await missing.pullRequest(repo: repo, number: 7) == .failure(.ghMissing))
+    }
 }
```

`Tests/CanopyCoreTests/PRReferenceTests.swift` (new):

```swift
import Testing

@testable import CanopyCore

struct PRReferenceTests {
    @Test func readsNumbers() {
        for text in ["7", "#7", " #7 ", "007"] {
            #expect(PRReference(text) == PRReference(number: 7), "\(text)")
        }
    }

    @Test func readsPullRequestURLs() {
        for text in [
            "https://github.com/acme/app/pull/7", "https://github.com/acme/app/pull/7/files",
            "https://github.com/acme/app/pull/7?diff=split", "https://github.com/acme/app/pull/7#discussion_r1",
            "http://www.github.com/acme/app/pull/7/", " HTTPS://GitHub.com/acme/app/pull/7 ",
        ] {
            let reference = PRReference(text)
            #expect(reference?.number == 7, "\(text)")
            #expect(reference?.repo == GitHubRepo(owner: "acme", name: "app"), "\(text)")
        }
    }

    @Test func refusesAnythingElse() {
        for text in [
            "", "#", "0", "-3", "7a", "#7 8", "feat/x", "https://github.com/acme/app/issues/7",
            "https://github.com/acme/pull/7", "https://gitlab.com/acme/app/pull/7",
            "https://github.com/acme/app/pull/x",
            "https://github.com/acme/app/pull/0", "99999999999999999999",
        ] {
            #expect(PRReference(text) == nil, "\(text)")
        }
    }
}
```

`Tests/CanopyCoreTests/PullRequestTests.swift`:

```diff
@@ -82,4 +82,83 @@ struct PullRequestTests {
         #expect(found["c"] == nil)
         #expect(found["d"]?.number == 3)
     }
+
+    @Test func comparesReposWithoutCase() {
+        #expect(GitHubRepo(owner: "NE1NN", name: "Canopy").matches(repo))
+        #expect(!GitHubRepo(owner: "NE1NN", name: "canopy-2").matches(repo))
+    }
+
+    @Test func reachesAForkTheWayOriginIsReached() {
+        let fork = GitHubRepo(owner: "someone", name: "canopy-fork")
+        let cases = [
+            "https://github.com/NE1NN/canopy.git": "https://github.com/someone/canopy-fork.git",
+            "https://github.com/NE1NN/canopy": "https://github.com/someone/canopy-fork",
+            "https://token@github.com/NE1NN/canopy.git/": "https://token@github.com/someone/canopy-fork.git",
+            "git@github.com:NE1NN/canopy.git": "git@github.com:someone/canopy-fork.git",
+            "git@github-work:NE1NN/canopy": "git@github-work:someone/canopy-fork",
+            "ssh://git@ssh.github.com:443/NE1NN/canopy.git": "ssh://git@ssh.github.com:443/someone/canopy-fork.git",
+        ]
+        for (origin, expected) in cases {
+            #expect(fork.url(replacingRepoIn: origin) == expected, "\(origin)")
+        }
+        #expect(fork.url(replacingRepoIn: "/local/path") == nil)
+    }
+
+    @Test func readsAPullRequestsHead() throws {
+        let json = """
+            {"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": {
+              "number": 7, "title": "Split checkout", "url": "https://github.com/NE1NN/canopy/pull/7", "state": "OPEN",
+              "isDraft": true, "updatedAt": "2026-09-28T01:00:00Z", "headRefName": "feat/split",
+              "headRefOid": "abc123", "headRef": {"name": "feat/split"}, "baseRefName": "main",
+              "isCrossRepository": true, "maintainerCanModify": true,
+              "headRepository": {"name": "canopy-fork"}, "headRepositoryOwner": {"login": "someone"}}}}}
+            """
+
+        let head = try #require(try PRHeadQuery.parse(Data(json.utf8)))
+
+        #expect(
+            head.pullRequest
+                == PullRequest(
+                    number: 7, title: "Split checkout", url: "https://github.com/NE1NN/canopy/pull/7", state: .draft,
+                    updatedAt: "2026-09-28T01:00:00Z"))
+        #expect(head.branch == "feat/split")
+        #expect(head.commit == "abc123")
+        #expect(head.branchExists)
+        #expect(head.isCrossRepository)
+        #expect(head.headRepo == GitHubRepo(owner: "someone", name: "canopy-fork"))
+        #expect(head.maintainerCanModify)
+        #expect(head.defaultBranch == "main")
+    }
+
+    @Test func readsAMergedHeadWhoseBranchAndForkAreGone() throws {
+        let json = """
+            {"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": {
+              "number": 7, "title": "t", "url": "u", "state": "MERGED", "isDraft": false, "updatedAt": "2026-09-28",
+              "headRefName": "feat/split", "headRefOid": "abc123", "headRef": null, "baseRefName": "main",
+              "isCrossRepository": true, "maintainerCanModify": false, "headRepository": null,
+              "headRepositoryOwner": null}}}}
+            """
+
+        let head = try #require(try PRHeadQuery.parse(Data(json.utf8)))
+
+        #expect(head.pullRequest.state == .merged)
+        #expect(!head.branchExists)
+        #expect(head.headRepo == nil)
+    }
+
+    @Test func aMissingPullRequestReadsAsNone() throws {
+        let json = #"{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": null}}}"#
+
+        #expect(try PRHeadQuery.parse(Data(json.utf8)) == nil)
+    }
+
+    @Test func headQueryAsksForOnePullRequest() {
+        let query = PRHeadQuery.build(repo: repo, number: 7)
+
+        #expect(query.contains(#"repository(owner: "NE1NN", name: "canopy")"#))
+        #expect(query.contains("pullRequest(number: 7)"))
+        for field in ["headRefOid", "headRef { name }", "maintainerCanModify", "headRepositoryOwner { login }"] {
+            #expect(query.contains(field), "\(field)")
+        }
+    }
 }
```

- [ ] **Step 2: Run them and see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'PRReferenceTests|PullRequestTests|GitHubCLITests'`
Expected: compile errors: `PRReference`, `PRHeadQuery`, `GitHubRepo(owner:name:)`, and `pullRequest(repo:number:)` do not exist.

- [ ] **Step 3: Implement**

`GitHubCLI` gets one `run` helper for every gh call, shaped like the one feat/repo-clone adds so the two branches rebase onto each other easily.
The fork URL keeps everything in front of origin's path, so SSH host aliases and `insteadOf` rewrites reach the fork the way they reach origin.

`Sources/CanopyCore/PullRequests/GitHubCLI.swift`:

```diff
@@ -1,5 +1,12 @@
 import Foundation
 
+/// Why gh could not do what it was asked.
+public enum GHFailure: Error, Sendable, Equatable {
+    case ghMissing
+    case notLoggedIn
+    case failed(String)
+}
+
 public enum PRLookup: Sendable, Equatable {
     /// Each looked-up branch that has a PR.
     case found([String: PullRequest])
@@ -43,45 +50,67 @@ public struct GitHubCLI: Sendable {
     }
 
     public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
+        let query = PRQuery.build(repo: repo, branches: branches)
+        switch await run(["api", "graphql", "-f", "query=\(query)"]) {
+        case .failure(.ghMissing): return .ghMissing
+        case .failure(.notLoggedIn): return .notLoggedIn
+        case .failure(.failed(let message)): return .failed(message)
+        case .success(let reply):
+            guard let found = try? PRQuery.parse(reply, branches: branches) else { return .failed(Self.unreadable) }
+            return .found(found)
+        }
+    }
+
+    /// One pull request of `repo`, with what starting a row from it needs. Nil when the repo has no such PR.
+    public func pullRequest(repo: GitHubRepo, number: Int) async -> Result<PullRequestHead?, GHFailure> {
+        switch await run(["api", "graphql", "-f", "query=\(PRHeadQuery.build(repo: repo, number: number))"]) {
+        case .failure(.failed(let message)) where message.hasPrefix("Could not resolve to a PullRequest"):
+            return .success(nil)
+        case .failure(let failure):
+            return .failure(failure)
+        case .success(let reply):
+            guard let head = try? PRHeadQuery.parse(reply) else { return .failure(.failed(Self.unreadable)) }
+            return .success(head)
+        }
+    }
+
+    private static let unreadable = "gh returned a reply Canopy could not read."
+
+    /// Runs gh off the Swift concurrency pool and returns what it printed.
+    private func run(_ arguments: [String]) async -> Result<Data, GHFailure> {
         await withCheckedContinuation { continuation in
             DispatchQueue.global().async {
-                continuation.resume(returning: lookUpBlocking(repo: repo, branches: branches))
+                continuation.resume(returning: runBlocking(arguments))
             }
         }
     }
 
-    private func lookUpBlocking(repo: GitHubRepo, branches: [String]) -> PRLookup {
+    private func runBlocking(_ arguments: [String]) -> Result<Data, GHFailure> {
         var environment = environment ?? GitEnvironment.current
         let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
         guard
             let executable = (folders + fallbackFolders).lazy.map({ $0 + "/gh" }).first(where: {
                 FileManager.default.isExecutableFile(atPath: $0)
             })
-        else { return .ghMissing }
+        else { return .failure(.ghMissing) }
         environment["GH_PROMPT_DISABLED"] = "1"
         environment["GH_NO_UPDATE_NOTIFIER"] = "1"
 
-        let query = PRQuery.build(repo: repo, branches: branches)
         let result: SubprocessResult
         do {
             result = try Subprocess.run(
-                executable, ["api", "graphql", "-f", "query=\(query)"], environment: environment, directory: nil,
-                timeout: timeout)
+                executable, arguments, environment: environment, directory: nil, timeout: timeout)
         } catch {
-            return .failed("\(error)")
+            return .failure(.failed("\(error)"))
         }
-        if result.timedOut { return .failed("gh did not answer in time.") }
+        if result.timedOut { return .failure(.failed("gh did not answer in time.")) }
         let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
         // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
-        if result.status == 4 || message.contains("HTTP 401") { return .notLoggedIn }
+        if result.status == 4 || message.contains("HTTP 401") { return .failure(.notLoggedIn) }
         guard result.status == 0 else {
             let line = message.split(separator: "\n").last.map(String.init) ?? "gh exited with \(result.status)."
-            return .failed(line.hasPrefix("gh: ") ? String(line.dropFirst(4)) : line)
-        }
-        do {
-            return .found(try PRQuery.parse(result.stdout, branches: branches))
-        } catch {
-            return .failed("gh returned a reply Canopy could not read.")
+            return .failure(.failed(line.hasPrefix("gh: ") ? String(line.dropFirst(4)) : line))
         }
+        return .success(result.stdout)
     }
 }
```

`Sources/CanopyCore/PullRequests/PRReference.swift` (new):

```swift
import Foundation

/// A pull request as a person types or pastes it: `7`, `#7`, or its URL.
public struct PRReference: Sendable, Equatable {
    public var number: Int
    /// The repo a URL names. Nil for a number, which means origin's repo.
    public var repo: GitHubRepo?

    public init(number: Int, repo: GitHubRepo? = nil) {
        self.number = number
        self.repo = repo
    }

    /// Nil for anything that is not a PR number or a GitHub pull request URL, such as an issue's URL.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Self.number(text.hasPrefix("#") ? String(text.dropFirst()) : text) {
            self.init(number: number)
            return
        }
        guard let url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
            let host = url.host?.lowercased(), GitHubRepo.hosts.contains(host)
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Self.number(parts[3]) else { return nil }
        self.init(number: number, repo: GitHubRepo(owner: parts[0], name: parts[1]))
    }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let number = Int(text),
            number > 0
        else { return nil }
        return number
    }
}
```

`Sources/CanopyCore/PullRequests/PullRequest.swift`:

```diff
@@ -2,6 +2,16 @@ import Foundation
 
 public enum PRState: String, Codable, Sendable {
     case open, draft, merged, closed
+
+    /// GitHub's state, with an open draft shown as draft.
+    init(gitHub state: String, isDraft: Bool) {
+        self =
+            switch state {
+            case "OPEN": isDraft ? .draft : .open
+            case "MERGED": .merged
+            default: .closed
+            }
+    }
 }
 
 public struct PullRequest: Codable, Sendable, Equatable {
@@ -29,6 +39,34 @@ public struct GitHubRepo: Sendable, Equatable {
 
     static let hosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]
 
+    public init(owner: String, name: String) {
+        self.owner = owner
+        self.name = name
+    }
+
+    /// GitHub ignores case in owner and repo names.
+    public func matches(_ other: GitHubRepo) -> Bool {
+        owner.lowercased() == other.owner.lowercased() && name.lowercased() == other.name.lowercased()
+    }
+
+    /// `remoteURL` with this repo's owner and name in place of its own, keeping its scheme, user, host, and `.git`
+    /// ending, so a fork is reached the way origin is: over the same protocol, SSH host alias, and URL rewrites.
+    public func url(replacingRepoIn remoteURL: String) -> String? {
+        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
+        guard Self.split(url) != nil else { return nil }
+        let pathStart: String.Index
+        if let separator = url.range(of: "://") {
+            guard let slash = url[separator.upperBound...].firstIndex(of: "/") else { return nil }
+            pathStart = url.index(after: slash)
+        } else {
+            guard let colon = url.firstIndex(of: ":") else { return nil }
+            pathStart = url.index(after: colon)
+        }
+        var path = url[pathStart...]
+        if path.hasSuffix("/") { path.removeLast() }
+        return url[..<pathStart] + "\(owner)/\(name)" + (path.hasSuffix(".git") ? ".git" : "")
+    }
+
     /// Reads https, ssh, and scp-style GitHub remotes. `sshHostName` says which host an SSH alias, such as the
     /// github-work people set up for a second account, connects to. Anything else has no GitHub repo.
     public init?(remoteURL: String, sshHostName: (String) -> String? = { _ in nil }) {
@@ -106,14 +144,9 @@ public enum PRQuery {
                 let chosen = nodes.first(where: { $0.state == "OPEN" })
                     ?? nodes.max(by: { $0.updatedAt < $1.updatedAt })
             else { continue }
-            let state: PRState =
-                switch chosen.state {
-                case "OPEN": chosen.isDraft ? .draft : .open
-                case "MERGED": .merged
-                default: .closed
-                }
             result[branch] = PullRequest(
-                number: chosen.number, title: chosen.title, url: chosen.url, state: state, updatedAt: chosen.updatedAt)
+                number: chosen.number, title: chosen.title, url: chosen.url,
+                state: PRState(gitHub: chosen.state, isDraft: chosen.isDraft), updatedAt: chosen.updatedAt)
         }
         return result
     }
```

`Sources/CanopyCore/PullRequests/PullRequestHead.swift` (new):

```swift
import Foundation

/// What starting a row from a pull request needs to know about it.
public struct PullRequestHead: Sendable, Equatable {
    public var pullRequest: PullRequest
    /// The head branch's name, in the repo the PR comes from.
    public var branch: String
    public var commit: String
    /// False once the head branch is deleted, as it usually is after a merge.
    public var branchExists: Bool
    /// Whether the PR comes from a fork.
    public var isCrossRepository: Bool
    /// The repo the head branch lives in. Nil when GitHub no longer reports it, as for a deleted fork.
    public var headRepo: GitHubRepo?
    /// Whether the PR's author lets maintainers push to its branch.
    public var maintainerCanModify: Bool
    /// The base repo's default branch.
    public var defaultBranch: String?
}

/// One GraphQL request for one pull request and its repo's default branch.
public enum PRHeadQuery {
    public static func build(repo: GitHubRepo, number: Int) -> String {
        "query { repository(owner: \(PRQuery.literal(repo.owner)), name: \(PRQuery.literal(repo.name))) { "
            + "defaultBranchRef { name } pullRequest(number: \(number)) { number title url state isDraft updatedAt "
            + "headRefName headRefOid headRef { name } baseRefName isCrossRepository maintainerCanModify "
            + "headRepository { name } headRepositoryOwner { login } } } }"
    }

    /// Nil when the repo has no such pull request.
    public static func parse(_ data: Data) throws -> PullRequestHead? {
        struct Name: Decodable { var name: String }
        struct Login: Decodable { var login: String }
        struct Node: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var headRefName: String
            var headRefOid: String
            var headRef: Name?
            var isCrossRepository: Bool
            var maintainerCanModify: Bool
            var headRepository: Name?
            var headRepositoryOwner: Login?
        }
        struct Repository: Decodable {
            var defaultBranchRef: Name?
            var pullRequest: Node?
        }
        struct Response: Decodable {
            struct Payload: Decodable { var repository: Repository? }
            var data: Payload?
        }
        let repository = try JSONDecoder().decode(Response.self, from: data).data?.repository
        guard let node = repository?.pullRequest else { return nil }
        var headRepo: GitHubRepo?
        if let owner = node.headRepositoryOwner, let repo = node.headRepository {
            headRepo = GitHubRepo(owner: owner.login, name: repo.name)
        }
        return PullRequestHead(
            pullRequest: PullRequest(
                number: node.number, title: node.title, url: node.url,
                state: PRState(gitHub: node.state, isDraft: node.isDraft), updatedAt: node.updatedAt),
            branch: node.headRefName, commit: node.headRefOid, branchExists: node.headRef != nil,
            isCrossRepository: node.isCrossRepository, headRepo: headRepo,
            maintainerCanModify: node.maintainerCanModify, defaultBranch: repository?.defaultBranchRef?.name)
    }
}
```

- [ ] **Step 4: Run the tests, the whole suite, and lint**

Run: the filter above, then `make test`, `make lint`, and `swift build 2>&1 | grep -c warning:`
Expected: every test passes, lint is clean, and there are 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/PullRequests/GitHubCLI.swift Sources/CanopyCore/PullRequests/PRReference.swift Sources/CanopyCore/PullRequests/PullRequest.swift Sources/CanopyCore/PullRequests/PullRequestHead.swift Tests/CanopyCoreTests/GitHubCLITests.swift Tests/CanopyCoreTests/PRReferenceTests.swift Tests/CanopyCoreTests/PullRequestTests.swift
git commit -m "feat: look up a PR's head through gh"
```

## Task 2: `row new <branch>` reports its source, takes `--existing`, and brings a branch up to date

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+Branches.swift`, `Tests/CanopyCoreTests/ExistingBranchTests.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Tests/CanopyCoreTests/RowLifecycleTests.swift`, `docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md`

**Interfaces:**
- Produces: `BranchSource` (`local`, `origin`, `new`) and `CreatedRow` with `row`, `source`, `base`, `pullRequest`, `notes`, and `warnings`.
- Produces: `Workspace.createRow(repoPath:branch:base:existing:)`.
- Produces for Task 3: `existingBranch(_:under:repoPath:)`, `holder(of:repoPath:)`, `claim(branch:repoPath:)`, `bringUpToDate(_:with:named:resetTo:repoPath:) -> BranchReport`, `requireValidBranchName(_:repoPath:)`, `addRow(repoPath:branch:arguments:) -> (row: Row, warnings: [String])`, and `pruneNow(repoPath:)`.
- Produces: `WorkspaceError.branchCheckedOut(String, row: Row?)` and `branchNotFound(String, fetchFailure: String?)`.

- [ ] **Step 1: Write the failing tests**

A second clone of the bare origin plays someone else pushing.
The case-twin test returns early on a case-sensitive file system, where `Feat/Lower` never finds `feat/lower`.
The old test that expected `branchCheckedOut("main")` now names the main row.

`Tests/CanopyCoreTests/ExistingBranchTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// `row new <branch>`: which branch it picks, and how an existing branch is brought up to date.
struct ExistingBranchTests {
    let git = Fixture.git

    /// A repo whose origin is a local bare repo, and a second clone of that origin for someone else's pushes.
    func setUp(_ dir: TempDir) async throws -> (repo: String, other: String, workspace: Workspace) {
        let repo = try await Fixture.repo(in: dir, origin: true)
        let other = dir.sub("other")
        try await git.run(["clone", "--quiet", dir.sub("demo-origin.git"), other])
        try await git.run(["config", "user.email", "other@example.com"], in: other)
        try await git.run(["config", "user.name", "Other"], in: other)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (repo, other, workspace)
    }

    func commit(_ count: Int, in path: String) async throws {
        for index in 1...count {
            try await git.run(["commit", "--quiet", "--allow-empty", "-m", "commit \(index)"], in: path)
        }
    }

    func head(_ ref: String, in path: String) async throws -> String {
        try await git.run(["rev-parse", ref], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func saysWhichBranchItUsed() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/local"], in: repo)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/remote"], in: other)

        let local = try await workspace.createRow(repoPath: repo, branch: "feat/local")
        let remote = try await workspace.createRow(repoPath: repo, branch: "feat/remote")
        let new = try await workspace.createRow(repoPath: repo, branch: "feat/new")

        #expect(local.source == .local && local.base == nil)
        #expect(remote.source == .origin && remote.base == nil)
        #expect(new.source == .new && new.base == "origin/main")
        #expect(try await workspace.createRow(repoPath: repo, branch: "feat/based", base: "main").base == "main")
    }

    @Test func existingRefusesANameThatMatchesNothing() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/theirs"], in: other)

        await #expect(throws: WorkspaceError.branchNotFound("feat/typo", fetchFailure: nil)) {
            try await workspace.createRow(repoPath: repo, branch: "feat/typo", existing: true)
        }
        #expect(!(await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/typo"], in: repo)))
        #expect(try await workspace.createRow(repoPath: repo, branch: "feat/theirs", existing: true).source == .origin)
    }

    @Test func existingSaysWhenOriginCouldNotBeAsked() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["remote", "set-url", "origin", dir.sub("nowhere.git")], in: repo)

        await #expect {
            try await workspace.createRow(repoPath: repo, branch: "feat/typo", existing: true)
        } throws: { error in
            guard case WorkspaceError.branchNotFound("feat/typo", let failure?) = error else { return false }
            return failure.hasPrefix("git fetch failed")
                && (error as? WorkspaceError)?.message.contains(failure) == true
        }
    }

    @Test func fastForwardsABranchThatIsOnlyBehind() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/x"], in: repo)
        try await git.run(["switch", "--quiet", "-c", "feat/x"], in: other)
        try await commit(2, in: other)
        try await git.run(["push", "--quiet", "origin", "feat/x"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(created.source == .local)
        #expect(try await head("HEAD", in: created.row.path) == (try await head("HEAD", in: other)))
        #expect(created.notes == ["Fast-forwarded feat/x by 2 commits to match origin/feat/x."])
        #expect(created.warnings.isEmpty)
    }

    @Test func keepsCommitsThatAreOnlyLocal() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/x"], in: repo)
        try await git.run(["switch", "--quiet", "-c", "feat/x"], in: repo)
        try await commit(1, in: repo)
        try await git.run(["switch", "--quiet", "main"], in: repo)
        let local = try await head("feat/x", in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(try await head("HEAD", in: created.row.path) == local)
        #expect(created.notes == ["feat/x has 1 commit that is not on origin/feat/x yet."])
        #expect(created.warnings.isEmpty)
    }

    @Test func neverResetsADivergedBranch() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/x"], in: repo)
        try await git.run(["branch", "feat/x", "main"], in: repo)
        try await git.run(["switch", "--quiet", "feat/x"], in: repo)
        try await commit(1, in: repo)
        try await git.run(["switch", "--quiet", "main"], in: repo)
        let local = try await head("feat/x", in: repo)
        try await git.run(["fetch", "--quiet"], in: other)
        try await git.run(["switch", "--quiet", "feat/x"], in: other)
        try await commit(2, in: other)
        try await git.run(["push", "--quiet", "origin", "feat/x"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(try await head("HEAD", in: created.row.path) == local)
        #expect(created.notes.isEmpty)
        let warning = try #require(created.warnings.first)
        #expect(warning.contains("have diverged"))
        #expect(warning.contains("1 commit here") && warning.contains("2 commits on origin/feat/x"))
        #expect(warning.contains("git rebase origin/feat/x") && warning.contains("git reset --hard origin/feat/x"))
    }

    @Test func warnsWhenABranchsUpstreamIsGone() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/merged"], in: repo)
        try await git.run(["push", "--quiet", "-u", "origin", "feat/merged"], in: repo)
        try await git.run(["push", "--quiet", "origin", "--delete", "feat/merged"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/merged")

        #expect(created.source == .local)
        #expect(
            created.warnings == [
                "feat/merged tracked origin/feat/merged, which is gone, so it was probably merged and deleted."
            ])
    }

    @Test func aBranchDeletedOnOriginIsNotOnOrigin() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/old"], in: other)
        try await git.run(["fetch", "--quiet"], in: repo)
        try await git.run(["push", "--quiet", "origin", "--delete", "feat/old"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/old")

        #expect(created.source == .new)
    }

    @Test func prunesAWorktreeWhoseFolderWasDeleted() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        let gone = try await workspace.createRow(repoPath: repo, branch: "feat/held")
        try FileManager.default.removeItem(atPath: gone.row.path)
        await workspace.refresh(repoPath: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/held")

        #expect(created.source == .local)
        #expect(FileManager.default.fileExists(atPath: created.row.path))
        #expect(await workspace.snapshot.repos.first?.rows.filter { $0.branch == "feat/held" }.count == 1)
    }

    @Test func namesTheRowThatHasTheBranch() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        let first = try await workspace.createRow(repoPath: repo, branch: "feat/a")

        await #expect(throws: WorkspaceError.branchCheckedOut("feat/a", row: first.row)) {
            try await workspace.createRow(repoPath: repo, branch: "feat/a")
        }
        let message = WorkspaceError.branchCheckedOut("feat/a", row: first.row).message
        #expect(message.contains(first.row.path) && message.contains("canopy row select feat/a"))
    }

    @Test func namesTheMainCheckout() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        let main = try #require(await workspace.snapshot.row(path: repo))

        await #expect(throws: WorkspaceError.branchCheckedOut("main", row: main)) {
            try await workspace.createRow(repoPath: repo, branch: "main")
        }
        #expect(WorkspaceError.branchCheckedOut("main", row: main).message.contains("main checkout at \(repo)"))
    }

    @Test func pointsAtAdoptingAnotherToolsWorktree() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        await workspace.refresh(repoPath: repo)
        let theirs = try #require(await workspace.snapshot.row(path: dir.sub("theirs")))

        await #expect(throws: WorkspaceError.branchCheckedOut("feat/theirs", row: theirs)) {
            try await workspace.createRow(repoPath: repo, branch: "feat/theirs", existing: true)
        }
        #expect(
            WorkspaceError.branchCheckedOut("feat/theirs", row: theirs).message.contains(
                "canopy row adopt \(dir.sub("theirs"))"))
    }

    @Test func usesABranchsOwnSpelling() async throws {
        let dir = try TempDir()
        FileManager.default.createFile(atPath: dir.sub("case"), contents: nil)
        // Only a case-insensitive file system lets a ref typed in another case find the branch.
        guard FileManager.default.fileExists(atPath: dir.sub("CASE")) else { return }
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/lower"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "Feat/Lower", existing: true)

        #expect(created.row.branch == "feat/lower")
        #expect(created.source == .local)
        #expect(created.notes == ["Using feat/lower, the branch's own spelling."])
    }
}
```

`Tests/CanopyCoreTests/RowLifecycleTests.swift`:

```diff
@@ -97,7 +97,8 @@ struct RowLifecycleTests {
                 try await workspace.createRow(repoPath: repo, branch: name)
             }
         }
-        await #expect(throws: WorkspaceError.branchCheckedOut("main")) {
+        let main = await workspace.snapshot.row(path: repo)
+        await #expect(throws: WorkspaceError.branchCheckedOut("main", row: main)) {
             try await workspace.createRow(repoPath: repo, branch: "main")
         }
     }
```

- [ ] **Step 2: Run them and see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'ExistingBranchTests|RowLifecycleTests'`
Expected: compile errors: `existing:`, `.source`, `.base`, `branchNotFound`, and `branchCheckedOut(_:row:)` do not exist.

- [ ] **Step 3: Implement**

The fetch gains `--prune`, so a branch deleted on GitHub is no longer on origin.
The branch is looked up in its own spelling, claimed (pruning a missing worktree that holds it), compared with `origin/<branch>` by name, and fast-forwarded with `git update-ref <ref> <new> <old>`, which fails rather than move a branch that changed.
`addRow` is the worktree add that Task 3 shares.
`prune` becomes a queued wrapper around `pruneNow`, which `claim` calls from inside the repo's git queue.
The spec's fix for a diverged branch becomes `git rebase origin/<branch>`, since `git pull --rebase` fails on a branch with no upstream.

`Sources/CanopyCore/Workspace/Workspace+Branches.swift` (new):

```swift
import Foundation

/// What bringing an existing branch up to date did, and what may need the user.
struct BranchReport: Sendable, Equatable {
    var notes: [String] = []
    var warnings: [String] = []
}

extension Workspace {
    /// The branch `name` finds under `prefix`, such as "refs/heads/", in its own spelling, or nil. On a case-insensitive
    /// file system a loose ref typed in another case opens the same file, so `Feat` finds `feat`, and git would then
    /// check out a second name for one ref.
    func existingBranch(_ name: String, under prefix: String, repoPath: String) async -> String? {
        guard await git.succeeds(["show-ref", "--verify", "--quiet", prefix + name], in: repoPath) else { return nil }
        let listed =
            (try? await git.run(["for-each-ref", "--format=%(refname)", prefix], in: repoPath))?
            .split(separator: "\n").map(String.init) ?? []
        let ref =
            listed.first { $0 == prefix + name }
            ?? listed.first { $0.caseInsensitiveCompare(prefix + name) == .orderedSame } ?? prefix + name
        return String(ref.dropFirst(prefix.count))
    }

    /// The worktree that has `branch` checked out, as of the last refresh.
    func holder(of branch: String, repoPath: String) -> Row? {
        snapshot.repo(path: repoPath)?.allRows.first { $0.branch == branch }
    }

    /// Fails unless `branch` is free to check out, naming where it is checked out. A worktree whose folder was deleted
    /// still holds its branch until it is pruned, and git would refuse the add, so that one is pruned instead.
    func claim(branch: String, repoPath: String) async throws {
        await refresh(repoPath: repoPath)
        guard let holder = holder(of: branch, repoPath: repoPath) else { return }
        guard holder.isMissing else { throw WorkspaceError.branchCheckedOut(branch, row: holder) }
        try await pruneNow(repoPath: repoPath)
        if let holder = self.holder(of: branch, repoPath: repoPath) {
            throw WorkspaceError.branchCheckedOut(branch, row: holder)
        }
    }

    /// Fast-forwards the local `branch` to `target` when it is only behind, and says how the two compare otherwise.
    /// Never resets: a branch with commits of its own stays where it is. `name` is how messages show `target`, and
    /// `resetTo` is what the fix commands name.
    func bringUpToDate(
        _ branch: String, with target: String, named name: String, resetTo: String, repoPath: String
    ) async -> BranchReport {
        let local = "refs/heads/\(branch)"
        guard
            let counts = try? await git.run(
                ["rev-list", "--left-right", "--count", "\(local)...\(target)"], in: repoPath),
            case let parts = counts.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }), parts.count == 2
        else { return BranchReport() }
        let (ahead, behind) = (parts[0], parts[1])
        switch (ahead, behind) {
        case (0, 0):
            return BranchReport()
        case (0, _):
            do {
                let old = try await git.run(["rev-parse", local], in: repoPath).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let new = try await git.run(["rev-parse", "\(target)^{commit}"], in: repoPath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The old value makes the update fail rather than move a branch that changed since it was read.
                try await git.run(
                    ["update-ref", "-m", "canopy: fast-forward to \(name)", local, new, old], in: repoPath)
                return BranchReport(notes: ["Fast-forwarded \(branch) by \(Self.commits(behind)) to match \(name)."])
            } catch {
                return BranchReport(warnings: [
                    "Could not fast-forward \(branch) to \(name), so it starts as it was: \(error)"
                ])
            }
        case (_, 0):
            let verb = ahead == 1 ? "is" : "are"
            return BranchReport(notes: ["\(branch) has \(Self.commits(ahead)) that \(verb) not on \(name) yet."])
        default:
            let here = ahead == 1 ? "is" : "are"
            let there = behind == 1 ? "is" : "are"
            return BranchReport(warnings: [
                "\(branch) and \(name) have diverged: \(Self.commits(ahead)) here \(here) not on \(name), and "
                    + "\(Self.commits(behind)) on \(name) \(there) not here. Canopy left \(branch) as it was. "
                    + "To keep the local commits, run `git rebase \(resetTo)` in the row. "
                    + "To drop them, run `git reset --hard \(resetTo)`."
            ])
        }
    }

    /// A warning when `branch` tracks a remote branch that no longer exists, which usually means it was merged.
    func goneUpstreamWarning(_ branch: String, repoPath: String) async -> String? {
        guard
            let line = try? await git.run(
                ["for-each-ref", "--format=%(upstream:short)%00%(upstream:track)", "refs/heads/\(branch)"],
                in: repoPath)
        else { return nil }
        let fields = line.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == "[gone]" else { return nil }
        return "\(branch) tracked \(fields[0]), which is gone, so it was probably merged and deleted."
    }

    static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`:

```diff
@@ -1,23 +1,45 @@
 import Foundation
 
+/// Where a new row's branch came from.
+public enum BranchSource: String, Codable, Sendable {
+    /// A local branch was checked out.
+    case local
+    /// A branch on origin was checked out as a new local branch tracking it.
+    case origin
+    /// Nothing matched, so a new branch was created.
+    case new
+}
+
 public struct CreatedRow: Sendable, Equatable {
     public var row: Row
+    public var source: BranchSource
+    /// Where a new branch started, such as origin/main.
+    public var base: String?
+    /// The pull request the row was started from.
+    public var pullRequest: PullRequest?
+    /// What Canopy did along the way, such as fast-forwarding the branch.
+    public var notes: [String]
+    /// What may need fixing, such as a branch that has diverged from origin.
     public var warnings: [String]
 }
 
 struct FetchAttempt: Sendable {
     var finishedAt: ContinuousClock.Instant
-    var warning: String?
+    /// Why the fetch failed, such as "git fetch timed out".
+    var failure: String?
 }
 
 extension Workspace {
-    /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/.
-    /// An existing local branch is checked out, a branch only on origin is tracked,
-    /// and anything else is created from `base` (default: origin's default branch).
-    public func createRow(repoPath: String, branch: String, base: String? = nil) async throws -> CreatedRow {
+    /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/. An existing local branch is checked out,
+    /// after a fast-forward if it is only behind origin. A branch only on origin is tracked. Anything else is created
+    /// from `base` (default: origin's default branch), unless `existing` asks to fail instead.
+    public func createRow(
+        repoPath: String, branch: String, base: String? = nil, existing: Bool = false
+    ) async throws -> CreatedRow {
         let requestedAt = ContinuousClock.now
         return try await serialized(repoPath: repoPath) {
-            try await self.createRowNow(repoPath: repoPath, branch: branch, base: base, requestedAt: requestedAt)
+            try await self.createRowNow(
+                repoPath: repoPath, branch: branch, base: base, existing: existing, requestedAt: requestedAt)
         }
     }
 
@@ -33,32 +55,99 @@ extension Workspace {
 
     private func createRowNow(
         repoPath: String,
-        branch: String,
+        branch requested: String,
         base: String?,
+        existing: Bool,
         requestedAt: ContinuousClock.Instant
     ) async throws -> CreatedRow {
-        let index = try entryIndex(repoPath: repoPath)
-        let dirName = state.repos[index].dirName
-        var warnings: [String] = []
-
+        _ = try entryIndex(repoPath: repoPath)
         guard FileManager.default.fileExists(atPath: repoPath) else {
             throw WorkspaceError.pathNotFound(repoPath)
         }
-        // `--branch` would expand "@{-1}" to the previous branch, and a leading "-" would read as an option.
+        try await requireValidBranchName(requested, repoPath: repoPath)
+        // Fails before fetching, since a row that has the branch will still have it after.
+        if let holder = holder(of: requested, repoPath: repoPath), !holder.isMissing {
+            throw WorkspaceError.branchCheckedOut(requested, row: holder)
+        }
+
+        var notes: [String] = []
+        var warnings: [String] = []
+        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
+        var fetchFailure: String?
+        if hasOrigin {
+            fetchFailure = await fetchUnlessFresh(repoPath: repoPath, since: requestedAt)
+            if let fetchFailure { warnings.append("\(fetchFailure), so the row starts from local refs.") }
+        }
+
+        let branch: String
+        let source: BranchSource
+        var start: String?
+        if let local = await existingBranch(requested, under: "refs/heads/", repoPath: repoPath) {
+            (branch, source) = (local, .local)
+        } else if hasOrigin,
+            let remote = await existingBranch(requested, under: "refs/remotes/origin/", repoPath: repoPath)
+        {
+            (branch, source) = (remote, .origin)
+        } else {
+            guard !existing else { throw WorkspaceError.branchNotFound(requested, fetchFailure: fetchFailure) }
+            (branch, source) = (requested, .new)
+            start = try await startPoint(base, repoPath: repoPath, hasOrigin: hasOrigin)
+        }
+        if branch != requested {
+            notes.append("Using \(branch), the branch's own spelling.")
+        }
+        try await claim(branch: branch, repoPath: repoPath)
+
+        if source == .local, hasOrigin {
+            let remote = "refs/remotes/origin/\(branch)"
+            if await git.succeeds(["show-ref", "--verify", "--quiet", remote], in: repoPath) {
+                let report = await bringUpToDate(
+                    branch, with: remote, named: "origin/\(branch)", resetTo: "origin/\(branch)", repoPath: repoPath)
+                notes += report.notes
+                warnings += report.warnings
+            } else if fetchFailure == nil, let warning = await goneUpstreamWarning(branch, repoPath: repoPath) {
+                warnings.append(warning)
+            }
+        }
+
+        let added = try await addRow(repoPath: repoPath, branch: branch) { folder in
+            switch source {
+            case .local: [folder, branch]
+            case .origin: ["--track", "-b", branch, folder, "origin/\(branch)"]
+            case .new: ["--no-track", "-b", branch, folder, start ?? "HEAD"]
+            }
+        }
+        return CreatedRow(
+            row: added.row, source: source, base: start, pullRequest: nil, notes: notes,
+            warnings: warnings + added.warnings)
+    }
+
+    /// `--branch` would expand "@{-1}" to the previous branch, and a leading "-" would read as an option.
+    func requireValidBranchName(_ branch: String, repoPath: String) async throws {
         guard !branch.hasPrefix("-"), branch != "HEAD",
             await git.succeeds(["check-ref-format", "refs/heads/\(branch)"], in: repoPath)
         else {
             throw WorkspaceError.invalidBranch(branch)
         }
-        if snapshot.repo(path: repoPath)?.allRows.contains(where: { $0.branch == branch }) == true {
-            throw WorkspaceError.branchCheckedOut(branch)
-        }
+    }
 
-        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
-        if hasOrigin, let warning = await fetchUnlessFresh(repoPath: repoPath, since: requestedAt) {
-            warnings.append(warning)
+    private func startPoint(_ base: String?, repoPath: String, hasOrigin: Bool) async throws -> String {
+        guard let base else { return await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin) }
+        guard !base.hasPrefix("-"),
+            await git.succeeds(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoPath)
+        else {
+            throw WorkspaceError.invalidBase(base)
         }
+        return base
+    }
 
+    /// Runs `git worktree add` into a new folder under the repo's Canopy folder, then lists the row last among the
+    /// repo's rows. `arguments` gets the folder and returns what follows `worktree add`. The warnings say when a
+    /// checkout hook failed after git had made the worktree.
+    func addRow(
+        repoPath: String, branch: String, arguments: (String) -> [String]
+    ) async throws -> (row: Row, warnings: [String]) {
+        let dirName = state.repos[try entryIndex(repoPath: repoPath)].dirName
         // A worktree whose folder was deleted keeps its path until it is pruned, so git would refuse to reuse it.
         await refresh(repoPath: repoPath)
         let registered = Set(snapshot.repo(path: repoPath)?.allRows.map(\.path) ?? [])
@@ -68,36 +157,16 @@ extension Workspace {
             registered.contains(Paths.canonical($0.path)) || FileManager.default.fileExists(atPath: $0.path)
         }
 
-        var arguments = ["worktree", "add"]
-        if await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoPath) {
-            arguments += [folder.path, branch]
-        } else if hasOrigin,
-            await git.succeeds(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: repoPath)
-        {
-            arguments += ["--track", "-b", branch, folder.path, "origin/\(branch)"]
-        } else {
-            let start: String
-            if let base {
-                guard !base.hasPrefix("-"),
-                    await git.succeeds(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoPath)
-                else {
-                    throw WorkspaceError.invalidBase(base)
-                }
-                start = base
-            } else {
-                start = await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin)
-            }
-            arguments += ["--no-track", "-b", branch, folder.path, start]
-        }
-
         let path = Paths.canonical(folder.path)
         changingRows[path] = .current
         defer { finishChanging([path], repoPath: repoPath) }
+        var warnings: [String] = []
         do {
-            try await git.run(arguments, in: repoPath)
+            try await git.run(["worktree", "add"] + arguments(folder.path), in: repoPath)
         } catch let error as GitError {
             if error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree") {
-                throw WorkspaceError.branchCheckedOut(branch)
+                await refresh(repoPath: repoPath)
+                throw WorkspaceError.branchCheckedOut(branch, row: holder(of: branch, repoPath: repoPath))
             }
             // A failing post-checkout hook makes git exit non-zero after the worktree is complete.
             await refresh(repoPath: repoPath)
@@ -111,7 +180,7 @@ extension Workspace {
         }
         await refresh(repoPath: repoPath)
         guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
-        return CreatedRow(row: row, warnings: warnings)
+        return (row, warnings)
     }
 
     private func removeRowNow(path: String, force: Bool, deleteBranch: Bool) async throws -> [String] {
@@ -171,20 +240,21 @@ extension Workspace {
 
     /// Parallel creates queue behind each other, so a fetch that finished after this request was made
     /// already covers it. Its outcome, including a failure, is reused rather than waiting on the network again.
+    /// Returns why the fetch failed, or nil. Pruning drops branches deleted on origin, which are no longer on it.
     private func fetchUnlessFresh(repoPath: String, since requestedAt: ContinuousClock.Instant) async -> String? {
         if let attempt = lastFetch[repoPath], attempt.finishedAt > requestedAt {
-            return attempt.warning
+            return attempt.failure
         }
-        var warning: String?
+        var failure: String?
         do {
-            try await git.run(["fetch", "--quiet", "origin"], in: repoPath, timeout: fetchTimeout)
+            try await git.run(["fetch", "--quiet", "--prune", "origin"], in: repoPath, timeout: fetchTimeout)
         } catch let error as GitError where error.timedOut {
-            warning = "git fetch timed out, so the row starts from local refs."
+            failure = "git fetch timed out"
         } catch {
-            warning = "git fetch failed, so the row starts from local refs: \(error)"
+            failure = "git fetch failed: \(error)"
         }
-        lastFetch[repoPath] = FetchAttempt(finishedAt: .now, warning: warning)
-        return warning
+        lastFetch[repoPath] = FetchAttempt(finishedAt: .now, failure: failure)
+        return failure
     }
 
     func entryIndex(repoPath: String) throws -> Int {
```

`Sources/CanopyCore/Workspace/Workspace.swift`:

```diff
@@ -254,23 +254,22 @@ public actor Workspace {
     }
 
     public func prune(repoPath: String) async throws {
+        try await serialized(repoPath: repoPath) { try await self.pruneNow(repoPath: repoPath) }
+    }
+
+    /// Prunes worktrees whose folders are gone. The caller holds the repo's git queue.
+    func pruneNow(repoPath: String) async throws {
         let missing = snapshot.repo(path: repoPath)?.allRows.filter(\.isMissing).map(\.path) ?? []
         for path in missing {
             changingRows[path] = .current
         }
         defer { finishChanging(missing, repoPath: repoPath) }
         do {
-            try await serialized(repoPath: repoPath) {
-                do {
-                    try await self.git.run(["worktree", "prune"], in: repoPath)
-                } catch let error as GitError {
-                    throw WorkspaceError.git(error)
-                }
-            }
-        } catch {
+            try await git.run(["worktree", "prune"], in: repoPath)
+        } catch let error as GitError {
             // git may have pruned some rows before it failed, and they are the caller's doing too.
             await refresh(repoPath: repoPath)
-            throw error
+            throw WorkspaceError.git(error)
         }
         await refresh(repoPath: repoPath)
     }
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -10,7 +10,10 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case missingTarget(flag: String)
     case invalidBranch(String)
     case invalidBase(String)
-    case branchCheckedOut(String)
+    /// `row` is where the branch is checked out, when Canopy knows.
+    case branchCheckedOut(String, row: Row?)
+    /// `fetchFailure` says why origin's branches may be out of date.
+    case branchNotFound(String, fetchFailure: String?)
     case worktreeDirty(String)
     case cannotRemoveMain
     case notManaged(String)
@@ -42,6 +45,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .invalidBranch: "invalid_branch"
         case .invalidBase: "invalid_base"
         case .branchCheckedOut: "branch_checked_out"
+        case .branchNotFound: "branch_not_found"
         case .worktreeDirty: "worktree_dirty"
         case .cannotRemoveMain: "cannot_remove_main"
         case .notManaged: "not_managed"
@@ -75,7 +79,20 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .missingTarget(let flag): "Could not tell which one you mean. Pass \(flag)."
         case .invalidBranch(let name): "Not a valid branch name: \(name)"
         case .invalidBase(let ref): "No commit matches --from \(ref)."
-        case .branchCheckedOut(let name): "Branch \(name) is already checked out in another worktree."
+        case .branchCheckedOut(let name, let row?):
+            switch row.rowClass {
+            case .main: "Branch \(name) is checked out in the main checkout at \(row.path)."
+            case .canopy, .adopted:
+                "Branch \(name) already has a row at \(row.path). Run `canopy row select \(name)` to show it."
+            case .external:
+                "Branch \(name) is checked out in another tool's worktree at \(row.path). "
+                    + "Run `canopy row adopt \(row.path)` to show it as a row."
+            }
+        case .branchCheckedOut(let name, nil): "Branch \(name) is already checked out in another worktree."
+        case .branchNotFound(let name, nil):
+            "No branch \(name) here or on origin. Leave out --existing to create it."
+        case .branchNotFound(let name, let failure?):
+            "No branch \(name) here or in what Canopy last saw of origin, because \(failure)."
         case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
         case .cannotRemoveMain: "The main checkout cannot be removed."
         case .notManaged(let path): "\(path) belongs to another tool. Adopt it first."
```

`docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md`:

```diff
@@ -75,7 +75,7 @@ Agents that mean to pick up someone else's work pass `--existing`.
 |---|---|
 | The local branch is only behind `origin/<branch>` | Fast-forwards it before checking it out, the way `gh pr checkout` runs `merge --ff-only`, and notes how many commits it moved. |
 | The local branch is only ahead | Checks it out as it is and notes the unpushed commits. |
-| The local branch has diverged | Checks it out as it is and warns with both counts and the two ways to fix it: `git pull --rebase` to keep the local commits, or `git reset --hard origin/<branch>` to drop them. Canopy never resets on its own. |
+| The local branch has diverged | Checks it out as it is and warns with both counts and the two ways to fix it: `git rebase origin/<branch>` to keep the local commits on top, or `git reset --hard origin/<branch>` to drop them. Canopy never resets on its own. |
 | The branch exists locally but not on origin | Checks it out as it is. If its upstream is set but gone from origin, warns that it was probably merged and deleted. If the fetch failed, keeps the warning that the row starts from local refs. |
 | The branch already has a Canopy or adopted row | Fails with `branch_checked_out`, naming the row's path and `canopy row select`. |
 | The branch is checked out in the main checkout | Fails with `branch_checked_out`, naming the main checkout. |
```

- [ ] **Step 4: Run the tests, the whole suite, and lint**

Run: the filter above, then `make test`, `make lint`, and `swift build 2>&1 | grep -c warning:`
Expected: every test passes, lint is clean, and there are 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Workspace/Workspace+Branches.swift Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift Sources/CanopyCore/Workspace/Workspace.swift Sources/CanopyCore/Workspace/WorkspaceError.swift Tests/CanopyCoreTests/ExistingBranchTests.swift Tests/CanopyCoreTests/RowLifecycleTests.swift docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md
git commit -m "feat: row new says which branch it used and brings it up to date"
```

## Task 3: Start a row from a PR

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`, `Tests/CanopyCoreTests/PullRequestRowTests.swift`, `Tests/CanopyCoreTests/Support/LocalGitHub.swift`
- Modify: `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Tests/CanopyCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's `GitHubCLI.pullRequest(repo:number:)`, `PRReference`, and `GitHubRepo.url(replacingRepoIn:)`, and Task 2's branch helpers and `addRow`.
- Produces: `Workspace.createRow(repoPath:pullRequest:branch:) async throws -> CreatedRow`.
- Produces: `PRBinding(number:repo:)` and `RepoEntry.prBindings: [String: PRBinding]`, keyed by local branch.
- Produces: `GitHubRemote` (`url`, `repo`) and `Workspace.gitHubRemote(_:repoPath:)`, which falls back to the configured URL when `get-url`'s rewritten one is not on GitHub.
- Produces: `WorkspaceError.branchExists([String], pr:)`, `pullRequestInOtherRepo(_:origin:)`, `pullRequestNotFound(_:repo:)`, and `pullRequestFetchFailed(_:reason:)`.

- [ ] **Step 1: Write the failing tests**

`LocalGitHub` is the test GitHub: bare repos under `remotes/`, a `GIT_CONFIG_COUNT` rewrite from `https://github.com/` to them, `openPR` pushing the head to the base repo's `refs/pull/<n>/head` the way GitHub does, and a stand-in gh answering from the PRs it wrote.
The fork tests pull and push through the fork's URL, which proves the tracking config works and not only that it was written.

`Tests/CanopyCoreTests/PullRequestRowTests.swift` (new):

```swift
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
```

`Tests/CanopyCoreTests/StateStoreTests.swift`:

```diff
@@ -14,7 +14,11 @@ struct StateStoreTests {
         let dir = try TempDir()
         let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
         let state = AppState(
-            repos: [RepoEntry(path: "/r", dirName: "r", adopted: ["/x"], rowOrder: ["/x"])],
+            repos: [
+                RepoEntry(
+                    path: "/r", dirName: "r", adopted: ["/x"], rowOrder: ["/x"],
+                    prBindings: ["someone/feat": PRBinding(number: 7, repo: "acme/app")])
+            ],
             selectedRowPath: "/x"
         )
 
@@ -34,6 +38,17 @@ struct StateStoreTests {
         #expect(StateStore(url: url).load() == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r")])))
     }
 
+    @Test func unreadableBindingsAreDroppedOnTheirOwn() throws {
+        let dir = try TempDir()
+        let url = URL(fileURLWithPath: dir.sub("state.json"))
+        try #"{"version": 1, "repos": [{"path": "/r", "dirName": "r", "adopted": ["/x"], "prBindings": {"b": 7}}]}"#
+            .write(to: url, atomically: true, encoding: .utf8)
+
+        #expect(
+            StateStore(url: url).load()
+                == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r", adopted: ["/x"])])))
+    }
+
     @Test func corruptFileIsBackedUp() throws {
         let dir = try TempDir()
         let url = URL(fileURLWithPath: dir.sub("state.json"))
```

`Tests/CanopyCoreTests/Support/LocalGitHub.swift` (new):

```swift
import Foundation

@testable import CanopyCore

/// A GitHub on this machine, so PR tests never reach the network. Repos are bare repos at
/// `<dir>/remotes/<owner>/<name>.git`, and `git` reaches them at https://github.com/<owner>/<name>.git through a URL
/// rewrite. `gh` answers a PR's lookup from what `openPR` wrote, and records every other query and answers it from
/// `reply`.
struct LocalGitHub {
    let dir: TempDir
    let git: GitRunner
    let gh: GitHubCLI
    private var remotes: String { dir.sub("remotes") }
    private var prs: String { dir.sub("gh-prs") }
    private var callsFile: String { dir.sub("gh-calls") }
    private var replyFile: String { dir.sub("gh-reply") }
    private var failureFile: String { dir.sub("gh-failure") }

    init(_ dir: TempDir) throws {
        self.dir = dir
        git = GitRunner(environment: Self.rewriting(to: dir.sub("remotes")))
        try FileManager.default.createDirectory(atPath: dir.sub("gh-prs"), withIntermediateDirectories: true)
        gh = try Fixture.gh(
            in: dir,
            """
            if [[ -f "\(dir.sub("gh-failure"))" ]]; then { read -r code; cat >&2; } < "\(dir.sub("gh-failure"))"; exit "$code"; fi
            query="${4#query=}"
            if [[ "$query" == *maintainerCanModify* ]]; then
                number=$(sed -E 's/.*pullRequest\\(number: ([0-9]+)\\).*/\\1/' <<< "$query")
                pr="\(dir.sub("gh-prs"))/$number.json"
                if [[ -f "$pr" ]]; then
                    printf '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": %s}}}\\n' "$(cat "$pr")"
                    exit 0
                fi
                echo '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": null}}}'
                echo "gh: Could not resolve to a PullRequest with the number of $number." >&2
                exit 1
            fi
            printf '%s\\n' "$query" >> "\(dir.sub("gh-calls"))"
            cat "\(dir.sub("gh-reply"))" 2>/dev/null || echo '{"data": {"repository": {}}}'
            """)
    }

    /// This process's environment, with https://github.com/ rewritten to `remotes`.
    static func rewriting(to remotes: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "url.\(remotes)/.insteadOf"
        environment["GIT_CONFIG_VALUE_0"] = "https://github.com/"
        return environment
    }

    /// Creates `nameWithOwner` with one commit on main.
    func createRepo(_ nameWithOwner: String) async throws {
        let seed = try await Fixture.repo(in: dir, name: "seed-\(UUID().uuidString.prefix(6))")
        try await Fixture.git.run(["clone", "--quiet", "--bare", seed, bare(nameWithOwner)])
    }

    /// Makes `fork` a copy of `base`, as forking on GitHub does.
    func fork(_ base: String, as fork: String) async throws {
        try await Fixture.git.run(["clone", "--quiet", "--bare", bare(base), bare(fork)])
    }

    /// Clones `nameWithOwner` into `<dir>/<name>` with origin at its GitHub URL, as `gh repo clone` does.
    func clone(_ nameWithOwner: String, name: String = "demo") async throws -> String {
        let path = dir.sub(name)
        try await git.run(["clone", "--quiet", "https://github.com/\(nameWithOwner).git", path])
        try await git.run(["config", "user.email", "test@example.com"], in: path)
        try await git.run(["config", "user.name", "Test"], in: path)
        return Paths.canonical(path)
    }

    /// Pushes `count` new commits on `branch` of `nameWithOwner`, starting it from main if it is new. Returns its tip.
    @discardableResult
    func push(_ count: Int = 1, to branch: String, of nameWithOwner: String) async throws -> String {
        let work = dir.sub("work/\(nameWithOwner)")
        if !FileManager.default.fileExists(atPath: work) {
            try await Fixture.git.run(["clone", "--quiet", bare(nameWithOwner), work])
            try await Fixture.git.run(["config", "user.email", "author@example.com"], in: work)
            try await Fixture.git.run(["config", "user.name", "Author"], in: work)
        }
        try await Fixture.git.run(["fetch", "--quiet", "origin"], in: work)
        let start = await Fixture.git.succeeds(["rev-parse", "--verify", "--quiet", "origin/\(branch)"], in: work)
        try await Fixture.git.run(
            ["switch", "--quiet", "--force-create", branch, start ? "origin/\(branch)" : "origin/main"], in: work)
        for index in 1...count {
            try await Fixture.git.run(["commit", "--quiet", "--allow-empty", "-m", "\(branch) \(index)"], in: work)
        }
        try await Fixture.git.run(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], in: work)
        return try await Fixture.git.run(["rev-parse", "HEAD"], in: work).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// Opens PR `number` on `base` from `branch` of `head` (default: `base` itself). GitHub keeps every PR's head at
    /// `refs/pull/<number>/head` of the base repo, so that ref is pointed at the branch's tip.
    func openPR(
        _ number: Int, on base: String, from branch: String, of head: String? = nil, state: String = "OPEN",
        maintainerCanModify: Bool = false, deleteBranch: Bool = false, forkGone: Bool = false
    ) async throws {
        let headRepo = head ?? base
        let tip = try await Fixture.git.run(["rev-parse", "refs/heads/\(branch)"], in: bare(headRepo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await Fixture.git.run(
            ["push", "--quiet", bare(base), "\(tip):refs/pull/\(number)/head"], in: bare(headRepo))
        if deleteBranch {
            try await Fixture.git.run(["branch", "--quiet", "-D", branch], in: bare(headRepo))
        }
        let parts = headRepo.split(separator: "/")
        let json: [String: Any] = [
            "number": number, "title": "PR \(number)", "url": "https://github.com/\(base)/pull/\(number)",
            "state": state, "isDraft": false, "updatedAt": "2026-09-28T00:00:00Z", "headRefName": branch,
            "headRefOid": tip, "headRef": deleteBranch ? NSNull() : ["name": branch], "baseRefName": "main",
            "isCrossRepository": headRepo != base, "maintainerCanModify": maintainerCanModify,
            "headRepository": forkGone ? NSNull() : ["name": String(parts[1])],
            "headRepositoryOwner": forkGone ? NSNull() : ["login": String(parts[0])],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: "\(prs)/\(number).json"))
    }

    /// What gh answers every query that is not a PR's lookup.
    func reply(_ json: String) {
        try? json.write(toFile: replyFile, atomically: true, encoding: .utf8)
    }

    func fail(exitCode: Int, _ message: String) {
        try? "\(exitCode)\n\(message)\n".write(toFile: failureFile, atomically: true, encoding: .utf8)
    }

    /// Every query gh was asked that was not a PR's lookup.
    var calls: [String] {
        ((try? String(contentsOfFile: callsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func bare(_ nameWithOwner: String) -> String {
        "\(remotes)/\(nameWithOwner).git"
    }

    /// A GitRunner like `git` whose git first runs `before` (bash, with the arguments in "$@").
    func git(before: String) throws -> GitRunner {
        let script = dir.sub("git-wrapper-\(UUID().uuidString.prefix(6))")
        try "#!/bin/bash\n\(before)\nexec /usr/bin/git \"$@\"\n".write(
            toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return GitRunner(executable: script, environment: Self.rewriting(to: remotes))
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'PullRequestRowTests|StateStoreTests'`
Expected: compile errors: `createRow(repoPath:pullRequest:branch:)`, `PRBinding`, and `branchExists` do not exist.

- [ ] **Step 3: Implement**

A same-repo PR with its branch still on origin fetches that branch and follows Task 2's rules.
A fork's PR, or one whose branch is gone, fetches `refs/pull/<n>/head` into `refs/canopy/pr/<n>`, which is deleted on every path out.
A branch Canopy creates is deleted again if its tracking or worktree fails.

`Sources/CanopyCore/State/AppState.swift`:

```diff
@@ -1,14 +1,33 @@
+/// The pull request a branch was started from with `row new --pr`.
+public struct PRBinding: Codable, Sendable, Equatable {
+    public var number: Int
+    /// origin's GitHub repo, as owner/name, when the branch was made. The number means nothing in another repo.
+    public var repo: String
+
+    public init(number: Int, repo: String) {
+        self.number = number
+        self.repo = repo
+    }
+}
+
 public struct RepoEntry: Codable, Sendable, Equatable {
     public var path: String
     public var dirName: String
     public var adopted: [String]
     public var rowOrder: [String]
+    /// PRs keyed by local branch, for branches whose name cannot find their PR: a fork's, or one checked out under
+    /// another name.
+    public var prBindings: [String: PRBinding]
 
-    public init(path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = []) {
+    public init(
+        path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = [],
+        prBindings: [String: PRBinding] = [:]
+    ) {
         self.path = path
         self.dirName = dirName
         self.adopted = adopted
         self.rowOrder = rowOrder
+        self.prBindings = prBindings
     }
 
     public init(from decoder: any Decoder) throws {
@@ -17,6 +36,8 @@ public struct RepoEntry: Codable, Sendable, Equatable {
         dirName = try container.decode(String.self, forKey: .dirName)
         adopted = try container.decodeIfPresent([String].self, forKey: .adopted) ?? []
         rowOrder = try container.decodeIfPresent([String].self, forKey: .rowOrder) ?? []
+        // Bindings that cannot be read only cost fork rows their badges, so the repo still loads.
+        prBindings = (try? container.decodeIfPresent([String: PRBinding].self, forKey: .prBindings)) ?? [:]
     }
 }
```

`Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift` (new):

```swift
import Foundation

extension Workspace {
    /// Creates a row on a pull request's branch, from the repo itself or from a fork, with `gh pr checkout`'s rules for
    /// naming the local branch and setting what it tracks. `branch` names the local branch instead.
    public func createRow(
        repoPath: String, pullRequest reference: PRReference, branch: String? = nil
    ) async throws -> CreatedRow {
        _ = try entryIndex(repoPath: repoPath)
        guard FileManager.default.fileExists(atPath: repoPath) else {
            throw WorkspaceError.pathNotFound(repoPath)
        }
        if let branch {
            try await requireValidBranchName(branch, repoPath: repoPath)
        }
        guard let origin = await gitHubRemote("origin", repoPath: repoPath) else {
            throw WorkspaceError.notOnGitHub(snapshot.repo(path: repoPath)?.name ?? repoPath)
        }
        if let repo = reference.repo, !repo.matches(origin.repo) {
            throw WorkspaceError.pullRequestInOtherRepo(repo.nameWithOwner, origin: origin.repo.nameWithOwner)
        }
        let head: PullRequestHead
        switch await github.pullRequest(repo: origin.repo, number: reference.number) {
        case .success(let found?):
            head = found
        case .success(nil):
            throw WorkspaceError.pullRequestNotFound(reference.number, repo: origin.repo.nameWithOwner)
        case .failure(.ghMissing):
            throw WorkspaceError.ghUnavailable(RepoPullRequests(source: .ghMissing).warning ?? "")
        case .failure(.notLoggedIn):
            throw WorkspaceError.ghUnavailable(RepoPullRequests(source: .notLoggedIn).warning ?? "")
        case .failure(.failed(let message)):
            throw WorkspaceError.ghFailed(message)
        }
        return try await serialized(repoPath: repoPath) {
            try await self.createPullRequestRowNow(repoPath: repoPath, head: head, origin: origin, branch: branch)
        }
    }

    private func createPullRequestRowNow(
        repoPath: String, head: PullRequestHead, origin: GitHubRemote, branch requested: String?
    ) async throws -> CreatedRow {
        let number = head.pullRequest.number
        // A fork's branch is not on origin, and a merged PR's branch is often deleted, but origin keeps every PR's head.
        let fromPullRef = head.isCrossRepository || !head.branchExists
        let target = fromPullRef ? "refs/canopy/pr/\(number)" : "refs/remotes/origin/\(head.branch)"
        let source = fromPullRef ? "refs/pull/\(number)/head" : "refs/heads/\(head.branch)"
        do {
            try await git.run(
                ["fetch", "--quiet", "--no-tags", "origin", "+\(source):\(target)"], in: repoPath, timeout: fetchTimeout
            )
        } catch let error as GitError {
            throw WorkspaceError.pullRequestFetchFailed(number, reason: "\(error)")
        }
        do {
            let created = try await checkOut(
                head, from: target, fromPullRef: fromPullRef, origin: origin, branch: requested, repoPath: repoPath)
            if fromPullRef { _ = try? await git.run(["update-ref", "-d", target], in: repoPath) }
            return created
        } catch {
            if fromPullRef { _ = try? await git.run(["update-ref", "-d", target], in: repoPath) }
            throw error
        }
    }

    /// Checks out the PR's head, fetched to `target`, in a new row.
    private func checkOut(
        _ head: PullRequestHead, from target: String, fromPullRef: Bool, origin: GitHubRemote,
        branch requested: String?,
        repoPath: String
    ) async throws -> CreatedRow {
        let number = head.pullRequest.number
        var notes: [String] = []
        var warnings: [String] = []
        if [.merged, .closed].contains(head.pullRequest.state) {
            warnings.append("PR #\(number) is \(head.pullRequest.state.rawValue), not open.")
        }
        if !head.isCrossRepository, !head.branchExists {
            warnings.append(
                "PR #\(number)'s branch \(head.branch) is gone from origin, so the row starts at the PR's last commit.")
        }

        let (name, exists) = try await localBranch(for: head, origin: origin, requested: requested, repoPath: repoPath)
        try await claim(branch: name, repoPath: repoPath)
        let source: BranchSource
        let added: (row: Row, warnings: [String])
        if exists {
            let tip = try await git.run(["rev-parse", target], in: repoPath).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let report = await bringUpToDate(
                name, with: target, named: fromPullRef ? "PR #\(number)'s head" : "origin/\(head.branch)",
                resetTo: fromPullRef ? tip : "origin/\(head.branch)", repoPath: repoPath)
            notes += report.notes
            warnings += report.warnings
            added = try await addRow(repoPath: repoPath, branch: name) { [$0, name] }
            source = .local
        } else if !fromPullRef {
            added = try await addRow(repoPath: repoPath, branch: name) {
                ["--track", "-b", name, $0, "origin/\(head.branch)"]
            }
            if name != head.branch {
                warnings.append(
                    "\(name) tracks origin/\(head.branch) under another name, so plain git push fails. "
                        + "Push with `git push origin HEAD:\(head.branch)`.")
            }
            source = .origin
        } else {
            do {
                try await git.run(["branch", "--no-track", name, target], in: repoPath)
            } catch let error as GitError {
                throw WorkspaceError.git(error)
            }
            do {
                warnings += try await track(name, head: head, origin: origin, repoPath: repoPath)
                added = try await addRow(repoPath: repoPath, branch: name) { [$0, name] }
            } catch {
                // Deleting the branch also drops the tracking set for it.
                _ = try? await git.run(["branch", "-D", name], in: repoPath)
                throw error
            }
            source = .origin
        }
        try bind(name, to: head, origin: origin, repoPath: repoPath)
        return CreatedRow(
            row: added.row, source: source, base: nil, pullRequest: head.pullRequest, notes: notes,
            warnings: warnings + added.warnings)
    }

    /// The local branch for the PR, and whether it exists already and is the PR's. The head's name comes first. A fork's
    /// head falls back to `<owner>/<head>` when that name is the default branch or an unrelated branch, as in gh.
    private func localBranch(
        for head: PullRequestHead, origin: GitHubRemote, requested: String?, repoPath: String
    ) async throws -> (name: String, exists: Bool) {
        let number = head.pullRequest.number
        let candidates: [String]
        if let requested {
            candidates = [requested]
        } else if !head.isCrossRepository {
            candidates = [head.branch]
        } else {
            let prefixed = head.headRepo.map { "\($0.owner)/\(head.branch)" } ?? "pr/\(number)"
            candidates = head.branch == head.defaultBranch ? [prefixed] : [head.branch, prefixed]
        }
        for candidate in candidates {
            guard let local = await existingBranch(candidate, under: "refs/heads/", repoPath: repoPath) else {
                return (candidate, false)
            }
            // A same-repo PR's head is the branch of that name, the way `row new <head>` would take it.
            if requested == nil && !head.isCrossRepository {
                return (local, true)
            }
            if await tracks(local, head: head, origin: origin, repoPath: repoPath) {
                return (local, true)
            }
        }
        throw WorkspaceError.branchExists(candidates, pr: number)
    }

    /// Whether `branch` tracks the PR: its head on origin, or its branch in the repo it comes from.
    private func tracks(_ branch: String, head: PullRequestHead, origin: GitHubRemote, repoPath: String) async -> Bool {
        func config(_ key: String) async -> String? {
            try? await git.run(["config", "--get", "branch.\(branch).\(key)"], in: repoPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let remote = await config("remote"), let merge = await config("merge") else { return false }
        let expected: GitHubRepo?
        if merge == "refs/pull/\(head.pullRequest.number)/head" {
            expected = origin.repo
        } else if merge == "refs/heads/\(head.branch)" {
            expected = head.isCrossRepository ? head.headRepo : origin.repo
        } else {
            expected = nil
        }
        guard let expected else { return false }
        // A branch's remote is a remote's name, or a URL, which is what gh pr checkout sets for a fork.
        if let named = await gitHubRemote(remote, repoPath: repoPath) {
            return named.repo.matches(expected)
        }
        return await github.repo(forRemote: remote)?.matches(expected) == true
    }

    /// Sets what a branch made from a PR's head tracks, the way gh pr checkout does, and returns warnings about pushing.
    /// When maintainers can push to the fork, the branch pulls from and pushes to it. Otherwise it pulls the PR's head
    /// from origin, and cannot push.
    private func track(
        _ name: String, head: PullRequestHead, origin: GitHubRemote, repoPath: String
    ) async throws -> [String] {
        let number = head.pullRequest.number
        var settings = [("remote", "origin"), ("merge", "refs/pull/\(number)/head")]
        var warnings: [String] = []
        if head.isCrossRepository, head.maintainerCanModify, let fork = head.headRepo,
            let url = fork.url(replacingRepoIn: origin.url)
        {
            settings = [("remote", url), ("pushRemote", url), ("merge", "refs/heads/\(head.branch)")]
            if name != head.branch {
                warnings.append(
                    "\(name) is named differently from the fork's branch \(head.branch), so plain git push fails. "
                        + "Push with `git push \(url) HEAD:\(head.branch)`.")
            }
        } else {
            let tracking = "\(name) tracks the PR on origin, where git pull works but git push does not."
            if !head.isCrossRepository {
                warnings.append("\(tracking) `git push -u origin HEAD:\(head.branch)` puts the branch back on origin.")
            } else {
                let reason =
                    head.headRepo.map { "\($0.owner)'s fork does not let maintainers push to it" }
                    ?? "The fork PR #\(number) came from is gone"
                warnings.append(
                    "\(reason), so \(tracking) To push, use a branch of your own: "
                        + "`git push -u origin HEAD:<new branch>`.")
            }
        }
        do {
            for (key, value) in settings {
                try await git.run(["config", "branch.\(name).\(key)", value], in: repoPath)
            }
        } catch let error as GitError {
            throw WorkspaceError.git(error)
        }
        return warnings
    }

    /// Saves the PR for a branch whose name cannot find it, so its row gets the PR's badge, and forgets any other.
    private func bind(_ name: String, to head: PullRequestHead, origin: GitHubRemote, repoPath: String) throws {
        guard let index = try? entryIndex(repoPath: repoPath) else { return }
        let binding =
            head.isCrossRepository || name != head.branch
            ? PRBinding(number: head.pullRequest.number, repo: origin.repo.nameWithOwner) : nil
        guard state.repos[index].prBindings[name] != binding else { return }
        state.repos[index].prBindings[name] = binding
        try save()
        _ = queuePullRequestRefresh(repoPath: repoPath)
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`:

```diff
@@ -57,7 +57,26 @@ struct RepoPullRequests: Equatable {
     }
 }
 
+/// A git remote on GitHub.
+struct GitHubRemote: Sendable, Equatable {
+    /// The URL git uses for the remote.
+    var url: String
+    var repo: GitHubRepo
+}
+
 extension Workspace {
+    /// The GitHub repo behind a remote, or nil when it is not on GitHub. `git remote get-url` applies `insteadOf`
+    /// rewrites, so a mirror can hide GitHub, and then the remote's configured URL still names the repo.
+    func gitHubRemote(_ remote: String, repoPath: String) async -> GitHubRemote? {
+        for arguments in [["remote", "get-url", remote], ["config", "--get", "remote.\(remote).url"]] {
+            guard let url = try? await git.run(arguments, in: repoPath).trimmingCharacters(in: .whitespacesAndNewlines),
+                let repo = await github.repo(forRemote: url)
+            else { continue }
+            return GitHubRemote(url: url, repo: repo)
+        }
+        return nil
+    }
+
     /// Main and external rows are never looked up, and neither is a detached HEAD.
     static func looksUpPullRequest(_ row: Row) -> Bool {
         (row.rowClass == .canopy || row.rowClass == .adopted) && row.branch != nil
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -14,6 +14,11 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case branchCheckedOut(String, row: Row?)
     /// `fetchFailure` says why origin's branches may be out of date.
     case branchNotFound(String, fetchFailure: String?)
+    /// Local branches a PR's row could have used, none of which is the PR's.
+    case branchExists([String], pr: Int)
+    case pullRequestInOtherRepo(String, origin: String)
+    case pullRequestNotFound(Int, repo: String)
+    case pullRequestFetchFailed(Int, reason: String)
     case worktreeDirty(String)
     case cannotRemoveMain
     case notManaged(String)
@@ -46,6 +51,10 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .invalidBase: "invalid_base"
         case .branchCheckedOut: "branch_checked_out"
         case .branchNotFound: "branch_not_found"
+        case .branchExists: "branch_exists"
+        case .pullRequestInOtherRepo: "invalid_pr"
+        case .pullRequestNotFound: "pr_not_found"
+        case .pullRequestFetchFailed: "git_failed"
         case .worktreeDirty: "worktree_dirty"
         case .cannotRemoveMain: "cannot_remove_main"
         case .notManaged: "not_managed"
@@ -93,6 +102,15 @@ public enum WorkspaceError: Error, Sendable, Equatable {
             "No branch \(name) here or on origin. Leave out --existing to create it."
         case .branchNotFound(let name, let failure?):
             "No branch \(name) here or in what Canopy last saw of origin, because \(failure)."
+        case .branchExists(let names, let number) where names.count == 1:
+            "Branch \(names[0]) already exists and is not PR #\(number)'s branch. Pass another --branch."
+        case .branchExists(let names, let number):
+            "Branches \(names.joined(separator: " and ")) already exist and are not PR #\(number)'s. "
+                + "Pass --branch to name the row's branch."
+        case .pullRequestInOtherRepo(let repo, let origin):
+            "That PR is in \(repo), but this repo's origin is \(origin). Pass --repo for a repo whose origin is \(repo)."
+        case .pullRequestNotFound(let number, let repo): "\(repo) has no PR #\(number)."
+        case .pullRequestFetchFailed(let number, let reason): "Could not fetch PR #\(number) from origin: \(reason)"
         case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
         case .cannotRemoveMain: "The main checkout cannot be removed."
         case .notManaged(let path): "\(path) belongs to another tool. Adopt it first."
```

- [ ] **Step 4: Run the tests, the whole suite, and lint**

Run: the filter above, then `make test`, `make lint`, and `swift build 2>&1 | grep -c warning:`
Expected: every test passes, lint is clean, and there are 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/State/AppState.swift Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift Sources/CanopyCore/Workspace/Workspace+PullRequests.swift Sources/CanopyCore/Workspace/WorkspaceError.swift Tests/CanopyCoreTests/PullRequestRowTests.swift Tests/CanopyCoreTests/StateStoreTests.swift Tests/CanopyCoreTests/Support/LocalGitHub.swift
git commit -m "feat: start a row from a PR, including a fork's"
```

## Task 4: Badges for branches bound to a PR

**Files:**
- Create: `Tests/CanopyCoreTests/PRBindingTests.swift`
- Modify: `Sources/CanopyCore/PullRequests/GitHubCLI.swift`, `Sources/CanopyCore/PullRequests/PullRequest.swift`, `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`, `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`, `Tests/CanopyCoreTests/PullRequestTests.swift`

**Interfaces:**
- Consumes: Task 3's `prBindings` and `gitHubRemote`.
- Produces: `PRQuery.build(repo:branches:numbers:)`, `GitHubCLI.pullRequests(repo:branches:numbers:)`, `Workspace.boundPullRequests(repoPath:branches:repo:)`, and `forgetPullRequest(of:repoPath:)`.

- [ ] **Step 1: Write the failing tests**

The workspace tests make a real fork PR row with `createRow(pullRequest:)` and check the query gh was sent.

`Tests/CanopyCoreTests/PRBindingTests.swift` (new):

```swift
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
```

`Tests/CanopyCoreTests/PullRequestTests.swift`:

```diff
@@ -83,6 +83,29 @@ struct PullRequestTests {
         #expect(found["d"]?.number == 3)
     }
 
+    @Test func asksForABoundBranchByItsNumber() throws {
+        let query = PRQuery.build(repo: repo, branches: ["feat/a", "someone/feat"], numbers: ["someone/feat": 7])
+
+        #expect(query.contains(#"b0: pullRequests(headRefName: "feat/a""#))
+        #expect(query.contains("b1: pullRequest(number: 7) { number title url state isDraft updatedAt"))
+        #expect(!query.contains(#"headRefName: "someone/feat""#))
+    }
+
+    @Test func aBoundBranchGetsItsPullRequestEvenFromAFork() throws {
+        let json = """
+            {"data": {"repository": {
+              "b0": {"nodes": []},
+              "b1": {"number": 7, "title": "t7", "url": "u7", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-27", "isCrossRepository": true},
+              "b2": null
+            }}}
+            """
+
+        let found = try PRQuery.parse(Data(json.utf8), branches: ["feat/a", "someone/feat", "gone"])
+
+        #expect(found.keys.sorted() == ["someone/feat"])
+        #expect(found["someone/feat"]?.number == 7)
+    }
+
     @Test func comparesReposWithoutCase() {
         #expect(GitHubRepo(owner: "NE1NN", name: "Canopy").matches(repo))
         #expect(!GitHubRepo(owner: "NE1NN", name: "canopy-2").matches(repo))
```

- [ ] **Step 2: Run them and see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'PRBindingTests|PullRequestTests'`
Expected: compile errors for `numbers:`, then, once the query builds, the five `PRBindingTests` fail on behavior.

- [ ] **Step 3: Implement**

A bound branch's alias asks for `pullRequest(number:)`, and the reply is either a connection or the PR itself, so `parse` reads both shapes and keeps fork PRs only when they were asked for by number.
The badge lookup now finds origin through `gitHubRemote`, the same way `--pr` does.

`Sources/CanopyCore/PullRequests/GitHubCLI.swift`:

```diff
@@ -49,8 +49,9 @@ public struct GitHubCLI: Sendable {
         }
     }
 
-    public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
-        let query = PRQuery.build(repo: repo, branches: branches)
+    /// `numbers` holds the PR bound to a branch whose name cannot find it.
+    public func pullRequests(repo: GitHubRepo, branches: [String], numbers: [String: Int] = [:]) async -> PRLookup {
+        let query = PRQuery.build(repo: repo, branches: branches, numbers: numbers)
         switch await run(["api", "graphql", "-f", "query=\(query)"]) {
         case .failure(.ghMissing): return .ghMissing
         case .failure(.notLoggedIn): return .notLoggedIn
```

`Sources/CanopyCore/PullRequests/PullRequest.swift`:

```diff
@@ -106,21 +106,27 @@ public struct GitHubRepo: Sendable, Equatable {
 
 /// One GraphQL request per repo, with an aliased pull request search per branch.
 public enum PRQuery {
-    public static func build(repo: GitHubRepo, branches: [String]) -> String {
-        let fields = branches.enumerated().map { index, branch in
-            """
-            b\(index): pullRequests(headRefName: \(literal(branch)), first: 100, \
-            orderBy: {field: UPDATED_AT, direction: DESC}) \
-            { nodes { number title url state isDraft updatedAt isCrossRepository } }
-            """
+    static let fields = "number title url state isDraft updatedAt isCrossRepository"
+
+    /// `numbers` holds the PR bound to a branch whose name cannot find it, which is asked for by number instead.
+    public static func build(repo: GitHubRepo, branches: [String], numbers: [String: Int] = [:]) -> String {
+        let aliases = branches.enumerated().map { index, branch in
+            if let number = numbers[branch] {
+                return "b\(index): pullRequest(number: \(number)) { \(fields) }"
+            }
+            return """
+                b\(index): pullRequests(headRefName: \(literal(branch)), first: 100, \
+                orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \(fields) } }
+                """
         }
         return "query { repository(owner: \(literal(repo.owner)), name: \(literal(repo.name))) { "
-            + fields.joined(separator: " ") + " } }"
+            + aliases.joined(separator: " ") + " } }"
     }
 
-    /// Each branch's PR: its open PR if there is one, otherwise its most recently updated. PRs from forks that
-    /// happen to use the same branch name are ignored. Comparing names instead would drop every PR of a repo that was
-    /// renamed, since GitHub answers for the old name with the new one.
+    /// Each branch's PR. A branch asked about by name gets its open PR if there is one, otherwise its most recently
+    /// updated, and PRs from forks that happen to use the same branch name are ignored. Comparing names instead would
+    /// drop every PR of a repo that was renamed, since GitHub answers for the old name with the new one. A branch
+    /// asked about by number gets that PR, from a fork or not.
     public static func parse(_ data: Data, branches: [String]) throws -> [String: PullRequest] {
         struct Node: Decodable {
             var number: Int
@@ -132,18 +138,37 @@ public enum PRQuery {
             var isCrossRepository: Bool
         }
         struct Connection: Decodable { var nodes: [Node] }
+        /// A search by name answers with a connection, and a lookup by number with the PR itself.
+        enum Field: Decodable {
+            case search([Node])
+            case bound(Node)
+
+            init(from decoder: any Decoder) throws {
+                if let connection = try? Connection(from: decoder) {
+                    self = .search(connection.nodes)
+                } else {
+                    self = .bound(try Node(from: decoder))
+                }
+            }
+        }
         struct Response: Decodable {
-            struct Payload: Decodable { var repository: [String: Connection]? }
+            struct Payload: Decodable { var repository: [String: Field?]? }
             var data: Payload?
         }
         let found = try JSONDecoder().decode(Response.self, from: data).data?.repository ?? [:]
         var result: [String: PullRequest] = [:]
         for (index, branch) in branches.enumerated() {
-            let nodes = (found["b\(index)"]?.nodes ?? []).filter { !$0.isCrossRepository }
-            guard
-                let chosen = nodes.first(where: { $0.state == "OPEN" })
-                    ?? nodes.max(by: { $0.updatedAt < $1.updatedAt })
-            else { continue }
+            let chosen: Node?
+            switch found["b\(index)"] ?? nil {
+            case .search(let nodes):
+                let own = nodes.filter { !$0.isCrossRepository }
+                chosen = own.first { $0.state == "OPEN" } ?? own.max { $0.updatedAt < $1.updatedAt }
+            case .bound(let node):
+                chosen = node
+            case nil:
+                chosen = nil
+            }
+            guard let chosen else { continue }
             result[branch] = PullRequest(
                 number: chosen.number, title: chosen.title, url: chosen.url,
                 state: PRState(gitHub: chosen.state, isDraft: chosen.isDraft), updatedAt: chosen.updatedAt)
```

`Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`:

```diff
@@ -82,6 +82,28 @@ extension Workspace {
         (row.rowClass == .canopy || row.rowClass == .adopted) && row.branch != nil
     }
 
+    /// The PRs bound to `branches`, while origin is still the repo they were bound in.
+    func boundPullRequests(repoPath: String, branches: [String], repo: GitHubRepo) -> [String: Int] {
+        let bindings = state.repos.first { $0.path == repoPath }?.prBindings ?? [:]
+        var numbers: [String: Int] = [:]
+        for branch in branches {
+            guard let binding = bindings[branch], binding.repo.lowercased() == repo.nameWithOwner.lowercased() else {
+                continue
+            }
+            numbers[branch] = binding.number
+        }
+        return numbers
+    }
+
+    /// Forgets the PR bound to `branch`, which is gone, or is about to be a new branch with the same name.
+    func forgetPullRequest(of branch: String, repoPath: String) throws {
+        guard let index = try? entryIndex(repoPath: repoPath), state.repos[index].prBindings[branch] != nil else {
+            return
+        }
+        state.repos[index].prBindings[branch] = nil
+        try save()
+    }
+
     func pullRequestBranches(repoPath: String) -> [String] {
         let rows = repoSnapshots[repoPath]?.rows ?? []
         return Set(rows.filter(Self.looksUpPullRequest).compactMap(\.branch)).sorted()
@@ -149,10 +171,12 @@ extension Workspace {
         guard state.repos.contains(where: { $0.path == repoPath }), let repo = repoSnapshots[repoPath], !repo.isMissing
         else { return }
         let branches = pullRequestBranches(repoPath: repoPath)
-        let origin = try? await git.run(["remote", "get-url", "origin"], in: repoPath)
         var lookup: PRLookup?
-        if let origin, let gitHubRepo = await github.repo(forRemote: origin) {
-            lookup = branches.isEmpty ? .found([:]) : await github.pullRequests(repo: gitHubRepo, branches: branches)
+        if let origin = await gitHubRemote("origin", repoPath: repoPath) {
+            let numbers = boundPullRequests(repoPath: repoPath, branches: branches, repo: origin.repo)
+            lookup =
+                branches.isEmpty
+                ? .found([:]) : await github.pullRequests(repo: origin.repo, branches: branches, numbers: numbers)
         }
         // The repo may have been removed while gh answered.
         guard state.repos.contains(where: { $0.path == repoPath }) else { return }
```

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`:

```diff
@@ -92,6 +92,8 @@ extension Workspace {
             guard !existing else { throw WorkspaceError.branchNotFound(requested, fetchFailure: fetchFailure) }
             (branch, source) = (requested, .new)
             start = try await startPoint(base, repoPath: repoPath, hasOrigin: hasOrigin)
+            // A PR bound to an old branch of this name is not the new branch's.
+            try forgetPullRequest(of: branch, repoPath: repoPath)
         }
         if branch != requested {
             notes.append("Using \(branch), the branch's own spelling.")
@@ -224,6 +226,7 @@ extension Workspace {
                 } catch {
                     return ["Removed the row, but could not delete branch \(branch): \(error)"]
                 }
+                try? forgetPullRequest(of: branch, repoPath: row.repoPath)
             }
             return []
         }
```

- [ ] **Step 4: Run the tests, the whole suite, and lint**

Run: the filter above, then `make test`, `make lint`, and `swift build 2>&1 | grep -c warning:`
Expected: every test passes, lint is clean, and there are 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/PullRequests/GitHubCLI.swift Sources/CanopyCore/PullRequests/PullRequest.swift Sources/CanopyCore/Workspace/Workspace+PullRequests.swift Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift Tests/CanopyCoreTests/PRBindingTests.swift Tests/CanopyCoreTests/PullRequestTests.swift
git commit -m "feat: badges for rows started from a fork's PR"
```

## Task 5: `canopy row new --pr`, `--branch`, and `--existing`

**Files:**
- Modify: `Sources/CanopyCLI/AgentGuide.swift`, `Sources/CanopyCLI/RowCommand.swift`, `Sources/CanopyCore/Control/ControlMethods.swift`, `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Tests/CanopyCoreTests/ControlProtocolTests.swift`, `Tests/CanopyCoreTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: both `createRow` calls, `PRReference`, and `BranchSource`.
- Produces: `RowNewParams` with optional `branch`, `pr` (a number or a string), and `existing`, and `RowNewResult` with `source`, `base`, `pr`, and `notes`.
- Produces: `WorkspaceError.invalidPullRequest(String)`.

- [ ] **Step 1: Write the failing tests**

`startServer` takes a `git` runner so one test can drive `--pr` over the socket against `LocalGitHub`.
An empty `row.new` now decodes, and the handler refuses it with `bad_params`.

`Tests/CanopyCoreTests/ControlProtocolTests.swift`:

```diff
@@ -28,7 +28,32 @@ struct JSONValueTests {
         #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(PortsStopParams.self) }
         let stop = try JSONValue.object(["port": .number(3000)]).decode(PortsStopParams.self)
         #expect(stop.target == TargetHint() && !stop.all)
-        #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(RowNewParams.self) }
+        #expect(!new.existing && new.pr == nil)
+    }
+
+    @Test func rowNewTakesAPullRequestAsANumberOrAString() throws {
+        let number = try JSONValue.object(["pr": .number(7)]).decode(RowNewParams.self)
+        #expect(number.pr == "7" && number.branch == nil)
+
+        let text = try JSONValue.object(["pr": .string("#7"), "branch": .string("mine")]).decode(RowNewParams.self)
+        #expect(text.pr == "#7" && text.branch == "mine")
+
+        let existing = try JSONValue.object(["branch": .string("feat/x"), "existing": .bool(true)])
+            .decode(RowNewParams.self)
+        #expect(existing.existing)
+        #expect(throws: DecodingError.self) { try JSONValue.object(["pr": .bool(true)]).decode(RowNewParams.self) }
+    }
+
+    @Test func rowNewResultsLeaveOutWhatDoesNotApply() throws {
+        let row = Row(repoPath: "/r", path: "/r/x", branch: "feat/x", head: nil, rowClass: .canopy)
+        let result = RowNewResult(
+            row: row, source: .origin, base: nil, pr: nil, notes: [], warnings: [], setup: SetupReport(status: .none),
+            pane: nil)
+
+        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
+
+        #expect(json.contains(#""source":"origin""#))
+        #expect(!json.contains(#""base""#) && !json.contains(#""pr""#))
     }
 
     @Test func aRowWithNoPullRequestSaysNull() throws {
```

`Tests/CanopyCoreTests/ControlServerTests.swift`:

```diff
@@ -13,12 +13,12 @@ final class RecordingUI: ControlUIBridge {
 }
 
 struct ControlServerTests {
-    func startServer(_ dir: TempDir, github: GitHubCLI = GitHubCLI(), logsCommands: Bool = true) async throws
-        -> (Workspace, ControlServer, ControlClient, RecordingUI)
-    {
+    func startServer(
+        _ dir: TempDir, git: GitRunner = Fixture.git, github: GitHubCLI = GitHubCLI(), logsCommands: Bool = true
+    ) async throws -> (Workspace, ControlServer, ControlClient, RecordingUI) {
         let home = CanopyHome(path: dir.sub("home"))
         let activity = ActivityLog(folder: home.activityFolder, logsCommands: logsCommands)
-        let workspace = Workspace(home: home, git: Fixture.git, github: github, activity: activity)
+        let workspace = Workspace(home: home, git: git, github: github, activity: activity)
         try await workspace.start()
         let ui = RecordingUI()
         let rows = await MainActor.run { RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)) }
@@ -364,6 +364,54 @@ struct ControlServerTests {
         #expect(texts == [nil, "ls"])
     }
 
+    @Test func rowNewStartsFromAPullRequest() async throws {
+        let dir = try TempDir()
+        let github = try LocalGitHub(dir)
+        try await github.createRepo("acme/app")
+        try await github.push(to: "feat/split", of: "acme/app")
+        try await github.openPR(7, on: "acme/app", from: "feat/split")
+        let repo = try await github.clone("acme/app")
+        let (_, server, client, _) = try await startServer(dir, git: github.git, github: github.gh)
+        defer { server.stop() }
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+
+        let created = try await call(
+            client, ControlMethod.rowNew,
+            JSONValue.object([
+                "pr": .string("https://github.com/acme/app/pull/7/files"), "target": .object(["repo": .string("demo")]),
+            ]),
+            as: RowNewResult.self)
+
+        #expect(created.row.branch == "feat/split")
+        #expect(created.source == .origin)
+        #expect(created.pr?.number == 7)
+    }
+
+    @Test func rowNewRefusesOptionsThatDoNotGoTogether() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir, origin: true)
+        let (_, server, client, _) = try await startServer(dir)
+        defer { server.stop() }
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+
+        func code(_ params: [String: JSONValue]) async throws -> String? {
+            var params = params
+            params["target"] = .object(["repo": .string("demo")])
+            let request = ControlRequest(method: ControlMethod.rowNew, params: .object(params))
+            return try await offPool { try client.send(request) }.error?.code
+        }
+        #expect(try await code([:]) == "bad_params")
+        #expect(try await code(["pr": .number(7), "base": .string("main")]) == "bad_params")
+        #expect(try await code(["pr": .number(7), "existing": .bool(true)]) == "bad_params")
+        #expect(
+            try await code(["branch": .string("feat/x"), "base": .string("main"), "existing": .bool(true)])
+                == "bad_params")
+        #expect(try await code(["pr": .string("feat/x")]) == "invalid_pr")
+        #expect(try await code(["branch": .string("feat/typo"), "existing": .bool(true)]) == "branch_not_found")
+        #expect(
+            await Fixture.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/x"], in: repo) == false)
+    }
+
     @Test func errorsCarryCodes() async throws {
         let dir = try TempDir()
         let (_, server, client, _) = try await startServer(dir)
```

- [ ] **Step 2: Run them and see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'ControlServerTests|JSONValueTests'`
Expected: compile errors: `RowNewParams` has no `pr` or `existing`, and `RowNewResult` has no `source` or `pr`.

- [ ] **Step 3: Implement**

`RowStart` refuses the combinations the CLI never sends before any git work.
The CLI checks the same combinations in `validate()`, prints which branch it used, and names `--branch`'s value `<name>` so usage does not show two `<branch>`es.

`Sources/CanopyCLI/AgentGuide.swift`:

```diff
@@ -26,7 +26,8 @@ struct AgentGuide: ParsableCommand {
             canopy repo add <path> | canopy repo list | canopy repo rm <name>
 
             canopy row list [--all]                       rows, and other tools' worktrees with --all
-            canopy row new <branch> [--from <ref>] [--run <cmd>] [--no-setup] [--select]
+            canopy row new <branch> [--from <ref> | --existing] [--run <cmd>] [--no-setup] [--select]
+            canopy row new --pr <n | #n | URL> [--branch <name>] [--run <cmd>] [--no-setup] [--select]
             canopy row rm [<branch>] [--force] [--delete-branch]
             canopy row select [<branch>]
             canopy row adopt <path>                       show another tool's worktree as a row
@@ -35,6 +36,16 @@ struct AgentGuide: ParsableCommand {
         Setup tab, waits for them, then types `--run` into a new terminal. If setup fails, the row stays, the
         command is not run, and `row new` exits 1. `row rm` runs teardown first, then removes the worktree.
 
+        `row new <branch>` fetches origin, then says in "source" which branch it used: `local` (an existing branch,
+        fast-forwarded if it was only behind origin), `origin` (a new local branch tracking origin's), or `new`
+        (created from --from, by default origin's default branch). A mistyped name makes a new branch, so pass
+        `--existing` when you mean someone else's branch: it fails with branch_not_found instead. A branch with
+        commits of its own is never reset. "notes" say what Canopy did, and "warnings" what may need you.
+
+        `row new --pr` checks out a pull request's branch, including one from a fork, with gh pr checkout's names and
+        tracking, and "pr" in the result is the PR. Pick the local name with `--branch`. A branch another row has
+        fails with branch_checked_out, which names that row; use `canopy row select` or `canopy term` there instead.
+
         ## Terminals
 
             canopy term list [--all]                      ID, row, tab, process, title, and folder
@@ -80,6 +91,10 @@ struct AgentGuide: ParsableCommand {
             pane=$(canopy row new fix/login-redirect --run 'claude "fix the login redirect, ticket FL-123"' --json | jq -r .pane)
             canopy term read "$pane" --lines 40
 
+        Review a pull request in its own row:
+
+            canopy row new --pr 123 --run 'claude "review this PR"'
+
         Run a dev server in its own tab of your row and watch it:
 
             pane=$(canopy term new --tab Server --run 'bun dev' --title 'dev server' --json | jq -r .pane)
```

`Sources/CanopyCLI/RowCommand.swift`:

```diff
@@ -41,8 +41,13 @@ struct RowCommand: AsyncParsableCommand {
         static let configuration = CommandConfiguration(
             abstract: "Create a row: a branch and a worktree under the Canopy folder.",
             discussion: """
-                An existing local branch is checked out. A branch that only exists on origin is tracked. \
-                Anything else is created from --from, which defaults to origin's default branch.
+                An existing local branch is checked out, after a fast-forward if it is only behind origin. A branch \
+                that only exists on origin is tracked. Anything else is created from --from, which defaults to \
+                origin's default branch, unless --existing asks to fail instead. A branch with commits of its own \
+                is never reset.
+
+                --pr checks out a pull request's branch, including one from a fork, named and tracked the way \
+                gh pr checkout does it.
 
                 The repo's setup commands from .canopy/config.json then run in the row's Setup tab, and this \
                 waits for them. If setup fails, the row stays, --run is skipped, and this exits 1.
@@ -50,11 +55,17 @@ struct RowCommand: AsyncParsableCommand {
         )
 
         @Argument(help: "Branch name, for example feat/login.")
-        var branch: String
+        var branch: String?
+        @Option(help: "Start from a pull request: its number, #number, or URL.")
+        var pr: String?
+        @Option(name: .customLong("branch"), help: ArgumentHelp("With --pr, the local branch name.", valueName: "name"))
+        var localBranch: String?
         @Option(help: "Repo name or path. Defaults to the repo you are in.")
         var repo: String?
         @Option(name: .customLong("from"), help: "Start point for a new branch.")
         var base: String?
+        @Flag(help: "Fail instead of creating a branch that is neither local nor on origin.")
+        var existing = false
         @Option(name: .customLong("run"), help: "Command to type into a new terminal once setup succeeds.")
         var command: String?
         @Flag(name: .customLong("no-setup"), help: "Skip the repo's setup commands.")
@@ -63,13 +74,32 @@ struct RowCommand: AsyncParsableCommand {
         var select = false
         @OptionGroup var output: OutputOptions
 
+        func validate() throws {
+            guard pr != nil else {
+                if branch == nil { throw ValidationError("Pass a branch name, or --pr.") }
+                if localBranch != nil {
+                    throw ValidationError("--branch is only for --pr. Pass the branch as the argument.")
+                }
+                if existing, base != nil {
+                    throw ValidationError("--from only applies to new branches, and --existing never creates one.")
+                }
+                return
+            }
+            if branch != nil {
+                throw ValidationError(
+                    "--pr cannot be used with a branch argument. Name the local branch with --branch.")
+            }
+            if base != nil { throw ValidationError("--from only applies to new branches, and --pr uses the PR's.") }
+            if existing { throw ValidationError("--existing is for a branch name. --pr always uses the PR's branch.") }
+        }
+
         func run() async throws {
             let client = Client(json: output.json)
             let result = client.call(
                 ControlMethod.rowNew,
                 RowNewParams(
-                    target: Client.hint(repo: repo), branch: branch, base: base, select: select, setup: !noSetup,
-                    run: command)
+                    target: Client.hint(repo: repo), branch: branch ?? localBranch, pr: pr, base: base,
+                    existing: existing, select: select, setup: !noSetup, run: command)
             )
             let created = try result.decode(RowNewResult.self)
             for warning in created.warnings {
@@ -84,7 +114,19 @@ struct RowCommand: AsyncParsableCommand {
         }
 
         private func summary(of created: RowNewResult) -> String {
-            var lines = ["Created \(created.row.displayName) at \(created.row.path)."]
+            let name = created.row.displayName
+            let path = created.row.path
+            var lines: [String]
+            if let pr = created.pr {
+                lines = ["Checked out PR #\(pr.number) as \(name) in \(path).", "\(pr.title): \(pr.url)"]
+            } else {
+                switch created.source {
+                case .local: lines = ["Checked out \(name) in \(path)."]
+                case .origin: lines = ["Checked out \(name), tracking origin/\(name), in \(path)."]
+                case .new: lines = ["Created new branch \(name) from \(created.base ?? "HEAD") in \(path)."]
+                }
+            }
+            lines += created.notes
             switch created.setup.status {
             case .succeeded: lines.append("Setup finished.")
             case .skipped: lines.append("Skipped setup.")
```

`Sources/CanopyCore/Control/ControlMethods.swift`:

```diff
@@ -119,8 +119,13 @@ public struct RowListParams: Codable, Sendable {
 
 public struct RowNewParams: Codable, Sendable {
     public var target: TargetHint
-    public var branch: String
+    /// The branch to check out or create. With `pr`, the local name for the PR's branch.
+    public var branch: String?
+    /// A pull request to start from: its number, `#number`, or URL. JSON may send the number as a number.
+    public var pr: String?
     public var base: String?
+    /// Fails with branch_not_found rather than create a branch that is neither local nor on origin.
+    public var existing: Bool
     public var select: Bool
     /// Runs the repo's setup commands. Off with `--no-setup`.
     public var setup: Bool
@@ -128,12 +133,14 @@ public struct RowNewParams: Codable, Sendable {
     public var run: String?
 
     public init(
-        target: TargetHint = TargetHint(), branch: String, base: String? = nil, select: Bool = false,
-        setup: Bool = true, run: String? = nil
+        target: TargetHint = TargetHint(), branch: String? = nil, pr: String? = nil, base: String? = nil,
+        existing: Bool = false, select: Bool = false, setup: Bool = true, run: String? = nil
     ) {
         self.target = target
         self.branch = branch
+        self.pr = pr
         self.base = base
+        self.existing = existing
         self.select = select
         self.setup = setup
         self.run = run
@@ -142,8 +149,14 @@ public struct RowNewParams: Codable, Sendable {
     public init(from decoder: any Decoder) throws {
         let container = try decoder.container(keyedBy: CodingKeys.self)
         target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
-        branch = try container.decode(String.self, forKey: .branch)
+        branch = try container.decodeIfPresent(String.self, forKey: .branch)
+        if let number = try? container.decodeIfPresent(Int.self, forKey: .pr) {
+            pr = String(number)
+        } else {
+            pr = try container.decodeIfPresent(String.self, forKey: .pr)
+        }
         base = try container.decodeIfPresent(String.self, forKey: .base)
+        existing = try container.decodeIfPresent(Bool.self, forKey: .existing) ?? false
         select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
         setup = try container.decodeIfPresent(Bool.self, forKey: .setup) ?? true
         run = try container.decodeIfPresent(String.self, forKey: .run)
@@ -152,6 +165,14 @@ public struct RowNewParams: Codable, Sendable {
 
 public struct RowNewResult: Codable, Sendable {
     public var row: Row
+    public var source: BranchSource
+    /// Where a new branch started, such as origin/main.
+    public var base: String?
+    /// The pull request the row was started from.
+    public var pr: PullRequest?
+    /// What Canopy did along the way, such as fast-forwarding the branch.
+    public var notes: [String]
+    /// What may need fixing, such as a branch that has diverged from origin.
     public var warnings: [String]
     public var setup: SetupReport
     /// The terminal started for `run`, such as "p12".
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`:

```diff
@@ -98,8 +98,16 @@ public struct WorkspaceControlHandler: Sendable {
 
         case ControlMethod.rowNew:
             let params = try request.decodeParams(RowNewParams.self)
+            let start = try RowStart(params)
             let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
-            let created = try await workspace.createRow(repoPath: repo.path, branch: params.branch, base: params.base)
+            let created =
+                switch start {
+                case .branch(let branch):
+                    try await workspace.createRow(
+                        repoPath: repo.path, branch: branch, base: params.base, existing: params.existing)
+                case .pullRequest(let reference):
+                    try await workspace.createRow(repoPath: repo.path, pullRequest: reference, branch: params.branch)
+                }
             let preparing = await rows.prepare(created.row, repoName: repo.name, setup: params.setup, run: params.run)
             if params.select {
                 await select(created.row.path)
@@ -107,7 +115,9 @@ public struct WorkspaceControlHandler: Sendable {
             let ready = await preparing.value
             return try .from(
                 RowNewResult(
-                    row: created.row, warnings: created.warnings, setup: ready.setup, pane: ready.pane?.description))
+                    row: created.row, source: created.source, base: created.base, pr: created.pullRequest,
+                    notes: created.notes, warnings: created.warnings, setup: ready.setup,
+                    pane: ready.pane?.description))
 
         case ControlMethod.rowRemove:
             let params = try request.decodeParams(RowRemoveParams.self)
@@ -204,3 +214,25 @@ public struct WorkspaceControlHandler: Sendable {
         await ui.selectRow(path: path)
     }
 }
+
+/// What `row.new` starts from, once the options the CLI never sends together are refused.
+private enum RowStart {
+    case branch(String)
+    case pullRequest(PRReference)
+
+    init(_ params: RowNewParams) throws {
+        func refuse(_ message: String) -> ControlError { ControlError(code: "bad_params", message: message) }
+        guard let text = params.pr else {
+            guard let branch = params.branch else { throw refuse("Pass a branch name, or a PR with --pr.") }
+            if params.existing, params.base != nil {
+                throw refuse("--from only applies to new branches, and --existing never creates one.")
+            }
+            self = .branch(branch)
+            return
+        }
+        if params.base != nil { throw refuse("--from only applies to new branches, and --pr uses the PR's.") }
+        if params.existing { throw refuse("--existing is for a branch name. --pr always uses the PR's branch.") }
+        guard let reference = PRReference(text) else { throw WorkspaceError.invalidPullRequest(text) }
+        self = .pullRequest(reference)
+    }
+}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -16,6 +16,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case branchNotFound(String, fetchFailure: String?)
     /// Local branches a PR's row could have used, none of which is the PR's.
     case branchExists([String], pr: Int)
+    case invalidPullRequest(String)
     case pullRequestInOtherRepo(String, origin: String)
     case pullRequestNotFound(Int, repo: String)
     case pullRequestFetchFailed(Int, reason: String)
@@ -52,7 +53,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .branchCheckedOut: "branch_checked_out"
         case .branchNotFound: "branch_not_found"
         case .branchExists: "branch_exists"
-        case .pullRequestInOtherRepo: "invalid_pr"
+        case .invalidPullRequest, .pullRequestInOtherRepo: "invalid_pr"
         case .pullRequestNotFound: "pr_not_found"
         case .pullRequestFetchFailed: "git_failed"
         case .worktreeDirty: "worktree_dirty"
@@ -107,6 +108,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .branchExists(let names, let number):
             "Branches \(names.joined(separator: " and ")) already exist and are not PR #\(number)'s. "
                 + "Pass --branch to name the row's branch."
+        case .invalidPullRequest(let text): "Pass a PR number, #number, or PR URL, not \"\(text)\"."
         case .pullRequestInOtherRepo(let repo, let origin):
             "That PR is in \(repo), but this repo's origin is \(origin). Pass --repo for a repo whose origin is \(repo)."
         case .pullRequestNotFound(let number, let repo): "\(repo) has no PR #\(number)."
```

- [ ] **Step 4: Run the tests, the whole suite, and lint**

Run: the filter above, then `make test`, `make lint`, and `swift build 2>&1 | grep -c warning:`
Expected: every test passes, lint is clean, and there are 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCLI/AgentGuide.swift Sources/CanopyCLI/RowCommand.swift Sources/CanopyCore/Control/ControlMethods.swift Sources/CanopyCore/Control/WorkspaceControlHandler.swift Sources/CanopyCore/Workspace/WorkspaceError.swift Tests/CanopyCoreTests/ControlProtocolTests.swift Tests/CanopyCoreTests/ControlServerTests.swift
git commit -m "feat: canopy row new --pr and --existing"
```

## Task 6: End-to-end cases

**Files:**
- Modify: `scripts/e2e.sh`

- [ ] **Step 1: Add the cases**

The app has to find the stand-in gh on its login PATH and get the URL rewrite, so this part launches the app itself after the earlier steps have stopped it.
The stand-in answers PR lookups, badge searches by name, and badge lookups by number from one folder of PR files.

`scripts/e2e.sh`:

```diff
@@ -267,5 +267,105 @@ done
 "$cli" log --type repo.added | grep -q demo || fail "canopy log needs the app"
 [[ -z "$(app_pid)" ]] || fail "canopy log launched the app"
 
+step "row new --pr checks out a PR's branch, from the repo and from a fork"
+# A GitHub on this machine: bare repos in $work/remotes, which git reaches at https://github.com/ through a URL rewrite,
+# and a stand-in gh that answers from the PRs in $work/prs. The app gets both only when this script launches it.
+mkdir -p "$work/prbin" "$work/przdot" "$work/prs"
+git clone -q --bare "$work/demo" "$work/remotes/acme/shop.git"
+git clone -q --bare "$work/demo" "$work/remotes/someone/shop.git"
+git clone -q "$work/remotes/acme/shop.git" "$work/prwork"
+author() { git -C "$work/prwork" -c user.email=e2e@example.com -c user.name=e2e "$@"; }
+author switch -q -c feat/checkout
+author commit -q --allow-empty -m "checkout in steps"
+author push -q origin feat/checkout feat/checkout:refs/pull/21/head
+author switch -q -c feat/fork main
+author commit -q --allow-empty -m "a fix from a fork"
+author push -q "$work/remotes/someone/shop.git" feat/fork
+author push -q origin feat/fork:refs/pull/22/head
+write_pr() { # number, head branch, head owner, maintainerCanModify
+    /usr/bin/python3 - "$work/prs/$1.json" "$1" "$2" "$3" "$4" "$(author rev-parse "$2")" <<'EOF'
+import json, sys
+path, number, branch, owner, editable, oid = sys.argv[1:]
+json.dump({"number": int(number), "title": f"PR {number}", "url": f"https://github.com/acme/shop/pull/{number}",
+           "state": "OPEN", "isDraft": False, "updatedAt": "2026-09-28T00:00:00Z", "headRefName": branch,
+           "headRefOid": oid, "headRef": {"name": branch}, "baseRefName": "main",
+           "isCrossRepository": owner != "acme", "maintainerCanModify": editable == "true",
+           "headRepository": {"name": "shop"}, "headRepositoryOwner": {"login": owner}}, open(path, "w"))
+EOF
+}
+write_pr 21 feat/checkout acme false
+write_pr 22 feat/fork someone true
+cat > "$work/prbin/gh" <<'GH'
+#!/usr/bin/python3
+import json, os, re, sys
+prs = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prs")
+query = next(a[6:] for a in sys.argv if a.startswith("query="))
+def load(number):
+    path = os.path.join(prs, f"{number}.json")
+    return json.load(open(path)) if os.path.exists(path) else None
+if "maintainerCanModify" in query:
+    number = re.search(r"pullRequest\(number: (\d+)\)", query).group(1)
+    pr = load(number)
+    print(json.dumps({"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": pr}}}))
+    if pr is None:
+        sys.stderr.write(f"gh: Could not resolve to a PullRequest with the number of {number}.\n")
+        sys.exit(1)
+    sys.exit(0)
+def node(pr):
+    return {key: pr[key] for key in ("number", "title", "url", "state", "isDraft", "updatedAt", "isCrossRepository")}
+everything = [load(name[:-5]) for name in os.listdir(prs)]
+repo = {}
+for alias, number in re.findall(r"(b\d+): pullRequest\(number: (\d+)\)", query):
+    repo[alias] = node(load(number)) if load(number) else None
+for alias, branch in re.findall(r'(b\d+): pullRequests\(headRefName: "([^"]*)"', query):
+    repo[alias] = {"nodes": [node(pr) for pr in everything if pr["headRefName"] == branch]}
+print(json.dumps({"data": {"repository": repo}}))
+GH
+chmod +x "$work/prbin/gh"
+printf 'export PATH="%s/prbin:$PATH"\n' "$work" > "$work/przdot/.zshrc"
+(ZDOTDIR="$work/przdot" SHELL=/bin/zsh GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/remotes/.insteadOf" \
+    GIT_CONFIG_VALUE_0=https://github.com/ exec "$app/Contents/MacOS/Canopy" </dev/null >/dev/null 2>&1) &
+# cleanup stops it, and bash would otherwise report the job it killed.
+disown
+for _ in $(seq 1 100); do
+    [[ -n "$(app_pid)" ]] && break
+    sleep 0.1
+done
+[[ -n "$(app_pid)" ]] || fail "the app did not start"
+git clone -q "$work/remotes/acme/shop.git" "$work/shop"
+git -C "$work/shop" remote set-url origin https://github.com/acme/shop.git
+"$cli" repo add "$work/shop" >/dev/null
+field() { /usr/bin/python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))
+for key in sys.argv[2].split("."): v = v[key]
+print(v)' "$@"; }
+"$cli" row new --pr 21 --repo shop --no-setup --json > "$work/pr21.json"
+[[ "$(field "$work/pr21.json" row.branch)" == feat/checkout ]] || fail "PR 21 is not on feat/checkout"
+[[ "$(field "$work/pr21.json" source)" == origin ]] || fail "PR 21's branch did not come from origin"
+[[ "$(field "$work/pr21.json" pr.number)" == 21 ]] || fail "the result does not name PR 21"
+row21="$(field "$work/pr21.json" row.path)"
+[[ "$(git -C "$row21" rev-parse --abbrev-ref '@{upstream}')" == origin/feat/checkout ]] || fail "PR 21 tracks the wrong branch"
+"$cli" row new --pr https://github.com/acme/shop/pull/22/files --repo shop --no-setup --select > "$work/pr22.txt"
+grep -q "^Checked out PR #22 as feat/fork in " "$work/pr22.txt" || fail "row new --pr printed $(cat "$work/pr22.txt")"
+[[ "$(git -C "$work/shop" config branch.feat/fork.pushRemote)" == https://github.com/someone/shop.git ]] ||
+    fail "the fork PR does not push to the fork"
+[[ "$(git -C "$work/shop" log -1 --format=%s feat/fork)" == "a fix from a fork" ]] || fail "the fork's commit is missing"
+
+step "a fork PR's row gets its badge"
+"$cli" pr feat/fork --repo shop --refresh --json > "$work/pr22-badge.json"
+[[ "$(field "$work/pr22-badge.json" pr.number)" == 22 ]] || fail "the fork PR row has no PR"
+sleep 1
+swift scripts/window-shot.swift "$(app_pid)" "$shots/pr-fork.png"
+echo "saved $shots/pr-fork.png"
+
+step "row new says which branch it used, and --existing refuses a name that matches nothing"
+git -C "$work/shop" branch feat/local
+"$cli" row new feat/local --repo shop --no-setup | grep -q "^Checked out feat/local in " || fail "feat/local was not checked out"
+"$cli" row new feat/brand-new --repo shop --no-setup | grep -q "^Created new branch feat/brand-new from origin/main in " ||
+    fail "feat/brand-new does not say it is new"
+if "$cli" row new feat/typo --repo shop --existing --json > "$work/typo.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"branch_not_found"' "$work/typo.json" || fail "missing branch_not_found"
+if git -C "$work/shop" show-ref --verify --quiet refs/heads/feat/typo; then fail "--existing created a branch"; fi
+"$cli" agent-guide | grep -q "row new --pr" || fail "agent-guide is missing row new --pr"
+
 echo
 echo "e2e passed"
```

- [ ] **Step 2: Run them**

Run: `make e2e`
Expected: "e2e passed", with `build/e2e/pr-fork.png` showing `feat/fork` with a green `#22`.

- [ ] **Step 3: Commit**

```bash
git add scripts/e2e.sh
git commit -m "test: e2e cases for row new --pr and --existing"
```

## After Review

An independent reviewer (opus) read `git diff main...feat/pull-branches` against the spec and this plan.
It found four Important and seven Minor issues, and nothing Critical.
Each was reproduced or traced in the code before it was fixed, and each fix has a test that failed first.
The fixes are one commit after Task 6, so the task code above is as first built.

1. **Important: a packed branch typed in another case was hidden by a new branch.**
   `existingBranch` matched without regard to case only when `show-ref` found the name, which it does for loose refs and not for packed ones.
   `row new Feat` next to a packed `feat` then created a loose `Feat`, and on APFS `feat` read that file and pointed at main.
   The lookup now lists refs with `for-each-ref` and matches without regard to case on any file system, exact spelling first.
   `usesABranchsOwnSpelling` runs with loose and packed refs, and checks that the branch did not move.
2. **Important: a PR's head name went into git arguments unchecked.**
   A fork branch named `-M` would have made `git branch --no-track -M refs/canopy/pr/9` rename the main checkout's branch.
   Head names now pass the same check as `--branch`, and a head that fails it gets `pr/<n>`.
3. **Important: `row new <branch>` kept a stale binding when it created the branch from origin.**
   Only the `new` source dropped it.
   Now every branch Canopy creates drops it.
4. **Important: one bound PR that GitHub cannot find broke every badge in the repo.**
   gh exits 1 when any alias fails to resolve, so the whole lookup failed until the branch was deleted.
   The lookup now drops the binding gh names and asks again, and both stand-in gh's fail the way gh does.
5. **Minor: the fast-forward read the branch and its target twice**, so a force-push between the reads could move the branch to a commit that does not descend from it.
6. **Minor: the fast-forward ran before git had checked that no other worktree holds the branch.**
   A worktree in the middle of a rebase lists as detached, so `claim` missed it, and `update-ref` moved the branch under the rebase.
   `compare` now reads both commits once and counts between them.
   The fast-forward runs as `git merge --ff-only <commit>` in the new row, after `worktree add` has succeeded, as gh does.
   `neverMovesABranchThatIsBeingRebasedElsewhere` covers it.
7. **Minor: `claim` pruned every missing worktree**, not only the one holding the branch, against the spec.
   It now runs `git worktree remove` on that one worktree, which works on a missing folder, and the `pruneNow` split is gone.
8. **Minor: a same-repo PR failed in a single-branch clone**, because `--track` needs a fetch refspec that covers the head.
   Every PR branch is now made with `--no-track`, and its tracking is set by hand.
9. **Minor: a failed fetch could leave the temporary ref behind**, when the fetch wrote it before failing or an earlier run had.
   It is now deleted on that path too.
10. **Minor: `canopy row new --branch x` said to pass a branch name.**
    It now says `--branch` is only for `--pr`.
11. **Minor: missing tests.**
    Added: a fork PR already in a row, both fork names taken, a gone fork whose head name is taken, and `--branch` naming a branch that tracks another PR.
    The case test no longer returns early on a case-sensitive file system, since the lookup no longer depends on it.
    The plan's header line keeps the template's wording.

The reviewer confirmed the refspecs, the tracking config, the naming rules, that nothing calls a queued method from inside the queue, the badge matching, the control API, and state compatibility.
