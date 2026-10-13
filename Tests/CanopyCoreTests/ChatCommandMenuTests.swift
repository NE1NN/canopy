import Foundation
import Testing

@testable import CanopyCore

struct ChatCommandMenuTests {
    let commands = [
        ClaudeCommand(name: "compact", description: "Clear history but keep a summary", argumentHint: ""),
        ClaudeCommand(name: "ship-pr", description: "Ship it (user)", argumentHint: ""),
        ClaudeCommand(name: "rewind", description: "Go back", argumentHint: ""),
        ClaudeCommand(name: "color", description: "Pick a color", argumentHint: ""),
        ClaudeCommand(name: "superpowers:brainstorming", description: "Ideas", argumentHint: ""),
    ]

    @Test func commandsComeBeforeSkillsAndFullScreenOnesOpenInATerminal() {
        let items = ChatCommandMenu.items(commands: commands, terminal: ["color"], typed: "")

        #expect(items.map(\.name) == ["color", "compact", "rewind", "ship-pr", "superpowers:brainstorming"])
        #expect(items.filter(\.opensInTerminal).map(\.name) == ["color", "rewind"])
        #expect(items.filter(\.isSkill).map(\.name) == ["ship-pr", "superpowers:brainstorming"])
    }

    @Test func filtersByWhatWasTypedWithPrefixesFirst() {
        let items = ChatCommandMenu.items(commands: commands, terminal: [], typed: "co")

        #expect(items.map(\.name) == ["color", "compact"])
    }
}
