import Foundation
import Testing

@testable import CanopyCore

/// `canopy term send`, down to the reads a program gets.
@MainActor
struct TermSendTests {
    @MainActor
    struct Recording {
        let terminals: TerminalStore
        let rows: RowLifecycle
        let pane: Pane

        var reads: [String] { ReadRecorder.reads(in: pane.screen.text) }

        func send(_ text: String, enter: Bool = false) async throws {
            try await rows.sendToTerminal(TermSendParams(pane: pane.id.description, text: text, enter: enter))
        }

        /// Waits for the program to have read `expected`, then checks, so a failure shows what it read.
        func expectReads(_ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
            _ = await eventually { reads == expected }
            #expect(reads == expected, sourceLocation: sourceLocation)
        }
    }

    /// A pane running the read recorder, and the lifecycle that sends to it as `canopy term send` does.
    func recording(_ dir: TempDir, paste: Bool) async throws -> Recording {
        let terminals = Fixture.terminals(dir)
        let rows = RowLifecycle(
            workspace: Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git), terminals: terminals)
        let command = ReadRecorder.command(try ReadRecorder.install(in: dir), paste: paste)
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(command)).focused
        // A loaded machine can take seconds to schedule the recorder, and Return must still wait for it.
        pane.returnPatience = .seconds(60)
        #expect(await eventually { pane.screen.text.contains("ready") })
        return Recording(terminals: terminals, rows: rows, pane: pane)
    }

    static let message = "Please reply with only the word ok, and do not use any tools while you do it, thanks."

    /// Claude Code keeps a Return that arrives in the same read as 64 or more bytes of text as a new line.
    @Test func enterSendsReturnInAReadOfItsOwn() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: false)
        defer { recording.terminals.closeAll() }

        try await recording.send(Self.message, enter: true)

        await recording.expectReads([Self.message, "<0d>"])
    }

    /// Codex takes an Enter within 120 ms of a burst of typed characters for part of a paste.
    @Test func returnWaitsAPauseAfterTheText() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: false)
        defer { recording.terminals.closeAll() }
        let start = Date()

        try await recording.send(Self.message, enter: true)

        await recording.expectReads([Self.message, "<0d>"])
        let returned = try #require(ReadRecorder.timedReads(in: recording.pane.screen.text).last?.time)
        #expect(returned.timeIntervalSince(start) >= Pane.returnPause / .seconds(1))
    }

    /// `term send --enter` returns once Return is in, so a `term read` right after sees what it did.
    @Test func sendReturnsOnceReturnIsIn() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: false)
        defer { recording.terminals.closeAll() }
        let start = Date()

        try await recording.send(Self.message, enter: true)

        #expect(Date().timeIntervalSince(start) >= Pane.returnPause / .seconds(1))
    }

    /// Text over the terminal's input queue goes in over several reads, and Return still comes after all of it.
    @Test func returnFollowsTextLongerThanTheInputQueue() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: false)
        defer { recording.terminals.closeAll() }
        let text = String(repeating: "0123456789", count: 300)

        try await recording.send(text, enter: true)

        _ = await eventually { recording.reads.last == "<0d>" }
        #expect(recording.reads.last == "<0d>")
        #expect(recording.reads.dropLast().joined() == text)
    }

    @Test func typingWhileReturnWaitsComesAfterIt() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: false)
        defer { recording.terminals.closeAll() }

        let sending = Task { try await recording.send(Self.message, enter: true) }
        _ = await eventually { recording.reads.first == Self.message }
        recording.pane.screen.type("x")
        try await sending.value

        _ = await eventually { recording.reads.dropFirst().joined() == "<0d>x" }
        #expect(recording.reads.dropFirst().joined() == "<0d>x")
    }

    /// Text goes in as typed even to a program that asked for bracketed paste, so vim in Normal mode still runs `:wq`
    /// instead of inserting it, and a menu still takes "2" as a key.
    @Test func textIsTypedEvenWhenTheProgramAskedForBracketedPaste() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: true)
        defer { recording.terminals.closeAll() }
        var expected: [String] = []

        for text in [Self.message, ":wq", "2", "first line\n\tsecond line", "\u{15}new text", "a\rb"] {
            try await recording.send(text, enter: true)
            expected += [ReadRecorder.escaped(text), "<0d>"]
            await recording.expectReads(expected)
        }
    }

    @Test func aLoneEnterWaitsForTextSentBeforeIt() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: false)
        defer { recording.terminals.closeAll() }

        // Written back to back, text and Return arrived in one read about two times in three.
        for round in 1...10 {
            try await recording.send(Self.message)
            try await recording.send("", enter: true)
            await recording.expectReads(Array(repeating: [Self.message, "<0d>"], count: round).flatMap { $0 })
        }
    }

    @Test func textWithoutEnterIsTypedAsBefore() async throws {
        let dir = try TempDir()
        let recording = try await recording(dir, paste: true)
        defer { recording.terminals.closeAll() }

        try await recording.send("echo one\r")

        await recording.expectReads(["echo one<0d>"])
    }
}
