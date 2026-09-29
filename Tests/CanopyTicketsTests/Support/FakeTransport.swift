import Foundation

@testable import CanopyTickets

extension HTTPReply {
    /// A reply of `status` carrying a fixture's bytes, with the Bearer challenge a 401 sends.
    static func fixture(_ status: Int, _ name: String) throws -> HTTPReply {
        HTTPReply(
            status: status, headers: status == 401 ? ["www-authenticate": "Bearer"] : [:],
            body: try APIFixture.data(name))
    }

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPReply {
        HTTPReply(status: status, headers: [:], body: try! JSONEncoder().encode(value))
    }
}

/// ticket-manager in memory: the fixture tickets, served the way the API serves them, with the replies and failures a
/// test sets on top, and a record of every request.
actor FakeTransport: TicketTransport {
    private var token: String
    private var summaries: [TicketSummary]
    private var details: [String: Data] = [:]
    private var malformed: Set<String> = []
    private var overrides: [String: Result<HTTPReply, URLError>] = [:]
    private var failure: URLError?
    private(set) var requests: [URL] = []
    private(set) var tokens: [String] = []
    private var stalling: Set<String> = []
    private var stalled: [(key: String, continuation: CheckedContinuation<Void, Never>)] = []

    init(token: String) {
        self.token = token
        summaries = ["tickets-open", "tickets-closed", "tickets-archived"].flatMap {
            (try? APIFixture.decode(TicketList.self, $0).tickets) ?? []
        }
        let detail = try! APIFixture.data("ticket-detail")
        details["0000000000000000000010001tickets"] = detail
    }

    func get(_ url: URL, token: String) async throws -> HTTPReply {
        requests.append(url)
        tokens.append(token)
        if let failure { throw failure }
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        if stalling.contains(key) {
            await withCheckedContinuation { stalled.append((key, $0)) }
        }
        if let override = overrides[key] { return try override.get() }
        guard token == self.token else { return try .fixture(401, "error-unauthorized") }
        return try answer(url)
    }

    private func answer(_ url: URL) throws -> HTTPReply {
        let path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if path == "/api/v1/me" { return try .fixture(200, "me") }
        if path == "/api/v1/tickets" {
            if let ids = query.first(where: { $0.name == "ids" })?.value {
                let asked = ids.split(separator: ",").map(String.init)
                if asked.count > 50 || asked.contains(where: malformed.contains) {
                    return try .fixture(400, "error-bad-request")
                }
                return .json(TicketList(tickets: asked.compactMap { id in summaries.first { $0.id == id } }))
            }
            let status = TicketStatus(query.first { $0.name == "status" }?.value ?? "open")
            let listed = summaries.filter { $0.status == status }.sorted { $0.lastActivityAt > $1.lastActivityAt }
            return .json(TicketList(tickets: listed))
        }
        if path.hasPrefix("/api/v1/tickets/") {
            let id = String(path.dropFirst("/api/v1/tickets/".count))
            guard let summary = summaries.first(where: { $0.id == id }) else {
                return try .fixture(404, "error-not-found")
            }
            if let data = details[id] {
                var detail = try JSONDecoder().decode(TicketDetail.self, from: data)
                detail.ticket = summary
                return .json(detail)
            }
            return .json(
                TicketDetail(
                    ticket: summary, messages: [], problems: [], draft: nil, handover: "# Handover: \(summary.name)\n",
                    notes: []))
        }
        return try .fixture(404, "error-not-found")
    }

    func set(_ key: String, _ reply: HTTPReply) {
        overrides[key] = .success(reply)
    }

    func fail(_ key: String, _ error: URLError) {
        overrides[key] = .failure(error)
    }

    /// Every request fails with `error` until it is set to nil.
    func failEverything(_ error: URLError?) {
        failure = error
    }

    func setToken(_ token: String) {
        self.token = token
    }

    /// Holds requests for `key` until `release(key)`, as a slow ticket-manager would.
    func stall(_ key: String) {
        stalling.insert(key)
    }

    func release(_ key: String) {
        stalling.remove(key)
        for waiting in stalled where waiting.key == key { waiting.continuation.resume() }
        stalled.removeAll { $0.key == key }
    }

    var stalledCount: Int { stalled.count }

    func clearRequests() {
        requests = []
        tokens = []
    }

    /// Ids ticket-manager answers 400 for, as it does for an id from another deployment.
    func markMalformed(_ id: String) {
        malformed.insert(id)
    }

    func addClosed(number: String, customer: String, id: String) {
        summaries.append(
            TicketSummary(
                id: id, name: "closed-\(number)-\(customer)", number: number, customer: customer, status: .closed,
                openedAt: 1_789_000_000_000, lastActivityAt: 1_789_000_000_000,
                discordUrl: "https://discord.com/channels/1/\(id)"))
    }

    func remove(_ id: String) {
        summaries.removeAll { $0.id == id }
    }

    func bumpActivity(of id: String, to milliseconds: Int64) {
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return }
        summaries[index].lastActivityAt = milliseconds
    }
}
