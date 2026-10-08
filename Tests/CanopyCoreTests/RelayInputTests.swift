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
