import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

struct TicketListingTests {
    let open = try! APIFixture.decode(TicketList.self, "tickets-open").tickets
    let closed =
        try! APIFixture.decode(TicketList.self, "tickets-closed").tickets
        + APIFixture.decode(TicketList.self, "tickets-archived").tickets

    func numbers(_ query: TicketListQuery, _ tickets: [TicketSummary]? = nil, me: String? = "hindie@example.com")
        -> [String]
    {
        TicketListing.list(tickets ?? open, query, me: me).map(\.number)
    }

    @Test func waitingFirstThenLatestActivity() {
        #expect(numbers(TicketListQuery()) == ["0853", "0850", "0849"])
        #expect(numbers(TicketListQuery(), closed) == ["0848", "0801"])
    }

    @Test func mineUnownedAnyoneAndWaiting() {
        #expect(numbers(TicketListQuery(owner: .mine)) == ["0853"])
        #expect(numbers(TicketListQuery(owner: .mine), me: "HINDIE@example.com") == ["0853"])
        #expect(numbers(TicketListQuery(owner: .mine), me: nil).isEmpty)
        #expect(numbers(TicketListQuery(owner: .unowned)) == ["0850"])
        #expect(numbers(TicketListQuery(waitingOnly: true)) == ["0853"])
        #expect(numbers(TicketListQuery(owner: .unowned, waitingOnly: true)).isEmpty)
    }

    @Test func searchMatchesNameAndCustomer() {
        #expect(numbers(TicketListQuery(text: "baba")) == ["0849"])
        #expect(numbers(TicketListQuery(text: "0850")) == ["0850"])
        #expect(numbers(TicketListQuery(text: "ticket QUIET")) == ["0850"])
        #expect(numbers(TicketListQuery(text: "nobody")).isEmpty)
    }

    @Test func equalTimesKeepAFixedOrder() {
        var tickets = open
        for index in tickets.indices { tickets[index].lastActivityAt = 1 }
        tickets[0].waiting = false
        #expect(numbers(TicketListQuery(), tickets) == ["0853", "0849", "0850"])
    }

    @Test func thePickersFilters() {
        #expect(TicketListing.filters.choices.map(\.id) == ["mine", "unowned", "anyone"])
        #expect(TicketListing.filters.choices.map(\.title) == ["Mine", "Unowned", "Anyone"])
        #expect(TicketListing.filters.defaultChoice == "anyone")
        #expect(TicketListing.filters.toggles.map(\.id) == ["closed"])
        #expect(TicketsPlugin().info.newRowTitle == "New Ticket Row")
    }

    @Test func pickerItems() {
        let now = Date(timeIntervalSince1970: 1_790_030_000)
        let item = TicketListing.item(open[2], now: now)
        #expect(item.id == "0000000000000000000010001tickets")
        #expect(item.title == "0853-sameergoyal")
        #expect(item.subtitle == "sameergoyal · 7h ago")
        #expect(item.accessories.map(\.kind) == [.dot, .initials])
        #expect(
            item.accessories.last
                == .initials(
                    "HI", color: TicketLook.ownerColor("hindie@example.com"), help: "Owned by hindie@example.com"))
        #expect(TicketListing.item(closed[1], now: now).accessories.map(\.text) == ["archived"])
        #expect(TicketListing.item(closed[0], now: now).accessories.map(\.text) == ["closed", "HI"])
    }

    @Test func ages() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        #expect(TicketAge.span(from: now.addingTimeInterval(-25_200), to: now) == "7h")
        #expect(TicketAge.span(from: now.addingTimeInterval(-30), to: now) == "now")
        #expect(TicketAge.span(from: now.addingTimeInterval(-720), to: now) == "12m")
        #expect(TicketAge.span(from: now.addingTimeInterval(-3 * 86_400), to: now) == "3d")
        #expect(TicketAge.span(from: now.addingTimeInterval(60), to: now) == "now")
        #expect(TicketAge.ago(now.addingTimeInterval(-20), now: now) == "20 s ago")
        #expect(TicketAge.ago(now.addingTimeInterval(-180), now: now) == "3 min ago")
        #expect(TicketAge.ago(now.addingTimeInterval(-7_200), now: now) == "2 h ago")
        #expect(TicketAge.ago(now.addingTimeInterval(-4 * 86_400), now: now) == "4 d ago")
        #expect(TicketAge.ago(now.addingTimeInterval(-2), now: now) == "just now")
    }
}
