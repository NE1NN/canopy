import CanopyCore
import Foundation

/// A ticket as `canopy ticket list` lists it, with its row.
public struct TicketListEntry: Sendable, Equatable, Codable {
    public var ticket: TicketSummary
    /// The ticket's row, or null.
    public var row: PluginRow?

    public init(ticket: TicketSummary, row: PluginRow?) {
        self.ticket = ticket
        self.row = row
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ticket, forKey: .ticket)
        try container.encode(row, forKey: .row)
    }
}

/// A ticket as `canopy ticket show` prints it.
public struct TicketShowResult: Sendable, Equatable, Codable {
    public var ticket: TicketDetail
    /// Milliseconds since the epoch.
    public var fetchedAt: Int64
    /// Why this copy may be old, and how old it is, when ticket-manager could not be reached.
    public var stale: String?
    public var row: PluginRow?
    /// The worktree rows linked to the ticket.
    public var fixRows: [Row]

    public init(ticket: TicketDetail, fetchedAt: Int64, stale: String?, row: PluginRow?, fixRows: [Row]) {
        self.ticket = ticket
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.row = row
        self.fixRows = fixRows
    }
}

/// The `tickets.*` control methods, which `canopy ticket` sends.
public enum TicketMethod {
    /// The plugin's id.
    public static let plugin = "tickets"
    public static let connect = "tickets.connect"
    public static let disconnect = "tickets.disconnect"
    public static let list = "tickets.list"
    public static let new = "tickets.new"
    public static let show = "tickets.show"
    public static let select = "tickets.select"
    public static let remove = "tickets.remove"

    public static let all: Set<String> = [connect, disconnect, list, new, show, select, remove]
    /// Left out of the activity log.
    public static let readOnly: Set<String> = [list, show]
}

public struct TicketConnectParams: Codable, Sendable {
    public var url: String
    /// Never written to the activity log.
    public var token: String
    /// ticket-manager's page for a ticket, with `{id}` where the ticket's id goes.
    public var web: String?

    public init(url: String, token: String, web: String? = nil) {
        self.url = url
        self.token = token
        self.web = web
    }
}

public struct TicketConnectResult: Codable, Sendable, Equatable {
    public var url: String
    /// The engineer the token belongs to.
    public var email: String
    public var web: String?

    public init(url: String, email: String, web: String?) {
        self.url = url
        self.email = email
        self.web = web
    }
}

public struct TicketDisconnectParams: Codable, Sendable {
    /// Closes the terminals in ticket rows even while programs run in them.
    public var force: Bool

    public init(force: Bool = false) {
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

public struct TicketListParams: Codable, Sendable {
    public var target: TargetHint
    public var owner: TicketOwnerFilter
    /// Only tickets whose customer is waiting.
    public var waiting: Bool
    public var query: String?
    /// Closed and archived tickets instead of open ones.
    public var closed: Bool

    public init(
        target: TargetHint = TargetHint(), owner: TicketOwnerFilter = .anyone, waiting: Bool = false,
        query: String? = nil, closed: Bool = false
    ) {
        self.target = target
        self.owner = owner
        self.waiting = waiting
        self.query = query
        self.closed = closed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        owner = try container.decodeIfPresent(TicketOwnerFilter.self, forKey: .owner) ?? .anyone
        waiting = try container.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        query = try container.decodeIfPresent(String.self, forKey: .query)
        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }
}

/// A command about one ticket: the one `reference` names, or without one, the ticket of the row it ran in.
public struct TicketRefParams: Codable, Sendable {
    public var target: TargetHint
    public var reference: String?

    public init(target: TargetHint = TargetHint(), reference: String? = nil) {
        self.target = target
        self.reference = reference
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
    }
}

public struct TicketNewParams: Codable, Sendable {
    public var target: TargetHint
    public var reference: String
    /// Typed into a new terminal in the row once its folder is filled. Config's `run` when nil.
    public var run: String?
    public var select: Bool

    public init(target: TargetHint = TargetHint(), reference: String, run: String? = nil, select: Bool = false) {
        self.target = target
        self.reference = reference
        self.run = run
        self.select = select
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        reference = try container.decode(String.self, forKey: .reference)
        run = try container.decodeIfPresent(String.self, forKey: .run)
        select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
    }
}

public struct TicketShowParams: Codable, Sendable {
    public var target: TargetHint
    public var reference: String?
    /// Asks ticket-manager even when the copy Canopy has is fresh.
    public var refresh: Bool
    /// The CLI prints the handover markdown alone.
    public var md: Bool

    public init(target: TargetHint = TargetHint(), reference: String? = nil, refresh: Bool = false, md: Bool = false) {
        self.target = target
        self.reference = reference
        self.refresh = refresh
        self.md = md
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        refresh = try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
        md = try container.decodeIfPresent(Bool.self, forKey: .md) ?? false
    }
}

public struct TicketRemoveParams: Codable, Sendable {
    public var target: TargetHint
    public var reference: String?
    /// Removes the row even while programs run in its terminals.
    public var force: Bool

    public init(target: TargetHint = TargetHint(), reference: String? = nil, force: Bool = false) {
        self.target = target
        self.reference = reference
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}
