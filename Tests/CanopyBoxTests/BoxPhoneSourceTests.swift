import CanopyAgents
import CanopyServer
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

/// canopy-box as a phone source.
struct BoxPhoneSourceTests {
    static let permission = AgentPrompt(kind: .permission, tool: "Bash", detail: "ls")

    func contents(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func theInboxAndRowsShowTheBoxsAgents() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/p"))
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: made.row.path))
        await daemon.report(pane: pane, AgentReport(state: .waiting, session: "s", prompt: Self.permission))
        let source = BoxPhoneSource(daemon: daemon)
        let inbox = await source.inbox()
        #expect(inbox.rows.flatMap(\.agents).filter { $0.state == .waiting }.map(\.pane) == [pane])
        let rows = await source.rows()
        #expect(rows.sections.map(\.name) == ["demo"])
        #expect(rows.sections.first?.main?.path == home.clone)
        #expect(rows.sections.first?.others.map(\.path) == [made.row.path])
    }

    /// A done agent's line is what it last said, as on the Mac, not the prompt its screen ends on.
    @Test func aDoneAgentsLineIsItsLastWords() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let transcript = home.dir.sub("t.jsonl")
        let said: [String: Any] = [
            "type": "assistant", "uuid": "u1", "timestamp": "2026-10-14T00:00:00.000Z", "sessionId": "s",
            "message": [
                "role": "assistant", "content": [["type": "text", "text": "Migrated.\n\nREADY: totals match"]],
            ],
        ]
        try (JSONSerialization.data(withJSONObject: said) + Data("\n".utf8)).write(to: URL(fileURLWithPath: transcript))
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s", transcriptPath: transcript))
        let source = BoxPhoneSource(daemon: daemon)

        let agent = await source.inbox().rows.flatMap(\.agents).first

        #expect(agent?.lastLine == "READY: totals match")
    }

    @Test func aTranscriptIsThePanesFile() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let source = BoxPhoneSource(daemon: daemon)
        await #expect(throws: BoxPhoneSource.noTranscript) { try await source.transcriptURL(pane) }
        await daemon.report(pane: pane, AgentReport(state: .working, session: "s", transcriptPath: "/t.jsonl"))
        #expect(try await source.transcriptURL(pane).path == "/t.jsonl")
    }

    @Test func aReplyGoesInAsAPasteThenReturn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let out = home.dir.sub("reply.txt")
        try await daemon.send(pane: pane, text: "cat > \(out)", enter: true)
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        let source = BoxPhoneSource(daemon: daemon)
        try await source.reply(PhoneReplyParams(pane: pane, text: "first line\nsecond"), delivered: {})
        try await daemon.keys(BoxKeysParams(pane: pane, keys: ["\u{04}"]))
        #expect(await eventually { contents(out) == "first line\nsecond\n" })
    }

    @Test func aReplyIsRefusedWhileADialogShowsOrNoAgentRuns() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let source = BoxPhoneSource(daemon: daemon)
        await #expect(throws: BoxPhoneSource.agentNotRunning) {
            try await source.reply(PhoneReplyParams(pane: pane, text: "x"), delivered: {})
        }
        await daemon.report(pane: pane, AgentReport(state: .waiting, session: "s", prompt: Self.permission))
        await #expect(throws: BoxPhoneSource.promptOpen) {
            try await source.reply(PhoneReplyParams(pane: pane, text: "x"), delivered: {})
        }
    }

    @Test func anAnswerTypesItsKeysAndASecondIsPromptGone() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let out = home.dir.sub("answer.bin")
        try await daemon.send(pane: pane, text: "stty raw -echo; touch \(out).ready; head -c 1 > \(out)", enter: true)
        #expect(await eventually { FileManager.default.fileExists(atPath: out + ".ready") })
        await daemon.report(pane: pane, AgentReport(state: .waiting, session: "s", prompt: Self.permission))
        let prompt = try #require(await daemon.agent(of: pane)?.prompt)
        let source = BoxPhoneSource(daemon: daemon)
        let answer = PhoneAnswerParams(pane: pane, prompt: prompt.id, answer: PhoneAnswer(allow: true))
        try await source.answer(answer)
        #expect(await eventually { FileManager.default.contents(atPath: out) == Data([0x0D]) })
        await #expect(throws: BoxPhoneSource.promptGone) { try await source.answer(answer) }
    }

    /// An answer whose keys never reached the pane leaves the prompt open, so it can be answered again.
    @Test func anAnswerThatFailsToTypeKeepsThePrompt() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .waiting, session: "s", prompt: Self.permission))
        let prompt = try #require(await daemon.agent(of: pane)?.prompt)
        await daemon.tmux.killSession(pane)
        let source = BoxPhoneSource(daemon: daemon)

        let answer = PhoneAnswerParams(pane: pane, prompt: prompt.id, answer: PhoneAnswer(allow: true))
        await #expect(throws: (any Error).self) { try await source.answer(answer) }

        #expect(await daemon.agent(of: pane)?.prompt?.id == prompt.id)
    }

    @Test func theScreenHasColoursAndScrollback() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        try await daemon.send(pane: pane, text: "seq 1 60; printf '\\033[31mred\\033[0m\\n'", enter: true)
        let source = BoxPhoneSource(daemon: daemon)
        #expect(
            await eventually {
                let screen = try? await source.screen(PhonePaneParams(pane: pane), scrollback: 20)
                return screen?.lines.contains { $0.contains("\u{1b}[31m") && $0.contains("red") } == true
                    && (screen?.scrollback?.isEmpty == false)
            })
    }

    @Test func aReplyWaitsOutADialog() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        let source = BoxPhoneSource(daemon: daemon)
        let replying = Task { try await source.reply(PhoneReplyParams(pane: pane, text: "go on"), delivered: {}) }
        // A dialog opens during the pause before Return, which must not answer it.
        try await Task.sleep(for: .milliseconds(50))
        await daemon.report(pane: pane, AgentReport(state: .waiting, session: "s", prompt: Self.permission))
        await #expect(throws: BoxPhoneSource.promptOpen) { try await replying.value }
    }

    @Test func aMostlyEmptyScreenKeepsItsRows() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        try await daemon.send(pane: pane, text: "clear; echo top-line", enter: true)
        let source = BoxPhoneSource(daemon: daemon)
        #expect(
            await eventually {
                guard let screen = try? await source.screen(PhonePaneParams(pane: pane), scrollback: nil) else {
                    return false
                }
                return screen.lines.count == screen.rows && screen.lines.contains { $0.contains("top-line") }
                    && screen.lines.firstIndex { $0.contains("top-line") }! < 3
            })
    }

    @Test func aPlainShellIsNoAgentInTheInbox() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        _ = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let rows = await BoxPhoneSource(daemon: daemon).inbox().rows
        #expect(rows.allSatisfy { $0.agents.isEmpty })
    }

    @Test func aConnectedPhoneKeepsTheBoxOn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        await daemon.tickBusy()
        #expect(!FileManager.default.fileExists(atPath: home.paths.busyFile))
        await daemon.setPhonesConnected(true)
        await daemon.tickBusy()
        #expect(FileManager.default.fileExists(atPath: home.paths.busyFile))
        try FileManager.default.removeItem(atPath: home.paths.busyFile)
        await daemon.setPhonesConnected(false)
        await daemon.tickBusy()
        #expect(!FileManager.default.fileExists(atPath: home.paths.busyFile))
    }

    /// A task from the phone: a row by the box's branch rules, and a pane typing the agent's line with the brief whole.
    @Test(arguments: ["Fix it's $(touch pwned) and `touch pwned`", "tab\there", "\u{15}touch pwned\r", "\u{3}a\nb"])
    func newRowOnTheBoxMakesARowAndAPane(_ brief: String) async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let source = BoxPhoneSource(daemon: daemon)
        let out = home.dir.sub("ran")

        let made = try await source.newRow(
            PhoneNewRowParams(repo: "demo", branch: "feat/task", brief: brief),
            line: PhoneAgentCommand.line("printf '%s|' > \(out)", brief: brief))
        #expect(!FileManager.default.fileExists(atPath: home.dir.sub("pwned")))

        #expect(made.branch == "feat/task")
        let snapshot = await daemon.snapshot()
        #expect(snapshot.rows.contains { $0.path == made.path && $0.branch == "feat/task" })
        #expect(snapshot.panes.contains { $0.id == made.pane && $0.rowPath == made.path })
        #expect(await eventually { contents(out) == brief + "|" })
        #expect(!FileManager.default.fileExists(atPath: made.path + "/pwned"))
    }

    @Test func aRefusedBranchMakesNoPane() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let source = BoxPhoneSource(daemon: daemon)

        await #expect(throws: ControlError.self) {
            try await source.newRow(PhoneNewRowParams(repo: "demo", branch: "bad..name", brief: ""), line: "true")
        }

        #expect(await daemon.snapshot().panes.isEmpty)
    }
}

/// The box's phone methods, which the Mac's `phone ... --on` reaches through the link.
struct BoxPhonesMethodsTests {
    /// `host upgrade` starts the daemon before it configures it, so the box's name for phones is its alias on the Mac
    /// from then on, not the name it started with.
    @Test func phonesSeeTheNameTheMacGaveTheBox() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon(configured: false)
        try "127.0.0.1 0".write(toFile: home.paths.folder + "/phone-listen", atomically: true, encoding: .utf8)
        let phones = BoxMain.phoneServer(daemon: daemon, paths: home.paths, environment: [:])
        await phones.refresh()
        defer { phones.stop() }
        try BoxFiles.write(try JSONEncoder().encode(home.config), to: home.paths.configFile)
        let port = try #require(await phones.status().endpoints.first?.port)
        let code = await phones.registry.newCode().code

        let client = try PhoneTestClient(port: port)
        let paired = try await offPool {
            try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: "iPhone")))
        }

        let result = try #require(paired.result).decode(PhonePairResult.self)
        #expect(result.mac == "box" && result.kind == PhoneServerKind.box)
    }

    /// Hello names the command the Mac set for the box, and the standard one until it sets one.
    @Test func helloCarriesTheCommandTheMacSet() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        try "127.0.0.1 0".write(toFile: home.paths.folder + "/phone-listen", atomically: true, encoding: .utf8)
        let phones = BoxMain.phoneServer(daemon: daemon, paths: home.paths, environment: [:])
        await phones.refresh()
        defer { phones.stop() }
        let port = try #require(await phones.status().endpoints.first?.port)
        let code = await phones.registry.newCode().code
        let client = try PhoneTestClient(port: port)
        let paired = try await offPool {
            try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: "iPhone")))
        }
        let token = try #require(paired.result).decode(PhonePairResult.self).token
        func greeting() async throws -> PhoneHelloResult {
            let hello = try await offPool {
                try client.call(PhoneMethod.hello, try .from(PhoneHelloParams(token: token)))
            }
            return try #require(hello.result).decode(PhoneHelloResult.self)
        }

        #expect(try await greeting().agentCommand == PhoneAgentCommand.standard)
        var config = home.config
        config.agentCommand = "codex --yolo"
        try await daemon.configure(config)
        #expect(try await greeting().agentCommand == "codex --yolo")
    }

    @Test func pairingGivesACodeAndListingShowsNoPhonesYet() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let phones = PhoneServer(
            source: BoxPhoneSource(daemon: daemon),
            settings: PhoneServerSettings(
                registryFile: URL(fileURLWithPath: home.paths.folder + "/phones.json"), serverName: { "box" },
                version: "1", port: 0, addresses: { ["127.0.0.1"] }, tailnetName: { nil }, closedReason: { "off" },
                record: { _ in }))
        await phones.refresh()
        defer { phones.stop() }
        let paired = await BoxServer.handle(
            ControlRequest(method: BoxMethod.phonesPair), daemon: daemon, phones: phones)
        #expect(paired.error == nil)
        #expect(paired.result.map { "\($0)" }?.contains("code") == true)
        let listed = await BoxServer.handle(
            ControlRequest(method: BoxMethod.phonesList), daemon: daemon, phones: phones)
        #expect(listed.result == .array([]))
        let off = await BoxServer.handle(ControlRequest(method: BoxMethod.phonesList), daemon: daemon)
        #expect(off.error?.code == "phones_off")
    }
}
