import Foundation

extension ChatSession {
    /// The conversation as plain text, oldest first, for `canopy term read`: the author's messages, Claude's text,
    /// one line per tool group, and what waits on the author.
    public var readableText: String {
        var lines: [String] = []
        for item in items {
            switch item.content {
            case .prompt(let prompt):
                let images = prompt.images == 0 ? "" : " [\(prompt.images) image\(prompt.images == 1 ? "" : "s")]"
                lines.append("You: " + prompt.text + images)
            case .text(let text):
                lines.append(text.markdown)
            case .tools(let group):
                lines.append("• " + group.summary + (group.failed ? " (failed)" : ""))
            case .edit(let call):
                lines.append("• " + ChatToolGroup(calls: [call]).summary)
            case .question(let question):
                let asked = question.questions.map(\.question).joined(separator: " ")
                lines.append("• Asked: " + asked + (question.answer.map { " → " + $0 } ?? ""))
            case .plan(let plan):
                lines.append("• Proposed a plan" + (plan.answer.map { " → " + $0 } ?? ""))
            case .notice(let notice):
                lines.append("• " + notice)
            case .shell(let shell):
                lines.append("$ " + shell.command + (shell.output.isEmpty ? "" : "\n" + shell.output))
            case .artifact(let artifact):
                let version = artifact.version.map { " (version \($0))" } ?? ""
                lines.append(
                    "• Published " + artifact.title + version + (artifact.url.map { ": " + $0.absoluteString } ?? ""))
            }
        }
        if let streaming, !streaming.text.isEmpty { lines.append(streaming.text) }
        lines += queued.map { "You (queued): " + $0.prompt.text }
        if let permission {
            switch permission.kind {
            case .permission: lines.append("Waiting for you: allow \(permission.subject)?")
            case .question(let questions):
                for question in questions {
                    let options = question.options.enumerated().map { "\($0.offset + 1). \($0.element.label)" }
                    lines.append("Waiting for you: " + question.question + " " + options.joined(separator: "  "))
                }
            case .plan: lines.append("Waiting for you: approve the plan?")
            }
        }
        return lines.joined(separator: "\n")
    }
}
