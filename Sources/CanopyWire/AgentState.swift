import Foundation

/// What an agent in a pane is doing, as Claude Code's hooks or `canopy term state` report it.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    case none
    case working
    case waiting
    case done
    /// The turn ended, but background work the agent started still runs, and the agent wakes when it ends.
    case background
}

/// What stands for a pane's agent in the sidebar, the tab bar, and the pane header. Ordered by urgency, so the most
/// urgent of several is their `max()`.
public enum AgentDot: Int, Comparable, Sendable {
    case background
    case working
    case done
    case waiting

    public static func < (lhs: AgentDot, rhs: AgentDot) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A pull request's state, with an open draft shown as draft.
public enum PRState: String, Codable, Sendable {
    case open, draft, merged, closed
}
