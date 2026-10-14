import Foundation

/// One entry in a chat's conversation. Its ID stays the same while it grows, as a tool group does.
public struct ChatItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var content: ChatContent
    /// Seconds since 1970.
    public var at: Double
    /// Changes whenever the item does, so a list redraws only items whose revision moved.
    public var revision = 0

    public init(id: String, content: ChatContent, at: Double) {
        self.id = id
        self.content = content
        self.at = at
    }
}

public enum ChatContent: Equatable, Sendable {
    case prompt(ChatPrompt)
    case text(ChatText)
    case tools(ChatToolGroup)
    case question(ChatQuestion)
    case plan(ChatPlan)
    case notice(String)
}

public struct ChatPrompt: Equatable, Sendable {
    public var text: String
    public var images: Int

    public init(text: String, images: Int) {
        self.text = text
        self.images = images
    }
}

/// Claude's markdown, parsed once.
public struct ChatText: Equatable, Sendable {
    public let markdown: String
    public let blocks: [ChatBlock]

    public init(_ markdown: String) {
        self.markdown = markdown
        blocks = ChatMarkdown.parse(markdown)
    }
}

public struct ChatToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: [String: JSONValue]
    /// Nil until the call returns.
    public var result: String?
    public var isError: Bool
}

/// Consecutive tool calls of one kind, read as one line: "Read TopBarView.swift and 3 more".
public struct ChatToolGroup: Equatable, Sendable {
    public var calls: [ChatToolCall]
    public var summary: String
    public var failed: Bool

    public var kind: TranscriptParser.ToolKind {
        TranscriptParser.ToolKind(calls[0].name)
    }

    init(calls: [ChatToolCall]) {
        self.calls = calls
        let kind = TranscriptParser.ToolKind(calls[0].name)
        let failures = calls.filter(\.isError)
        let declined = failures.contains {
            TranscriptParser.ToolResult(text: $0.result ?? "", isError: true).isDeclined
        }
        var summary = kind.summary(calls.map { ($0.name, $0.input) })
        if !failures.isEmpty {
            summary += calls.count == 1 ? (declined ? ", declined" : ", failed") : ", \(failures.count) failed"
        }
        self.summary = summary
        failed = !failures.isEmpty
    }
}

public struct ChatQuestion: Equatable, Sendable {
    public var questions: [PromptQuestion]
    /// Nil while it waits.
    public var answer: String?
}

public struct ChatPlan: Equatable, Sendable {
    public var markdown: String
    /// "Approved" or "Declined", nil while it waits.
    public var answer: String?
}
