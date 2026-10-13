import CanopyAgents
import CanopyWire
import Foundation

/// What canopy-box saves in `state.json`. git and tmux hold the rest, so losing it costs pane order and agent states.
struct BoxState: Codable, Sendable, Equatable {
    /// Rows other than each repo's clone, in the order they were made.
    var rows: [StoredRow] = []
    var panes: [StoredPane] = []
    /// The number of the next `b<N>` pane.
    var nextPane = 1
    /// The Mac's last pull request numbers, by row path.
    var prs: [String: Int] = [:]
    /// Everything went back to the Mac with `box.release`, so worktrees and sessions are not taken in again until the
    /// Mac adopts or configures.
    var released = false

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([StoredRow].self, forKey: .rows) ?? []
        panes = try container.decodeIfPresent([StoredPane].self, forKey: .panes) ?? []
        nextPane = try container.decodeIfPresent(Int.self, forKey: .nextPane) ?? 1
        prs = try container.decodeIfPresent([String: Int].self, forKey: .prs) ?? [:]
        released = try container.decodeIfPresent(Bool.self, forKey: .released) ?? false
    }
}

struct StoredRow: Codable, Sendable, Equatable {
    var path: String
    var repo: String
    var branch: String?
    var head: String?
    var missing = false
}

struct StoredPane: Codable, Sendable, Equatable {
    var id: String
    var rowPath: String
    var folder: String
    var agent: PaneAgent
    /// When text or keys last went in, in seconds since 1970, so `wait` passes over a state from before them.
    var lastInput: Double = 0
}

/// What the daemon learns of a pane as it runs, never saved.
struct PaneActivity: Sendable, Equatable {
    var foreground: String?
    var title: String?
    var busy = false
    var lastLine: String?
}
