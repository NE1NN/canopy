import CanopyCore
import Foundation

/// Everything that can go wrong in the Tickets plugin, each with a code agents match on and a message that says how to
/// fix it.
public enum TicketError: Error, Sendable, Equatable {
    /// The plugin is off. `url` is the one config.json names, if any.
    case off(url: String?)
    /// The plugin is on but could not start, and why.
    case notStarted(String)
    case invalidURL(String)
    case tokenRejected(url: String)
    /// ticket-manager's own words, such as "gone@example.com is not on the staff list".
    case notStaff(String, url: String)
    case unreachable(String, url: String)
    case badResponse(String, url: String)
    /// ticket-manager answered with JSON this build cannot read, and what in it.
    case unreadable(String, url: String)
    case badRequest(String)
    /// The reference that matched nothing, or the id ticket-manager does not have.
    case notFound(String)
    /// The reference, and the row titles of the tickets it matches.
    case ambiguous(String, [String])
    /// The ticket's row title, and the row's folder.
    case hasRow(String, path: String)
    /// The ticket's row title.
    case hasNoRow(String)
    case keychain(String)

    public var code: String {
        switch self {
        case .off: "plugin_off"
        case .notStarted: "plugin_not_started"
        case .invalidURL: "invalid_url"
        case .tokenRejected: "token_rejected"
        case .notStaff: "not_staff"
        case .unreachable: "tickets_unreachable"
        case .badResponse: "bad_response"
        case .unreadable: "unreadable_answer"
        case .badRequest: "bad_request"
        case .notFound: "ticket_not_found"
        case .ambiguous: "ticket_ambiguous"
        case .hasRow: "ticket_has_row"
        case .hasNoRow: "ticket_has_no_row"
        case .keychain: "keychain_failed"
        }
    }

    public var message: String {
        switch self {
        case .off(let url):
            "Tickets is off. Run `canopy ticket connect \(url ?? "<url>")` to connect it."
        case .notStarted(let reason): "Tickets did not start. \(reason)"
        case .invalidURL(let reason): reason
        case .tokenRejected(let url):
            "ticket-manager at \(url) rejected the token. Make a new one and run `canopy ticket connect \(url)` with it."
        case .notStaff(let message, let url):
            "\(Self.sentence(message)) Canopy picks it up by itself once the email is on ticket-manager's staff list "
                + "again, or run `canopy ticket connect \(url)` with another engineer's token."
        case .unreachable(let reason, let url): "Could not reach ticket-manager at \(url): \(Self.sentence(reason))"
        case .badResponse(let reason, let url):
            "\(url) did not answer like ticket-manager: \(Self.sentence(reason)) Check that it is the deployment's "
                + ".convex.site address."
        case .unreadable(let reason, let url):
            "ticket-manager at \(url) answered, but Canopy cannot read the answer: \(Self.sentence(reason)) Canopy and "
                + "ticket-manager disagree about the API, so one of them needs an update."
        case .badRequest(let message): "ticket-manager refused the request: \(Self.sentence(message))"
        case .notFound(let reference):
            "No ticket matches \"\(reference)\". Run `canopy ticket list`, with --closed for closed ones."
        case .ambiguous(let reference, let names):
            "\"\(reference)\" matches \(Self.list(names)). Pass one of those."
        case .hasRow(let name, let path):
            "\(name) already has a row at \(path). Run `canopy ticket select \(name)` to show it."
        case .hasNoRow(let name): "\(name) has no row. Run `canopy ticket new \(name)` to open one."
        case .keychain(let description): "The Keychain refused: \(description)"
        }
    }

    /// The section's warning, for the errors only connecting again or ticket-manager's admins fix.
    public var warning: String? {
        switch self {
        case .tokenRejected, .notStaff: message
        default: nil
        }
    }

    /// ticket-manager is not answering as it should, so the refresh schedule waits longer before asking again.
    public var backsOff: Bool {
        switch self {
        case .tokenRejected, .notStaff, .unreachable, .badResponse, .unreadable: true
        default: false
        }
    }

    public var controlError: ControlError {
        ControlError(code: code, message: message)
    }

    /// `error` as a TicketError. Anything else means no answer came.
    public static func from(_ error: any Error, url: String) -> TicketError {
        switch error {
        case let error as TicketError: error
        case let error as URLError where error.code == .timedOut:
            .unreachable("no answer within \(Int(URLSessionTicketTransport.timeout)) seconds", url: url)
        case let error as URLError: .unreachable(error.localizedDescription, url: url)
        case let error as ControlError: .unreachable(error.message, url: url)
        case is CancellationError: .unreachable("the request was cancelled", url: url)
        default: .unreachable("\(error)", url: url)
        }
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
