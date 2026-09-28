# Default Signals for Canopy's Subprocesses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every program Canopy starts through `Subprocess.run` (git, gh, ssh, the login shell) starts with every signal at its default and none blocked, and no stand-in script in the tests can outlive its test by more than a minute.

**Architecture:** `Subprocess.run` asks `posix_spawn` for an empty signal mask (`POSIX_SPAWN_SETSIGMASK`) and every signal at its default (`POSIX_SPAWN_SETSIGDEF`), as the pty child already does by hand after `forkpty`.
The tests' stand-in scripts wait for a release file through one fixture helper, `Fixture.waitForFile`, which gives up after 60 seconds by the shell's own clock.

**Tech Stack:** Swift 6.2, Darwin `posix_spawn`, bash 3.2, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Git operations".

## Root Cause

On 2026-09-29 two stand-in `gh` scripts from killed test runs were still polling for their release file, one for 9.5 hours, and `kill` did nothing to them.
A probe that prints its own blocked and ignored signals (`sigprocmask` and `sigaction` for each signal) showed why:

| Where `Subprocess.run` was called | Signals blocked in the child |
|---|---|
| The main thread | none |
| A Dispatch global queue | HUP INT QUIT ABRT ALRM TERM URG TSTP CONT CHLD TTIN TTOU IO XCPU XFSZ VTALRM WINCH INFO USR1 USR2 |
| A Swift concurrency task | the same |
| `onOwnThread` from a task, as git and gh run | the same |
| A `post-checkout` hook of the git the dev app ran for `canopy row new` | the same, less CHLD |

A child spawned that way and sent SIGTERM kept running to the end of its sleep, in a standalone harness and as the hook of the dev app's own git.

Dispatch's worker threads block every signal they can, and a thread inherits the mask of the thread that creates it, so the `Thread` that `onOwnThread` starts blocks them too.
`posix_spawn` hands the child the calling thread's mask unless `POSIX_SPAWN_SETSIGMASK` says otherwise, and `Subprocess.run` never said.
So every git, gh, and ssh Canopy started, and everything they started in turn (hooks, credential helpers, `sleep` in a stand-in), ignored SIGTERM, SIGINT, and SIGHUP.
A signal a blocked process ignores stays pending, and `ps -o blocked` on macOS still shows 0, so only an in-process probe shows it.

The app ignores no signal today, but a disposition of `SIG_IGN` survives `exec`, so one added later (SIGPIPE is the usual one) would reach every child as well.
The pty child resets both after `forkpty`, and Foundation's `Process`, which the CLI uses to run `open` and some tests use, resets both too: a probe run through it from a Dispatch thread, with SIGPIPE ignored in the parent, showed nothing blocked or ignored.
`Subprocess.run` is the only spawn path with the gap.

The stand-ins could loop forever because their waits had no limit: `while [[ ! -f release ]]; do sleep 0.05; done`.
Once the test process died, nothing would ever create the file, and `Subprocess` starts each child in its own process group, so nothing signalled it either.
Five tests wait that way: `CloneTests.cancellingAQueuedCloneLeavesTheOneAheadAlone`, `GroupRowCreationTests.stalledSetUp`, `PullRequestWorkspaceTests.anAnswerForARepoRemovedMeanwhileIsDropped`, `RowActivityTests.aRowCanopyIsStillCreatingIsLoggedOnceItIsDone`, and `WatcherLifetimeTests.removingARepoWhileItIsBeingAddedLeavesNoWatcher`.
`CloneTests.aCloneDoesNotWaitBehindTheRepositorysOtherGitWork` already counts 1200 rounds, which is at least 60 seconds but more under load.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings, including `swift build --build-tests`.
- `make lint` passes `swift format lint --strict`.
- A test must not leave process-wide state changed once it returns.

## Review Focus

1. A child started from the main thread, whose mask is already empty, still starts and runs as before.
   Pinned by every existing `GitRunnerTests` and `GitHubCLITests` test.
2. `sigfillset` puts SIGKILL and SIGSTOP in the default set, which no process can change; `posix_spawn` must still accept it.
   Pinned by every test that runs git, since each spawn would fail with EINVAL otherwise.
3. Timeouts and cancellation still kill the child and everything it started.
   Pinned by `GitRunnerTests.timeoutKillsGitAndEverythingItStarted` and `GitHubCLITests`' cancel tests.
4. A stand-in whose file appears goes on at once, not after the limit.
   Pinned by `aStandInGoesOnOnceItsFileExists` in Task 2.
5. A stand-in path with a space or a quote.
   Every stand-in path is a `TempDir` path, which has neither, and the helper quotes it as the old loops did.

## Decisions to Review

- A stand-in gives up after 60 seconds, counted with bash's `SECONDS`, which follows the wall clock in whole seconds.
  Counting rounds of `sleep 0.05` instead takes longer the busier the machine is.
- A stand-in that gives up goes on as if released, as the existing counted loop does, rather than failing.
  A live test that waited that long fails on its own expectations anyway.
- The SIGPIPE test ignores SIGPIPE in the whole test process while it runs and puts the old disposition back after.
  Ignoring SIGPIPE can only keep a process alive that would have died, so tests running alongside are unaffected.

---

## Task 1: Children start with default signals and none blocked

**Files:**
- Modify: `Sources/CanopyCore/Support/Subprocess.swift` (`run`)
- Create: `Tests/CanopyCoreTests/SubprocessTests.swift`

**Interfaces:**
- Produces: no new API. `Subprocess.run` keeps its signature.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyCore

struct SubprocessTests {
    /// Dispatch's threads block most signals, and so does every thread they start, like the one `onOwnThread` runs git
    /// and gh on. A child inherited that mask, so git and gh ignored SIGTERM, SIGINT, and SIGHUP.
    @Test func aChildEndsOnSIGTERMWhenStartedFromAThreadThatBlocksSignals() async throws {
        let dir = try TempDir()
        var every = sigset_t()
        sigfillset(&every)
        let sleeper = Sleeper(in: dir, blocking: every)
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGTERM)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    /// An ignored signal stays ignored across exec, so a child would inherit any the app ignores.
    @Test func aChildDoesNotIgnoreASignalThisProcessIgnores() async throws {
        let dir = try TempDir()
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let sleeper = Sleeper(in: dir)
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGPIPE)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGPIPE)
    }
}

/// A `sleep 60` started through `Subprocess.run` on a thread of its own that blocks `signals`. It writes its pid to a
/// file first, since `Subprocess.run` returns only once it exits.
private struct Sleeper {
    let pidFile: String
    let result: Task<SubprocessResult, any Error>

    init(in dir: TempDir, blocking signals: sigset_t = sigset_t()) {
        let pidFile = dir.sub("sleeper.pid")
        self.pidFile = pidFile
        result = Task {
            try await offPool {
                var mask = signals
                pthread_sigmask(SIG_BLOCK, &mask, nil)
                return try Subprocess.run(
                    "/bin/bash", ["-c", "echo $$ > '\(pidFile)'; exec /bin/sleep 60"], environment: [:],
                    directory: nil, timeout: .seconds(20))
            }
        }
    }

    func pid() async -> pid_t? {
        var pid: pid_t?
        _ = await eventually {
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return pid
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test $(scripts/test-flags.sh) --filter SubprocessTests`
Expected: both FAIL after the 20 second timeout, with `result.timedOut` true and `result.status == 137`, since the sleeper never saw the signal.

- [ ] **Step 3: Start every child with an empty mask and default dispositions**

In `Subprocess.run`, replace the `setflags` line:

```swift
        // Dispatch's threads, and threads they start, block most signals, and a child inherits the caller's mask.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var every = sigset_t()
        sigfillset(&every)
        posix_spawnattr_setsigdefault(&attributes, &every)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
```

And say so in its doc comment: "Runs a program in its own process group with stdin from /dev/null, no inherited descriptors, and every signal unblocked and at its default, ...".

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test $(scripts/test-flags.sh) --filter SubprocessTests`
Expected: both PASS within a second or two.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Support/Subprocess.swift Tests/CanopyCoreTests/SubprocessTests.swift
git commit -m "fix: start git and gh with every signal unblocked and at its default"
```

## Task 2: Stand-in scripts give up waiting after a minute

**Files:**
- Modify: `Tests/CanopyCoreTests/Support/Fixtures.swift` (add `waitForFile`)
- Create: `Tests/CanopyCoreTests/StandInWaitTests.swift`
- Modify: `Tests/CanopyCoreTests/CloneTests.swift`, `WorkspaceGroupTests.swift`, `PullRequestWorkspaceTests.swift`, `RowActivityTests.swift`, `WatchTests.swift`

**Interfaces:**
- Produces: `Fixture.waitForFile(_ path: String, limit: Duration = .seconds(60)) -> String`, one bash line.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyCore

/// A stand-in script that waits for its test to create a file must not poll forever once that test has died.
struct StandInWaitTests {
    func run(_ script: String) async throws -> SubprocessResult {
        try await offPool {
            try Subprocess.run("/bin/bash", ["-c", script], environment: [:], directory: nil, timeout: .seconds(20))
        }
    }

    @Test func aStandInGivesUpWaitingOnceTheLimitPasses() async throws {
        let dir = try TempDir()
        let result = try await run(Fixture.waitForFile(dir.sub("never"), limit: .seconds(1)) + "\necho went-on")

        #expect(!result.timedOut)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
    }

    @Test func aStandInGoesOnOnceItsFileExists() async throws {
        let dir = try TempDir()
        FileManager.default.createFile(atPath: dir.sub("go"), contents: nil)
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await run(Fixture.waitForFile(dir.sub("go")) + "\necho went-on")

        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
        #expect(clock.now - start < .seconds(10))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift build --build-tests`
Expected: FAIL to compile with "type 'Fixture' has no member 'waitForFile'".

- [ ] **Step 3: Add the helper**

In `Fixture`:

```swift
    /// A bash line for a stand-in script that holds until the test creates `path`. It gives up after `limit` and goes
    /// on, so a stand-in whose test was killed ends by itself rather than polling forever.
    static func waitForFile(_ path: String, limit: Duration = .seconds(60)) -> String {
        "stand_in_deadline=$((SECONDS + \(limit.components.seconds)))\n"
            + "until [[ -e '\(path)' ]] || ((SECONDS >= stand_in_deadline)); do sleep 0.05; done"
    }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test $(scripts/test-flags.sh) --filter StandInWaitTests`
Expected: both PASS, the first in about a second.

- [ ] **Step 5: Move every stand-in wait onto the helper**

- `CloneTests.cancellingAQueuedCloneLeavesTheOneAheadAlone`: `before: "touch '\(started)'\n" + Fixture.waitForFile(go)`.
- `CloneTests.aCloneDoesNotWaitBehindTheRepositorysOtherGitWork`: the `for _ in $(seq 1 1200)` loop becomes `\#(Fixture.waitForFile(release))`.
- `GroupRowCreationTests.stalledSetUp`: `let wait = Fixture.waitForFile(dir.sub("go"))`.
- `PullRequestWorkspaceTests.anAnswerForARepoRemovedMeanwhileIsDropped`: the `while` line becomes `\(Fixture.waitForFile(release))`.
- `RowActivityTests.aRowCanopyIsStillCreatingIsLoggedOnceItIsDone`: git waits for a `resume` file instead of for `paused` to go away, and the test creates `resume` where it removed `paused`.
- `WatcherLifetimeTests.removingARepoWhileItIsBeingAddedLeavesNoWatcher`: the one-line `if` becomes a block with `touch "\(started)"` and `\(Fixture.waitForFile(release))`.

Then check none is left:

Run: `grep -rnE '(while|until) .*sleep' Tests scripts | grep -v waitForFile`
Expected: no output other than the helper itself.

- [ ] **Step 6: Run the touched suites**

Run: `swift test $(scripts/test-flags.sh) --filter 'CloneTests|GroupRowCreationTests|PullRequestWorkspaceTests|RowActivityTests|WatcherLifetimeTests|StandInWaitTests'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Tests
git commit -m "test: bound every stand-in script's wait with one fixture helper"
```
