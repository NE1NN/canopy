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
