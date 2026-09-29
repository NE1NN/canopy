import CanopyCore
import Testing

@testable import CanopyTickets

struct TicketLookTests {
    @Test func aWaitingOpenTicket() throws {
        let ticket = try APIFixture.decode(TicketList.self, "tickets-open").tickets[2]
        let look = TicketLook.look(title: "0853-sameergoyal", summary: ticket, isMissing: false)
        #expect(look == PluginRowLook(label: "#0853", accessories: [.dot(.orange, help: "Customer waiting")]))
    }

    @Test func closedAndArchivedTicketsAreTaggedClosed() throws {
        for fixture in ["tickets-closed", "tickets-archived"] {
            let ticket = try APIFixture.decode(TicketList.self, fixture).tickets[0]
            let look = TicketLook.look(title: TicketName.rowTitle(for: ticket.name), summary: ticket, isMissing: false)
            #expect(look.accessories == [.tag("closed", help: ticket.status == .closed ? "Closed" : "Archived")])
        }
    }

    @Test func withoutASummaryOnlyTheLabel() {
        #expect(
            TicketLook.look(title: "0853-sameergoyal", summary: nil, isMissing: false) == PluginRowLook(label: "#0853"))
        #expect(TicketLook.look(title: "0853-sameergoyal", summary: nil, isMissing: true).isMissing)
        #expect(TicketLook.look(title: "general", summary: nil, isMissing: false).label == nil)
    }

    @Test func ownersKeepTheirColorAndNeverTakeOrange() {
        #expect(TicketLook.ownerColor("hindie@example.com") == TicketLook.ownerColor("HINDIE@example.com"))
        let colors = Set((0..<200).map { TicketLook.ownerColor("user\($0)@example.com") })
        #expect(!colors.contains(.orange) && !colors.contains(.accent) && colors.count > 2)
    }
}
