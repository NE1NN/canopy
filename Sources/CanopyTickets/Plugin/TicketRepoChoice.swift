import Foundation

/// The Connect Tickets sheet's Code repo pop-up: what it offers, where it starts, and what connecting with a choice does.
public struct TicketRepoChoice: Sendable, Equatable {
    /// config.json's `repo` when the sheet opened.
    public let saved: String?
    /// The registered repos' names.
    public let registered: [String]

    public init(saved: String?, registered: [String]) {
        self.saved = saved
        self.registered = registered
    }

    /// The registered repos, then the saved one when Canopy has no repo of that name, so the pop-up can start on it.
    public var options: [String] {
        guard let saved, !registered.contains(saved) else { return registered }
        return registered + [saved]
    }

    public func isRegistered(_ name: String) -> Bool {
        registered.contains(name)
    }

    /// What `tickets.connect` gets as `repo`. A saved name Canopy has no repo for would fail, so it is left out, which
    /// keeps it.
    public func connectRepo(_ choice: String?) -> String? {
        choice.flatMap { isRegistered($0) ? $0 : nil }
    }

    /// Whether connecting also takes the saved repo out, as picking None over it asks.
    public func clears(_ choice: String?) -> Bool {
        saved != nil && choice == nil
    }
}
