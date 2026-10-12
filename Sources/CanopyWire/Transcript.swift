import Foundation

/// One entry of an agent's conversation, as the phone shows it.
public struct TranscriptEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// What the author typed.
        case prompt
        /// What the agent wrote.
        case text
        /// One or more tool calls of the same kind, folded to one line.
        case tools
        /// The agent asked with options, through AskUserQuestion.
        case question
        /// The agent's plan, through ExitPlanMode.
        case plan
        /// Something that happened around the conversation, such as a slash command or an interrupt.
        case notice
    }

    /// Stable while the entry grows, so the phone replaces an entry it already has.
    public var id: String
    public var kind: Kind
    public var text: String
    /// Seconds since 1970.
    public var at: Double
    /// A tool call failed, or the author declined it.
    public var failed: Bool
    /// A question's questions and options.
    public var questions: [PromptQuestion]?
    /// What the author answered, or nil while the question or plan waits.
    public var answer: String?

    public init(
        id: String, kind: Kind, text: String, at: Double, failed: Bool = false, questions: [PromptQuestion]? = nil,
        answer: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.at = at
        self.failed = failed
        self.questions = questions
        self.answer = answer
    }

    /// A kind this phone does not know reads as a notice.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .notice
        text = try container.decode(String.self, forKey: .text)
        at = try container.decode(Double.self, forKey: .at)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        questions = try container.decodeIfPresent([PromptQuestion].self, forKey: .questions)
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
    }
}

/// One question of an AskUserQuestion call.
public struct PromptQuestion: Codable, Sendable, Equatable, Hashable {
    public struct Option: Codable, Sendable, Equatable, Hashable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }
}

/// What a waiting agent waits on, which the phone can answer while it is still the pane's open prompt.
public struct OpenPrompt: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// AskUserQuestion: one or more questions with options.
        case question
        /// A tool waiting for permission: Allow or Deny.
        case permission
        /// ExitPlanMode: approve the plan or keep planning.
        case plan
        /// The agent's last message ended on a question, which only a reply answers.
        case reply
    }

    public var id: String
    public var kind: Kind
    public var questions: [PromptQuestion]?
    /// The tool waiting for permission, such as Bash.
    public var tool: String?
    /// What it wants to run, the plan, or the question asked.
    public var detail: String?

    public init(
        id: String, kind: Kind, questions: [PromptQuestion]? = nil, tool: String? = nil, detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.questions = questions
        self.tool = tool
        self.detail = detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .reply
        questions = try container.decodeIfPresent([PromptQuestion].self, forKey: .questions)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
}
