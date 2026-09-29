import Foundation

/// ticket-manager's read-only API, under `/api/v1/` on the deployment's `.convex.site` address.
public struct TicketAPI: Sendable {
    public static let maximumIDs = 50

    public let base: URL
    private let token: String
    private let transport: any TicketTransport

    public init(base: URL, token: String, transport: any TicketTransport) {
        self.base = base
        self.token = token
        self.transport = transport
    }

    /// The email of the engineer the token belongs to.
    public func me() async throws -> String {
        try await get("me", query: nil, notFound: nil, as: TicketMe.self).value.email
    }

    /// Every ticket with that status, newest activity first.
    public func tickets(status: TicketStatus) async throws -> [TicketSummary] {
        try await get("tickets", query: "status=" + Self.encoded(status.text), notFound: nil, as: TicketList.self)
            .value.tickets
    }

    /// Up to 50 tickets by id, whatever their status, in the order asked, leaving out ids ticket-manager does not know.
    /// A malformed id fails the whole request with `TicketError.badRequest`.
    public func tickets(ids: [String]) async throws -> [TicketSummary] {
        precondition(ids.count <= Self.maximumIDs, "ticket-manager takes at most \(Self.maximumIDs) ids at once")
        let query = "ids=" + ids.map(Self.encoded).joined(separator: ",")
        return try await get("tickets", query: query, notFound: nil, as: TicketList.self).value.tickets
    }

    /// The ticket's detail, and the response's bytes, which ticket.json keeps.
    public func ticket(id: String) async throws -> (detail: TicketDetail, data: Data) {
        let (detail, data) = try await get(
            "tickets/" + Self.encoded(id), query: nil, notFound: id, as: TicketDetail.self)
        return (detail, data)
    }

    /// `notFound` names what a 404 means is gone. Without it, a 404 means there is no API at this address.
    private func get<T: Decodable>(_ path: String, query: String?, notFound: String?, as type: T.Type) async throws
        -> (value: T, data: Data)
    {
        let url = self.url(path, query: query)
        let reply: HTTPReply
        do {
            reply = try await transport.get(url, token: token)
        } catch {
            throw TicketError.from(error, url: base.absoluteString)
        }
        let address = base.absoluteString
        switch reply.status {
        case 200..<300:
            guard let value = try? JSONDecoder().decode(type, from: reply.body) else {
                throw TicketError.badResponse("its answer was not the JSON Canopy expects", url: address)
            }
            return (value, reply.body)
        case 300..<400:
            let target = reply.headers["location"].map { " to \($0)" } ?? ""
            throw TicketError.badResponse("it redirected\(target)", url: address)
        case 400: throw TicketError.badRequest(Self.serverMessage(reply) ?? "ticket-manager refused the request")
        case 401: throw TicketError.tokenRejected(url: address)
        case 403:
            throw TicketError.notStaff(
                Self.serverMessage(reply) ?? "The token's email is not on the staff list", url: address)
        case 404:
            if let notFound { throw TicketError.notFound(notFound) }
            throw TicketError.badResponse("no ticket-manager API here (HTTP 404)", url: address)
        case 500..<600: throw TicketError.unreachable("it answered HTTP \(reply.status)", url: address)
        default: throw TicketError.badResponse("it answered HTTP \(reply.status)", url: address)
        }
    }

    private func url(_ path: String, query: String?) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/api/v1/" + path
        components.percentEncodedQuery = query
        return components.url ?? base
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private static func serverMessage(_ reply: HTTPReply) -> String? {
        (try? JSONDecoder().decode(TicketAPIErrorBody.self, from: reply.body))?.error.message
    }
}
