import CanopyTickets
import SwiftUI

/// A message's text as Discord shows it: styled paragraphs, code blocks, and quotes.
struct DiscordTextView: View {
    let blocks: [DiscordBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let spans):
                    Text(Self.attributed(spans))
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .code(_, let text):
                    Text(verbatim: text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Style.badgeFill, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                case .quote(let inner):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tertiary)
                            .frame(width: 3)
                        DiscordTextView(blocks: inner)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static let mention = Color.adaptive(light: 0x4752C4, dark: 0xC9CDFB)
    static let mentionFill = Color.adaptive(
        light: NSColor(hex: 0x5865F2).withAlphaComponent(0.15), dark: NSColor(hex: 0x5865F2).withAlphaComponent(0.3))

    static func attributed(_ spans: [DiscordSpan]) -> AttributedString {
        var text = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            var font = Font.system(size: 13, weight: span.style.contains(.bold) ? .semibold : .regular)
            if span.style.contains(.code) {
                font = .system(
                    size: 11.5, weight: span.style.contains(.bold) ? .semibold : .regular, design: .monospaced)
                part.backgroundColor = Style.badgeFill
            }
            if span.style.contains(.italic) { font = font.italic() }
            part.font = font
            if span.style.contains(.underline) { part.underlineStyle = .single }
            if span.style.contains(.strikethrough) { part.strikethroughStyle = .single }
            if span.style.contains(.spoiler) { part.backgroundColor = Style.selectionFill }
            switch span.kind {
            case .text: break
            case .link(let url): part.link = url
            case .mention:
                part.foregroundColor = mention
                part.backgroundColor = mentionFill
                part.font = font.weight(.medium)
            case .emoji: part.foregroundColor = .secondary
            }
            text += part
        }
        return text
    }
}
