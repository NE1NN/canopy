import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// Lines as Claude Code 2.1.296 writes them with `--output-format stream-json --verbose --include-partial-messages`.
struct ClaudeEventTests {
    func event(_ line: String) -> ClaudeEvent? {
        ClaudeEvent(line: Data(line.utf8))
    }

    @Test func readsInit() {
        let line = """
            {"type":"system","subtype":"init","cwd":"/w/demo","session_id":"s-1","model":"claude-sonnet-5-5",\
            "permissionMode":"default","slash_commands":["compact","greet"],"tools":["Bash"],"claude_code_version":"2.1.296"}
            """

        #expect(
            event(line)
                == .initialized(
                    ClaudeInit(
                        session: "s-1", model: "claude-sonnet-5-5", mode: "default", cwd: "/w/demo", version: "2.1.296")
                )
        )
    }

    @Test func readsStatusChanges() {
        #expect(
            event(#"{"type":"system","subtype":"status","status":"requesting","session_id":"s"}"#)
                == .status(ClaudeStatus(activity: "requesting", mode: nil, compacted: nil)))
        #expect(
            event(#"{"type":"system","subtype":"status","status":null,"permissionMode":"plan","session_id":"s"}"#)
                == .status(ClaudeStatus(activity: nil, mode: "plan", compacted: nil)))
        #expect(
            event(#"{"type":"system","subtype":"status","status":null,"compact_result":"success","session_id":"s"}"#)
                == .status(ClaudeStatus(activity: nil, mode: nil, compacted: true)))
    }

    @Test func readsTasks() {
        let started = """
            {"type":"system","subtype":"task_started","task_id":"b9oz","tool_use_id":"toolu_1",\
            "description":"Print ticks","is_backgrounded":false,"task_type":"local_bash","session_id":"s"}
            """
        let ended = """
            {"type":"system","subtype":"task_notification","task_id":"b9oz","tool_use_id":"toolu_1",\
            "status":"completed","output_file":"","summary":"Print ticks","session_id":"s"}
            """

        #expect(event(started) == .taskStarted(task: "b9oz", toolUse: "toolu_1", background: false))
        #expect(event(ended) == .taskEnded(task: "b9oz", toolUse: "toolu_1", status: "completed"))
    }

    @Test func readsAConversationReset() {
        let line = """
            {"type":"conversation_reset","new_conversation_id":"a671","trigger":"clear","session_id":"f0bc"}
            """

        #expect(event(line) == .conversationReset)
    }

    @Test func keepsMessagesWhole() throws {
        let line = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],\
            "usage":{"input_tokens":2,"cache_creation_input_tokens":3096,"cache_read_input_tokens":36374,\
            "output_tokens":34}},"parent_tool_use_id":null,"session_id":"s","uuid":"u-1"}
            """

        guard case .message(let message) = event(line) else {
            Issue.record("not a message")
            return
        }
        #expect(message.role == "assistant")
        #expect(message.uuid == "u-1")
        #expect(message.parentToolUse == nil)
        #expect(message.isReplay == false)
        #expect(message.contextTokens == 2 + 3096 + 36374)
        #expect(message.line == Data(line.utf8))
    }

    @Test func marksSubagentAndReplayedMessages() {
        let sub = """
            {"type":"assistant","message":{"role":"assistant","content":[]},"parent_tool_use_id":"toolu_9",\
            "session_id":"s","uuid":"u-2"}
            """
        let replay = """
            {"type":"user","message":{"role":"user","content":"hi"},"session_id":"s","parent_tool_use_id":null,\
            "uuid":"u-3","isReplay":true}
            """

        guard case .message(let subagent) = event(sub), case .message(let replayed) = event(replay) else {
            Issue.record("not messages")
            return
        }
        #expect(subagent.parentToolUse == "toolu_9")
        #expect(replayed.isReplay)
        #expect(replayed.contextTokens == nil)
    }

    @Test func readsStreamDeltas() {
        let start = """
            {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","usage":\
            {"input_tokens":2,"output_tokens":1}}},"session_id":"s"}
            """
        let block = """
            {"type":"stream_event","event":{"type":"content_block_start","index":0,\
            "content_block":{"type":"thinking","thinking":""}},"session_id":"s"}
            """
        let delta = """
            {"type":"stream_event","event":{"type":"content_block_delta","index":1,\
            "delta":{"type":"text_delta","text":"Hel"}},"session_id":"s"}
            """
        let usage = """
            {"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":null},\
            "usage":{"output_tokens":57}},"session_id":"s"}
            """

        #expect(event(start) == .messageStarted(id: "msg_1"))
        #expect(event(block) == .blockStarted(index: 0, kind: "thinking"))
        #expect(event(delta) == .textDelta(index: 1, text: "Hel"))
        #expect(event(usage) == .outputTokens(57))
    }

    @Test func skipsASubagentsStreamedText() {
        let line = """
            {"type":"stream_event","event":{"type":"content_block_delta","index":0,\
            "delta":{"type":"text_delta","text":"inner"}},"parent_tool_use_id":"toolu_9","session_id":"s"}
            """

        #expect(event(line) == nil)
    }

    @Test func readsResults() {
        let line = """
            {"type":"result","subtype":"success","is_error":false,"duration_ms":18143,"result":"Done.",\
            "session_id":"s","modelUsage":{"claude-sonnet-5-5":{"contextWindow":1000000,"outputTokens":121}}}
            """
        let failed = """
            {"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s"}
            """

        #expect(
            event(line)
                == .result(ClaudeResult(isError: false, kind: "success", text: "Done.", contextWindow: 1_000_000)))
        #expect(
            event(failed)
                == .result(ClaudeResult(isError: true, kind: "error_during_execution", text: nil, contextWindow: nil)))
    }

    @Test func readsRateLimits() {
        let line = """
            {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791879000,\
            "rateLimitType":"five_hour"},"session_id":"s"}
            """

        #expect(event(line) == .rateLimit(allowed: false, resetsAt: Date(timeIntervalSince1970: 1_791_879_000)))
    }

    @Test func readsPermissionRequests() throws {
        let line = """
            {"type":"control_request","request_id":"r-1","request":{"subtype":"can_use_tool","tool_name":"Bash",\
            "display_name":"Bash","input":{"command":"touch x && ls","description":"Create file"},\
            "description":"Create file","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash",\
            "ruleContent":"touch x && ls"}],"behavior":"allow","destination":"localSettings"}],\
            "blocked_path":"/w/x","tool_use_id":"toolu_1"}}
            """

        guard case .toolRequest(let request) = event(line) else {
            Issue.record("not a tool request")
            return
        }
        #expect(request.id == "r-1")
        #expect(request.tool == "Bash")
        #expect(request.input["command"] == "touch x && ls")
        #expect(request.description == "Create file")
        #expect(request.blockedPath == "/w/x")
        #expect(request.toolUse == "toolu_1")
        #expect(request.needsAuthor == false)
        #expect(request.suggestions.count == 1)
    }

    @Test func readsOtherControlTraffic() {
        let unknown = #"{"type":"control_request","request_id":"r-2","request":{"subtype":"hook_callback"}}"#
        let success = """
            {"type":"control_response","response":{"subtype":"success","request_id":"c-1","response":{"mode":"plan"}}}
            """
        let failure = """
            {"type":"control_response","response":{"subtype":"error","request_id":"c-2","error":"no such mode"}}
            """

        #expect(event(unknown) == .unknownRequest(id: "r-2", kind: "hook_callback"))
        #expect(event(success) == .controlResponse(id: "c-1", error: nil, value: .object(["mode": "plan"])))
        #expect(event(failure) == .controlResponse(id: "c-2", error: "no such mode", value: nil))
    }

    @Test func skipsWhatItCannotRead() {
        #expect(event("not json") == nil)
        #expect(event(#"{"type":"something_new","x":1}"#) == nil)
        #expect(event(#"{"type":"system","subtype":"hook_started"}"#) == nil)
        #expect(event(#"{"type":"stream_event","event":{"type":"ping"}}"#) == nil)
    }

    // MARK: Input

    func decoded(_ data: Data) throws -> [String: JSONValue] {
        #expect(data.last == 0x0A)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    @Test func writesUserMessages() throws {
        let line = try decoded(ClaudeInput.user([.text("hi"), .image(mediaType: "image/png", data: Data([1, 2]))]))

        #expect(line["type"] == "user")
        #expect(line["parent_tool_use_id"] == .null)
        guard case .object(let message)? = line["message"], case .array(let content)? = message["content"] else {
            Issue.record("no content")
            return
        }
        #expect(message["role"] == "user")
        #expect(content[0] == .object(["type": "text", "text": "hi"]))
        #expect(
            content[1]
                == .object([
                    "type": "image",
                    "source": .object(["type": "base64", "media_type": "image/png", "data": "AQI="]),
                ]))
    }

    @Test func writesControlRequests() throws {
        let line = try decoded(ClaudeInput.request(id: "c-1", kind: "set_permission_mode", ["mode": "plan"]))

        #expect(line["type"] == "control_request")
        #expect(line["request_id"] == "c-1")
        #expect(line["request"] == .object(["subtype": "set_permission_mode", "mode": "plan"]))
    }

    @Test func writesPermissionAnswers() throws {
        let allow = try decoded(
            ClaudeInput.allow(request: "r-1", input: ["command": "ls"], permissions: [.object(["type": "addRules"])]))
        let deny = try decoded(ClaudeInput.deny(request: "r-2", message: "Run the tests instead"))
        let stop = try decoded(ClaudeInput.deny(request: "r-4", message: "No", interrupt: true))
        let refuse = try decoded(ClaudeInput.refuse(request: "r-3", error: "Canopy does not answer hook_callback"))

        #expect(
            allow["response"]
                == .object([
                    "subtype": "success", "request_id": "r-1",
                    "response": .object([
                        "behavior": "allow", "updatedInput": .object(["command": "ls"]),
                        "updatedPermissions": .array([.object(["type": "addRules"])]),
                    ]),
                ]))
        #expect(
            deny["response"]
                == .object([
                    "subtype": "success", "request_id": "r-2",
                    "response": .object(["behavior": "deny", "message": "Run the tests instead"]),
                ]))
        #expect(stop["response"]?.fields?["response"]?.fields?["interrupt"] == true)
        #expect(
            refuse["response"]
                == .object([
                    "subtype": "error", "request_id": "r-3", "error": "Canopy does not answer hook_callback",
                ]))
    }
}
