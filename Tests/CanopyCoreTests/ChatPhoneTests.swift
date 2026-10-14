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
        let prompt = try #require(chat.openPrompt)
        #expect(prompt.detail == "make deploy")

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
        let prompt = try #require(chat.openPrompt)
        #expect(prompt.questions?.first?.question == "Which color?")

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

    /// Parallel subagents can ask twice at once. The phone answers the one it showed, and only while it is the front one.
    @Test func phoneAnswerReachesOnlyThePromptItShowed() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)
        chat.send("two")
        #expect(await eventually { chat.pendingPermissions.count == 2 })
        let first = try #require(chat.openPrompt)
        let second = chat.pendingPermissions[1].id
        // The hook may have reported the second, which the phone must not use to answer the first.
        pane.report(
            AgentReport(
                state: .waiting, session: "s1", event: "PermissionRequest",
                prompt: AgentPrompt(kind: .permission, tool: "Bash", detail: "second")))

        await #expect(throws: PhonePanes.promptGone) {
            try await panes.answer(
                PhoneAnswerParams(pane: pane.id.description, prompt: second, answer: PhoneAnswer(allow: true)))
        }
        #expect(chat.pendingPermissions.count == 2)
        try await panes.answer(
            PhoneAnswerParams(pane: pane.id.description, prompt: first.id, answer: PhoneAnswer(allow: true)))

        #expect(chat.pendingPermissions.map(\.id) == [second])
        #expect(chat.openPrompt?.id == second)
        chat.interrupt()
    }

    @Test func phoneReplyWhileAQuestionIsOpenTurnsItDownAndSends() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)
        chat.send("ask")
        #expect(await eventually { chat.permission != nil })

        try await panes.reply(PhoneReplyParams(pane: pane.id.description, text: "say never mind"))

        #expect(chat.permission == nil)
        #expect(await eventually { !chat.isWorking && texts(chat).last == "never mind" })
        let answers = chat.items.compactMap {
            if case .question(let question) = $0.content { question.answer } else { nil }
        }
        #expect(answers == ["Declined"])
    }

    @Test func phoneReplyBeforeTrustSaysItWaits() async throws {
        terminals.chatTrust = { _ in ChatTrust(isTrusted: { false }, grant: {}) }
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }

        await #expect(throws: PhonePanes.chatWaits) {
            try await panes.reply(PhoneReplyParams(pane: pane.id.description, text: "!rm -rf build"))
        }
        // From the phone a leading ! is text, never a command run on the Mac.
        #expect(pane.chat?.shellRuns.isEmpty == true)
        #expect(pane.chat?.draft == "!rm -rf build")
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
