# Canopy Git Timeout Flake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop child-process waits from taking every thread Dispatch lends, so git and gh timeouts hold on a small machine and `GitRunnerTests.timeoutKillsGitAndEverythingItStarted` stops flaking on CI.

**Architecture:** A new `onOwnThread` helper in `CanopyCore` runs blocking work on a thread of its own.
`GitRunner.run` and both `GitHubCLI` lookups use it instead of `DispatchQueue.global()`, since each one blocks for as long as its child process runs.
Short scans, such as the port scans, stay on Dispatch.

**Tech Stack:** Swift 6.2, Foundation `Thread`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Creating a row" (the fetch) and "PR badges" (the `gh` call).
The spec says nothing about threads, so it does not change.

## Root Cause

On PR 12's CI run, `timeoutKillsGitAndEverythingItStarted` took 41 s against its 5 s bound, and passed on rerun.
The handover guessed that `Subprocess.waitForExit` took a kevent `EV_ERROR` for the exit and skipped the kill.
The CI log rules that out: the test's only failure was the 5 s bound, so `timedOut` was true and the kill ran.

What the logs of 13 CI runs show instead:

- Every run has a stall of 10 to 27 s in which no test finishes.
- `returnsStdout`, a bare `git --version`, takes 20 to 43 s in every run, and under 1 s locally.
- The stall always ends with the same tests: the port stopper's, the quick git runner tests, `overLongLinesAreRejected`, and `addRepoRejectsNonRepos`.
  Each of them waits on a `DispatchQueue.global()` block.

A throwaway draft PR (13, closed) sampled the test process during a CI run.
At +25 s the process had exactly 64 threads on `com.apple.root.default-qos`, and the runner's `kern.wq_max_constrained_threads` is 64.
63 were blocked in `kevent` inside `Subprocess.waitForExit` and one in `posix_spawn`, all under `GitRunner.run`.
The flaky test failed on that run too, at 12.7 s.

So the mechanism is:

1. `GitRunner.run` hands `Subprocess.run` to `DispatchQueue.global()`, which blocks the worker until git exits.
2. Dispatch lends its global queues at most `max(64, 5 × CPUs)` threads: 64 on CI's 3 CPUs, 90 on an 18-CPU Mac.
3. Dozens of parallel tests run git at once, so every one of those threads waits on a child process.
   Any block queued behind them waits for one of them to finish.
4. `waitForExit` starts its deadline only once its block runs, so a 300 ms timeout can end many seconds after the call.

The app has the same flaw, not just the tests.
A stalled `git fetch` holds a thread for its 60 s timeout, and a hung `gh` for 30 s.
With enough of them, every git and gh call in the app waits, and their timeouts start late.
`GitHubCLI.pullRequests` and `GitHubCLI.repo(forRemote:)` block the same way, on `gh api graphql` and `ssh -G`.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings.
- `make lint` passes `swift format lint --strict`.
- No change to what git, gh, or ssh are run with, or to any timeout value.
- Blocking work never runs on the Swift concurrency pool, as before.

## Review Focus

1. Every thread Dispatch lends is already waiting, as on CI: git and gh timeouts still end on time.
   Pinned by the three `...WhenDispatchHasNoThreadsLeft` tests in Tasks 1 and 2.
2. More git runs at once than Dispatch would lend threads, as when the app refreshes many repos: each run gets its own thread, so none waits for another to finish.
   Pinned by the same tests, since each needs a thread while all of Dispatch's are taken.
3. A git run that throws, such as a timeout or a failed command, still reaches the caller as a `GitError`.
   Pinned by the existing `throwsWithStderrOnFailure` and `timeoutKillsGitAndEverythingItStarted`.
4. The first git or gh call in a process resolves the login `PATH` through the user's shell, which can take up to 5 s.
   It still runs off the Swift concurrency pool, now on the call's own thread.
5. A test that holds every Dispatch thread slows other tests that use Dispatch while it runs.
   `withEveryDispatchThreadBusy` releases them when its body returns, and after ten seconds at most, so a regression shows as a failed bound rather than a hang.

## Decisions to Review

1. **A new thread per call, with no cap.**
   A cap would bring back the queueing that started timeouts late.
   A thread costs far less than the git process it waits on, and the app runs at most a few hundred at once.
   The alternative, waiting on exits with Dispatch sources and no thread at all, needs its own handling of the exit event arriving before `waitpid` can reap, which CI has shown before.
2. **The port scans stay on `DispatchQueue.global()`.**
   They read the process table and return; they never wait on a child.
3. **The test helper `offPool` now calls `onOwnThread`,** so one function spawns threads for blocking work.

---

## Task 1: Run git on a thread of its own

**Files:**
- Create: `Sources/CanopyCore/Support/OwnThread.swift`
- Modify: `Sources/CanopyCore/Git/GitRunner.swift`
- Modify: `Sources/CanopyCore/Support/Subprocess.swift` (doc comment only)
- Modify: `Tests/CanopyCoreTests/Support/Fixtures.swift`
- Test: `Tests/CanopyCoreTests/GitRunnerTests.swift`

**Interfaces:**
- Produces: `func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T`, internal to `CanopyCore`.
- Produces (tests): `func withEveryDispatchThreadBusy<T>(_ body: () async throws -> T) async throws -> T`.

- [ ] **Step 1: Add the test helper that takes every Dispatch thread**

In `Tests/CanopyCoreTests/Support/Fixtures.swift`, add `import Testing` below `import Foundation`, and this above `eventually`:

```swift
/// Runs `body` while blocks hold every thread Dispatch lends its global queues, as dozens of tests running git at once
/// did on a 3-CPU CI runner. Anything queued there meanwhile waits until `body` returns, or ten seconds at most.
func withEveryDispatchThreadBusy<T>(_ body: () async throws -> T) async throws -> T {
    var limit: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    try #require(sysctlbyname("kern.wq_max_constrained_threads", &limit, &size, nil, 0) == 0)
    let release = DispatchSemaphore(value: 0)
    for _ in 0..<limit {
        DispatchQueue.global().async { _ = release.wait(timeout: .now() + 10) }
    }
    defer {
        for _ in 0..<limit { release.signal() }
    }
    return try await body()
}
```

- [ ] **Step 2: Write the failing test**

In `Tests/CanopyCoreTests/GitRunnerTests.swift`, after `timeoutKillsGitAndEverythingItStarted`:

```swift
    /// On CI, dozens of tests running git at once took every thread Dispatch lends, and a run that queued for one
    /// started its timeout late.
    @Test func timeoutHoldsWhenDispatchHasNoThreadsLeft() async throws {
        let dir = try TempDir()
        let git = try Fixture.git(in: dir, before: "sleep 30")
        let clock = ContinuousClock()

        let elapsed = try await withEveryDispatchThreadBusy {
            let start = clock.now
            do {
                try await git.run(["fetch"], in: dir.path, timeout: .milliseconds(300))
                Issue.record("expected a timeout")
            } catch let error as GitError {
                #expect(error.timedOut)
            }
            return clock.now - start
        }

        #expect(elapsed < .seconds(5))
    }
```

- [ ] **Step 3: Run it and watch it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter timeoutHoldsWhenDispatchHasNoThreadsLeft`
Expected: FAIL at the last line with `elapsed → 10.3 seconds`, since git's block waits for the busy blocks to time out.

- [ ] **Step 4: Add `onOwnThread`**

Create `Sources/CanopyCore/Support/OwnThread.swift`:

```swift
import Foundation

/// Runs `work` on a thread of its own, for work that blocks as long as a child process runs. Dispatch lends its global
/// queues a fixed number of threads, 64 on a small Mac. Once they all wait on children, every block queued there waits
/// too, and a timeout counted inside one starts late.
func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: work()) }.start()
    }
}
```

- [ ] **Step 5: Run git with it**

In `Sources/CanopyCore/Git/GitRunner.swift`, replace the body of `run` and its first doc line:

```swift
    /// Runs git on a thread of its own. With a timeout, git and everything it started are killed
    /// when it expires, and the error has `timedOut` set.
    @discardableResult
    public func run(_ arguments: [String], in directory: String? = nil, timeout: Duration? = nil) async throws
        -> String
    {
        try await onOwnThread { Result { try runBlocking(arguments, in: directory, timeout: timeout) } }.get()
    }
```

In `Sources/CanopyCore/Support/Subprocess.swift`, extend the doc comment of `run` so the next caller knows where to call it from:

```swift
    /// Runs a program in its own process group with stdin from /dev/null and no inherited descriptors,
    /// blocking the calling thread until it exits. On timeout the whole group is killed.
    /// Call it through `onOwnThread`, not on a Dispatch global queue, whose threads run out.
```

- [ ] **Step 6: Make the test helper `offPool` use it**

In `Tests/CanopyCoreTests/Support/Fixtures.swift`:

```swift
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await onOwnThread { Result { try work() } }.get()
}
```

- [ ] **Step 7: Run the git runner tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter GitRunnerTests`
Expected: all pass, `timeoutHoldsWhenDispatchHasNoThreadsLeft` in well under a second.

- [ ] **Step 8: Commit**

```bash
git add Sources/CanopyCore/Support/OwnThread.swift Sources/CanopyCore/Git/GitRunner.swift \
    Sources/CanopyCore/Support/Subprocess.swift Tests/CanopyCoreTests/Support/Fixtures.swift \
    Tests/CanopyCoreTests/GitRunnerTests.swift
git commit -m "fix: run git on a thread of its own so its timeout holds when Dispatch runs out of threads"
```

## Task 2: Look up pull requests and SSH aliases on a thread of their own

**Files:**
- Modify: `Sources/CanopyCore/PullRequests/GitHubCLI.swift`
- Test: `Tests/CanopyCoreTests/GitHubCLITests.swift`

**Interfaces:**
- Consumes: `onOwnThread` and `withEveryDispatchThreadBusy` from Task 1.

- [ ] **Step 1: Write the failing tests**

In `Tests/CanopyCoreTests/GitHubCLITests.swift`, after `stopsAHungGH`:

```swift
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
```

- [ ] **Step 2: Run them and watch them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter WhenDispatchHasNoThreadsLeft`
Expected: both GitHubCLI tests FAIL on `elapsed < .seconds(5)`, while their lookups still give the right answers.

- [ ] **Step 3: Use `onOwnThread` for both lookups**

In `Sources/CanopyCore/PullRequests/GitHubCLI.swift`:

```swift
    /// The GitHub repo behind a remote, following SSH host aliases the way git would.
    public func repo(forRemote url: String) async -> GitHubRepo? {
        let environment = environment ?? ProcessInfo.processInfo.environment
        return await onOwnThread {
            GitHubRepo(remoteURL: url) {
                SSHConfig.hostName(for: $0, configFile: sshConfigFile, environment: environment)
            }
        }
    }

    public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
        await onOwnThread { lookUpBlocking(repo: repo, branches: branches) }
    }
```

- [ ] **Step 4: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "GitHubCLITests|WhenDispatchHasNoThreadsLeft"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/PullRequests/GitHubCLI.swift Tests/CanopyCoreTests/GitHubCLITests.swift
git commit -m "fix: run gh and ssh lookups on a thread of their own"
```

## Task 3: The merge bar

- [ ] `make lint` and `make build` with 0 warnings.
- [ ] Three clean `make test` runs under the shared lock: `lockf -k /tmp/canopy-merge-bar.lock sh -c 'make test && make test && make test'`.
- [ ] `make e2e`.
- [ ] An independent opus reviewer on `git diff main...HEAD`, with findings fixed and listed under "After Review".
- [ ] CI `check` green, and its log shows `returnsStdout` and `timeoutKillsGitAndEverythingItStarted` finishing in seconds, with no long stall.
