import Foundation
import Testing

@testable import CanopyCore

struct GitRunnerTests {
    @Test func returnsStdout() async throws {
        let output = try await Fixture.git.run(["--version"])
        #expect(output.hasPrefix("git version"))
    }

    @Test func throwsWithStderrOnFailure() async throws {
        let dir = try TempDir()
        do {
            try await Fixture.git.run(["rev-parse", "HEAD"], in: dir.path)
            Issue.record("expected failure outside a repo")
        } catch let error as GitError {
            #expect(error.exitCode != 0)
            #expect(error.stderr.contains("not a git repository"))
        }
    }

    @Test func succeedsReportsExitStatus() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        #expect(await Fixture.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/main"], in: repo))
        #expect(!(await Fixture.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/nope"], in: repo)))
    }

    @Test func timeoutKillsGitAndEverythingItStarted() async throws {
        let dir = try TempDir()
        // The backgrounded sleep keeps stdout open, like an ssh child of a stalled fetch.
        let git = try Fixture.git(in: dir, before: "sleep 30 &\nsleep 30")
        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await git.run(["fetch"], timeout: .milliseconds(300))
            Issue.record("expected a timeout")
        } catch let error as GitError {
            #expect(error.timedOut)
        }

        // Well short of the 30 s sleep, with room for a loaded Mac to kill and reap the processes.
        #expect(clock.now - start < .seconds(20))
    }

    /// On CI, dozens of tests running git at once took every thread Dispatch lends, and a run that queued for one
    /// started its timeout late.
    @Test func timeoutHoldsWhenDispatchHasNoThreadsLeft() async throws {
        let dir = try TempDir()
        let git = try Fixture.git(in: dir, before: "sleep 30")

        let onTime = try await withEveryDispatchThreadBusy { isHolding in
            do {
                try await git.run(["fetch"], in: dir.path, timeout: .milliseconds(300))
                Issue.record("expected a timeout")
            } catch let error as GitError {
                #expect(error.timedOut)
            }
            return isHolding()
        }

        #expect(onTime, "the timeout waited for Dispatch to have a thread")
    }

    /// Through the /usr/bin/git shim, each test's git asked xcrun, which started xcodebuild on a fresh CI runner.
    @Test func testsRunGitWithoutTheShim() {
        #expect(Fixture.gitPath != "/usr/bin/git")
        #expect(FileManager.default.isExecutableFile(atPath: Fixture.gitPath))
    }

    @Test func noTimeoutByDefault() async throws {
        let dir = try TempDir()
        let git = try Fixture.git(in: dir, before: "sleep 0.5")
        #expect(try await git.run(["--version"]).hasPrefix("git version"))
    }

    @Test func aHandleStopsGitAndEverythingItStarted() async throws {
        let dir = try TempDir()
        let background = dir.sub("background.pid")
        // Renamed into place, so the test never reads it before the pid is in it.
        let git = try Fixture.git(
            in: dir,
            before: "sleep 60 &\necho $! > '\(background).tmp'\nmv '\(background).tmp' '\(background)'\nsleep 60")
        let handle = SubprocessHandle()

        let run = Task { try await git.run(["clone"], handle: handle) }
        #expect(await eventually { FileManager.default.fileExists(atPath: background) })
        // Timed from the cancel: a loaded CI runner can take many seconds just to start bash.
        let clock = ContinuousClock()
        let start = clock.now
        handle.cancel()

        await #expect(throws: GitError.self) { try await run.value }
        #expect(handle.isCancelled)
        #expect(clock.now - start < .seconds(30))
        let pid = try #require(
            Int32(String(contentsOfFile: background, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
    }

    @Test func aHandleCancelledFirstStopsGitAsItStarts() async throws {
        let dir = try TempDir()
        let git = try Fixture.git(in: dir, before: "sleep 60")
        let handle = SubprocessHandle()
        handle.cancel()
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: GitError.self) { try await git.run(["clone"], handle: handle) }

        // Well short of the sleep, with room for a loaded CI runner to start the process.
        #expect(clock.now - start < .seconds(30))
    }

    @Test func aHandleReadsWhatGitWroteToStderrSoFar() async throws {
        let dir = try TempDir()
        let git = try Fixture.git(in: dir, before: "echo 'Receiving objects:  50% (1/2)' >&2\nsleep 30")
        let handle = SubprocessHandle()

        let run = Task { try await git.run(["clone"], handle: handle) }
        let seen = await eventually {
            String(decoding: handle.errorOutput(), as: UTF8.self).contains("Receiving objects:  50%")
        }
        let wasRunning = handle.isRunning
        handle.cancel()
        _ = try? await run.value

        #expect(seen)
        #expect(wasRunning)
        #expect(!handle.isRunning)
        #expect(handle.errorOutput().isEmpty)
    }

}
