import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyCore

/// The phone's replies and answers to a chat, which go through its session, not keys.
@MainActor
struct ChatPhoneTests {
    let dir: TempDir
    let terminals: TerminalStore
    let panes: PhonePanes
    let context: PaneContext

    init() throws {
        dir = try TempDir()
        terminals = Fixture.terminals(dir)
        panes = PhonePanes(terminals: terminals)
        context = Fixture.context(dir.path)
        let home = Fixture.shellSettings(dir).baseEnvironment["HOME"]!
        let folder = dir.path
        terminals.chatLauncher = { _, _, model, mode, resume in
            var launch = FakeClaude.launch(home: home, folder: folder)
            launch.arguments =
                ["python3", "-I", FakeClaude.script]
                + ClaudeLaunch.arguments(model: model, mode: mode, resume: resume)
            return launch
        }
        terminals.chatTrust = { _ in ChatTrust(isTrusted: { true }, grant: {}) }
    }

    func texts(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .text(let text) = $0.content { text.markdown } else { nil } }
    }

    /// As its PermissionRequest hook would report it.
    func reportPrompt(_ pane: Pane, _ prompt: AgentPrompt) throws -> OpenPrompt {
        pane.report(AgentReport(state: .waiting, session: "s1", event: "PermissionRequest", prompt: prompt))
        return try #require(pane.agent.prompt)
    }

    @Test func phoneReplyToAChatWithAnOpenPromptSendsIt() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)
        chat.send("run make deploy")
        #expect(await eventually { chat.permission != nil })

        try await panes.reply(PhoneReplyParams(pane: pane.id.description, text: "say from the phone"))

        #expect(chat.permission == nil)
        #expect(await eventually { !chat.isWorking && texts(chat).last == "from the phone" })
    }

    @Test func phoneAnswerToAChatAllowsItsPermission() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)
        chat.send("run make deploy")
        #expect(await eventually { chat.permission != nil })
        let prompt = try reportPrompt(pane, AgentPrompt(kind: .permission, tool: "Bash", detail: "make deploy"))

        try await panes.answer(
            PhoneAnswerParams(pane: pane.id.description, prompt: prompt.id, answer: PhoneAnswer(allow: true)))

        #expect(await eventually { !chat.isWorking && texts(chat).last == "It ran." })
        await #expect(throws: PhonePanes.promptGone) {
            try await panes.answer(
                PhoneAnswerParams(pane: pane.id.description, prompt: prompt.id, answer: PhoneAnswer(allow: true)))
        }
    }

    @Test func phoneAnswerToAChatAnswersItsQuestion() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)
        chat.send("ask")
        #expect(await eventually { chat.permission != nil })
        let questions = [
            PromptQuestion(
                question: "Which color?", options: [.init(label: "Blue (Recommended)"), .init(label: "Red")])
        ]
        let prompt = try reportPrompt(pane, AgentPrompt(kind: .question, questions: questions))

        // An answer that does not fit the question is refused, as for a terminal.
        await #expect(throws: ControlError.self) {
            try await panes.answer(
                PhoneAnswerParams(pane: pane.id.description, prompt: prompt.id, answer: PhoneAnswer(options: [[5]])))
        }
        try await panes.answer(
            PhoneAnswerParams(pane: pane.id.description, prompt: prompt.id, answer: PhoneAnswer(options: [[1]])))

        #expect(await eventually { !chat.isWorking })
        let answers = chat.items.compactMap {
            if case .question(let question) = $0.content { question.answer } else { nil }
        }
        #expect(answers == ["Red"])
    }

    @Test func phoneScreenOfAChatIsNotATerminal() throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }

        #expect(throws: WorkspaceError.notATerminal(pane.id.description)) {
            try panes.screen(PhonePaneParams(pane: pane.id.description), scrollback: nil)
        }
        #expect(throws: WorkspaceError.notATerminal(pane.id.description)) {
            try panes.keys(PhoneKeysParams(pane: pane.id.description, text: "\r"))
        }
    }

    @Test func anAgentWithoutKindDecodesAsATerminal() throws {
        let old = Data(#"{"pane":"p1","state":"working","since":1}"#.utf8)
        let newer = Data(#"{"pane":"p1","state":"working","since":1,"kind":"hologram"}"#.utf8)
        let chat = try JSONEncoder().encode(PhoneAgent(pane: "p2", state: .done, since: 1, kind: .chat))

        #expect(try JSONDecoder().decode(PhoneAgent.self, from: old).kind == .terminal)
        #expect(try JSONDecoder().decode(PhoneAgent.self, from: newer).kind == .terminal)
        #expect(try JSONDecoder().decode(PhoneAgent.self, from: chat).kind == .chat)
    }
}
