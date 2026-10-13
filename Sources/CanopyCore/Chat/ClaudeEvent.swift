import Foundation

/// What `init` says about the session.
public struct ClaudeInit: Equatable, Sendable {
    public var session: String
    public var model: String
    public var mode: String
    public var cwd: String
    /// Claude Code's version, such as "2.1.296".
    public var version: String?
}

/// A `status` line: what Claude is doing, a permission mode it switched to, or how compacting went.
public struct ClaudeStatus: Equatable, Sendable {
    /// `requesting` or `compacting`, or nil when it stopped doing either.
    public var activity: String?
    public var mode: String?
    public var compacted: Bool?
}

/// A whole message, in the form Claude Code also writes to its transcript, kept as the line it came in.
public struct ClaudeMessage: Equatable, Sendable {
    public var role: String
    public var uuid: String?
    /// Set for a subagent's message: the tool call that started it.
    public var parentToolUse: String?
    /// One of the author's messages, echoed once Claude took it.
    public var isReplay: Bool
    /// What the conversation held when the message was written, for an assistant message that says.
    public var contextTokens: Int?
    public var line: Data
}

/// The end of a turn.
public struct ClaudeResult: Equatable, Sendable {
    public var isError: Bool
    /// `success`, `error_during_execution`, `error_max_turns`, and the like.
    public var kind: String
    public var text: String?
    public var contextWindow: Int?
}

/// A tool call waiting on Canopy: a permission prompt, or a tool that needs the author, such as AskUserQuestion.
public struct ClaudeToolRequest: Equatable, Sendable {
    public var id: String
    public var tool: String
    public var input: [String: JSONValue]
    public var description: String?
    public var blockedPath: String?
    public var toolUse: String?
    /// Claude Code asks the author whatever the permission mode says, as for AskUserQuestion and ExitPlanMode.
    public var needsAuthor: Bool
    /// Rules Claude Code offers to save with the answer, sent back as they are for Always allow.
    public var suggestions: [JSONValue]
}

/// One line of Claude Code's stream-json output, or nil for a line Canopy does not use.
public enum ClaudeEvent: Equatable, Sendable {
    case initialized(ClaudeInit)
    case status(ClaudeStatus)
    case conversationReset
    case taskStarted(task: String, toolUse: String?, background: Bool)
    case taskEnded(task: String, toolUse: String?, status: String)
    case message(ClaudeMessage)
    case messageStarted(id: String)
    case blockStarted(index: Int, kind: String)
    case textDelta(index: Int, text: String)
    case outputTokens(Int)
    case result(ClaudeResult)
    case rateLimit(allowed: Bool, resetsAt: Date?)
    case toolRequest(ClaudeToolRequest)
    /// A control request Canopy does not answer, which still needs an answer.
    case unknownRequest(id: String, kind: String)
    case controlResponse(id: String, error: String?, value: JSONValue?)

    public init?(line: Data) {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: line),
            let type = object["type"]?.text
        else { return nil }
        switch type {
        case "system": self.init(system: object)
        case "conversation_reset": self = .conversationReset
        case "assistant", "user": self.init(message: object, role: type, line: line)
        case "stream_event": self.init(stream: object["event"]?.fields ?? [:])
        case "result":
            var window: Int?
            if case .object(let models)? = object["modelUsage"] {
                window = models.values.compactMap { $0.fields?["contextWindow"]?.integer }.max()
            }
            self = .result(
                ClaudeResult(
                    isError: object["is_error"]?.flag ?? false, kind: object["subtype"]?.text ?? "",
                    text: object["result"]?.text, contextWindow: window))
        case "rate_limit_event":
            let info = object["rate_limit_info"]?.fields ?? [:]
            self = .rateLimit(
                allowed: info["status"]?.text != "rejected",
                resetsAt: info["resetsAt"]?.number.map(Date.init(timeIntervalSince1970:)))
        case "control_request": self.init(request: object)
        case "control_response":
            let response = object["response"]?.fields ?? [:]
            guard let id = response["request_id"]?.text else { return nil }
            let failed = response["subtype"]?.text == "error"
            self = .controlResponse(
                id: id, error: failed ? response["error"]?.text ?? "failed" : nil,
                value: failed ? nil : response["response"])
        default: return nil
        }
    }

    private init?(system object: [String: JSONValue]) {
        switch object["subtype"]?.text {
        case "init":
            guard let session = object["session_id"]?.text else { return nil }
            self = .initialized(
                ClaudeInit(
                    session: session, model: object["model"]?.text ?? "", mode: object["permissionMode"]?.text ?? "",
                    cwd: object["cwd"]?.text ?? "", version: object["claude_code_version"]?.text))
        case "status":
            let compacted = object["compact_result"]?.text.map { $0 == "success" }
            self = .status(
                ClaudeStatus(
                    activity: object["status"]?.text, mode: object["permissionMode"]?.text, compacted: compacted))
        case "task_started":
            guard let task = object["task_id"]?.text else { return nil }
            self = .taskStarted(
                task: task, toolUse: object["tool_use_id"]?.text, background: object["is_backgrounded"]?.flag ?? false)
        case "task_notification":
            guard let task = object["task_id"]?.text else { return nil }
            self = .taskEnded(
                task: task, toolUse: object["tool_use_id"]?.text, status: object["status"]?.text ?? "")
        default:
            return nil
        }
    }

    private init(message object: [String: JSONValue], role: String, line: Data) {
        var context: Int?
        if case .object(let usage)? = object["message"]?.fields?["usage"] {
            let counts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap {
                usage[$0]?.integer
            }
            context = counts.isEmpty ? nil : counts.reduce(0, +)
        }
        self = .message(
            ClaudeMessage(
                role: role, uuid: object["uuid"]?.text, parentToolUse: object["parent_tool_use_id"]?.text,
                isReplay: object["isReplay"]?.flag ?? false, contextTokens: context, line: line))
    }

    private init?(stream event: [String: JSONValue]) {
        switch event["type"]?.text {
        case "message_start":
            guard let id = event["message"]?.fields?["id"]?.text else { return nil }
            self = .messageStarted(id: id)
        case "content_block_start":
            guard let index = event["index"]?.integer, let kind = event["content_block"]?.fields?["type"]?.text
            else { return nil }
            self = .blockStarted(index: index, kind: kind)
        case "content_block_delta":
            guard let index = event["index"]?.integer, let delta = event["delta"]?.fields,
                delta["type"]?.text == "text_delta", let text = delta["text"]?.text
            else { return nil }
            self = .textDelta(index: index, text: text)
        case "message_delta":
            guard let tokens = event["usage"]?.fields?["output_tokens"]?.integer else { return nil }
            self = .outputTokens(tokens)
        default:
            return nil
        }
    }

    private init?(request object: [String: JSONValue]) {
        guard let id = object["request_id"]?.text, let request = object["request"]?.fields,
            let kind = request["subtype"]?.text
        else { return nil }
        guard kind == "can_use_tool", let tool = request["tool_name"]?.text else {
            self = .unknownRequest(id: id, kind: kind)
            return
        }
        var suggestions: [JSONValue] = []
        if case .array(let items)? = request["permission_suggestions"] { suggestions = items }
        self = .toolRequest(
            ClaudeToolRequest(
                id: id, tool: tool, input: request["input"]?.fields ?? [:], description: request["description"]?.text,
                blockedPath: request["blocked_path"]?.text, toolUse: request["tool_use_id"]?.text,
                needsAuthor: request["requires_user_interaction"]?.flag ?? false, suggestions: suggestions))
    }
}

/// Lines Canopy writes to Claude Code's stream-json input, each ending in a newline.
public enum ClaudeInput {
    public enum Content: Equatable, Sendable {
        case text(String)
        case image(mediaType: String, data: Data)

        var json: JSONValue {
            switch self {
            case .text(let text):
                return .object(["type": "text", "text": .string(text)])
            case .image(let mediaType, let data):
                return .object([
                    "type": "image",
                    "source": .object([
                        "type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString()),
                    ]),
                ])
            }
        }
    }

    public static func user(_ content: [Content]) -> Data {
        line([
            "type": "user", "message": .object(["role": "user", "content": .array(content.map(\.json))]),
            "parent_tool_use_id": .null, "session_id": "",
        ])
    }

    public static func request(id: String, kind: String, _ fields: [String: JSONValue] = [:]) -> Data {
        var request = fields
        request["subtype"] = .string(kind)
        return line(["type": "control_request", "request_id": .string(id), "request": .object(request)])
    }

    public static func allow(request: String, input: [String: JSONValue], permissions: [JSONValue] = []) -> Data {
        var answer: [String: JSONValue] = ["behavior": "allow", "updatedInput": .object(input)]
        if !permissions.isEmpty { answer["updatedPermissions"] = .array(permissions) }
        return response(request, answer)
    }

    /// With `interrupt`, Claude also stops the turn and waits, as Esc at a prompt in the TUI does.
    public static func deny(request: String, message: String, interrupt: Bool = false) -> Data {
        var answer: [String: JSONValue] = ["behavior": "deny", "message": .string(message)]
        if interrupt { answer["interrupt"] = true }
        return response(request, answer)
    }

    /// Answers a control request Canopy cannot handle, so Claude does not wait on it.
    public static func refuse(request: String, error: String) -> Data {
        line([
            "type": "control_response",
            "response": .object(["subtype": "error", "request_id": .string(request), "error": .string(error)]),
        ])
    }

    private static func response(_ request: String, _ answer: [String: JSONValue]) -> Data {
        line([
            "type": "control_response",
            "response": .object(["subtype": "success", "request_id": .string(request), "response": .object(answer)]),
        ])
    }

    private static func line(_ object: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

extension JSONValue {
    var text: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var integer: Int? {
        number.map { Int($0) }
    }

    var flag: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var fields: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }
}
