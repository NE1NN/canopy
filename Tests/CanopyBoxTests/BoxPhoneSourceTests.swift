import CanopyAgents
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
        #expect(inbox.sections.needsYou.map(\.agent.pane) == [pane])
        let rows = await source.rows()
        #expect(rows.sections.map(\.name) == ["demo"])
        #expect(rows.sections.first?.main?.path == home.clone)
        #expect(rows.sections.first?.others.map(\.path) == [made.row.path])
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
}
