import CanopyCore
import Foundation

/// The plugin's section of config.json: `url`, ticket-manager's address, `run`, the command new ticket rows start
/// with, and `web`, ticket-manager's page for a ticket, with `{id}` where the ticket's id goes.
public struct TicketSettings: Sendable, Equatable {
    public var url: URL
    public var web: String?
    public var run: String?

    public init(url: URL, web: String? = nil, run: String? = nil) {
        self.url = url
        self.web = web
        self.run = run
    }

    /// Throws `.notStarted` without a usable `url`. A `web` that is not a usable template is left out.
    public init(_ section: JSONValue) throws {
        guard case .object(let fields) = section, case .string(let text)? = fields["url"] else {
            throw TicketError.notStarted("config.json has no url for Tickets. Run `canopy ticket connect <url>`.")
        }
        do {
            url = try Self.url(text)
        } catch let error as TicketError {
            throw TicketError.notStarted(error.message)
        }
        if case .string(let web)? = fields["web"] { self.web = try? Self.web(web) }
        if case .string(let run)? = fields["run"], !run.trimmingCharacters(in: .whitespaces).isEmpty { self.run = run }
    }

    /// ticket-manager's address: `https://` anywhere, and `http://` only on this Mac, so a token never crosses the
    /// network in the clear. A trailing `/` or `/api/v1` is dropped.
    public static func url(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else {
            throw TicketError.invalidURL(
                "\(text) is not a ticket-manager address. Pass its .convex.site URL, such as "
                    + "https://<deployment>.convex.site.")
        }
        switch scheme {
        case "https": break
        case "http" where ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()):
            break
        case "http":
            throw TicketError.invalidURL(
                "Canopy sends the token over https:// only, or http:// on this Mac. Use https://\(host).")
        default:
            throw TicketError.invalidURL("\(text) is not an http or https address.")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api/v1") { path.removeLast("/api/v1".count) }
        components.scheme = scheme
        components.percentEncodedPath = path
        guard let url = components.url else { throw TicketError.invalidURL("\(text) is not a URL.") }
        return url
    }

    /// A ticket-manager page template must be an http or https address with `{id}` in it.
    public static func web(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("{id}"), let url = URL(string: text.replacingOccurrences(of: "{id}", with: "id")),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false
        else {
            throw TicketError.invalidURL(
                "ticket-manager's page must be an http or https address with {id} where the ticket's id goes, such "
                    + "as https://tickets.example.com/tickets/{id}.")
        }
        return text
    }

    /// The ticket's page in ticket-manager, from the template.
    public static func webURL(_ template: String, for ticket: TicketSummary) -> URL? {
        let id = ticket.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ticket.id
        return URL(string: template.replacingOccurrences(of: "{id}", with: id))
    }
}
