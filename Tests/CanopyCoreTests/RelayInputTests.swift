import Foundation
import Testing

@testable import CanopyCore

/// Which commands the host's relay sends standard input to. `RelayInputCommandsTests` checks the list against the
/// CLI's commands.
struct RelayInputTests {
    @Test func aCommandsWordsAreMatchedPastOptionsAndOthersReadNothing() {
        #expect(RelayInput.reading(["agent-hook"]) == .hookReport)
        #expect(RelayInput.reading(["ticket", "connect", "https://t.example", "--repo", "app"]) == .firstLine)
        #expect(RelayInput.reading(["ticket", "--json", "connect"]) == .firstLine)
        #expect(RelayInput.reading(["ticket", "list"]) == nil)
        #expect(RelayInput.reading(["term", "send", "p1", "agent-hook"]) == nil)
        #expect(RelayInput.reading([]) == nil)
    }

    /// The host's script holds the commands as a Python literal, where JSON's `\/` for a slash is an invalid escape
    /// that newer Pythons warn about.
    @Test func theCommandsLiteralIsPythonThatReadsBackAsTheCommands() async throws {
        let commands: [(words: [String], input: RelayInput)] = [
            (["web", "a/b"], .firstLine), (["agent-hook"], .hookReport),
        ]
        let literal = RelayInput.literal(of: commands)
        let program = "import json, sys\nprint(json.dumps(" + literal + "))"

        let result = try await offPool {
            try Subprocess.run(
                "/usr/bin/python3", ["-I", "-W", "error", "-c", program], environment: Fixture.environment,
                directory: nil, timeout: .seconds(30))
        }

        #expect(!literal.contains(#"\/"#))
        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        let read = try JSONSerialization.jsonObject(with: result.stdout) as? [[Any]]
        #expect(read?.map { $0[0] as? [String] } == commands.map(\.words))
        #expect(read?.map { $0[1] as? String } == commands.map(\.input.rawValue))
        #expect(RelayInput.literal == RelayInput.literal(of: RelayInput.commands))
    }

    /// Asking for a command's help prints it and reads nothing, however the command reads input otherwise.
    @Test func aCommandsHelpReadsNoInput() {
        #expect(RelayInput.reading(["ticket", "connect", "--help"]) == nil)
        #expect(RelayInput.reading(["ticket", "connect", "https://t.example", "-h"]) == nil)
        #expect(RelayInput.reading(["ticket", "--help-hidden", "connect"]) == nil)
        #expect(RelayInput.reading(["agent-hook", "--help"]) == nil)
        // After `--` it is an argument like any other.
        #expect(RelayInput.reading(["ticket", "connect", "--", "--help"]) == .firstLine)
    }
}
