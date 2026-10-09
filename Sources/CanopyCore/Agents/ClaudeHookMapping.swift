import Foundation

/// Turns what a Claude Code hook receives on stdin into a report of the agent's state.
public enum ClaudeHookMapping {
    /// The report for a hook's input, or nil for an event that says nothing about the pane.
    /// `startedAt` is when the hook process started, which orders reports that arrive out of order.
    public static func report(from input: Data, startedAt: Date?) -> AgentReport? {
        guard let hook = try? JSONDecoder().decode(HookInput.self, from: input) else { return nil }
        func report(
            _ state: AgentState?, question: Bool = false, takesOver: Bool = false, releases: Bool = false,
            backgroundTasks: [String] = []
        ) -> AgentReport {
            AgentReport(
                state: state, session: hook.sessionID, event: hook.event, at: startedAt, question: question,
                takesOver: takesOver, releases: releases, backgroundTasks: backgroundTasks)
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
            default:
                // agent_completed is a background session finishing, not this pane's agent, which Stop reports.
                return nil
            }
        case "Stop":
            // Background subagents and workflows end on their own and wake the agent, so the turn is not over.
            if hook.backgroundTasks?.contains(where: { $0.isAgent && $0.isRunning }) == true {
                return report(.working)
            }
            if let message = hook.lastAssistantMessage, endsOnQuestion(message) {
                return report(.waiting, question: true)
            }
            // Shells and monitors can run for good, like a dev server, so the turn is over, but the agent will wake.
            let running = (hook.backgroundTasks ?? []).filter { !$0.isAgent && $0.isRunning }
            if !running.isEmpty {
                return report(.background, backgroundTasks: running.map(\.label))
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
            var status: String?
            var description: String?
            var command: String?

            /// Subagents and workflows. Any other kind is background work, so a kind Claude Code adds later shows
            /// background rather than done.
            var isAgent: Bool { ["subagent", "workflow"].contains(type) }
            var isRunning: Bool { status == nil || status == "running" }

            var label: String {
                [description, command, type].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "background task"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                status = try? container.decodeIfPresent(String.self, forKey: .status)
                description = try? container.decodeIfPresent(String.self, forKey: .description)
                command = try? container.decodeIfPresent(String.self, forKey: .command)
            }

            enum CodingKeys: String, CodingKey {
                case type, status, description, command
            }
        }

        /// Only the event's name must decode. Any other field that changed shape reads as missing, so one odd field
        /// cannot drop a whole event.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = try container.decode(String.self, forKey: .event)
            sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
            agentID = try? container.decodeIfPresent(String.self, forKey: .agentID)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
            notificationType = try? container.decodeIfPresent(String.self, forKey: .notificationType)
            lastAssistantMessage = try? container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
            backgroundTasks = (try? container.decodeIfPresent([Lossy<BackgroundTask>].self, forKey: .backgroundTasks))?
                .compactMap(\.value)
        }

        /// One element of a list that reads as nil when it has the wrong shape, so it cannot drop the others.
        struct Lossy<Value: Decodable>: Decodable {
            var value: Value?

            init(from decoder: any Decoder) throws {
                value = try? Value(from: decoder)
            }
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
    /// A relayed hook is dated by `CANOPY_STARTED_AT`, when it ran on the host, since this process started later.
    public static func request(input: Data, environment: [String: String], startedAt: Date?) -> AgentHookRequest? {
        guard let pane = environment["CANOPY_PANE"], !pane.isEmpty,
            let home = environment[CanopyHome.environmentKey], !home.isEmpty,
            let report = ClaudeHookMapping.report(
                from: input, startedAt: relayedStart(in: environment) ?? startedAt),
            let params = try? JSONValue.from(TermStateParams(pane: pane, report))
        else { return nil }
        return AgentHookRequest(
            socketPath: CanopyHome(path: home).socketPath,
            request: ControlRequest(method: TermMethod.state, params: params))
    }

    static func relayedStart(in environment: [String: String]) -> Date? {
        guard let seconds = environment["CANOPY_STARTED_AT"].flatMap(Double.init), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
