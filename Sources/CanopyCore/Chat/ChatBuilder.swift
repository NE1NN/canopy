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
    private var orphanStructured: [String: JSONValue] = [:]
    private var revisions = 0
    /// Artifacts published since `takePublished` last ran.
    private var published: [ChatArtifact] = []

    public init() {}

    public mutating func add(line: Data) {
        guard let record = TranscriptParser.Record(line: line) else { return }
        add(record)
    }

    /// A subagent's own message, which counts its tool calls on the call that started it.
    public mutating func add(subagentLine line: Data, parent: String) {
        guard let record = TranscriptParser.Record(line: line), seen.insert(record.id).inserted,
            let itemID = callItems[parent], let index = items.lastIndex(where: { $0.id == itemID }),
            case .tools(let group) = items[index].content
        else { return }
        let calls = record.blocks.filter { if case .tool = $0 { true } else { false } }.count
        guard calls > 0 else { return }
        var updated = group.calls
        if let call = updated.firstIndex(where: { $0.id == parent }) { updated[call].innerCalls += calls }
        items[index].content = .tools(ChatToolGroup(calls: updated))
        items[index].revision = nextRevision()
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
        older.orphanStructured = orphanStructured
        older.seen = seen
        for line in lines { older.add(line: line) }
        return older
    }

    public mutating func prepend(_ older: ChatBuilder) {
        // Results that arrived while the page loaded belong to its calls too.
        let late = orphanResults.filter { older.callItems[$0.key] != nil }
        let lateStructured = orphanStructured.filter { older.callItems[$0.key] != nil }
        defer {
            for (id, result) in late { addResult(id, result, structured: lateStructured[id]) }
            markVersions()
        }
        for id in older.callItems.keys {
            orphanResults[id] = nil
            orphanStructured[id] = nil
        }
        items = older.items + items
        seen.formUnion(older.seen)
        callItems.merge(older.callItems) { new, _ in new }
        orphanResults.merge(older.orphanResults.filter { callItems[$0.key] == nil }) { new, _ in new }
        orphanStructured.merge(older.orphanStructured.filter { callItems[$0.key] == nil }) { new, _ in new }
    }

    /// Artifacts whose publish came in since the last call, oldest first.
    public mutating func takePublished() -> [ChatArtifact] {
        defer { published = [] }
        return published
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
                addResult(
                    id, TranscriptParser.ToolResult(text: text, isError: isError), structured: record.toolUseResult)
            case .tool: break
            }
        }
        // A TUI's `!` commands come as `<bash-input>` and `<bash-stdout>` lines, a chat's as blocks ahead of a message.
        var shellIndex: Int?
        parts = parts.filter { part in
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let shell = ChatShell.parse(block: text) {
                append(ChatItem(id: record.id + "#shell\(items.count)", content: .shell(shell), at: record.at))
                return false
            }
            if let command = Self.shellCommand(text) {
                // Done unless its output says otherwise: in a TUI transcript the output can be on an older page.
                append(
                    ChatItem(
                        id: record.id + "#shell\(items.count)",
                        content: .shell(ChatShell(command: command, output: "", exitCode: 0)), at: record.at))
                shellIndex = items.count - 1
                return false
            }
            if let output = Self.shellOutput(text) {
                let index = shellIndex ?? items.lastIndex { if case .shell = $0.content { true } else { false } }
                if let index, case .shell(var shell) = items[index].content {
                    shell.output = output
                    items[index].content = .shell(shell)
                    items[index].revision = nextRevision()
                }
                return false
            }
            return true
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

    static func shellCommand(_ text: String) -> String? {
        guard text.hasPrefix("<bash-input>"), text.hasSuffix("</bash-input>") else { return nil }
        return String(text.dropFirst("<bash-input>".count).dropLast("</bash-input>".count))
    }

    /// A TUI's output, cut at the last closing tags, since the output itself may hold them. Its stderr stays output.
    static func shellOutput(_ text: String) -> String? {
        guard text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") else { return nil }
        var stdout = ""
        var stderr = Substring(text)
        if text.hasPrefix("<bash-stdout>") {
            let body = text.dropFirst("<bash-stdout>".count)
            guard let end = body.range(of: "</bash-stdout><bash-stderr>", options: .backwards) else {
                return String(body.hasSuffix("</bash-stdout>") ? body.dropLast("</bash-stdout>".count) : body)
            }
            stdout = String(body[..<end.lowerBound])
            stderr = "<bash-stderr>" + body[end.upperBound...]
        }
        stderr = stderr.dropFirst("<bash-stderr>".count)
        if stderr.hasSuffix("</bash-stderr>") { stderr = stderr.dropLast("</bash-stderr>".count) }
        return [stdout.trimmingCharacters(in: .newlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
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
                addTool(
                    ChatToolCall(
                        id: id, name: name, input: input, result: nil, isError: false,
                        edit: ChatEdit(proposed: name, input: input)),
                    at: record.at)
            case .image, .result: break
            }
        }
        flush(&self)
    }

    private mutating func addTool(_ call: ChatToolCall, at: Double) {
        var call = call
        let structured = orphanStructured.removeValue(forKey: call.id)
        if let result = orphanResults.removeValue(forKey: call.id) {
            call.result = result.text
            call.isError = result.isError
        }
        switch call.name {
        case "ToolSearch":
            return
        case "Artifact" where ChatArtifact.publishes(call) && !call.isError:
            var artifact = ChatArtifact(call: call)
            if let result = call.result { artifact.published(text: result, structured: structured) }
            // A result that names no page reads as the tool call it was, as when it comes after the call.
            if call.result != nil, artifact.url == nil {
                append(ChatItem(id: call.id, content: .tools(ChatToolGroup(calls: [call])), at: at))
            } else {
                append(ChatItem(id: call.id, content: .artifact(artifact), at: at))
                if artifact.url != nil { markVersions() }
            }
        case "AskUserQuestion":
            let questions = TranscriptParser.Builder.questions(call.input)
            let question = ChatQuestion(questions: questions, answer: answer(toQuestions: questions, call))
            append(ChatItem(id: call.id, content: .question(question), at: at))
        case let name where ChatEdit.tools.contains(name):
            append(ChatItem(id: call.id, content: .edit(call), at: at))
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

    private mutating func addResult(
        _ id: String, _ result: TranscriptParser.ToolResult, structured: JSONValue? = nil
    ) {
        guard let itemID = callItems[id], let index = items.lastIndex(where: { $0.id == itemID }) else {
            orphanResults[id] = result
            orphanStructured[id] = structured
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
        case .edit(var call):
            call.result = result.text
            call.isError = result.isError
            if let edit = ChatEdit(result: structured) { call.edit = edit }
            items[index].content = .edit(call)
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
        case .artifact(var artifact):
            items[index].revision = nextRevision()
            var call = artifact.call
            call.result = result.text
            call.isError = result.isError
            artifact.published(text: result.text, structured: structured)
            guard !result.isError, artifact.url != nil else {
                // A publish that failed, or whose result names no page, reads as the tool call it was.
                items[index].content = .tools(ChatToolGroup(calls: [call]))
                return
            }
            items[index].content = .artifact(artifact)
            markVersions()
            if case .artifact(let numbered) = items[index].content { published.append(numbered) }
        default:
            break
        }
    }

    /// Numbers each artifact's versions in the conversation, where the result named none, and marks all but the
    /// newest of each as replaced.
    private mutating func markVersions() {
        var counts: [URL: Int] = [:]
        var newest: [URL: Int] = [:]
        var numbered: [Int: Int] = [:]
        for (index, item) in items.enumerated() {
            guard case .artifact(let artifact) = item.content, let url = artifact.url else { continue }
            counts[url, default: 0] += 1
            let version = artifact.reportedVersion ?? counts[url, default: 1]
            numbered[index] = version
            newest[url] = max(newest[url] ?? 0, version)
        }
        for (index, version) in numbered {
            guard case .artifact(var artifact) = items[index].content, let url = artifact.url else { continue }
            let replacedBy = newest[url].flatMap { $0 > version ? $0 : nil }
            guard artifact.version != version || artifact.replacedBy != replacedBy else { continue }
            artifact.version = version
            artifact.replacedBy = replacedBy
            items[index].content = .artifact(artifact)
            items[index].revision = nextRevision()
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
