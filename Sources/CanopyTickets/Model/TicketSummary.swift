import Foundation

/// Where a ticket is in its life. Closed and archived tickets have left Discord's open list.
public enum TicketStatus: Sendable, Equatable, Hashable, Codable {
    case open, closed, archived
    /// A status this build does not know, kept as sent.
    case other(String)

    public init(_ text: String) {
        switch text {
        case "open": self = .open
        case "closed": self = .closed
        case "archived": self = .archived
        default: self = .other(text)
        }
    }

    public var text: String {
        switch self {
        case .open: "open"
        case .closed: "closed"
        case .archived: "archived"
        case .other(let text): text
        }
    }

    public var isClosed: Bool { self == .closed || self == .archived }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// The engineer ticket-manager says owns a ticket.
public struct TicketOwner: Sendable, Equatable, Codable {
    public var email: String
    public var initials: String
    /// How ticket-manager decided the owner, such as "action" or "reply".
    public var via: String?
    /// Milliseconds since the epoch.
    public var at: Int64?

    public init(email: String, initials: String, via: String? = nil, at: Int64? = nil) {
        self.email = email
        self.initials = initials
        self.via = via
        self.at = at
    }
}

/// A ticket as ticket-manager's lists give it.
public struct TicketSummary: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// The Discord channel's name, such as `ticket-0853-sameergoyal`.
    public var name: String
    public var number: String
    public var customer: String
    public var status: TicketStatus
    /// Milliseconds since the epoch, as ticket-manager keeps times.
    public var openedAt: Int64
    public var lastActivityAt: Int64
    public var owner: TicketOwner?
    /// The customer spoke last and staff have not answered.
    public var waiting: Bool
    public var staleHours: Int?
    public var discordUrl: String

    public init(
        id: String, name: String, number: String, customer: String, status: TicketStatus, openedAt: Int64,
        lastActivityAt: Int64, owner: TicketOwner? = nil, waiting: Bool = false, staleHours: Int? = nil,
        discordUrl: String
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.customer = customer
        self.status = status
        self.openedAt = openedAt
        self.lastActivityAt = lastActivityAt
        self.owner = owner
        self.waiting = waiting
        self.staleHours = staleHours
        self.discordUrl = discordUrl
    }

    public var lastActivity: Date { Date(milliseconds: lastActivityAt) }
    public var opened: Date { Date(milliseconds: openedAt) }
}

/// `{"tickets": [...]}`.
public struct TicketList: Sendable, Equatable, Codable {
    public var tickets: [TicketSummary]

    public init(tickets: [TicketSummary]) {
        self.tickets = tickets
    }
}

/// `{"email": ...}`, the engineer a token belongs to.
public struct TicketMe: Sendable, Equatable, Codable {
    public var email: String
}

/// `{"error": {"code", "message"}}`.
public struct TicketAPIErrorBody: Sendable, Equatable, Codable {
    public struct Detail: Sendable, Equatable, Codable {
        public var code: String
        public var message: String
    }

    public var error: Detail
}

extension Date {
    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
