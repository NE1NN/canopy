# Canopy Terminals and Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every row tabs of real terminals, run each repo's setup and teardown commands in visible tabs, and let an agent start work in a new row with `canopy row new --run`.

**Architecture:** `CanopyCore` owns the process side.
A small C target forks each shell into its own pseudo-terminal, `PtyProcess` streams it, `Pane` and `TerminalStore` model panes and tabs per row, and `RowLifecycle` wraps `Workspace` with setup and teardown.
The app supplies the screen side through the `TerminalEmulator` protocol, implemented on SwiftTerm's `TerminalView`, and only that one file imports SwiftTerm.
The sidebar, the new tab bar, and the control API all create and remove rows through `RowLifecycle`.

**Tech Stack:** Swift 6.2 with strict concurrency, SwiftUI and AppKit on macOS 15 or later, SwiftTerm 1.20.0 (the `TerminalView` class only), a C target using `forkpty(3)`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`

## Global Constraints

- macOS 15.0 minimum, `swift-tools-version: 6.2`, Swift 6 language mode, zero compiler warnings.
- Builds with Command Line Tools only. Run tests with `make test`, never bare `swift test`.
- `swift format lint --strict` passes with the repo's `.swift-format`.
- `make test` runs with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, so nothing may block a Swift concurrency thread. Blocking work runs on a private dispatch queue or its own thread.
- SwiftTerm is pinned with `exact: "1.20.0"`. Only `Sources/CanopyApp/Terminal/SwiftTermEmulator.swift` imports it.
- Each pane runs the user's login shell in the row's folder with this environment added: `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Canopy`, `CANOPY_HOME`, `CANOPY_REPO`, `CANOPY_ROW`, `CANOPY_ROW_PATH`, `CANOPY_PANE` (such as `p12`), and `PATH` with the bundle's CLI folder first.
- Setup and teardown commands also see `CANOPY_ROOT_PATH`, run in order in the row's folder, and stop at the first failure.
- Terminals use the system monospaced font at 13 points, follow the system light or dark appearance, and keep 10,000 lines of scrollback.
- New tabs are named "Terminal", "Terminal 2", and so on. Setup runs in a tab named "Setup" and teardown in one named "Teardown".
- Keys: `⌘T` new tab, `⌘W` close the focused pane, `⌘⇧[` and `⌘⇧]` previous and next tab.
- Conventional commit prefixes, one PR for this milestone, squash-merged after review. `main` is protected.
- Commit messages carry no AI co-author trailer. PR descriptions end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Markdown files put one sentence per line and never use em dashes.

## Review Focus

1. **Commands with quotes, `$`, and non-ASCII text**, such as `claude "fix the login redirect, ticket FL-123"`, must reach the shell unchanged through both `--run` and setup steps. Pinned by `runTypesCommandsVerbatim` in Task 4 and `keepsQuotesVariablesAndUnicode` in Task 3.
2. **Repo and row folders with spaces in their paths** must start shells, setup, and teardown in the right folder. Pinned by `startsInTheFolderWithTheEnvironment` in Task 2, `shellStartsInTheRowWithItsEnvironment` in Task 4, and `setupRunsInTheRowWithItsVariablesThenLeavesATerminal` (repo named "my repo") in Task 5.
3. **A row whose folder was deleted** must not get a shell somewhere else when selected, and removing it must skip teardown rather than fail. Pinned by `missingRowGetsNoTerminal` and `missingFolderStartsInHome` in Task 4 and `removingAMissingRowSkipsTeardown` in Task 5.
4. **Several agents running `canopy row new --run` at once in one repo** must each get their own pane running their own command. Pinned by `parallelRunsGetTheirOwnPanes` in Task 5.
5. **An agent removing the row it is running in** must still see the row removed, even though closing the row's terminals kills its own shell mid-request. Pinned by the "an agent can remove the row it runs in" step of `scripts/e2e.sh` in Task 9.

## Where This Plan Sits

This is PR 5 of the spec's delivery list: terminals and tabs, plus setup and teardown in a visible terminal tab.
The grid (the add rule, drag, resize, and restoring layouts on relaunch) is PR 6, so every tab holds exactly one pane here and nothing about terminals is saved yet.
`canopy term` and `canopy agent-guide` are PR 7.
`canopy row new --run` and `--no-setup` land here, because they belong to `row new` and need terminals.

The spec's engine interface also reads the screen and scrollback, and reports the bell and shell integration marks.
Each arrives with its first user: screen reading with `canopy term read` in PR 7, and marks with command logging in PR 10.
Nothing in v1 reacts to the bell, so SwiftTerm keeps its default beep.

It also fixes the review minors carried over from PRs 2 to 4 that sit in code this PR touches:

- 2: a stale refresh could overwrite a newer snapshot and drop the selection. Refreshes of one repo now run one after another, and a failed refresh keeps the last known rows (Task 1).
- 4: `--from` values starting with "-" were passed to git as options (Task 1).
- 5: "@{-1}" passed branch validation (Task 1).
- 6: a failed `--delete-branch` skipped the rest of the cleanup (Task 1).
- 7: slug folder picking ignored registered worktrees whose folders are gone (Task 1).
- 8: creating a row in a missing repo reported `invalid_branch` (Task 1).
- 12: quitting with no window left a stale socket, because termination was observed from a view. An app delegate now owns startup and shutdown (Task 8).
- 13: `status --json` lacked `"running": true` (Task 7).
- 14: params required `target`, `select`, `force`, and `all`, so the spec's example request was rejected (Task 7).

Minors 1, 3, and 9 (control socket framing and the client) wait for PR 7, which leans on the socket hardest.
Minors 10 and 11 (the directory watcher) wait for PR 8, which adds new watches.
Minors 15 and 16 (repo naming and sidebar actions) wait for the next sidebar change.

## Decisions Made While Planning

These were checked on the author's machine before writing the tasks.

- **Canopy owns the pseudo-terminal instead of using SwiftTerm's `LocalProcessTerminalView`.** In SwiftTerm 1.20.0 that class hands the raw `waitpid` status to its delegate (exit code 1 arrives as 256), sends SIGTERM to the shell only, and forks without closing inherited descriptors or resetting ignored signals. A shell started from the app would inherit the control socket and an ignored SIGPIPE. Task 2's tests fail against a child that skips either fix.
- **The fork happens in C.** `posix_spawn` cannot give the child a controlling terminal on macOS: `tcgetpgrp` on the master returned 0 and job control broke. `forkpty` works, and doing the post-fork steps in C keeps the Swift runtime out of the child of a multithreaded process.
- **`--run` types the command once the shell's line editor is ready.** Shells turn off canonical mode when their prompt waits for input, and typing before that makes the kernel echo the command once and the line editor echo it again. `PtyProcess.isAtPrompt` checks that the shell holds the terminal and `ICANON` is off. Shells without a line editor get the command after 10 seconds anyway.
- **Setup scripts run as `$SHELL -i -l -c <script>`**, so they find the same tools as a terminal, including ones added in `.zshrc`. Shells that cannot run POSIX sh, such as fish, hand the script to zsh.
- **Terminals start from a clean environment.** Only what a macOS login session starts with (`HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`, `__CF_USER_TEXT_ENCODING`, `LANG`, `LC_ALL`, `LC_CTYPE`) passes through. The SwiftTerm spike showed a Claude Code session's `CLAUDE_CODE_CHILD_SESSION` leaking into shells and disabling Claude transcripts.
- **`PATH` puts the bundle's CLI folder first**, but the login shell's `path_helper` and the user's startup files run after that and can put `~/.local/bin` ahead of it. PR 10's zsh startup shim can prepend it again after the user's files.
- **`CommandGroup(replacing: .saveItem)` takes over `⌘W`.** It removes File > Close, verified by dumping the menu of a test app. `⌘⇧[` reaches menus as "{", so the tab shortcuts are declared as `⌘{` and `⌘}`; a shortcut declared as "[" with Shift never matched.
- **Additions the spec does not mention:** tabs get a close button on hover, a row whose tabs were all closed shows "No Terminals" with a New Terminal button instead of reopening one at once, and the remove popover warns when the row's terminals are running programs.
- **Teardown failures stop the removal unless `--force` is given**, so cleanup of outside resources is never skipped silently. Uncommitted changes are checked before teardown runs, so a removal that would be refused anyway does not tear anything down first. Hiding an adopted row closes its terminals too.

## Every PR

- Start from the latest `main`: `git switch main && git pull --ff-only && git switch -c feat/terminals-tabs`.
- Before pushing, run `make lint && make build && make test && make e2e`.
- Open the PR with `gh pr create`, then wait for review.

## File Structure

```
Package.swift                                   adds the CPty target and SwiftTerm for the app
Sources/CPty/
  include/CPty.h                                fork a program into a new pseudo-terminal, set its size
  pty.c                                         forkpty, then reset signals and close descriptors in the child
Sources/CanopyCore/Terminal/
  PtyProcess.swift                              TerminalSize, TerminalLaunch, ForegroundProcess, PtyProcess
  TerminalIDs.swift                             PaneID ("p12"), TabID, PaneContext
  ShellSettings.swift                           the user's shell, launches for shells and scripts, LoginShell
  PaneEnvironment.swift                         the clean environment each terminal starts with
  SetupScript.swift                             setup and teardown commands as one POSIX sh script
  TerminalEmulator.swift                        TerminalEmulator, TerminalEngine, PaneCommand, titles, tab names
  Pane.swift                                    one terminal: process, status, title, restart, run, close
  TerminalStore.swift                           TerminalTab and every row's tabs
Sources/CanopyCore/Rows/
  RepoConfig.swift                              .canopy/config.json
  RowLifecycle.swift                            SetupReport, RowPreparation, setup and teardown around Workspace
Sources/CanopyApp/Terminal/
  SwiftTermEmulator.swift                       the only SwiftTerm import: TerminalView behind TerminalEmulator
  TerminalSurface.swift                         hosts a pane's terminal view with padding and focus tracking
  PaneView.swift                                header, terminal, and the strip shown after the shell exits
  RowTerminalsView.swift                        a row's tab bar and selected pane, or empty and missing states
  TabBarView.swift                              tabs with rename, close, and a new tab button
Tests/CanopyCoreTests/
  Support/FakeTerminal.swift                    FakeEmulator, FakeEngine, bash-based shell settings for tests
  PtyProcessTests.swift, PaneEnvironmentTests.swift, SetupScriptTests.swift, TerminalModelTests.swift,
  PaneTests.swift, TerminalStoreTests.swift, RowSetupTests.swift
```

Existing files that change: `Workspace.swift`, `Workspace+RowLifecycle.swift`, `WorkspaceError.swift`, `ControlMethods.swift`, `WorkspaceControlHandler.swift`, `RowCommand.swift`, `AppModel.swift`, `CanopyApp.swift`, `RootView.swift`, `RowActionViews.swift`, `scripts/e2e.sh`, and their tests.

Each task below shows new files in full and changes to existing files as diffs against the previous task.

---

## Task 1: Harden row creation and refresh

Seven of the carried-over review minors live in `Workspace`, which the rest of this plan builds on.
Fix them first so later tasks rely on a refresh that always reflects git once it returns.

**Files:**
- Modify: `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace.swift`
- Modify: `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Modify: `Tests/CanopyCoreTests/RowLifecycleTests.swift`, `Tests/CanopyCoreTests/WorkspaceTests.swift`, `Tests/CanopyCoreTests/Support/Fixtures.swift`

**Interfaces:**
- Consumes: `Workspace`, `GitRunner`, `BranchSlug`, `Fixture.git(in:before:)`.
- Produces:
  - `WorkspaceError.invalidBase(String)`, code `invalid_base`.
  - `Workspace.hasUncommittedChanges(path: String) async throws -> Bool`, true when `git worktree remove` would need `--force`.
  - `Workspace.refresh(repoPath:)` now queues behind earlier refreshes of the same repo, and a failed refresh keeps the last known rows with `error` set.
  - `eventually(timeout:isolation:_:)` runs its condition on the caller's actor, so main-actor tests can use it.

- [ ] **Step 1: Write the failing tests**

The branch names cover minor 5 ("@{-1}"), option injection ("-x"), and names git refuses to create ("HEAD", ".lock").
`staleRefreshDoesNotReplaceNewerRows` wraps git so one `worktree list` reads its output, removes a marker, and returns a second later, while a newer refresh sees a worktree added in between.

`Tests/CanopyCoreTests/RowLifecycleTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/RowLifecycleTests.swift
+++ b/Tests/CanopyCoreTests/RowLifecycleTests.swift
@@ -92,14 +92,48 @@ struct RowLifecycleTests {
         let dir = try TempDir()
         let (repo, workspace) = try await setUp(dir)
 
-        await #expect(throws: WorkspaceError.invalidBranch("bad name")) {
-            try await workspace.createRow(repoPath: repo, branch: "bad name")
+        for name in ["bad name", "@{-1}", "-x", "HEAD", "feat/x.lock"] {
+            await #expect(throws: WorkspaceError.invalidBranch(name)) {
+                try await workspace.createRow(repoPath: repo, branch: name)
+            }
         }
         await #expect(throws: WorkspaceError.branchCheckedOut("main")) {
             try await workspace.createRow(repoPath: repo, branch: "main")
         }
     }
 
+    @Test func rejectsBasesThatAreNotCommits() async throws {
+        let dir = try TempDir()
+        let (repo, workspace) = try await setUp(dir)
+
+        for base in ["-q", "nope", "main:missing"] {
+            await #expect(throws: WorkspaceError.invalidBase(base)) {
+                try await workspace.createRow(repoPath: repo, branch: "feat/based", base: base)
+            }
+        }
+    }
+
+    @Test func missingRepoFolderSaysSo() async throws {
+        let dir = try TempDir()
+        let (repo, workspace) = try await setUp(dir)
+        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
+
+        await #expect(throws: WorkspaceError.pathNotFound(repo)) {
+            try await workspace.createRow(repoPath: repo, branch: "feat/x")
+        }
+    }
+
+    @Test func slugSkipsFolderOfDeletedWorktree() async throws {
+        let dir = try TempDir()
+        let (repo, workspace) = try await setUp(dir)
+        let gone = try await workspace.createRow(repoPath: repo, branch: "feat/gone")
+        try FileManager.default.removeItem(atPath: gone.row.path)
+
+        let created = try await workspace.createRow(repoPath: repo, branch: "feat-gone")
+
+        #expect(created.row.path == dir.sub("home/worktrees/demo/feat-gone-2"))
+    }
+
     @Test func slugCollisionGetsSuffix() async throws {
         let dir = try TempDir()
         let (repo, workspace) = try await setUp(dir)
@@ -191,6 +225,38 @@ struct RowLifecycleTests {
         #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main"])
     }
 
+    @Test func failedBranchDeletionStillRemovesTheRow() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir, origin: true)
+        let git = try Fixture.git(
+            in: dir, before: #"[[ "$1" == "branch" && "$2" == "-D" ]] && { echo "error: simulated" >&2; exit 1; }"#)
+        let home = CanopyHome(path: dir.sub("home"))
+        let workspace = Workspace(home: home, git: git)
+        try await workspace.start()
+        try await workspace.addRepo(path: repo)
+        let created = try await workspace.createRow(repoPath: repo, branch: "feat/stuck")
+        try await workspace.setSelectedRow(path: created.row.path)
+
+        await #expect(throws: WorkspaceError.self) {
+            try await workspace.removeRow(path: created.row.path, deleteBranch: true)
+        }
+
+        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main"])
+        let saved = StateStore(url: home.stateFile).load().state
+        #expect(saved.repos.first?.rowOrder == [])
+        #expect(saved.selectedRowPath == nil)
+    }
+
+    @Test func reportsUncommittedChanges() async throws {
+        let dir = try TempDir()
+        let (repo, workspace) = try await setUp(dir)
+        let created = try await workspace.createRow(repoPath: repo, branch: "feat/check")
+
+        #expect(try await workspace.hasUncommittedChanges(path: created.row.path) == false)
+        try "x".write(toFile: created.row.path + "/new.txt", atomically: true, encoding: .utf8)
+        #expect(try await workspace.hasUncommittedChanges(path: created.row.path) == true)
+    }
+
     @Test func dirtyRowNeedsForce() async throws {
         let dir = try TempDir()
         let (repo, workspace) = try await setUp(dir)
```

`Tests/CanopyCoreTests/Support/Fixtures.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/Support/Fixtures.swift
+++ b/Tests/CanopyCoreTests/Support/Fixtures.swift
@@ -54,7 +54,12 @@ func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async thro
 }
 
 /// Polls until `condition` holds or the timeout passes. Returns whether it held.
-func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
+/// The condition runs on the caller's actor, so main-actor tests can read main-actor state.
+func eventually(
+    timeout: Duration = .seconds(5),
+    isolation: isolated (any Actor)? = #isolation,
+    _ condition: () async -> Bool
+) async -> Bool {
     let clock = ContinuousClock()
     let deadline = clock.now + timeout
     while clock.now < deadline {
```

`Tests/CanopyCoreTests/WorkspaceTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/WorkspaceTests.swift
+++ b/Tests/CanopyCoreTests/WorkspaceTests.swift
@@ -220,6 +220,69 @@ struct WorkspaceTests {
         #expect(!relocated.isMissing)
     }
 
+    @Test func staleRefreshDoesNotReplaceNewerRows() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let marker = dir.sub("slow-once")
+        // With the marker present, the next worktree list is read at once, then the marker is removed,
+        // and the list is returned a second later.
+        let script = dir.sub("slow-git")
+        try """
+        #!/bin/bash
+        if [[ "$1 $2" == "worktree list" && -f "\(marker)" ]]; then
+            out=$(mktemp)
+            /usr/bin/git "$@" > "$out"
+            status=$?
+            rm "\(marker)"
+            sleep 1
+            cat "$out"
+            rm "$out"
+            exit $status
+        fi
+        exec /usr/bin/git "$@"
+        """.write(toFile: script, atomically: true, encoding: .utf8)
+        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
+        let git = GitRunner(executable: script, environment: ProcessInfo.processInfo.environment)
+        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
+        try await workspace.start()
+        try await workspace.addRepo(path: repo)
+
+        FileManager.default.createFile(atPath: marker, contents: nil)
+        async let stale: Void = workspace.refresh(repoPath: repo)
+        #expect(await eventually { !FileManager.default.fileExists(atPath: marker) })
+        try await Fixture.worktree(repo: repo, branch: "feat/new", at: dir.sub("new"))
+        await workspace.refresh(repoPath: repo)
+        await stale
+
+        #expect(await workspace.snapshot.repos.first?.external.map(\.branch) == ["feat/new"])
+    }
+
+    @Test func failedRefreshKeepsRowsAndShowsTheError() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        try await Fixture.worktree(repo: repo, branch: "feat/kept", at: dir.sub("kept"))
+        let marker = dir.sub("fail")
+        let git = try Fixture.git(
+            in: dir,
+            before:
+                #"[[ "$1 $2" == "worktree list" && -f "\#(marker)" ]] && { echo "fatal: simulated" >&2; exit 128; }"#
+        )
+        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
+        try await workspace.start()
+        try await workspace.addRepo(path: repo)
+
+        FileManager.default.createFile(atPath: marker, contents: nil)
+        await workspace.refresh(repoPath: repo)
+
+        let failed = try #require(await workspace.snapshot.repos.first)
+        #expect(failed.rows.map(\.branch) == ["main"])
+        #expect(failed.external.map(\.branch) == ["feat/kept"])
+        #expect(failed.error?.contains("simulated") == true)
+        try FileManager.default.removeItem(atPath: marker)
+        await workspace.refresh(repoPath: repo)
+        #expect(await workspace.snapshot.repos.first?.error == nil)
+    }
+
     @Test func updatesStreamYieldsChanges() async throws {
         let dir = try TempDir()
         let repo = try await Fixture.repo(in: dir)
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "RowLifecycleTests|WorkspaceTests"`
Expected: build failure, `type 'WorkspaceError' has no member 'invalidBase'` and `value of type 'Workspace' has no member 'hasUncommittedChanges'`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift
+++ b/Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift
@@ -39,7 +39,13 @@ extension Workspace {
         let dirName = state.repos[index].dirName
         var warnings: [String] = []
 
-        guard await git.succeeds(["check-ref-format", "--branch", branch], in: repoPath) else {
+        guard FileManager.default.fileExists(atPath: repoPath) else {
+            throw WorkspaceError.pathNotFound(repoPath)
+        }
+        // `--branch` would expand "@{-1}" to the previous branch, and a leading "-" would read as an option.
+        guard !branch.hasPrefix("-"), branch != "HEAD",
+            await git.succeeds(["check-ref-format", "refs/heads/\(branch)"], in: repoPath)
+        else {
             throw WorkspaceError.invalidBranch(branch)
         }
         if snapshot.repo(path: repoPath)?.allRows.contains(where: { $0.branch == branch }) == true {
@@ -51,9 +57,14 @@ extension Workspace {
             warnings.append(warning)
         }
 
+        // A worktree whose folder was deleted keeps its path until it is pruned, so git would refuse to reuse it.
+        await refresh(repoPath: repoPath)
+        let registered = Set(snapshot.repo(path: repoPath)?.allRows.map(\.path) ?? [])
         let parent = home.worktreesRoot.appending(path: dirName)
         try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
-        let folder = BranchSlug.folder(for: branch, in: parent) { FileManager.default.fileExists(atPath: $0.path) }
+        let folder = BranchSlug.folder(for: branch, in: parent) {
+            registered.contains(Paths.canonical($0.path)) || FileManager.default.fileExists(atPath: $0.path)
+        }
 
         var arguments = ["worktree", "add"]
         if await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoPath) {
@@ -65,6 +76,11 @@ extension Workspace {
         } else {
             let start: String
             if let base {
+                guard !base.hasPrefix("-"),
+                    await git.succeeds(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoPath)
+                else {
+                    throw WorkspaceError.invalidBase(base)
+                }
                 start = base
             } else {
                 start = await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin)
@@ -115,13 +131,6 @@ extension Workspace {
                 }
                 throw WorkspaceError.git(error)
             }
-            if deleteBranch, let branch = row.branch {
-                do {
-                    try await git.run(["branch", "-D", branch], in: row.repoPath)
-                } catch let error as GitError {
-                    throw WorkspaceError.git(error)
-                }
-            }
             if let index = try? entryIndex(repoPath: row.repoPath) {
                 state.repos[index].rowOrder.removeAll { $0 == path }
             }
@@ -130,6 +139,23 @@ extension Workspace {
             }
             try save()
             await refresh(repoPath: row.repoPath)
+            // Last, so a branch that cannot be deleted still leaves the row fully removed.
+            if deleteBranch, let branch = row.branch {
+                do {
+                    try await git.run(["branch", "-D", branch], in: row.repoPath)
+                } catch let error as GitError {
+                    throw WorkspaceError.git(error)
+                }
+            }
+        }
+    }
+
+    /// Whether `git worktree remove` would refuse the row without `--force`: modified or untracked files.
+    public func hasUncommittedChanges(path: String) async throws -> Bool {
+        do {
+            return !(try await git.run(["status", "--porcelain", "-z"], in: path)).isEmpty
+        } catch let error as GitError {
+            throw WorkspaceError.git(error)
         }
     }
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -13,6 +13,7 @@ public actor Workspace {
     var repoSnapshots: [String: RepoSnapshot] = [:]
     var watchers: [String: DirectoryWatcher] = [:]
     var pendingRefreshes: [String: Task<Void, Never>] = [:]
+    var refreshQueues: [String: Task<Void, Never>] = [:]
     var gitQueues: [String: Task<Void, Never>] = [:]
     var instanceLock: InstanceLock?
     var subscribers: [UUID: AsyncStream<WorkspaceSnapshot>.Continuation] = [:]
@@ -196,7 +197,19 @@ public actor Workspace {
         }
     }
 
+    /// Refreshes of one repo run one after another, so a slow worktree list can never land after a newer one,
+    /// and the snapshot reflects git as of this call once it returns.
     public func refresh(repoPath: String) async {
+        let previous = refreshQueues[repoPath]
+        let task = Task {
+            await previous?.value
+            await self.refreshNow(repoPath: repoPath)
+        }
+        refreshQueues[repoPath] = task
+        await task.value
+    }
+
+    private func refreshNow(repoPath: String) async {
         guard let entry = state.repos.first(where: { $0.path == repoPath }) else { return }
         guard FileManager.default.fileExists(atPath: entry.path) else {
             repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", isMissing: true)
@@ -207,7 +220,11 @@ public actor Workspace {
         do {
             output = try await git.run(["worktree", "list", "--porcelain", "-z"], in: entry.path)
         } catch {
-            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", error: "\(error)")
+            // Keep the last known rows, so a passing git failure does not close the view onto them.
+            var failed = repoSnapshots[entry.path] ?? RepoSnapshot(path: entry.path, name: "")
+            failed.isMissing = false
+            failed.error = "\(error)"
+            repoSnapshots[entry.path] = failed
             publish()
             return
         }
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/WorkspaceError.swift
+++ b/Sources/CanopyCore/Workspace/WorkspaceError.swift
@@ -9,6 +9,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case ambiguousRow(String, repos: [String])
     case missingTarget(flag: String)
     case invalidBranch(String)
+    case invalidBase(String)
     case branchCheckedOut(String)
     case worktreeDirty(String)
     case cannotRemoveMain
@@ -27,6 +28,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .ambiguousRow: "ambiguous_row"
         case .missingTarget: "missing_target"
         case .invalidBranch: "invalid_branch"
+        case .invalidBase: "invalid_base"
         case .branchCheckedOut: "branch_checked_out"
         case .worktreeDirty: "worktree_dirty"
         case .cannotRemoveMain: "cannot_remove_main"
@@ -48,6 +50,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
             "\"\(name)\" exists in several repos (\(repos.joined(separator: ", "))). Pass --repo."
         case .missingTarget(let flag): "Could not tell which one you mean. Pass \(flag)."
         case .invalidBranch(let name): "Not a valid branch name: \(name)"
+        case .invalidBase(let ref): "No commit matches --from \(ref)."
         case .branchCheckedOut(let name): "Branch \(name) is already checked out in another worktree."
         case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
         case .cannotRemoveMain: "The main checkout cannot be removed."
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`
Expected: lint prints nothing after its command line, and `Test run with 107 tests in 18 suites passed`.

Check that the stale refresh test bites: delete the body of the new `refresh(repoPath:)` down to a direct `await refreshNow(repoPath: repoPath)` and rerun `--filter staleRefresh`.
Expected: `staleRefreshDoesNotReplaceNewerRows` fails. Restore the queue.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Workspace Tests/CanopyCoreTests
git commit -m "fix: harden row creation and refresh against edge cases"
```

## Task 2: Run processes in pseudo-terminals

This is the process half of a terminal, with no UI.
The C target does only what must happen between `fork` and `exec`.
`PtyProcess` reads output on a private queue and hands each chunk to the main actor synchronously, so a flood of output waits for the screen instead of growing a buffer.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CPty/include/CPty.h`, `Sources/CPty/pty.c`
- Create: `Sources/CanopyCore/Terminal/PtyProcess.swift`
- Test: `Tests/CanopyCoreTests/PtyProcessTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `TerminalSize(columns: Int, rows: Int)`, `TerminalSize.standard` (80 by 24).
  - `TerminalLaunch(executable: String, arguments: [String], environment: [String: String], directory: String)`, where `arguments` is the whole argv.
  - `ForegroundProcess(pid: pid_t, name: String)`.
  - `PtySpawnError(executable: String, code: Int32)`.
  - `PtyProcess(_ launch: TerminalLaunch, size: TerminalSize, onOutput: @MainActor @Sendable (Data) -> Void, onExit: @MainActor @Sendable (Int32) -> Void) throws`, with `pid`, `write(_: Data)`, `write(_: String)`, `resize(_:)`, `foreground: ForegroundProcess?`, `isAtPrompt: Bool`, `terminate()`, and `static exitCode(fromWaitStatus:) -> Int32`.

- [ ] **Step 1: Write the failing tests**

`childGetsNoInheritedDescriptors` takes its descriptor with `F_DUPFD`, which picks the lowest free number from 200 up.
A fixed number with `dup2` would replace another test's pty master when tests run in parallel.

`Tests/CanopyCoreTests/PtyProcessTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
final class PtyRecorder {
    var output = Data()
    var exitCode: Int32?
    var text: String { String(decoding: output, as: UTF8.self) }
}

@MainActor
struct PtyProcessTests {
    let environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory()]

    func start(_ arguments: [String], environment: [String: String]? = nil, directory: String = "/") throws -> (
        PtyProcess, PtyRecorder
    ) {
        let recorder = PtyRecorder()
        let launch = TerminalLaunch(
            executable: arguments[0], arguments: arguments, environment: environment ?? self.environment,
            directory: directory)
        let process = try PtyProcess(
            launch, size: .standard,
            onOutput: { recorder.output.append($0) },
            onExit: { recorder.exitCode = $0 }
        )
        return (process, recorder)
    }

    @Test func deliversOutputThenExitCode() async throws {
        let (_, recorder) = try start(["/bin/sh", "-c", "printf hello; exit 3"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.exitCode == 3)
        #expect(recorder.text == "hello")
    }

    @Test func reportsProcessesThatExitAtOnce() async throws {
        for _ in 0..<20 {
            let (_, recorder) = try start(["/usr/bin/true"])
            #expect(await eventually { recorder.exitCode == 0 })
        }
    }

    @Test func startsInTheFolderWithTheEnvironment() async throws {
        let dir = try TempDir()
        let folder = dir.sub("with space")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let (_, recorder) = try start(
            ["/bin/sh", "-c", #"printf '%s|%s' "$(pwd -P)" "$CANOPY_X""#],
            environment: ["PATH": "/usr/bin:/bin", "CANOPY_X": "yes"], directory: folder)

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text == "\(folder)|yes")
    }

    @Test func childGetsNoInheritedDescriptors() async throws {
        // F_DUPFD takes the lowest free number from 200 up, so it never replaces a descriptor another test uses.
        let original = open("/dev/null", O_RDONLY)
        let leaked = fcntl(original, F_DUPFD, 200)
        defer {
            close(original)
            close(leaked)
        }

        let (_, recorder) = try start(["/bin/sh", "-c", "ls /dev/fd"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(!recorder.text.split(whereSeparator: \.isWhitespace).contains("\(leaked)"))
    }

    @Test func childGetsDefaultSignalHandling() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }

        // With SIGPIPE ignored, `yes` would print "Broken pipe" and exit 1 instead of dying from the signal.
        let (_, recorder) = try start(["/bin/bash", "-c", "yes | head -1 >/dev/null; echo status=${PIPESTATUS[0]}"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.contains("status=141"))
    }

    @Test func largeOutputArrivesWholeAndInOrder() async throws {
        let (_, recorder) = try start(["/usr/bin/seq", "1", "200000"])

        #expect(await eventually(timeout: .seconds(20)) { recorder.exitCode != nil })
        #expect(recorder.text.hasSuffix("199999\r\n200000\r\n"))
        #expect(recorder.text.components(separatedBy: "\r\n").count == 200_001)
    }

    @Test func inputReachesTheProcess() async throws {
        let (process, recorder) = try start(["/bin/sh", "-c", #"read line; printf 'got:%s' "$line""#])

        process.write("hi\r")

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.contains("got:hi"))
    }

    @Test func resizeReachesTheProcess() async throws {
        let (process, recorder) = try start(["/bin/sh", "-c", "sleep 0.3; stty size"])

        process.resize(TerminalSize(columns: 132, rows: 40))

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.contains("40 132"))
    }

    @Test func foregroundAndPromptFollowTheShell() async throws {
        let (process, recorder) = try start(["/bin/bash", "--noprofile", "--norc", "-i"])

        #expect(await eventually { process.isAtPrompt })
        #expect(process.foreground?.name == "bash")
        process.write("sleep 3\r")
        #expect(await eventually { process.foreground?.name == "sleep" })
        #expect(!process.isAtPrompt)

        process.terminate()
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.exitCode == nil)
    }

    @Test func terminateEndsTheWholeProcessGroup() async throws {
        let (process, _) = try start(["/bin/sh", "-c", "sleep 30 & sleep 30"])
        let group = process.pid
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(-group, 0) == 0)

        process.terminate()

        #expect(await eventually { kill(-group, 0) == -1 && errno == ESRCH })
    }

    @Test func missingExecutableThrows() {
        #expect(throws: PtySpawnError.self) { try start(["/nonexistent/shell"]) }
    }

    @Test func exitCodeDecodesSignals() {
        #expect(PtyProcess.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(PtyProcess.exitCode(fromWaitStatus: SIGHUP) == 129)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PtyProcessTests`
Expected: build failure, `cannot find type 'PtyProcess' in scope`.

- [ ] **Step 3: Implement**

`Package.swift` (modify):

```diff
--- a/Package.swift
+++ b/Package.swift
@@ -12,7 +12,8 @@ let package = Package(
         .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
     ],
     targets: [
-        .target(name: "CanopyCore"),
+        .target(name: "CPty"),
+        .target(name: "CanopyCore", dependencies: ["CPty"]),
         .executableTarget(name: "CanopyApp", dependencies: ["CanopyCore"]),
         .executableTarget(
             name: "CanopyCLI",
```

`Sources/CPty/include/CPty.h` (new):

```c
#ifndef CANOPY_CPTY_H
#define CANOPY_CPTY_H

#include <sys/types.h>

/// Starts `path` as the session leader of a new pseudo-terminal, which becomes its controlling terminal.
/// The child starts in `directory` with default signal handling, an empty signal mask, and no open
/// descriptors besides 0, 1, and 2. Returns the child's pid and stores the master descriptor, which is
/// non-blocking and close-on-exec, in `master`. Returns -1 with errno set on failure.
pid_t canopy_pty_spawn(
    const char *path, char *const argv[], char *const envp[], const char *directory,
    unsigned short columns, unsigned short rows, int *master);

/// Sets the terminal size the child sees. Returns 0, or -1 with errno set.
int canopy_pty_resize(int master, unsigned short columns, unsigned short rows);

#endif
```

`Sources/CPty/pty.c` (new):

```c
#include "CPty.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <unistd.h>
#include <util.h>

pid_t canopy_pty_spawn(
    const char *path, char *const argv[], char *const envp[], const char *directory,
    unsigned short columns, unsigned short rows, int *master)
{
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    struct rlimit limit;
    int highest = 10240;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur < 1048576) {
        highest = (int)limit.rlim_cur;
    }
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &size);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // The parent has other threads, so only async-signal-safe calls from here on.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int signal_number = 1; signal_number < NSIG; signal_number++) {
            signal(signal_number, SIG_DFL);
        }
        for (int descriptor = 3; descriptor < highest; descriptor++) {
            close(descriptor);
        }
        if (chdir(directory) != 0) {
            _exit(126);
        }
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    *master = fd;
    return pid;
}

int canopy_pty_resize(int master, unsigned short columns, unsigned short rows)
{
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    return ioctl(master, TIOCSWINSZ, &size);
}
```

`Sources/CanopyCore/Terminal/PtyProcess.swift` (new):

```swift
import CPty
import Darwin
import Foundation
import Synchronization

public struct TerminalSize: Sendable, Equatable, Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public static let standard = TerminalSize(columns: 80, rows: 24)
}

/// What to run in a new pseudo-terminal.
public struct TerminalLaunch: Sendable, Equatable {
    public var executable: String
    /// The whole argv, starting with argv[0]. A leading "-" in argv[0] makes a shell a login shell.
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

public struct ForegroundProcess: Sendable, Equatable {
    /// The foreground process group, which is also the pid of its leader.
    public var pid: pid_t
    public var name: String
}

public struct PtySpawnError: Error, Sendable, Equatable, CustomStringConvertible {
    public var executable: String
    public var code: Int32

    public var description: String {
        "Could not start \(executable): \(String(cString: strerror(code)))"
    }
}

/// A process running in its own pseudo-terminal. Output, then the exit status, arrive on the main actor.
/// Output is handed over synchronously, so a program that floods the terminal waits for the screen to
/// catch up instead of filling an unbounded buffer.
public final class PtyProcess: @unchecked Sendable {
    public typealias OutputHandler = @MainActor @Sendable (Data) -> Void
    public typealias ExitHandler = @MainActor @Sendable (Int32) -> Void

    private struct State {
        var fd: Int32
        var exited = false
        var onOutput: OutputHandler?
        var onExit: ExitHandler?
    }

    public let pid: pid_t
    /// The descriptor closes only in the read source's cancel handler, and writes hold the lock,
    /// so no write can reach a reused descriptor number.
    private let state: Mutex<State>
    private let readQueue = DispatchQueue(label: "canopy.pty.read")
    private let writeQueue = DispatchQueue(label: "canopy.pty.write")
    // Touched only on readQueue.
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    public init(
        _ launch: TerminalLaunch,
        size: TerminalSize,
        onOutput: @escaping OutputHandler,
        onExit: @escaping ExitHandler
    ) throws {
        guard access(launch.executable, X_OK) == 0 else {
            throw PtySpawnError(executable: launch.executable, code: errno)
        }
        let argv = launch.arguments.map { strdup($0) } + [nil]
        let envp = launch.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        var master: Int32 = -1
        let pid = canopy_pty_spawn(
            launch.executable, argv, envp, launch.directory,
            UInt16(clamping: size.columns), UInt16(clamping: size.rows), &master)
        guard pid > 0 else { throw PtySpawnError(executable: launch.executable, code: errno) }
        self.pid = pid
        self.state = Mutex(State(fd: master, onOutput: onOutput, onExit: onExit))
        let fd = master
        readQueue.async { self.watch(fd) }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async {
            var offset = 0
            while offset < data.count {
                let (count, code, fd) = self.state.withLock { state -> (Int, Int32, Int32) in
                    guard state.fd >= 0 else { return (-1, EBADF, -1) }
                    let count = data.withUnsafeBytes {
                        Darwin.write(state.fd, $0.baseAddress! + offset, $0.count - offset)
                    }
                    return (count, errno, state.fd)
                }
                if count > 0 {
                    offset += count
                } else if code == EAGAIN {
                    // The program is not reading its input yet. Wait outside the lock so output keeps flowing.
                    var poll = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&poll, 1, 100)
                } else if code != EINTR {
                    return
                }
            }
        }
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    public func resize(_ size: TerminalSize) {
        state.withLock { state in
            guard state.fd >= 0 else { return }
            _ = canopy_pty_resize(state.fd, UInt16(clamping: size.columns), UInt16(clamping: size.rows))
        }
    }

    /// The process group the terminal is running in the foreground, such as `claude` or the shell itself.
    public var foreground: ForegroundProcess? {
        let group = state.withLock { $0.fd >= 0 ? tcgetpgrp($0.fd) : -1 }
        guard group > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
        return ForegroundProcess(pid: group, name: name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// True while the process itself is in the foreground with its line editor waiting for input.
    /// Shells switch the terminal out of canonical mode when their prompt is ready.
    public var isAtPrompt: Bool {
        state.withLock { state in
            guard state.fd >= 0, tcgetpgrp(state.fd) == pid else { return false }
            var attributes = termios()
            return tcgetattr(state.fd, &attributes) == 0 && attributes.c_lflag & tcflag_t(ICANON) == 0
        }
    }

    /// Hangs up the terminal. No more output or exit status is delivered.
    public func terminate() {
        state.withLock { state in
            state.onOutput = nil
            state.onExit = nil
            if !state.exited {
                kill(pid, SIGHUP)
            }
        }
        readQueue.async { self.stopReading() }
    }

    // MARK: readQueue

    private func watch(_ fd: Int32) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        reader.setEventHandler { self.drain() }
        reader.setCancelHandler {
            self.state.withLock { state in
                close(state.fd)
                state.fd = -1
            }
        }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        exit.setEventHandler { self.finish() }
        readSource = reader
        exitSource = exit
        reader.activate()
        exit.activate()
        // A child that exited before the source was armed may never be reported, so look without reaping.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            finish()
        }
    }

    /// Reads what is available, up to 256 KB, and hands it to the main actor. Returns the byte count.
    @discardableResult
    private func drain() -> Int {
        guard readSource != nil else { return 0 }
        let fd = state.withLock { $0.fd }
        var chunk = Data()
        while chunk.count < 262_144 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                chunk.append(contentsOf: buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if count == 0 || errno != EAGAIN {
                    // EOF or EIO: nothing holds the terminal open anymore.
                    stopReading()
                }
                break
            }
        }
        if !chunk.isEmpty, let handler = state.withLock({ $0.onOutput }) {
            DispatchQueue.main.sync { MainActor.assumeIsolated { handler(chunk) } }
        }
        return chunk.count
    }

    private func finish() {
        guard let exitSource else { return }
        exitSource.cancel()
        self.exitSource = nil
        let status = state.withLock { state -> Int32 in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            state.exited = true
            return status
        }
        // Take what the shell wrote before exiting, but stop if something it left behind keeps writing.
        for _ in 0..<16 where drain() > 0 {}
        stopReading()
        let handler = state.withLock { state in
            defer {
                state.onOutput = nil
                state.onExit = nil
            }
            return state.onExit
        }
        if let handler {
            let code = Self.exitCode(fromWaitStatus: status)
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(code) } }
        }
    }

    private func stopReading() {
        readSource?.cancel()
        readSource = nil
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`
Expected: `Test run with 119 tests in 19 suites passed`.

Check that the child fixes are what the tests pin: in `pty.c`, replace `signal(signal_number, SIG_DFL);` with `(void)signal_number;` and `close(descriptor);` with `(void)descriptor;`, then rerun `--filter "childGets"`.
Expected: both tests fail, one with "yes: stdout: Broken pipe" and one listing descriptor 200 or above. Restore `pty.c`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CPty Sources/CanopyCore/Terminal Tests/CanopyCoreTests/PtyProcessTests.swift
git commit -m "feat: run processes in pseudo-terminals"
```

## Task 3: Terminal environments and setup scripts

Pure pieces the panes and setup runner need: IDs, the row a pane belongs to, how the shell is launched, the clean environment, and the script that runs setup commands.

**Files:**
- Create: `Sources/CanopyCore/Terminal/TerminalIDs.swift`
- Create: `Sources/CanopyCore/Terminal/ShellSettings.swift`
- Create: `Sources/CanopyCore/Terminal/PaneEnvironment.swift`
- Create: `Sources/CanopyCore/Terminal/SetupScript.swift`
- Test: `Tests/CanopyCoreTests/PaneEnvironmentTests.swift`, `Tests/CanopyCoreTests/SetupScriptTests.swift`

**Interfaces:**
- Consumes: `TerminalLaunch`, `CanopyHome`, `CanopyVersion`, `Row`, `Subprocess`, `offPool`.
- Produces:
  - `PaneID(_ number: Int)` whose description is `"p12"`, and `TabID(_ number: Int)`.
  - `PaneContext(row: Row, repoName: String)` with `repoName`, `repoPath`, `rowName`, `rowPath`.
  - `ShellSettings(shell:baseEnvironment:cliDirectory:home:language:)`, `ShellSettings.current(home:cliDirectory:)`, `interactiveShell(environment:directory:) -> TerminalLaunch`, `script(_:environment:directory:) -> TerminalLaunch`.
  - `LoginShell.path(environment:) -> String`, `LoginShell.language(for:exists:) -> String`.
  - `PaneEnvironment.build(settings:context:pane:) -> [String: String]`.
  - `SetupScript.render(_ commands: [String], label: String) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PaneEnvironmentTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

struct PaneEnvironmentTests {
    let context = PaneContext(
        row: Row(repoPath: "/r/demo", path: "/w/feat-x", branch: "feat/x", head: nil, rowClass: .canopy),
        repoName: "demo"
    )

    func settings(_ base: [String: String], shell: String = "/bin/zsh") -> ShellSettings {
        ShellSettings(
            shell: shell, baseEnvironment: base, cliDirectory: "/App/Contents/Resources/bin",
            home: CanopyHome(path: "/h/.canopy"), language: "en_AU.UTF-8")
    }

    @Test func keepsLoginSessionVariablesAndDropsTheRest() {
        let base = [
            "HOME": "/Users/me", "USER": "me", "SSH_AUTH_SOCK": "/tmp/agent", "CLAUDE_CODE_CHILD_SESSION": "1",
            "PATH": "/some/tool/bin:/usr/bin", "GIT_DIR": "/elsewhere/.git",
        ]

        let environment = PaneEnvironment.build(settings: settings(base), context: context, pane: PaneID(12))

        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["USER"] == "me")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(environment["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(environment["GIT_DIR"] == nil)
        #expect(environment["PATH"] == "/App/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["SHELL"] == "/bin/zsh")
        #expect(environment["LANG"] == "en_AU.UTF-8")
    }

    @Test func describesTheTerminalRowAndPane() {
        let environment = PaneEnvironment.build(settings: settings([:]), context: context, pane: PaneID(12))

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "Canopy")
        #expect(environment["CANOPY_HOME"] == "/h/.canopy")
        #expect(environment["CANOPY_REPO"] == "demo")
        #expect(environment["CANOPY_ROW"] == "feat/x")
        #expect(environment["CANOPY_ROW_PATH"] == "/w/feat-x")
        #expect(environment["CANOPY_ROOT_PATH"] == "/r/demo")
        #expect(environment["CANOPY_PANE"] == "p12")
        #expect(environment["HOME"] == NSHomeDirectory())
    }

    @Test func keepsTheAppsOwnLanguage() {
        let environment = PaneEnvironment.build(
            settings: settings(["LANG": "fr_FR.UTF-8"]), context: context, pane: PaneID(1))

        #expect(environment["LANG"] == "fr_FR.UTF-8")
    }

    @Test func languageFollowsTheLocaleWhenMacOSHasIt() {
        let installed: Set<String> = ["en_AU.UTF-8", "en_US.UTF-8"]

        #expect(LoginShell.language(for: "en_AU", exists: installed.contains) == "en_AU.UTF-8")
        #expect(LoginShell.language(for: "en_AU@rg=auzzzz", exists: installed.contains) == "en_AU.UTF-8")
        #expect(LoginShell.language(for: "en-AU", exists: installed.contains) == "en_AU.UTF-8")
        #expect(LoginShell.language(for: "xx_YY", exists: installed.contains) == "en_US.UTF-8")
    }

    @Test func interactiveShellIsALoginShell() {
        let launch = settings([:]).interactiveShell(environment: [:], directory: "/w")

        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-zsh"])
        #expect(launch.directory == "/w")
    }

    @Test func scriptsRunInAnInteractiveLoginShell() {
        let zsh = settings([:]).script("echo hi", environment: [:], directory: "/w")
        let fish = settings([:], shell: "/opt/homebrew/bin/fish").script("echo hi", environment: [:], directory: "/w")

        #expect(zsh.arguments == ["zsh", "-i", "-l", "-c", "echo hi"])
        #expect(fish.executable == "/bin/zsh")
        #expect(fish.arguments == ["zsh", "-i", "-l", "-c", "echo hi"])
    }

    @Test func loginShellIsRunnable() {
        #expect(access(LoginShell.path(), X_OK) == 0)
    }
}
```

`Tests/CanopyCoreTests/SetupScriptTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

struct SetupScriptTests {
    func run(_ commands: [String], shell: String) async throws -> (status: Int32, output: String, dir: TempDir) {
        let dir = try TempDir()
        let script = SetupScript.render(commands, label: "Setup")
        let result = try await offPool {
            try Subprocess.run(
                shell, ["-c", script], environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path, "V": "value"],
                directory: dir.path, timeout: .seconds(10))
        }
        return (result.status, String(decoding: result.stdout, as: UTF8.self), dir)
    }

    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func stopsAtTheFirstFailureWithItsCode(shell: String) async throws {
        let result = try await run(["echo one", "sh -c 'exit 7'", "echo three"], shell: shell)

        #expect(result.status == 7)
        #expect(result.output.contains("$ echo one"))
        #expect(result.output.contains("one\n"))
        #expect(!result.output.contains("three"))
        #expect(result.output.contains("Setup failed with exit code 7."))
    }

    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func keepsQuotesVariablesAndUnicode(shell: String) async throws {
        let result = try await run([#"printf '%s|%s|%s\n' "it's" "$V" "héllo ✓""#], shell: shell)

        #expect(result.status == 0)
        #expect(result.output.contains("it's|value|héllo ✓"))
    }

    @Test func laterCommandsSeeEarlierOnes() async throws {
        let result = try await run(["mkdir sub", "cd sub", "pwd -P"], shell: "/bin/sh")

        #expect(result.output.hasSuffix(result.dir.sub("sub") + "\n"))
    }

    @Test func noCommandsSucceed() async throws {
        #expect(try await run([], shell: "/bin/sh").status == 0)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "PaneEnvironmentTests|SetupScriptTests"`
Expected: build failure, `cannot find 'PaneContext' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Terminal/PaneEnvironment.swift` (new):

```swift
import Foundation

public enum PaneEnvironment {
    /// What a macOS login session starts with. Everything else in the app's environment came from whatever
    /// launched it, such as a Claude Code session running a dev build, and must not reach terminals.
    static let inherited: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "LC_CTYPE",
    ]
    /// The login shell's path_helper adds /etc/paths to this, and the user's startup files add the rest.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func build(settings: ShellSettings, context: PaneContext, pane: PaneID) -> [String: String] {
        var environment = settings.baseEnvironment.filter { inherited.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["LANG"] = environment["LANG"] ?? settings.language
        environment["SHELL"] = settings.shell
        environment["PATH"] = ([settings.cliDirectory].compactMap { $0 } + [systemPath]).joined(separator: ":")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Canopy"
        environment["TERM_PROGRAM_VERSION"] = CanopyVersion.current
        environment["CANOPY_HOME"] = settings.home.root.path
        environment["CANOPY_REPO"] = context.repoName
        environment["CANOPY_ROW"] = context.rowName
        environment["CANOPY_ROW_PATH"] = context.rowPath
        environment["CANOPY_ROOT_PATH"] = context.repoPath
        environment["CANOPY_PANE"] = pane.description
        return environment
    }
}
```

`Sources/CanopyCore/Terminal/SetupScript.swift` (new):

```swift
/// Turns a repo's setup or teardown commands into one POSIX sh script. It shows each command before running
/// it, runs them in order in one shell so a `cd` carries over, and stops at the first failure with its exit code.
public enum SetupScript {
    public static func render(_ commands: [String], label: String) -> String {
        let runner = [
            "canopy_run() {",
            #"    printf '\033[1m$ %s\033[0m\n' "$1""#,
            #"    eval "$1" || {"#,
            "        canopy_status=$?",
            #"        printf '\n\033[31m%s failed with exit code %s.\033[0m\n' \#(quoted(label)) "$canopy_status""#,
            #"        exit "$canopy_status""#,
            "    }",
            "}",
        ]
        return (runner + commands.map { "canopy_run \(quoted($0))" }).joined(separator: "\n") + "\n"
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
```

`Sources/CanopyCore/Terminal/ShellSettings.swift` (new):

```swift
import Foundation

/// How Canopy starts terminal processes: which shell, and the environment they start from.
public struct ShellSettings: Sendable, Equatable {
    /// Shells that can run the POSIX sh scripts Canopy writes for setup and teardown.
    static let posixShells: Set<String> = ["zsh", "bash", "sh", "ksh", "dash"]

    public var shell: String
    /// The app's own environment. Terminals only get what a macOS login session starts with.
    public var baseEnvironment: [String: String]
    /// The folder holding the bundled `canopy`, put on PATH so agents in a terminal can run it.
    public var cliDirectory: String?
    public var home: CanopyHome
    /// LANG for terminals when the app has none, as Terminal sets it.
    public var language: String

    public init(
        shell: String,
        baseEnvironment: [String: String],
        cliDirectory: String?,
        home: CanopyHome,
        language: String = "en_US.UTF-8"
    ) {
        self.shell = shell
        self.baseEnvironment = baseEnvironment
        self.cliDirectory = cliDirectory
        self.home = home
        self.language = language
    }

    public static func current(home: CanopyHome, cliDirectory: String?) -> ShellSettings {
        ShellSettings(
            shell: LoginShell.path(),
            baseEnvironment: ProcessInfo.processInfo.environment,
            cliDirectory: cliDirectory,
            home: home,
            language: LoginShell.language(for: Locale.current.identifier) {
                FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)")
            }
        )
    }

    /// An interactive login shell, started the way Terminal starts one: argv[0] is "-zsh".
    public func interactiveShell(environment: [String: String], directory: String) -> TerminalLaunch {
        TerminalLaunch(
            executable: shell, arguments: ["-" + Self.name(of: shell)], environment: environment, directory: directory)
    }

    /// Runs a POSIX sh script in an interactive login shell, so it finds the same tools a terminal does.
    /// Shells that cannot run sh scripts, such as fish, hand it to zsh.
    public func script(_ script: String, environment: [String: String], directory: String) -> TerminalLaunch {
        let runner = Self.posixShells.contains(Self.name(of: shell)) ? shell : "/bin/zsh"
        return TerminalLaunch(
            executable: runner,
            arguments: [Self.name(of: runner), "-i", "-l", "-c", script],
            environment: environment,
            directory: directory
        )
    }

    static func name(of shell: String) -> String {
        (shell as NSString).lastPathComponent
    }
}

public enum LoginShell {
    /// The shell in the user's account record, which Terminal also uses. An app's $SHELL can be stale.
    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, access(shell, X_OK) == 0 { return shell }
        }
        if let shell = environment["SHELL"], access(shell, X_OK) == 0 { return shell }
        return "/bin/zsh"
    }

    /// "en_AU" and "en_AU@rg=auzzzz" become "en_AU.UTF-8" when macOS has that locale, and "en_US.UTF-8" if not.
    public static func language(for localeIdentifier: String, exists: (String) -> Bool) -> String {
        let base = localeIdentifier.split(separator: "@").first.map(String.init) ?? localeIdentifier
        let candidate = base.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
        return exists(candidate) ? candidate : "en_US.UTF-8"
    }
}
```

`Sources/CanopyCore/Terminal/TerminalIDs.swift` (new):

```swift
/// A pane's ID, such as `p12`. Agents see it as CANOPY_PANE.
public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "p\(number)" }
}

public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "t\(number)" }
}

/// The row a terminal belongs to.
public struct PaneContext: Sendable, Equatable {
    public var repoName: String
    public var repoPath: String
    public var rowName: String
    public var rowPath: String

    public init(row: Row, repoName: String) {
        self.repoName = repoName
        self.repoPath = row.repoPath
        self.rowName = row.displayName
        self.rowPath = row.path
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`
Expected: `Test run with 130 tests in 21 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Terminal Tests/CanopyCoreTests
git commit -m "feat: build terminal environments and setup scripts"
```

## Task 4: Panes and tabs per row

`Pane` joins a `PtyProcess` to an emulator and handles exit, restart, titles, and typing a command once the prompt is ready.
`TerminalStore` keeps every row's tabs, keyed by row path, and is the only place panes are created.
Tests run real bash processes against a fake emulator, with a private `HOME` so the runner's startup files never matter.

**Files:**
- Create: `Sources/CanopyCore/Terminal/TerminalEmulator.swift`
- Create: `Sources/CanopyCore/Terminal/Pane.swift`
- Create: `Sources/CanopyCore/Terminal/TerminalStore.swift`
- Create: `Tests/CanopyCoreTests/Support/FakeTerminal.swift`
- Test: `Tests/CanopyCoreTests/TerminalModelTests.swift`, `Tests/CanopyCoreTests/PaneTests.swift`, `Tests/CanopyCoreTests/TerminalStoreTests.swift`

**Interfaces:**
- Consumes: `PtyProcess`, `TerminalLaunch`, `ForegroundProcess`, `ShellSettings`, `PaneEnvironment`, `PaneContext`, `PaneID`, `TabID`.
- Produces:
  - `@MainActor protocol TerminalEmulator: AnyObject` with `size`, `onInput`, `onResize`, `onTitle`, `feed(_:)`.
  - `@MainActor protocol TerminalEngine` with `makeEmulator(size:) -> any TerminalEmulator`.
  - `PaneCommand.shell` and `PaneCommand.script(String)`.
  - `ProgramTitle`, `PaneTitle.resolve(_:foreground:)`, `TabNaming.next(after:)`, `BusyTerminals.quitWarning(_:)`.
  - `Pane` with `id`, `context`, `emulator`, `status` (`.running` or `.exited(Int32)`), `title`, `pid`, `foreground`, `isBusy`, `waitForExit()`, `run(_:timeout:)`, `restart()`, `close()`, `refreshTitle()`, and `Pane.closedExitCode` (129).
  - `TerminalTab` with `id`, `name`, `pane`.
  - `TerminalStore(engine:settings:)` with `tabsByRow`, `preferredSize`, `settings`, `tabs(inRow:)`, `selectedTab(inRow:)`, `panes`, `pane(_:)`, `busyPanes`, `busyPanes(inRow:)`, `openTab(for:name:command:) -> TerminalTab`, `ensureTab(for:)`, `selectTab(_:inRow:)`, `selectTab(offset:inRow:)`, `renameTab(_:inRow:to:)`, `closeTab(_:inRow:)`, `closePane(_:)`, `closeRow(path:)`, `closeAll()`.
  - Test support: `FakeEmulator` (`type(_:)`, `text`), `FakeEngine`, `Fixture.shellSettings(_:)`, `Fixture.terminals(_:)`, `Fixture.context(_:branch:repoPath:)`, `Pane.screen`, `processGroupEnded(_:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PaneTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PaneTests {
    @Test func shellStartsInTheRowWithItsEnvironment() async throws {
        let dir = try TempDir()
        let row = dir.sub("my row")
        try FileManager.default.createDirectory(atPath: row, withIntermediateDirectories: true)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(row)).pane
        await pane.run(#"printf 'ready:%s:%s:%s\n' "$CANOPY_PANE" "$CANOPY_ROW" "$(pwd -P)""#)

        #expect(await eventually { pane.screen.text.contains("ready:p1:feat/x:\(row)") })
    }

    @Test func runTypesCommandsVerbatim() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        await pane.run(#"printf '%s|%s\n' "it's" "héllo ✓ $CANOPY_ROW""#)

        #expect(await eventually { pane.screen.text.contains("it's|héllo ✓ feat/x") })
    }

    @Test func exitShowsItsCodeAndReturnRestarts() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        let firstShell = try #require(pane.pid)

        #expect(await eventually { pane.foreground?.name == "bash" })
        pane.refreshTitle()
        await pane.run("exit 3")
        #expect(await eventually { pane.status == .exited(3) })
        pane.refreshTitle()
        #expect(pane.title == "bash")
        #expect(pane.screen.text.hasSuffix("\u{1b}[?25l"))
        pane.screen.type("x")
        #expect(pane.status == .exited(3))
        pane.screen.type("\r")

        #expect(pane.status == .running)
        #expect(pane.pid != nil && pane.pid != firstShell)
        await pane.run("echo second-life")
        #expect(await eventually { pane.screen.text.contains("second-life\r\n") })
    }

    @Test func titleAndBusyFollowTheForegroundProgram() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        pane.screen.onTitle?("my title")
        #expect(pane.title == "my title")
        #expect(!pane.isBusy)

        await pane.run("sleep 30")
        #expect(
            await eventually {
                pane.refreshTitle()
                return pane.title == "sleep"
            })
        #expect(pane.isBusy)
    }

    @Test func closingEndsTheProcessAndWakesWaiters() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 30")).pane
        let group = try #require(pane.pid)
        let waiter = Task { await pane.waitForExit() }
        try await Task.sleep(for: .milliseconds(100))

        terminals.closePane(pane.id)

        #expect(await waiter.value == Pane.closedExitCode)
        #expect(await eventually { processGroupEnded(group) })
    }

    @Test func scriptReportsItsExitCode() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("echo working; exit 4")).pane

        #expect(await pane.waitForExit() == 4)
        #expect(pane.screen.text.contains("working"))
        #expect(pane.title == "bash")
    }

    @Test func missingFolderStartsInHome() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.sub("gone"))).pane
        await pane.run(#"echo "at:$(pwd -P)""#)

        #expect(await eventually { pane.screen.text.contains("at:\(dir.sub("user-home"))") })
    }
}
```

`Tests/CanopyCoreTests/Support/FakeTerminal.swift` (new):

```swift
import Foundation

@testable import CanopyCore

/// Records what a pane shows and stands in for the user at the keyboard.
@MainActor
final class FakeEmulator: TerminalEmulator {
    var size = TerminalSize.standard
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalSize) -> Void)?
    var onTitle: ((String) -> Void)?
    private(set) var shown = Data()

    var text: String { String(decoding: shown, as: UTF8.self) }

    func feed(_ data: Data) {
        shown.append(data)
    }

    func type(_ text: String) {
        onInput?(Data(text.utf8))
    }
}

struct FakeEngine: TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator {
        let emulator = FakeEmulator()
        emulator.size = size
        return emulator
    }
}

extension Fixture {
    /// Terminals run bash with a private HOME, so tests never depend on the login shell or startup files
    /// of whoever runs them.
    static func shellSettings(_ dir: TempDir) -> ShellSettings {
        let home = dir.sub("user-home")
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return ShellSettings(
            shell: "/bin/bash",
            baseEnvironment: ["HOME": home, "USER": NSUserName(), "BASH_SILENCE_DEPRECATION_WARNING": "1"],
            cliDirectory: nil,
            home: CanopyHome(path: dir.sub("home")),
            language: "en_US.UTF-8"
        )
    }

    @MainActor
    static func terminals(_ dir: TempDir) -> TerminalStore {
        TerminalStore(engine: FakeEngine(), settings: shellSettings(dir))
    }

    static func context(_ path: String, branch: String = "feat/x", repoPath: String = "/r/demo") -> PaneContext {
        PaneContext(
            row: Row(repoPath: repoPath, path: path, branch: branch, head: nil, rowClass: .canopy), repoName: "demo")
    }
}

extension Pane {
    var screen: FakeEmulator { emulator as! FakeEmulator }
}

/// True once no process is left in the group.
func processGroupEnded(_ group: pid_t) -> Bool {
    kill(-group, 0) == -1 && errno == ESRCH
}
```

`Tests/CanopyCoreTests/TerminalModelTests.swift` (new):

```swift
import Testing

@testable import CanopyCore

struct TerminalModelTests {
    @Test func tabNamesCountUpAndReuseGaps() {
        #expect(TabNaming.next(after: []) == "Terminal")
        #expect(TabNaming.next(after: ["Terminal"]) == "Terminal 2")
        #expect(TabNaming.next(after: ["Terminal", "Terminal 2", "Setup"]) == "Terminal 3")
        #expect(TabNaming.next(after: ["Terminal 2"]) == "Terminal")
        #expect(TabNaming.next(after: ["Terminal", "Terminal 3"]) == "Terminal 2")
    }

    @Test func programTitleHoldsWhileItsProgramIsInFront() {
        let claude = ForegroundProcess(pid: 20, name: "claude")
        let shell = ForegroundProcess(pid: 10, name: "zsh")
        let title = ProgramTitle(text: "✳ Claude Code", group: 20)

        #expect(PaneTitle.resolve(title, foreground: claude) == "✳ Claude Code")
        #expect(PaneTitle.resolve(title, foreground: shell) == "zsh")
        #expect(PaneTitle.resolve(nil, foreground: shell) == "zsh")
        #expect(PaneTitle.resolve(ProgramTitle(text: "", group: 10), foreground: shell) == "zsh")
        #expect(PaneTitle.resolve(title, foreground: nil) == "✳ Claude Code")
        #expect(PaneTitle.resolve(nil, foreground: nil) == "")
    }

    @Test func quitWarningCountsTerminalsAndNamesEachProgramOnce() {
        #expect(BusyTerminals.quitWarning(["claude"]) == "1 terminal is running a process: claude. Quitting stops it.")
        #expect(
            BusyTerminals.quitWarning(["claude", "bun", "claude"])
                == "3 terminals are running processes: claude, bun. Quitting stops them.")
    }
}
```

`Tests/CanopyCoreTests/TerminalStoreTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct TerminalStoreTests {
    @Test func rowOnScreenGetsExactlyOneTerminal() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        terminals.ensureTab(for: Fixture.context(dir.path))
        terminals.ensureTab(for: Fixture.context(dir.path))

        #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal"])
        #expect(terminals.selectedTab(inRow: dir.path)?.name == "Terminal")
    }

    @Test func missingRowGetsNoTerminal() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)

        terminals.ensureTab(for: Fixture.context(dir.sub("gone")))

        #expect(terminals.tabs(inRow: dir.sub("gone")).isEmpty)
    }

    @Test func newTabsAreNumberedAndPanesGetDistinctIDs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)

        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }
        terminals.closeTab(tabs[0].id, inRow: dir.path)
        terminals.openTab(for: context)

        #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal 2", "Terminal 3", "Terminal"])
        #expect(Set(terminals.panes.map(\.id)).count == 3)
        #expect(terminals.pane(tabs[1].pane.id) === tabs[1].pane)
    }

    @Test func closingTheSelectedTabSelectsItsRightNeighbor() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }

        terminals.selectTab(tabs[1].id, inRow: dir.path)
        terminals.closeTab(tabs[1].id, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)

        terminals.closeTab(tabs[2].id, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)

        terminals.closePane(tabs[0].pane.id)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(terminals.selectedTab(inRow: dir.path) == nil)
    }

    @Test func closingAnotherTabKeepsTheSelection() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }

        terminals.selectTab(tabs[2].id, inRow: dir.path)
        terminals.closeTab(tabs[0].id, inRow: dir.path)

        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)
    }

    @Test func tabSwitchingWrapsAround() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }

        terminals.selectTab(offset: 1, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)
        terminals.selectTab(offset: -1, inRow: dir.path)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[2].id)
    }

    @Test func renameTrimsAndIgnoresBlankNames() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let tab = terminals.openTab(for: Fixture.context(dir.path))

        terminals.renameTab(tab.id, inRow: dir.path, to: "  Server ")
        terminals.renameTab(tab.id, inRow: dir.path, to: "   ")

        #expect(tab.name == "Server")
    }

    @Test func closingARowEndsItsTerminalsOnly() async throws {
        let dir = try TempDir()
        let other = dir.sub("other")
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let groups = [
            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
        ].compactMap { $0 }
        let kept = terminals.openTab(for: Fixture.context(other)).pane

        terminals.closeRow(path: dir.path)

        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(await eventually { groups.allSatisfy(processGroupEnded) })
        #expect(kept.status == .running)
    }

    @Test func busyPanesAreThoseRunningAProgram() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let idle = terminals.openTab(for: Fixture.context(dir.path)).pane
        let busy = terminals.openTab(for: Fixture.context(dir.path)).pane

        await busy.run("sleep 30")

        #expect(await eventually { terminals.busyPanes.map(\.id) == [busy.id] })
        #expect(terminals.busyPanes(inRow: dir.path).map(\.id) == [busy.id])
        #expect(!idle.isBusy)
    }

    @Test func newTerminalsStartAtThePreferredSize() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        terminals.preferredSize = TerminalSize(columns: 150, rows: 45)

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane

        #expect(pane.emulator.size == TerminalSize(columns: 150, rows: 45))
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "TerminalModelTests|PaneTests|TerminalStoreTests"`
Expected: build failure, `cannot find type 'TerminalEmulator' in scope`.

- [ ] **Step 3: Implement**

A pane's first title is the name of the program it launched.
Reading the foreground process right after the fork can catch the child before `exec`, still named after Canopy.

`Sources/CanopyCore/Terminal/Pane.swift` (new):

```swift
import Foundation
import Observation

/// One terminal: a process in a pseudo-terminal, shown by an emulator.
@MainActor
@Observable
public final class Pane: Identifiable {
    public enum Status: Sendable, Equatable {
        case running
        case exited(Int32)
    }

    /// What `waitForExit` reports for a pane closed while its process ran, as for SIGHUP.
    public static let closedExitCode: Int32 = 129

    public let id: PaneID
    public let context: PaneContext
    public let emulator: any TerminalEmulator
    public private(set) var status = Status.running
    public private(set) var title = ""
    @ObservationIgnored private let settings: ShellSettings
    @ObservationIgnored private var process: PtyProcess?
    @ObservationIgnored private var programTitle: ProgramTitle?
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    @ObservationIgnored private var isClosed = false

    init(
        id: PaneID, context: PaneContext, command: PaneCommand, settings: ShellSettings,
        emulator: any TerminalEmulator
    ) {
        self.id = id
        self.context = context
        self.settings = settings
        self.emulator = emulator
        emulator.onInput = { [weak self] in self?.input($0) }
        emulator.onResize = { [weak self] in self?.process?.resize($0) }
        emulator.onTitle = { [weak self] in self?.setProgramTitle($0) }
        start(command)
    }

    /// The shell's pid while it runs.
    public var pid: pid_t? { process?.pid }

    public var foreground: ForegroundProcess? { process?.foreground }

    /// True while something other than the shell holds the terminal, such as `claude` or `bun dev`.
    public var isBusy: Bool {
        guard let process, let foreground = process.foreground else { return false }
        return foreground.pid != process.pid
    }

    /// Resolves to the exit code once the process exits. A pane closed first reports `closedExitCode`.
    public func waitForExit() async -> Int32 {
        if case .exited(let code) = status { return code }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Types `command` and Return once the shell's line editor is ready, so the shell does not echo it twice.
    /// Shells without a line editor never report ready, so it types anyway after `timeout`.
    public func run(_ command: String, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while let process, !process.isAtPrompt, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        process?.write(command + "\r")
    }

    /// Starts a new shell in the same folder after the last one exited.
    public func restart() {
        guard case .exited = status, !isClosed else { return }
        programTitle = nil
        // DECSTR undoes modes the last program left on, such as a hidden cursor, then start on a fresh line.
        emulator.feed(Data("\u{1b}[!p\r\n".utf8))
        start(.shell)
    }

    /// Ends the process for good.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        process?.terminate()
        if case .running = status {
            processExited(Self.closedExitCode)
        }
    }

    /// Reads the foreground process again. The app calls it while the pane is on screen.
    /// A pane whose process exited keeps its last title.
    public func refreshTitle() {
        guard let process else { return }
        let resolved = PaneTitle.resolve(programTitle, foreground: process.foreground)
        if !resolved.isEmpty {
            title = resolved
        }
    }

    /// The row's folder, or the home folder if the row's folder is gone.
    private var directory: String {
        FileManager.default.fileExists(atPath: context.rowPath)
            ? context.rowPath : settings.baseEnvironment["HOME"] ?? NSHomeDirectory()
    }

    private func start(_ command: PaneCommand) {
        let environment = PaneEnvironment.build(settings: settings, context: context, pane: id)
        let launch =
            switch command {
            case .shell: settings.interactiveShell(environment: environment, directory: directory)
            case .script(let script): settings.script(script, environment: environment, directory: directory)
            }
        do {
            process = try PtyProcess(
                launch, size: emulator.size,
                onOutput: { [weak self] in self?.emulator.feed($0) },
                onExit: { [weak self] in self?.processExited($0) }
            )
            status = .running
            // Name the pane after what was launched. Reading the foreground now could catch the child
            // between fork and exec, still named after Canopy.
            title = (launch.executable as NSString).lastPathComponent
        } catch {
            emulator.feed(Data("\(error)\r\n".utf8))
            processExited(127)
        }
    }

    private func input(_ data: Data) {
        switch status {
        case .running:
            process?.write(data)
        case .exited:
            if data == Data("\r".utf8) { restart() }
        }
    }

    private func setProgramTitle(_ text: String) {
        programTitle = ProgramTitle(text: text, group: process?.foreground?.pid)
        refreshTitle()
    }

    private func processExited(_ code: Int32) {
        process = nil
        status = .exited(code)
        // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
        emulator.feed(Data("\u{1b}[?25l".utf8))
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: code)
        }
    }
}
```

`Sources/CanopyCore/Terminal/TerminalEmulator.swift` (new):

```swift
import Foundation

/// The screen side of a terminal: it interprets what the process writes and draws it.
/// The app implements it with SwiftTerm.
@MainActor
public protocol TerminalEmulator: AnyObject {
    /// The size in cells the emulator shows.
    var size: TerminalSize { get }
    /// Called with what the user types or pastes.
    var onInput: ((Data) -> Void)? { get set }
    /// Called when the size in cells changes.
    var onResize: ((TerminalSize) -> Void)? { get set }
    /// Called when the running program sets the title.
    var onTitle: ((String) -> Void)? { get set }
    /// Shows what the process wrote.
    func feed(_ data: Data)
}

@MainActor
public protocol TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator
}

public enum PaneCommand: Sendable, Equatable {
    /// The user's interactive login shell.
    case shell
    /// A POSIX sh script, run by the user's shell. Setup and teardown use it.
    case script(String)
}

/// A title a program set, and the process group in the foreground when it set it.
public struct ProgramTitle: Sendable, Equatable {
    public var text: String
    public var group: pid_t?

    public init(text: String, group: pid_t?) {
        self.text = text
        self.group = group
    }
}

public enum PaneTitle {
    /// A program's title holds while the process group that set it is in the foreground, so a finished `claude`
    /// does not leave its title behind. Otherwise the foreground process names the pane.
    public static func resolve(_ title: ProgramTitle?, foreground: ForegroundProcess?) -> String {
        if let title, !title.text.isEmpty, foreground == nil || title.group == foreground?.pid {
            return title.text
        }
        return foreground?.name ?? ""
    }
}

public enum TabNaming {
    static let base = "Terminal"

    /// "Terminal", then "Terminal 2", "Terminal 3", and so on, skipping names the row's tabs already use.
    public static func next(after existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }
}

public enum BusyTerminals {
    /// For the quit confirmation, such as "3 terminals are running processes: claude, bun. Quitting stops them."
    public static func quitWarning(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) {
            unique.append(name)
        }
        let list = unique.joined(separator: ", ")
        return names.count == 1
            ? "1 terminal is running a process: \(list). Quitting stops it."
            : "\(names.count) terminals are running processes: \(list). Quitting stops them."
    }
}
```

`Sources/CanopyCore/Terminal/TerminalStore.swift` (new):

```swift
import Foundation
import Observation

@MainActor
@Observable
public final class TerminalTab: Identifiable {
    public let id: TabID
    public internal(set) var name: String
    /// A tab holds one pane until the grid arrives.
    public let pane: Pane

    init(id: TabID, name: String, pane: Pane) {
        self.id = id
        self.name = name
        self.pane = pane
    }
}

/// Every row's tabs and terminals. Terminals keep running while their row or tab is out of view.
@MainActor
@Observable
public final class TerminalStore {
    /// Each row's tabs in tab bar order, keyed by row path.
    public private(set) var tabsByRow: [String: [TerminalTab]] = [:]
    private var selectedTabByRow: [String: TabID] = [:]
    /// The size new terminals start at, so one opened in the background already fits the window.
    public var preferredSize = TerminalSize.standard
    @ObservationIgnored public let settings: ShellSettings
    @ObservationIgnored private let engine: any TerminalEngine
    @ObservationIgnored private var nextPane = 1
    @ObservationIgnored private var nextTab = 1

    public init(engine: any TerminalEngine, settings: ShellSettings) {
        self.engine = engine
        self.settings = settings
    }

    public func tabs(inRow path: String) -> [TerminalTab] {
        tabsByRow[path] ?? []
    }

    public func selectedTab(inRow path: String) -> TerminalTab? {
        let tabs = tabs(inRow: path)
        return tabs.first { $0.id == selectedTabByRow[path] } ?? tabs.first
    }

    public var panes: [Pane] {
        tabsByRow.values.flatMap { $0.map(\.pane) }
    }

    public func pane(_ id: PaneID) -> Pane? {
        panes.first { $0.id == id }
    }

    public var busyPanes: [Pane] {
        panes.filter(\.isBusy)
    }

    public func busyPanes(inRow path: String) -> [Pane] {
        tabs(inRow: path).map(\.pane).filter(\.isBusy)
    }

    /// Opens a tab with one pane at the end of the row's tab bar and selects it.
    @discardableResult
    public func openTab(for context: PaneContext, name: String? = nil, command: PaneCommand = .shell) -> TerminalTab {
        let tabs = tabs(inRow: context.rowPath)
        let pane = Pane(
            id: PaneID(nextPane), context: context, command: command, settings: settings,
            emulator: engine.makeEmulator(size: preferredSize))
        let tab = TerminalTab(id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.map(\.name)), pane: pane)
        nextPane += 1
        nextTab += 1
        tabsByRow[context.rowPath] = tabs + [tab]
        selectedTabByRow[context.rowPath] = tab.id
        return tab
    }

    /// A row on screen with no tabs gets one. A row whose folder is gone gets none, not a shell somewhere else.
    public func ensureTab(for context: PaneContext) {
        guard tabs(inRow: context.rowPath).isEmpty, FileManager.default.fileExists(atPath: context.rowPath) else {
            return
        }
        openTab(for: context)
    }

    public func selectTab(_ id: TabID, inRow path: String) {
        guard tabs(inRow: path).contains(where: { $0.id == id }) else { return }
        selectedTabByRow[path] = id
    }

    /// Moves the selection by `offset` tabs, wrapping around at the ends.
    public func selectTab(offset: Int, inRow path: String) {
        let tabs = tabs(inRow: path)
        guard let current = selectedTab(inRow: path), let index = tabs.firstIndex(where: { $0.id == current.id })
        else { return }
        let count = tabs.count
        selectedTabByRow[path] = tabs[((index + offset) % count + count) % count].id
    }

    public func renameTab(_ id: TabID, inRow path: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }) else { return }
        tab.name = trimmed
    }

    /// Closes a tab and its terminal. If it was selected, the tab to its right takes over, or else the new last tab.
    public func closeTab(_ id: TabID, inRow path: String) {
        var tabs = tabs(inRow: path)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab(inRow: path)?.id == id
        tabs.remove(at: index).pane.close()
        tabsByRow[path] = tabs.isEmpty ? nil : tabs
        if tabs.isEmpty {
            selectedTabByRow[path] = nil
        } else if wasSelected {
            selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Closing a tab's last pane closes the tab. Every tab holds one pane until the grid arrives.
    public func closePane(_ id: PaneID) {
        for (path, tabs) in tabsByRow {
            if let tab = tabs.first(where: { $0.pane.id == id }) {
                closeTab(tab.id, inRow: path)
                return
            }
        }
    }

    public func closeRow(path: String) {
        for tab in tabs(inRow: path) {
            tab.pane.close()
        }
        tabsByRow[path] = nil
        selectedTabByRow[path] = nil
    }

    public func closeAll() {
        for path in Array(tabsByRow.keys) {
            closeRow(path: path)
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times.
Expected: `Test run with 150 tests in 24 suites passed` every time, and `pgrep -fl "sleep 30"` prints nothing afterwards.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Terminal Tests/CanopyCoreTests
git commit -m "feat: model panes and tabs per row"
```

## Task 5: Setup and teardown in terminal tabs

`RowLifecycle` is where a row's terminals meet its git lifecycle.
`prepare` opens the row's first tab before it returns, so a caller that selects the row next never also gets a blank terminal.
Configs are read from the row's own checkout, so each branch runs the commands it commits.

**Files:**
- Create: `Sources/CanopyCore/Rows/RepoConfig.swift`
- Create: `Sources/CanopyCore/Rows/RowLifecycle.swift`
- Modify: `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/RowSetupTests.swift`, `Tests/CanopyCoreTests/TerminalModelTests.swift`

**Interfaces:**
- Consumes: `Workspace` (with `hasUncommittedChanges`), `TerminalStore`, `Pane`, `SetupScript`, `PaneContext`.
- Produces:
  - `WorkspaceError.badConfig(String, reason: String)` (code `bad_config`) and `WorkspaceError.teardownFailed(Int32)` (code `teardown_failed`).
  - `RepoConfig(setup:teardown:)`, `RepoConfig.load(from:) throws -> RepoConfig`.
  - `SetupReport(status:exitCode:message:)` with `Status` `none`, `skipped`, `succeeded`, `failed`. It is `Codable` for the control API.
  - `RowPreparation(setup: SetupReport, pane: PaneID?)`.
  - `@MainActor final class RowLifecycle(workspace:terminals:)` with `prepare(_ row: Row, repoName: String, setup: Bool, run: String?) -> Task<RowPreparation, Never>` and `remove(_ row: Row, repoName: String, force: Bool, deleteBranch: Bool) async throws`.

- [ ] **Step 1: Write the failing tests**

The fixture commits `.canopy/config.json` on `main` of a repo without an origin, so rows branch from it and start clean.
Commands write their evidence one folder up, next to the repo, so rows stay clean for removal.

`Tests/CanopyCoreTests/RowSetupTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct RowSetupTests {
    /// A repo whose main branch commits `config` as `.canopy/config.json`, so new rows get it and start clean.
    /// Commands write to the folder above the repo, `dir`, to keep rows clean for removal.
    func setUp(_ dir: TempDir, config: String?, name: String = "demo") async throws -> (String, RowLifecycle) {
        let repo = try await Fixture.repo(in: dir, name: name)
        if let config {
            try FileManager.default.createDirectory(atPath: repo + "/.canopy", withIntermediateDirectories: true)
            try config.write(toFile: repo + "/.canopy/config.json", atomically: true, encoding: .utf8)
            try await Fixture.git.run(["add", ".canopy"], in: repo)
            try await Fixture.git.run(["commit", "--quiet", "-m", "config"], in: repo)
        }
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (repo, RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)))
    }

    func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    @Test func setupRunsInTheRowWithItsVariablesThenLeavesATerminal() async throws {
        let dir = try TempDir()
        let config = #"""
            {"setup": ["printf '%s|%s|%s|%s|%s' \"$CANOPY_ROOT_PATH\" \"$CANOPY_ROW_PATH\" \"$CANOPY_REPO\" \"$CANOPY_ROW\" \"$(pwd -P)\" > \"$CANOPY_ROOT_PATH/../setup.out\""]}
            """#
        let (repo, rows) = try await setUp(dir, config: config, name: "my repo")
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/setup").row

        let ready = await rows.prepare(row, repoName: "my repo", setup: true, run: nil).value

        #expect(ready.setup == SetupReport(status: .succeeded, exitCode: 0))
        #expect(read(dir.sub("setup.out")) == "\(repo)|\(row.path)|my repo|feat/setup|\(row.path)")
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Terminal"])
    }

    @Test func setupTabOpensBeforePrepareReturns() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["sleep 0.5"]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/slow").row

        let task = rows.prepare(row, repoName: "demo", setup: true, run: nil)

        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Setup"])
        #expect(await task.value.setup.status == .succeeded)
    }

    @Test func failedSetupStaysOpenAndSkipsRun() async throws {
        let dir = try TempDir()
        let config = #"{"setup": ["exit 5", "touch \"$CANOPY_ROOT_PATH/../never\""]}"#
        let (repo, rows) = try await setUp(dir, config: config)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/broken").row

        let ready = await rows.prepare(row, repoName: "demo", setup: true, run: "touch ran").value

        #expect(ready.setup.status == .failed)
        #expect(ready.setup.exitCode == 5)
        #expect(ready.setup.message?.contains("Setup tab") == true)
        #expect(ready.pane == nil)
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Setup"])
        #expect(!FileManager.default.fileExists(atPath: dir.sub("never")))
        #expect(await rows.workspace.snapshot.row(path: row.path) != nil)
    }

    @Test func runStartsOnceSetupSucceeds() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["true"]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/run").row

        let ready = await rows.prepare(
            row, repoName: "demo", setup: true, run: #"echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran""#
        ).value

        let pane = try #require(ready.pane)
        #expect(await eventually { read(dir.sub("ran")) == "\(pane)\n" })
        #expect(rows.terminals.tabs(inRow: row.path).map(\.pane.id) == [pane])
    }

    @Test func runStartsAtOnceWithoutSetupCommands() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/plain").row

        let task = rows.prepare(row, repoName: "demo", setup: true, run: "echo hi")

        #expect(rows.terminals.tabs(inRow: row.path).count == 1)
        let ready = await task.value
        #expect(ready.setup.status == .none)
        #expect(ready.pane == rows.terminals.tabs(inRow: row.path).first?.pane.id)
    }

    @Test func setupCanBeSkipped() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["touch \"$CANOPY_ROOT_PATH/../ran\""]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/skip").row

        let ready = await rows.prepare(row, repoName: "demo", setup: false, run: nil).value

        #expect(ready.setup.status == .skipped)
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.sub("ran")))
    }

    @Test func unreadableConfigFailsSetupAndSaysWhere() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": "bun install"}"#)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/bad").row

        let ready = await rows.prepare(row, repoName: "demo", setup: true, run: "echo hi").value

        #expect(ready.setup.status == .failed)
        #expect(ready.setup.message?.contains(".canopy/config.json") == true)
        #expect(ready.setup.message?.contains("setup") == true)
        #expect(ready.pane == nil)
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }

    @Test func closingTheSetupTabStopsSetup() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["sleep 30"]}"#)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/stop").row
        let task = rows.prepare(row, repoName: "demo", setup: true, run: nil)

        let setupTab = try #require(rows.terminals.tabs(inRow: row.path).first)
        rows.terminals.closeTab(setupTab.id, inRow: row.path)

        let ready = await task.value
        #expect(ready.setup.status == .failed)
        #expect(ready.setup.message == "Setup stopped because its tab was closed.")
    }

    @Test func parallelRunsGetTheirOwnPanes() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }
        let workspace = rows.workspace
        async let first = workspace.createRow(repoPath: repo, branch: "agent/one")
        async let second = workspace.createRow(repoPath: repo, branch: "agent/two")
        async let third = workspace.createRow(repoPath: repo, branch: "agent/three")
        let created = try await [first, second, third].map(\.row)

        let tasks = created.map { row in
            rows.prepare(
                row, repoName: "demo", setup: true,
                run: #"echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../$(basename "$CANOPY_ROW").out""#)
        }
        var panes: [PaneID] = []
        for task in tasks {
            panes.append(try #require(await task.value.pane))
        }

        #expect(Set(panes).count == 3)
        for (row, pane) in zip(created, panes) {
            let file = dir.sub((row.branch! as NSString).lastPathComponent + ".out")
            #expect(await eventually { read(file) == "\(pane)\n" })
        }
    }

    @Test func teardownRunsThenTheRowGoes() async throws {
        let dir = try TempDir()
        let config = #"{"teardown": ["echo \"$CANOPY_ROW\" > \"$CANOPY_ROOT_PATH/../teardown.out\""]}"#
        let (repo, rows) = try await setUp(dir, config: config)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/done").row
        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).pane.pid)

        try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)

        #expect(read(dir.sub("teardown.out")) == "feat/done\n")
        #expect(!FileManager.default.fileExists(atPath: row.path))
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
        #expect(await eventually { processGroupEnded(shell) })
    }

    @Test func failedTeardownKeepsTheRowUnlessForced() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["exit 6"]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/stuck").row

        await #expect(throws: WorkspaceError.teardownFailed(6)) {
            try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: row.path))
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Teardown"])

        try await rows.remove(row, repoName: "demo", force: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: row.path))
    }

    @Test func uncommittedChangesStopRemovalBeforeTeardown() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["touch \"$CANOPY_ROOT_PATH/../torn\""]}"#)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/dirty").row
        try "x".write(toFile: row.path + "/new.txt", atomically: true, encoding: .utf8)

        await #expect(throws: WorkspaceError.worktreeDirty(row.path)) {
            try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.sub("torn")))
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }

    @Test func removingAMissingRowSkipsTeardown() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["exit 1"]}"#)
        let created = try await rows.workspace.createRow(repoPath: repo, branch: "feat/gone").row
        try FileManager.default.removeItem(atPath: created.path)
        await rows.workspace.refresh(repoPath: repo)
        let row = try #require(await rows.workspace.snapshot.row(path: created.path))
        #expect(row.isMissing)

        try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)

        #expect(await rows.workspace.snapshot.row(path: created.path) == nil)
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }

    @Test func removingAnAdoptedRowClosesItsTerminalsAndKeepsItsFiles() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["exit 1"]}"#)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        let row = try await rows.workspace.adopt(path: dir.sub("theirs"))
        rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo"))

        try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)

        #expect(FileManager.default.fileExists(atPath: dir.sub("theirs")))
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }
}
```

`Tests/CanopyCoreTests/TerminalModelTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/TerminalModelTests.swift
+++ b/Tests/CanopyCoreTests/TerminalModelTests.swift
@@ -1,3 +1,4 @@
+import Foundation
 import Testing
 
 @testable import CanopyCore
@@ -31,3 +32,33 @@ struct TerminalModelTests {
                 == "3 terminals are running processes: claude, bun. Quitting stops them.")
     }
 }
+
+struct RepoConfigTests {
+    @Test func readsCommandsAndDefaultsMissingOnes() throws {
+        let dir = try TempDir()
+        try FileManager.default.createDirectory(atPath: dir.sub(".canopy"), withIntermediateDirectories: true)
+        try #"{"setup": ["bun install"], "other": true}"#.write(
+            toFile: dir.sub(".canopy/config.json"), atomically: true, encoding: .utf8)
+
+        #expect(try RepoConfig.load(from: dir.path) == RepoConfig(setup: ["bun install"], teardown: []))
+        #expect(try RepoConfig.load(from: dir.sub("nowhere")) == RepoConfig())
+    }
+
+    @Test func explainsWhatIsWrong() throws {
+        let dir = try TempDir()
+        try FileManager.default.createDirectory(atPath: dir.sub(".canopy"), withIntermediateDirectories: true)
+        let path = dir.sub(".canopy/config.json")
+
+        try "{".write(toFile: path, atomically: true, encoding: .utf8)
+        #expect(throws: WorkspaceError.self) { try RepoConfig.load(from: dir.path) }
+
+        try #"{"teardown": [1]}"#.write(toFile: path, atomically: true, encoding: .utf8)
+        do {
+            _ = try RepoConfig.load(from: dir.path)
+            Issue.record("expected an error")
+        } catch let error as WorkspaceError {
+            #expect(error.code == "bad_config")
+            #expect(error.message.hasPrefix("Could not read \(path): teardown.0:"))
+        }
+    }
+}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "RowSetupTests|RepoConfigTests"`
Expected: build failure, `cannot find type 'RowLifecycle' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Rows/RepoConfig.swift` (new):

```swift
import Foundation

/// Commands a repo commits in `.canopy/config.json` to prepare a new row and to clean one up.
public struct RepoConfig: Codable, Sendable, Equatable {
    public static let relativePath = ".canopy/config.json"

    public var setup: [String]
    public var teardown: [String]

    public init(setup: [String] = [], teardown: [String] = []) {
        self.setup = setup
        self.teardown = teardown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setup = try container.decodeIfPresent([String].self, forKey: .setup) ?? []
        teardown = try container.decodeIfPresent([String].self, forKey: .teardown) ?? []
    }

    /// Reads the row's own checkout, so each branch runs the commands it commits. No file means nothing to run.
    public static func load(from folder: String) throws -> RepoConfig {
        let path = (folder as NSString).appendingPathComponent(relativePath)
        guard let data = FileManager.default.contents(atPath: path) else { return RepoConfig() }
        do {
            return try JSONDecoder().decode(RepoConfig.self, from: data)
        } catch {
            throw WorkspaceError.badConfig(path, reason: reason(error))
        }
    }

    static func reason(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
            .dataCorrupted(let context):
            let field = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return field.isEmpty ? context.debugDescription : "\(field): \(context.debugDescription)"
        default:
            return "\(error)"
        }
    }
}
```

`Sources/CanopyCore/Rows/RowLifecycle.swift` (new):

```swift
import Foundation

/// How setup went for a new row.
public struct SetupReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The row's checkout has no setup commands.
        case none
        /// Setup was turned off, as with `--no-setup`.
        case skipped
        case succeeded
        case failed
    }

    public var status: Status
    public var exitCode: Int32?
    public var message: String?

    public init(status: Status, exitCode: Int32? = nil, message: String? = nil) {
        self.status = status
        self.exitCode = exitCode
        self.message = message
    }
}

/// A new row, ready: its setup outcome and the pane started for `--run`.
public struct RowPreparation: Sendable, Equatable {
    public var setup: SetupReport
    public var pane: PaneID?

    public init(setup: SetupReport, pane: PaneID? = nil) {
        self.setup = setup
        self.pane = pane
    }
}

/// The parts of creating and removing a row that involve its terminals: setup runs in a visible tab before the
/// row is used, and teardown runs in one before it goes. The UI and the control API both come through here.
@MainActor
public final class RowLifecycle {
    public nonisolated let workspace: Workspace
    public let terminals: TerminalStore

    public init(workspace: Workspace, terminals: TerminalStore) {
        self.workspace = workspace
        self.terminals = terminals
    }

    /// Opens the new row's first tab before returning, either Setup or the `run` command, so a caller that selects
    /// the row next does not also get a blank terminal. The task ends when setup has and `run` has been typed.
    /// A successful Setup tab closes, leaving the `run` pane or a plain terminal. A failed one stays open.
    public func prepare(_ row: Row, repoName: String, setup: Bool, run: String?) -> Task<RowPreparation, Never> {
        let context = PaneContext(row: row, repoName: repoName)
        let commands: [String]
        do {
            commands = setup ? try RepoConfig.load(from: row.path).setup : []
        } catch {
            let report = SetupReport(status: .failed, message: (error as? WorkspaceError)?.message ?? "\(error)")
            return Task { RowPreparation(setup: report) }
        }

        guard !commands.isEmpty else {
            let pane = run.map { _ in terminals.openTab(for: context).pane }
            let report = SetupReport(status: setup ? .none : .skipped)
            return Task {
                if let pane, let run { await pane.run(run) }
                return RowPreparation(setup: report, pane: pane?.id)
            }
        }

        let script = SetupScript.render(commands, label: "Setup")
        let tab = terminals.openTab(for: context, name: "Setup", command: .script(script))
        return Task {
            let code = await tab.pane.waitForExit()
            guard code == 0 else {
                let closed = !terminals.tabs(inRow: row.path).contains { $0.id == tab.id }
                let message =
                    closed
                    ? "Setup stopped because its tab was closed."
                    : "Setup failed with exit code \(code). The Setup tab in \(context.rowName) shows why."
                return RowPreparation(setup: SetupReport(status: .failed, exitCode: code, message: message))
            }
            var pane: Pane?
            if run != nil {
                pane = terminals.openTab(for: context).pane
            } else if terminals.tabs(inRow: row.path).count == 1 {
                terminals.openTab(for: context)
            }
            terminals.closeTab(tab.id, inRow: row.path)
            if let pane, let run { await pane.run(run) }
            return RowPreparation(setup: SetupReport(status: .succeeded, exitCode: 0), pane: pane?.id)
        }
    }

    /// Removes a Canopy row once its teardown commands succeed, or un-adopts an adopted row. The row's terminals
    /// close first. With `force`, neither uncommitted changes nor a failing teardown stop the removal.
    public func remove(_ row: Row, repoName: String, force: Bool, deleteBranch: Bool) async throws {
        switch row.rowClass {
        case .main:
            throw WorkspaceError.cannotRemoveMain
        case .external:
            throw WorkspaceError.notManaged(row.path)
        case .adopted:
            break
        case .canopy:
            // A row whose folder is gone has no checkout to tear down.
            if !row.isMissing {
                // Checked first, so a removal that would be refused anyway does not run teardown.
                if !force, try await workspace.hasUncommittedChanges(path: row.path) {
                    throw WorkspaceError.worktreeDirty(row.path)
                }
                try await tearDown(row, repoName: repoName, force: force)
            }
        }
        terminals.closeRow(path: row.path)
        try await workspace.removeRow(path: row.path, force: force, deleteBranch: deleteBranch)
    }

    private func tearDown(_ row: Row, repoName: String, force: Bool) async throws {
        let commands: [String]
        do {
            commands = try RepoConfig.load(from: row.path).teardown
        } catch  where force {
            return
        }
        guard !commands.isEmpty else { return }
        let script = SetupScript.render(commands, label: "Teardown")
        let tab = terminals.openTab(
            for: PaneContext(row: row, repoName: repoName), name: "Teardown", command: .script(script))
        let code = await tab.pane.waitForExit()
        if code != 0 && !force {
            throw WorkspaceError.teardownFailed(code)
        }
    }
}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/WorkspaceError.swift
+++ b/Sources/CanopyCore/Workspace/WorkspaceError.swift
@@ -14,6 +14,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case worktreeDirty(String)
     case cannotRemoveMain
     case notManaged(String)
+    case badConfig(String, reason: String)
+    case teardownFailed(Int32)
     case git(GitError)
 
     public var code: String {
@@ -33,6 +35,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .worktreeDirty: "worktree_dirty"
         case .cannotRemoveMain: "cannot_remove_main"
         case .notManaged: "not_managed"
+        case .badConfig: "bad_config"
+        case .teardownFailed: "teardown_failed"
         case .git: "git_failed"
         }
     }
@@ -55,6 +59,9 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
         case .cannotRemoveMain: "The main checkout cannot be removed."
         case .notManaged(let path): "\(path) belongs to another tool. Adopt it first."
+        case .badConfig(let path, let reason): "Could not read \(path): \(reason)"
+        case .teardownFailed(let code):
+            "Teardown failed with exit code \(code). Its tab shows why. Pass --force to remove the row anyway."
         case .git(let error): error.description
         }
     }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times.
Expected: `Test run with 166 tests in 26 suites passed` every time.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: run repo setup and teardown in terminal tabs"
```

## Task 6: Show a row's terminal in the window

SwiftTerm's `TerminalView` becomes a `TerminalEmulator`.
The terminal view belongs to its pane and moves between containers, so switching rows keeps every screen and process alive.
Selecting a row opens its first terminal, and the sidebar's create and remove actions go through `RowLifecycle`.

**Files:**
- Modify: `Package.swift` (and the resolved SwiftTerm pin in `Package.resolved`)
- Create: `Sources/CanopyApp/Terminal/SwiftTermEmulator.swift`
- Create: `Sources/CanopyApp/Terminal/TerminalSurface.swift`
- Create: `Sources/CanopyApp/Terminal/PaneView.swift`
- Create: `Sources/CanopyApp/Terminal/RowTerminalsView.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/Sidebar/RowActionViews.swift`

**Interfaces:**
- Consumes: `TerminalEmulator`, `TerminalEngine`, `TerminalStore`, `RowLifecycle`, `Pane`, `PaneContext`.
- Produces:
  - `SwiftTermEmulator(size:)` with `view: NSView`, `background: NSColor`, `applyAppearance(_:)`, and `SwiftTermEngine`.
  - `TerminalSurface(pane:onFocusChange:onSizeChange:)` and `TerminalContainerView`.
  - `PaneView(pane:onClose:onSizeChange:)`, `PaneHeader`, `ExitStrip`, `RowTerminalsView(row:)`.
  - `AppModel.terminals`, `AppModel.rows`, `AppModel.select(_:) async`, `AppModel.context(for:)`, `AppModel.newTab()`, `AppModel.closePane(_:)`, and `RemoveOutcome.teardownFailed(Int32)`.

- [ ] **Step 1: Write the changes**

The container gives the terminal 8 points of padding on the left and 4 elsewhere, and paints the padding in the terminal's background color, which follows the system appearance.
A terminal that comes into view takes the keyboard.

`Package.swift` (modify):

```diff
--- a/Package.swift
+++ b/Package.swift
@@ -9,12 +9,16 @@ let package = Package(
         .executable(name: "canopy", targets: ["CanopyCLI"]),
     ],
     dependencies: [
-        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
+        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
+        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
     ],
     targets: [
         .target(name: "CPty"),
         .target(name: "CanopyCore", dependencies: ["CPty"]),
-        .executableTarget(name: "CanopyApp", dependencies: ["CanopyCore"]),
+        .executableTarget(
+            name: "CanopyApp",
+            dependencies: ["CanopyCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
+        ),
         .executableTarget(
             name: "CanopyCLI",
             dependencies: [
```

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -8,6 +8,8 @@ import Observation
 final class AppModel {
     let home: CanopyHome
     let workspace: Workspace
+    let terminals: TerminalStore
+    let rows: RowLifecycle
     private(set) var snapshot = WorkspaceSnapshot()
     private(set) var toast: String?
     var selectedRowPath: String? {
@@ -21,7 +23,20 @@ final class AppModel {
 
     init(home: CanopyHome) {
         self.home = home
-        self.workspace = Workspace(home: home)
+        let workspace = Workspace(home: home)
+        let terminals = TerminalStore(
+            engine: SwiftTermEngine(), settings: .current(home: home, cliDirectory: Self.bundledCLIDirectory()))
+        self.workspace = workspace
+        self.terminals = terminals
+        self.rows = RowLifecycle(workspace: workspace, terminals: terminals)
+    }
+
+    /// The bundle's folder holding `canopy`, which terminals get on their PATH.
+    private static func bundledCLIDirectory() -> String? {
+        guard let bin = Bundle.main.resourceURL?.appending(path: "bin"),
+            FileManager.default.isExecutableFile(atPath: bin.appending(path: "canopy").path)
+        else { return nil }
+        return bin.path
     }
 
     var selectedRow: Row? {
@@ -56,10 +71,11 @@ final class AppModel {
     func shutdown() {
         server?.stop()
         server = nil
+        terminals.closeAll()
     }
 
     private func startControlServer() async {
-        let bridge = AppUIBridge { [weak self] path in self?.selectedRowPath = path }
+        let bridge = AppUIBridge { [weak self] path in await self?.select(path) }
         let handler = WorkspaceControlHandler(workspace: workspace, ui: bridge)
         let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
         do {
@@ -95,14 +111,27 @@ final class AppModel {
         Task { await workspace.refreshAll() }
     }
 
-    /// Creates a row and selects it. Returns an error message for the sheet to show, or nil.
+    /// Selects a row once the snapshot has it, so a row created a moment ago gets its terminal.
+    func select(_ path: String) async {
+        apply(await workspace.snapshot)
+        selectedRowPath = path
+    }
+
+    /// Creates a row, starts its setup, and selects it. Returns an error message for the sheet to show, or nil.
     func createRow(in repo: RepoSnapshot, branch: String, base: String?) async -> String? {
         do {
             let created = try await workspace.createRow(repoPath: repo.path, branch: branch, base: base)
-            selectedRowPath = created.row.path
+            let preparing = rows.prepare(created.row, repoName: repo.name, setup: true, run: nil)
+            await select(created.row.path)
             if let warning = created.warnings.first {
                 show(warning)
             }
+            Task {
+                let ready = await preparing.value
+                if ready.setup.status == .failed, let message = ready.setup.message {
+                    show(message)
+                }
+            }
             return nil
         } catch {
             return (error as? WorkspaceError)?.message ?? "\(error)"
@@ -112,20 +141,39 @@ final class AppModel {
     enum RemoveOutcome {
         case removed
         case dirty
+        case teardownFailed(Int32)
         case failed(String)
     }
 
     func removeRow(_ row: Row, force: Bool, deleteBranch: Bool) async -> RemoveOutcome {
         do {
-            try await workspace.removeRow(path: row.path, force: force, deleteBranch: deleteBranch)
+            let repoName = snapshot.repo(path: row.repoPath)?.name ?? ""
+            try await rows.remove(row, repoName: repoName, force: force, deleteBranch: deleteBranch)
             return .removed
         } catch WorkspaceError.worktreeDirty {
             return .dirty
+        } catch WorkspaceError.teardownFailed(let code) {
+            return .teardownFailed(code)
         } catch {
             return .failed((error as? WorkspaceError)?.message ?? "\(error)")
         }
     }
 
+    // MARK: Terminals
+
+    func context(for row: Row) -> PaneContext {
+        PaneContext(row: row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "")
+    }
+
+    func newTab() {
+        guard let row = selectedRow, !row.isMissing else { return }
+        terminals.openTab(for: context(for: row))
+    }
+
+    func closePane(_ pane: Pane) {
+        terminals.closePane(pane.id)
+    }
+
     // MARK: Repos
 
     func addRepo(_ url: URL) {
@@ -161,6 +209,10 @@ final class AppModel {
             perform { _ = try await $0.adopt(path: path) }
         }
         perform { try await $0.setSelectedRow(path: path) }
+        // Selecting a row with no tabs opens one. A row whose tabs were all closed stays empty until then.
+        if let row = selectedRow {
+            terminals.ensureTab(for: context(for: row))
+        }
     }
 
     func perform(_ action: @escaping @Sendable (Workspace) async throws -> Void) {
@@ -189,7 +241,7 @@ final class AppModel {
 }
 
 struct AppUIBridge: ControlUIBridge {
-    let select: @MainActor @Sendable (String) -> Void
+    let select: @MainActor @Sendable (String) async -> Void
 
     func selectRow(path: String) async {
         await select(path)
```

`Sources/CanopyApp/RootView.swift` (modify):

```diff
--- a/Sources/CanopyApp/RootView.swift
+++ b/Sources/CanopyApp/RootView.swift
@@ -36,20 +36,9 @@ struct RowDetailView: View {
 
     var body: some View {
         if let row = model.selectedRow {
-            VStack(alignment: .leading, spacing: 6) {
-                Label {
-                    Text(row.displayName)
-                } icon: {
-                    BranchIcon()
-                }
-                .font(.title2)
-                Text(row.path)
-                    .font(.callout.monospaced())
-                    .foregroundStyle(.secondary)
-                    .textSelection(.enabled)
-            }
-            .frame(maxWidth: .infinity, maxHeight: .infinity)
-            .navigationTitle(row.displayName)
+            RowTerminalsView(row: row)
+                .navigationTitle(row.displayName)
+                .navigationSubtitle(model.snapshot.repo(path: row.repoPath)?.name ?? "")
         } else {
             ContentUnavailableView(
                 "No Row Selected",
```

`Sources/CanopyApp/Sidebar/RowActionViews.swift` (modify):

```diff
--- a/Sources/CanopyApp/Sidebar/RowActionViews.swift
+++ b/Sources/CanopyApp/Sidebar/RowActionViews.swift
@@ -66,6 +66,7 @@ struct RemoveRowPopover: View {
     @Binding var isPresented: Bool
     @State private var deleteBranch = false
     @State private var isDirty = false
+    @State private var teardownCode: Int32?
     @State private var isWorking = false
     @State private var error: String?
 
@@ -90,6 +91,14 @@ struct RemoveRowPopover: View {
                 Label("It has uncommitted changes.", systemImage: "exclamationmark.triangle.fill")
                     .foregroundStyle(.orange)
             }
+            if let teardownCode {
+                Label(
+                    "Teardown failed with exit code \(teardownCode). Its tab shows why.",
+                    systemImage: "exclamationmark.triangle.fill"
+                )
+                .foregroundStyle(.orange)
+                .fixedSize(horizontal: false, vertical: true)
+            }
             if let error {
                 Text(error)
                     .font(.callout)
@@ -100,7 +109,7 @@ struct RemoveRowPopover: View {
                 Spacer()
                 Button("Cancel") { isPresented = false }
                     .keyboardShortcut(.cancelAction)
-                Button(isDirty ? "Force Remove" : isAdopted ? "Hide" : "Remove", role: .destructive, action: remove)
+                Button(buttonTitle, role: .destructive, action: remove)
                     .keyboardShortcut(.defaultAction)
                     .disabled(isWorking)
             }
@@ -109,13 +118,19 @@ struct RemoveRowPopover: View {
         .frame(width: 300)
     }
 
+    private var buttonTitle: String {
+        if isDirty || teardownCode != nil { return "Remove Anyway" }
+        return isAdopted ? "Hide" : "Remove"
+    }
+
     private func remove() {
         isWorking = true
         error = nil
         Task {
-            switch await model.removeRow(row, force: isDirty, deleteBranch: deleteBranch) {
+            switch await model.removeRow(row, force: isDirty || teardownCode != nil, deleteBranch: deleteBranch) {
             case .removed: isPresented = false
             case .dirty: isDirty = true
+            case .teardownFailed(let code): teardownCode = code
             case .failed(let message): error = message
             }
             isWorking = false
```

`Sources/CanopyApp/Terminal/PaneView.swift` (new):

```swift
import CanopyCore
import SwiftUI

/// One terminal with its header, and a strip below it once its shell has exited.
struct PaneView: View {
    let pane: Pane
    let onClose: () -> Void
    var onSizeChange: (TerminalSize) -> Void = { _ in }
    @State private var isFocused = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: pane.title, isFocused: isFocused, onClose: onClose)
            TerminalSurface(pane: pane, onFocusChange: { isFocused = $0 }, onSizeChange: onSizeChange)
            if case .exited(let code) = pane.status {
                ExitStrip(code: code)
            }
        }
        .task(id: pane.id) {
            // Titles fall back to the foreground program, which changes without any event to watch.
            while !Task.isCancelled {
                pane.refreshTitle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct PaneHeader: View {
    let title: String
    let isFocused: Bool
    let onClose: () -> Void
    @Environment(\.controlActiveState) private var activeState

    private var isHighlighted: Bool { isFocused && activeState == .key }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.isEmpty ? "Terminal" : title)
                .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close Terminal (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

struct ExitStrip: View {
    let code: Int32

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(code == 0 ? .green : .red)
            Text("exited (code \(code))")
                .fontWeight(.medium)
            Text("Return restarts the shell. ⌘W closes the terminal.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}
```

`Sources/CanopyApp/Terminal/RowTerminalsView.swift` (new):

```swift
import CanopyCore
import SwiftUI

/// The detail area for a row: its selected tab's terminal.
struct RowTerminalsView: View {
    @Environment(AppModel.self) private var model
    let row: Row

    var body: some View {
        if row.isMissing {
            ContentUnavailableView {
                Label("Worktree Missing", systemImage: "folder.badge.questionmark")
            } description: {
                Text("\(row.path) no longer exists.")
            } actions: {
                if let repo = model.snapshot.repo(path: row.repoPath) {
                    Button("Prune Missing Worktrees") { model.prune(repo) }
                }
            }
        } else if let tab = model.terminals.selectedTab(inRow: row.path) {
            PaneView(
                pane: tab.pane,
                onClose: { model.closePane(tab.pane) },
                onSizeChange: { model.terminals.preferredSize = $0 }
            )
            .id(tab.pane.id)
        } else {
            ContentUnavailableView {
                Label("No Terminals", systemImage: "apple.terminal")
            } description: {
                Text("Open one to work in \(row.displayName).")
            } actions: {
                Button("New Terminal") { model.newTab() }
            }
        }
    }
}
```

`Sources/CanopyApp/Terminal/SwiftTermEmulator.swift` (new):

```swift
import AppKit
import CanopyCore
import SwiftTerm

/// SwiftTerm behind Canopy's emulator interface. Nothing else in Canopy imports SwiftTerm.
@MainActor
final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency TerminalViewDelegate {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let scrollback = 10_000

    /// Terminal.app's ANSI colors, which read well on light and dark backgrounds alike.
    private static let palette: [SwiftTerm.Color] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ].map { (rgb: (UInt16, UInt16, UInt16)) in Color(red8: rgb.0, green8: rgb.1, blue8: rgb.2) }

    let view: NSView
    private let terminalView: TerminalView
    private(set) var background = NSColor.textBackgroundColor
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalSize) -> Void)?
    var onTitle: ((String) -> Void)?

    init(size: TerminalSize) {
        terminalView = TerminalView(
            frame: .zero, font: Self.font,
            options: TerminalOptions(cols: size.columns, rows: size.rows, scrollback: Self.scrollback))
        view = terminalView
        super.init()
        terminalView.terminalDelegate = self
        terminalView.installColors(Self.palette)
        applyAppearance(NSApp.effectiveAppearance)
    }

    var size: TerminalSize {
        let terminal = terminalView.getTerminal()
        return TerminalSize(columns: terminal.cols, rows: terminal.rows)
    }

    func feed(_ data: Data) {
        terminalView.feed(byteArray: [UInt8](data)[...])
    }

    /// Text and background follow the system's light or dark appearance.
    func applyAppearance(_ appearance: NSAppearance) {
        var foreground = NSColor.black
        var background = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? foreground
            background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? background
        }
        self.background = background
        terminalView.nativeForegroundColor = foreground
        terminalView.nativeBackgroundColor = background
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(TerminalSize(columns: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52, which editors and tmux use to copy.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SwiftTermEngine: TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator {
        SwiftTermEmulator(size: size)
    }
}
```

`Sources/CanopyApp/Terminal/TerminalSurface.swift` (new):

```swift
import AppKit
import CanopyCore
import SwiftUI

/// Shows a pane's terminal with inner padding, since the terminal draws right up to its edges.
/// The terminal view belongs to the pane, so it keeps its screen while its tab or row is out of view.
struct TerminalSurface: NSViewRepresentable {
    let pane: Pane
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSizeChange: (TerminalSize) -> Void = { _ in }

    func makeNSView(context: Context) -> TerminalContainerView {
        // Only SwiftTermEngine makes the app's panes.
        TerminalContainerView(emulator: pane.emulator as! SwiftTermEmulator)
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.onFocusChange = onFocusChange
        container.onSizeChange = onSizeChange
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.releaseTerminal()
    }
}

final class TerminalContainerView: NSView {
    static let padding = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)

    private let emulator: SwiftTermEmulator
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSizeChange: (TerminalSize) -> Void = { _ in }
    private var focusObservation: NSKeyValueObservation?

    init(emulator: SwiftTermEmulator) {
        self.emulator = emulator
        super.init(frame: .zero)
        wantsLayer = true
        emulator.view.removeFromSuperview()
        addSubview(emulator.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func releaseTerminal() {
        focusObservation = nil
        if emulator.view.superview === self {
            emulator.view.removeFromSuperview()
        }
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        emulator.view.frame = NSRect(
            x: padding.left, y: padding.bottom,
            width: max(bounds.width - padding.left - padding.right, 0),
            height: max(bounds.height - padding.top - padding.bottom, 0))
        onSizeChange(emulator.size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onFocusChange(window.firstResponder === self.emulator.view)
            }
        }
        // A terminal that comes into view takes the keyboard.
        window?.makeFirstResponder(emulator.view)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        emulator.applyAppearance(effectiveAppearance)
        layer?.backgroundColor = emulator.background.cgColor
    }

    override func updateLayer() {
        layer?.backgroundColor = emulator.background.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Clicks on the padding focus the terminal too.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(emulator.view)
    }
}
```

- [ ] **Step 2: Build without warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:"`
Expected: no output.

- [ ] **Step 3: Look at it**

Run `make app`, then start the dev build against a throwaway home with a repo and a row, as `scripts/e2e.sh` does, and take a window screenshot with `swift scripts/window-shot.swift <pid> shot.png`.
Expected: the selected row shows a pane header reading "zsh" (or the user's shell) above a prompt in the row's folder, with padding around the text and colors matching the system appearance.
Type `echo "$CANOPY_PANE $TERM_PROGRAM"` and Return into the window.
Expected: it prints `p1 Canopy`.
Relaunch with `-NSRequiresAquaSystemAppearance YES` after the binary path to check the light appearance: white background, dark text.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved Sources/CanopyApp
git commit -m "feat: show a row's terminal in the window"
```

## Task 7: `canopy row new --run` and `--no-setup`

The control API goes through `RowLifecycle` too, so an agent's `row new` waits for setup and then types its command into a new terminal.
Params now default everything but what a method cannot do without, so the spec's short example request is accepted.

**Files:**
- Modify: `Sources/CanopyCore/Control/ControlMethods.swift`
- Modify: `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`
- Modify: `Sources/CanopyCLI/RowCommand.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`
- Test: `Tests/CanopyCoreTests/ControlProtocolTests.swift`, `Tests/CanopyCoreTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: `RowLifecycle.prepare`, `RowLifecycle.remove`, `SetupReport`.
- Produces:
  - `StatusResult.running` (always true).
  - `RowNewParams(target:branch:base:select:setup:run:)` with defaults, `RowNewResult.setup: SetupReport`, `RowNewResult.pane: String?`.
  - Defaulting decoders for `RowListParams`, `RowRefParams`, `RowRemoveParams`.
  - `WorkspaceControlHandler(rows: RowLifecycle, ui: any ControlUIBridge)`.
  - CLI: `canopy row new <branch> [--run <cmd>] [--no-setup]`, exiting 1 after printing the result when setup fails. `canopy row rm --force` also gets past a failing teardown.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlProtocolTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlProtocolTests.swift
+++ b/Tests/CanopyCoreTests/ControlProtocolTests.swift
@@ -5,10 +5,25 @@ import Testing
 
 struct JSONValueTests {
     @Test func roundTripsTypedValues() throws {
-        let params = RowNewParams(target: TargetHint(repo: "web"), branch: "fix/a", base: nil, select: true)
+        let params = RowNewParams(target: TargetHint(repo: "web"), branch: "fix/a", select: true, run: "claude")
         let decoded = try JSONValue.from(params).decode(RowNewParams.self)
         #expect(decoded.branch == "fix/a")
         #expect(decoded.select)
+        #expect(decoded.run == "claude")
+    }
+
+    @Test func paramsDefaultWhatIsLeftOut() throws {
+        let new = try JSONValue.object(["branch": .string("fix/x")]).decode(RowNewParams.self)
+        #expect(new.target == TargetHint())
+        #expect(!new.select)
+        #expect(new.setup)
+        #expect(new.run == nil)
+
+        let remove = try JSONValue.object([:]).decode(RowRemoveParams.self)
+        #expect(!remove.force && !remove.deleteBranch)
+        #expect(try JSONValue.object([:]).decode(RowListParams.self).all == false)
+        #expect(try JSONValue.object([:]).decode(RowRefParams.self).target == TargetHint())
+        #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(RowNewParams.self) }
     }
 
     @Test func keepsIntegersIntegral() throws {
```

`Tests/CanopyCoreTests/ControlServerTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -18,7 +18,8 @@ struct ControlServerTests {
         let workspace = Workspace(home: home, git: Fixture.git)
         try await workspace.start()
         let ui = RecordingUI()
-        let handler = WorkspaceControlHandler(workspace: workspace, ui: ui)
+        let rows = await MainActor.run { RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)) }
+        let handler = WorkspaceControlHandler(rows: rows, ui: ui)
         let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
         try await server.start()
         return (workspace, server, ControlClient(socketPath: home.socketPath, timeout: 10), ui)
@@ -71,6 +72,7 @@ struct ControlServerTests {
 
         let status = try await call(client, ControlMethod.status, JSONValue.null, as: StatusResult.self)
         #expect(status.pid == ProcessInfo.processInfo.processIdentifier)
+        #expect(status.running)
 
         let added = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
         #expect(added.name == "demo")
@@ -78,25 +80,63 @@ struct ControlServerTests {
         let created = try await call(
             client,
             ControlMethod.rowNew,
-            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", base: nil, select: true),
+            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", select: true),
             as: RowNewResult.self
         )
         #expect(created.row.branch == "feat/cli")
+        #expect(created.setup.status == .none)
+        #expect(created.pane == nil)
         #expect(ui.selected.withLock { $0 } == [created.row.path])
 
-        let rows = try await call(client, ControlMethod.rowList, RowListParams(repo: nil, all: false), as: [Row].self)
+        let rows = try await call(client, ControlMethod.rowList, RowListParams(), as: [Row].self)
         #expect(rows.map(\.branch) == ["main", "feat/cli"])
 
         let removed = try await call(
             client,
             ControlMethod.rowRemove,
-            RowRemoveParams(
-                target: TargetHint(envRepo: "demo", cwd: created.row.path), force: false, deleteBranch: true),
+            RowRemoveParams(target: TargetHint(envRepo: "demo", cwd: created.row.path), deleteBranch: true),
             as: Row.self
         )
         #expect(removed.path == created.row.path)
     }
 
+    @Test func shortRequestsLikeTheSpecsExampleAreAccepted() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let (_, server, client, _) = try await startServer(dir)
+        defer { server.stop() }
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+
+        // Without a target the app cannot tell which repo is meant, but the params themselves are fine.
+        let untargeted = try await offPool {
+            try client.send(
+                ControlRequest(
+                    method: ControlMethod.rowNew,
+                    params: .object(["branch": .string("fix/x"), "run": .string("echo hi")])))
+        }
+        #expect(untargeted.error?.code == "missing_target")
+
+        let created = try await call(
+            client, ControlMethod.rowNew,
+            JSONValue.object([
+                "branch": .string("fix/x"), "run": .string(#"echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran""#),
+                "target": .object(["repo": .string("demo")]),
+            ]),
+            as: RowNewResult.self
+        )
+        let pane = try #require(created.pane)
+        #expect(
+            await eventually { (try? String(contentsOfFile: dir.sub("ran"), encoding: .utf8)) == "\(pane)\n" })
+
+        let rows = try await call(client, ControlMethod.rowList, JSONValue.object([:]), as: [Row].self)
+        #expect(rows.map(\.branch) == ["main", "fix/x"])
+        _ = try await call(
+            client, ControlMethod.rowRemove,
+            JSONValue.object([
+                "target": .object(["repo": .string("demo"), "row": .string("fix/x")]), "force": .bool(true),
+            ]), as: Row.self)
+    }
+
     @Test func errorsCarryCodes() async throws {
         let dir = try TempDir()
         let (_, server, client, _) = try await startServer(dir)
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "JSONValueTests|ControlServerTests"`
Expected: build failure, because `RowNewParams` has no `run` argument yet and `WorkspaceControlHandler` has no `rows:ui:` initializer.

- [ ] **Step 3: Implement**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -76,7 +76,7 @@ final class AppModel {
 
     private func startControlServer() async {
         let bridge = AppUIBridge { [weak self] path in await self?.select(path) }
-        let handler = WorkspaceControlHandler(workspace: workspace, ui: bridge)
+        let handler = WorkspaceControlHandler(rows: rows, ui: bridge)
         let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
         do {
             try await server.start()
```

`Sources/CanopyCLI/RowCommand.swift` (modify):

```diff
--- a/Sources/CanopyCLI/RowCommand.swift
+++ b/Sources/CanopyCLI/RowCommand.swift
@@ -43,6 +43,9 @@ struct RowCommand: AsyncParsableCommand {
             discussion: """
                 An existing local branch is checked out. A branch that only exists on origin is tracked. \
                 Anything else is created from --from, which defaults to origin's default branch.
+
+                The repo's setup commands from .canopy/config.json then run in the row's Setup tab, and this \
+                waits for them. If setup fails, the row stays, --run is skipped, and this exits 1.
                 """
         )
 
@@ -52,6 +55,10 @@ struct RowCommand: AsyncParsableCommand {
         var repo: String?
         @Option(name: .customLong("from"), help: "Start point for a new branch.")
         var base: String?
+        @Option(name: .customLong("run"), help: "Command to type into a new terminal once setup succeeds.")
+        var command: String?
+        @Flag(name: .customLong("no-setup"), help: "Skip the repo's setup commands.")
+        var noSetup = false
         @Flag(help: "Switch the Canopy window to the new row.")
         var select = false
         @OptionGroup var output: OutputOptions
@@ -60,27 +67,51 @@ struct RowCommand: AsyncParsableCommand {
             let client = Client(json: output.json)
             let result = client.call(
                 ControlMethod.rowNew,
-                RowNewParams(target: Client.hint(repo: repo), branch: branch, base: base, select: select)
+                RowNewParams(
+                    target: Client.hint(repo: repo), branch: branch, base: base, select: select, setup: !noSetup,
+                    run: command)
             )
             let created = try result.decode(RowNewResult.self)
             for warning in created.warnings {
                 FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
             }
-            try client.print(result) { "Created \(created.row.displayName) at \(created.row.path)." }
+            try client.print(result) { summary(of: created) }
+            if created.setup.status == .failed {
+                fflush(stdout)
+                FileHandle.standardError.write(Data("error: \(created.setup.message ?? "Setup failed.")\n".utf8))
+                throw ExitCode(1)
+            }
+        }
+
+        private func summary(of created: RowNewResult) -> String {
+            var lines = ["Created \(created.row.displayName) at \(created.row.path)."]
+            switch created.setup.status {
+            case .succeeded: lines.append("Setup finished.")
+            case .skipped: lines.append("Skipped setup.")
+            case .none, .failed: break
+            }
+            if let pane = created.pane, let command {
+                lines.append("Running \(command) in \(pane).")
+            }
+            return lines.joined(separator: "\n")
         }
     }
 
     struct Remove: AsyncParsableCommand {
         static let configuration = CommandConfiguration(
             commandName: "rm",
-            abstract: "Remove a row's worktree, or hide an adopted row."
+            abstract: "Remove a row's worktree, or hide an adopted row.",
+            discussion: """
+                The repo's teardown commands from .canopy/config.json run first in the row's Teardown tab, \
+                then the row's terminals close and the worktree is removed.
+                """
         )
 
         @Argument(help: "Branch or path. Defaults to the row you are in.")
         var row: String?
         @Option(help: "Repo name or path, when the branch exists in several repos.")
         var repo: String?
-        @Flag(help: "Remove even with uncommitted changes.")
+        @Flag(help: "Remove even with uncommitted changes or a failing teardown.")
         var force = false
         @Flag(help: "Also delete the branch.")
         var deleteBranch = false
```

`Sources/CanopyCore/Control/ControlMethods.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/ControlMethods.swift
+++ b/Sources/CanopyCore/Control/ControlMethods.swift
@@ -46,6 +46,8 @@ public struct TargetHint: Codable, Sendable, Equatable {
 }
 
 public struct StatusResult: Codable, Sendable, Equatable {
+    /// Always true here. The CLI prints `"running": false` itself when it cannot connect.
+    public var running = true
     public var version: String
     public var home: String
     public var pid: Int32
@@ -84,16 +86,25 @@ public struct RepoRemoveParams: Codable, Sendable {
     }
 }
 
+// Params decode with defaults for everything but what a method cannot do without, so agents can send
+// short requests such as {"branch": "fix/x", "run": "claude"}.
+
 public struct RowListParams: Codable, Sendable {
     /// Limits the list to one repo. Lists every repo when nil.
     public var repo: String?
     /// Includes external worktrees.
     public var all: Bool
 
-    public init(repo: String?, all: Bool) {
+    public init(repo: String? = nil, all: Bool = false) {
         self.repo = repo
         self.all = all
     }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        repo = try container.decodeIfPresent(String.self, forKey: .repo)
+        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
+    }
 }
 
 public struct RowNewParams: Codable, Sendable {
@@ -101,38 +112,73 @@ public struct RowNewParams: Codable, Sendable {
     public var branch: String
     public var base: String?
     public var select: Bool
+    /// Runs the repo's setup commands. Off with `--no-setup`.
+    public var setup: Bool
+    /// A command to type into a new terminal once setup succeeds.
+    public var run: String?
 
-    public init(target: TargetHint, branch: String, base: String?, select: Bool) {
+    public init(
+        target: TargetHint = TargetHint(), branch: String, base: String? = nil, select: Bool = false,
+        setup: Bool = true, run: String? = nil
+    ) {
         self.target = target
         self.branch = branch
         self.base = base
         self.select = select
+        self.setup = setup
+        self.run = run
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
+        branch = try container.decode(String.self, forKey: .branch)
+        base = try container.decodeIfPresent(String.self, forKey: .base)
+        select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
+        setup = try container.decodeIfPresent(Bool.self, forKey: .setup) ?? true
+        run = try container.decodeIfPresent(String.self, forKey: .run)
     }
 }
 
 public struct RowNewResult: Codable, Sendable {
     public var row: Row
     public var warnings: [String]
+    public var setup: SetupReport
+    /// The terminal started for `run`, such as "p12".
+    public var pane: String?
 }
 
 public struct RowRefParams: Codable, Sendable {
     public var target: TargetHint
 
-    public init(target: TargetHint) {
+    public init(target: TargetHint = TargetHint()) {
         self.target = target
     }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
+    }
 }
 
 public struct RowRemoveParams: Codable, Sendable {
     public var target: TargetHint
+    /// Removes the row even with uncommitted changes or a failing teardown.
     public var force: Bool
     public var deleteBranch: Bool
 
-    public init(target: TargetHint, force: Bool, deleteBranch: Bool) {
+    public init(target: TargetHint = TargetHint(), force: Bool = false, deleteBranch: Bool = false) {
         self.target = target
         self.force = force
         self.deleteBranch = deleteBranch
     }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
+        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
+        deleteBranch = try container.decodeIfPresent(Bool.self, forKey: .deleteBranch) ?? false
+    }
 }
 
 public struct RowAdoptParams: Codable, Sendable {
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
+++ b/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
@@ -6,14 +6,16 @@ public protocol ControlUIBridge: Sendable {
 }
 
 public struct WorkspaceControlHandler: Sendable {
-    let workspace: Workspace
+    let rows: RowLifecycle
     let ui: any ControlUIBridge
 
-    public init(workspace: Workspace, ui: any ControlUIBridge) {
-        self.workspace = workspace
+    public init(rows: RowLifecycle, ui: any ControlUIBridge) {
+        self.rows = rows
         self.ui = ui
     }
 
+    var workspace: Workspace { rows.workspace }
+
     public func handle(_ request: ControlRequest) async -> ControlResponse {
         guard request.v == ControlCodec.version else {
             return .failure(
@@ -72,15 +74,22 @@ public struct WorkspaceControlHandler: Sendable {
             let params = try request.decodeParams(RowNewParams.self)
             let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
             let created = try await workspace.createRow(repoPath: repo.path, branch: params.branch, base: params.base)
+            let preparing = await rows.prepare(created.row, repoName: repo.name, setup: params.setup, run: params.run)
             if params.select {
                 await select(created.row.path)
             }
-            return try .from(RowNewResult(row: created.row, warnings: created.warnings))
+            let ready = await preparing.value
+            return try .from(
+                RowNewResult(
+                    row: created.row, warnings: created.warnings, setup: ready.setup, pane: ready.pane?.description))
 
         case ControlMethod.rowRemove:
             let params = try request.decodeParams(RowRemoveParams.self)
-            let row = try TargetResolver.row(for: params.target, in: await workspace.snapshot)
-            try await workspace.removeRow(path: row.path, force: params.force, deleteBranch: params.deleteBranch)
+            let snapshot = await workspace.snapshot
+            let row = try TargetResolver.row(for: params.target, in: snapshot)
+            try await rows.remove(
+                row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "", force: params.force,
+                deleteBranch: params.deleteBranch)
             return try .from(row)
 
         case ControlMethod.rowSelect:
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`
Expected: `Test run with 168 tests in 26 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: let agents run setup and a command with canopy row new"
```

## Task 8: Tabs, keys, and confirmations

The tab bar, the menu commands, the busy checks before closing or quitting, and an app delegate that starts and stops the model whether or not a window is open.

**Files:**
- Create: `Sources/CanopyApp/Terminal/TabBarView.swift`
- Modify: `Sources/CanopyApp/CanopyApp.swift`, `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/RootView.swift`
- Modify: `Sources/CanopyApp/Terminal/RowTerminalsView.swift`, `Sources/CanopyApp/Terminal/SwiftTermEmulator.swift`
- Modify: `Sources/CanopyApp/Sidebar/RowActionViews.swift`

**Interfaces:**
- Consumes: `TerminalStore`, `BusyTerminals.quitWarning`, `Pane.isBusy`, `Pane.foreground`.
- Produces:
  - `TabBarView(row:)`, `TabItemView`, `NoteLine`.
  - `AppDelegate` owning `model`, `TerminalCommands`.
  - `AppModel.PendingClose`, `pendingClose`, `selectedTab`, `canOpenTerminal`, `requestClose(_:)`, `confirmClose()`, `closeFocusedPane()`, `focusSelectedTerminal()`, `selectTab(offset:)`.
  - `SwiftTermEmulator.focus()`.

- [ ] **Step 1: Write the changes**

The remove popover sets `.lineLimit(nil)` because a popover inherits the sidebar row's one-line limit, which cut its notes off after one line.

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -165,13 +165,59 @@ final class AppModel {
         PaneContext(row: row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "")
     }
 
+    /// A close waiting for the user to confirm, because a program still runs in the terminal.
+    struct PendingClose {
+        let pane: PaneID
+        let program: String
+    }
+
+    var pendingClose: PendingClose?
+
+    var selectedTab: TerminalTab? {
+        selectedRow.flatMap { terminals.selectedTab(inRow: $0.path) }
+    }
+
+    var canOpenTerminal: Bool {
+        selectedRow.map { !$0.isMissing } ?? false
+    }
+
     func newTab() {
         guard let row = selectedRow, !row.isMissing else { return }
         terminals.openTab(for: context(for: row))
     }
 
-    func closePane(_ pane: Pane) {
-        terminals.closePane(pane.id)
+    /// Closes a terminal, first asking if a program other than the shell still runs in it.
+    func requestClose(_ pane: Pane) {
+        if pane.isBusy, let program = pane.foreground?.name {
+            pendingClose = PendingClose(pane: pane.id, program: program)
+        } else {
+            terminals.closePane(pane.id)
+        }
+    }
+
+    func confirmClose() {
+        if let pending = pendingClose {
+            terminals.closePane(pending.pane)
+        }
+        pendingClose = nil
+    }
+
+    /// ⌘W. Only for the main window itself, so it never closes a terminal behind a sheet or a closed window.
+    func closeFocusedPane() {
+        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
+            let pane = selectedTab?.pane
+        else { return }
+        requestClose(pane)
+    }
+
+    /// Hands the keyboard back to the terminal on screen, as after renaming a tab.
+    func focusSelectedTerminal() {
+        (selectedTab?.pane.emulator as? SwiftTermEmulator)?.focus()
+    }
+
+    func selectTab(offset: Int) {
+        guard let row = selectedRow else { return }
+        terminals.selectTab(offset: offset, inRow: row.path)
     }
 
     // MARK: Repos
```

`Sources/CanopyApp/CanopyApp.swift` (modify):

```diff
--- a/Sources/CanopyApp/CanopyApp.swift
+++ b/Sources/CanopyApp/CanopyApp.swift
@@ -4,19 +4,71 @@ import SwiftUI
 
 @main
 struct CanopyApp: App {
-    @State private var model = AppModel(
-        home: CanopyHome.resolve(
-            bundleHome: Bundle.main.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
-        )
-    )
+    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
 
     var body: some Scene {
         Window("Canopy", id: "main") {
             RootView()
-                .environment(model)
+                .environment(delegate.model)
         }
         .commands {
-            RowCommands(model: model)
+            TerminalCommands(model: delegate.model)
+            RowCommands(model: delegate.model)
+        }
+    }
+}
+
+/// Owns the model, so starting and stopping do not depend on the window being open.
+@MainActor
+final class AppDelegate: NSObject, NSApplicationDelegate {
+    let model = AppModel(
+        home: CanopyHome.resolve(
+            bundleHome: Bundle.main.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
+        )
+    )
+
+    func applicationDidFinishLaunching(_ notification: Notification) {
+        Task { await model.start() }
+    }
+
+    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
+        let busy = model.terminals.busyPanes.compactMap(\.foreground?.name)
+        guard !busy.isEmpty else { return .terminateNow }
+        let alert = NSAlert()
+        alert.messageText = "Quit Canopy?"
+        alert.informativeText = BusyTerminals.quitWarning(busy)
+        alert.addButton(withTitle: "Quit")
+        alert.addButton(withTitle: "Cancel")
+        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
+    }
+
+    func applicationWillTerminate(_ notification: Notification) {
+        model.shutdown()
+    }
+}
+
+struct TerminalCommands: Commands {
+    let model: AppModel
+
+    var body: some Commands {
+        CommandGroup(after: .newItem) {
+            Button("New Tab", action: model.newTab)
+                .keyboardShortcut("t")
+                .disabled(!model.canOpenTerminal)
+        }
+        // Replacing the save group also drops File > Close, so ⌘W closes a terminal rather than the window.
+        CommandGroup(replacing: .saveItem) {
+            Button("Close Terminal", action: model.closeFocusedPane)
+                .keyboardShortcut("w")
+                .disabled(model.selectedTab == nil)
+        }
+        CommandGroup(before: .windowArrangement) {
+            // ⌘⇧[ reaches the menu as "{", so the shortcuts are declared by the character the keys type.
+            Button("Show Previous Tab") { model.selectTab(offset: -1) }
+                .keyboardShortcut("{", modifiers: .command)
+            Button("Show Next Tab") { model.selectTab(offset: 1) }
+                .keyboardShortcut("}", modifiers: .command)
+            Divider()
         }
     }
 }
```

`Sources/CanopyApp/RootView.swift` (modify):

```diff
--- a/Sources/CanopyApp/RootView.swift
+++ b/Sources/CanopyApp/RootView.swift
@@ -21,12 +21,18 @@ struct RootView: View {
             }
         }
         .animation(.snappy, value: model.toast)
-        .task { await model.start() }
         .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             model.refresh()
         }
-        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
-            model.shutdown()
+        .alert(
+            "Close this terminal?",
+            isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } }),
+            presenting: model.pendingClose
+        ) { _ in
+            Button("Close Terminal", role: .destructive, action: model.confirmClose)
+            Button("Cancel", role: .cancel) {}
+        } message: { pending in
+            Text("\(pending.program) is still running in it.")
         }
     }
 }
```

`Sources/CanopyApp/Sidebar/RowActionViews.swift` (modify):

```diff
--- a/Sources/CanopyApp/Sidebar/RowActionViews.swift
+++ b/Sources/CanopyApp/Sidebar/RowActionViews.swift
@@ -72,6 +72,9 @@ struct RemoveRowPopover: View {
 
     private var isAdopted: Bool { row.rowClass == .adopted }
 
+    /// Read while the popover lays itself out, so its height includes the note.
+    private var busyTerminals: Int { model.terminals.busyPanes(inRow: row.path).count }
+
     var body: some View {
         VStack(alignment: .leading, spacing: 10) {
             Text(isAdopted ? "Hide \(row.displayName)?" : "Remove \(row.displayName)?")
@@ -87,17 +90,25 @@ struct RemoveRowPopover: View {
             if !isAdopted, let branch = row.branch {
                 Toggle("Also delete branch \(branch)", isOn: $deleteBranch)
             }
+            if busyTerminals > 0 {
+                NoteLine(
+                    systemImage: "apple.terminal",
+                    text: busyTerminals == 1
+                        ? "A terminal in this row is running a program. Removing stops it."
+                        : "\(busyTerminals) terminals in this row are running programs. Removing stops them.",
+                    color: .secondary
+                )
+            }
             if isDirty {
-                Label("It has uncommitted changes.", systemImage: "exclamationmark.triangle.fill")
-                    .foregroundStyle(.orange)
+                NoteLine(
+                    systemImage: "exclamationmark.triangle.fill", text: "It has uncommitted changes.", color: .orange)
             }
             if let teardownCode {
-                Label(
-                    "Teardown failed with exit code \(teardownCode). Its tab shows why.",
-                    systemImage: "exclamationmark.triangle.fill"
+                NoteLine(
+                    systemImage: "exclamationmark.triangle.fill",
+                    text: "Teardown failed with exit code \(teardownCode). Its tab shows why.",
+                    color: .orange
                 )
-                .foregroundStyle(.orange)
-                .fixedSize(horizontal: false, vertical: true)
             }
             if let error {
                 Text(error)
@@ -116,6 +127,8 @@ struct RemoveRowPopover: View {
         }
         .padding(14)
         .frame(width: 300)
+        // The popover inherits the sidebar row's one-line limit.
+        .lineLimit(nil)
     }
 
     private var buttonTitle: String {
@@ -137,3 +150,19 @@ struct RemoveRowPopover: View {
         }
     }
 }
+
+/// An icon and a sentence that wraps, for notes in narrow popovers.
+struct NoteLine: View {
+    let systemImage: String
+    let text: String
+    let color: Color
+
+    var body: some View {
+        HStack(alignment: .firstTextBaseline, spacing: 6) {
+            Image(systemName: systemImage)
+            Text(text)
+                .fixedSize(horizontal: false, vertical: true)
+        }
+        .foregroundStyle(color)
+    }
+}
```

`Sources/CanopyApp/Terminal/RowTerminalsView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/RowTerminalsView.swift
+++ b/Sources/CanopyApp/Terminal/RowTerminalsView.swift
@@ -1,7 +1,7 @@
 import CanopyCore
 import SwiftUI
 
-/// The detail area for a row: its selected tab's terminal.
+/// The detail area for a row: its tab bar and the selected tab's terminal.
 struct RowTerminalsView: View {
     @Environment(AppModel.self) private var model
     let row: Row
@@ -18,17 +18,20 @@ struct RowTerminalsView: View {
                 }
             }
         } else if let tab = model.terminals.selectedTab(inRow: row.path) {
-            PaneView(
-                pane: tab.pane,
-                onClose: { model.closePane(tab.pane) },
-                onSizeChange: { model.terminals.preferredSize = $0 }
-            )
-            .id(tab.pane.id)
+            VStack(spacing: 0) {
+                TabBarView(row: row)
+                PaneView(
+                    pane: tab.pane,
+                    onClose: { model.requestClose(tab.pane) },
+                    onSizeChange: { model.terminals.preferredSize = $0 }
+                )
+                .id(tab.pane.id)
+            }
         } else {
             ContentUnavailableView {
                 Label("No Terminals", systemImage: "apple.terminal")
             } description: {
-                Text("Open one to work in \(row.displayName).")
+                Text("Press ⌘T to open one in \(row.displayName).")
             } actions: {
                 Button("New Terminal") { model.newTab() }
             }
```

`Sources/CanopyApp/Terminal/SwiftTermEmulator.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
+++ b/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
@@ -39,6 +39,11 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         return TerminalSize(columns: terminal.cols, rows: terminal.rows)
     }
 
+    /// Gives the terminal the keyboard, if it is on screen.
+    func focus() {
+        view.window?.makeFirstResponder(view)
+    }
+
     func feed(_ data: Data) {
         terminalView.feed(byteArray: [UInt8](data)[...])
     }
```

`Sources/CanopyApp/Terminal/TabBarView.swift` (new):

```swift
import CanopyCore
import SwiftUI

/// A row's tabs. Double-click a tab to rename it.
struct TabBarView: View {
    @Environment(AppModel.self) private var model
    let row: Row

    var body: some View {
        let tabs = model.terminals.tabs(inRow: row.path)
        let selected = model.terminals.selectedTab(inRow: row.path)?.id
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tab.id == selected,
                            onSelect: { model.terminals.selectTab(tab.id, inRow: row.path) },
                            onClose: { model.requestClose(tab.pane) },
                            onRename: { name in
                                model.terminals.renameTab(tab.id, inRow: row.path, to: name)
                                model.focusSelectedTerminal()
                            }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
            Button(action: model.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("New Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

struct TabItemView: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isRenaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .fixedSize()
                    .onAppear { isFieldFocused = true }
                    .onSubmit(finishRenaming)
                    .onExitCommand {
                        draft = tab.name
                        finishRenaming()
                    }
                    .onChange(of: isFieldFocused) {
                        if !isFieldFocused { finishRenaming() }
                    }
            } else {
                Text(tab.name)
                    .lineLimit(1)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close Tab")
            .opacity(isHovering ? 1 : 0)
        }
        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.1) : isHovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                draft = tab.name
                isRenaming = true
            }
        )
        .simultaneousGesture(TapGesture().onEnded(onSelect))
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        onRename(draft)
    }
}
```

- [ ] **Step 2: Build without warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:"`
Expected: no output.

- [ ] **Step 3: Check the keys and confirmations in the running app**

Start the dev build against a throwaway home with a selected row, as in Task 6, and check each of these with window screenshots:
- `⌘T` adds "Terminal 2" and focuses it. `⌘⇧[` goes back to "Terminal" with its screen intact.
- `sleep 100` then `⌘W` shows "Close this terminal?" with "sleep is still running in it." Escape cancels.
- `exit 3` shows the strip "exited (code 3)" with the cursor hidden and the header keeping its title. Return starts a new shell on a fresh line.
- Double-clicking a tab opens a rename field. Typing a name and Return renames it and gives the keyboard back to the terminal.
- With `sleep 300` running, `⌘Q` shows "Quit Canopy?" and "1 terminal is running a process: sleep. Quitting stops it." Cancel keeps the app running.
- Hovering a row with a running program and clicking `×` shows the remove popover with "A terminal in this row is running a program. Removing stops it." on two wrapped lines. Remove deletes the row and ends the program.
- Closing a row's last tab shows "No Terminals" with a New Terminal button.

- [ ] **Step 4: Commit**

```bash
git add Sources/CanopyApp
git commit -m "feat: tabs, terminal shortcuts, and confirmations before closing running programs"
```

## Task 9: End-to-end coverage and the PR

**Files:**
- Modify: `scripts/e2e.sh`

**Interfaces:**
- Consumes: the whole CLI and a dev build.
- Produces: `make e2e` covering setup, `--run`, `--no-setup`, failed setup, failed teardown, and self-removal, and leaving `build/e2e/terminal.png`.

- [ ] **Step 1: Add the steps**

Insert them after the "canopy row rm removes the worktree and branch" step.
The config is committed after the earlier steps, so the rows they create have no setup.

`scripts/e2e.sh` (modify):

```diff
--- a/scripts/e2e.sh
+++ b/scripts/e2e.sh
@@ -79,6 +79,74 @@ step "canopy row rm removes the worktree and branch"
 [[ ! -d "$CANOPY_HOME/worktrees/demo/feat-e2e" ]] || fail "worktree folder still exists"
 if git -C "$work/demo" show-ref --verify --quiet refs/heads/feat/e2e; then fail "branch still exists"; fi
 
+step "setup runs with the row's variables, then --run types a command into a new terminal"
+mkdir -p "$work/demo/.canopy"
+cat > "$work/demo/.canopy/config.json" <<'EOF'
+{
+  "setup": [
+    "printf '%s\\n' \"$CANOPY_ROOT_PATH\" \"$CANOPY_REPO\" \"$CANOPY_ROW\" \"$TERM_PROGRAM\" > \"$CANOPY_ROOT_PATH/../setup-$(basename \"$CANOPY_ROW_PATH\").env\""
+  ],
+  "teardown": ["echo \"$CANOPY_ROW\" >> \"$CANOPY_ROOT_PATH/../teardown.log\""]
+}
+EOF
+git -C "$work/demo" add .canopy
+git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q -m "canopy config"
+git -C "$work/demo" push -q origin main
+"$cli" row new feat/setup --repo demo --select --run 'echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran"' --json \
+    > "$work/setup.json"
+grep -q '"status" : "succeeded"' "$work/setup.json" || fail "setup did not succeed"
+pane=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pane"])' "$work/setup.json")
+env_file="$work/setup-feat-setup.env"
+[[ "$(sed -n 1p "$env_file")" == "$(cd "$work/demo" && pwd -P)" ]] || fail "CANOPY_ROOT_PATH is wrong"
+[[ "$(sed -n 2,4p "$env_file" | tr '\n' ' ')" == "demo feat/setup Canopy " ]] || fail "setup variables are wrong"
+for _ in $(seq 1 100); do
+    [[ "$(cat "$work/ran" 2>/dev/null)" == "$pane" ]] && break
+    sleep 0.1
+done
+[[ "$(cat "$work/ran" 2>/dev/null)" == "$pane" ]] || fail "--run did not reach pane $pane"
+sleep 1
+swift scripts/window-shot.swift "$(app_pid)" "$shots/terminal.png"
+echo "saved $shots/terminal.png"
+
+step "--no-setup skips setup"
+"$cli" row new feat/no-setup --repo demo --no-setup --json | grep -q '"status" : "skipped"' || fail "setup not skipped"
+[[ ! -e "$work/setup-feat-no-setup.env" ]] || fail "setup ran anyway"
+
+step "failed setup keeps the row, skips --run, and exits 1"
+git -C "$work/demo" switch -q -c broken-config
+printf '{"setup": ["exit 5"], "teardown": ["exit 6"]}\n' > "$work/demo/.canopy/config.json"
+git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q -am "broken config"
+git -C "$work/demo" switch -q main
+if "$cli" row new feat/broken --repo demo --from broken-config --run 'touch "$CANOPY_ROOT_PATH/../never"' --json \
+    > "$work/broken.json" 2>/dev/null; then
+    fail "expected failure"
+fi
+grep -q '"exitCode" : 5' "$work/broken.json" || fail "setup exit code missing"
+[[ -d "$CANOPY_HOME/worktrees/demo/feat-broken" ]] || fail "row was not kept"
+sleep 1
+[[ ! -e "$work/never" ]] || fail "--run ran after failed setup"
+
+step "failed teardown keeps the row until --force"
+if "$cli" row rm feat/broken --repo demo --json > "$work/teardown.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"teardown_failed"' "$work/teardown.json" || fail "missing teardown_failed"
+[[ -d "$CANOPY_HOME/worktrees/demo/feat-broken" ]] || fail "row removed despite failed teardown"
+"$cli" row rm feat/broken --repo demo --force >/dev/null
+[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-broken" ]] || fail "--force did not remove the row"
+
+step "teardown runs before the row goes"
+"$cli" row rm feat/setup --repo demo >/dev/null
+grep -qx feat/setup "$work/teardown.log" || fail "teardown did not run"
+[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-setup" ]] || fail "row still exists"
+
+step "an agent can remove the row it runs in"
+"$cli" row new feat/self --repo demo --no-setup --run "'$cli' row rm" >/dev/null
+for _ in $(seq 1 150); do
+    [[ -d "$CANOPY_HOME/worktrees/demo/feat-self" ]] || break
+    sleep 0.1
+done
+[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-self" ]] || fail "the row's own agent could not remove it"
+grep -qx feat/self "$work/teardown.log" || fail "teardown did not run for the self-removed row"
+
 step "errors are machine-readable"
 if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
 grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"
```

- [ ] **Step 2: Run it**

Run: `make e2e`
Expected: every `==>` step runs and the last line is `e2e passed`.

Look at `build/e2e/terminal.png`.
Expected: `feat/setup` is selected with one "Terminal" tab, whose prompt shows the `--run` command typed once and a fresh prompt after it.

- [ ] **Step 3: Full check and commit**

```bash
make lint && make build && make test
git add scripts/e2e.sh
git commit -m "test: cover setup, teardown, and --run end to end"
```

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin feat/terminals-tabs
gh pr create --title "feat: terminals and tabs, with setup and teardown" --body "$(cat <<'EOF'
## Summary

Every row now has tabs of real terminals running the user's login shell in the row's folder.
Terminals keep running while their row or tab is out of view, and quitting or closing asks first when a program is still running.
A repo's `.canopy/config.json` setup commands run in a visible Setup tab when a row is created, and its teardown commands run in a Teardown tab before a row is removed.
Agents can now run `canopy row new fix/x --run 'claude "..."'`, which waits for setup and then types the command into a new terminal.
It also fixes nine of the review minors carried over from PRs 2 to 4.

## Testing

- `make test`: 168 tests pass, including real pseudo-terminals, setup and teardown against real git repos, and parallel `--run` rows.
- `make e2e`: drives a dev build through setup, `--run`, `--no-setup`, failing setup and teardown, and an agent removing its own row. Screenshot attached.
- By hand in the running app: typing, `⌘T`, `⌘W`, `⌘⇧[`, restart after exit, tab rename, the close and quit confirmations, the remove popover, and light and dark appearance.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

Attach `build/e2e/terminal.png` to the PR.

## After Review

Two commits followed the nine tasks.
They are on the branch, so the code there is the reference for these parts.

- `perf: let terminal output overlap with drawing`: `PtyProcess` hands output to the main actor with up to four chunks in flight instead of one at a time. A million lines went from 4.5 to 3.7 seconds.
- `fix: address review of terminals and tabs`, from an independent review of the branch:
  - `TerminalStore.closeRowsGone(from:)` closes the terminals of rows that leave a repo git could list, for example after a plain `git worktree remove`. Rows not yet seen in any snapshot are left alone, so a row created a moment ago keeps its Setup tab. Removing a repo closes its terminals, asking first in the UI if any run programs, and relocating a repo moves its terminals with it.
  - "Remove Anyway" after a failed teardown skips teardown without discarding uncommitted changes. The CLI's `--force` still does both.
  - New terminals get `IUTF8`, as Terminal sets it.
  - `row new` and `row rm` wait for setup and teardown without a reply timeout, since the app cannot cancel them.
  - A branch that cannot be deleted comes back as a warning in `RowRemoveResult`, because the row is already gone.
  - Closing the Teardown tab stops the removal with `teardown_stopped`.
