import Foundation

/// What a pane is: a terminal, or a chat, which has no screen or keys.
public enum PaneKind: String, Codable, Sendable, Equatable, Hashable {
    case terminal
    case chat

    /// A kind a newer Mac sends that this one does not know reads as a terminal.
    public init(from decoder: any Decoder) throws {
        self = PaneKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .terminal
    }
}

/// One pane's agent, as the phone shows it.
public struct PhoneAgent: Codable, Sendable, Equatable, Hashable {
    public var pane: String
    public var state: AgentState
    /// Done and not yet seen, on the Mac or the phone.
    public var unseen: Bool
    /// When the agent reached its state, in seconds since 1970.
    public var since: Double
    /// The agent's latest line, such as what it runs or asks.
    public var lastLine: String?
    /// What a background agent waits on.
    public var backgroundTasks: [String]?
    /// What a waiting agent waits on, which the phone can answer.
    public var prompt: OpenPrompt?
    /// Whether the pane has a transcript the phone can read.
    public var hasTranscript: Bool
    /// A chat has no Terminal tab. A Mac that sends no kind has only terminals.
    public var kind: PaneKind

    public init(
        pane: String, state: AgentState, unseen: Bool = false, since: Double, lastLine: String? = nil,
        backgroundTasks: [String]? = nil, prompt: OpenPrompt? = nil, hasTranscript: Bool = false,
        kind: PaneKind = .terminal
    ) {
        self.kind = kind
        self.prompt = prompt
        self.hasTranscript = hasTranscript
        self.pane = pane
        self.state = state
        self.unseen = unseen
        self.since = since
        self.lastLine = lastLine
        self.backgroundTasks = backgroundTasks
    }

    /// A state a newer Mac sends that this phone does not know reads as none, so it cannot spoil the whole inbox.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        state = AgentState(rawValue: try container.decode(String.self, forKey: .state)) ?? .none
        unseen = try container.decodeIfPresent(Bool.self, forKey: .unseen) ?? false
        since = try container.decode(Double.self, forKey: .since)
        lastLine = try container.decodeIfPresent(String.self, forKey: .lastLine)
        backgroundTasks = try container.decodeIfPresent([String].self, forKey: .backgroundTasks)
        prompt = try? container.decodeIfPresent(OpenPrompt.self, forKey: .prompt)
        hasTranscript = try container.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false
        kind = (try? container.decodeIfPresent(PaneKind.self, forKey: .kind)) ?? .terminal
    }

    /// The same dot the Mac's sidebar shows for it.
    public var dot: AgentDot? {
        switch state {
        case .none: nil
        case .working: .working
        case .waiting: .waiting
        case .done: unseen ? .done : nil
        case .background: .background
        }
    }
}

/// A row and the agents in its panes.
public struct PhoneRow: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var path: String
    /// The branch, or a plugin row's title.
    public var name: String
    /// The repo's name. Nil for a plugin's row.
    public var repo: String?
    /// The plugin's name, for a plugin's row.
    public var plugin: String?
    /// The repo's own checkout rather than a worktree.
    public var isMain: Bool
    public var pr: PhonePR?
    public var agents: [PhoneAgent]

    public init(
        path: String, name: String, repo: String? = nil, plugin: String? = nil, isMain: Bool = false,
        pr: PhonePR? = nil, agents: [PhoneAgent] = []
    ) {
        self.path = path
        self.name = name
        self.repo = repo
        self.plugin = plugin
        self.isMain = isMain
        self.pr = pr
        self.agents = agents
    }

    public var id: String { path }

    /// The agent the row shows: its most urgent, else the latest to change.
    public var lead: PhoneAgent? {
        agents.max { lhs, rhs in
            let left = lhs.dot.map { $0.rawValue + 1 } ?? 0
            let right = rhs.dot.map { $0.rawValue + 1 } ?? 0
            return left == right ? lhs.since < rhs.since : left < right
        }
    }

    public var dot: AgentDot? {
        agents.compactMap(\.dot).max()
    }
}

public struct PhonePR: Codable, Sendable, Equatable, Hashable {
    public var number: Int
    public var state: PRState
    public var title: String
    public var url: String

    public init(number: Int, state: PRState, title: String, url: String) {
        self.number = number
        self.state = state
        self.title = title
        self.url = url
    }

    /// A state this phone does not know reads as open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        state = PRState(rawValue: try container.decode(String.self, forKey: .state)) ?? .open
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
    }
}

/// Every row, in the sidebar's order, with the agents in it. The Mac sends all of it on each change.
public struct PhoneInbox: Codable, Sendable, Equatable {
    public var rows: [PhoneRow]

    public init(rows: [PhoneRow] = []) {
        self.rows = rows
    }

    /// An agent and the row it is in.
    public struct Item: Sendable, Equatable, Identifiable {
        public var row: PhoneRow
        public var agent: PhoneAgent

        public init(row: PhoneRow, agent: PhoneAgent) {
            self.row = row
            self.agent = agent
        }

        public var id: String { agent.pane }
    }

    public struct Sections: Sendable, Equatable {
        /// Waiting agents, the longest waiting first.
        public var needsYou: [Item]
        /// Done agents not yet seen, the newest first.
        public var done: [Item]

        public init(needsYou: [Item] = [], done: [Item] = []) {
            self.needsYou = needsYou
            self.done = done
        }

        /// What the tab's badge counts.
        public var count: Int { needsYou.count + done.count }
        public var isEmpty: Bool { count == 0 }
    }

    /// The Inbox: what wants the author. Agents with the same time keep the Mac's order.
    public var sections: Sections {
        let items = rows.flatMap { row in row.agents.map { Item(row: row, agent: $0) } }.enumerated()
        let waiting = items.filter { $0.element.agent.state == .waiting }
            .sorted { ($0.element.agent.since, $0.offset) < ($1.element.agent.since, $1.offset) }
        let done = items.filter { $0.element.agent.state == .done && $0.element.agent.unseen }
            .sorted { ($1.element.agent.since, $0.offset) < ($0.element.agent.since, $1.offset) }
        return Sections(needsYou: waiting.map(\.element), done: done.map(\.element))
    }

    /// Working and background agents, which the Inbox leaves to Rows.
    public var runningCount: Int {
        rows.flatMap(\.agents).filter { $0.state == .working || $0.state == .background }.count
    }
}

/// What `phone.rows` answers: the sidebar's sections, repos first, then plugins.
public struct PhoneRowsResult: Codable, Sendable, Equatable {
    public struct Section: Codable, Sendable, Equatable, Identifiable {
        /// The repo's or plugin's name.
        public var name: String
        public var isPlugin: Bool
        public var rows: [PhoneRow]

        public init(name: String, isPlugin: Bool, rows: [PhoneRow]) {
            self.name = name
            self.isPlugin = isPlugin
            self.rows = rows
        }

        public var id: String { (isPlugin ? "plugin:" : "repo:") + name }

        /// The repo's own checkout, which Rows shows as a card above the others.
        public var main: PhoneRow? { rows.first(where: \.isMain) }

        /// Every row but the main one, in the server's order.
        public var others: [PhoneRow] { rows.filter { !$0.isMain } }
    }

    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }
}
