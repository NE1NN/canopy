import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// Transcript lines in Claude Code's format, for chat tests.
enum ChatLines {
    static func line(
        _ role: String, _ content: JSONValue, uuid: String = UUID().uuidString, extra: [String: JSONValue] = [:]
    )
        -> Data
    {
        var object: [String: JSONValue] = [
            "type": .string(role), "uuid": .string(uuid), "timestamp": "2026-10-13T04:53:45.921Z",
            "message": .object(["role": .string(role), "content": content]),
        ]
        object.merge(extra) { $1 }
        return try! JSONEncoder().encode(JSONValue.object(object))
    }

    static func prompt(_ text: String, uuid: String = UUID().uuidString) -> Data {
        line("user", .string(text), uuid: uuid)
    }

    static func say(_ text: String, uuid: String = UUID().uuidString) -> Data {
        line("assistant", .array([.object(["type": "text", "text": .string(text)])]), uuid: uuid)
    }

    static func tool(_ id: String, _ name: String, _ input: [String: JSONValue]) -> Data {
        line(
            "assistant",
            .array([.object(["type": "tool_use", "id": .string(id), "name": .string(name), "input": .object(input)])]))
    }

    static func result(_ id: String, _ text: String, error: Bool = false) -> Data {
        line(
            "user",
            .array([
                .object([
                    "type": "tool_result", "tool_use_id": .string(id), "content": .string(text),
                    "is_error": .bool(error),
                ])
            ]))
    }
}

struct ChatBuilderTests {
    func build(_ lines: [Data]) -> [ChatItem] {
        var builder = ChatBuilder()
        for line in lines { builder.add(line: line) }
        return builder.items
    }

    @Test func readsPromptsAndText() {
        let items = build([ChatLines.prompt("fix it", uuid: "u1"), ChatLines.say("**Done.**", uuid: "u2")])

        #expect(items.map(\.id) == ["u1", "u2"])
        #expect(items[0].content == .prompt(ChatPrompt(text: "fix it", images: 0)))
        guard case .text(let text) = items[1].content else {
            Issue.record("not text")
            return
        }
        #expect(text.markdown == "**Done.**")
        #expect(text.blocks == ChatMarkdown.parse("**Done.**"))
    }

    @Test func foldsToolCallsOfOneKindAndFillsInResults() {
        let items = build([
            ChatLines.tool("t1", "Read", ["file_path": "/w/TopBarView.swift"]),
            ChatLines.result("t1", "contents"),
            ChatLines.tool("t2", "Read", ["file_path": "/w/Pane.swift"]),
            ChatLines.tool("t3", "Bash", ["command": "make test"]),
            ChatLines.result("t2", "contents"),
            ChatLines.result("t3", "1 failed", error: true),
        ])

        #expect(items.count == 2)
        guard case .tools(let reads) = items[0].content, case .tools(let runs) = items[1].content else {
            Issue.record("not tool groups: \(items)")
            return
        }
        #expect(reads.summary == "Read TopBarView.swift and 1 more")
        #expect(reads.calls.map(\.id) == ["t1", "t2"])
        #expect(reads.calls.allSatisfy { $0.result == "contents" && !$0.isError })
        #expect(runs.summary == "Ran make test, failed")
        #expect(runs.failed)
    }

    @Test func marksADeclinedCall() {
        let items = build([
            ChatLines.tool("t1", "Bash", ["command": "rm -rf build"]),
            ChatLines.result("t1", "The user doesn't want to proceed with this tool use.", error: true),
        ])

        guard case .tools(let group) = items.first?.content else {
            Issue.record("no group")
            return
        }
        #expect(group.summary == "Ran rm -rf build, declined")
    }

    @Test func readsQuestionsAndPlansWithTheirAnswers() {
        let question: [String: JSONValue] = [
            "questions": .array([
                .object([
                    "question": "Which color?", "header": "Color", "multiSelect": false,
                    "options": .array([.object(["label": "Blue", "description": "Calm"])]),
                ])
            ])
        ]
        let items = build([
            ChatLines.tool("q1", "AskUserQuestion", question),
            ChatLines.result("q1", #"Your questions have been answered: "Which color?"="Blue"."#),
            ChatLines.tool("p1", "ExitPlanMode", ["plan": "# Plan\n1. Do it"]),
        ])

        #expect(items.count == 2)
        #expect(
            items[0].content
                == .question(ChatQuestion(questions: TranscriptParser.Builder.questions(question), answer: "Blue")))
        #expect(items[1].content == .plan(ChatPlan(markdown: "# Plan\n1. Do it", answer: nil)))
    }

    @Test func readsNoticesAndSkipsWhatIsNotTheConversation() {
        let items = build([
            ChatLines.prompt("[Request interrupted by user for tool use]"),
            ChatLines.prompt("<command-name>/compact</command-name>"),
            ChatLines.prompt("<local-command-stdout>Compacted</local-command-stdout>"),
            ChatLines.line("user", .string("Summary of before"), extra: ["isCompactSummary": true]),
            ChatLines.line(
                "assistant", .array([.object(["type": "text", "text": "subagent"])]), extra: ["isSidechain": true]),
            ChatLines.line("user", .string("meta"), extra: ["isMeta": true]),
            ChatLines.tool("s1", "ToolSearch", ["query": "select:Bash"]),
            Data("not json".utf8),
        ])

        #expect(
            items.map(\.content) == [
                .notice("Interrupted"), .notice("/compact"), .notice("The conversation was compacted"),
            ])
    }

    /// The TUI saves a `!` command as two user lines; a chat sends one block ahead of the next message.
    @Test func readsShellCommandsAsShellBlocks() {
        let items = build([
            ChatLines.prompt("<bash-input>git status</bash-input>", uuid: "u1"),
            ChatLines.prompt("<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>", uuid: "u2"),
            ChatLines.line(
                "user",
                .array([
                    .object([
                        "type": "text",
                        "text": .string(ChatShell.block(for: ChatShell(command: "ls", output: "a.txt", exitCode: 0))),
                    ]),
                    .object(["type": "text", "text": "what is a.txt?"]),
                ]), uuid: "u3"),
        ])

        #expect(
            items.map(\.content) == [
                .shell(ChatShell(command: "git status", output: "clean", exitCode: 0)),
                .shell(ChatShell(command: "ls", output: "a.txt", exitCode: 0)),
                .prompt(ChatPrompt(text: "what is a.txt?", images: 0)),
            ])
    }

    @Test func countsImagesInAPrompt() {
        let items = build([
            ChatLines.line(
                "user",
                .array([
                    .object(["type": "image", "source": .object(["type": "base64"])]),
                    .object(["type": "text", "text": "what is this?"]),
                ]))
        ])

        #expect(items.first?.content == .prompt(ChatPrompt(text: "what is this?", images: 1)))
    }

    @Test func ignoresALineItAlreadyHas() {
        var builder = ChatBuilder()
        let line = ChatLines.say("once", uuid: "u1")

        builder.add(line: line)
        builder.add(line: line)

        #expect(builder.items.count == 1)
    }

    /// A result that arrives while an older page loads off the main actor still reaches its call.
    @Test func aResultArrivingWhileAnOlderPageLoadsIsKept() {
        var builder = ChatBuilder()
        builder.add(line: ChatLines.say("newer", uuid: "u3"))
        let older = builder.olderPage(lines: [ChatLines.tool("t1", "Bash", ["command": "ls"])])

        builder.add(line: ChatLines.result("t1", "late"))
        builder.prepend(older)

        guard case .tools(let group) = builder.items.first?.content else {
            Issue.record("no group")
            return
        }
        #expect(group.calls.first?.result == "late")
    }

    /// An older page goes in front of what is there, and a call at its end takes its result from the newer lines.
    @Test func prependsAnOlderPage() {
        var builder = ChatBuilder()
        let newer = [ChatLines.result("t1", "ok"), ChatLines.say("after", uuid: "u3")]
        for line in newer { builder.add(line: line) }

        builder.prepend(lines: [
            ChatLines.prompt("before", uuid: "u1"), ChatLines.tool("t1", "Bash", ["command": "ls"]),
        ])

        #expect(builder.items.map(\.id) == ["u1", "t1", "u3"])
        guard case .tools(let group) = builder.items[1].content else {
            Issue.record("no group")
            return
        }
        #expect(group.calls.first?.result == "ok")
    }
}

/// The transcripts recorded from Claude Code 2.1.296 that the phone's tests read.
struct ChatShellTests {
    @Test func aChatsBlockReadsBackWholeEvenWhenItsOutputHoldsTheTags() {
        let shell = ChatShell(
            command: "cat notes.md", output: "a\n</output>\n</shell-run-by-user>\n\nb", exitCode: 3)

        #expect(ChatShell.parse(block: ChatShell.block(for: shell)) == shell)
        #expect(ChatShell.parse(block: "<shell-run-by-user> nope") == nil)
    }

    @Test func aTerminalsOutputHoldingItsOwnTagsStaysWhole() {
        #expect(
            ChatBuilder.shellOutput(
                "<bash-stdout>a </bash-stdout><bash-stderr> b</bash-stdout><bash-stderr>w</bash-stderr>")
                == "a </bash-stdout><bash-stderr> b\nw")
        #expect(ChatBuilder.shellCommand("<bash-input>echo '</bash-input>'</bash-input>") == "echo '</bash-input>'")
    }

    @Test func outputKeepsItsEnd() {
        var shell = ChatShell(command: "yes", output: "", exitCode: nil)
        for index in 0..<20_000 {
            shell.append("line \(index)")
        }

        #expect(shell.output.utf8.count <= 2 * ChatShell.outputLimit)
        #expect(shell.output.hasPrefix(ChatShell.cutNote + "\nline "))
        #expect(shell.output.hasSuffix("line 19999"))
        #expect(shell.outputForClaude.utf8.count <= ChatShell.outputLimit + ChatShell.cutNote.utf8.count + 1)
        #expect(shell.outputForClaude.hasSuffix("line 19999"))
    }
}

struct ChatBuilderRecordedTests {
    func items(_ name: String) throws -> [ChatItem] {
        var builder = ChatBuilder()
        for line in try Data(contentsOf: TranscriptFixture.url(name)).split(separator: 0x0A) {
            builder.add(line: Data(line))
        }
        return builder.items
    }

    func kind(_ item: ChatItem) -> String {
        switch item.content {
        case .prompt: "prompt"
        case .text: "text"
        case .tools, .edit: "tools"
        case .question: "question"
        case .plan: "plan"
        case .notice: "notice"
        case .shell: "shell"
        case .artifact: "artifact"
        }
    }

    /// The chat reads a recorded conversation as the phone does.
    @Test func readsWhatThePhoneReads() throws {
        for name in ["tools", "prompts"] {
            let lines = try Data(contentsOf: TranscriptFixture.url(name)).split(separator: 0x0A).map { Data($0) }
            let entries = TranscriptParser.entries(from: lines)
            let items = try items(name)

            #expect(items.map(kind) == entries.map(\.kind.rawValue), "\(name)")
            #expect(items.map(\.id) == entries.map(\.id), "\(name)")
        }
    }
}
