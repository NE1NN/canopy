import Foundation
import Markdown

/// A block of Claude's text as a chat draws it. Inline styles and links are in each `AttributedString`, as
/// `inlinePresentationIntent` and `link`, which SwiftUI's `Text` draws.
public enum ChatBlock: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(language: String?, text: String)
    /// Each item is the blocks inside it.
    case list(ordered: Bool, start: Int, items: [[ChatBlock]])
    case quote([ChatBlock])
    case table(header: [AttributedString], rows: [[AttributedString]], alignments: [Alignment])
    case rule
}

/// Turns Claude's markdown into blocks. HTML stays as the text it is, since a chat shows no web content inline.
public enum ChatMarkdown {
    public static func parse(_ text: String) -> [ChatBlock] {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        return document.children.compactMap(block)
    }

    private static func block(_ markup: any Markup) -> ChatBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inline(paragraph.children))
        case let heading as Heading:
            return .heading(level: heading.level, inline(heading.children))
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            return .code(language: language, text: text)
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: list.listItems.map(items))
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map(items))
        case let quote as BlockQuote:
            return .quote(quote.children.compactMap(block))
        case let table as Table:
            let header = Array(table.head.cells.map { inline($0.children) })
            let rows = Array(table.body.rows.map { row in Array(row.cells.map { inline($0.children) }) })
            let alignments = (0..<header.count).map { index -> ChatBlock.Alignment in
                switch index < table.columnAlignments.count ? table.columnAlignments[index] : nil {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            return .table(header: header, rows: rows, alignments: alignments)
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            var text = html.rawHTML
            if text.hasSuffix("\n") { text.removeLast() }
            return .paragraph(AttributedString(text))
        default:
            return nil
        }
    }

    private static func items(_ item: ListItem) -> [ChatBlock] {
        item.children.compactMap(block)
    }

    private static func inline(_ children: some Sequence<any Markup>) -> AttributedString {
        var text = AttributedString()
        for child in children {
            text += inline(child, intent: [], link: nil)
        }
        return text
    }

    private static func inline(_ markup: any Markup, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        func styled(_ string: String, _ intent: InlinePresentationIntent) -> AttributedString {
            var run = AttributedString(string)
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if let link { run.link = link }
            return run
        }
        func nested(_ intent: InlinePresentationIntent, link: URL?) -> AttributedString {
            markup.children.reduce(into: AttributedString()) { $0 += inline($1, intent: intent, link: link) }
        }
        switch markup {
        case let text as Markdown.Text: return styled(text.string, intent)
        case let code as InlineCode: return styled(code.code, intent.union(.code))
        case is Emphasis: return nested(intent.union(.emphasized), link: link)
        case is Strong: return nested(intent.union(.stronglyEmphasized), link: link)
        case is Strikethrough: return nested(intent.union(.strikethrough), link: link)
        case let anchor as Markdown.Link:
            return nested(intent, link: anchor.destination.flatMap(URL.init(string:)) ?? link)
        case is SoftBreak: return styled(" ", intent)
        case is LineBreak: return styled("\n", intent)
        case let html as InlineHTML: return styled(html.rawHTML, intent)
        case let image as Markdown.Image:
            let alt = image.plainText
            return styled(alt.isEmpty ? (image.source ?? "") : alt, intent)
        default: return nested(intent, link: link)
        }
    }
}
