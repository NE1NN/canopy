import CanopyWire
import Foundation

/// Turns lines of a Claude Code transcript (JSONL) into the conversation the phone shows: prompts, the agent's text,
/// tool calls folded by kind, questions, plans, and notices. Tool output, thinking, subagents, hook messages, and lines
/// it cannot read are left out, so a Claude Code version that changes its format loses entries rather than failing.
public enum TranscriptParser {
    public static func entries(from lines: [Data]) -> [TranscriptEntry] {
        located(from: lines).map(\.entry)
    }

    /// Entries with the index of the line each starts at. `following` are lines after `lines`, read only for the
    /// results of calls in `lines`.
    static func located(from lines: [Data], following: [Data] = []) -> [(entry: TranscriptEntry, line: Int)] {
        let records = lines.enumerated().compactMap { index, line in Record(line: line).map { (index, $0) } }
        var results: [String: ToolResult] = [:]
        for record in records.map(\.1) + following.compactMap(Record.init(line:)) {
            for block in record.blocks {
                if case .result(let id, let text, let isError) = block {
                    results[id] = ToolResult(text: text, isError: isError)
                }
            }
        }
        var builder = Builder(results: results)
        for (index, record) in records {
            builder.line = index
            builder.add(record)
        }
        return Array(zip(builder.entries, builder.lines))
    }

    public struct ToolResult: Sendable {
        public var text: String
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }

        /// The author said no at a permission prompt.
        public var isDeclined: Bool {
            isError && text.hasPrefix("The user doesn't want to proceed")
        }
    }

    /// One line of the transcript that may hold part of the conversation.
    public struct Record: Sendable {
        public enum Block: Sendable {
            case text(String)
            case image
            case tool(id: String, name: String, input: [String: JSONValue])
            case result(id: String, text: String, isError: Bool)
        }

        public var id: String
        public var role: String
        public var at: Double
        public var blocks: [Block]
        /// The author's own words, as a plain string.
        public var plainText: String?
        public var isCompactSummary: Bool
        /// A tool's structured result, such as an edit's patch: `toolUseResult` in a transcript, `tool_use_result` in
        /// Claude Code's stream.
        public var toolUseResult: JSONValue?

        public init?(line: Data) {
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: line),
                case .string(let type)? = object["type"], type == "user" || type == "assistant",
                case .string(let id)? = object["uuid"], case .object(let message)? = object["message"]
            else { return nil }
            if case .bool(true)? = object["isSidechain"] { return nil }
            if case .bool(true)? = object["isMeta"] { return nil }
            self.id = id
            role = type
            at = Self.date(object["timestamp"])
            toolUseResult = object["toolUseResult"] ?? object["tool_use_result"]
            if case .bool(true)? = object["isCompactSummary"] {
                isCompactSummary = true
            } else {
                isCompactSummary = false
            }
            switch message["content"] {
            case .string(let text):
                plainText = text
                blocks = [.text(text)]
            case .array(let items):
                plainText = nil
                blocks = items.compactMap(Self.block)
            default:
                return nil
            }
        }

        private static func block(_ value: JSONValue) -> Block? {
            guard case .object(let fields) = value, case .string(let type)? = fields["type"] else { return nil }
            switch type {
            case "text":
                guard case .string(let text)? = fields["text"] else { return nil }
                return .text(text)
            case "image":
                return .image
            case "tool_use":
                guard case .string(let id)? = fields["id"], case .string(let name)? = fields["name"] else { return nil }
                if case .object(let input)? = fields["input"] { return .tool(id: id, name: name, input: input) }
                return .tool(id: id, name: name, input: [:])
            case "tool_result":
                guard case .string(let id)? = fields["tool_use_id"] else { return nil }
                var isError = false
                if case .bool(let flag)? = fields["is_error"] { isError = flag }
                return .result(id: id, text: Self.text(of: fields["content"]), isError: isError)
            default:
                return nil
            }
        }

        private static func text(of content: JSONValue?) -> String {
            switch content {
            case .string(let text): text
            case .array(let items):
                items.compactMap { item -> String? in
                    if case .object(let fields) = item, case .string(let text)? = fields["text"] { return text }
                    return nil
                }.joined(separator: "\n")
            default: ""
            }
        }

        private static func date(_ value: JSONValue?) -> Double {
            guard case .string(let text)? = value,
                let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                    ?? (try? Date(text, strategy: .iso8601))
            else { return 0 }
            return date.timeIntervalSince1970
        }
    }

    /// Builds entries in order, folding consecutive tool calls of one kind into the entry before.
    public struct Builder {
        let results: [String: ToolResult]
        var entries: [TranscriptEntry] = []
        /// The line each entry starts at.
        var lines: [Int] = []
        /// The line being added.
        var line = 0
        /// Entries the line being added has made so far, which names a second text entry from the same line.
        private var entriesInRecord = 0
        /// The tool calls in the last entry, when it is a `.tools` entry.
        private var group: (kind: ToolKind, calls: [(name: String, input: [String: JSONValue], id: String)])?

        init(results: [String: ToolResult]) {
            self.results = results
        }

        mutating func add(_ record: Record) {
            entriesInRecord = 0
            if record.role == "user" {
                addUser(record)
            } else {
                addAssistant(record)
            }
        }

        private mutating func addUser(_ record: Record) {
            if record.isCompactSummary {
                append(
                    TranscriptEntry(id: record.id, kind: .notice, text: "The conversation was compacted", at: record.at)
                )
                return
            }
            var parts: [String] = []
            for block in record.blocks {
                switch block {
                case .text(let text): parts.append(text)
                case .image: parts.append("[image]")
                case .tool, .result: break
                }
            }
            let text = Self.unwrappingPastes(parts.joined(separator: "\n")).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let notice = Self.notice(for: text) {
                if !notice.isEmpty {
                    append(TranscriptEntry(id: record.id, kind: .notice, text: notice, at: record.at))
                }
                return
            }
            append(TranscriptEntry(id: record.id, kind: .prompt, text: text, at: record.at))
        }

        /// Claude Code keeps a paste in the prompt between `<pasted_content id="…">` and `</pasted_content id="…">`.
        public static func unwrappingPastes(_ text: String) -> String {
            text.replacing(/<pasted_content id="[^"]*">\n?/, with: "")
                .replacing(/\n?<\/pasted_content(?: id="[^"]*")?>/, with: "")
        }

        /// What a user line that is not the author's own words stands for, empty to leave it out, or nil for a prompt.
        public static func notice(for text: String) -> String? {
            if text.hasPrefix("[Request interrupted by user") { return "Interrupted" }
            if text.hasPrefix("<command-name>") {
                return Self.tag("command-name", in: text) ?? ""
            }
            if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-stderr>")
                || text.hasPrefix("<command-message>") || text.hasPrefix("<bash-")
            {
                return ""
            }
            if text.hasPrefix("<task-notification>") {
                return Self.tag("summary", in: text) ?? "A background task finished"
            }
            return nil
        }

        public static func tag(_ name: String, in text: String) -> String? {
            guard let open = text.range(of: "<\(name)>"),
                let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private mutating func addAssistant(_ record: Record) {
            var texts: [String] = []
            for block in record.blocks {
                switch block {
                case .text(let text):
                    texts.append(text)
                case .tool(let id, let name, let input):
                    flushText(&texts, record)
                    addTool(id: id, name: name, input: input, at: record.at)
                case .image, .result:
                    break
                }
            }
            flushText(&texts, record)
        }

        private mutating func flushText(_ texts: inout [String], _ record: Record) {
            let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            texts = []
            guard !text.isEmpty else { return }
            let id = entriesInRecord == 0 ? record.id : record.id + "#\(entriesInRecord)"
            append(TranscriptEntry(id: id, kind: .text, text: text, at: record.at))
        }

        private mutating func addTool(id: String, name: String, input: [String: JSONValue], at: Double) {
            switch name {
            case "AskUserQuestion":
                let questions = Self.questions(input)
                let result = results[id]
                append(
                    TranscriptEntry(
                        id: id, kind: .question, text: questions.first?.question ?? "Asks a question", at: at,
                        failed: result?.isError ?? false, questions: questions,
                        answer: result.map { $0.isError ? "Declined" : Self.answers(in: $0.text, for: questions) }))
            case "ExitPlanMode":
                let result = results[id]
                append(
                    TranscriptEntry(
                        id: id, kind: .plan, text: Self.string(input["plan"]) ?? "A plan", at: at,
                        failed: result?.isError ?? false,
                        answer: result.map { $0.isError ? "Declined" : "Approved" }))
            case "ToolSearch":
                return
            default:
                let kind = ToolKind(name)
                if let group, group.kind == kind, entries.last?.kind == .tools {
                    self.group?.calls.append((name, input, id))
                    entries[entries.count - 1] = toolEntry(
                        kind: kind, calls: self.group?.calls ?? [], at: entries.last?.at ?? at)
                } else {
                    let calls = [(name: name, input: input, id: id)]
                    append(toolEntry(kind: kind, calls: calls, at: at))
                    group = (kind, calls)
                }
            }
        }

        private func toolEntry(
            kind: ToolKind, calls: [(name: String, input: [String: JSONValue], id: String)], at: Double
        )
            -> TranscriptEntry
        {
            let outcomes = calls.map { results[$0.id] }
            let failures = outcomes.filter { $0?.isError == true }.count
            let declined = outcomes.contains { $0?.isDeclined == true }
            var text = kind.summary(calls.map { ($0.name, $0.input) })
            if failures > 0 {
                text += calls.count == 1 ? (declined ? ", declined" : ", failed") : ", \(failures) failed"
            }
            return TranscriptEntry(id: calls[0].id, kind: .tools, text: text, at: at, failed: failures > 0)
        }

        private mutating func append(_ entry: TranscriptEntry) {
            entriesInRecord += 1
            entries.append(entry)
            lines.append(line)
            if entry.kind != .tools { group = nil }
        }

        public static func questions(_ input: [String: JSONValue]) -> [PromptQuestion] {
            guard case .array(let items)? = input["questions"] else { return [] }
            return items.compactMap { try? $0.decode(PromptQuestion.self) }
        }

        /// The answers in a tool result such as `Your questions have been answered: "Q"="A", "Q2"="B".`, in the
        /// questions' order.
        public static func answers(in text: String, for questions: [PromptQuestion]) -> String {
            var found: [String: String] = [:]
            let pattern = /"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"/
            for match in text.matches(of: pattern) {
                found[String(match.1)] = String(match.2)
            }
            let ordered = questions.compactMap { found[$0.question] }
            return ordered.isEmpty ? "Answered" : ordered.joined(separator: "; ")
        }

        public static func string(_ value: JSONValue?) -> String? {
            if case .string(let text)? = value { text } else { nil }
        }
    }

    /// Tool calls that fold together, and how a run of them reads.
    public enum ToolKind: Equatable, Sendable {
        case run, read, edit, search, fetch, webSearch, agent, todo, other(String)

        public init(_ name: String) {
            switch name {
            case "Bash", "BashOutput", "KillShell", "KillBash": self = .run
            case "Read", "NotebookRead": self = .read
            case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .edit
            case "Grep", "Glob", "LS": self = .search
            case "WebFetch": self = .fetch
            case "WebSearch": self = .webSearch
            case "Task", "Agent": self = .agent
            case "TodoWrite": self = .todo
            default: self = .other(name)
            }
        }

        public func summary(_ calls: [(name: String, input: [String: JSONValue])]) -> String {
            let more = calls.count > 1 ? " and \(calls.count - 1) more" : ""
            let first = calls.first?.input ?? [:]
            switch self {
            case .run:
                return "Ran \(Self.short(Builder.string(first["command"]) ?? "a command"))" + more
            case .read:
                return "Read \(Self.fileName(first["file_path"]) ?? "a file")" + more
            case .edit:
                let files = Set(calls.compactMap { Self.fileName($0.input["file_path"] ?? $0.input["notebook_path"]) })
                return files.count > 1 ? "Edited \(files.count) files" : "Edited \(files.first ?? "a file")"
            case .search:
                return "Searched for \(Self.short(Builder.string(first["pattern"]) ?? "files"))" + more
            case .fetch:
                let url = Builder.string(first["url"]).flatMap { URL(string: $0)?.host() }
                return "Fetched \(url ?? "a page")" + more
            case .webSearch:
                return "Searched the web for \(Self.short(Builder.string(first["query"]) ?? "something"))" + more
            case .agent:
                return "Ran an agent: \(Self.short(Builder.string(first["description"]) ?? "a task"))" + more
            case .todo:
                return "Updated the to-do list"
            case .other(let name):
                let shortName =
                    name.hasPrefix("mcp__") ? String(name.split(separator: "__").last ?? Substring(name)) : name
                return "Used \(shortName)" + more
            }
        }

        static func fileName(_ value: JSONValue?) -> String? {
            Builder.string(value).map { ($0 as NSString).lastPathComponent }
        }

        /// The first line, cut to a phone's width.
        public static func short(_ text: String) -> String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.count > 80 ? String(line.prefix(79)) + "…" : line
        }
    }
}
