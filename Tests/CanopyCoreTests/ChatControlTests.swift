import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// `canopy chat new` and the `term` commands on a chat, against the stand-in Claude.
@MainActor
struct ChatControlTests {
    let dir: TempDir
    let terminals: TerminalStore
    let rows: RowLifecycle
    let context: PaneContext

    init() throws {
        dir = try TempDir()
        terminals = Fixture.terminals(dir)
        rows = RowLifecycle(
            workspace: Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git), terminals: terminals)
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

    func chat(_ result: ChatNewResult) throws -> ChatSession {
        try #require(PaneID(result.pane).flatMap { terminals.pane($0) }?.chat)
    }

    func read(_ pane: String, lines: Int? = nil) throws -> String {
        try rows.readTerminal(TermReadParams(pane: pane, lines: lines)).text
    }

    @Test func chatNewOpensAChatWithItsModelModeAndPrompt() async throws {
        terminals.openTab(for: context)
        defer { terminals.closeAll() }
        let defaults = terminals.chatDefaults

        let result = try rows.newChat(context, ChatNewParams(prompt: "say hello there", model: "haiku", mode: "plan"))

        let chat = try chat(result)
        #expect(chat.model == "haiku")
        #expect(chat.mode == "plan")
        #expect(result.tab == "say hello there")
        #expect(await eventually { !chat.isWorking && chat.items.count == 2 })
        #expect(try read(result.pane) == "You: say hello there\nhello there")
        // A mode or model an agent asks for is the chat's own, not the next one's.
        #expect(terminals.chatDefaults == defaults)
    }

    @Test func chatNewRefusesAnUnknownModeAndASessionThatIsOpen() throws {
        defer { terminals.closeAll() }
        #expect(throws: ControlError.self) { try rows.newChat(context, ChatNewParams(mode: "yolo")) }

        let (_, pane) = terminals.openChat(for: context, session: "s-1")
        #expect(pane.chat?.sessionID == "s-1")
        #expect(throws: ControlError.self) { try rows.newChat(context, ChatNewParams(resume: "s-1")) }
    }

    @Test func termSendWithoutEnterFillsTheDraft() async throws {
        defer { terminals.closeAll() }
        let result = try rows.newChat(context, ChatNewParams())
        let chat = try chat(result)

        try await rows.sendToTerminal(TermSendParams(pane: result.pane, text: "say draft"))
        #expect(chat.draft == "say draft")
        #expect(!chat.isRunning)

        try await rows.sendToTerminal(TermSendParams(pane: result.pane, text: "ed"))
        #expect(chat.draft == "say drafted")
        // Enter with no text sends what the sends before put in the composer.
        try await rows.sendToTerminal(TermSendParams(pane: result.pane, text: "", enter: true))
        #expect(chat.draft.isEmpty)
        #expect(await eventually { !chat.isWorking && chat.items.count == 2 })
        #expect(try read(result.pane, lines: 1) == "drafted")

        // Text sent with Enter goes alone, and leaves what the author is writing.
        chat.draft = "half a thought"
        try await rows.sendToTerminal(TermSendParams(pane: result.pane, text: "say alone", enter: true))
        #expect(chat.draft == "half a thought")
        #expect(await eventually { !chat.isWorking && (try? read(result.pane, lines: 1)) == "alone" })
    }

    @Test func termSendToAChatDeniesAnOpenPromptAndSends() async throws {
        defer { terminals.closeAll() }
        let result = try rows.newChat(context, ChatNewParams(prompt: "run make deploy"))
        let chat = try chat(result)
        #expect(await eventually { chat.permission != nil })
        #expect(try read(result.pane).hasSuffix("Waiting for you: allow make deploy?"))

        try await rows.sendToTerminal(TermSendParams(pane: result.pane, text: "say do this instead", enter: true))

        #expect(chat.permission == nil)
        #expect(await eventually { !chat.isWorking && (try? read(result.pane, lines: 1)) == "do this instead" })
    }

    @Test func chatNewLeavesTheSelectedTab() throws {
        defer { terminals.closeAll() }
        let (tab, _) = terminals.openTab(for: context)

        _ = try rows.newChat(context, ChatNewParams())

        #expect(terminals.selectedTab(inRow: dir.path)?.id == tab.id)
    }

    @Test func chatNewOfAConversationThatIsGoneFails() throws {
        defer { terminals.closeAll() }

        #expect(throws: ControlError.self) { try rows.newChat(context, ChatNewParams(resume: "no-such-session")) }
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
    }

    @Test func termSendBeforeTrustSaysTheMessageWaits() async throws {
        terminals.chatTrust = { _ in ChatTrust(isTrusted: { false }, grant: {}) }
        defer { terminals.closeAll() }
        let result = try rows.newChat(context, ChatNewParams())

        await #expect(throws: ControlError.self) {
            try await rows.sendToTerminal(TermSendParams(pane: result.pane, text: "say later", enter: true))
        }
        #expect(try chat(result).draft == "say later")
        #expect(try read(result.pane).hasSuffix("trust this folder for Claude Code, then it sends: say later"))
    }

    @Test func termReadSaysWhenClaudeCodeStopped() async throws {
        defer { terminals.closeAll() }
        let result = try rows.newChat(context, ChatNewParams(prompt: "crash"))
        let chat = try chat(result)

        #expect(await eventually { chat.failure != nil })
        #expect(try read(result.pane, lines: 1) == "Stopped: Claude Code exited with code 1: boom: something broke")
    }

    @Test func termListShowsTheKind() throws {
        defer { terminals.closeAll() }
        terminals.openTab(for: context)
        _ = try rows.newChat(context, ChatNewParams())

        let panes = rows.terminalInfo(rowPath: dir.path, repoNames: [:])

        #expect(panes.map(\.kind) == ["terminal", "chat"])
        #expect(panes.last?.foreground == nil)
    }

    @Test func closingAWorkingChatNamesClaude() async throws {
        defer { terminals.closeAll() }
        let result = try rows.newChat(context, ChatNewParams(prompt: "pause"))
        let chat = try chat(result)
        #expect(await eventually { chat.turnTokens > 0 })

        #expect(throws: WorkspaceError.paneBusy(result.pane, program: "Claude")) {
            try rows.closeTerminal(TermCloseParams(pane: result.pane))
        }
        chat.interrupt()
    }
}
