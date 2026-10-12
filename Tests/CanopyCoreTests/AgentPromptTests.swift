import Foundation
import Testing

@testable import CanopyCore

/// Hook inputs as Claude Code 2.1.296 sent them, trimmed and scrubbed.
enum CapturedHook {
    static let transcript = "/Users/author/.claude/projects/-Users-author-proj/5671.jsonl"
    static let questions =
        #"{"questions": [{"question": "What should the new file be named?", "header": "File name", "options": [{"label": "c.txt", "description": "Name the new file c.txt."}, {"label": "d.txt", "description": "Name the new file d.txt."}], "multiSelect": false}]}"#

    static func hook(_ event: String, tool: String? = nil, input: String? = nil, extra: String = "") -> Data {
        var fields = [
            #""session_id": "s1""#, #""transcript_path": "\#(transcript)""#, #""hook_event_name": "\#(event)""#,
        ]
        if let tool { fields.append(#""tool_name": "\#(tool)""#) }
        if let input { fields.append(#""tool_input": \#(input)"#) }
        if !extra.isEmpty { fields.append(extra) }
        return Data(("{" + fields.joined(separator: ", ") + "}").utf8)
    }

    static let askQuestion = hook("PreToolUse", tool: "AskUserQuestion", input: questions)
    static let askPermission = hook("PermissionRequest", tool: "AskUserQuestion", input: questions)
    static let notification = hook("Notification", extra: #""notification_type": "permission_prompt""#)
    static let bashPermission = hook(
        "PermissionRequest", tool: "Bash",
        input: #"{"command": "touch d.txt && ls -l d.txt", "description": "Create d.txt and list it"}"#,
        extra: #""permission_suggestions": [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]"#)
    static let plan = hook(
        "PreToolUse", tool: "ExitPlanMode",
        input:
            ##"{"plan": "# Add f.txt\n\n1. Create f.txt.\n2. Read it back.\n", "planFilePath": "/Users/author/.claude/plans/p.md"}"##
    )
    static let answered = hook("PostToolUse", tool: "AskUserQuestion", input: questions)
    static let stopOnQuestion = hook(
        "Stop", extra: #""last_assistant_message": "Tests pass.\n\nShould I open the PR?""#)
}

struct AgentPromptMappingTests {
    func report(_ data: Data) -> AgentReport? {
        ClaudeHookMapping.report(from: data, startedAt: nil)
    }

    @Test func everyHookCarriesItsTranscript() {
        #expect(
            report(CapturedHook.hook("SessionStart", extra: #""source": "startup""#))?.transcriptPath
                == CapturedHook.transcript)
        #expect(report(CapturedHook.hook("UserPromptSubmit"))?.transcriptPath == CapturedHook.transcript)
    }

    @Test func aQuestionIsAPromptWithItsOptions() throws {
        let prompt = try #require(report(CapturedHook.askQuestion)?.prompt)
        #expect(prompt.kind == .question)
        #expect(prompt.questions?.first?.question == "What should the new file be named?")
        #expect(prompt.questions?.first?.options.map(\.label) == ["c.txt", "d.txt"])
        // The permission request Claude Code sends for the same picker describes the same prompt.
        #expect(report(CapturedHook.askPermission)?.prompt == prompt)
    }

    @Test func aPermissionRequestSaysWhatItWantsToRun() throws {
        let permission = try #require(report(CapturedHook.bashPermission))
        #expect(permission.state == .waiting)
        #expect(permission.prompt == AgentPrompt(kind: .permission, tool: "Bash", detail: "touch d.txt && ls -l d.txt"))
    }

    @Test(arguments: [
        (#"{"file_path": "/Users/author/proj/notes.md", "content": "x"}"#, "Write", "/Users/author/proj/notes.md"),
        (#"{"url": "https://example.com/a", "prompt": "x"}"#, "WebFetch", "https://example.com/a"),
        (#"{"query": "x"}"#, "mcp__notion__notion-search", "notion-search"),
    ])
    func otherToolsNameTheirTarget(_ input: String, _ tool: String, _ detail: String) {
        let data = CapturedHook.hook("PermissionRequest", tool: tool, input: input)
        #expect(report(data)?.prompt?.detail == detail)
    }

    @Test func aPlanIsAPrompt() throws {
        let prompt = try #require(report(CapturedHook.plan)?.prompt)
        #expect(
            prompt
                == AgentPrompt(
                    kind: .plan, tool: "ExitPlanMode", detail: "# Add f.txt\n\n1. Create f.txt.\n2. Read it back.\n"))
    }

    @Test func aTurnEndingOnAQuestionWantsAReply() throws {
        let stop = try #require(report(CapturedHook.stopOnQuestion))
        #expect(stop.state == .waiting && stop.question)
        #expect(stop.prompt == AgentPrompt(kind: .reply, detail: "Should I open the PR?"))
    }

    @Test func aNotificationNamesNoPrompt() {
        #expect(report(CapturedHook.notification)?.state == .waiting)
        #expect(report(CapturedHook.notification)?.prompt == nil)
    }
}

struct OpenPromptTests {
    let start = Date(timeIntervalSince1970: 1_000)

    mutating func apply(_ agent: inout PaneAgent, _ data: Data, at seconds: Double) {
        var report = ClaudeHookMapping.report(from: data, startedAt: start + seconds)!
        report.at = start + seconds
        _ = agent.apply(report, now: start + seconds)
    }

    @Test mutating func aQuestionStaysTheSamePromptThroughItsPermissionRequestAndNotification() throws {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.hook("UserPromptSubmit"), at: 1)
        apply(&agent, CapturedHook.askQuestion, at: 2)
        let prompt = try #require(agent.prompt)
        apply(&agent, CapturedHook.askPermission, at: 3)
        apply(&agent, CapturedHook.notification, at: 4)
        #expect(agent.prompt == prompt)
        #expect(agent.state == .waiting)
        #expect(agent.transcriptPath == CapturedHook.transcript)

        apply(&agent, CapturedHook.answered, at: 5)
        #expect(agent.prompt == nil)
        #expect(agent.state == .working)
    }

    @Test mutating func aNewPromptGetsANewID() throws {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.bashPermission, at: 1)
        let first = try #require(agent.prompt)
        apply(&agent, CapturedHook.hook("PostToolUse", tool: "Bash"), at: 2)
        apply(&agent, CapturedHook.bashPermission, at: 3)
        let second = try #require(agent.prompt)
        #expect(first.id != second.id)
        #expect(second.kind == .permission)
    }

    @Test mutating func keysThatEndThePromptCloseIt() throws {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.bashPermission, at: 1)
        #expect(agent.prompt != nil)
        _ = agent.typed(Data([0x1B]), at: start + 2)
        #expect(agent.prompt == nil)

        apply(&agent, CapturedHook.bashPermission, at: 3)
        _ = agent.typed(Data("\r".utf8), at: start + 4)
        #expect(agent.prompt == nil && agent.state == .working)
    }

    @Test mutating func anyKeyAtTheMacClosesADialogsPrompt() throws {
        for key in ["1", "2", "\u{1b}[B", "y"] {
            var agent = PaneAgent()
            apply(&agent, CapturedHook.bashPermission, at: 1)
            #expect(agent.prompt != nil)
            _ = agent.typed(Data(key.utf8), at: start + 2)
            #expect(agent.prompt == nil, "after \(key.debugDescription)")
            #expect(agent.state == .waiting)
        }
    }

    @Test mutating func typingADraftLeavesAReplyPromptOpen() throws {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.stopOnQuestion, at: 1)
        _ = agent.typed(Data("y".utf8), at: start + 2)
        #expect(agent.prompt?.kind == .reply)
    }

    @Test mutating func aPartlyReadPickerCannotBeAnswered() throws {
        let input =
            #"{"questions": [{"question": "A?", "options": [{"label": "x"}]}, {"question": 7}]}"#
        let data = CapturedHook.hook("PreToolUse", tool: "AskUserQuestion", input: input)
        let prompt = try #require(ClaudeHookMapping.report(from: data, startedAt: nil)?.prompt)
        #expect(prompt.questions == nil)
        #expect(throws: ControlError.self) {
            try PhoneAnswerKeys.keys(for: prompt.opened(id: "q"), PhoneAnswer(options: [[0]]))
        }
    }

    @Test mutating func answeringClosesThePromptAtOnce() throws {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.askQuestion, at: 1)
        let prompt = try #require(agent.prompt)
        let wrong = agent.answer(promptID: "other")
        let right = agent.answer(promptID: prompt.id)
        let again = agent.answer(promptID: prompt.id)
        #expect(!wrong && right && !again)
        #expect(agent.prompt == nil)
    }

    @Test mutating func theAgentEndingClosesThePromptButKeepsTheTranscript() {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.askQuestion, at: 1)
        _ = agent.ended(at: start + 2)
        #expect(agent.prompt == nil)
        #expect(agent.transcriptPath == CapturedHook.transcript)
    }

    @Test mutating func aNewSessionBringsItsTranscript() {
        var agent = PaneAgent()
        apply(&agent, CapturedHook.hook("UserPromptSubmit"), at: 1)
        let resumed = Data(
            #"{"session_id": "s2", "transcript_path": "/t/s2.jsonl", "hook_event_name": "SessionStart", "source": "clear"}"#
                .utf8)
        apply(&agent, resumed, at: 2)
        #expect(agent.transcriptPath == "/t/s2.jsonl")
        // A session that does not hold the pane says nothing about its transcript.
        let other = Data(#"{"session_id": "s9", "transcript_path": "/t/s9.jsonl", "hook_event_name": "Stop"}"#.utf8)
        apply(&agent, other, at: 3)
        #expect(agent.transcriptPath == "/t/s2.jsonl")
    }
}

struct TermStatePromptTests {
    @Test func theHookCommandHandsThePromptAndTranscriptToTheApp() throws {
        let report = try #require(ClaudeHookMapping.report(from: CapturedHook.bashPermission, startedAt: nil))
        let params = TermStateParams(pane: "p1", report)
        let decoded = try JSONValue.from(params).decode(TermStateParams.self)
        #expect(decoded.report == report)
        #expect(decoded.report.transcriptPath == CapturedHook.transcript)
    }

    @Test func aPromptThisBuildCannotReadKeepsTheState() throws {
        let json = #"{"pane": "p1", "state": "waiting", "prompt": {"kind": 7}}"#
        let decoded = try JSONDecoder().decode(TermStateParams.self, from: Data(json.utf8))
        #expect(decoded.state == .waiting && decoded.prompt == nil)
    }
}
