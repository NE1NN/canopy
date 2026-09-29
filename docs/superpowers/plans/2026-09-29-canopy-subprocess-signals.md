# Default Signals for Canopy's Subprocesses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every program Canopy starts through `Subprocess.run` (git, gh, ssh, the login shell) starts with every signal at its default and none blocked, in a session of its own with no terminal, and no stand-in script in the tests waits for its test's release file for more than about a minute.

**Architecture:** `Subprocess.run` asks `posix_spawn` for an empty signal mask (`POSIX_SPAWN_SETSIGMASK`) and every signal at its default (`POSIX_SPAWN_SETSIGDEF`), as the pty child already does by hand after `forkpty`.
It also starts the child in a new session (`POSIX_SPAWN_SETSID`) rather than only a new process group, so the child has no controlling terminal to be stopped by.
The tests' stand-in scripts wait for a release file through one fixture helper, `Fixture.waitForFile`, which gives up after about 60 seconds by the shell's own clock.

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

Dispatch's worker threads block every signal in that list, and a thread inherits the mask of the thread that creates it, so the `Thread` that `onOwnThread` starts blocks them too.
`posix_spawn` hands the child the calling thread's mask unless `POSIX_SPAWN_SETSIGMASK` says otherwise, and `Subprocess.run` never said.
So every git, gh, and ssh Canopy started, and everything they started in turn (hooks, credential helpers, `sleep` in a stand-in), held SIGTERM, SIGINT, and SIGHUP pending and ran on.
`ps -o blocked` on macOS shows 0 for such a process, so only an in-process probe shows the mask.

A disposition of `SIG_IGN` survives `exec` too.
The app started from Finder ignores no signal, but one that `scripts/e2e.sh` or `scripts/ui-fixture.sh` starts as a background job of a script ignores SIGINT and SIGQUIT, and every child inherited that.
The pty child resets both after `forkpty`, and Foundation's `Process`, which the CLI uses to run `open` and some tests use, resets both too: a probe run through it from a Dispatch thread, with SIGPIPE ignored in the parent, showed nothing blocked or ignored.
`Subprocess.run` is the only spawn path with the gap.

The stand-ins could loop forever because their waits had no limit: `while [[ ! -f release ]]; do sleep 0.05; done`.
Once the test process died, nothing would ever create the file, and `Subprocess` starts each child in a process group of its own, so nothing signalled it either.
Five tests wait that way: `CloneTests.cancellingAQueuedCloneLeavesTheOneAheadAlone`, `GroupRowCreationTests.stalledSetUp`, `PullRequestWorkspaceTests.anAnswerForARepoRemovedMeanwhileIsDropped`, `RowActivityTests.aRowCanopyIsStillCreatingIsLoggedOnceItIsDone`, and `WatcherLifetimeTests.removingARepoWhileItIsBeingAddedLeavesNoWatcher`.
`CloneTests.aCloneDoesNotWaitBehindTheRepositorysOtherGitWork` already counts 1200 rounds, which is at least 60 seconds but more under load.
Plain `sleep 60` and `sleep 120` stand-ins, as in `GitRunnerTests` and `PortStopperTests`, end by themselves and stay as they are.

### Why a session of its own

The review found that default signals alone broke a dev app started from a terminal, as `make e2e` and `scripts/ui-fixture.sh` start it when a person runs them.
Such an app has that terminal as its controlling terminal, and each child ran in a background process group of it.
The first git or gh works out the user's login PATH with `zsh -ilc`, and an interactive zsh takes the terminal's foreground with `tcsetpgrp`.
From a background group that raises SIGTTOU, which stops the shell by default, so the lookup timed out after 5 seconds, the app used the plain PATH, and the e2e clone steps reached the real `gh`.
With SIGTTOU blocked, as on `main`, the call went through instead, and the login shell took the terminal's foreground away from the shell that started the app.
The same probe under `script`, which gives it a terminal, showed all three:

| Spawn flags | `zsh -ilc` in the child | The terminal's foreground afterwards |
|---|---|---|
| `main`: own process group, inherited mask | exits 0 | the dead zsh's group |
| Own process group, default signals | stopped by SIGTTOU | the starting shell |
| Own session, default signals | exits 0 | the starting shell |

A session of its own has no controlling terminal, so no terminal signal can stop the child and it cannot take over anyone's terminal.
It also leads its own process group, so `kill(-pid, SIGKILL)` still ends the child and everything it started.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings, including `swift build --build-tests`.
- `make lint` passes `swift format lint --strict`.
- A test must not leave process-wide state changed once it returns, even while other tests run alongside it.

## Review Focus

1. A child started from the main thread, whose mask is already empty, still starts and runs as before.
   Pinned by every existing `GitRunnerTests` and `GitHubCLITests` test.
2. `sigfillset` puts SIGKILL and SIGSTOP in the default set, which no process can change; `posix_spawn` must still accept it.
   Pinned by every test that runs git, since each spawn would fail with EINVAL otherwise.
3. Timeouts and cancellation still kill the child and everything it started.
   Pinned by `GitRunnerTests.timeoutKillsGitAndEverythingItStarted` and `GitHubCLITests`' cancel tests.
4. A dev app started from a terminal still works out the login PATH, and leaves that terminal alone.
   Pinned by `aChildRunsInASessionOfItsOwn` in Task 1, and checked end to end by running `scripts/e2e.sh` under `script`.
5. A stand-in whose file appears goes on at once, not after the limit.
   Pinned by `aStandInGoesOnOnceItsFileAppears` in Task 2.

## Decisions to Review

- A stand-in gives up after about 60 seconds, counted with bash's `SECONDS`, which follows the wall clock in whole seconds.
  Counting rounds of `sleep 0.05` instead takes longer the busier the machine is.
- A stand-in that gives up goes on as if released, as the existing counted loop does, rather than failing.
  A live test that waited that long fails on its own expectations anyway.
- The ignored-signal test ignores SIGUSR2 in the whole test process while it runs, and puts the old disposition back after.
  No other test touches SIGUSR2, so no other test can save and restore it in between.
- A child no longer shares the app's terminal, if the app has one.
  An ssh passphrase or git credential prompt on `/dev/tty` now fails at once, where it could stop or take over the terminal before; stdin was already `/dev/null`, and the release app, started by launchd, never had a terminal.

---

## Task 1: Children start with default signals, in a session of their own

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
    /// and gh on. A child inherited that mask, so git and gh held SIGTERM, SIGINT, and SIGHUP pending and ran on.
    @Test func aChildEndsOnSIGTERMWhenStartedFromAThreadThatBlocksSignals() async throws {
        let dir = try TempDir()
        var every = sigset_t()
        sigfillset(&every)
        let sleeper = Sleeper(in: dir, mask: every)
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGTERM)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    /// An ignored signal stays ignored across exec, so a child would inherit any the app ignores, like the SIGINT and
    /// SIGQUIT a script's background job starts with. SIGUSR2 stands in for them, since no other test touches it.
    @Test func aChildDoesNotIgnoreASignalThisProcessIgnores() async throws {
        let dir = try TempDir()
        let previous = signal(SIGUSR2, SIG_IGN)
        defer { signal(SIGUSR2, previous) }
        let sleeper = Sleeper(in: dir, mask: sigset_t())
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGUSR2)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGUSR2)
    }

    /// In a background group of the terminal the app was started from, a child with default signals stopped as soon as
    /// it touched that terminal, as an interactive login shell does. In a session of its own it has no terminal at all.
    @Test func aChildRunsInASessionOfItsOwn() async throws {
        let dir = try TempDir()
        let sleeper = Sleeper(in: dir)
        let pid = try #require(await sleeper.pid())

        #expect(getsid(pid) == pid)
        #expect(getpgid(pid) == pid)
        kill(pid, SIGKILL)
        _ = try await sleeper.result.value
    }
}

/// A `sleep 60` started through `Subprocess.run` on a thread of its own, which sets `mask` in place of the one it
/// inherited. It writes its pid to a file first, since `Subprocess.run` returns only once it exits.
private struct Sleeper {
    let pidFile: String
    let result: Task<SubprocessResult, any Error>

    init(in dir: TempDir, mask: sigset_t = sigset_t()) {
        let pidFile = dir.sub("sleeper.pid")
        self.pidFile = pidFile
        result = Task {
            try await offPool {
                var mask = mask
                pthread_sigmask(SIG_SETMASK, &mask, nil)
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

Each test pins one flag: the SIGTERM test sets a full mask on its thread, so only `POSIX_SPAWN_SETSIGMASK` can let the signal through; the SIGUSR2 test sets an empty one, so only `POSIX_SPAWN_SETSIGDEF` matters.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test $(scripts/test-flags.sh) --filter SubprocessTests`
Expected: the two signal tests FAIL after the 20 second timeout, with `result.timedOut` true and `result.status == 137`, since the sleeper never saw the signal.
`aChildRunsInASessionOfItsOwn` FAILS at once, with `getsid(pid)` the test process's session.

- [ ] **Step 3: Start every child with an empty mask, default dispositions, and a session of its own**

In `Subprocess.run`, replace the `setflags` and `setpgroup` lines:

```swift
        // Dispatch's threads, and threads they start, block most signals, a child inherits the caller's mask, and an
        // ignored signal stays ignored across exec. With its signals back at their defaults, a child in a background
        // group of a terminal the app was started from would stop the moment it touched that terminal, so it gets a
        // session of its own, which has no terminal.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var every = sigset_t()
        sigfillset(&every)
        posix_spawnattr_setsigdefault(&attributes, &every)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
```

`POSIX_SPAWN_SETSID` replaces `POSIX_SPAWN_SETPGROUP` rather than joining it: `setsid` fails for a process that already leads a group.
Say so in the doc comment:

```swift
    /// Runs a program in a session of its own, with no controlling terminal, stdin from /dev/null, no inherited
    /// descriptors, and every signal unblocked and at its default, blocking the calling thread until it exits.
    /// On timeout the session's process group, the child and everything it started, is killed.
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test $(scripts/test-flags.sh) --filter SubprocessTests`
Expected: all three PASS within a second.

- [ ] **Step 5: Check each flag against its test**

Copy `Subprocess.swift` into the scratchpad, drop `POSIX_SPAWN_SETSIGDEF`, and run the suite: only `aChildDoesNotIgnoreASignalThisProcessIgnores` fails.
Put the copy back, drop `POSIX_SPAWN_SETSIGMASK`, and run it again: only `aChildEndsOnSIGTERMWhenStartedFromAThreadThatBlocksSignals` fails.
Put the copy back.

- [ ] **Step 6: Check a dev app started from a terminal**

Run: `make app`, then `(sleep 900) | script -q /tmp/e2e.log bash -c 'scripts/e2e.sh; echo "e2e exit $?"'`
Expected: `e2e passed`, and the terminal's foreground group, `ps -o tpgid= -p $$`, is the same before and after.
With own-group spawning and default signals, the clone step fails with the real `gh`'s "Could not resolve to a Repository".

- [ ] **Step 7: Commit**

```bash
git add Sources/CanopyCore/Support/Subprocess.swift Tests/CanopyCoreTests/SubprocessTests.swift
git commit -m "fix: start git and gh with every signal unblocked and at its default"
```

## Task 2: Stand-in scripts give up waiting after about a minute

**Files:**
- Modify: `Tests/CanopyCoreTests/Support/Fixtures.swift` (add `waitForFile`)
- Create: `Tests/CanopyCoreTests/StandInWaitTests.swift`
- Modify: `Tests/CanopyCoreTests/CloneTests.swift`, `WorkspaceGroupTests.swift`, `PullRequestWorkspaceTests.swift`, `RowActivityTests.swift`, `WatchTests.swift`

**Interfaces:**
- Produces: `Fixture.waitForFile(_ path: String, seconds: Int = 60) -> String`, two lines of bash.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyCore

/// A stand-in script that waits for its test to create a file must not poll forever once that test has died.
struct StandInWaitTests {
    static func run(_ script: String) async throws -> SubprocessResult {
        try await offPool {
            try Subprocess.run("/bin/bash", ["-c", script], environment: [:], directory: nil, timeout: .seconds(20))
        }
    }

    @Test func aStandInGivesUpWaitingOnceTheLimitPasses() async throws {
        let dir = try TempDir()
        let result = try await Self.run(Fixture.waitForFile(dir.sub("never"), seconds: 1) + "\necho went-on")

        #expect(!result.timedOut)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
    }

    @Test func aStandInGoesOnOnceItsFileAppears() async throws {
        let dir = try TempDir()
        let (waiting, go) = (dir.sub("waiting"), dir.sub("go"))
        let script = "touch '\(waiting)'\n" + Fixture.waitForFile(go) + "\necho went-on"
        let running = Task { try await Self.run(script) }
        #expect(await eventually { FileManager.default.fileExists(atPath: waiting) })
        let clock = ContinuousClock()
        let start = clock.now

        FileManager.default.createFile(atPath: go, contents: nil)
        let result = try await running.value

        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
        #expect(clock.now - start < .seconds(10))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift build --build-tests`
Expected: FAIL to compile with "type 'Fixture' has no member 'waitForFile'".
Then give the helper the old unbounded loop, `while [[ ! -e '\(path)' ]]; do sleep 0.05; done`, and run `StandInWaitTests`: `aStandInGivesUpWaitingOnceTheLimitPasses` FAILS on the 20 second timeout.

- [ ] **Step 3: Add the helper**

In `Fixture`:

```swift
    /// Bash lines for a stand-in script that holds until the test creates `path`. It gives up and goes on after about
    /// `seconds`, as bash counts whole seconds, so a stand-in whose test was killed ends by itself.
    static func waitForFile(_ path: String, seconds: Int = 60) -> String {
        "stand_in_deadline=$((SECONDS + \(seconds)))\n"
            + "until [[ -e '\(path)' ]] || ((SECONDS >= stand_in_deadline)); do sleep 0.05; done"
    }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test $(scripts/test-flags.sh) --filter StandInWaitTests`
Expected: both PASS, the first within a second.

- [ ] **Step 5: Move every stand-in wait onto the helper**

- `CloneTests.cancellingAQueuedCloneLeavesTheOneAheadAlone`: `before: "touch '\(started)'\n" + Fixture.waitForFile(go)`.
- `CloneTests.aCloneDoesNotWaitBehindTheRepositorysOtherGitWork`: the `for _ in $(seq 1 1200)` loop becomes `\#(Fixture.waitForFile(release))`.
- `GroupRowCreationTests.stalledSetUp`: `let wait = Fixture.waitForFile(dir.sub("go"))`.
- `PullRequestWorkspaceTests.anAnswerForARepoRemovedMeanwhileIsDropped`: the `while` line becomes `\(Fixture.waitForFile(release))`.
- `RowActivityTests.aRowCanopyIsStillCreatingIsLoggedOnceItIsDone`: git waits for a `resume` file instead of for `paused` to go away, and the test creates `resume` where it removed `paused`.
- `WatcherLifetimeTests.removingARepoWhileItIsBeingAddedLeavesNoWatcher`: the one-line `if` becomes a block with `touch "\(started)"` and `\(Fixture.waitForFile(release))`.

Then check none is left:

Run: `grep -rnE '(while|until|for) .*sleep' Tests scripts | grep -v stand_in_deadline`
Expected: only Swift loops with their own deadline, and the e2e listener's `sleep 300`.

- [ ] **Step 6: Run the touched suites**

Run: `swift test $(scripts/test-flags.sh) --filter 'CloneTests|GroupRowCreationTests|PullRequestWorkspaceTests|RowActivityTests|WatcherLifetimeTests|StandInWaitTests'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Tests
git commit -m "test: bound every stand-in script's wait with one fixture helper"
```

## After Review

An independent reviewer read `git diff main...HEAD` with this plan.

1. **Bug: a dev app started from a terminal lost its login PATH.**
   Default signals let SIGTTOU stop the login shell that works out the PATH, as "Why a session of its own" above describes.
   Reproduced by running `scripts/e2e.sh` under `script`: it failed at the clone step.
   Fixed by starting each child in a session of its own, pinned by `aChildRunsInASessionOfItsOwn`, and the same run now passes with the terminal's foreground left alone.
   On `main` the shell did not stop, but it took the terminal's foreground from the shell that started the app, which this also fixes.
2. **Should-fix: two tests saved and restored SIGPIPE at once.**
   `PtyProcessTests` ignores SIGPIPE the same way, and Swift Testing can run both together, so one could restore the other's "ignored" and leave SIGPIPE ignored for the rest of the run.
   The test now uses SIGUSR2, which no other test touches, and sets an empty mask on its thread, so it pins `POSIX_SPAWN_SETSIGDEF` alone.
3. **Nits: claims in the plan and PR.**
   Terminal signals never reached these children, since they always ran in a group of their own, so only an explicit `kill` is fixed.
   Dispatch blocks the signals in the table, not every signal: SEGV, BUS, ILL, FPE, TRAP, SYS, PIPE, and PROF stay unblocked.
   The dev app that `scripts/e2e.sh` and `scripts/ui-fixture.sh` start ignores SIGINT and SIGQUIT, so `POSIX_SPAWN_SETSIGDEF` fixes a live case.
   The goal now covers only the waits for a release file, since plain `sleep 60` and `sleep 120` stand-ins still run to their end.
   Corrected above and in the PR.
4. **Nit: `limit.components.seconds` truncated a `Duration`,** so half a second gave up at once.
   `waitForFile` now takes whole `seconds`, and says the wait is about that long.
5. **Nit: `aStandInGoesOnOnceItsFileExists` created the file before bash started,** so the loop never ran.
   Renamed `aStandInGoesOnOnceItsFileAppears`, it now creates the file once the script has signalled that it is waiting.
6. **Nits: wording.**
   The spawn comment now says why dispositions are reset too, the SIGTERM test says the signals were held pending rather than ignored, and the `Sleeper` doc says its thread sets the mask in place of the inherited one.

The reviewer checked and found fine: the flag values fit `Int16`, a full default set is accepted, Foundation's `Process` and the pty child need no change, no unbounded stand-in wait is left, the bash works in macOS's bash 3.2, and `RowActivityTests` still tests the same thing.
