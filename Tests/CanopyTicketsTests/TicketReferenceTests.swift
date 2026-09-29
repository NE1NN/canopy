import Testing

@testable import CanopyTickets

struct TicketReferenceTests {
    @Test func namesComeApart() {
        #expect(
            TicketName("ticket-0853-sameergoyal") == TicketName(number: 853, digits: "0853", customer: "sameergoyal"))
        #expect(TicketName("closed-0848-shathrem").number == 848)
        #expect(TicketName("0853-sameer-goyal").customer == "sameer-goyal")
        #expect(TicketName("0853").customer == nil)
        #expect(TicketName("general").number == nil)
        #expect(TicketName.rowTitle(for: "ticket-0853-sameergoyal") == "0853-sameergoyal")
        #expect(TicketName.rowTitle(for: "closed-0848-shathrem") == "0848-shathrem")
        #expect(TicketName.rowTitle(for: "general") == "general")
        #expect(TicketName.label(for: "0853-sameergoyal") == "#0853")
        #expect(TicketName.label(for: "general") == nil)
    }

    @Test func everySpecFormParses() {
        for text in ["853", "0853", " 0853 ", "#0853"] {
            #expect(TicketReference(text) == .number(853, customer: nil), "\(text)")
        }
        for text in ["0853-sameergoyal", "ticket-0853-sameergoyal", "closed-0853-sameergoyal"] {
            #expect(TicketReference(text) == .number(853, customer: "sameergoyal"), "\(text)")
        }
        #expect(TicketReference("0000000000000000000010001tickets") == .id("0000000000000000000010001tickets"))
        #expect(TicketReference("   ") == nil)
    }

    @Test func numbersMatchIgnoringZerosAndCustomersIgnoringCase() {
        #expect(TicketReference("853")!.matches("ticket-0853-sameergoyal"))
        #expect(TicketReference("0853-SAMEERGOYAL")!.matches("closed-0853-sameergoyal"))
        #expect(TicketReference("853")!.matches("0853-sameergoyal"))
        #expect(!TicketReference("0853-other")!.matches("ticket-0853-sameergoyal"))
        #expect(!TicketReference("85")!.matches("ticket-0853-sameergoyal"))
        #expect(!TicketReference("x1")!.matches("ticket-0853-sameergoyal"))
    }

    @Test func pickingFindsOneRefusesTwoAndFallsThrough() throws {
        let open = TicketResolution.Candidate(id: "a", name: "ticket-0853-sameergoyal")
        let row = TicketResolution.Candidate(id: "a", name: "0853-sameergoyal")
        let closed = TicketResolution.Candidate(id: "b", name: "closed-0853-other")
        #expect(try TicketResolution.pick(.number(853, customer: nil), text: "853", among: [row, open]) == .found("a"))
        #expect(try TicketResolution.pick(.number(900, customer: nil), text: "900", among: [open]) == .none)
        #expect(throws: TicketError.ambiguous("853", ["0853-other", "0853-sameergoyal"])) {
            try TicketResolution.pick(.number(853, customer: nil), text: "853", among: [open, closed])
        }
        #expect(
            try TicketResolution.pick(.number(853, customer: "other"), text: "0853-other", among: [open, closed])
                == .found("b"))
        #expect(try TicketResolution.pick(.id("b"), text: "b", among: [open, closed]) == .found("b"))
        #expect(try TicketResolution.pick(.id("c"), text: "c", among: [open, closed]) == .none)
    }
}
