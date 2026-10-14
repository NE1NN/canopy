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
    /// A file change, as a diff card.
    case edit(ChatToolCall)
    case question(ChatQuestion)
    case plan(ChatPlan)
    case notice(String)
    /// A `!` command the author ran, and what it printed.
    case shell(ChatShell)
    /// A page Claude published, as a card.
    case artifact(ChatArtifact)
}

public struct ChatShell: Equatable, Sendable {
    public var command: String
    public var output: String
    /// Nil while it runs, for one the author is running now.
    public var exitCode: Int32?

    public init(command: String, output: String, exitCode: Int32?) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
    }

    /// How much output Claude gets, as Claude Code's own `!` keeps: the end of it.
    public static let outputLimit = 30_000

    /// Adds printed lines, keeping about the last `outputLimit` bytes so a command that prints without end stays cheap.
    public mutating func append(_ text: String) {
        output += (output.isEmpty ? "" : "\n") + text
        if output.utf8.count > 2 * Self.outputLimit { output = Self.lastPart(of: output) }
    }

    /// The output as Claude gets it.
    public var outputForClaude: String {
        output.utf8.count > Self.outputLimit ? Self.lastPart(of: output) : output
    }

    static let cutNote = "[earlier output cut]"

    /// How a chat hands Claude a `!` command.
    public static func block(for shell: ChatShell) -> String {
        "<shell-run-by-user>\n<command>\(shell.command)</command>\n<exit-code>\(shell.exitCode ?? 0)</exit-code>\n"
            + "<output>\n\(shell.outputForClaude)\n</output>\n</shell-run-by-user>"
    }

    /// Reads `block(for:)` back. The output is cut at the last closing tags, since it may hold them itself.
    public static func parse(block text: String) -> ChatShell? {
        let start = "<shell-run-by-user>\n<command>"
        let end = "\n</output>\n</shell-run-by-user>"
        guard text.hasPrefix(start), text.hasSuffix(end) else { return nil }
        let body = text.dropFirst(start.count).dropLast(end.count)
        guard let command = body.range(of: "</command>\n<exit-code>"),
            let code = body[command.upperBound...].range(of: "</exit-code>\n<output>\n")
        else { return nil }
        return ChatShell(
            command: String(body[..<command.lowerBound]), output: String(body[code.upperBound...]),
            exitCode: Int32(body[command.upperBound..<code.lowerBound]) ?? 0)
    }

    private static func lastPart(of output: String) -> String {
        let tail = String(decoding: output.utf8.suffix(outputLimit), as: UTF8.self)
        let lines = tail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = lines.count == 2 && !tail.hasPrefix(cutNote) ? String(lines[1]) : tail
        return whole.hasPrefix(cutNote) ? whole : cutNote + "\n" + whole
    }
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
    /// A file change's diff: from its input while it waits, from its result once it ran.
    public var edit: ChatEdit?
    /// For a subagent: how many tool calls it has made so far.
    public var innerCalls = 0
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
