import Foundation
import Testing

@testable import CanopyCore

struct EnvironmentTests {
    @Test func gitEnvironmentUsesLoginPathAndDropsRepoOverrides() {
        let base = [
            "PATH": "/usr/bin:/bin", "HOME": "/h", "GIT_DIR": "/elsewhere/.git",
            "GIT_WORK_TREE": "/elsewhere", "GIT_INDEX_FILE": "/elsewhere/index",
        ]

        let environment = GitEnvironment.build(base: base, loginPath: "/opt/homebrew/bin:/usr/bin:/bin")

        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(environment["HOME"] == "/h")
        #expect(environment["GIT_DIR"] == nil)
        #expect(environment["GIT_WORK_TREE"] == nil)
        #expect(environment["GIT_INDEX_FILE"] == nil)
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["LC_ALL"] == "C")
    }

    @Test func gitEnvironmentKeepsInheritedPathWithoutALoginPath() {
        #expect(GitEnvironment.build(base: ["PATH": "/usr/bin"], loginPath: nil)["PATH"] == "/usr/bin")
    }

    @Test func loginPathComesFromTheShellEvenWithNoisyStartupFiles() throws {
        let dir = try TempDir()
        let shell = dir.sub("fake-shell")
        try "#!/bin/bash\necho 'welcome to your shell'\nexport PATH=/opt/fake/bin:/usr/bin:/bin\neval \"$2\"\n"
            .write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)

        #expect(ShellEnvironment.loginPath(shell: shell, timeout: .seconds(5)) == "/opt/fake/bin:/usr/bin:/bin")
    }

    @Test func slowShellGivesUpInsteadOfBlocking() throws {
        let dir = try TempDir()
        let shell = dir.sub("slow-shell")
        try "#!/bin/bash\nsleep 30\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
        let clock = ContinuousClock()
        let start = clock.now

        #expect(ShellEnvironment.loginPath(shell: shell, timeout: .milliseconds(300)) == nil)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func gitIgnoresAnInheritedGitDir() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let git = GitRunner(environment: ["PATH": "/usr/bin:/bin", "GIT_DIR": dir.sub("nowhere/.git")])

        let top = try await git.run(["rev-parse", "--show-toplevel"], in: repo)

        #expect(top.trimmingCharacters(in: .whitespacesAndNewlines) == repo)
    }
}
