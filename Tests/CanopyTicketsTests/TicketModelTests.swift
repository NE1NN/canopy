import Foundation
import Testing

@testable import CanopyTickets

struct TicketModelTests {
    @Test func decodesTheOpenList() throws {
        let list = try APIFixture.decode(TicketList.self, "tickets-open")
        #expect(
            list.tickets.map(\.name) == [
                "ticket-0850-quietcustomer", "ticket-0849-babamachine", "ticket-0853-sameergoyal",
            ])
        let waiting = list.tickets[2]
        #expect(waiting.waiting && waiting.staleHours == 7 && waiting.status == .open)
        #expect(
            waiting.owner
                == TicketOwner(email: "hindie@example.com", initials: "HI", via: "action", at: 1_790_001_200_000))
        #expect(waiting.lastActivity == Date(timeIntervalSince1970: 1_790_004_800))
        #expect(list.tickets[0].owner == nil)
    }

    @Test func decodesClosedArchivedAndIdLists() throws {
        #expect(try APIFixture.decode(TicketList.self, "tickets-closed").tickets.map(\.status) == [.closed])
        #expect(try APIFixture.decode(TicketList.self, "tickets-archived").tickets.map(\.status) == [.archived])
        #expect(
            try APIFixture.decode(TicketList.self, "tickets-ids").tickets.map(\.number) == ["0848", "0853", "0801"])
    }

    @Test func decodesTheDetail() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        #expect(detail.messages.count == 6)
        #expect(detail.messages[0].author.isBot && detail.messages[0].author.shownName == "Ticket Tool")
        #expect(
            detail.messages[0].mentions == [
                MessageMention(id: "111", username: "sameergoyal", displayName: "Sameer Goyal")
            ])
        #expect(detail.messages[1].attachments.first?.contentType == "image/png")
        #expect(detail.messages[1].author.role == .customer && detail.messages[2].author.role == .staff)
        #expect(detail.messages[3].thread == MessageThread(id: "1400000000000000002", name: nil))
        #expect(detail.messages[4].thread?.name == "Shadowban check")
        #expect(detail.messages[5].posted == Date(timeIntervalSince1970: 1_790_004_800))
        #expect(detail.handover.hasPrefix("# Handover: ticket-0853-sameergoyal\n"))
    }

    @Test func decodesMeAndErrors() throws {
        #expect(try APIFixture.decode(TicketMe.self, "me").email == "hindie@example.com")
        for (name, code) in [
            ("error-bad-request", "bad_request"), ("error-not-found", "not_found"),
            ("error-not-staff", "not_staff"), ("error-unauthorized", "unauthorized"),
        ] {
            #expect(try APIFixture.decode(TicketAPIErrorBody.self, name).error.code == code)
        }
    }

    @Test func unknownValuesAndMissingFieldsStillDecode() throws {
        let json = """
            {"id": "x", "name": "ticket-0001-a", "number": "0001", "customer": "a", "status": "snoozed", "openedAt": 1,
             "lastActivityAt": 2, "owner": null, "waiting": false, "discordUrl": "u", "extra": 1}
            """
        let summary = try JSONDecoder().decode(TicketSummary.self, from: Data(json.utf8))
        #expect(summary.status == .other("snoozed") && summary.staleHours == nil)
        #expect(!summary.status.isClosed)
        #expect(TicketStatus.archived.isClosed && TicketStatus.closed.isClosed)

        let message = """
            {"id": "m", "author": {"username": "u", "role": "moderator"}, "text": "hi", "postedAt": 5}
            """
        let decoded = try JSONDecoder().decode(TicketMessage.self, from: Data(message.utf8))
        #expect(decoded.author.role == .other("moderator") && !decoded.author.isBot)
        #expect(decoded.mentions.isEmpty && decoded.attachments.isEmpty && decoded.thread == nil)

        let bare = #"{"ticket": \#(json), "handover": "h"}"#
        let detail = try JSONDecoder().decode(TicketDetail.self, from: Data(bare.utf8))
        #expect(detail.messages.isEmpty && detail.handover == "h")
    }

    @Test func aChannelNameWithoutACustomerHasNoNumber() throws {
        let json = """
            {"tickets": [{"id": "x", "name": "closed-0079", "number": null, "customer": "0079", "status": "closed",
             "openedAt": 1, "lastActivityAt": 2, "owner": null, "waiting": false, "staleHours": null, "discordUrl": "u"}]}
            """
        let ticket = try #require(JSONDecoder().decode(TicketList.self, from: Data(json.utf8)).tickets.first)
        #expect(ticket.number == nil && TicketName.label(for: ticket.name) == "#0079")
        #expect(try JSONDecoder().decode(TicketSummary.self, from: JSONEncoder().encode(ticket)) == ticket)
    }

    @Test func encodingGivesBackTheAPIsKeys() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let again = try JSONDecoder().decode(TicketDetail.self, from: JSONEncoder().encode(detail))
        #expect(again == detail)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail.ticket)) as? [String: Any]
        #expect(raw?["status"] as? String == "open" && raw?["discordUrl"] as? String != nil)
        let author =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail.messages[2].author)) as? [String: Any]
        #expect(author?["role"] as? String == "staff")
    }
}
