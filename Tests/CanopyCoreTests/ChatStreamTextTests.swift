import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

struct ChatStreamTextTests {
    @Test func finishedBlocksStayAndOnlyTheLastOneChanges() {
        var text = ChatStreamText()
        text.append("First para")
        #expect(text.blocks.count == 1)
        #expect(text.settledCount == 0)

        text.append("graph.\n\nSecond ")
        #expect(text.settledCount == 1)
        let settled = text.blocks[0]

        text.append("paragraph, still growing")
        #expect(text.blocks.count == 2)
        #expect(text.blocks[0] == settled)
        #expect(text.blocks[1] == ChatMarkdown.parse("Second paragraph, still growing")[0])
    }

    /// A blank line inside a code fence does not end a block.
    @Test func aFenceKeepsItsBlankLines() {
        var text = ChatStreamText()
        text.append("```swift\nlet a = 1\n\nlet b = 2\n")
        #expect(text.settledCount == 0)
        #expect(text.blocks == [.code(language: "swift", text: "let a = 1\n\nlet b = 2")])

        text.append("```\n\nAfter.")
        #expect(text.settledCount == 1)
        #expect(text.blocks.count == 2)
    }

    @Test func readsAsTheWholeTextWouldForPlainParagraphs() {
        var text = ChatStreamText()
        let whole = "# Title\n\nOne **two**.\n\n- a\n- b\n\nEnd `x`."
        for character in whole { text.append(String(character)) }

        #expect(text.blocks == ChatMarkdown.parse(whole))
    }
}
