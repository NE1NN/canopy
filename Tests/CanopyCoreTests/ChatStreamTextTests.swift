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

    /// A nested item or rule starting under a line of text is not shown as that line's heading for a moment.
    @Test func theStartOfAnItemUnderALineIsNotTakenForAHeading() {
        var text = ChatStreamText()
        text.append("- A bullet with **bold**\n  -")
        #expect(text.blocks == ChatMarkdown.parse("- A bullet with **bold**"))
        text.append(" nested")
        #expect(text.blocks == ChatMarkdown.parse("- A bullet with **bold**\n  - nested"))

        var title = ChatStreamText()
        title.append("Title\n===")
        #expect(title.blocks == ChatMarkdown.parse("Title"))

        var code = ChatStreamText()
        code.append("```\nlet a = 1\n-")
        #expect(code.blocks == ChatMarkdown.parse("```\nlet a = 1\n-"))
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

    @Test func tildeFencesAndLongerFencesKeepTheirBlankLines() {
        var text = ChatStreamText()
        text.append("~~~\na\n\nb\n")
        #expect(text.settledCount == 0)
        text.append("~~~\n\n````\n```\n\n````\n\nEnd.")
        #expect(text.blocks.count == 3)
        #expect(text.blocks[1] == .code(language: nil, text: "```\n"))
    }

    @Test func readsAsTheWholeTextWouldForPlainParagraphs() {
        var text = ChatStreamText()
        let whole = "# Title\n\nOne **two**.\n\n- a\n- b\n\nEnd `x`."
        for character in whole { text.append(String(character)) }

        #expect(text.blocks == ChatMarkdown.parse(whole))
    }

    /// Each draw looks for paragraph breaks only past the settled blocks, and must end where a whole parse would.
    @Test func streamingInPiecesSettlesAsTheWholeTextWould() {
        let text = """
            First paragraph.

            ```swift
            let a = 1

            let b = 2
            ```

            Second paragraph
            with two lines.

            ~~~~
            ```
            still code

            ~~~~

            Last one.
            """
        var whole = ChatStreamText()
        whole.append(text)
        for size in [1, 3, 7, 40] {
            var pieces = ChatStreamText()
            var rest = Substring(text)
            while !rest.isEmpty {
                pieces.append(String(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            #expect(pieces.blocks == whole.blocks)
            #expect(pieces.settledCount == whole.settledCount)
        }
        #expect(whole.growingLength == "Last one.".utf8.count)
    }

    @MainActor @Test func aLongBlockIsDrawnLessOften() {
        #expect(ChatSession.streamingInterval(growing: 200) == ChatSession.streamingInterval)
        #expect(ChatSession.streamingInterval(growing: 5_000) == .milliseconds(100))
        #expect(ChatSession.streamingInterval(growing: 100_000) == .milliseconds(300))
    }
}
