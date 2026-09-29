import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

struct TicketAPITests {
    let base = URL(string: "https://tm.example.convex.site")!
    let id853 = "0000000000000000000010001tickets"
    let id848 = "0000000000000000000010004tickets"

    @Test func sendsTheTokenToEachRoute() async throws {
        let transport = FakeTransport(token: "t0k")
        let api = TicketAPI(base: base, token: "t0k", transport: transport)

        #expect(try await api.me() == "hindie@example.com")
        #expect(try await api.tickets(status: .closed).map(\.number) == ["0848"])
        #expect(try await api.tickets(ids: [id848, id853]).map(\.number) == ["0848", "0853"])
        let (detail, data) = try await api.ticket(id: id853)
        #expect(detail.ticket.number == "0853")
        #expect(try JSONDecoder().decode(TicketDetail.self, from: data) == detail)

        #expect(
            await transport.requests.map(\.absoluteString) == [
                "https://tm.example.convex.site/api/v1/me",
                "https://tm.example.convex.site/api/v1/tickets?status=closed",
                "https://tm.example.convex.site/api/v1/tickets?ids=\(id848),\(id853)",
                "https://tm.example.convex.site/api/v1/tickets/\(id853)",
            ])
        #expect(await transport.tokens == ["t0k", "t0k", "t0k", "t0k"])
    }

    @Test func aBaseWithAPathKeepsIt() async throws {
        let transport = FakeTransport(token: "t")
        let api = TicketAPI(base: URL(string: "http://127.0.0.1:8123/tm/")!, token: "t", transport: transport)
        _ = try? await api.me()
        #expect(await transport.requests.map(\.absoluteString) == ["http://127.0.0.1:8123/tm/api/v1/me"])
    }

    @Test func eachStatusBecomesItsError() async throws {
        let transport = FakeTransport(token: "t")
        let api = TicketAPI(base: base, token: "t", transport: transport)
        let url = base.absoluteString
        let cases: [(HTTPReply, TicketError)] = [
            (try .fixture(401, "error-unauthorized"), .tokenRejected(url: url)),
            (try .fixture(403, "error-not-staff"), .notStaff("gone@example.com is not on the staff list", url: url)),
            (try .fixture(400, "error-bad-request"), .badRequest("status must be open, closed, or archived")),
            (HTTPReply(status: 502, headers: [:], body: Data()), .unreachable("it answered HTTP 502", url: url)),
            (
                HTTPReply(status: 200, headers: [:], body: Data("<html>".utf8)),
                .badResponse("its answer was not JSON", url: url)
            ),
            (
                HTTPReply(status: 302, headers: ["location": "https://elsewhere"], body: Data()),
                .badResponse("it redirected to https://elsewhere", url: url)
            ),
            (try .fixture(404, "error-not-found"), .badResponse("no ticket-manager API here (HTTP 404)", url: url)),
            (HTTPReply(status: 418, headers: [:], body: Data()), .badResponse("it answered HTTP 418", url: url)),
        ]
        for (reply, error) in cases {
            await transport.set("/api/v1/me", reply)
            await #expect(throws: error) { try await api.me() }
        }
    }

    @Test func anAnswerCanopyCannotReadNamesTheFieldAndTheTicket() async throws {
        let transport = FakeTransport(token: "t")
        let api = TicketAPI(base: base, token: "t", transport: transport)
        let url = base.absoluteString
        let good = """
            {"id": "a", "name": "ticket-0001-a", "number": "0001", "customer": "a", "status": "open", "openedAt": 1,
             "lastActivityAt": 2, "owner": null, "waiting": false, "staleHours": null, "discordUrl": "u"}
            """
        let cases: [(String, String)] = [
            (
                good.replacingOccurrences(of: #""customer": "a""#, with: #""customer": null"#),
                "`tickets[1].customer` is null, where Canopy expects text (ticket ticket-0001-a)"
            ),
            (
                good.replacingOccurrences(of: #""openedAt": 1"#, with: #""openedAt": "1""#),
                "`tickets[1].openedAt` is not a whole number (ticket ticket-0001-a)"
            ),
            (
                good.replacingOccurrences(of: #""discordUrl": "u""#, with: #""other": 1"#),
                "`tickets[1].discordUrl` is missing (ticket ticket-0001-a)"
            ),
        ]
        for (ticket, reason) in cases {
            let body = #"{"tickets": [\#(good), \#(ticket)]}"#
            await transport.set(
                "/api/v1/tickets?status=open", HTTPReply(status: 200, headers: [:], body: Data(body.utf8)))
            await #expect(throws: TicketError.unreadable(reason, url: url)) { try await api.tickets(status: .open) }
        }

        await transport.set("/api/v1/me", HTTPReply(status: 200, headers: [:], body: Data(#"{"user": "x"}"#.utf8)))
        await #expect(throws: TicketError.unreadable("`email` is missing", url: url)) { try await api.me() }
        await transport.set("/api/v1/me", HTTPReply(status: 200, headers: [:], body: Data("[]".utf8)))
        await #expect(throws: TicketError.unreadable("the answer is not an object", url: url)) { try await api.me() }
    }

    @Test func aTicketThatIsGoneIsNotFound() async throws {
        let transport = FakeTransport(token: "t")
        await #expect(throws: TicketError.notFound("zz")) {
            try await TicketAPI(base: base, token: "t", transport: transport).ticket(id: "zz")
        }
    }

    @Test func aMalformedIdIsABadRequest() async throws {
        let transport = FakeTransport(token: "t")
        await transport.markMalformed("bad")
        await #expect(throws: TicketError.badRequest("status must be open, closed, or archived")) {
            try await TicketAPI(base: base, token: "t", transport: transport).tickets(ids: [id853, "bad"])
        }
    }

    @Test func noAnswerIsUnreachable() async throws {
        let transport = FakeTransport(token: "t")
        let api = TicketAPI(base: base, token: "t", transport: transport)
        await transport.fail("/api/v1/me", URLError(.timedOut))
        await #expect(throws: TicketError.unreachable("no answer within 15 seconds", url: base.absoluteString)) {
            try await api.me()
        }
        await transport.fail("/api/v1/me", URLError(.cannotConnectToHost))
        await #expect { try await api.me() } throws: {
            guard case .unreachable(let reason, _)? = $0 as? TicketError else { return false }
            return !reason.isEmpty
        }
    }

    @Test func aReasonThatEndsASentenceGetsOnePeriod() {
        let url = "https://tm.example.convex.site"
        #expect(
            TicketError.unreachable("Could not connect to the server.", url: url).message
                == "Could not reach ticket-manager at \(url): Could not connect to the server.")
        #expect(
            TicketError.badResponse("it answered HTTP 418.", url: url).message.hasPrefix(
                "\(url) did not answer like ticket-manager: it answered HTTP 418. Check"))
    }

    @Test func errorsMapToCodesWarningsAndBackoff() {
        let url = "https://tm.example.convex.site"
        #expect(TicketError.tokenRejected(url: url).code == "token_rejected")
        #expect(TicketError.tokenRejected(url: url).warning?.contains("canopy ticket connect \(url)") == true)
        #expect(TicketError.notStaff("x", url: url).code == "not_staff")
        #expect(TicketError.notStaff("x", url: url).warning != nil)
        #expect(TicketError.unreachable("r", url: url).code == "tickets_unreachable")
        #expect(TicketError.unreachable("r", url: url).warning == nil)
        #expect(TicketError.off(url: nil).message.contains("canopy ticket connect <url>"))
        #expect(TicketError.off(url: url).code == "plugin_off")
        #expect(
            TicketError.ambiguous("853", ["0853-a", "0853-b"]).message
                == "\"853\" matches 0853-a and 0853-b. Pass one of those.")
        let unreadable = TicketError.unreadable("`tickets[0].number` is null", url: url)
        #expect(unreadable.code == "unreadable_answer" && unreadable.warning == nil)
        #expect(
            unreadable.message
                == "ticket-manager at \(url) answered, but Canopy cannot read the answer: `tickets[0].number` is null. "
                + "Canopy and ticket-manager disagree about the API, so one of them needs an update.")
        #expect(
            [
                TicketError.unreachable("r", url: url), .badResponse("r", url: url), .unreadable("r", url: url),
                .tokenRejected(url: url),
            ]
            .allSatisfy { $0.backsOff })
        #expect(![TicketError.notFound("1"), .badRequest("b")].contains { $0.backsOff })
        #expect(TicketError.from(ControlError(code: "x", message: "y"), url: url) == .unreachable("y", url: url))
        #expect(TicketError.from(TicketError.notFound("1"), url: url) == .notFound("1"))
        let control = TicketError.hasRow("0853-s", path: "/p").controlError
        #expect(control.code == "ticket_has_row" && control.message.contains("canopy ticket select 0853-s"))
    }
}
