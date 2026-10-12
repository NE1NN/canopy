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
