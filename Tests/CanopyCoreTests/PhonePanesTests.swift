import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PhonePanesTests {
    @MainActor
    struct Recording {
        let terminals: TerminalStore
        let panes: PhonePanes
        let pane: Pane

        var reads: [String] { ReadRecorder.reads(in: (pane.emulator as? FakeEmulator)?.text ?? "") }
        var id: String { pane.id.description }

        func close() {
            panes.stop()
            terminals.closeAll()
        }
    }

    func recording(_ dir: TempDir) async throws -> Recording {
        let terminals = Fixture.terminals(dir)
        let command = ReadRecorder.command(try ReadRecorder.install(in: dir), paste: true)
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(command)).pane
        pane.returnPatience = .seconds(60)
        #expect(await eventually { (pane.emulator as? FakeEmulator)?.text.contains("ready") == true })
        let panes = PhonePanes(terminals: terminals)
        panes.start()
        return Recording(terminals: terminals, panes: panes, pane: pane)
    }

    @Test func aReplyIsOnePasteThenReturnOnItsOwn() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }

        _ = try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "line one\nline two"))

        let expected = ReadRecorder.escaped("\u{1b}[200~line one\rline two\u{1b}[201~")
        #expect(await eventually { recording.reads.last == "<0d>" })
        #expect(recording.reads.dropLast().joined() == expected)
    }

    @Test func aLongReplyLandsWhole() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let text = (1...200).map { "Line \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n")

        _ = try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: text))

        #expect(await eventually { recording.reads.last == "<0d>" })
        let pasted = text.replacingOccurrences(of: "\n", with: "\r")
        #expect(recording.reads.dropLast().joined() == ReadRecorder.escaped("\u{1b}[200~" + pasted + "\u{1b}[201~"))
    }

    @Test func aReplyCannotEndItsOwnPaste() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }

        _ = try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "a\u{1b}[201~\u{1b}b\r\nc"))

        #expect(await eventually { recording.reads.last == "<0d>" })
        #expect(recording.reads.dropLast().joined() == ReadRecorder.escaped("\u{1b}[200~a[201~b\rc\u{1b}[201~"))
    }

    @Test func aReplyIsDeliveredWhenThePanesNextPromptArrives() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let delivered = Shared<[String]>([])

        let reply = try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "go")) {
            delivered.withLock { list in
                let label = list.isEmpty ? "first" : "again"
                list.append(label)
            }
        }
        #expect(!reply.reply.isEmpty)
        #expect(delivered.withLock { $0 }.isEmpty)
        recording.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        recording.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        #expect(delivered.withLock { $0 } == ["first"])
    }

    @Test func anAnswerSendsItsKeysOneReadEachAndOnlyOnce() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let questions = [
            PromptQuestion(question: "Color?", options: [.init(label: "Red"), .init(label: "Blue")]),
            PromptQuestion(question: "Size?", options: [.init(label: "Small"), .init(label: "Large")]),
        ]
        recording.pane.report(
            AgentReport(
                state: .waiting, event: "PreToolUse", prompt: AgentPrompt(kind: .question, questions: questions)))
        let prompt = try #require(recording.pane.agent.prompt)

        let stale = PhoneAnswerParams(pane: recording.id, prompt: "old", answer: PhoneAnswer(options: [[0], [0]]))
        await #expect(throws: PhonePanes.promptGone) { try await recording.panes.answer(stale) }

        let answer = PhoneAnswerParams(pane: recording.id, prompt: prompt.id, answer: PhoneAnswer(options: [[1], [1]]))
        try await recording.panes.answer(answer)
        #expect(await eventually { recording.reads == ["2", "2", "1"] })
        await #expect(throws: PhonePanes.promptGone) { try await recording.panes.answer(answer) }
    }

    @Test func allowingAPermissionIsReturn() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        recording.pane.report(
            AgentReport(
                state: .waiting, event: "PermissionRequest", prompt: AgentPrompt(kind: .permission, tool: "Bash")))
        let prompt = try #require(recording.pane.agent.prompt)

        try await recording.panes.answer(
            PhoneAnswerParams(pane: recording.id, prompt: prompt.id, answer: PhoneAnswer(allow: true)))

        #expect(await eventually { recording.reads == ["<0d>"] })
        #expect(recording.pane.agent.state == .working)
    }

    @Test func keysGoInAsTheyAre() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        try recording.panes.keys(PhoneKeysParams(pane: recording.id, text: "\u{1b}[A"))
        #expect(await eventually { recording.reads == ["<1b>[A"] })
    }

    @Test func seeingADoneAgentClearsItsGreen() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        recording.pane.report(AgentReport(state: .done))
        #expect(recording.pane.agent.unseen)
        try recording.panes.seen(PhonePaneParams(pane: recording.id))
        #expect(!recording.pane.agent.unseen)
    }

    @Test func aPaneThatIsGoneSaysSo() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        #expect(throws: WorkspaceError.paneNotFound("p999")) {
            try recording.panes.keys(PhoneKeysParams(pane: "p999", text: "x"))
        }
    }

    @Test func theScreenComesWithItsScrollback() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("seq 1 100; sleep 60")).pane
        let emulator = try #require(pane.emulator as? FakeEmulator)
        #expect(await eventually { emulator.lines.last == "100" })
        let panes = PhonePanes(terminals: terminals)

        let screen = try panes.screen(PhonePaneParams(pane: pane.id.description), scrollback: 30)
        #expect(screen.columns == TerminalSize.standard.columns && screen.rows == TerminalSize.standard.rows)
        #expect(screen.lines.last == "100")
        #expect(screen.lines.count == screen.rows)
        #expect(screen.scrollback?.count == 30)
        #expect(screen.scrollback?.last == String(100 - screen.rows))
    }

    @Test func theTranscriptIsTheAgentsAndOnlyOnThisMac() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        #expect(throws: PhonePanes.noTranscript) { try recording.panes.transcriptURL(recording.id) }
        recording.pane.report(AgentReport(state: .working, transcriptPath: "/t/s.jsonl"))
        #expect(try recording.panes.transcriptURL(recording.id).path == "/t/s.jsonl")
    }
}
