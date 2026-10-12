import Foundation

/// The keys the author would press to answer a prompt in Claude Code, one write each.
public enum PhoneAnswerKeys {
    static let down = "\u{1b}[B"

    public static func keys(for prompt: OpenPrompt, _ answer: PhoneAnswer) throws -> [String] {
        switch prompt.kind {
        case .permission, .plan:
            guard let allow = answer.allow, answer.options == nil else {
                throw refusal("Answer a \(prompt.kind.rawValue) prompt with allow true or false.")
            }
            return [allow ? "\r" : "\u{1b}"]
        case .question:
            let questions = prompt.questions ?? []
            guard answer.allow == nil, let chosen = answer.options, chosen.count == questions.count, !questions.isEmpty
            else { throw refusal("Answer each of the \(questions.count) questions with its options.") }
            var keys: [String] = []
            for (question, picked) in zip(questions, chosen) {
                guard !picked.isEmpty, Set(picked).count == picked.count,
                    picked.allSatisfy({ question.options.indices.contains($0) }),
                    question.multiSelect || picked.count == 1
                else { throw refusal("\"\(question.question)\" has no such choice.") }
                // Digits 1 to 9 pick options; AskUserQuestion offers at most four.
                keys += picked.map { String($0 + 1) }
                if question.multiSelect {
                    // Past the options and "Type something" to Submit.
                    keys += Array(repeating: down, count: question.options.count + 1) + ["\r"]
                }
            }
            if questions.count > 1 || questions.contains(where: \.multiSelect) {
                keys.append("1")
            }
            return keys
        case .reply:
            throw refusal("The agent asked in its message. Answer it with phone.reply.")
        }
    }

    private static func refusal(_ message: String) -> ControlError {
        ControlError(code: "bad_params", message: message)
    }
}
