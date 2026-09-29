import CanopyCore
import Foundation

/// Whose tickets a list shows.
public enum TicketOwnerFilter: String, Sendable, Codable, CaseIterable {
    case mine, unowned, anyone
}

public struct TicketListQuery: Sendable, Equatable {
    public var owner: TicketOwnerFilter
    /// Only tickets whose customer is waiting for a reply.
    public var waitingOnly: Bool
    /// Words each found in the name or the customer.
    public var text: String

    public init(owner: TicketOwnerFilter = .anyone, waitingOnly: Bool = false, text: String = "") {
        self.owner = owner
        self.waitingOnly = waitingOnly
        self.text = text
    }
}

/// Lists of tickets as the picker and `canopy ticket list` show them.
public enum TicketListing {
    /// Mine, Unowned, and Anyone, starting on Anyone, and a Closed toggle that lists closed and archived tickets instead.
    public static let filters = PluginFilters(
        choices: [
            PluginFilter(id: TicketOwnerFilter.mine.rawValue, title: "Mine"),
            PluginFilter(id: TicketOwnerFilter.unowned.rawValue, title: "Unowned"),
            PluginFilter(id: TicketOwnerFilter.anyone.rawValue, title: "Anyone"),
        ],
        defaultChoice: TicketOwnerFilter.anyone.rawValue, toggles: [PluginFilter(id: "closed", title: "Closed")])

    /// Keeps the tickets the query asks for, then sorts them as the picker does: waiting customers first, then latest
    /// activity. `me` is the connected engineer's email, which Mine compares owners with.
    public static func list(_ tickets: [TicketSummary], _ query: TicketListQuery, me: String?) -> [TicketSummary] {
        let search = SearchText(query.text)
        return
            tickets
            .filter { ticket in
                switch query.owner {
                case .anyone: true
                case .unowned: ticket.owner == nil
                case .mine:
                    me.map { ticket.owner?.email.caseInsensitiveCompare($0) == .orderedSame } ?? false
                }
            }
            .filter { !query.waitingOnly || $0.waiting }
            .filter { search.matches([$0.name, $0.customer]) }
            .sorted {
                ($0.waiting ? 0 : 1, -$0.lastActivityAt, $0.id) < ($1.waiting ? 0 : 1, -$1.lastActivityAt, $1.id)
            }
    }

    /// The picker's line: the row title, the customer and how long ago the ticket was active, the waiting dot, the
    /// status tag of a ticket that is closed or archived, and the owner's initials.
    public static func item(_ ticket: TicketSummary, now: Date) -> PluginItem {
        PluginItem(
            id: ticket.id, title: TicketName.rowTitle(for: ticket.name),
            subtitle: "\(ticket.customer) · \(ShortAge.text(ticket.lastActivity, now: now))",
            accessories: TicketLook.accessories(ticket, withOwner: true))
    }
}

/// How long ago something happened, short for lists and in words for sentences.
public enum TicketAge {
    /// "now", "12m", "7h", "3d", "2w", "5mo", or "1y", as in "waiting 7h".
    public static func span(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let day = 86_400
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<day: return "\(seconds / 3600)h"
        case ..<(7 * day): return "\(seconds / day)d"
        case ..<(30 * day): return "\(seconds / (7 * day))w"
        case ..<(365 * day): return "\(seconds / (30 * day))mo"
        default: return "\(seconds / (365 * day))y"
        }
    }

    /// "just now", "20 s ago", "3 min ago", "2 h ago", or "4 d ago", as in "updated 20 s ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
