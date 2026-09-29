import Foundation
import Testing

@testable import CanopyTickets

struct DiscordMarkdownTests {
    let names = DiscordNames(
        users: ["111": "Sameer Goyal"], channels: ["1300000000000000853": "ticket-0853-sameergoyal"])

    func spans(_ text: String) -> [DiscordSpan] {
        guard case .paragraph(let spans) = DiscordMarkdown.parse(text, names: names).first else { return [] }
        return spans
    }

    func span(_ text: String, _ style: DiscordStyle = [], _ kind: DiscordSpan.Kind = .text) -> DiscordSpan {
        DiscordSpan(text: text, style: style, kind: kind)
    }

    @Test func emphasis() {
        #expect(
            spans("Checked the **shadowban** flag") == [span("Checked the "), span("shadowban", .bold), span(" flag")])
        #expect(
            spans("*a* _b_ __c__ ~~d~~ ***e***") == [
                span("a", .italic), span(" "), span("b", .italic), span(" "), span("c", .underline), span(" "),
                span("d", .strikethrough), span(" "), span("e", [.bold, .italic]),
            ])
        #expect(
            spans("**bold with *italic* inside**") == [
                span("bold with ", .bold), span("italic", [.bold, .italic]), span(" inside", .bold),
            ])
        #expect(
            spans("*a **b** c*") == [span("a ", .italic), span("b", [.bold, .italic]), span(" c", .italic)])
        #expect(spans("||secret||") == [span("secret", .spoiler)])
        #expect(spans("**bold across\nlines**") == [span("bold across\nlines", .bold)])
    }

    @Test func unbalancedAndIntrawordMarkersStayText() {
        #expect(spans("2 ** 3 and a*") == [span("2 ** 3 and a*")])
        #expect(spans("snake_case_names") == [span("snake_case_names")])
        #expect(spans("\\*not italic\\*") == [span("*not italic*")])
        #expect(spans("****") == [span("****")])
        #expect(spans("a * b * c") == [span("a * b * c")])
        #expect(spans("~single~ |pipe|") == [span("~single~ |pipe|")])
        #expect(spans("** **") == [span("** **")])
    }

    @Test func inlineCodeKeepsMarkupAsIs() {
        #expect(spans("run `a **b** c` now") == [span("run "), span("a **b** c", .code), span(" now")])
        #expect(spans("``has ` inside``") == [span("has ` inside", .code)])
        #expect(spans("a `unclosed") == [span("a `unclosed")])
    }

    @Test func codeBlocksWithAndWithoutALanguage() {
        let blocks = DiscordMarkdown.parse("Before\n```swift\nlet a = 1\n**not bold**\n```\nAfter", names: names)
        #expect(
            blocks == [
                .paragraph([span("Before")]), .code(language: "swift", text: "let a = 1\n**not bold**"),
                .paragraph([span("After")]),
            ])
        #expect(DiscordMarkdown.parse("```\nplain\n```", names: names) == [.code(language: nil, text: "plain")])
        #expect(DiscordMarkdown.parse("```one line```", names: names) == [.code(language: nil, text: "one line")])
        #expect(
            DiscordMarkdown.parse("```two words\nbody```", names: names) == [
                .code(language: nil, text: "two words\nbody")
            ])
        #expect(DiscordMarkdown.parse("``` not closed", names: names) == [.paragraph([span("``` not closed")])])
    }

    @Test func linksMentionsChannelsAndEmoji() {
        let url = URL(string: "https://solis.app/help")!
        #expect(
            spans("See https://solis.app/help.") == [
                span("See "), span("https://solis.app/help", [], .link(url)), span("."),
            ])
        #expect(spans("[the docs](https://solis.app/help)") == [span("the docs", [], .link(url))])
        #expect(
            spans("[**bold** docs](https://solis.app/help)") == [
                span("bold", .bold, .link(url)), span(" docs", [], .link(url)),
            ])
        #expect(spans("<https://solis.app/help>") == [span("https://solis.app/help", [], .link(url))])
        #expect(
            spans("(see https://solis.app/help)") == [
                span("(see "), span("https://solis.app/help", [], .link(url)), span(")"),
            ])
        #expect(spans("Welcome <@111>!") == [span("Welcome "), span("@Sameer Goyal", [], .mention), span("!")])
        #expect(spans("<@!999>") == [span("@unknown-user", [], .mention)])
        #expect(
            spans("<#1300000000000000853> <#42>") == [
                span("#ticket-0853-sameergoyal", [], .mention), span(" "), span("#channel", [], .mention),
            ])
        #expect(spans("<@&7>") == [span("@role", [], .mention)])
        #expect(
            spans("ok <:pepe_ok:123> <a:party:456>") == [
                span("ok "), span(":pepe_ok:", [], .emoji), span(" "), span(":party:", [], .emoji),
            ])
        #expect(spans("a <b> c") == [span("a <b> c")])
        #expect(
            spans("javascript:alert(1) [x](javascript:alert(1))") == [
                span("javascript:alert(1) [x](javascript:alert(1))")
            ])
    }

    @Test func timestampsShowAsDates() {
        let shown = spans("at <t:1790000000:d>")
        #expect(shown.count == 1 && shown[0].text.hasPrefix("at ") && shown[0].text.contains("2026"))
        #expect(spans("<t:nope>") == [span("<t:nope>")])
        for literal in [
            "<t:nan>", "<t:1e300>", "<t:1.5>", "<t:99999999999999999999>", "<t:-9223372036854775808>",
            "<t:9223372036854775807>", "<t:8640000000001>", "<t:-8640000000001>", "<t:+1790000000>", "<t:->",
            "<t:>", "<t:٣>",
        ] {
            #expect(spans(literal) == [span(literal)], "\(literal)")
        }
        for seconds in ["8640000000000", "-8640000000000", "0"] {
            for style in ["", ":t", ":T", ":d", ":D", ":f", ":F", ":R"] {
                let edge = "<t:\(seconds)\(style)>"
                #expect(spans(edge).count == 1 && spans(edge)[0].text != edge, "\(edge)")
            }
        }
    }

    /// Customers write whatever they like, so no text may crash the parser.
    @Test func noTextCrashesTheParser() {
        let pieces = [
            "*", "**", "_", "__", "~~", "||", "`", "``", "```", "\\", "<", ">", "[", "]", "(", ")", "<@", "<@!", "<@&",
            "<#", "<:", "<a:", ":", "<t:", "-", "<t:-9223372036854775808>", "9223372036854775808", "1", "https://",
            "http://x.y", " ", "\n", "> ",
            ">>> ", "é", "🇦🇺", "👩‍💻", "\u{0}", "\u{1B}[31m",
        ]
        var generator = SplitMix(seed: 853)
        for _ in 0..<3000 {
            let count = Int(generator.next() % 24)
            let text = (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            _ = DiscordMarkdown.parse(text, names: names)
            _ = DiscordMarkdown.plain(text, names: names)
        }
    }

    @Test func quotes() {
        #expect(
            DiscordMarkdown.parse("> quoted\nnot", names: names) == [
                .quote([.paragraph([span("quoted")])]), .paragraph([span("not")]),
            ])
        #expect(
            DiscordMarkdown.parse("> one\n> **two**", names: names) == [
                .quote([.paragraph([span("one\n"), span("two", .bold)])])
            ])
        #expect(
            DiscordMarkdown.parse(">>> all\nof this", names: names) == [.quote([.paragraph([span("all\nof this")])])])
        #expect(DiscordMarkdown.parse(">not a quote", names: names) == [.paragraph([span(">not a quote")])])
    }

    @Test func plainTextForTheCLI() {
        #expect(
            DiscordMarkdown.plain("Thanks <@111>, **looking** into `it`.", names: names)
                == "Thanks @Sameer Goyal, looking into it.")
        #expect(DiscordMarkdown.plain("```\ncode\n```", names: names) == "```\ncode\n```")
        #expect(DiscordMarkdown.plain("> said\nthen", names: names) == "> said\nthen")
    }

    @Test func namesComeFromTheMessageAndTheTicket() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let names = DiscordNames(
            message: detail.messages[0], ticket: detail.ticket, threads: detail.messages.compactMap(\.thread))
        #expect(names.users["111"] == "Sameer Goyal")
        #expect(names.channels["1300000000000000853"] == "ticket-0853-sameergoyal")
        #expect(names.channels["1400000000000000001"] == "Shadowban check")
        #expect(names.channels["1400000000000000002"] == nil)
    }
}

/// A small generator with a fixed seed, so a failing text comes back on every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
