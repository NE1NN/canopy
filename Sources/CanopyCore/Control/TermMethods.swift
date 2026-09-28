import Foundation

public enum TermMethod {
    public static let list = "term.list"
    public static let new = "term.new"
    public static let send = "term.send"
    public static let read = "term.read"
    public static let close = "term.close"
    public static let state = "term.state"
    public static let wait = "term.wait"
}

/// One terminal as `canopy term list` shows it.
public struct TermInfo: Codable, Sendable, Equatable {
    public var pane: String
    public var repo: String
    public var row: String
    public var rowPath: String
    public var tab: String
    public var title: String
    public var folder: String
    /// The program in the foreground, such as `claude`, or the shell when it is idle.
    public var foreground: String?
    public var exited: Int32?
    /// The agent's state, left out when it is none.
    public var agent: AgentState?
}

public struct TermListParams: Codable, Sendable {
    public var target: TargetHint
    public var all: Bool

    public init(target: TargetHint = TargetHint(), all: Bool = false) {
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct TermNewParams: Codable, Sendable {
    public var target: TargetHint
    /// Adds the pane to the tab with this name, opening it if the row has none.
    public var tab: String?
    public var newTab: Bool
    public var run: String?
    public var title: String?

    public init(
        target: TargetHint = TargetHint(), tab: String? = nil, newTab: Bool = false, run: String? = nil,
        title: String? = nil
    ) {
        self.target = target
        self.tab = tab
        self.newTab = newTab
        self.run = run
        self.title = title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        tab = try container.decodeIfPresent(String.self, forKey: .tab)
        newTab = try container.decodeIfPresent(Bool.self, forKey: .newTab) ?? false
        run = try container.decodeIfPresent(String.self, forKey: .run)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

public struct TermNewResult: Codable, Sendable, Equatable {
    public var pane: String
    public var tab: String
}

public struct TermSendParams: Codable, Sendable {
    public var pane: String
    public var text: String
    public var enter: Bool

    public init(pane: String, text: String, enter: Bool = false) {
        self.pane = pane
        self.text = text
        self.enter = enter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        text = try container.decode(String.self, forKey: .text)
        enter = try container.decodeIfPresent(Bool.self, forKey: .enter) ?? false
    }
}

public struct TermReadParams: Codable, Sendable {
    public var pane: String
    /// The last this many lines, scrollback included. Nil reads the visible screen.
    public var lines: Int?

    public init(pane: String, lines: Int? = nil) {
        self.pane = pane
        self.lines = lines
    }
}

public struct TermReadResult: Codable, Sendable, Equatable {
    public var text: String
}

public struct TermCloseParams: Codable, Sendable {
    public var pane: String
    public var force: Bool

    public init(pane: String, force: Bool = false) {
        self.pane = pane
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

/// A report of a pane's agent state, from `canopy term state` or Claude Code's hooks through `canopy agent-hook`.
public struct TermStateParams: Codable, Sendable {
    public var pane: String
    /// Nil only from a hook that takes the pane for its session without changing the state.
    public var state: AgentState?
    public var session: String?
    /// The hook event's name.
    public var event: String?
    /// When the hook process started, in seconds since 1970.
    public var at: Double?
    public var question: Bool
    public var takesOver: Bool
    public var releases: Bool

    public init(
        pane: String, state: AgentState?, session: String? = nil, event: String? = nil, at: Double? = nil,
        question: Bool = false, takesOver: Bool = false, releases: Bool = false
    ) {
        self.pane = pane
        self.state = state
        self.session = session
        self.event = event
        self.at = at
        self.question = question
        self.takesOver = takesOver
        self.releases = releases
    }

    public init(pane: String, _ report: AgentReport) {
        self.init(
            pane: pane, state: report.state, session: report.session, event: report.event,
            at: report.at?.timeIntervalSince1970, question: report.question, takesOver: report.takesOver,
            releases: report.releases)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        state = try container.decodeIfPresent(AgentState.self, forKey: .state)
        session = try container.decodeIfPresent(String.self, forKey: .session)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        at = try container.decodeIfPresent(Double.self, forKey: .at)
        question = try container.decodeIfPresent(Bool.self, forKey: .question) ?? false
        takesOver = try container.decodeIfPresent(Bool.self, forKey: .takesOver) ?? false
        releases = try container.decodeIfPresent(Bool.self, forKey: .releases) ?? false
    }

    public var report: AgentReport {
        AgentReport(
            state: state, session: session, event: event, at: at.map(Date.init(timeIntervalSince1970:)),
            question: question, takesOver: takesOver, releases: releases)
    }
}

public struct TermStateResult: Codable, Sendable, Equatable {
    public var pane: String
    /// The state after the report, which is the state the pane kept when the report was ignored.
    public var state: AgentState
}

public struct TermWaitParams: Codable, Sendable {
    public var panes: [String]
    public var target: AgentWaitTarget
    /// Seconds.
    public var timeout: Double

    public static let defaultTimeout = 30.0 * 60

    enum CodingKeys: String, CodingKey {
        case panes
        case target = "for"
        case timeout
    }

    public init(panes: [String], target: AgentWaitTarget = .any, timeout: Double = TermWaitParams.defaultTimeout) {
        self.panes = panes
        self.target = target
        self.timeout = timeout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panes = try container.decode([String].self, forKey: .panes)
        target = try container.decodeIfPresent(AgentWaitTarget.self, forKey: .target) ?? .any
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? Self.defaultTimeout
    }
}

public struct TermWaitResult: Codable, Sendable, Equatable {
    public var pane: String
    public var state: AgentState
}
