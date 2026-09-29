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

    @Test func showPrintsEverySection() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let fix = Row(
            repoPath: "/r/solis-v1", path: "/Users/me/.canopy/worktrees/solis-v1/fix-shadowban-check",
            branch: "fix/shadowban-check", head: nil, rowClass: .canopy)
        let row = PluginRow(
            plugin: "tickets", item: detail.ticket.id, title: "0853-sameergoyal",
            path: "/Users/me/.canopy/plugins/tickets/0853-sameergoyal")
        let result = TicketShowResult(
            ticket: detail, fetchedAt: 1_790_029_000_000, stale: nil, row: row, fixRows: [fix])
        let text = TicketText.show(result, now: now, homeFolder: "/Users/me")
        #expect(text.hasPrefix("ticket-0853-sameergoyal · open · sameergoyal · owner HI · waiting 7h\n"))
        for part in [
            "\nDiscord: https://discord.com/channels/1100000000000000000/1300000000000000853\n",
            "\nRow: ~/.canopy/plugins/tickets/0853-sameergoyal\n",
            "\nMessages\n  Ticket Tool (bot) · ", "    Welcome @Sameer Goyal! Support will be with you shortly.\n",
            "    screenshot.png (47 KB) https://cdn.discordapp.com/attachments/1300000000000000853/1500000000000000002/screenshot.png\n",
            "  Anish · in thread Shadowban check · ", "    Checked the shadowban flag, it is clear.\n",
            "  Sameer Goyal · in a thread · ",
            "\nProblems\n  open · Automations stopped posting · bug\n    - No posts since yesterday\n",
            "  resolved · Finding the automation export · how-to\n",
            "\nDraft · ok · 6 h ago\n  Hi Sameer, the posting worker",
            "\nNotes\n  hindie@example.com · 5 h ago\n    Root cause: the posting worker skips accounts flagged for review.\n",
            "\nFix rows\n  fix/shadowban-check · solis-v1 · ~/.canopy/worktrees/solis-v1/fix-shadowban-check",
        ] {
            #expect(text.contains(part), "\(part)")
        }
    }

    @Test func emptySectionsAreLeftOut() throws {
        var detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        detail.problems = []
        detail.draft = nil
        detail.notes = []
        detail.ticket.owner = nil
        detail.ticket.waiting = false
        let text = TicketText.show(
            TicketShowResult(ticket: detail, fetchedAt: 0, stale: nil, row: nil, fixRows: []), now: now,
            homeFolder: "/Users/me")
        #expect(text.hasPrefix("ticket-0853-sameergoyal · open · sameergoyal\n"))
        for part in ["Problems", "Draft", "Notes", "Fix rows", "Row:"] {
            #expect(!text.contains(part), "\(part)")
        }
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
