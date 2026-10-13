import Foundation

/// Builds a chat's items from transcript lines, which are also what Claude Code streams, one line at a time.
/// Consecutive tool calls of one kind fold into a group, and a call's result fills it in when it comes.
public struct ChatBuilder: Sendable {
    public private(set) var items: [ChatItem] = []
    /// Lines already taken, by UUID.
    private var seen: Set<String> = []
    /// The item each call is in.
    private var callItems: [String: String] = [:]
    /// Results whose call is not loaded, which an older page may hold.
    private var orphanResults: [String: TranscriptParser.ToolResult] = [:]
    private var revisions = 0

    public init() {}

    public mutating func add(line: Data) {
        guard let record = TranscriptParser.Record(line: line) else { return }
        add(record)
    }

    /// A notice from Canopy rather than the transcript, such as an error Claude Code reported.
    public mutating func addNotice(_ text: String) {
        append(ChatItem(id: "notice-" + UUID().uuidString, content: .notice(text), at: Date().timeIntervalSince1970))
    }

    /// Puts an older page of lines in front of the items.
    public mutating func prepend(lines: [Data]) {
        prepend(olderPage(lines: lines))
    }

    /// An older page built apart, which can happen off the main actor, for `prepend(_:)` to put in front.
    public func olderPage(lines: [Data]) -> ChatBuilder {
        var older = ChatBuilder()
        older.orphanResults = orphanResults
        older.seen = seen
        for line in lines { older.add(line: line) }
        return older
    }

    public mutating func prepend(_ older: ChatBuilder) {
        for id in older.callItems.keys { orphanResults[id] = nil }
        items = older.items + items
        seen.formUnion(older.seen)
        callItems.merge(older.callItems) { new, _ in new }
        orphanResults.merge(older.orphanResults.filter { callItems[$0.key] == nil }) { new, _ in new }
    }

    mutating func add(_ record: TranscriptParser.Record) {
        guard seen.insert(record.id).inserted else { return }
        if record.role == "user" {
            addUser(record)
        } else {
            addAssistant(record)
        }
    }

    private mutating func addUser(_ record: TranscriptParser.Record) {
        var parts: [String] = []
        var images = 0
        for block in record.blocks {
            switch block {
            case .text(let text): parts.append(text)
            case .image: images += 1
            case .result(let id, let text, let isError):
                addResult(id, TranscriptParser.ToolResult(text: text, isError: isError))
            case .tool: break
            }
        }
        if record.isCompactSummary {
            append(ChatItem(id: record.id, content: .notice("The conversation was compacted"), at: record.at))
            return
        }
        let text = TranscriptParser.Builder.unwrappingPastes(parts.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || images > 0 else { return }
        if let notice = TranscriptParser.Builder.notice(for: text) {
            if !notice.isEmpty { append(ChatItem(id: record.id, content: .notice(notice), at: record.at)) }
            return
        }
        append(ChatItem(id: record.id, content: .prompt(ChatPrompt(text: text, images: images)), at: record.at))
    }

    private mutating func addAssistant(_ record: TranscriptParser.Record) {
        var texts: [String] = []
        var count = 0
        func flush(_ builder: inout ChatBuilder) {
            let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            texts = []
            guard !text.isEmpty else { return }
            let id = count == 0 ? record.id : record.id + "#\(count)"
            count += 1
            builder.append(ChatItem(id: id, content: .text(ChatText(text)), at: record.at))
        }
        for block in record.blocks {
            switch block {
            case .text(let text): texts.append(text)
            case .tool(let id, let name, let input):
                flush(&self)
                addTool(ChatToolCall(id: id, name: name, input: input, result: nil, isError: false), at: record.at)
            case .image, .result: break
            }
        }
        flush(&self)
    }

    private mutating func addTool(_ call: ChatToolCall, at: Double) {
        var call = call
        if let result = orphanResults.removeValue(forKey: call.id) {
            call.result = result.text
            call.isError = result.isError
        }
        switch call.name {
        case "ToolSearch":
            return
        case "AskUserQuestion":
            let questions = TranscriptParser.Builder.questions(call.input)
            let question = ChatQuestion(questions: questions, answer: answer(toQuestions: questions, call))
            append(ChatItem(id: call.id, content: .question(question), at: at))
        case "ExitPlanMode":
            let plan = ChatPlan(
                markdown: TranscriptParser.Builder.string(call.input["plan"]) ?? "", answer: answer(toPlan: call))
            append(ChatItem(id: call.id, content: .plan(plan), at: at))
        default:
            if case .tools(let group)? = items.last?.content,
                TranscriptParser.ToolKind(group.calls[0].name) == TranscriptParser.ToolKind(call.name)
            {
                items[items.count - 1].content = .tools(ChatToolGroup(calls: group.calls + [call]))
                items[items.count - 1].revision = nextRevision()
                callItems[call.id] = items[items.count - 1].id
            } else {
                append(ChatItem(id: call.id, content: .tools(ChatToolGroup(calls: [call])), at: at))
                callItems[call.id] = call.id
            }
            return
        }
        callItems[call.id] = call.id
    }

    private mutating func addResult(_ id: String, _ result: TranscriptParser.ToolResult) {
        guard let itemID = callItems[id], let index = items.lastIndex(where: { $0.id == itemID }) else {
            orphanResults[id] = result
            return
        }
        switch items[index].content {
        case .tools(let group):
            var calls = group.calls
            if let call = calls.firstIndex(where: { $0.id == id }) {
                calls[call].result = result.text
                calls[call].isError = result.isError
            }
            items[index].content = .tools(ChatToolGroup(calls: calls))
            items[index].revision = nextRevision()
        case .question(var question):
            question.answer =
                result.isError
                ? "Declined" : TranscriptParser.Builder.answers(in: result.text, for: question.questions)
            items[index].content = .question(question)
            items[index].revision = nextRevision()
        case .plan(var plan):
            plan.answer = result.isError ? "Declined" : "Approved"
            items[index].content = .plan(plan)
            items[index].revision = nextRevision()
        default:
            break
        }
    }

    private func answer(toQuestions questions: [PromptQuestion], _ call: ChatToolCall) -> String? {
        guard let result = call.result else { return nil }
        return call.isError ? "Declined" : TranscriptParser.Builder.answers(in: result, for: questions)
    }

    private func answer(toPlan call: ChatToolCall) -> String? {
        call.result.map { _ in call.isError ? "Declined" : "Approved" }
    }

    private mutating func append(_ item: ChatItem) {
        var item = item
        item.revision = nextRevision()
        items.append(item)
    }

    private mutating func nextRevision() -> Int {
        revisions += 1
        return revisions
    }
}
