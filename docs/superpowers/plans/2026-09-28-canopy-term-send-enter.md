# Canopy Term Send Enter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `canopy term send <pane> <text> --enter` submit into Claude Code and Codex at the first try, whatever the text's length and even when it holds newlines, while every other program gets exactly the keys it got before.

**Architecture:** `--enter` no longer writes `text + "\r"` in one write.
The text goes first, unchanged, and Return follows in a write of its own once the program has read the text and 200 ms have passed.
`PtyProcess` learns to write a second part after the terminal's input queue empties and a pause, and `Pane.type(_:enter:)` uses it and returns once Return is in, so `term send` does too.
In canonical mode the terminal hands the program whole lines, so there is nothing to wait for there.

**Tech Stack:** Swift 6.2, a small C helper for `FIONREAD`, Swift Testing, and a Perl read recorder in the tests and e2e.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Commands" (`canopy term send`).
The spec's table row and `canopy agent-guide` change to say how Return is sent.

## Root Cause

Reproduced with a dev build on a throwaway home, a pane running `claude --model haiku` (Claude Code 2.1.283), and the real CLI:

- `term send p2 "<132-character message>" --enter` left the message in the input box with a blank line after it, every time.
- A lone `term send p2 "" --enter` then did nothing visible, and a second lone one submitted.
- A 60-character message with `--enter` submitted every time.
- Typing the long message without `--enter`, then a lone `--enter`, submitted at the first Return.

A pane running a read logger showed the 132 bytes arriving in a single `read()` for each send.
Claude Code's input tokenizer, read from its bundled JavaScript, splits control characters out of a chunk only when the chunk is shorter than 64 bytes:

```js
else if (!s && a < 32 && (u.length < 64 || a === Zne.BS)) { g(), i++, ...; m.push({type: "text", value: String.fromCharCode(a)}) }
else i++;
```

In a longer chunk, `\r` stays inside the text, and the prompt inserts it as a line break, as it would for an unbracketed paste.
The stray `\r` left in the input is what swallowed the next lone Return; a trailing `\n` does not.

Writing Return separately is not enough on its own.
Against an idle reader, a write of the text and a write of `\r` back to back arrived in one read 33 times in 50, once in 50 with 1 ms between them, and never with 5 ms or more.
On macOS, `FIONREAD` on the pty master reports the input the program has not read yet: 132 before a raw-mode reader read, 0 after, and only whole lines in canonical mode.
Waiting for it to reach 0 puts Return in a read of its own for any program that is reading.

That fixed Claude Code, but Codex 0.149 still kept the Return as a new line.
Codex guesses pastes from timing: an Enter within `PASTE_ENTER_SUPPRESS_WINDOW`, 120 ms after a burst of typed characters, inserts a new line (`codex-rs/tui/src/bottom_pane/paste_burst.rs`).
With 40 ms or more between the read and Return it submitted every time, and at about 20 ms it sometimes did not.
So Return also waits 200 ms after the program has read the text.

### Why not bracketed paste

The first draft wrapped the text in `ESC [200~` and `ESC [201~` when the program had turned on bracketed paste, as Claude Code's own pty driver does when it types into another Claude.
It submitted into Claude Code every time, but vim turns bracketed paste on in every mode, and `term send <pane> ":wq" --enter` in Normal mode inserted `:wq` into the buffer instead of saving.
Menus that take "2" or "y" as a key can ignore a paste the same way.
Typing the text unchanged and timing Return keeps every program's keys as they were.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings.
- `make lint` passes `swift format lint --strict`.
- The bytes a program reads do not change: `term send` without `--enter` sends exactly what it did, and `--enter` adds only `\r`.
- `canopy term new --run` and `row new --run`, which type a command and Return into a shell at its prompt, do not change.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. Claude Code with a message of 64 bytes or more, with or without newlines: the first `--enter` submits.
   Pinned by `enterSendsReturnInAReadOfItsOwn` in Task 2 and the e2e step in Task 3, and checked by hand against real Claude.
2. Codex, which takes an Enter within 120 ms of typed text for part of a paste: the first `--enter` submits.
   Pinned by `returnWaitsAPauseAfterTheText` in Task 2 and `secondPartWaitsThePauseToo` in Task 1, and checked by hand against real Codex.
3. A lone `term send <pane> "" --enter` right after text sent without `--enter`: Return still lands in a read of its own.
   Pinned by `aLoneEnterWaitsForTextSentBeforeIt` in Task 2 and the e2e step.
4. vim in Normal mode, and menus that take one key, when the program turned on bracketed paste: `:wq` and "2" arrive as keys.
   Pinned by `textIsTypedEvenWhenTheProgramAskedForBracketedPaste` in Task 2.
5. A program that is busy and not reading: Return still goes in after the patience runs out, instead of waiting forever.
   Pinned by `secondPartGoesInWhenTheProgramDoesNotReadInTime` in Task 1.

## Decisions to Review

1. **No bracketed paste markers.**
   They would make Codex's Return deterministic, but they turn keys into text in vim's Normal mode and in menus, as shown above.
2. **Return waits 200 ms after the program has read the text.**
   Codex's window is 120 ms; the rest is margin for a program that is busy drawing when the text arrives.
   Every `--enter` pays it, even a lone Return, since text sent without `--enter` just before counts as a burst too.
3. **Return waits up to 2 seconds for the program to read what came before it, then goes in anyway.**
   A program that is not reading gets Return queued behind the text, as typing ahead would.
   Writes to that pane, including the user's typing, wait behind it meanwhile, on the pane's own write queue.
4. **`Pane.run`, used by `--run`, still writes the command and Return together.**
   It types into a shell at its prompt, which reads keys as keys.
5. **`term send --enter` returns once Return is written, 200 ms to about 2.2 s later than before.**
   A `term read` or `term close` right after it then sees, or keeps, the Return.
6. **No wait in canonical mode.**
   The terminal hands such a program whole lines, so the Return completes the line whenever it goes in, and waiting would only hold up the pane's writes, a Control-C included.
7. **Typing ahead into a program that has not started reading keys yet still does not submit.**
   While it starts, the terminal is in canonical mode and hands it the text and its Return as one line, which Claude Code then reads as text with a new line.
   The agent guide says to send once the program's prompt shows, as before this change.

---

## Task 1: Write a second part once the program has read the first

**Files:**
- Modify: `Sources/CPty/include/CPty.h`, `Sources/CPty/pty.c`
- Modify: `Sources/CanopyCore/Terminal/PtyProcess.swift`
- Create: `Tests/CanopyCoreTests/Support/ReadRecorder.swift`
- Test: `Tests/CanopyCoreTests/PtyProcessTests.swift`

**Interfaces:**
- Produces: `int canopy_pty_unread_input(int master)` in CPty.
- Produces: `PtyProcess.write(_ data: Data, then next: Data, pause: Duration = .zero, patience: Duration = .seconds(2)) async` and `PtyProcess.unreadInput: Int` (internal).
- Produces (tests): `enum ReadRecorder` with `install(in:)`, `command(_:paste:)`, `timedReads(in:)`, `reads(in:)`, and `escaped(_:)`.

- [ ] **Step 1: Add the read recorder**

Create `Tests/CanopyCoreTests/Support/ReadRecorder.swift`:

```swift
import Foundation

/// A program that puts its terminal in raw mode, asks for bracketed paste if told to, then prints each read it gets
/// as a line "read <time> <bytes>", with the time in seconds since 1970 and bytes outside printable ASCII written as
/// <hex>, such as <0d> for Return.
enum ReadRecorder {
    static let script = #"""
        use Time::HiRes qw(time);
        system("stty raw -echo");
        $| = 1;
        print "\e[?2004h" if $ARGV[0] eq "paste";
        print "ready\r\n";
        while (sysread(STDIN, my $bytes, 65536)) {
            my $when = time;
            $bytes =~ s/([^ -~])/sprintf("<%02x>", ord $1)/ge;
            printf "read %.6f %s\r\n", $when, $bytes;
        }
        """#

    /// Writes the script into `dir` and returns its path.
    static func install(in dir: TempDir) throws -> String {
        let path = dir.sub("read-recorder.pl")
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A shell command that runs the recorder at `path`.
    static func command(_ path: String, paste: Bool) -> String {
        "exec /usr/bin/perl '\(path)' \(paste ? "paste" : "plain")"
    }

    /// Each read, in order, with when the program got it.
    static func timedReads(in output: String) -> [(bytes: String, time: Date)] {
        output.components(separatedBy: "\r\n").compactMap { line in
            guard line.hasPrefix("read ") else { return nil }
            let fields = line.dropFirst(5).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let seconds = Double(fields[0]) else { return nil }
            return (String(fields[1]), Date(timeIntervalSince1970: seconds))
        }
    }

    /// What each read held, in order.
    static func reads(in output: String) -> [String] {
        timedReads(in: output).map(\.bytes)
    }

    /// `text` as the recorder prints it.
    static func escaped(_ text: String) -> String {
        text.utf8.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : String(format: "<%02x>", $0) }
            .joined()
    }
}
```

- [ ] **Step 2: Write the failing tests**

In `Tests/CanopyCoreTests/PtyProcessTests.swift`, after `startsInTheFolderWithTheEnvironment`:

```swift
    @Test func secondPartWaitsUntilTheProgramHasReadTheFirst() async throws {
        let dir = try TempDir()
        let recorder = try ReadRecorder.install(in: dir)
        let (process, output) = try start(["/bin/sh", "-c", ReadRecorder.command(recorder, paste: false)])
        defer { process.terminate() }
        #expect(await eventually { output.text.contains("ready") })

        // Written back to back, the two parts arrived in one read about two times in three.
        for round in 1...10 {
            await process.write(Data("some text".utf8), then: Data("\r".utf8), patience: .seconds(60))
            let expected = Array(repeating: ["some text", "<0d>"], count: round).flatMap { $0 }
            _ = await eventually { ReadRecorder.reads(in: output.text) == expected }
            #expect(ReadRecorder.reads(in: output.text) == expected)
        }
    }

    @Test func secondPartWaitsThePauseToo() async throws {
        let dir = try TempDir()
        let recorder = try ReadRecorder.install(in: dir)
        let (process, output) = try start(["/bin/sh", "-c", ReadRecorder.command(recorder, paste: false)])
        defer { process.terminate() }
        #expect(await eventually { output.text.contains("ready") })
        let start = Date()

        await process.write(
            Data("some text".utf8), then: Data("\r".utf8), pause: .milliseconds(300), patience: .seconds(60))

        _ = await eventually { ReadRecorder.reads(in: output.text).count == 2 }
        let reads = ReadRecorder.timedReads(in: output.text)
        try #require(reads.map(\.bytes) == ["some text", "<0d>"])
        #expect(reads[1].time.timeIntervalSince(start) >= 0.3)
    }

    @Test func secondPartGoesInWhenTheProgramDoesNotReadInTime() async throws {
        let (process, output) = try start([
            "/usr/bin/perl", "-e", #"system("stty raw -echo"); $| = 1; print "ready\r\n"; sleep 60"#,
        ])
        defer { process.terminate() }
        #expect(await eventually { output.text.contains("ready") })

        await process.write(Data("abc".utf8), then: Data("\r".utf8), patience: .milliseconds(100))

        #expect(process.unreadInput == 4)
    }

    /// In canonical mode the terminal hands the program whole lines, so Return cannot join an earlier chunk.
    @Test func secondPartDoesNotWaitForAProgramThatReadsWholeLines() async throws {
        let (process, output) = try start(["/bin/sleep", "60"])
        defer { process.terminate() }

        Task { await process.write(Data("abc\n".utf8), then: Data("\r".utf8), patience: .seconds(60)) }

        // The terminal echoes each line as it arrives.
        #expect(await eventually { output.text.contains("abc\r\n\r\n") })
    }
```

The pause test compares the recorder's clock with the test's, both wall clock, so it only holds Return to a lower bound that cannot be wrong under load.

- [ ] **Step 3: Watch them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PtyProcessTests`
Expected: the build fails, since `write(_:then:pause:patience:)` and `unreadInput` do not exist.
With a stand-in that writes both parts back to back without waiting for them, reporting no unread input, all four fail: from the second round the reads come back as `"some text<0d>"`, Return comes in under a millisecond, `unreadInput` is 0 when the call returns, and a stand-in that waits in canonical mode too holds Return back for the whole minute.

- [ ] **Step 4: Add the C helper**

In `Sources/CPty/include/CPty.h`, before `#endif`:

```c
/// The bytes written to the terminal that the child has not read yet. On macOS, FIONREAD on the master reports the
/// terminal's input queue, which in canonical mode counts only whole lines, and outside it counts nothing while fewer
/// than VMIN bytes wait with VTIME 0. Returns -1 with errno set on failure.
int canopy_pty_unread_input(int master);
```

At the end of `Sources/CPty/pty.c`:

```c
int canopy_pty_unread_input(int master)
{
    int count = 0;
    return ioctl(master, FIONREAD, &count) == 0 ? count : -1;
}
```

- [ ] **Step 5: Write the second part once the first is read**

In `Sources/CanopyCore/Terminal/PtyProcess.swift`, replace `write(_ data: Data)` with:

```swift
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { self.writeAll(data) }
    }

    /// Writes `data`, then `next` once the program has read everything before it and `pause` has passed, so a program
    /// that is reading gets `next` in a read of its own, a moment later. A program that has not read it all within
    /// `patience` gets `next` behind it anyway, as typing ahead would. Nothing else is written in between, and it
    /// returns once `next` is written.
    public func write(_ data: Data, then next: Data, pause: Duration = .zero, patience: Duration = .seconds(2)) async {
        await withCheckedContinuation { (written: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                defer { written.resume() }
                guard self.writeAll(data) else { return }
                let deadline = ContinuousClock.now + patience
                while self.unreadInput > 0, ContinuousClock.now < deadline {
                    usleep(1000)
                }
                Thread.sleep(forTimeInterval: pause / .seconds(1))
                self.writeAll(next)
            }
        }
    }
```

After `resize(_:)`:

```swift
    /// Bytes written to the program that it has not read yet, while it reads input as it comes. In canonical mode the
    /// terminal hands it whole lines, so a later write cannot join an earlier one's read, and nothing counts.
    var unreadInput: Int {
        state.withLock { state in
            var attributes = termios()
            guard state.fd >= 0, tcgetattr(state.fd, &attributes) == 0, attributes.c_lflag & tcflag_t(ICANON) == 0
            else { return 0 }
            return max(0, Int(canopy_pty_unread_input(state.fd)))
        }
    }
```

Before `// MARK: readQueue`, the old write loop as its own function:

```swift
    // MARK: writeQueue

    /// Returns false if the terminal is gone or refused the write.
    @discardableResult
    private func writeAll(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let (count, code, fd) = state.withLock { state -> (Int, Int32, Int32) in
                guard state.fd >= 0 else { return (-1, EBADF, -1) }
                let count = data.withUnsafeBytes {
                    Darwin.write(state.fd, $0.baseAddress! + offset, $0.count - offset)
                }
                return (count, errno, state.fd)
            }
            if count > 0 {
                offset += count
            } else if code == EAGAIN {
                // The program is not reading its input yet. Wait outside the lock so output keeps flowing.
                var poll = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&poll, 1, 100)
            } else if code != EINTR {
                return false
            }
        }
        return true
    }
```

The write queue is a serial queue of its own, so waiting there holds up only this pane's writes, which must come after Return anyway.
It is not the Swift concurrency pool or one of Dispatch's constrained threads: a serial queue runs on an overcommit thread.

- [ ] **Step 6: Watch them pass, then commit**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PtyProcessTests`
Expected: PASS.

```bash
make lint && make build
git add Sources/CPty Sources/CanopyCore/Terminal/PtyProcess.swift Tests/CanopyCoreTests/Support/ReadRecorder.swift Tests/CanopyCoreTests/PtyProcessTests.swift
git commit -m "feat: write a second part once the program has read the first"
```

## Task 2: Send Return as a keystroke of its own

**Files:**
- Modify: `Sources/CanopyCore/Terminal/Pane.swift`
- Modify: `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`
- Create: `Tests/CanopyCoreTests/TermSendTests.swift`

**Interfaces:**
- Consumes: `PtyProcess.write(_:then:pause:patience:)`, `ReadRecorder`.
- Produces: `Pane.type(_ text: String, enter: Bool = false) async`, `Pane.returnPause`, and `Pane.returnPatience`, which the tests raise.
- Produces: `RowLifecycle.sendToTerminal(_:) async throws`; `WorkspaceControlHandler` already awaits it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CanopyCoreTests/TermSendTests.swift`. The tests go through `RowLifecycle.sendToTerminal`, the code `canopy term send` runs:

```swift
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
```

- [ ] **Step 2: Watch them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter TermSendTests`
Expected: the build fails on `returnPatience`.
With it added and `sendToTerminal` still writing the text and Return together, `textWithoutEnterIsTypedAsBefore` passes and every test that uses `--enter` fails, most with the text and `<0d>` in one read, such as `["Please reply ... thanks.<0d>"]`, and `sendReturnsOnceReturnIsIn` in under 10 ms.
In `Tests/CanopyCoreTests/PaneTests.swift`, `pane.type("\u{3}")` becomes `await pane.type("\u{3}")`.

- [ ] **Step 3: Send Return on its own**

In `Sources/CanopyCore/Terminal/Pane.swift`, replace `type(_:)` with:

```swift
    /// How long Return waits after the program has read the text. Codex takes an Enter that comes within 120 ms of a
    /// burst of typed characters for part of a paste.
    static let returnPause = Duration.milliseconds(200)
    /// How long Return waits for a program that is not reading, before it goes in behind the text anyway.
    @ObservationIgnored var returnPatience = Duration.seconds(2)

    /// Sends text as if typed, for `canopy term send`. An exited pane ignores it.
    /// With `enter`, Return follows as a keystroke of its own, in a later read than the text and `returnPause` after
    /// it, and this returns once Return is in. Programs such as Claude Code and Codex take text and a Return that
    /// arrive together for a paste, where Return adds a new line instead of submitting.
    public func type(_ text: String, enter: Bool = false) async {
        guard case .running = status, let process else { return }
        guard enter else {
            process.write(text)
            return
        }
        await process.write(Data(text.utf8), then: Data("\r".utf8), pause: Self.returnPause, patience: returnPatience)
    }
```

In `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`, in `sendToTerminal`:

```swift
    public func sendToTerminal(_ params: TermSendParams) async throws {
        let pane = try terminal(params.pane)
        guard case .running = pane.status else { throw WorkspaceError.paneExited(params.pane) }
        await pane.type(params.text, enter: params.enter)
    }
```

- [ ] **Step 4: Watch them pass, then commit**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "TermSendTests|PaneTests|ControlServerTests"`
Expected: PASS.

```bash
make lint && make build
git add Sources/CanopyCore Tests/CanopyCoreTests/TermSendTests.swift
git commit -m "fix: term send --enter sends Return as a keystroke of its own"
```

## Task 3: Docs, the e2e step, and hand checks

**Files:**
- Modify: `docs/superpowers/specs/2026-09-27-canopy-design.md`
- Modify: `Sources/CanopyCLI/AgentGuide.swift`
- Modify: `scripts/e2e.sh`

- [ ] **Step 1: Add the e2e step**

In `scripts/e2e.sh`, after the `canopy term` step's last line, `"$cli" agent-guide | grep -q "canopy term read" || fail ...`:

```bash
step "term send --enter presses Return as a keystroke of its own, with no paste markers"
# Puts its terminal in raw mode, turns on bracketed paste as Claude Code and vim do, and logs each read, with Return
# as <0d>.
cat > "$work/reads.pl" <<'PERL'
system("stty raw -echo");
open(my $log, ">>", $ARGV[0]) or die;
$log->autoflush(1);
$| = 1;
print "\e[?2004hready\r\n";
while (sysread(STDIN, my $bytes, 65536)) {
    $bytes =~ s/([^ -~])/sprintf("<%02x>", ord $1)/ge;
    print $log "$bytes\n";
}
PERL
recorder=$("$cli" term new --repo demo --row feat/term --run "exec perl '$work/reads.pl' '$work/reads.log'" --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
wait_for_reads() {
    for _ in $(seq 1 100); do
        [[ "$(cat "$work/reads.log" 2>/dev/null)" == "$1" ]] && return 0
        sleep 0.1
    done
    echo "reads were: $(cat "$work/reads.log" 2>/dev/null)" >&2
    return 1
}
for _ in $(seq 1 100); do
    "$cli" term read "$recorder" | grep -q ready && break
    sleep 0.1
done
"$cli" term read "$recorder" | grep -q ready || fail "the read recorder did not start"
message="A message of more than sixty-four bytes, which Claude Code once kept as a new line"
"$cli" term send "$recorder" "$message" --enter >/dev/null
wait_for_reads "$message"$'\n'"<0d>" || fail "Return did not come in a read of its own"
"$cli" term send "$recorder" "" --enter >/dev/null
wait_for_reads "$message"$'\n'"<0d>"$'\n'"<0d>" || fail "a lone --enter did not send Return"
"$cli" term close "$recorder" --force >/dev/null
"$cli" agent-guide | grep -q "keystroke of its own" || fail "agent-guide does not say how --enter presses Return"
```

Run against a dev build of the old code, the first check fails with `reads were: A message ... new line<0d>`.

- [ ] **Step 2: Update the spec and the agent guide**

In the spec's command table, the `term send` row becomes:

```markdown
| `canopy term send <id> <text> [--enter]` | type text into a pane; `--enter` then presses Return as a keystroke of its own, once the program has read the text (or after 2 s if it is not reading) and 200 ms more have passed, and returns once Return is in, so programs that take a burst of input for a paste still submit |
```

In `Sources/CanopyCLI/AgentGuide.swift`, after the line about terminal IDs:

```
        With --enter, Return goes in as a keystroke of its own once the program has read the text, or after 2 seconds if
        it is not reading, and a moment later; `term send` returns once it is in. Claude Code and Codex take a Return
        that arrives with the text for part of a paste, so this is what makes a long or multi-line message submit.
        Send to a program you just started once its prompt shows in `term read`: until it reads keys itself, the
        terminal hands it typed-ahead lines together with their Return.
```

- [ ] **Step 3: Run the e2e and the hand checks**

Run: `make e2e`
Expected: every step passes, including the new one.

Then, with a dev build on a throwaway home:

- `claude --model haiku`: a 129-character message with `--enter` submits at once, five times running and as the first message after startup; so do a two-line message, a 1465-character one, one sent while Claude is still answering (it queues), and a lone `--enter` after text sent without it.
  `term send --enter` returned after 245 and 391 ms, with the message already submitted.
- Codex, run with a throwaway `CODEX_HOME` so its trust prompts stay out of the user's config: the same long, two-line, lone-Enter, and short sends each submit at once.
- zsh at its prompt: a long `echo` and two lines run.
- vim, bare and with the user's vimrc: text with `--enter` in insert mode adds a line, and `:wq` with `--enter` in Normal mode saves and quits.
- `/opt/homebrew/bin/python3` and `/usr/bin/python3`: a long `print` and a two-line `for` loop run.

- [ ] **Step 4: Commit**

```bash
make lint
git add docs/superpowers/specs scripts/e2e.sh Sources/CanopyCLI/AgentGuide.swift
git commit -m "docs: say how term send --enter presses Return, and check it end to end"
```

## Task 4: The merge bar

- [ ] `make lint` and `make build` with 0 warnings.
- [ ] `lockf -k /tmp/canopy-merge-bar.lock sh -c 'make test && make test && make test'`, all three clean.
- [ ] `make e2e`.
- [ ] An independent opus reviewer on `git diff main...HEAD`, findings fixed and listed under "After Review".
- [ ] CI `check` green on the PR, titled `fix: term send --enter submits into Claude Code`.

## After Review

An independent opus reviewer read `git diff main...HEAD` and found no blockers and no major issues.
Its minor findings and nits, and what changed:

1. **Typing ahead into a program that is still starting.**
   Its terminal is in canonical mode, so it gets the text and Return as one line once it switches to raw mode, as with the old code.
   Not changed in code; the agent guide now says to send once the program's prompt shows (Decision 7).
2. **A busy canonical-mode program held the pane's writes for the full 2 seconds on each later send, a Control-C included.**
   Fixed: `unreadInput` counts nothing in canonical mode, pinned by `secondPartDoesNotWaitForAProgramThatReadsWholeLines`.
3. **`term send --enter` returned before Return went in**, so a `term read` right after showed the message unsent, and a `term close` right after dropped the Return.
   Fixed: `PtyProcess.write(_:then:)`, `Pane.type(_:enter:)`, and `sendToTerminal` are async and return once Return is written, pinned by `sendReturnsOnceReturnIsIn`.
4. **The 2-second patience could flake the tests on a loaded machine.**
   Fixed: the pty tests pass a patience of 60 s where they test the wait, and `TermSendTests` raise `Pane.returnPatience` to 60 s.
5. **Two missing tests.**
   Added `returnFollowsTextLongerThanTheInputQueue`, 3000 bytes over several reads, and `typingWhileReturnWaitsComesAfterIt`.
6. **The docs left out the 2-second cap.** The spec row, the agent guide, and `Pane.type` now say it.
7. **The `CPty.h` comment left out that FIONREAD counts nothing while fewer than VMIN bytes wait.** Added.
8. **The e2e readiness loop failed silently.** It now fails with "the read recorder did not start".

### Test runs under load

The merge-bar runs came while four other agents built and tested, with a load average of 20 to 38 on 18 cores and 11 of 12 GB of swap in use.
Three of six full runs of this branch failed, all in tests this branch does not touch: `PullRequestRowTests` with "gh did not answer in time" after its 30 s timeout, and helper scripts in `CloneTests`, `PullRequestWorkspaceTests`, and `WatchTests` not starting within 20 s.
Three runs of `origin/main` right after failed the same way in every run, with 36 to 43 issues each, so these are the machine and not this change.
