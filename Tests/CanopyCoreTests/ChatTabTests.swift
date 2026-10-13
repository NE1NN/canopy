import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct ChatTabTests {
    let dir: TempDir
    let terminals: TerminalStore
    let context: PaneContext

    init() throws {
        dir = try TempDir()
        terminals = Fixture.terminals(dir)
        context = Fixture.context(dir.path)
        let home = Fixture.shellSettings(dir).baseEnvironment["HOME"]!
        let folder = dir.path
        // The stand-in Claude, trusted, so no test reaches the real one or the author's ~/.claude.json.
        terminals.chatLauncher = { _, _, model, mode, resume in
            var launch = FakeClaude.launch(home: home, folder: folder)
            launch.arguments =
                ["python3", "-I", FakeClaude.script]
                + ClaudeLaunch.arguments(model: model, mode: mode, resume: resume)
            return launch
        }
        terminals.chatTrust = { _ in ChatTrust(isTrusted: { true }, grant: {}) }
    }

    @Test func opensAChatTabThatStartsNothingUntilUsed() throws {
        terminals.openTab(for: context)

        let (tab, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }

        #expect(terminals.selectedTab(inRow: dir.path)?.id == tab.id)
        #expect(tab.chat === pane)
        #expect(tab.grid == nil)
        #expect(tab.paneList.map(\.id) == [pane.id])
        #expect(tab.name == "Chat")
        #expect(pane.chat != nil)
        #expect(pane.terminal == nil)
        #expect(pane.pid == nil)
        #expect(!pane.isBusy)
        #expect(terminals.pane(pane.id) === pane)
        #expect(terminals.tab(containing: pane.id)?.1.id == tab.id)
    }

    @Test func theTabIsNamedAfterTheConversation() async throws {
        let (tab, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)

        chat.send("say hi")
        #expect(await eventually { !chat.isWorking })

        #expect(tab.name == "say hi")
        #expect(pane.title == "say hi")
        #expect(pane.foreground?.name == "claude")
        terminals.renameTab(tab.id, inRow: dir.path, to: "Greeting")
        #expect(chat.title == "Greeting")
        #expect(tab.name == "Greeting")
    }

    @Test func closingTheTabEndsClaude() async throws {
        let (tab, pane) = terminals.openChat(for: context)
        let chat = try #require(pane.chat)
        chat.send("say hi")
        #expect(await eventually { !chat.isWorking })
        let pid = try #require(pane.pid)

        terminals.closeTab(tab.id, inRow: dir.path)

        #expect(!chat.isRunning)
        #expect(pane.status == .exited(Pane.closedExitCode))
        #expect(await eventually { kill(pid, 0) != 0 })
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
    }

    @Test func closingTheChatPaneClosesItsTab() {
        terminals.openTab(for: context)
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }

        terminals.closePane(pane.id)

        #expect(terminals.tabs(inRow: dir.path).count == 1)
        #expect(terminals.pane(pane.id) == nil)
    }

    @Test func savesAndRestoresTheConversation() async throws {
        let (_, pane) = terminals.openChat(for: context)
        let chat = try #require(pane.chat)
        chat.send("say remembered")
        #expect(await eventually { !chat.isWorking })
        let session = try #require(chat.sessionID)

        let saved = try #require(terminals.saved()[dir.path])
        terminals.closeAll()

        #expect(
            saved.tabs.map(\.chat) == [
                SavedChat(session: session, model: "claude-sonnet-5-5", mode: "default", title: "say remembered")
            ])
        let restored = Fixture.terminals(dir)
        restored.chatLauncher = terminals.chatLauncher
        restored.chatTrust = terminals.chatTrust
        defer { restored.closeAll() }
        restored.restore(saved, for: context)
        let tab = try #require(restored.tabs(inRow: dir.path).first)
        let restoredChat = try #require(tab.chat?.chat)
        restoredChat.open()
        #expect(tab.name == "say remembered")
        #expect(restoredChat.sessionID == session)
        #expect(restoredChat.model == "claude-sonnet-5-5")
        #expect(!restoredChat.isRunning)
        #expect(restoredChat.items.contains { $0.plainText == "remembered" })
    }

    @Test func openInTerminalPutsATerminalResumingTheSessionInTheChatsPlace() async throws {
        // `echo` stands in for claude, so the terminal prints what it would run instead of starting Claude Code.
        var settings = Fixture.shellSettings(dir)
        settings.baseEnvironment["CANOPY_CLAUDE"] = "echo"
        let store = TerminalStore(engine: FakeEngine(), settings: settings)
        store.chatLauncher = terminals.chatLauncher
        store.chatTrust = terminals.chatTrust
        store.openTab(for: context)
        let (tab, pane) = store.openChat(for: context)
        defer { store.closeAll() }
        let chat = try #require(pane.chat)
        chat.send("say moving")
        #expect(await eventually { !chat.isWorking })
        let session = try #require(chat.sessionID)
        #expect(store.pane(holdingSession: session) === pane)

        chat.draft = "not sent yet"

        let terminal = try #require(await store.openInTerminal(pane))

        #expect(!chat.isRunning)
        let tabs = store.tabs(inRow: dir.path)
        #expect(tabs.count == 2)
        #expect(tabs[1].grid?.paneList.first === terminal)
        #expect(tabs[1].name == tab.name)
        #expect(store.selectedTab(inRow: dir.path)?.id == tabs[1].id)
        #expect(await eventually { terminal.screen.text.contains("--resume \(session)") })
        #expect(await eventually { terminal.screen.text.contains("not sent yet") })
        // Before its Claude Code reports in, the terminal already holds the session, so a chat cannot take it too.
        #expect(store.pane(holdingSession: session) === terminal)
        let (_, again) = store.openChat(for: context, session: session, title: "again")
        let second = try #require(again.chat)
        second.send("say twice")
        #expect(second.failure == .heldElsewhere(pane: terminal.id.description))
        #expect(!second.isRunning)
        #expect(second.draft == "say twice")
        second.showHolder()
        #expect(store.selectedTab(inRow: dir.path)?.id == tabs[1].id)
    }

    @Test func aRepublishReloadsThePanelInsteadOfOpeningAnother() async throws {
        var reloads: [WebPageID] = []
        terminals.onReloadPage = { reloads.append($0) }
        terminals.openTab(for: context)
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)

        chat.send("artifact Board")
        #expect(await eventually { !chat.isWorking })

        let page = try #require(terminals.panelsByRow[dir.path]?.page)
        #expect(page.url.absoluteString == "https://claude.ai/artifact/FakeBoard")
        #expect(reloads.isEmpty)
        let wish = try #require(terminals.takeThumbnailWish(for: page.id, at: page.url))
        #expect(wish.key == "fake-board-v1")
        #expect(wish.pane == pane.id)

        chat.send("artifact Board")
        #expect(await eventually { !chat.isWorking && reloads.count == 1 })

        #expect(terminals.panelsByRow[dir.path]?.page === page)
        #expect(reloads == [page.id])
        #expect(terminals.pages(inRow: dir.path).count == 1)
        // A page that went to sign in instead keeps the wish for when it comes back.
        #expect(terminals.takeThumbnailWish(for: page.id, at: URL(string: "https://claude.ai/login")) == nil)
        let second = try #require(terminals.takeThumbnailWish(for: page.id, at: page.url))
        #expect(second.key == "fake-board-v2")

        let cardKey = { ChatRows.rows(for: chat).last { if case .artifact = $0 { true } else { false } }?.key }
        let before = cardKey()
        try terminals.saveThumbnail(Data([1]), for: second)
        #expect(chat.thumbnailsSaved == 1)
        #expect(cardKey() != before)
        let card = chat.items.compactMap { if case .artifact(let artifact) = $0.content { artifact } else { nil } }.last
        #expect(chat.thumbnail(for: try #require(card)) != nil)
    }

    @Test func aSavedChatTabRoundTripsThroughJSON() throws {
        let tab = SavedTab(name: "Plan", chat: SavedChat(session: "s-1", model: nil, mode: "plan", title: "Plan"))

        let decoded = try JSONDecoder().decode(SavedTab.self, from: JSONEncoder().encode(tab))

        #expect(decoded == tab)
        #expect(decoded.layout == nil)
        #expect(decoded.web == nil)
    }

    @Test func claudeGetsWhatATerminalsAgentGets() throws {
        let settings = Fixture.shellSettings(dir)

        let launch = ClaudeLaunch.terminalLaunch(
            settings: settings, context: context, pane: PaneID(7), model: "opus", mode: "default", resume: "s-1")

        #expect(launch.environment["CANOPY_PANE"] == "p7")
        #expect(launch.environment["CANOPY_ROW_PATH"] == dir.path)
        #expect(launch.directory == dir.path)
        #expect(launch.arguments.first == "bash")
        #expect(launch.arguments.dropFirst().prefix(3) == ["-i", "-l", "-c"])
        #expect(launch.arguments.last?.hasPrefix("exec claude '-p' ") == true)
        #expect(
            launch.arguments.last?.hasSuffix("'--model' 'opus' '--permission-mode' 'default' '--resume' 's-1'") == true)
    }

    @Test func trustFollowsTheRowsRepo() {
        #expect(TerminalStore.trustPlace(for: context) == .row(path: dir.path, repo: "/r/demo"))
        let plugin = PaneContext(
            pluginRow: PluginRow(plugin: "tickets", item: "0811", title: "Paul", path: "/h/t/0811"))
        #expect(TerminalStore.trustPlace(for: plugin) == .folder("/h/t/0811"))
    }

    @Test func termAndThePhoneRefuseWhatOnlyTerminalsHave() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let phone = PhonePanes(terminals: terminals)
        let id = pane.id.description

        #expect(throws: WorkspaceError.notATerminal(id)) {
            try phone.screen(PhonePaneParams(pane: id), scrollback: nil)
        }
        #expect(throws: WorkspaceError.notATerminal(id)) { try phone.keys(PhoneKeysParams(pane: id, text: "x")) }
        await #expect(throws: WorkspaceError.notATerminal(id)) {
            try await phone.reply(PhoneReplyParams(pane: id, text: "hi"))
        }
    }

    /// The author's actions stand for the keys they replace, so the agent's state follows as it does for a terminal.
    @Test func theAgentStateFollowsTheAuthorsActions() async throws {
        let (_, pane) = terminals.openChat(for: context)
        defer { terminals.closeAll() }
        let chat = try #require(pane.chat)

        chat.send("run make deploy")
        #expect(await eventually { chat.permission != nil })
        pane.report(AgentReport(state: .waiting, session: chat.sessionID, event: "PermissionRequest"))
        #expect(pane.agent.state == .waiting)
        chat.allow()
        #expect(pane.agent.state == .working)

        #expect(await eventually { !chat.isWorking })
        chat.close()
        #expect(await eventually { pane.agent.state == .none })
    }
}
