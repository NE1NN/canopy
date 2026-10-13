import CanopyWire
import Foundation

/// One report of an agent's state.
public struct AgentReport: Sendable, Equatable {
    /// Nil for a report that only takes the pane for its session, as `SessionStart` does.
    public var state: AgentState?
    /// The Claude Code session that sent it. Reports without one always count.
    public var session: String?
    /// The hook event's name, such as `Stop`. Nil for `canopy term state`.
    public var event: String?
    /// When the hook process started. Nil takes the time the report arrives.
    public var at: Date?
    /// A turn ended on a question, so the agent waits at its own input line, where typing only drafts the answer.
    public var question: Bool
    /// The session replaces the one holding the pane, as when one `claude` resumes, clears, compacts, or forks.
    public var takesOver: Bool
    /// The session ends and lets go of the pane.
    public var releases: Bool
    /// What still runs for a background report, by the labels `BackgroundWork` shows.
    public var backgroundTasks: [String]
    /// Claude Code's transcript of the session, which every hook names.
    public var transcriptPath: String?
    /// What a waiting agent waits on, when the hook says.
    public var prompt: AgentPrompt?

    public init(
        state: AgentState?, session: String? = nil, event: String? = nil, at: Date? = nil, question: Bool = false,
        takesOver: Bool = false, releases: Bool = false, backgroundTasks: [String] = [], transcriptPath: String? = nil,
        prompt: AgentPrompt? = nil
    ) {
        self.transcriptPath = transcriptPath
        self.prompt = prompt
        self.state = state
        self.session = session
        self.event = event
        self.at = at
        self.question = question
        self.takesOver = takesOver
        self.releases = releases
        self.backgroundTasks = backgroundTasks
    }
}

public struct AgentChange: Sendable, Equatable {
    public var from: AgentState
    public var to: AgentState
    /// What caused it: a hook event's name, `term.state`, `key`, or `exit`.
    public var via: String
    /// The session whose report caused it.
    public var session: String?

    public init(from: AgentState, to: AgentState, via: String, session: String? = nil) {
        self.from = from
        self.to = to
        self.via = via
        self.session = session
    }

    /// A finish or a need for the author, which plays a sound.
    public var alerts: Bool {
        to == .done || to == .waiting
    }
}

/// What a waiting agent waits on, before the pane gives it an ID.
public struct AgentPrompt: Codable, Sendable, Equatable {
    public var kind: OpenPrompt.Kind
    public var questions: [PromptQuestion]?
    public var tool: String?
    public var detail: String?

    public init(kind: OpenPrompt.Kind, questions: [PromptQuestion]? = nil, tool: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.questions = questions
        self.tool = tool
        self.detail = detail
    }

    func opened(id: String) -> OpenPrompt {
        OpenPrompt(id: id, kind: kind, questions: questions, tool: tool, detail: detail)
    }

    func describes(_ prompt: OpenPrompt) -> Bool {
        opened(id: prompt.id) == prompt
    }
}

/// A pane's agent state and the rules that change it. It knows nothing of processes or windows, so each rule can be
/// tested on its own.
public struct PaneAgent: Sendable, Equatable {
    public private(set) var state = AgentState.none
    /// Done and not yet seen by the author, which shows green.
    public private(set) var unseen = false
    /// The Claude Code session the pane listens to.
    public private(set) var session: String?
    /// Waiting at the agent's own input line after a question, rather than on a prompt that keys answer.
    public private(set) var waitsOnQuestion = false
    /// The labels of the work still running while the pane is background.
    public private(set) var backgroundTasks: [String] = []
    /// The transcript of the session that last held the pane. It stays after the agent exits, so its conversation can
    /// still be read.
    public private(set) var transcriptPath: String?
    /// What the waiting agent waits on, while the author has not answered it.
    public private(set) var prompt: OpenPrompt?
    /// When Canopy saw the pane reach its state.
    public private(set) var since = Date.distantPast
    /// When the last change happened, by the clock of whatever caused it. Hooks that started earlier are stale.
    private var changedAt = Date.distantPast

    public init() {}

    public var dot: AgentDot? {
        switch state {
        case .none: nil
        case .working: .working
        case .waiting: .waiting
        case .done: unseen ? .done : nil
        case .background: .background
        }
    }

    /// Whether the pane reached its state after input at `lastInput`. A done from before a new prompt is stale.
    public func isFresh(after lastInput: Date) -> Bool {
        lastInput <= since
    }

    /// Applies a report, returning the change, or nil when it was ignored or changed nothing.
    /// A done on a done pane is a new finish, for agents that report only their finishes.
    public mutating func apply(_ report: AgentReport, now: Date) -> AgentChange? {
        let at = report.at ?? now
        guard at >= changedAt else { return nil }
        if let reporter = report.session {
            if session == nil || report.takesOver {
                session = reporter
            } else if session != reporter {
                return nil
            }
        }
        defer {
            if report.releases { session = nil }
        }
        if let path = report.transcriptPath { transcriptPath = path }
        guard let next = report.state else { return nil }
        // A Monitor wakes the agent on each line it reads, and the turn can end background again with less running.
        if next == .background, state == .background {
            backgroundTasks = report.backgroundTasks
            changedAt = at
            return nil
        }
        guard next != state || next == .done else {
            if next == .waiting { open(report.prompt) }
            return nil
        }
        waitsOnQuestion = next == .waiting && report.question
        let change = change(to: next, via: report.event ?? "term.state", session: report.session, at: at, now: now)
        if next == .background { backgroundTasks = report.backgroundTasks }
        if next == .waiting { open(report.prompt) }
        return change
    }

    /// Keys typed into the pane, or text sent with `canopy term send`. Claude Code runs no hook for an interrupt or a
    /// dismissed prompt, so Escape and Control-C clear the state, and Return answers a prompt. ⌥Return, ESC CR, does
    /// not.
    public mutating func typed(_ data: Data, at: Date) -> AgentChange? {
        let interrupts = Self.interruptKeys.contains(data)
        switch state {
        case .working where interrupts:
            return change(to: .none, via: "key", session: nil, at: at, now: at)
        case .waiting where !waitsOnQuestion && interrupts:
            return change(to: .none, via: "key", session: nil, at: at, now: at)
        case .waiting where !waitsOnQuestion && data.contains(0x0D) && data != Self.optionReturn:
            return change(to: .working, via: "key", session: nil, at: at, now: at)
        case .waiting where !waitsOnQuestion:
            // Any other key in a dialog, a digit or an arrow, makes what the phone saw out of date.
            prompt = nil
            return nil
        default:
            return nil
        }
    }

    /// The agent's program exited, or the pane closed. The session lets go of the pane.
    public mutating func ended(at: Date) -> AgentChange? {
        session = nil
        guard state != .none else { return nil }
        return change(to: .none, via: "exit", session: nil, at: at, now: at)
    }

    /// Takes the answer to the open prompt, if `promptID` still names it. A prompt is answered once, and the hook that
    /// follows the answer moves the state on.
    public mutating func answer(promptID: String) -> Bool {
        guard prompt?.id == promptID else { return false }
        prompt = nil
        return true
    }

    /// Keeps the open prompt while a hook describes it again, as the permission request after an AskUserQuestion does.
    private mutating func open(_ next: AgentPrompt?) {
        guard let next else { return }
        if let prompt, next.describes(prompt) { return }
        prompt = next.opened(id: UUID().uuidString)
    }

    /// The author saw the pane. Returns whether a green dot went away.
    public mutating func seen() -> Bool {
        guard unseen else { return false }
        unseen = false
        return true
    }

    private mutating func change(to next: AgentState, via: String, session: String?, at: Date, now: Date)
        -> AgentChange
    {
        let change = AgentChange(from: state, to: next, via: via, session: session)
        state = next
        unseen = next == .done
        if next != .waiting {
            waitsOnQuestion = false
            prompt = nil
        }
        backgroundTasks = []
        since = now
        changedAt = at
        return change
    }

    /// Whether `data` is something the terminal sends on its own rather than a key: a focus change, a mouse report,
    /// or a reply to a query about the terminal.
    public static func isTerminalReport(_ data: Data) -> Bool {
        guard data.count >= 3, data.first == 0x1B else { return false }
        let text = String(decoding: data, as: UTF8.self)
        if text == "\u{1b}[I" || text == "\u{1b}[O" { return true }
        if text.hasPrefix("\u{1b}[<") || text.hasPrefix("\u{1b}[M") { return true }
        if text.hasPrefix("\u{1b}]") || text.hasPrefix("\u{1b}P") { return true }
        // Cursor position, device attributes, status, and mode replies.
        return text.hasPrefix("\u{1b}[") && ["R", "c", "n", "y", "t"].contains(text.last.map(String.init) ?? "")
            && text.dropFirst(2).dropLast().allSatisfy { "0123456789;?$>=".contains($0) }
    }

    static let optionReturn = Data([0x1B, 0x0D])

    /// Escape and Control-C as a terminal sends them, plainly or in the kitty keyboard protocol's form.
    static let interruptKeys: Set<Data> = [
        Data([0x1B]), Data([0x03]), Data("\u{1b}[27u".utf8), Data("\u{1b}[99;5u".utf8),
    ]
}
