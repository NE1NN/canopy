import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

struct TicketTextTests {
    let now = Date(timeIntervalSince1970: 1_790_030_000)

    @Test func listLinesLineUp() throws {
        let open = try APIFixture.decode(TicketList.self, "tickets-open").tickets
        let row = PluginRow(
            plugin: "tickets", item: open[2].id, title: "0853-sameergoyal",
            path: "/Users/me/.canopy/plugins/tickets/0853-sameergoyal")
        let entries = TicketListing.list(open, TicketListQuery(), me: nil).map {
            TicketListEntry(ticket: $0, row: $0.id == row.item ? row : nil)
        }
        #expect(
            TicketText.listLines(entries, now: now, homeFolder: "/Users/me") == [
                "0853-sameergoyal    waiting 7h  HI  ~/.canopy/plugins/tickets/0853-sameergoyal",
                "0850-quietcustomer  1h ago",
                "0849-babamachine    2h ago      AN",
            ])
        #expect(TicketText.listLines([], now: now, homeFolder: "/Users/me").isEmpty)
    }

    @Test func showPrintsTheHeaderAndTheConversationOnly() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let row = PluginRow(
            plugin: "tickets", item: detail.ticket.id, title: "0853-sameergoyal",
            path: "/Users/me/.canopy/plugins/tickets/0853-sameergoyal")
        let text = TicketText.show(
            TicketShowResult(ticket: detail, fetchedAt: 0, stale: nil, row: row), now: now, homeFolder: "/Users/me")
        #expect(text.hasPrefix("ticket-0853-sameergoyal · open · sameergoyal · owner HI · waiting 7h\n"))
        for part in [
            "\nDiscord: https://discord.com/channels/1100000000000000000/1300000000000000853\n",
            "\nRow: ~/.canopy/plugins/tickets/0853-sameergoyal\n",
            "\nMessages\n  Ticket Tool (bot) · ", "    Welcome @Sameer Goyal! Support will be with you shortly.\n",
            "    screenshot.png (47 KB) https://cdn.discordapp.com/attachments/1300000000000000853/1500000000000000002/screenshot.png\n",
            "  Anish · in thread Shadowban check · ", "    Checked the shadowban flag, it is clear.\n",
            "  Sameer Goyal · in a thread · ",
        ] {
            #expect(text.contains(part), "\(part)")
        }
        #expect(
            text.hasSuffix(
                "    Any update? The automation log is attached.\n    automation-log.csv (1 KB) https://cdn.discordapp.com/attachments/1300000000000000853/1500000000000000006/automation-log.csv"
            ))
        for gone in ["Problems", "Draft", "Notes", "Fix rows", "Root cause"] {
            #expect(!text.contains(gone), "\(gone)")
        }
    }

    @Test func terminalControlsFromCustomersNeverReachTheTerminal() throws {
        var detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        detail.messages[1].text = "hi\u{1b}]52;c;cHduZWQ=\u{07} there\u{1b}[2J\u{9b}31m"
        detail.messages[1].author.displayName = "Sam\u{1b}[31m"
        detail.handover += "\u{1b}]0;title\u{07}"
        let text = TicketText.show(
            TicketShowResult(ticket: detail, fetchedAt: 0, stale: nil, row: nil), now: now,
            homeFolder: "/Users/me")
        #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        #expect(text.contains("hi]52;c;cHduZWQ= there[2J31m"))
        #expect(!TicketFiles.markdown(handover: detail.handover).unicodeScalars.contains { $0 == "\u{1b}" })
        #expect(TicketText.clean("a\tb\nc\u{1b}") == "a\tb\nc")
    }
}

struct TicketsGuideTests {
    @Test func theGuideShowsOnlyWhileTicketsIsOn() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        #expect(!TicketsGuide.isOn(configFile: file))
        for off in ["{}", #"{"plugins": {"tickets": {"enabled": false, "url": "u"}}}"#, "{not json"] {
            try off.write(to: file, atomically: true, encoding: .utf8)
            #expect(!TicketsGuide.isOn(configFile: file), "\(off)")
        }
        try #"{"plugins": {"tickets": {"url": "u"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(TicketsGuide.isOn(configFile: file))
        #expect(TicketsGuide.text.hasPrefix("## Tickets\n"))
        #expect(TicketsGuide.text.contains("canopy ticket new 853 --run 'claude \"$(cat ticket.md)\"'"))
    }
}
