import Testing

@testable import CanopyCore

struct GitRunnerTests {
    @Test func returnsStdout() async throws {
        let output = try await GitRunner().run(["--version"])
        #expect(output.hasPrefix("git version"))
    }

    @Test func throwsWithStderrOnFailure() async throws {
        let dir = try TempDir()
        do {
            try await GitRunner().run(["rev-parse", "HEAD"], in: dir.path)
            Issue.record("expected failure outside a repo")
        } catch let error as GitError {
            #expect(error.exitCode != 0)
            #expect(error.stderr.contains("not a git repository"))
        }
    }

    @Test func succeedsReportsExitStatus() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        #expect(await GitRunner().succeeds(["show-ref", "--verify", "--quiet", "refs/heads/main"], in: repo))
        #expect(!(await GitRunner().succeeds(["show-ref", "--verify", "--quiet", "refs/heads/nope"], in: repo)))
    }
}
