import CanopyWire
import Foundation

/// The one line a phone shows for an agent, the same on the Mac and on a box.
public enum AgentLine {
    /// What the agent waits on, or else its conversation's last entry.
    public static func line(
        prompt: OpenPrompt?, state: AgentState, backgroundTasks: [String], tail: TranscriptEntry?
    ) -> String? {
        if let prompt {
            switch prompt.kind {
            case .permission where prompt.tool == "Bash":
                return "Wants to run \(short(prompt.detail ?? "a command"))"
            case .permission:
                return "Wants to use \(prompt.tool ?? "a tool")" + (prompt.detail.map { ": \(short($0))" } ?? "")
            case .question:
                return "Asks: \(short(prompt.questions?.first?.question ?? "a question"))"
            case .plan:
                return "Has a plan ready"
            case .reply:
                return "Asks: \(short(prompt.detail ?? "a question"))"
            }
        }
        if state == .background, !backgroundTasks.isEmpty {
            return "Waiting on \(backgroundTasks.joined(separator: ", ")) in the background"
        }
        guard let tail else { return nil }
        switch tail.kind {
        case .text:
            return tail.text.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
                .map { short(String($0)) }
        case .prompt:
            return "You: " + short(tail.text)
        case .question:
            return "Asked: \(short(tail.text))"
        case .plan:
            return "Made a plan"
        case .tools, .notice:
            return tail.text
        }
    }

    /// A line cut to the length a phone shows.
    public static func short(_ text: String) -> String {
        TranscriptParser.ToolKind.short(text)
    }
}
