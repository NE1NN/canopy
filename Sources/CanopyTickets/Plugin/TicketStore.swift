import Foundation
import Observation

/// What a ticket's panel shows about it.
public struct TicketViewState: Sendable, Equatable {
    public var detail: TicketDetail?
    /// When `detail` was fetched.
    public var fetchedAt: Date?
    /// The latest fetch's failure, until one succeeds.
    public var failure: TicketFailure?
    public var isFetching = false
    /// ticket-manager no longer has the ticket.
    public var isMissing = false

    public init() {}

    /// What the panel shows in place of the conversation while it has no copy of the ticket.
    public enum Placeholder: Sendable, Equatable {
        /// A spinner: the ticket is on its way, or not asked for yet.
        case fetching
        /// ticket-manager no longer has it, so no copy is coming.
        case missing
        /// Tickets is on but could not start, which the section's warning explains.
        case notRunning
        /// The last fetch failed, which the banner explains.
        case failed
    }

    /// `rowIsMissing` is the row's own look, which also covers an id ticket-manager calls malformed. `isRunning` is
    /// the store's.
    public func placeholder(rowIsMissing: Bool, isRunning: Bool) -> Placeholder {
        if isFetching { return .fetching }
        if isMissing || rowIsMissing { return .missing }
        if !isRunning { return .notRunning }
        return failure == nil ? .fetching : .failed
    }
}

public struct TicketFailure: Sendable, Equatable {
    public var code: String
    public var message: String
    public var at: Date

    public init(code: String, message: String, at: Date) {
        self.code = code
        self.message = message
        self.at = at
    }
}

/// What the Tickets plugin knows, kept on the main actor for its panels. The plugin writes it, and panels only read it.
@MainActor
@Observable
public final class TicketStore {
    /// ticket-manager's address while the plugin runs.
    public private(set) var url: URL?
    public private(set) var web: String?
    /// The connected engineer's email.
    public private(set) var me: String?
    private var tickets: [String: TicketViewState] = [:]
    private var summaries: [String: TicketSummary] = [:]

    public nonisolated init() {}

    /// Whether the plugin runs and can fetch tickets.
    public var isRunning: Bool { url != nil }

    public func ticket(_ id: String) -> TicketViewState {
        tickets[id] ?? TicketViewState()
    }

    /// The newest summary of the ticket: from the rows' refresh, or from its detail.
    public func summary(_ id: String) -> TicketSummary? {
        summaries[id] ?? tickets[id]?.detail?.ticket
    }

    /// The ticket's page in ticket-manager, when config.json says where that is.
    public func webURL(for ticket: TicketSummary) -> URL? {
        web.flatMap { TicketSettings.webURL($0, for: ticket) }
    }

    // MARK: The plugin's writes

    func connected(url: URL, web: String?) {
        self.url = url
        self.web = web
    }

    func setMe(_ email: String?) {
        me = email
    }

    func setFetching(_ id: String, _ isFetching: Bool) {
        tickets[id, default: TicketViewState()].isFetching = isFetching
    }

    func setDetail(_ detail: TicketDetail, fetchedAt: Date) {
        var state = tickets[detail.ticket.id] ?? TicketViewState()
        state.detail = detail
        state.fetchedAt = fetchedAt
        state.failure = nil
        state.isMissing = false
        tickets[detail.ticket.id] = state
        summaries[detail.ticket.id] = detail.ticket
    }

    func setFailure(_ id: String, _ failure: TicketFailure?) {
        tickets[id, default: TicketViewState()].failure = failure
    }

    func setMissing(_ id: String, _ isMissing: Bool) {
        tickets[id, default: TicketViewState()].isMissing = isMissing
        if isMissing { tickets[id]?.failure = nil }
    }

    func setSummaries(_ found: [TicketSummary]) {
        for summary in found {
            summaries[summary.id] = summary
        }
    }

    func clear() {
        url = nil
        web = nil
        me = nil
        tickets = [:]
        summaries = [:]
    }
}
