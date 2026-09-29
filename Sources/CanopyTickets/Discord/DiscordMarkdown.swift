import Foundation

public struct DiscordStyle: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold = DiscordStyle(rawValue: 1 << 0)
    public static let italic = DiscordStyle(rawValue: 1 << 1)
    public static let underline = DiscordStyle(rawValue: 1 << 2)
    public static let strikethrough = DiscordStyle(rawValue: 1 << 3)
    public static let code = DiscordStyle(rawValue: 1 << 4)
    public static let spoiler = DiscordStyle(rawValue: 1 << 5)
}

/// A run of a message's text with one style.
public struct DiscordSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case link(URL)
        /// `@Sameer Goyal`, `#ticket-0853-sameergoyal`, or `@role`, drawn as a mention.
        case mention
        /// `:name:` for a custom emoji, which Canopy shows by name.
        case emoji
    }

    public var text: String
    public var style: DiscordStyle
    public var kind: Kind

    public init(text: String, style: DiscordStyle = [], kind: Kind = .text) {
        self.text = text
        self.style = style
        self.kind = kind
    }
}

public enum DiscordBlock: Sendable, Equatable {
    case paragraph([DiscordSpan])
    case code(language: String?, text: String)
    case quote([DiscordBlock])
}

/// What the mentions in a message's text name. Users come from the message's mentions list. The API names no channels,
/// so only the ticket's own channel and its named threads get their names.
public struct DiscordNames: Sendable, Equatable {
    public var users: [String: String]
    public var channels: [String: String]

    public init(users: [String: String] = [:], channels: [String: String] = [:]) {
        self.users = users
        self.channels = channels
    }

    public init(message: TicketMessage, ticket: TicketSummary, threads: [MessageThread]) {
        var users: [String: String] = [:]
        for mention in message.mentions where users[mention.id] == nil {
            let name = mention.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? mention.username
            users[mention.id] = name
        }
        var channels: [String: String] = [:]
        if let channel = URL(string: ticket.discordUrl)?.lastPathComponent, !channel.isEmpty {
            channels[channel] = ticket.name
        }
        for thread in threads {
            if let name = thread.name, !name.isEmpty { channels[thread.id] = name }
        }
        self.init(users: users, channels: channels)
    }
}

/// Discord's markdown, as its client shows it: bold, italics, underline, strikethrough, spoilers, inline code, code
/// blocks, quotes, links, mentions, custom emoji, and timestamps.
public enum DiscordMarkdown {
    public static func parse(_ text: String, names: DiscordNames) -> [DiscordBlock] {
        var blocks: [DiscordBlock] = []
        for piece in fences(text) {
            switch piece {
            case .code(let language, let body): blocks.append(.code(language: language, text: body))
            case .text(let text): blocks += textBlocks(text, names: names)
            }
        }
        return blocks
    }

    /// The text as a person reads it: mentions and emoji written out, styles dropped, code blocks fenced, and quotes
    /// marked with `>`.
    public static func plain(_ text: String, names: DiscordNames) -> String {
        parse(text, names: names).map(plain).joined(separator: "\n")
    }

    private static func plain(_ block: DiscordBlock) -> String {
        switch block {
        case .paragraph(let spans): spans.map(\.text).joined()
        case .code(let language, let text): "```\(language ?? "")\n\(text)\n```"
        case .quote(let blocks):
            blocks.map(plain).joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n")
        }
    }

    // MARK: Blocks

    private enum Piece {
        case text(String)
        case code(language: String?, body: String)
    }

    /// The text split at fenced code blocks. A fence with no closing fence is text.
    private static func fences(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = text[...]
        while let open = rest.range(of: "```"),
            let close = rest.range(of: "```", range: open.upperBound..<rest.endIndex)
        {
            pieces.append(.text(String(rest[..<open.lowerBound])))
            pieces.append(codeBlock(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        pieces.append(.text(String(rest)))
        return pieces
    }

    /// A first line that is one word, with more lines after it, names the language.
    private static func codeBlock(_ content: Substring) -> Piece {
        var body = content
        var language: String?
        if let newline = body.firstIndex(of: "\n") {
            let first = body[..<newline]
            if first.isEmpty || first.allSatisfy({ $0.isLetter || $0.isNumber || "+#-_.".contains($0) }) {
                language = first.isEmpty ? nil : String(first)
                body = body[body.index(after: newline)...]
            }
        }
        if body.hasSuffix("\n") { body = body.dropLast() }
        return .code(language: language, body: String(body))
    }

    /// Paragraphs and quotes: `> ` quotes its line, and `>>> ` the rest of the text.
    private static func textBlocks(_ text: String, names: DiscordNames) -> [DiscordBlock] {
        var blocks: [DiscordBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        func flushParagraph() {
            if let block = self.paragraph(paragraph, names: names) { blocks.append(block) }
            paragraph = []
        }
        func flushQuote() {
            if let block = self.paragraph(quote, names: names) { blocks.append(.quote([block])) }
            quote = []
        }
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line == ">>>" || line.hasPrefix(">>> ") {
                flushParagraph()
                flushQuote()
                quote = [String(line.dropFirst(min(4, line.count)))] + lines[(index + 1)...]
                break
            }
            if line == ">" || line.hasPrefix("> ") {
                flushParagraph()
                quote.append(String(line.dropFirst(min(2, line.count))))
            } else {
                flushQuote()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    private static func paragraph(_ lines: [String], names: DiscordNames) -> DiscordBlock? {
        var text = lines.joined(separator: "\n")[...]
        while text.hasPrefix("\n") { text = text.dropFirst() }
        while text.hasSuffix("\n") { text = text.dropLast() }
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        let parser = InlineParser(characters: Array(text), names: names)
        return .paragraph(parser.parse(0..<parser.characters.count, style: [], link: nil))
    }
}

extension DiscordSpan.Kind {
    fileprivate var joins: Bool {
        switch self {
        case .text, .link: true
        case .mention, .emoji: false
        }
    }
}

/// Inline markup within one paragraph, over its characters.
private struct InlineParser {
    let characters: [Character]
    let names: DiscordNames

    func parse(_ range: Range<Int>, style: DiscordStyle, link: URL?) -> [DiscordSpan] {
        var spans: [DiscordSpan] = []
        var buffer = ""
        let plainKind: DiscordSpan.Kind = link.map { .link($0) } ?? .text
        func flush() {
            if !buffer.isEmpty { spans.append(DiscordSpan(text: buffer, style: style, kind: plainKind)) }
            buffer = ""
        }
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            let character = characters[index]
            if character == "\\", index + 1 < end, Self.escapable(characters[index + 1]) {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`", let (code, next) = inlineCode(at: index, end: end) {
                flush()
                spans.append(DiscordSpan(text: code, style: style.union(.code), kind: plainKind))
                index = next
                continue
            }
            if character == "<", let (text, kind, next) = angle(at: index, end: end) {
                flush()
                spans.append(DiscordSpan(text: text, style: style, kind: kind))
                index = next
                continue
            }
            if character == "[", link == nil, let (inner, url, next) = maskedLink(at: index, end: end) {
                flush()
                spans += parse(inner, style: style, link: url)
                index = next
                continue
            }
            if character == "h", link == nil, index == 0 || !Self.isWordCharacter(characters[index - 1]),
                let (text, url, next) = bareURL(at: index, end: end)
            {
                flush()
                spans.append(DiscordSpan(text: text, style: style, kind: .link(url)))
                index = next
                continue
            }
            if "*_~|".contains(character) {
                let run = runLength(at: index, end: end)
                if let (inner, added, next) = emphasis(at: index, run: run, end: end) {
                    flush()
                    spans += parse(inner, style: style.union(added), link: link)
                    index = next
                } else {
                    buffer += String(repeating: character, count: run)
                    index += run
                }
                continue
            }
            buffer.append(character)
            index += 1
        }
        flush()
        return Self.merged(spans)
    }

    // MARK: Rules

    /// A delimiter run of exactly its length opens, and the next run of the same character and length closes. A single
    /// `*` needs text right after it and right before its closer, and `_` must sit at a word's edge, so
    /// `snake_case_names` stays as typed.
    private func emphasis(at index: Int, run: Int, end: Int) -> (Range<Int>, DiscordStyle, Int)? {
        let character = characters[index]
        let style: DiscordStyle
        switch (character, run) {
        case ("*", 1), ("_", 1): style = .italic
        case ("*", 2): style = .bold
        case ("*", 3): style = [.bold, .italic]
        case ("_", 2): style = .underline
        case ("_", 3): style = [.underline, .italic]
        case ("~", 2): style = .strikethrough
        case ("|", 2): style = .spoiler
        default: return nil
        }
        let open = index + run
        if character == "*", run == 1, open < end, characters[open].isWhitespace { return nil }
        if character == "_", index > 0, Self.isWordCharacter(characters[index - 1]) { return nil }
        var search = open
        while search < end {
            let next = characters[search]
            if next == "\\" {
                search += 2
                continue
            }
            if next == "`", let (_, after) = inlineCode(at: search, end: end) {
                search = after
                continue
            }
            guard next == character else {
                search += 1
                continue
            }
            let closing = runLength(at: search, end: end)
            if closing == run, search > open, isValidCloser(character, run: run, content: open..<search, end: end) {
                return (open..<search, style, search + run)
            }
            search += closing
        }
        return nil
    }

    private func isValidCloser(_ character: Character, run: Int, content: Range<Int>, end: Int) -> Bool {
        guard characters[content].contains(where: { !$0.isWhitespace }) else { return false }
        if character == "*", run == 1, characters[content.upperBound - 1].isWhitespace { return false }
        let after = content.upperBound + run
        if character == "_", after < characters.count, Self.isWordCharacter(characters[after]) { return false }
        return true
    }

    /// One or two backticks, closed by as many.
    private func inlineCode(at index: Int, end: Int) -> (String, Int)? {
        let run = runLength(at: index, end: end)
        guard run <= 2 else { return nil }
        var search = index + run
        while search < end {
            guard characters[search] == "`" else {
                search += 1
                continue
            }
            let closing = runLength(at: search, end: end)
            if closing == run, search > index + run {
                var code = String(characters[(index + run)..<search])
                if code.count > 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                    code = String(code.dropFirst().dropLast())
                }
                return (code, search + run)
            }
            search += closing
        }
        return nil
    }

    /// `<@id>`, `<@!id>`, `<@&id>`, `<#id>`, `<:name:id>`, `<a:name:id>`, `<t:seconds:style>`, and `<https://…>`.
    private func angle(at index: Int, end: Int) -> (String, DiscordSpan.Kind, Int)? {
        guard let close = characters[(index + 1)..<end].firstIndex(of: ">") else { return nil }
        let inner = String(characters[(index + 1)..<close])
        guard !inner.isEmpty, !inner.contains(where: \.isWhitespace) else { return nil }
        let next = close + 1
        if Self.digits(after: "@&", in: inner) != nil {
            return ("@role", .mention, next)
        }
        if let id = Self.digits(after: "@!", in: inner) ?? Self.digits(after: "@", in: inner) {
            return ("@" + (names.users[id] ?? "unknown-user"), .mention, next)
        }
        if let id = Self.digits(after: "#", in: inner) {
            return ("#" + (names.channels[id] ?? "channel"), .mention, next)
        }
        if let name = Self.emojiName(inner) {
            return (":\(name):", .emoji, next)
        }
        if let time = Self.timestamp(inner) {
            return (time, .text, next)
        }
        if inner.hasPrefix("https://") || inner.hasPrefix("http://"), let url = URL(string: inner) {
            return (inner, .link(url), next)
        }
        return nil
    }

    /// `[text](https://…)`. Only web links, so a message cannot hide another kind of link behind text.
    private func maskedLink(at index: Int, end: Int) -> (Range<Int>, URL, Int)? {
        guard let close = characters[(index + 1)..<end].firstIndex(of: "]"), close > index + 1,
            close + 1 < end, characters[close + 1] == "("
        else { return nil }
        let start = close + 2
        guard let paren = characters[start..<end].firstIndex(of: ")") else { return nil }
        let target = String(characters[start..<paren])
        guard target.hasPrefix("https://") || target.hasPrefix("http://"), !target.contains(where: \.isWhitespace),
            let url = URL(string: target)
        else { return nil }
        return ((index + 1)..<close, url, paren + 1)
    }

    /// A web address in the text, without the punctuation that ends the sentence it is in.
    private func bareURL(at index: Int, end: Int) -> (String, URL, Int)? {
        let rest = String(characters[index..<min(end, index + 8)])
        guard rest.hasPrefix("https://") || rest.hasPrefix("http://") else { return nil }
        var stop = index
        while stop < end, !characters[stop].isWhitespace, characters[stop] != "<" { stop += 1 }
        var text = String(characters[index..<stop])
        while let last = text.last,
            ".,:;!?\"'".contains(last)
                || (last == ")" && text.filter({ $0 == ")" }).count > text.filter({ $0 == "(" }).count)
        {
            text.removeLast()
        }
        guard text.count > (text.hasPrefix("https://") ? 8 : 7), let url = URL(string: text) else { return nil }
        return (text, url, index + text.count)
    }

    // MARK: Helpers

    private func runLength(at index: Int, end: Int) -> Int {
        var length = 0
        while index + length < end, characters[index + length] == characters[index] { length += 1 }
        return length
    }

    private static func escapable(_ character: Character) -> Bool {
        character.isASCII && (character.isPunctuation || character.isSymbol)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func digits(after prefix: String, in text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let id = text.dropFirst(prefix.count)
        return !id.isEmpty && id.allSatisfy({ $0.isASCII && $0.isNumber }) ? String(id) : nil
    }

    private static func emojiName(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty || parts[0] == "a", !parts[1].isEmpty,
            parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "~" }),
            !parts[2].isEmpty, parts[2].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return String(parts[1])
    }

    /// `t:seconds` and `t:seconds:style`, in the styles Discord knows.
    private static func timestamp(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        // Whole seconds, within the range Discord's clients can show, as Discord itself accepts.
        guard parts.count == 2 || parts.count == 3, parts[0] == "t", let seconds = Int64(parts[1]),
            abs(seconds) <= 8_640_000_000_000
        else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        switch parts.count == 3 ? String(parts[2]) : "f" {
        case "t": return date.formatted(date: .omitted, time: .shortened)
        case "T": return date.formatted(date: .omitted, time: .standard)
        case "d": return date.formatted(date: .numeric, time: .omitted)
        case "D": return date.formatted(date: .long, time: .omitted)
        case "F": return date.formatted(date: .complete, time: .shortened)
        case "R": return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        case "f": return date.formatted(date: .long, time: .shortened)
        default: return nil
        }
    }

    /// Neighbouring text, or neighbouring parts of one link, with the same style become one span. Mentions and emoji
    /// stay spans of their own.
    private static func merged(_ spans: [DiscordSpan]) -> [DiscordSpan] {
        var result: [DiscordSpan] = []
        for span in spans where !span.text.isEmpty {
            if let last = result.last, last.style == span.style, last.kind == span.kind, span.kind.joins {
                result[result.count - 1].text += span.text
            } else {
                result.append(span)
            }
        }
        return result
    }
}
