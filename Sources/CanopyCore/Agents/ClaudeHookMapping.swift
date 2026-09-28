import Foundation

/// Turns what a Claude Code hook receives on stdin into a report of the agent's state.
public enum ClaudeHookMapping {
    /// The report for a hook's input, or nil for an event that says nothing about the pane.
    /// `startedAt` is when the hook process started, which orders reports that arrive out of order.
    public static func report(from input: Data, startedAt: Date?) -> AgentReport? {
        guard let hook = try? JSONDecoder().decode(HookInput.self, from: input) else { return nil }
        func report(
            _ state: AgentState?, question: Bool = false, takesOver: Bool = false, releases: Bool = false
        ) -> AgentReport {
            AgentReport(
                state: state, session: hook.sessionID, event: hook.event, at: startedAt, question: question,
                takesOver: takesOver, releases: releases)
        }
        let fromMainAgent = hook.agentID == nil
        switch hook.event {
        case "SessionStart":
            return report(nil, takesOver: (hook.source ?? "startup") != "startup")
        case "SessionEnd":
            return report(AgentState.none, releases: true)
        case "UserPromptSubmit", "ElicitationResult":
            return report(.working)
        case "PostToolUse", "PostToolUseFailure":
            return fromMainAgent ? report(.working) : nil
        case "PreToolUse":
            return ["AskUserQuestion", "ExitPlanMode"].contains(hook.toolName) ? report(.waiting) : nil
        case "PermissionRequest":
            return fromMainAgent ? report(.waiting) : nil
        case "Elicitation":
            return report(.waiting)
        case "Notification":
            switch hook.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return report(.waiting)
            case "agent_completed":
                return report(.done)
            default:
                return nil
            }
        case "Stop":
            // Background subagents and workflows end on their own and wake the agent, so the turn is not over.
            // Shell and monitor tasks can run for good, like a dev server, so they do not count.
            if hook.backgroundTasks?.contains(where: { ["subagent", "workflow"].contains($0.type) }) == true {
                return report(.working)
            }
            if let message = hook.lastAssistantMessage, endsOnQuestion(message) {
                return report(.waiting, question: true)
            }
            return report(.done)
        case "StopFailure":
            return report(.done)
        default:
            return nil
        }
    }

    /// Whether a message's last line that is not blank ends in a question mark, after closing marks such as `**`,
    /// `)`, and quotes.
    public static func endsOnQuestion(_ message: String) -> Bool {
        guard let line = message.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) })
        else { return false }
        var text = line
        while let last = text.last, last.isWhitespace || closingMarks.contains(last) {
            text = text.dropLast()
        }
        return text.last == "?" || text.last == "？"
    }

    static let closingMarks: Set<Character> = ["*", "_", "`", ")", "]", "\"", "'", "”", "’"]

    struct HookInput: Decodable {
        var event: String
        var sessionID: String?
        var agentID: String?
        var source: String?
        var toolName: String?
        var notificationType: String?
        var lastAssistantMessage: String?
        var backgroundTasks: [BackgroundTask]?

        struct BackgroundTask: Decodable {
            var type: String?
        }

        enum CodingKeys: String, CodingKey {
            case event = "hook_event_name"
            case sessionID = "session_id"
            case agentID = "agent_id"
            case source
            case toolName = "tool_name"
            case notificationType = "notification_type"
            case lastAssistantMessage = "last_assistant_message"
            case backgroundTasks = "background_tasks"
        }
    }
}

/// What `canopy agent-hook` sends, and where.
public struct AgentHookRequest: Sendable {
    public var socketPath: String
    public var request: ControlRequest
}

public enum AgentHook {
    /// The request for a hook's input, or nil outside a Canopy terminal or for an event that maps to nothing.
    public static func request(input: Data, environment: [String: String], startedAt: Date?) -> AgentHookRequest? {
        guard let pane = environment["CANOPY_PANE"], !pane.isEmpty,
            let home = environment[CanopyHome.environmentKey], !home.isEmpty,
            let report = ClaudeHookMapping.report(from: input, startedAt: startedAt),
            let params = try? JSONValue.from(TermStateParams(pane: pane, report))
        else { return nil }
        return AgentHookRequest(
            socketPath: CanopyHome(path: home).socketPath,
            request: ControlRequest(method: TermMethod.state, params: params))
    }
}
