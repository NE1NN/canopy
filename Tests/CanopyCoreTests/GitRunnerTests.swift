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

        #expect(clock.now - start < .seconds(5))
    }

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

    @Test func noTimeoutByDefault() async throws {
        let dir = try TempDir()
        let git = try Fixture.git(in: dir, before: "sleep 0.5")
        #expect(try await git.run(["--version"]).hasPrefix("git version"))
    }
}
