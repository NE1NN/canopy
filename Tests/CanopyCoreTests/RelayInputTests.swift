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
}
