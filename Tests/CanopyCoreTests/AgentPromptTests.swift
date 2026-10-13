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
