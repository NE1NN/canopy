import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// The phone's methods on panes, through the listener as a phone calls them.
@MainActor
struct PhoneServicePaneTests {
    typealias Harness = PhoneServiceTests.Harness

    @MainActor
    struct Setup {
        let harness: Harness
        let client: PhoneTestClient
        let pane: Pane

        var id: String { pane.id.description }
        var reads: [String] { ReadRecorder.reads(in: (pane.terminal!.emulator as? FakeEmulator)?.text ?? "") }

        func call(_ method: String, _ params: some Encodable) async throws -> ControlResponse {
            let value = try JSONValue.from(params)
            let client = self.client
            return try await offPool { try client.call(method, value) }
        }

        func next() async throws -> PhoneMessage? {
            let client = self.client
            return try await offPool { try client.next() }
        }
    }

    func setup(_ dir: TempDir) async throws -> Setup {
        let harness = try Harness(dir)
        await harness.start()
        let command = ReadRecorder.command(try ReadRecorder.install(in: dir), paste: true)
        let pane = harness.terminals.openTab(
            for: PaneContext(row: harness.row, repoName: "r"), command: .script(command)
        )
        .pane
        pane.terminal!.returnPatience = .seconds(60)
        #expect(await eventually { (pane.terminal!.emulator as? FakeEmulator)?.text.contains("ready") == true })
        // Replies go only where a Claude Code session holds the pane.
        pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        pane.report(AgentReport(state: .done, session: "s1", event: "Stop"))
        return Setup(harness: harness, client: try await harness.pairedClient("Hindie's iPhone"), pane: pane)
    }

    func transcript(_ dir: TempDir) throws -> URL {
        let url = URL(fileURLWithPath: dir.sub("session.jsonl"))
        try FileManager.default.copyItem(at: try TranscriptFixture.url("tools"), to: url)
        return url
    }

    @Test func readsAndFollowsAConversation() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        let url = try transcript(dir)
        setup.pane.report(AgentReport(state: .working, transcriptPath: url.path))

        let page = try await setup.call(
            PhoneMethod.transcript, PhoneTranscriptParams(pane: setup.id, limit: 2, follow: true))
        let result = try #require(page.result).decode(PhoneTranscriptResult.self)
        #expect(result.entries.map(\.kind) == [.tools, .text])
        #expect(result.older != nil)

        let line =
            #"{"type":"user","uuid":"new","timestamp":"2026-10-12T03:10:00.000Z","message":{"role":"user","content":"thanks"}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        let event = try #require(try await setup.next()?.event)
        #expect(event.event == PhoneEvent.transcript && event.subscription == page.id)
        #expect(try event.data.decode(PhoneTranscriptUpdate.self).entries.map(\.text) == ["thanks"])

        let older = try await setup.call(
            PhoneMethod.transcript, PhoneTranscriptParams(pane: setup.id, before: result.older, limit: 50))
        #expect(try #require(older.result).decode(PhoneTranscriptResult.self).entries.first?.kind == .prompt)

        let stopped = try await setup.call(PhoneMethod.unsubscribe, PhoneUnsubscribeParams(subscription: page.id))
        #expect(stopped.error == nil)
        let more = try FileHandle(forWritingTo: url)
        try more.seekToEnd()
        try more.write(contentsOf: Data((line.replacingOccurrences(of: "\"new\"", with: "\"newer\"") + "\n").utf8))
        try more.close()
        let client = setup.client
        #expect(try await offPool { try client.isQuiet(for: .milliseconds(800)) })
    }

    @Test func aTranscriptNotWrittenYetIsEmptyAndStillFollowed() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        let url = URL(fileURLWithPath: dir.sub("later.jsonl"))
        setup.pane.report(AgentReport(state: .working, session: "s1", transcriptPath: url.path))
        let page = try await setup.call(PhoneMethod.transcript, PhoneTranscriptParams(pane: setup.id, follow: true))
        #expect(try #require(page.result).decode(PhoneTranscriptResult.self).entries.isEmpty)
        let line =
            #"{"type":"user","uuid":"first","timestamp":"2026-10-12T03:10:00.000Z","message":{"role":"user","content":"hello"}}"#
        try Data((line + "\n").utf8).write(to: url)
        let event = try #require(try await setup.next()?.event)
        #expect(try event.data.decode(PhoneTranscriptUpdate.self).entries.map(\.text) == ["hello"])
    }

    @Test func followingStartsFromTheNewestPage() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        setup.pane.report(AgentReport(state: .working, session: "s1", transcriptPath: try transcript(dir).path))
        let response = try await setup.call(
            PhoneMethod.transcript, PhoneTranscriptParams(pane: setup.id, before: 100, follow: true))
        #expect(response.error?.code == "bad_params")
    }

    @Test func aPaneWithoutAConversationSaysSo() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        let response = try await setup.call(PhoneMethod.transcript, PhoneTranscriptParams(pane: setup.id))
        #expect(response.error?.code == "no_transcript")
        let missing = try await setup.call(PhoneMethod.transcript, PhoneTranscriptParams(pane: "p999"))
        #expect(missing.error?.code == "pane_not_found")
    }

    @Test func aReplyIsSentThenDelivered() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }

        let response = try await setup.call(PhoneMethod.reply, PhoneReplyParams(pane: setup.id, text: "Tailscale"))
        let reply = try #require(response.result).decode(PhoneReplyResult.self)
        #expect(await eventually { setup.reads.last == "<0d>" })
        setup.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        let event = try #require(try await setup.next()?.event)
        #expect(event.event == PhoneEvent.delivered)
        #expect(try event.data.decode(PhoneDelivered.self) == PhoneDelivered(pane: setup.id, reply: reply.reply))

        let logged = try setup.harness.events(ActivityType.phoneCall)
        #expect(logged.first?.data["phone"] == "Hindie's iPhone")
        #expect(logged.first?.data["text"] == "Tailscale")
        #expect(logged.first?.source == .phone)
    }

    @Test func anAnswerToAPromptThatMovedOnSendsNothing() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        setup.pane.report(
            AgentReport(
                state: .waiting, event: "PermissionRequest", prompt: AgentPrompt(kind: .permission, tool: "Bash")))
        let prompt = try #require(setup.pane.agent.prompt)

        let stale = try await setup.call(
            PhoneMethod.answer, PhoneAnswerParams(pane: setup.id, prompt: "older", answer: PhoneAnswer(allow: true)))
        #expect(stale.error?.code == "prompt_gone")
        let allowed = try await setup.call(
            PhoneMethod.answer, PhoneAnswerParams(pane: setup.id, prompt: prompt.id, answer: PhoneAnswer(allow: false)))
        #expect(allowed.error == nil)
        #expect(await eventually { setup.reads == ["<1b>"] })
    }

    @Test func keysAreSentButNotLogged() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        let response = try await setup.call(PhoneMethod.keys, PhoneKeysParams(pane: setup.id, text: "secret"))
        #expect(response.error == nil)
        #expect(await eventually { setup.reads == ["secret"] })
        let logged = try setup.harness.events(ActivityType.phoneCall)
        #expect(logged.map { $0.data["method"] } == [.string(PhoneMethod.keys)])
        #expect(logged.first?.data["text"] == nil)
    }

    @Test func aScreenStreamsWhileItChanges() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        let response = try await setup.call(PhoneMethod.screen, PhonePaneParams(pane: setup.id))
        let first = try #require(response.result).decode(PhoneScreen.self)
        #expect(first.scrollback != nil)
        #expect(first.lines.contains("ready"))

        let keys = try await setup.call(PhoneMethod.keys, PhoneKeysParams(pane: setup.id, text: "x"))
        #expect(keys.error == nil)
        var changed: PhoneScreen?
        while changed == nil, let message = try await setup.next() {
            if let event = message.event, event.event == PhoneEvent.screen {
                changed = try event.data.decode(PhoneScreen.self)
            }
        }
        #expect(changed?.lines.contains { $0.hasPrefix("read ") } == true)
        #expect(changed?.scrollback == nil)
    }

    @Test func seeingADoneAgentFromThePhone() async throws {
        let dir = try TempDir()
        let setup = try await setup(dir)
        defer { setup.harness.close() }
        setup.pane.report(AgentReport(state: .done))
        let response = try await setup.call(PhoneMethod.seen, PhonePaneParams(pane: setup.id))
        #expect(response.error == nil)
        #expect(!setup.pane.agent.unseen)
    }
}
