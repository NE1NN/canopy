import Foundation
import Testing

@testable import CanopyCore

/// The keys follow Claude Code 2.1.296's dialogs, checked by hand in a terminal: a digit picks an option, a picker with
/// several questions or a multiple choice ends on a review where 1 submits, Return takes a permission or plan's first
/// option, and Escape turns it down.
struct PhoneAnswerKeysTests {
    let down = "\u{1b}[B"

    func question(_ options: Int, multiSelect: Bool = false) -> PromptQuestion {
        PromptQuestion(
            question: "Q?", options: (1...options).map { PromptQuestion.Option(label: "o\($0)") },
            multiSelect: multiSelect)
    }

    func prompt(_ questions: [PromptQuestion]) -> OpenPrompt {
        OpenPrompt(id: "q", kind: .question, questions: questions)
    }

    @Test func oneQuestionIsItsDigit() throws {
        #expect(try PhoneAnswerKeys.keys(for: prompt([question(2)]), PhoneAnswer(options: [[1]])) == ["2"])
    }

    @Test func severalQuestionsEndOnTheReview() throws {
        let keys = try PhoneAnswerKeys.keys(for: prompt([question(2), question(3)]), PhoneAnswer(options: [[1], [0]]))
        #expect(keys == ["2", "1", "1"])
    }

    @Test func aMultipleChoiceTogglesThenSubmits() throws {
        let keys = try PhoneAnswerKeys.keys(
            for: prompt([question(3, multiSelect: true)]), PhoneAnswer(options: [[0, 2]]))
        #expect(keys == ["1", "3", down, down, down, down, "\r", "1"])
    }

    @Test func permissionsAndPlansAreReturnOrEscape() throws {
        for kind in [OpenPrompt.Kind.permission, .plan] {
            let open = OpenPrompt(id: "p", kind: kind, tool: "Bash")
            #expect(try PhoneAnswerKeys.keys(for: open, PhoneAnswer(allow: true)) == ["\r"])
            #expect(try PhoneAnswerKeys.keys(for: open, PhoneAnswer(allow: false)) == ["\u{1b}"])
        }
    }

    @Test(arguments: [
        PhoneAnswer(options: [[2]]),
        PhoneAnswer(options: [[-1]]),
        PhoneAnswer(options: [[0, 1]]),
        PhoneAnswer(options: [[]]),
        PhoneAnswer(options: [[0], [1]]),
        PhoneAnswer(allow: true),
        PhoneAnswer(),
    ])
    func answersThatDoNotFitTheQuestionAreRefused(_ answer: PhoneAnswer) {
        #expect(throws: ControlError.self) { try PhoneAnswerKeys.keys(for: prompt([question(2)]), answer) }
    }

    @Test func aPermissionNeedsAllowOrDeny() {
        let open = OpenPrompt(id: "p", kind: .permission, tool: "Bash")
        #expect(throws: ControlError.self) { try PhoneAnswerKeys.keys(for: open, PhoneAnswer(options: [[0]])) }
    }

    @Test func aReplyPromptTakesAReply() {
        let open = OpenPrompt(id: "r", kind: .reply, detail: "Should I?")
        #expect(throws: ControlError.self) { try PhoneAnswerKeys.keys(for: open, PhoneAnswer(allow: true)) }
    }
}
