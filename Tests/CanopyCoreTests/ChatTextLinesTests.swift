import Foundation
import Testing

@testable import CanopyCore

struct ChatTextLinesTests {
    private func lines(_ markdown: String) -> [ChatTextLine] {
        ChatMarkdown.parse(markdown).flatMap(ChatTextLines.lines)
    }

    @Test func aParagraphKeepsItsInlineStyles() throws {
        let line = try #require(lines("Some **bold**, *slanted*, and `code` [here](https://example.com).").first)
        #expect(line.style == .body)
        #expect(line.depth == 0)
        #expect(line.marker == nil)
        #expect(line.spacingBefore == 0)
        let runs = line.text.runs.map { (String(line.text[$0.range].characters), $0.inlinePresentationIntent) }
        #expect(runs.contains { $0.0 == "bold" && $0.1 == .stronglyEmphasized })
        #expect(runs.contains { $0.0 == "slanted" && $0.1 == .emphasized })
        #expect(runs.contains { $0.0 == "code" && $0.1 == .code })
        #expect(line.text.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    @Test func headingsKeepTheirLevelAndLargeOnesTheSpaceAbove() {
        #expect(lines("# Title") == [ChatTextLine("Title", style: .heading(level: 1), spacingBefore: 4)])
        #expect(lines("### Small") == [ChatTextLine("Small", style: .heading(level: 3))])
    }

    @Test func aCodeBlockIsOneLineOfItsText() {
        #expect(
            lines("```swift\nlet a = 1\n\nlet b = 2\n```") == [ChatTextLine("let a = 1\n\nlet b = 2", style: .code)])
    }

    @Test func listItemsCarryTheirMarkersAndSpacing() {
        #expect(
            lines("- one\n- two") == [
                ChatTextLine("one", depth: 1, marker: "•"),
                ChatTextLine("two", depth: 1, marker: "•", spacingBefore: 5),
            ])
        #expect(
            lines("3. three\n4. four") == [
                ChatTextLine("three", depth: 1, marker: "3."),
                ChatTextLine("four", depth: 1, marker: "4.", spacingBefore: 5),
            ])
    }

    @Test func aNestedListGoesOneDeeperAndOnlyItsItemsTakeItsMarkers() {
        #expect(
            lines("- outer\n  - inner\n- next") == [
                ChatTextLine("outer", depth: 1, marker: "•"),
                ChatTextLine("inner", depth: 2, marker: "•", spacingBefore: 5),
                ChatTextLine("next", depth: 1, marker: "•", spacingBefore: 5),
            ])
    }

    @Test func anEmptyItemGetsALineForItsMarker() {
        #expect(
            lines("1.\n2. two") == [
                ChatTextLine("", depth: 1, marker: "1."),
                ChatTextLine("two", depth: 1, marker: "2.", spacingBefore: 5),
            ])
    }

    /// What `MarkdownView` draws with a box, bar, line, or grid of its own inside a list or quote stays with SwiftUI,
    /// as does an item opening with a list, whose markers SwiftUI puts on one line.
    @Test func blocksThatNeedMoreThanTextInsideAListStayWithSwiftUI() {
        let stays = [
            "1. Run:\n\n   ```bash\n   make\n   ```", "- > quoted", "> ```\n> code\n> ```", "- a\n\n  ---",
            "1. - inner", "> | a |\n> |---|\n> | b |",
        ]
        for markdown in stays {
            #expect(!ChatTextLines.draws(ChatMarkdown.parse(markdown)[0]), "\(markdown)")
        }
        let drawn = ["- one\n  - two", "> a\n>\n> - b", "1. **bold** item", "```swift\nlet a = 1\n```", "> quoted"]
        for markdown in drawn {
            #expect(ChatTextLines.draws(ChatMarkdown.parse(markdown)[0]), "\(markdown)")
        }
    }

    @Test func aQuoteIsQuietAndSpacedAsMarkdownViewSpacesIt() {
        #expect(
            lines("> first\n>\n> second") == [
                ChatTextLine("first", quoted: true),
                ChatTextLine("second", quoted: true, spacingBefore: 8),
            ])
    }

    @Test func tablesStayWithSwiftUIAndRulesHaveNoText() {
        let table = ChatMarkdown.parse("| a |\n|---|\n| b |")[0]
        #expect(!ChatTextLines.draws(table))
        #expect(ChatTextLines.draws(.rule))
        #expect(ChatTextLines.lines(for: .rule).isEmpty)
    }
}
