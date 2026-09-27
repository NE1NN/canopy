# Canopy PR Badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each row's pull request in the sidebar, colored by state and one click from GitHub, and let agents read it with `canopy pr`.

**Architecture:** `CanopyCore` builds one GraphQL query per repo, with an aliased `pullRequests(headRefName:)` field per Canopy or adopted row, and runs it through the user's own `gh`, so Canopy never holds a token.
The workspace keeps what each repo's latest lookup found, merges it into rows as `Row.pullRequest` when it publishes a snapshot, and schedules lookups: when rows appear, every minute, when the app comes to the front, and often for two minutes after a push.
The sidebar draws a pull request glyph and number for rows with a PR, and a warning under the repo's name when `gh` cannot answer.
Watcher minors 10 and 11 from the PR 2 to 4 review are fixed first, since the push trigger leans on the watcher.

**Tech Stack:** Swift 6.2, SwiftUI, FSEvents, swift-argument-parser, Swift Testing, GitHub CLI (`gh api graphql`).

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Sidebar rows", "PR badges", and `canopy pr` under "Commands".

## Global Constraints

- One `gh api graphql` call per repo per lookup. Main rows, external rows, and detached HEADs are never looked up.
- Only PRs whose head repository is the repo itself count, so forks with the same branch name are ignored.
- A row's PR is its open PR if there is one, otherwise its most recently updated PR. An open draft shows as draft.
- Colors: green for open, gray for draft, purple for merged, red for closed.
- Refresh every 60 seconds; when the app comes to the front, at most once every 15 seconds; every 10 seconds for two minutes after a push is seen in `.git/refs/remotes/` or `.git/packed-refs`; and on `canopy pr --refresh`.
- `gh` missing or logged out hides badges, and the repo shows a warning with the fix. An origin that is not on GitHub shows no badges and no warning.
- Clicking the PR number opens the PR. Clicking anywhere else on the row selects it.
- Never block a Swift concurrency thread: `gh` runs through `Subprocess` on a dispatch queue, like git.

## Review Focus

1. **A fork that happens to use the same branch name** must not put its PR on the row. Pinned by `picksOpenFirstThenLatestAndIgnoresForks` in Task 1.
2. **A logged-out `gh`, or a revoked token that comes back as HTTP 401,** must hide badges and say to run `gh auth login`, not keep showing stale PRs. Pinned by `reportsLoggedOutGH`, `treatsARejectedTokenAsLoggedOut`, and `loggedOutGHHidesBadgesAndSaysHowToFixIt` in Task 3.
3. **A flaky network** must keep the last badges rather than blank the sidebar, and say what went wrong. Pinned by `aFailedLookupKeepsTheLastBadges` in Task 3.
4. **An app launched from Finder whose login PATH could not be read** must still find a Homebrew `gh`. Pinned by `findsGHInHomebrewWhenPATHLacksIt` in Task 3.
5. **A `gh` that hangs** must not hold a repo's lookups forever. Pinned by `stopsAHungGH` in Task 3.

---

## Task 1: Find a branch's pull request from one GraphQL query per repo

**Files:** Create `Sources/CanopyCore/PullRequests/PullRequest.swift`. Test `Tests/CanopyCoreTests/PullRequestTests.swift`.

**Interfaces:** Produces `PRState` (`open`, `draft`, `merged`, `closed`), `PullRequest` (`number`, `title`, `url`, `state`, `updatedAt`), `GitHubRepo(remoteURL:)` with `owner`, `name`, and `nameWithOwner`, `PRQuery.build(repo:branches:) -> String`, and `PRQuery.parse(_:repo:branches:) throws -> [String: PullRequest]`.
Branch `i` is aliased `b<i>` in the query, so callers must pass the same branch order to `build` and `parse`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PullRequestTests.swift` (new):

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PullRequestTests`
Expected: does not compile, `GitHubRepo` and `PRQuery` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/PullRequests/PullRequest.swift` (new):

```swift
import Foundation

public enum PRState: String, Codable, Sendable {
    case open, draft, merged, closed
}

public struct PullRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: PRState
    public var updatedAt: String

    public init(number: Int, title: String, url: String, state: PRState, updatedAt: String) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// The GitHub repository behind an `origin` remote.
public struct GitHubRepo: Sendable, Equatable {
    public var owner: String
    public var name: String

    public var nameWithOwner: String { "\(owner)/\(name)" }

    /// Reads https, ssh, and scp-style GitHub remotes. Anything else has no GitHub repo.
    public init?(remoteURL: String) {
        var path = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["git@github.com:", "https://github.com/", "http://github.com/", "ssh://git@github.com/"]
        guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { return nil }
        path = String(path.dropFirst(prefix.count))
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }
}

/// One GraphQL request per repo, with an aliased pull request search per branch.
public enum PRQuery {
    public static func build(repo: GitHubRepo, branches: [String]) -> String {
        let fields = branches.enumerated().map { index, branch in
            """
            b\(index): pullRequests(headRefName: \(literal(branch)), first: 10, \
            orderBy: {field: UPDATED_AT, direction: DESC}) \
            { nodes { number title url state isDraft updatedAt headRepository { nameWithOwner } } }
            """
        }
        return "query { repository(owner: \(literal(repo.owner)), name: \(literal(repo.name))) { "
            + fields.joined(separator: " ") + " } }"
    }

    /// Each branch's PR: its open PR if there is one, otherwise its most recently updated. PRs from forks that
    /// happen to use the same branch name are ignored.
    public static func parse(_ data: Data, repo: GitHubRepo, branches: [String]) throws -> [String: PullRequest] {
        struct Node: Decodable {
            struct Head: Decodable { var nameWithOwner: String }
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var headRepository: Head?
        }
        struct Connection: Decodable { var nodes: [Node] }
        struct Response: Decodable {
            struct Payload: Decodable { var repository: [String: Connection]? }
            var data: Payload?
        }
        let found = try JSONDecoder().decode(Response.self, from: data).data?.repository ?? [:]
        var result: [String: PullRequest] = [:]
        for (index, branch) in branches.enumerated() {
            let nodes = (found["b\(index)"]?.nodes ?? []).filter {
                $0.headRepository?.nameWithOwner.lowercased() == repo.nameWithOwner.lowercased()
            }
            guard
                let chosen = nodes.first(where: { $0.state == "OPEN" })
                    ?? nodes.max(by: { $0.updatedAt < $1.updatedAt })
            else { continue }
            let state: PRState =
                switch chosen.state {
                case "OPEN": chosen.isDraft ? .draft : .open
                case "MERGED": .merged
                default: .closed
                }
            result[branch] = PullRequest(
                number: chosen.number, title: chosen.title, url: chosen.url, state: state, updatedAt: chosen.updatedAt)
        }
        return result
    }

    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`. Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: find a branch's pull request from one GraphQL query per repo"
```

## Task 2: Keep directory watchers alive for their callbacks

Fixes carried-over review minors 10 and 11.
The push trigger in Task 3 adds work to every watcher event, so both are fixed first.

Minor 10: the FSEvents context held the watcher unretained, so releasing a watcher while the stream delivered an event touched freed memory.
The stress test below aborts every run on the old code with "Object of class DirectoryWatcher deallocated with non-zero retain count".
The stream now holds its own reference to a small handler box, taken through the context's `retain` and `release` callbacks.

Minor 11: `watch(repoPath:)` stored the watcher after awaiting git, so a repo removed during `addRepo` kept a live watcher.
It now checks the repo is still registered after the await.

**Files:** Modify `Sources/CanopyCore/Watch/DirectoryWatcher.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`. Test `Tests/CanopyCoreTests/WatchTests.swift`.

- [ ] **Step 1: Write the failing tests**

The stress test writes files from a plain `Thread`. A busy loop on a Swift concurrency thread would starve the test, since `make test` limits the pool with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.

`Tests/CanopyCoreTests/WatchTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/WatchTests.swift
+++ b/Tests/CanopyCoreTests/WatchTests.swift
@@ -44,3 +44,50 @@ struct DirectoryWatcherTests {
         _ = watcher
     }
 }
+
+final class StopFlag: Sendable {
+    let value = Atomic(false)
+}
+
+struct WatcherLifetimeTests {
+    @Test func removingARepoWhileItIsBeingAddedLeavesNoWatcher() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let started = dir.sub("rev-parse-started")
+        let release = dir.sub("rev-parse-release")
+        let git = try Fixture.git(
+            in: dir,
+            before: """
+                if [[ "$1" == "rev-parse" ]]; then touch "\(started)"; while [[ ! -f "\(release)" ]]; do sleep 0.05; done; fi
+                """)
+        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
+        try await workspace.start()
+
+        let adding = Task { try await workspace.addRepo(path: repo) }
+        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
+        try await workspace.removeRepo(path: repo)
+        FileManager.default.createFile(atPath: release, contents: nil)
+        _ = try? await adding.value
+
+        #expect(await workspace.watchers.isEmpty)
+    }
+
+    @Test func releasingAWatcherWhileEventsArriveIsSafe() async throws {
+        let dir = try TempDir()
+        let stop = StopFlag()
+        // A thread of its own: a busy loop on a Swift concurrency thread would starve the test.
+        Thread {
+            var count = 0
+            while !stop.value.load(ordering: .relaxed) {
+                FileManager.default.createFile(atPath: dir.sub("f\(count % 50)"), contents: Data([1]))
+                count += 1
+            }
+        }.start()
+        for _ in 0..<200 {
+            let watcher = DirectoryWatcher(paths: [dir.path], latency: 0) { _ in usleep(200) }
+            try await Task.sleep(for: .milliseconds(Int.random(in: 1...8)))
+            _ = watcher
+        }
+        stop.value.store(true, ordering: .relaxed)
+    }
+}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter WatcherLifetimeTests`
Expected: `removingARepoWhileItIsBeingAddedLeavesNoWatcher` fails its expectation, and `releasingAWatcherWhileEventsArriveIsSafe` aborts the test process with signal 6.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Watch/DirectoryWatcher.swift` (modify):

```diff
--- a/Sources/CanopyCore/Watch/DirectoryWatcher.swift
+++ b/Sources/CanopyCore/Watch/DirectoryWatcher.swift
@@ -5,28 +5,45 @@ import Foundation
 public final class DirectoryWatcher: @unchecked Sendable {
     private var stream: FSEventStreamRef?
     private let queue = DispatchQueue(label: "canopy.directory-watcher")
-    private let onChange: @Sendable ([String]) -> Void
+
+    /// What the stream calls. The stream holds its own reference, so a callback already running when the
+    /// watcher is released never touches freed memory.
+    private final class Handler: Sendable {
+        let onChange: @Sendable ([String]) -> Void
+
+        init(_ onChange: @escaping @Sendable ([String]) -> Void) {
+            self.onChange = onChange
+        }
+    }
 
     public init(paths: [String], latency: TimeInterval = 0.1, onChange: @escaping @Sendable ([String]) -> Void) {
-        self.onChange = onChange
+        let handler = Handler(onChange)
         var context = FSEventStreamContext(
             version: 0,
-            info: Unmanaged.passUnretained(self).toOpaque(),
-            retain: nil,
-            release: nil,
+            info: Unmanaged.passUnretained(handler).toOpaque(),
+            retain: { info in
+                guard let info else { return nil }
+                _ = Unmanaged<Handler>.fromOpaque(info).retain()
+                return info
+            },
+            release: { info in
+                guard let info else { return }
+                Unmanaged<Handler>.fromOpaque(info).release()
+            },
             copyDescription: nil
         )
         let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
             guard let info else { return }
-            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
+            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
             let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
-            watcher.onChange(Array(paths.prefix(count)))
+            handler.onChange(Array(paths.prefix(count)))
         }
         let flags = FSEventStreamCreateFlags(
             kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
         )
-        guard
-            let stream = FSEventStreamCreate(
+        // Swift may release the handler after its last use, which would be before the stream retains it.
+        let created = withExtendedLifetime(handler) {
+            FSEventStreamCreate(
                 nil,
                 callback,
                 &context,
@@ -35,7 +52,8 @@ public final class DirectoryWatcher: @unchecked Sendable {
                 latency,
                 flags
             )
-        else { return }
+        }
+        guard let stream = created else { return }
         self.stream = stream
         FSEventStreamSetDispatchQueue(stream, queue)
         FSEventStreamStart(stream)
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -337,6 +337,8 @@ public actor Workspace {
                 in: repoPath
             )
         else { return }
+        // The repo may have been removed while git answered.
+        guard state.repos.contains(where: { $0.path == repoPath }) else { return }
         let canonicalGitDir = Paths.canonical(gitDir.trimmingCharacters(in: .whitespacesAndNewlines))
         watchers[repoPath] = DirectoryWatcher(paths: [canonicalGitDir]) { [weak self] paths in
             guard paths.contains(where: { GitEventFilter.isRelevant(eventPath: $0, gitDir: canonicalGitDir) }) else {
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times. Expected: every run passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "fix: keep directory watchers alive for their callbacks and never leak one"
```

## Task 3: Look up each row's pull request through gh, and keep it fresh

**Files:** Create `Sources/CanopyCore/PullRequests/GitHubCLI.swift`, `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`. Modify `Row.swift`, `WorkspaceSnapshot.swift`, `GitEventFilter.swift`, `Workspace.swift`. Test `Tests/CanopyCoreTests/GitHubCLITests.swift`, `Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift`, `WatchTests.swift`, and the `Fixture.gh` helper.

**Interfaces:**
- Consumes `PRQuery`, `GitHubRepo`, and `PullRequest` from Task 1.
- Produces `GitHubCLI(environment:timeout:fallbackFolders:)` and `pullRequests(repo:branches:) async -> PRLookup` (`found`, `ghMissing`, `notLoggedIn`, `failed(String)`).
- Produces `PRTiming` (`interval`, `focusGap`, `afterPushInterval`, `afterPushDuration`, and `.standard`), and `Workspace(home:git:fetchTimeout:github:prTiming:)`.
- Produces `Workspace.refreshPullRequests(repoPath:)`, `refreshAllPullRequests()`, `applicationBecameActive()`, and `GitEventFilter.isRemoteRefChange(eventPath:gitDir:)`.
- Produces `Row.pullRequest` (JSON key `"pr"`) and `RepoSnapshot.pullRequestWarning`.

How lookups are scheduled:
- `queuePullRequestRefresh(repoPath:)` chains lookups of one repo, so an older answer never replaces a newer one. A lookup that is queued but not started covers anyone asking after it was queued, so later callers share it instead of queueing another.
- `refreshNow` queues a lookup whenever the repo's set of looked-up branches changes, which covers launch, new rows, and removed rows.
- A timer calls `refreshAllPullRequests` every `interval`. `applicationBecameActive` does too, at most once per `focusGap`.
- The repo's watcher reports remote-tracking ref writes. The first starts a task that refreshes every `afterPushInterval`, and each one pushes the end of the window out to `afterPushDuration` from now.
- `gh` missing or logged out clears the repo's PRs. Any other failure keeps them and records the message, which becomes the warning.

`gh` exits 4 when it has no login, and an expired or revoked token comes back as exit 1 with `HTTP 401` on stderr, so both count as logged out.
The app's own PATH comes from launchd, so `gh` is searched on the user's login PATH, then in Homebrew's folders.

- [ ] **Step 1: Write the failing tests**

The workspace tests drive a fake `gh` that logs each query and answers from files the test writes, so they cover the real `GitHubCLI` process handling too.

`Tests/CanopyCoreTests/GitHubCLITests.swift` (new):

```swift
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
            echo '{"data": {"repository": {"b0": {"nodes": [{"number": 3, "title": "Fix it", "url": "https://x/3", "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-28T01:00:00Z", "headRepository": {"nameWithOwner": "NE1NN/canopy"}}]}}}}'
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
}
```

`Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift` (new):

```swift
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
```

`Tests/CanopyCoreTests/Support/Fixtures.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/Support/Fixtures.swift
+++ b/Tests/CanopyCoreTests/Support/Fixtures.swift
@@ -36,6 +36,15 @@ enum Fixture {
         return GitRunner(executable: script, environment: ProcessInfo.processInfo.environment)
     }
 
+    /// A GitHubCLI whose `gh` is a bash script running `body`, alone on PATH.
+    static func gh(in dir: TempDir, _ body: String, timeout: Duration = .seconds(30)) throws -> GitHubCLI {
+        let bin = dir.sub("gh-bin")
+        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
+        try "#!/bin/bash\n\(body)\n".write(toFile: bin + "/gh", atomically: true, encoding: .utf8)
+        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/gh")
+        return GitHubCLI(environment: ["PATH": bin + ":/usr/bin:/bin", "HOME": dir.path], timeout: timeout)
+    }
+
     static func worktree(repo: String, branch: String, at path: String) async throws {
         try FileManager.default.createDirectory(
             atPath: (path as NSString).deletingLastPathComponent,
```

`Tests/CanopyCoreTests/WatchTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/WatchTests.swift
+++ b/Tests/CanopyCoreTests/WatchTests.swift
@@ -22,6 +22,15 @@ struct GitEventFilterTests {
         #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/logs/HEAD", gitDir: gitDir))
         #expect(!GitEventFilter.isRelevant(eventPath: "/r/.gitignore", gitDir: gitDir))
     }
+
+    @Test func remoteRefWritesMeanAPush() {
+        #expect(GitEventFilter.isRemoteRefChange(eventPath: "/r/.git/refs/remotes/origin/feat/x", gitDir: gitDir))
+        #expect(GitEventFilter.isRemoteRefChange(eventPath: "/r/.git/packed-refs", gitDir: gitDir))
+        #expect(!GitEventFilter.isRemoteRefChange(eventPath: "/r/.git/refs/remotes/origin/x.lock", gitDir: gitDir))
+        #expect(!GitEventFilter.isRemoteRefChange(eventPath: "/r/.git/packed-refs.lock", gitDir: gitDir))
+        #expect(!GitEventFilter.isRemoteRefChange(eventPath: "/r/.git/refs/heads/feat/x", gitDir: gitDir))
+        #expect(!GitEventFilter.isRemoteRefChange(eventPath: "/r/.git/HEAD", gitDir: gitDir))
+    }
 }
 
 final class EventLog: Sendable {
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'GitHubCLITests|PullRequestWorkspaceTests|GitEventFilterTests'`
Expected: does not compile, `GitHubCLI`, `PRTiming`, and `isRemoteRefChange` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/PullRequests/GitHubCLI.swift` (new):

```swift
import Foundation

public enum PRLookup: Sendable, Equatable {
    /// Each looked-up branch that has a PR.
    case found([String: PullRequest])
    case ghMissing
    case notLoggedIn
    case failed(String)
}

/// Asks GitHub about pull requests through the user's own `gh`, so Canopy never handles a token.
public struct GitHubCLI: Sendable {
    private let environment: [String: String]?
    private let timeout: Duration
    private let fallbackFolders: [String]

    /// Where Homebrew puts gh, searched after PATH for when the login PATH could not be read.
    public static let homebrewFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// With no environment, gh gets this process's environment with the user's login PATH.
    public init(
        environment: [String: String]? = nil, timeout: Duration = .seconds(30),
        fallbackFolders: [String] = homebrewFolders
    ) {
        self.environment = environment
        self.timeout = timeout
        self.fallbackFolders = fallbackFolders
    }

    public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: lookUpBlocking(repo: repo, branches: branches))
            }
        }
    }

    private func lookUpBlocking(repo: GitHubRepo, branches: [String]) -> PRLookup {
        var environment = environment ?? GitEnvironment.current
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard
            let executable = (folders + fallbackFolders).lazy.map({ $0 + "/gh" }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { return .ghMissing }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"

        let query = PRQuery.build(repo: repo, branches: branches)
        let result: SubprocessResult
        do {
            result = try Subprocess.run(
                executable, ["api", "graphql", "-f", "query=\(query)"], environment: environment, directory: nil,
                timeout: timeout)
        } catch {
            return .failed("\(error)")
        }
        if result.timedOut { return .failed("gh did not answer in time.") }
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
        if result.status == 4 || message.contains("HTTP 401") { return .notLoggedIn }
        guard result.status == 0 else {
            let line = message.split(separator: "\n").last.map(String.init) ?? "gh exited with \(result.status)."
            return .failed(line.hasPrefix("gh: ") ? String(line.dropFirst(4)) : line)
        }
        do {
            return .found(try PRQuery.parse(result.stdout, repo: repo, branches: branches))
        } catch {
            return .failed("gh returned a reply Canopy could not read.")
        }
    }
}
```

`Sources/CanopyCore/Rows/Row.swift` (modify):

```diff
--- a/Sources/CanopyCore/Rows/Row.swift
+++ b/Sources/CanopyCore/Rows/Row.swift
@@ -27,6 +27,8 @@ public struct Row: Sendable, Equatable, Identifiable, Codable {
     public var rowClass: RowClass
     public var externalTag: ExternalTag?
     public var isMissing: Bool
+    /// Looked up only for Canopy and adopted rows on a branch.
+    public var pullRequest: PullRequest?
 
     public var id: String { path }
 
@@ -59,5 +61,6 @@ public struct Row: Sendable, Equatable, Identifiable, Codable {
         case rowClass = "class"
         case externalTag = "tag"
         case isMissing = "missing"
+        case pullRequest = "pr"
     }
 }
```

`Sources/CanopyCore/Watch/GitEventFilter.swift` (modify):

```diff
--- a/Sources/CanopyCore/Watch/GitEventFilter.swift
+++ b/Sources/CanopyCore/Watch/GitEventFilter.swift
@@ -1,6 +1,7 @@
-/// Decides which file events inside a repo's git folder can change its worktree list.
+/// Picks out the file events inside a repo's git folder that Canopy acts on.
 /// Everything else (objects, index, logs, lock files) is noise from normal git use.
 public enum GitEventFilter {
+    /// Whether the event can change the repo's worktree list.
     public static func isRelevant(eventPath: String, gitDir: String) -> Bool {
         guard Paths.isInside(eventPath, gitDir), eventPath != gitDir else { return false }
         let relative = eventPath.dropFirst(gitDir.count).split(separator: "/").map(String.init)
@@ -9,4 +10,11 @@ public enum GitEventFilter {
         if relative.count <= 2 { return true }
         return relative.count == 3 && ["HEAD", "gitdir", "locked"].contains(relative[2])
     }
+
+    /// Whether a write in the git folder updated a remote-tracking branch, which is what `git push` leaves behind.
+    public static func isRemoteRefChange(eventPath: String, gitDir: String) -> Bool {
+        guard Paths.isInside(eventPath, gitDir), !eventPath.hasSuffix(".lock") else { return false }
+        let relative = eventPath.dropFirst(gitDir.count).split(separator: "/")
+        return relative == ["packed-refs"] || (relative.count > 2 && relative.starts(with: ["refs", "remotes"]))
+    }
 }
```

`Sources/CanopyCore/Workspace/Workspace+PullRequests.swift` (new):

```swift
import Foundation

/// When PR badges refresh, besides `canopy pr --refresh` and rows appearing.
public struct PRTiming: Sendable {
    public var interval: Duration
    /// The least time between refreshes caused by the app coming to the front.
    public var focusGap: Duration
    public var afterPushInterval: Duration
    public var afterPushDuration: Duration

    public init(interval: Duration, focusGap: Duration, afterPushInterval: Duration, afterPushDuration: Duration) {
        self.interval = interval
        self.focusGap = focusGap
        self.afterPushInterval = afterPushInterval
        self.afterPushDuration = afterPushDuration
    }

    /// Every minute, on focus at most every 15 seconds, and every 10 seconds for two minutes after a push,
    /// when a PR is most likely to be opened.
    public static let standard = PRTiming(
        interval: .seconds(60), focusGap: .seconds(15), afterPushInterval: .seconds(10),
        afterPushDuration: .seconds(120))
}

/// What Canopy last learned about one repo's pull requests.
struct RepoPullRequests: Equatable {
    enum Source: Equatable {
        case github
        case notGitHub
        case ghMissing
        case notLoggedIn
        case failed(String)
    }

    var source: Source
    /// The branches the last finished lookup asked about.
    var branches: [String] = []
    var found: [String: PullRequest] = [:]

    var warning: String? {
        switch source {
        case .github, .notGitHub: nil
        case .ghMissing: "Install gh to see pull requests: `brew install gh`, then `gh auth login`."
        case .notLoggedIn: "Run `gh auth login` to see pull requests."
        case .failed(let message): "Pull requests did not load: \(message)"
        }
    }

    /// A failed lookup keeps the last badges. They only go when gh cannot be used at all.
    func apply(to repo: inout RepoSnapshot) {
        repo.pullRequestWarning = warning
        for index in repo.rows.indices where Workspace.looksUpPullRequest(repo.rows[index]) {
            repo.rows[index].pullRequest = repo.rows[index].branch.flatMap { found[$0] }
        }
    }
}

extension Workspace {
    /// Main and external rows are never looked up, and neither is a detached HEAD.
    static func looksUpPullRequest(_ row: Row) -> Bool {
        (row.rowClass == .canopy || row.rowClass == .adopted) && row.branch != nil
    }

    func pullRequestBranches(repoPath: String) -> [String] {
        let rows = repoSnapshots[repoPath]?.rows ?? []
        return Set(rows.filter(Self.looksUpPullRequest).compactMap(\.branch)).sorted()
    }

    /// Returns once the snapshot reflects GitHub as of this call.
    public func refreshPullRequests(repoPath: String) async {
        await queuePullRequestRefresh(repoPath: repoPath).value
    }

    /// Repos are looked up in parallel.
    public func refreshAllPullRequests() async {
        let lookups = state.repos.map { queuePullRequestRefresh(repoPath: $0.path) }
        for lookup in lookups {
            await lookup.value
        }
    }

    public func applicationBecameActive() async {
        let now = ContinuousClock.now
        if let last = lastFocusRefresh, now - last < prTiming.focusGap { return }
        lastFocusRefresh = now
        await refreshAllPullRequests()
    }

    /// Lookups of one repo run one after another, so an older answer never replaces a newer one.
    /// A lookup that is queued but not started yet already covers anyone asking now, so they share it.
    func queuePullRequestRefresh(repoPath: String) -> Task<Void, Never> {
        prBranchesRequested[repoPath] = pullRequestBranches(repoPath: repoPath)
        if let pending = prPending[repoPath] { return pending }
        let previous = prQueues[repoPath]
        let task = Task {
            await previous?.value
            await self.lookUpPullRequests(repoPath: repoPath)
        }
        prPending[repoPath] = task
        prQueues[repoPath] = task
        return task
    }

    private func lookUpPullRequests(repoPath: String) async {
        prPending[repoPath] = nil
        guard state.repos.contains(where: { $0.path == repoPath }), let repo = repoSnapshots[repoPath], !repo.isMissing
        else { return }
        let branches = pullRequestBranches(repoPath: repoPath)
        let origin = try? await git.run(["remote", "get-url", "origin"], in: repoPath)
        var lookup: PRLookup?
        if let github = origin.flatMap(GitHubRepo.init(remoteURL:)) {
            lookup = branches.isEmpty ? .found([:]) : await self.github.pullRequests(repo: github, branches: branches)
        }
        // The repo may have been removed while gh answered.
        guard state.repos.contains(where: { $0.path == repoPath }) else { return }
        var entry = pullRequests[repoPath] ?? RepoPullRequests(source: .github)
        switch lookup {
        case nil: entry = RepoPullRequests(source: .notGitHub, branches: branches)
        case .found(let found): entry = RepoPullRequests(source: .github, branches: branches, found: found)
        case .ghMissing: entry = RepoPullRequests(source: .ghMissing, branches: branches)
        case .notLoggedIn: entry = RepoPullRequests(source: .notLoggedIn, branches: branches)
        case .failed(let message): entry.source = .failed(message)
        }
        guard entry != pullRequests[repoPath] else { return }
        pullRequests[repoPath] = entry
        publish()
    }

    func startPullRequestTimer() {
        prTimer?.cancel()
        prTimer = Task { [weak self, interval = prTiming.interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refreshAllPullRequests()
            }
        }
    }

    /// A push moved a remote-tracking branch. Another push in the window extends it.
    func refreshOftenAfterPush(repoPath: String) {
        guard state.repos.contains(where: { $0.path == repoPath }) else { return }
        let until = ContinuousClock.now + prTiming.afterPushDuration
        if let running = afterPush[repoPath] {
            afterPush[repoPath] = (until, running.task)
            return
        }
        let task = Task { [weak self, every = prTiming.afterPushInterval] in
            while true {
                try? await Task.sleep(for: every)
                guard let self, await self.isAfterPush(repoPath: repoPath) else { return }
                await self.refreshPullRequests(repoPath: repoPath)
            }
        }
        afterPush[repoPath] = (until, task)
    }

    /// Called from the repo's after-push task, so a cancelled one never touches its successor's entry.
    private func isAfterPush(repoPath: String) -> Bool {
        guard !Task.isCancelled, let entry = afterPush[repoPath] else { return false }
        if ContinuousClock.now < entry.until { return true }
        afterPush[repoPath] = nil
        return false
    }

    func forgetPullRequests(repoPath: String) {
        pullRequests[repoPath] = nil
        prBranchesRequested[repoPath] = nil
        afterPush.removeValue(forKey: repoPath)?.task.cancel()
    }

    func stopPullRequestRefreshes() {
        prTimer?.cancel()
        prTimer = nil
        for entry in afterPush.values {
            entry.task.cancel()
        }
        afterPush.removeAll()
    }
}
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -19,10 +19,27 @@ public actor Workspace {
     var subscribers: [UUID: AsyncStream<WorkspaceSnapshot>.Continuation] = [:]
     public private(set) var loadNotice: String?
 
-    public init(home: CanopyHome, git: GitRunner = GitRunner(), fetchTimeout: Duration = .seconds(60)) {
+    let github: GitHubCLI
+    let prTiming: PRTiming
+    var pullRequests: [String: RepoPullRequests] = [:]
+    /// The branches each repo's latest lookup asked about, set when it is queued.
+    var prBranchesRequested: [String: [String]] = [:]
+    var prQueues: [String: Task<Void, Never>] = [:]
+    /// A queued lookup that has not started yet, which later callers share instead of queueing another.
+    var prPending: [String: Task<Void, Never>] = [:]
+    var prTimer: Task<Void, Never>?
+    var afterPush: [String: (until: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]
+    var lastFocusRefresh: ContinuousClock.Instant?
+
+    public init(
+        home: CanopyHome, git: GitRunner = GitRunner(), fetchTimeout: Duration = .seconds(60),
+        github: GitHubCLI = GitHubCLI(), prTiming: PRTiming = .standard
+    ) {
         self.home = home
         self.git = git
         self.fetchTimeout = fetchTimeout
+        self.github = github
+        self.prTiming = prTiming
         self.store = StateStore(url: home.stateFile)
         self.classifier = RowClassifier(
             canopyWorktreesRoot: Paths.canonical(home.worktreesRoot.path),
@@ -48,6 +65,7 @@ public actor Workspace {
             await watch(repoPath: entry.path)
         }
         await refreshAll()
+        startPullRequestTimer()
     }
 
     /// Stops watching and releases the home for another instance.
@@ -57,6 +75,7 @@ public actor Workspace {
             task.cancel()
         }
         pendingRefreshes.removeAll()
+        stopPullRequestRefreshes()
         for subscriber in subscribers.values {
             subscriber.finish()
         }
@@ -69,6 +88,7 @@ public actor Workspace {
         let repos = state.repos.map { entry in
             var repo = repoSnapshots[entry.path] ?? RepoSnapshot(path: entry.path, name: "")
             repo.name = names[entry.path] ?? entry.dirName
+            pullRequests[entry.path]?.apply(to: &repo)
             return repo
         }
         return WorkspaceSnapshot(repos: repos, selectedRowPath: state.selectedRowPath)
@@ -114,6 +134,7 @@ public actor Workspace {
         pendingRefreshes.removeValue(forKey: path)?.cancel()
         refreshQueues[path] = nil
         repoSnapshots[path] = nil
+        forgetPullRequests(repoPath: path)
         try save()
         publish()
     }
@@ -137,6 +158,7 @@ public actor Workspace {
         pendingRefreshes.removeValue(forKey: path)?.cancel()
         refreshQueues[path] = nil
         repoSnapshots[path] = nil
+        forgetPullRequests(repoPath: path)
         try save()
         await watch(repoPath: mainPath)
         await refresh(repoPath: mainPath)
@@ -272,6 +294,9 @@ public actor Workspace {
             external: rows.filter { $0.rowClass == .external }
         )
         publish()
+        if prBranchesRequested[current.path] != pullRequestBranches(repoPath: current.path) {
+            _ = queuePullRequestRefresh(repoPath: current.path)
+        }
     }
 
     // MARK: Internals
@@ -341,10 +366,13 @@ public actor Workspace {
         guard state.repos.contains(where: { $0.path == repoPath }) else { return }
         let canonicalGitDir = Paths.canonical(gitDir.trimmingCharacters(in: .whitespacesAndNewlines))
         watchers[repoPath] = DirectoryWatcher(paths: [canonicalGitDir]) { [weak self] paths in
-            guard paths.contains(where: { GitEventFilter.isRelevant(eventPath: $0, gitDir: canonicalGitDir) }) else {
-                return
+            let worktrees = paths.contains { GitEventFilter.isRelevant(eventPath: $0, gitDir: canonicalGitDir) }
+            let pushed = paths.contains { GitEventFilter.isRemoteRefChange(eventPath: $0, gitDir: canonicalGitDir) }
+            guard worktrees || pushed else { return }
+            Task {
+                if worktrees { await self?.scheduleRefresh(repoPath: repoPath) }
+                if pushed { await self?.refreshOftenAfterPush(repoPath: repoPath) }
             }
-            Task { await self?.scheduleRefresh(repoPath: repoPath) }
         }
     }
```

`Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift
+++ b/Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift
@@ -7,6 +7,8 @@ public struct RepoSnapshot: Sendable, Equatable, Identifiable {
     public var external: [Row]
     public var isMissing: Bool
     public var error: String?
+    /// Why PR badges are hidden or stale, with the fix, such as running `gh auth login`.
+    public var pullRequestWarning: String?
 
     public var id: String { path }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times. Expected: every run passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: look up each row's pull request through gh, and keep it fresh"
```

## Task 4: `canopy pr`

**Files:** Create `Sources/CanopyCLI/PRCommand.swift`. Modify `ControlMethods.swift`, `WorkspaceControlHandler.swift`, `WorkspaceError.swift`, `Workspace+PullRequests.swift`, `CanopyCLI.swift`, `AgentGuide.swift`, `scripts/e2e.sh`. Test `PullRequestWorkspaceTests.swift`, `ControlServerTests.swift`, `ControlProtocolTests.swift`.

**Interfaces:**
- Consumes the workspace lookups from Task 3.
- Produces `ControlMethod.prShow` (`"pr.show"`), `PRShowParams(target:refresh:)`, `PRShowResult` (`repo`, `branch`, `path`, `pr`), and `Workspace.pullRequest(for:refresh:) async throws -> PullRequest?`.
- Produces errors `no_pr_lookup`, `not_github`, `gh_unavailable`, and `gh_failed`.

`pullRequest(for:refresh:)` looks the repo up first when asked to, or when the row's branch was not in the last finished lookup, so an agent asking right after `canopy row new` gets an answer rather than null.
Without `--refresh`, a failed lookup still answers with the last PR it found.
`pr.show` gets a 90 second reply timeout: a refresh can queue behind a lookup already asking GitHub, and each may take 30 seconds.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlProtocolTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlProtocolTests.swift
+++ b/Tests/CanopyCoreTests/ControlProtocolTests.swift
@@ -23,6 +23,7 @@ struct JSONValueTests {
         #expect(!remove.force && !remove.deleteBranch)
         #expect(try JSONValue.object([:]).decode(RowListParams.self).all == false)
         #expect(try JSONValue.object([:]).decode(RowRefParams.self).target == TargetHint())
+        #expect(try JSONValue.object([:]).decode(PRShowParams.self).refresh == false)
         #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(RowNewParams.self) }
     }
 
@@ -43,6 +44,8 @@ struct JSONValueTests {
         #expect(ControlMethod.replyTimeout(for: ControlMethod.repoAdd).map { $0 >= 600 } == true)
         #expect(ControlMethod.replyTimeout(for: ControlMethod.status).map { $0 <= 60 } == true)
         #expect(ControlMethod.replyTimeout(for: ControlMethod.rowList).map { $0 <= 60 } == true)
+        // A refresh can wait behind a lookup already asking GitHub, and each gets 30 seconds.
+        #expect(ControlMethod.replyTimeout(for: ControlMethod.prShow).map { $0 >= 60 } == true)
     }
 
     @Test func clientFailuresMapToStableCodes() {
```

`Tests/CanopyCoreTests/ControlServerTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -13,9 +13,11 @@ final class RecordingUI: ControlUIBridge {
 }
 
 struct ControlServerTests {
-    func startServer(_ dir: TempDir) async throws -> (Workspace, ControlServer, ControlClient, RecordingUI) {
+    func startServer(_ dir: TempDir, github: GitHubCLI = GitHubCLI()) async throws
+        -> (Workspace, ControlServer, ControlClient, RecordingUI)
+    {
         let home = CanopyHome(path: dir.sub("home"))
-        let workspace = Workspace(home: home, git: Fixture.git)
+        let workspace = Workspace(home: home, git: Fixture.git, github: github)
         try await workspace.start()
         let ui = RecordingUI()
         let rows = await MainActor.run { RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)) }
@@ -196,6 +198,29 @@ struct ControlServerTests {
         #expect(missing.error?.code == "pane_not_found")
     }
 
+    @Test func prShowAnswersOverTheSocket() async throws {
+        let dir = try TempDir()
+        let gh = try FakeGH(dir)
+        gh.answer([0: (5, "OPEN")])
+        let (workspace, server, client, _) = try await startServer(dir, github: gh.cli)
+        defer { server.stop() }
+        let repo = try await Fixture.repo(in: dir)
+        try await Fixture.git.run(["remote", "add", "origin", "https://github.com/NE1NN/canopy.git"], in: repo)
+        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
+        try await workspace.addRepo(path: repo)
+
+        let shown = try await call(
+            client, ControlMethod.prShow, PRShowParams(target: TargetHint(row: "feat/a")), as: PRShowResult.self)
+
+        #expect(shown.pr?.number == 5)
+        #expect(shown.branch == "feat/a")
+        #expect(shown.repo == "demo")
+        let request = ControlRequest(
+            method: ControlMethod.prShow, params: .object(["target": .object(["row": .string("main")])]))
+        let main = try await offPool { try client.send(request) }
+        #expect(main.error?.code == "no_pr_lookup")
+    }
+
     @Test func errorsCarryCodes() async throws {
         let dir = try TempDir()
         let (_, server, client, _) = try await startServer(dir)
```

`Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift
+++ b/Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift
@@ -215,4 +215,62 @@ struct PullRequestWorkspaceTests {
 
         #expect(await workspace.pullRequests[repo] == nil)
     }
+
+    @Test func askingForARowsPullRequestLooksItUpIfNeeded() async throws {
+        let dir = try TempDir()
+        let (workspace, gh, _) = try await setUp(dir)
+        let row = try #require(await workspace.snapshot.row(path: dir.sub("home/worktrees/demo/feat-a")))
+
+        #expect(try await workspace.pullRequest(for: row, refresh: false)?.number == 5)
+
+        gh.answer([0: (5, "MERGED")])
+        #expect(try await workspace.pullRequest(for: row, refresh: false)?.state == .open)
+        #expect(try await workspace.pullRequest(for: row, refresh: true)?.state == .merged)
+    }
+
+    @Test func mainRowsHaveNoPullRequestLookup() async throws {
+        let dir = try TempDir()
+        let (workspace, _, repo) = try await setUp(dir)
+        let main = try #require(await workspace.snapshot.row(path: repo))
+
+        await #expect(throws: WorkspaceError.noPullRequestLookup("main")) {
+            try await workspace.pullRequest(for: main, refresh: false)
+        }
+    }
+
+    @Test func lookupsSayWhyTheyCannotAnswer() async throws {
+        let dir = try TempDir()
+        let (workspace, gh, _) = try await setUp(dir)
+        let row = try #require(await workspace.snapshot.row(path: dir.sub("home/worktrees/demo/feat-a")))
+        _ = try await workspace.pullRequest(for: row, refresh: true)
+
+        gh.fail(exitCode: 1, "gh: error connecting to api.github.com")
+        #expect(try await workspace.pullRequest(for: row, refresh: false)?.number == 5)
+        await #expect(throws: WorkspaceError.ghFailed("error connecting to api.github.com")) {
+            try await workspace.pullRequest(for: row, refresh: true)
+        }
+
+        gh.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")
+        await #expect {
+            try await workspace.pullRequest(for: row, refresh: true)
+        } throws: { error in
+            guard case WorkspaceError.ghUnavailable(let message) = error else { return false }
+            return message.contains("gh auth login")
+        }
+    }
+
+    @Test func reposOffGitHubSaySo() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir, origin: true)
+        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
+        let workspace = Workspace(
+            home: CanopyHome(path: dir.sub("home")), git: Fixture.git, github: try FakeGH(dir).cli)
+        try await workspace.start()
+        try await workspace.addRepo(path: repo)
+        let row = try #require(await workspace.snapshot.row(path: dir.sub("home/worktrees/demo/feat-a")))
+
+        await #expect(throws: WorkspaceError.notOnGitHub("demo")) {
+            try await workspace.pullRequest(for: row, refresh: false)
+        }
+    }
 }
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'PullRequestWorkspaceTests|ControlServerTests|ControlProtocolTests'`
Expected: does not compile, `PRShowParams`, `ControlMethod.prShow`, and `Workspace.pullRequest(for:refresh:)` are missing.

- [ ] **Step 3: Implement**

The e2e step looks up the newest merged PR of the checkout's own GitHub repo with the user's `gh`, and skips when there is none to find.

`Sources/CanopyCLI/AgentGuide.swift` (modify):

```diff
--- a/Sources/CanopyCLI/AgentGuide.swift
+++ b/Sources/CanopyCLI/AgentGuide.swift
@@ -45,6 +45,14 @@ struct AgentGuide: ParsableCommand {
 
         Terminal IDs such as p12 stay unique across relaunches. `term send`, `read`, and `close` never start Canopy.
 
+        ## Pull requests
+
+            canopy pr [<branch>] [--refresh]              the row's PR: number, state, title, and URL
+
+        Canopy looks up PRs with your `gh` login for its own and adopted rows, about once a minute and more often
+        right after a push. `--refresh` asks GitHub now, for example right after `gh pr create`.
+        `row list --json` also carries each row's PR as "pr".
+
         ## Examples
 
         Start a parallel agent on a fix in its own row, then check on it:
```

`Sources/CanopyCLI/CanopyCLI.swift` (modify):

```diff
--- a/Sources/CanopyCLI/CanopyCLI.swift
+++ b/Sources/CanopyCLI/CanopyCLI.swift
@@ -8,7 +8,9 @@ struct CanopyCLI: AsyncParsableCommand {
         commandName: "canopy",
         abstract: "Drive Canopy from the command line.",
         version: CanopyVersion.current,
-        subcommands: [Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, AgentGuide.self]
+        subcommands: [
+            Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, PRCommand.self, AgentGuide.self,
+        ]
     )
 }
```

`Sources/CanopyCLI/PRCommand.swift` (new):

```swift
import ArgumentParser
import CanopyCore

struct PRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pr",
        abstract: "Show a row's pull request.",
        discussion: """
            Canopy looks up PRs with your gh login for its own and adopted rows, about once a minute and more \
            often right after a push. --refresh asks GitHub now, for example right after gh pr create.
            """
    )

    @Argument(help: "Branch or path. Defaults to the row you are in.")
    var row: String?
    @Option(help: "Repo name or path, when the branch exists in several repos.")
    var repo: String?
    @Flag(help: "Ask GitHub now instead of using the last lookup.")
    var refresh = false
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = Client(json: output.json)
        let result = client.call(
            ControlMethod.prShow, PRShowParams(target: Client.hint(repo: repo, row: row), refresh: refresh))
        try client.print(result) {
            let shown = try result.decode(PRShowResult.self)
            guard let pr = shown.pr else { return "\(shown.branch) has no pull request." }
            return "#\(pr.number) \(pr.state.rawValue): \(pr.title)\n\(pr.url)"
        }
    }
}
```

`Sources/CanopyCore/Control/ControlMethods.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/ControlMethods.swift
+++ b/Sources/CanopyCore/Control/ControlMethods.swift
@@ -10,12 +10,15 @@ public enum ControlMethod {
     public static let rowRemove = "row.remove"
     public static let rowSelect = "row.select"
     public static let rowAdopt = "row.adopt"
+    public static let prShow = "pr.show"
 
     /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo, so they
     /// can take minutes. Creating and removing rows also wait for setup or teardown, which can run for as long as
-    /// a build does and cannot be cancelled, so the CLI waits for them without a limit. Reads answer from memory.
+    /// a build does and cannot be cancelled, so the CLI waits for them without a limit. A PR lookup can queue
+    /// behind one already asking GitHub, and each may take 30 seconds. Other reads answer from memory.
     public static func replyTimeout(for method: String) -> TimeInterval? {
         if [rowNew, rowRemove].contains(method) { return nil }
+        if method == prShow { return 90 }
         return [repoAdd, repoRemove, rowAdopt].contains(method) ? 900 : 30
     }
 }
@@ -196,3 +199,28 @@ public struct RowAdoptParams: Codable, Sendable {
         self.path = path
     }
 }
+
+public struct PRShowParams: Codable, Sendable {
+    public var target: TargetHint
+    /// Asks GitHub now instead of answering with the last lookup.
+    public var refresh: Bool
+
+    public init(target: TargetHint = TargetHint(), refresh: Bool = false) {
+        self.target = target
+        self.refresh = refresh
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
+        refresh = try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
+    }
+}
+
+public struct PRShowResult: Codable, Sendable {
+    public var repo: String
+    public var branch: String
+    public var path: String
+    /// Nil when the branch has no PR.
+    public var pr: PullRequest?
+}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
+++ b/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
@@ -102,6 +102,16 @@ public struct WorkspaceControlHandler: Sendable {
             let params = try request.decodeParams(RowAdoptParams.self)
             return try .from(try await workspace.adopt(path: params.path))
 
+        case ControlMethod.prShow:
+            let params = try request.decodeParams(PRShowParams.self)
+            let snapshot = await workspace.snapshot
+            let row = try TargetResolver.row(for: params.target, in: snapshot)
+            let pr = try await workspace.pullRequest(for: row, refresh: params.refresh)
+            return try .from(
+                PRShowResult(
+                    repo: snapshot.repo(path: row.repoPath)?.name ?? "", branch: row.displayName, path: row.path,
+                    pr: pr))
+
         case TermMethod.list:
             let params = try request.decodeParams(TermListParams.self)
             let snapshot = await workspace.snapshot
```

`Sources/CanopyCore/Workspace/Workspace+PullRequests.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace+PullRequests.swift
+++ b/Sources/CanopyCore/Workspace/Workspace+PullRequests.swift
@@ -79,6 +79,27 @@ extension Workspace {
         }
     }
 
+    /// The row's PR, looked up first when asked to or when its branch has not been looked up yet.
+    public func pullRequest(for row: Row, refresh: Bool) async throws -> PullRequest? {
+        guard Self.looksUpPullRequest(row), let branch = row.branch else {
+            throw WorkspaceError.noPullRequestLookup(row.displayName)
+        }
+        if refresh || pullRequests[row.repoPath]?.branches.contains(branch) != true {
+            await refreshPullRequests(repoPath: row.repoPath)
+        }
+        guard let entry = pullRequests[row.repoPath] else { throw WorkspaceError.rowNotFound(row.path) }
+        switch entry.source {
+        case .notGitHub:
+            throw WorkspaceError.notOnGitHub(snapshot.repo(path: row.repoPath)?.name ?? row.repoPath)
+        case .ghMissing, .notLoggedIn:
+            throw WorkspaceError.ghUnavailable(entry.warning ?? "")
+        case .failed(let message) where refresh || !entry.branches.contains(branch):
+            throw WorkspaceError.ghFailed(message)
+        case .github, .failed:
+            return entry.found[branch]
+        }
+    }
+
     public func applicationBecameActive() async {
         let now = ContinuousClock.now
         if let last = lastFocusRefresh, now - last < prTiming.focusGap { return }
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/WorkspaceError.swift
+++ b/Sources/CanopyCore/Workspace/WorkspaceError.swift
@@ -20,6 +20,10 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case paneNotFound(String)
     case paneBusy(String, program: String)
     case paneExited(String)
+    case noPullRequestLookup(String)
+    case notOnGitHub(String)
+    case ghUnavailable(String)
+    case ghFailed(String)
     case git(GitError)
 
     public var code: String {
@@ -45,6 +49,10 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .paneNotFound: "pane_not_found"
         case .paneBusy: "pane_busy"
         case .paneExited: "pane_exited"
+        case .noPullRequestLookup: "no_pr_lookup"
+        case .notOnGitHub: "not_github"
+        case .ghUnavailable: "gh_unavailable"
+        case .ghFailed: "gh_failed"
         case .git: "git_failed"
         }
     }
@@ -74,6 +82,11 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .paneNotFound(let id): "No terminal \(id). Run `canopy term list --all`."
         case .paneBusy(let id, let program): "\(program) is still running in \(id). Pass --force to close it anyway."
         case .paneExited(let id): "The shell in \(id) has exited. Close it, or restart it from the window."
+        case .noPullRequestLookup(let name):
+            "Canopy only looks up PRs for its own and adopted rows on a branch, and \(name) is not one."
+        case .notOnGitHub(let repo): "\(repo)'s origin is not on GitHub, so its rows have no PRs."
+        case .ghUnavailable(let warning): warning
+        case .ghFailed(let message): "Pull requests did not load: \(message)"
         case .git(let error): error.description
         }
     }
```

`scripts/e2e.sh` (modify):

```diff
--- a/scripts/e2e.sh
+++ b/scripts/e2e.sh
@@ -166,6 +166,36 @@ wait_for_text sent-text || fail "term send did not reach the terminal"
 if "$cli" term list --all --json | grep -q "\"$pane\""; then fail "closed terminal is still listed"; fi
 "$cli" agent-guide | grep -q "canopy term read" || fail "agent-guide is missing term read"
 
+step "canopy pr says when a repo's origin is not on GitHub"
+if "$cli" pr feat/term --repo demo --json > "$work/pr-local.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"not_github"' "$work/pr-local.json" || fail "missing not_github"
+"$cli" agent-guide | grep -q "canopy pr" || fail "agent-guide is missing canopy pr"
+
+step "canopy pr finds a real PR through gh"
+# Looks up the newest merged PR of this checkout's own GitHub repo, with the user's gh login.
+if merged=$(gh pr list --state merged --limit 1 --json number,headRefName --jq '.[0] | "\(.number) \(.headRefName)"' \
+    2>/dev/null) && [[ -n "$merged" ]]; then
+    read -r number branch <<< "$merged"
+    git init -q -b main "$work/ghdemo"
+    git -C "$work/ghdemo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
+    git -C "$work/ghdemo" remote add origin "$(git remote get-url origin)"
+    "$cli" repo add "$work/ghdemo" >/dev/null
+    git -C "$work/ghdemo" worktree add -q -b "$branch" "$CANOPY_HOME/worktrees/ghdemo/merged"
+    for _ in $(seq 1 30); do
+        "$cli" row list --repo ghdemo | grep -q "$branch" && break
+        sleep 0.1
+    done
+    "$cli" pr "$branch" --repo ghdemo --refresh --json > "$work/pr.json"
+    grep -q "\"number\" : $number" "$work/pr.json" || fail "canopy pr did not find PR $number"
+    grep -q '"state" : "merged"' "$work/pr.json" || fail "PR $number is not shown as merged"
+    "$cli" row select "$branch" --repo ghdemo >/dev/null
+    sleep 1
+    swift scripts/window-shot.swift "$(app_pid)" "$shots/pr.png"
+    echo "saved $shots/pr.png"
+else
+    echo "skipped: needs gh logged in and an origin on GitHub with a merged PR"
+fi
+
 step "errors are machine-readable"
 if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
 grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"
```

- [ ] **Step 4: Run everything**

Run: `make lint && make test && make e2e`
Expected: `e2e passed`, including "canopy pr finds a real PR through gh" when `gh` is logged in.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests scripts
git commit -m "feat: canopy pr shows a row's pull request"
```

## Task 5: PR badges in the sidebar

**Files:** Modify `Sources/CanopyApp/Sidebar/BranchGlyph.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/CanopyApp.swift`.

**Interfaces:** Consumes `Row.pullRequest`, `RepoSnapshot.pullRequestWarning`, and `Workspace.applicationBecameActive()` from Task 3.

Design choices, checked with window screenshots in dark and light mode:
- The pull request glyph uses the branch glyph's 24 point grid and stroke, so the two swap without the row shifting.
- Colors are GitHub's own for each state, with light and dark values, so a badge reads the way it does on github.com. System purple renders pink next to it.
- A row without a PR keeps a muted branch glyph, so color only ever means a PR's state.
- On a selected row in a focused sidebar, the glyph and number turn white like the rest of the row, since state colors clash with the accent color there.
- The warning sits in the section, under the repo's name, because sidebar section headers keep a fixed height and clipped a second line. It wraps to three lines at most, with the full text on hover.
- Coming back to Canopy counts as the window gaining focus, through `applicationDidBecomeActive`.

- [ ] **Step 1: Implement**

`Sources/CanopyApp/CanopyApp.swift` (modify):

```diff
--- a/Sources/CanopyApp/CanopyApp.swift
+++ b/Sources/CanopyApp/CanopyApp.swift
@@ -31,6 +31,11 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
         Task { await model.start() }
     }
 
+    func applicationDidBecomeActive(_ notification: Notification) {
+        let workspace = model.workspace
+        Task { await workspace.applicationBecameActive() }
+    }
+
     func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
         let busy = model.terminals.busyPanes.compactMap(\.foreground?.name)
         guard busy.isEmpty || confirmQuit(busy) else { return .terminateCancel }
```

`Sources/CanopyApp/Sidebar/BranchGlyph.swift` (modify):

```diff
--- a/Sources/CanopyApp/Sidebar/BranchGlyph.swift
+++ b/Sources/CanopyApp/Sidebar/BranchGlyph.swift
@@ -1,3 +1,5 @@
+import AppKit
+import CanopyCore
 import SwiftUI
 
 /// The git branch mark: a trunk with a commit at each end and a branch curving in from the right.
@@ -17,12 +19,82 @@ struct BranchGlyph: Shape {
     }
 }
 
-struct BranchIcon: View {
-    var color: Color = .green
+/// The pull request mark: a trunk with a commit on top, and a branch from a commit on the right back towards the
+/// trunk, ending in an arrow. Same grid and stroke as the branch mark, so the two swap cleanly.
+struct PullRequestGlyph: Shape {
+    func path(in rect: CGRect) -> Path {
+        let scale = min(rect.width, rect.height) / 24
+        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
+        var path = Path()
+        path.addEllipse(in: CGRect(x: 2, y: 3, width: 6, height: 6))
+        path.move(to: CGPoint(x: 5, y: 9))
+        path.addLine(to: CGPoint(x: 5, y: 21))
+        path.addEllipse(in: CGRect(x: 16, y: 15, width: 6, height: 6))
+        path.move(to: CGPoint(x: 19, y: 15))
+        path.addLine(to: CGPoint(x: 19, y: 8))
+        path.addQuadCurve(to: CGPoint(x: 17, y: 6), control: CGPoint(x: 19, y: 6))
+        path.addLine(to: CGPoint(x: 12, y: 6))
+        path.move(to: CGPoint(x: 15, y: 3))
+        path.addLine(to: CGPoint(x: 12, y: 6))
+        path.addLine(to: CGPoint(x: 15, y: 9))
+        return path.applying(transform)
+    }
+}
+
+/// A row's mark: its PR in the PR's state color, or a muted branch when it has none.
+struct RowIcon: View {
+    let row: Row
+    @Environment(\.backgroundProminence) private var prominence
 
     var body: some View {
-        BranchGlyph()
-            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
-            .frame(width: 14, height: 14)
+        Group {
+            if let pr = row.pullRequest {
+                PullRequestGlyph().stroke(pr.state.style(on: prominence), style: Self.stroke)
+            } else {
+                BranchGlyph().stroke(.secondary, style: Self.stroke)
+            }
+        }
+        .frame(width: 14, height: 14)
+    }
+
+    private static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
+}
+
+extension PRState {
+    /// GitHub's own state colors, so a badge reads the way it does on github.com.
+    var color: Color {
+        switch self {
+        case .open: .adaptive(light: 0x1A7F37, dark: 0x3FB950)
+        case .draft: .adaptive(light: 0x59636E, dark: 0x9198A1)
+        case .merged: .adaptive(light: 0x8250DF, dark: 0xAB7DF8)
+        case .closed: .adaptive(light: 0xD1242F, dark: 0xF85149)
+        }
+    }
+
+    /// On a selected row in a focused sidebar, state colors would clash with the accent color, so they turn white
+    /// like the rest of the row.
+    func style(on prominence: BackgroundProminence) -> AnyShapeStyle {
+        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
+    }
+
+    var label: String {
+        switch self {
+        case .open: "Open"
+        case .draft: "Draft"
+        case .merged: "Merged"
+        case .closed: "Closed"
+        }
+    }
+}
+
+extension Color {
+    static func adaptive(light: UInt32, dark: UInt32) -> Color {
+        Color(
+            nsColor: NSColor(name: nil) { appearance in
+                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
+                return NSColor(
+                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
+                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
+            })
     }
 }
```

`Sources/CanopyApp/Sidebar/SidebarView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Sidebar/SidebarView.swift
+++ b/Sources/CanopyApp/Sidebar/SidebarView.swift
@@ -18,6 +18,11 @@ struct SidebarView: View {
         List(selection: $model.selectedRowPath) {
             ForEach(model.snapshot.repos) { repo in
                 Section {
+                    // A header keeps one line, so the warning sits just below it where it can wrap.
+                    if let warning = repo.pullRequestWarning {
+                        RepoWarningView(text: warning)
+                            .selectionDisabled()
+                    }
                     ForEach(repo.rows) { row in
                         RowLineView(row: row, shortcut: model.shortcut(for: row), removable: row.rowClass != .main)
                             .tag(row.path)
@@ -140,7 +145,7 @@ struct RowLineView: View {
 
     var body: some View {
         HStack(spacing: 6) {
-            BranchIcon(color: row.isMissing ? .secondary : .green)
+            RowIcon(row: row)
             Text(row.displayName)
                 .lineLimit(1)
                 .truncationMode(.middle)
@@ -152,6 +157,9 @@ struct RowLineView: View {
                 TagView(text: "missing")
             }
             Spacer(minLength: 4)
+            if let pr = row.pullRequest {
+                PullRequestNumber(pr: pr)
+            }
             if isHovering || isConfirmingRemove {
                 if let shortcut {
                     Text("⌘\(shortcut)")
@@ -177,10 +185,51 @@ struct RowLineView: View {
         }
         .contentShape(Rectangle())
         .onHover { isHovering = $0 }
+        // The PR number slides left as the shortcut and remove button come in.
+        .animation(.easeOut(duration: 0.12), value: isHovering)
         .help(row.path)
     }
 }
 
+/// Opens the PR on GitHub. The rest of the row still selects it.
+struct PullRequestNumber: View {
+    let pr: PullRequest
+    @Environment(\.openURL) private var openURL
+    @Environment(\.backgroundProminence) private var prominence
+
+    var body: some View {
+        Button {
+            if let url = URL(string: pr.url) { openURL(url) }
+        } label: {
+            Text("#\(pr.number)")
+                .font(.callout)
+                .monospacedDigit()
+                .foregroundStyle(pr.state.style(on: prominence))
+        }
+        .buttonStyle(.borderless)
+        .help("\(pr.state.label): \(pr.title)")
+        .accessibilityLabel("Pull request \(pr.number), \(pr.state.label). Opens on GitHub.")
+    }
+}
+
+/// Why a repo shows no PR badges, with the fix. Long messages from gh stop at three lines, with the rest on hover.
+struct RepoWarningView: View {
+    let text: String
+
+    var body: some View {
+        HStack(alignment: .firstTextBaseline, spacing: 5) {
+            Image(systemName: "exclamationmark.triangle.fill")
+                .foregroundStyle(.orange)
+            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
+                .foregroundStyle(.secondary)
+                .lineLimit(3)
+                .fixedSize(horizontal: false, vertical: true)
+        }
+        .font(.caption)
+        .help(text)
+    }
+}
+
 struct TagView: View {
     let text: String
```

- [ ] **Step 2: Check it by eye**

Run: `make app`, then register a repo whose `origin` is on GitHub with a row on a branch that has a PR, one with a nonexistent GitHub origin, and one with a local origin.
Expected, in dark and light mode: purple glyph and `#N` on the merged row, a muted branch glyph elsewhere, a wrapped warning under the nonexistent repo, and nothing extra on the local repo.
Launch with `GH_CONFIG_DIR` pointing at an empty folder: badges hide, and each GitHub repo says to run `gh auth login`.

- [ ] **Step 3: Commit**

```bash
git add Sources
git commit -m "feat: PR badges in the sidebar"
```
