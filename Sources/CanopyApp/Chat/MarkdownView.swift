import CanopyCore
import SwiftUI

/// Claude's text as a document: blocks parsed once in CanopyCore, drawn here.
struct MarkdownView: View {
    let blocks: [ChatBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: ChatBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            InlineText(text: text)
        case .heading(let level, let text):
            InlineText(text: text, font: Self.headingFont(level))
                .padding(.top, level <= 2 ? 4 : 0)
        case .code(let language, let text):
            CodeBlockView(language: language, text: text)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: ordered ? "\(start + index)." : "•")
                            .font(ChatStyle.text)
                            .foregroundStyle(ChatStyle.secondaryText)
                            .frame(minWidth: 12, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                MarkdownBlockView(block: block)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 4)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(ChatStyle.cardBorder).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
                .foregroundStyle(ChatStyle.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows, let alignments):
            TableBlockView(header: header, rows: rows, alignments: alignments)
        case .rule:
            Rectangle().fill(ChatStyle.cardBorder).frame(height: 1).padding(.vertical, 4)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 17, weight: .semibold)
        case 2: .system(size: 15.5, weight: .semibold)
        default: .system(size: 13.5, weight: .semibold)
        }
    }
}

/// A run of text with Claude's inline styles: bold, italic, struck, code in a pill, and links.
struct InlineText: View {
    let text: AttributedString
    var font = ChatStyle.text

    var body: some View {
        Text(Self.styled(text, font: font))
            .font(font)
            .lineSpacing(ChatStyle.textLineSpacing)
            .foregroundStyle(ChatStyle.primaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Turns Foundation's presentation intents into what SwiftUI's Text draws.
    static func styled(_ text: AttributedString, font: Font = ChatStyle.text) -> AttributedString {
        var styled = text
        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let range = run.range
            if intent.contains(.code) {
                styled[range].font = ChatStyle.mono
                styled[range].backgroundColor = ChatStyle.inlineCode
                styled[range].foregroundColor = ChatStyle.strongText
            } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
                styled[range].font = font.weight(.semibold).italic()
            } else if intent.contains(.stronglyEmphasized) {
                styled[range].font = font.weight(.semibold)
            } else if intent.contains(.emphasized) {
                styled[range].font = font.italic()
            }
            if intent.contains(.strikethrough) {
                styled[range].strikethroughStyle = .single
            }
        }
        return styled
    }
}

private struct CodeBlockView: View {
    let language: String?
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(ChatStyle.mono)
                .lineSpacing(3)
                .foregroundStyle(ChatStyle.primaryText)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatStyle.codeFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChatStyle.cardBorder))
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ChatStyle.tertiaryText)
                    .padding(6)
            }
        }
    }
}

private struct TableBlockView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [ChatBlock.Alignment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        cellText(cell, index).fontWeight(.semibold)
                    }
                }
                Rectangle().fill(ChatStyle.cardBorder).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellText(cell, index)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cellText(_ cell: AttributedString, _ index: Int) -> some View {
        Text(InlineText.styled(cell))
            .font(ChatStyle.text)
            .foregroundStyle(ChatStyle.primaryText)
            .textSelection(.enabled)
            .gridColumnAlignment(alignment(index))
    }

    private func alignment(_ index: Int) -> HorizontalAlignment {
        switch index < alignments.count ? alignments[index] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
