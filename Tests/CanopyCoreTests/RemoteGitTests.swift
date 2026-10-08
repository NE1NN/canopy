import Foundation
import Testing

@testable import CanopyCore

struct RemoteGitTests {
    @Test func gitRunsInAFolderOnTheHost() async throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        let clone = try await Fixture.repo(in: dir, name: "host-box/my clone")

        let top = try await host.git.run(["rev-parse", "--show-toplevel"], in: clone)

        #expect(top.trimmingCharacters(in: .newlines) == clone)
    }

    @Test func gitFailuresOnTheHostKeepGitsMessage() async throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)

        do {
            try await host.git.run(["rev-parse", "HEAD"], in: host.home)
            Issue.record("expected git to fail outside a repo")
        } catch let error as GitError {
            #expect(!error.hostUnreachable)
            #expect(error.stderr.contains("not a git repository"))
        }
    }

    @Test func aHostThatCannotBeReachedSaysSo() async throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir, down: true)

        do {
            try await host.git.run(["status"], in: host.home)
            Issue.record("expected the host to be unreachable")
        } catch let error as GitError {
            #expect(error.hostUnreachable)
            #expect(error.stderr.contains("Connection closed"))
        }
    }
}
