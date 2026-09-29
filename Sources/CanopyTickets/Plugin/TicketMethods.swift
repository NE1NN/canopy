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
