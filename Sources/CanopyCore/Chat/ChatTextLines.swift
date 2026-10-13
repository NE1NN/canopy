import Foundation

/// A block of Claude's text flattened into paragraphs of styled text, so the block Claude is still writing can be drawn
/// by a plain text view rather than laid out again by SwiftUI on every redraw. Spacing and indents follow
/// `MarkdownView`, so the switch to it when the block settles does not move the text.
public struct ChatTextLine: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case body
        case heading(level: Int)
        case code
    }

    public var text: AttributedString
    public var style: Style
    /// How many list items the paragraph sits in.
    public var depth: Int
    /// A list item's "•" or "3.", on its first paragraph only.
    public var marker: String?
    /// Inside a quote, which draws in the quieter color.
    public var quoted: Bool
    /// Space above the paragraph, in points.
    public var spacingBefore: Double

    public init(
        _ text: AttributedString, style: Style = .body, depth: Int = 0, marker: String? = nil, quoted: Bool = false,
        spacingBefore: Double = 0
    ) {
        self.text = text
        self.style = style
        self.depth = depth
        self.marker = marker
        self.quoted = quoted
        self.spacingBefore = spacingBefore
    }
}

public enum ChatTextLines {
    /// `MarkdownView`'s gaps: between a list's items and the blocks in one, and between a quote's blocks.
    public static let listSpacing = 5.0
    public static let quoteSpacing = 8.0
    /// The space above a large heading.
    public static let headingSpacing = 4.0

    /// Whether `ChatTextLines` can draw `block` as `MarkdownView` does. A table needs its grid, and inside a list or
    /// quote a code block, quote, or rule needs its own box, bar, or line, so those stay with SwiftUI. So does a list
    /// item that opens with a list, whose markers SwiftUI puts on one line.
    public static func draws(_ block: ChatBlock) -> Bool {
        switch block {
        case .table: false
        case .paragraph, .heading, .code, .rule: true
        case .list(_, _, let items):
            items.allSatisfy { blocks in
                if case .list? = blocks.first { return false }
                return blocks.allSatisfy(drawsInside)
            }
        case .quote(let blocks): blocks.allSatisfy(drawsInside)
        }
    }

    private static func drawsInside(_ block: ChatBlock) -> Bool {
        switch block {
        case .paragraph, .heading: true
        case .list: draws(block)
        case .code, .quote, .rule, .table: false
        }
    }

    public static func lines(for block: ChatBlock) -> [ChatTextLine] {
        var lines: [ChatTextLine] = []
        append(block, depth: 0, quoted: false, gap: 0, to: &lines)
        return lines
    }

    private static func append(
        _ block: ChatBlock, depth: Int, quoted: Bool, gap: Double, to lines: inout [ChatTextLine]
    ) {
        switch block {
        case .paragraph(let text):
            lines.append(ChatTextLine(text, depth: depth, quoted: quoted, spacingBefore: gap))
        case .heading(let level, let text):
            let space = level <= 2 ? headingSpacing : 0
            lines.append(
                ChatTextLine(
                    text, style: .heading(level: level), depth: depth, quoted: quoted, spacingBefore: gap + space))
        case .code(_, let text):
            lines.append(
                ChatTextLine(AttributedString(text), style: .code, depth: depth, quoted: quoted, spacingBefore: gap))
        case .list(let ordered, let start, let items):
            for (index, blocks) in items.enumerated() {
                let first = lines.count
                for (offset, inner) in blocks.enumerated() {
                    let space = index == 0 && offset == 0 ? gap : listSpacing
                    append(inner, depth: depth + 1, quoted: quoted, gap: space, to: &lines)
                }
                let marker = ordered ? "\(start + index)." : "•"
                if first < lines.count, lines[first].marker == nil {
                    lines[first].marker = marker
                } else {
                    // An empty item, or one that opens with a list of its own, gets a line for its marker.
                    lines.insert(
                        ChatTextLine(
                            AttributedString(), depth: depth + 1, marker: marker, quoted: quoted,
                            spacingBefore: index == 0 ? gap : listSpacing),
                        at: first)
                    if first + 1 < lines.count { lines[first + 1].spacingBefore = listSpacing }
                }
            }
        case .quote(let blocks):
            for (offset, inner) in blocks.enumerated() {
                append(inner, depth: depth, quoted: true, gap: offset == 0 ? gap : quoteSpacing, to: &lines)
            }
        case .table, .rule:
            break
        }
    }
}
