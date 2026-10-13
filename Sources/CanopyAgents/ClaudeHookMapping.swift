import CanopyWire
import Foundation

/// Turns what a Claude Code hook receives on stdin into a report of the agent's state.
public enum ClaudeHookMapping {
    /// The report for a hook's input, or nil for an event that says nothing about the pane.
    /// `startedAt` is when the hook process started, which orders reports that arrive out of order.
    public static func report(from input: Data, startedAt: Date?) -> AgentReport? {
        guard let hook = try? JSONDecoder().decode(HookInput.self, from: input) else { return nil }
        func report(
            _ state: AgentState?, question: Bool = false, takesOver: Bool = false, releases: Bool = false,
            backgroundTasks: [String] = [], prompt: AgentPrompt? = nil
        ) -> AgentReport {
            AgentReport(
                state: state, session: hook.sessionID, event: hook.event, at: startedAt, question: question,
                takesOver: takesOver, releases: releases, backgroundTasks: backgroundTasks,
                transcriptPath: hook.transcriptPath, prompt: prompt)
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
            return ["AskUserQuestion", "ExitPlanMode"].contains(hook.toolName)
                ? report(.waiting, prompt: prompt(for: hook)) : nil
        case "PermissionRequest":
            return fromMainAgent ? report(.waiting, prompt: prompt(for: hook)) : nil
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
                return report(
                    .waiting, question: true, prompt: AgentPrompt(kind: .reply, detail: lastParagraph(message)))
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

    /// The open prompt a tool call waiting on the author makes.
    static func prompt(for hook: HookInput) -> AgentPrompt? {
        guard let tool = hook.toolName else { return nil }
        let input = hook.toolInput ?? [:]
        func text(_ key: String) -> String? {
            if case .string(let value)? = input[key], !value.isEmpty { value } else { nil }
        }
        switch tool {
        case "AskUserQuestion":
            // A picker read only in part would take answers meant for another question, so it cannot be answered.
            let questions = TranscriptParser.Builder.questions(input)
            let complete =
                questions.count
                == input["questions"].map { value -> Int in
                    if case .array(let items) = value { items.count } else { -1 }
                }
            return AgentPrompt(kind: .question, questions: complete ? questions : nil)
        case "ExitPlanMode":
            return AgentPrompt(kind: .plan, tool: tool, detail: text("plan"))
        default:
            if tool.hasPrefix("mcp__") {
                return AgentPrompt(
                    kind: .permission, tool: tool, detail: String(tool.split(separator: "__").last ?? ""))
            }
            let detail =
                text("command") ?? text("file_path") ?? text("notebook_path") ?? text("url") ?? text("query")
                ?? text("pattern") ?? text("description")
            return AgentPrompt(kind: .permission, tool: tool, detail: detail)
        }
    }

    /// The message's last paragraph, which holds the question it ended on.
    static func lastParagraph(_ message: String) -> String {
        let paragraphs = message.components(separatedBy: "\n\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return paragraphs.last { !$0.isEmpty } ?? message
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
        var transcriptPath: String?
        var toolInput: [String: JSONValue]?

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
            transcriptPath = try? container.decodeIfPresent(String.self, forKey: .transcriptPath)
            toolInput = try? container.decodeIfPresent([String: JSONValue].self, forKey: .toolInput)
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
            case transcriptPath = "transcript_path"
            case toolInput = "tool_input"
        }
    }
}
