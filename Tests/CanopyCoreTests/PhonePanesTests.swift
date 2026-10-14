import CanopyTestSupport
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

        var reads: [String] { ReadRecorder.reads(in: (pane.terminal!.emulator as? FakeEmulator)?.text ?? "") }
        var id: String { pane.id.description }

        func close() {
            panes.stop()
            terminals.closeAll()
        }
    }

    /// A pane running the read recorder, whose agent a Claude Code session holds, as replies need.
    func recording(_ dir: TempDir) async throws -> Recording {
        let recording = try await bareRecording(dir)
        recording.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        recording.pane.report(AgentReport(state: .done, session: "s1", event: "Stop"))
        return recording
    }

    func bareRecording(_ dir: TempDir) async throws -> Recording {
        let terminals = Fixture.terminals(dir)
        let command = ReadRecorder.command(try ReadRecorder.install(in: dir), paste: true)
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(command)).pane
        pane.terminal!.returnPatience = .seconds(60)
        #expect(await eventually { (pane.terminal!.emulator as? FakeEmulator)?.text.contains("ready") == true })
        let panes = PhonePanes(terminals: terminals)
        panes.start()
        return Recording(terminals: terminals, panes: panes, pane: pane)
    }

    @Test func aReplyIsOnePasteThenReturnOnItsOwn() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }

        try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "line one\nline two"))

        let expected = ReadRecorder.escaped("\u{1b}[200~line one\rline two\u{1b}[201~")
        #expect(await eventually { recording.reads.last == "<0d>" })
        #expect(recording.reads.dropLast().joined() == expected)
    }

    @Test func aLongReplyLandsWhole() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let text = (1...200).map { "Line \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n")

        try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: text))

        #expect(await eventually { recording.reads.last == "<0d>" })
        let pasted = text.replacingOccurrences(of: "\n", with: "\r")
        #expect(recording.reads.dropLast().joined() == ReadRecorder.escaped("\u{1b}[200~" + pasted + "\u{1b}[201~"))
    }

    @Test func aReplyCannotEndItsOwnPaste() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }

        try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "a\u{1b}[201~\u{1b}b\r\nc"))

        #expect(await eventually { recording.reads.last == "<0d>" })
        #expect(recording.reads.dropLast().joined() == ReadRecorder.escaped("\u{1b}[200~a[201~b\rc\u{1b}[201~"))
    }

    @Test func aReplyIsDeliveredWhenThePanesNextPromptArrives() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let delivered = Shared<[String]>([])

        try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "go")) {
            delivered.withLock { list in
                let label = list.isEmpty ? "first" : "again"
                list.append(label)
            }
        }
        #expect(delivered.withLock { $0 }.isEmpty)
        recording.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        recording.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        #expect(delivered.withLock { $0 } == ["first"])
    }

    @Test func aReplyNeverAnswersADialogThePhoneDidNotSee() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        recording.pane.report(
            AgentReport(
                state: .waiting, session: "s1", event: "PermissionRequest",
                prompt: AgentPrompt(kind: .permission, tool: "Bash", detail: "rm -rf build")))

        await #expect(throws: PhonePanes.promptOpen) {
            try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "also check the migrations"))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(recording.reads.isEmpty)
    }

    @Test func aDialogOpeningDuringThePasteHoldsBackReturn() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let pane = recording.pane
        let panes = recording.panes
        let id = recording.id
        // Return waits long after the paste is read, and the dialog's hook lands in between.
        pane.terminal!.replyPause = .seconds(2)
        let reply = Task { try await panes.reply(PhoneReplyParams(pane: id, text: "go")) }
        #expect(await eventually { !recording.reads.isEmpty })
        pane.report(
            AgentReport(
                state: .waiting, session: "s1", event: "PermissionRequest",
                prompt: AgentPrompt(kind: .permission, tool: "Bash", detail: "rm -rf build")))
        await #expect(throws: PhonePanes.promptOpen) { try await reply.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!recording.reads.contains("<0d>"))
    }

    @Test func aReplyToAQuestionInTheMessageIsFine() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        recording.pane.report(
            AgentReport(
                state: .waiting, session: "s1", event: "Stop", question: true,
                prompt: AgentPrompt(kind: .reply, detail: "Should I?")))
        try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "yes"))
        #expect(await eventually { recording.reads.last == "<0d>" })
    }

    @Test func aReplyNeedsClaudeCodeRunning() async throws {
        let dir = try TempDir()
        let recording = try await bareRecording(dir)
        defer { recording.close() }
        await #expect(throws: PhonePanes.agentNotRunning) {
            try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "rm -rf ~"))
        }
        recording.pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
        recording.pane.report(AgentReport(state: AgentState.none, session: "s1", event: "SessionEnd", releases: true))
        await #expect(throws: PhonePanes.agentNotRunning) {
            try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "rm -rf ~"))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(recording.reads.isEmpty)
    }

    @Test func aReplyTheAgentNeverTookIsForgottenWhenItEnds() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir)
        defer { recording.close() }
        let delivered = Shared(0)
        try await recording.panes.reply(PhoneReplyParams(pane: recording.id, text: "go")) {
            delivered.withLock { $0 += 1 }
        }
        recording.pane.report(AgentReport(state: AgentState.none, session: "s1", event: "SessionEnd", releases: true))
        recording.pane.report(AgentReport(state: .working, session: "s2", event: "UserPromptSubmit"))
        #expect(delivered.withLock { $0 } == 0)
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
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("seq 1 100; exec sleep 60")).pane
        let emulator = try #require(pane.terminal!.emulator as? FakeEmulator)
        #expect(await eventually { emulator.lines.contains("100") })
        let panes = PhonePanes(terminals: terminals)

        let screen = try panes.screen(PhonePaneParams(pane: pane.id.description), scrollback: 30)
        #expect(screen.columns == TerminalSize.standard.columns && screen.rows == TerminalSize.standard.rows)
        #expect(screen.lines.count == screen.rows)
        #expect(screen.lines.contains("100"))
        let scrollback = try #require(screen.scrollback)
        #expect(scrollback.count == 30)
        // The scrollback runs on into the screen without a gap.
        let all = scrollback + screen.lines
        let first = try #require(Int(all[0]))
        #expect(Array(all.prefix(30)) == (first..<first + 30).map(String.init))
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
