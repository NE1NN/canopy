import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

struct ChatMarkdownTests {
    func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    @Test func readsParagraphsAndHeadings() {
        let blocks = ChatMarkdown.parse("# Title\n\nFirst line\nstill first.\n\n### Small")

        #expect(blocks.count == 3)
        guard case .heading(1, let title) = blocks[0], case .paragraph(let body) = blocks[1],
            case .heading(3, let small) = blocks[2]
        else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(plain(title) == "Title")
        #expect(plain(body) == "First line still first.")
        #expect(plain(small) == "Small")
    }

    @Test func marksEmphasisCodeAndLinksInline() throws {
        let blocks = ChatMarkdown.parse("Some **bold**, *slanted*, `code`, ~~gone~~ and [a link](https://example.com).")

        guard case .paragraph(let text) = blocks.first else {
            Issue.record("not a paragraph")
            return
        }
        #expect(plain(text) == "Some bold, slanted, code, gone and a link.")
        func intent(of word: String) -> InlinePresentationIntent? {
            text.range(of: word).flatMap { text[$0].runs.first?.inlinePresentationIntent }
        }
        #expect(intent(of: "bold") == .stronglyEmphasized)
        #expect(intent(of: "slanted") == .emphasized)
        #expect(intent(of: "code") == .code)
        #expect(intent(of: "gone") == .strikethrough)
        let link = try #require(text.range(of: "a link"))
        #expect(text[link].runs.first?.link == URL(string: "https://example.com"))
    }

    @Test func keepsCodeBlocksVerbatimWithTheirLanguage() {
        let blocks = ChatMarkdown.parse("```swift\nlet x = 1\n  // **not bold**\n```")

        #expect(blocks == [.code(language: "swift", text: "let x = 1\n  // **not bold**")])
    }

    @Test func readsNestedListsAndQuotes() {
        let blocks = ChatMarkdown.parse("3. three\n4. four\n   - inner\n\n> quoted\n> text")

        guard case .list(let ordered, let start, let items) = blocks.first, case .quote(let quoted) = blocks.last else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(ordered)
        #expect(start == 3)
        #expect(items.count == 2)
        guard case .list(false, _, let inner) = items[1].last else {
            Issue.record("no inner list in \(items[1])")
            return
        }
        #expect(inner.count == 1)
        guard case .paragraph(let line) = quoted.first else {
            Issue.record("no paragraph in quote")
            return
        }
        #expect(plain(line) == "quoted text")
    }

    @Test func readsTablesWithAlignment() {
        let blocks = ChatMarkdown.parse("| Name | Size |\n|:---|---:|\n| a | 1 |\n| b | 22 |")

        guard case .table(let header, let rows, let alignments) = blocks.first else {
            Issue.record("not a table: \(blocks)")
            return
        }
        #expect(header.map(plain) == ["Name", "Size"])
        #expect(rows.map { $0.map(plain) } == [["a", "1"], ["b", "22"]])
        #expect(alignments == [.leading, .trailing])
    }

    @Test func readsRulesAndKeepsHardBreaks() {
        let blocks = ChatMarkdown.parse("one  \ntwo\n\n---")

        guard case .paragraph(let text) = blocks.first else {
            Issue.record("not a paragraph")
            return
        }
        #expect(plain(text) == "one\ntwo")
        #expect(blocks.last == .rule)
    }

    /// A message still streaming can end inside a code fence, which reads as code up to where it stops.
    @Test func anUnfinishedFenceIsCodeSoFar() {
        let blocks = ChatMarkdown.parse("Here:\n\n```sh\nmake te")

        #expect(blocks.last == .code(language: "sh", text: "make te"))
    }

    @Test func htmlStaysAsText() {
        let blocks = ChatMarkdown.parse("<b>hi</b> there")

        guard case .paragraph(let text) = blocks.first else {
            Issue.record("not a paragraph")
            return
        }
        #expect(plain(text) == "<b>hi</b> there")
    }
}
