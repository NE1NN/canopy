# Canopy Terminal Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let agents list, open, type into, read, and close terminals with `canopy term`, and learn Canopy from `canopy agent-guide`.

**Architecture:** Five control methods (`term.list`, `term.new`, `term.send`, `term.read`, `term.close`) run on the main actor through `RowLifecycle`, where terminals live.
The emulator interface gains plain-text reads of the screen and of recent lines with scrollback.
The control socket first gets the three fixes carried over from PR 4's review, since `canopy term` leans on it hardest.

**Tech Stack:** Swift 6.2, swift-argument-parser, Network.framework, SwiftTerm 1.20.0, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Control API".

## Global Constraints

The constraints of the terminals and grid plans still hold.
`canopy term` resolves its row like the other commands. `term list` shows the resolved row's terminals, or every terminal with `--all` or when no row resolves.
`--tab` and `--new-tab` are mutually exclusive. A busy terminal closes only with `--force`.
`canopy agent-guide` works without the app running.

## Review Focus

1. **A client that closes its write side right after sending** must still get its reply. Pinned by `halfClosedConnectionsStillGetTheirReply` in Task 1.
2. **Pipelined requests** must be answered in order even when an earlier one is slower. Pinned by `repliesComeInRequestOrder` in Task 1.
3. **A runaway line with no newline** must be refused rather than buffered without end. Pinned by `overLongLinesAreRejected` in Task 1.
4. **Closing a terminal that is running a program** must refuse without `--force`. Pinned by `termCommandsDriveTerminals` in Task 2.
5. **Reading a real terminal's screen** through the app must show what the program printed. Pinned by the `canopy term` step of `scripts/e2e.sh` in Task 3.

---

## Task 1: Answer every control request, in order, before closing

Fixes carried-over review minors 1, 3, and 9.

**Files:** Modify `Sources/CanopyCore/Control/ControlServer.swift`, `Sources/CanopyCore/Control/ControlClient.swift`. Test `Tests/CanopyCoreTests/ControlServerTests.swift`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlServerTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -178,6 +178,84 @@ struct ControlServerTests {
         #expect(response.error?.code == "bad_request")
     }
 
+    /// Sends `payload` on a raw connection, optionally closes the write side, and reads until `lines` replies arrive.
+    func exchange(_ socketPath: String, _ payload: Data, halfClose: Bool = false, lines: Int = 1) async throws
+        -> [String]
+    {
+        try await offPool {
+            let fd = try ControlClient.connect(to: socketPath)
+            defer { close(fd) }
+            var timeout = timeval(tv_sec: 10, tv_usec: 0)
+            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
+            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
+            if halfClose { shutdown(fd, SHUT_WR) }
+            var received = Data()
+            var chunk = [UInt8](repeating: 0, count: 65_536)
+            while received.filter({ $0 == 0x0A }).count < lines {
+                let count = read(fd, &chunk, chunk.count)
+                guard count > 0 else { break }
+                received.append(contentsOf: chunk[0..<count])
+            }
+            return String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
+        }
+    }
+
+    @Test func halfClosedConnectionsStillGetTheirReply() async throws {
+        let dir = try TempDir()
+        let home = CanopyHome(path: dir.sub("home"))
+        try home.ensureExists()
+        let server = ControlServer(socketPath: home.socketPath) { request in
+            try? await Task.sleep(for: .milliseconds(200))
+            return .success(id: request.id, result: .bool(true))
+        }
+        try await server.start()
+        defer { server.stop() }
+
+        let replies = try await exchange(
+            home.socketPath, try ControlCodec.encodeLine(ControlRequest(method: "slow", id: "a")), halfClose: true)
+
+        #expect(replies.count == 1)
+        #expect(replies.first?.contains(#""id":"a""#) == true)
+    }
+
+    @Test func repliesComeInRequestOrder() async throws {
+        let dir = try TempDir()
+        let home = CanopyHome(path: dir.sub("home"))
+        try home.ensureExists()
+        let server = ControlServer(socketPath: home.socketPath) { request in
+            if request.id == "first" { try? await Task.sleep(for: .milliseconds(300)) }
+            return .success(id: request.id, result: .null)
+        }
+        try await server.start()
+        defer { server.stop() }
+        var payload = try ControlCodec.encodeLine(ControlRequest(method: "x", id: "first"))
+        payload.append(try ControlCodec.encodeLine(ControlRequest(method: "x", id: "second")))
+
+        let replies = try await exchange(home.socketPath, payload, lines: 2)
+
+        #expect(replies.map { $0.contains(#""id":"first""#) } == [true, false])
+    }
+
+    @Test func overLongLinesAreRejected() async throws {
+        let dir = try TempDir()
+        let home = CanopyHome(path: dir.sub("home"))
+        try home.ensureExists()
+        let server = ControlServer(socketPath: home.socketPath) { .success(id: $0.id, result: .null) }
+        try await server.start()
+        defer { server.stop() }
+
+        let replies = try await exchange(home.socketPath, Data(repeating: 0x61, count: (1 << 20) + 10))
+
+        #expect(replies.first?.contains("bad_request") == true)
+    }
+
+    @Test func serverRejectsASocketPathOverTheLimit() async {
+        let path = "/tmp/" + String(repeating: "x", count: 120) + "/canopy.sock"
+        await #expect(throws: ControlServerError.socketPathTooLong(path)) {
+            try await ControlServer(socketPath: path) { .success(id: $0.id, result: .null) }.start()
+        }
+    }
+
     @Test func socketPathOverTheLimitFailsClearly() {
         let path = "/tmp/" + String(repeating: "x", count: 120) + "/canopy.sock"
         #expect(throws: ControlClientError.socketPathTooLong(path)) {
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ControlServerTests`
Expected: `halfClosedConnectionsStillGetTheirReply` and `overLongLinesAreRejected` fail, and the path test does not compile (`socketPathTooLong` is missing).

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Control/ControlClient.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/ControlClient.swift
+++ b/Sources/CanopyCore/Control/ControlClient.swift
@@ -54,6 +54,7 @@ public struct ControlClient: Sendable {
             var offset = 0
             while offset < raw.count {
                 let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
+                if written < 0 && errno == EINTR { continue }
                 if written < 0 { throw ControlClientError.writeFailed(errno: errno) }
                 offset += written
             }
@@ -64,6 +65,7 @@ public struct ControlClient: Sendable {
         while !received.contains(0x0A) {
             let count = read(fd, &chunk, chunk.count)
             if count == 0 { throw ControlClientError.connectionClosed }
+            if count < 0 && errno == EINTR { continue }
             if count < 0 {
                 throw errno == EAGAIN ? ControlClientError.timedOut : ControlClientError.connectionClosed
             }
```

`Sources/CanopyCore/Control/ControlServer.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/ControlServer.swift
+++ b/Sources/CanopyCore/Control/ControlServer.swift
@@ -4,10 +4,12 @@ import Synchronization
 
 public enum ControlServerError: Error, Equatable, CustomStringConvertible {
     case alreadyRunning(String)
+    case socketPathTooLong(String)
 
     public var description: String {
         switch self {
         case .alreadyRunning(let path): "Another Canopy is already listening on \(path)."
+        case .socketPathTooLong(let path): "Socket path is longer than macOS allows: \(path)"
         }
     }
 }
@@ -27,6 +29,8 @@ public final class ControlServer: Sendable {
     }
 
     public func start() async throws {
+        // sockaddr_un holds 104 bytes including the terminator. A longer path would bind somewhere else.
+        guard socketPath.utf8.count < 104 else { throw ControlServerError.socketPathTooLong(socketPath) }
         if FileManager.default.fileExists(atPath: socketPath) {
             if ControlClient.canConnect(socketPath: socketPath) {
                 throw ControlServerError.alreadyRunning(socketPath)
@@ -81,10 +85,15 @@ private final class ResumeOnce: Sendable {
 }
 
 private final class ControlConnection: Sendable {
+    /// A line longer than this is not a request anyone meant to send.
+    static let maximumLine = 1 << 20
+
     private let connection: NWConnection
     private let queue: DispatchQueue
     private let handler: ControlServer.Handler
     private let buffer = Mutex(Data())
+    /// The last reply in line. Requests are handled at once but answered in the order they came.
+    private let lastReply = Mutex<Task<Void, Never>?>(nil)
 
     init(connection: NWConnection, queue: DispatchQueue, handler: @escaping ControlServer.Handler) {
         self.connection = connection
@@ -103,7 +112,12 @@ private final class ControlConnection: Sendable {
                 self.consume(data)
             }
             if isComplete || error != nil {
-                self.connection.cancel()
+                // The client may close its side right after sending, so answer what came in before closing.
+                let pending = self.lastReply.withLock { $0 }
+                Task {
+                    await pending?.value
+                    self.connection.cancel()
+                }
             } else {
                 self.receive()
             }
@@ -120,19 +134,51 @@ private final class ControlConnection: Sendable {
             }
             return lines
         }
+        if buffer.withLock({ $0.count > Self.maximumLine }) {
+            reply(
+                ControlResponse.failure(
+                    id: "", error: ControlError(code: "bad_request", message: "Request is too long.")))
+            let pending = lastReply.withLock { $0 }
+            Task {
+                await pending?.value
+                self.connection.cancel()
+            }
+            return
+        }
         for line in lines where !line.isEmpty {
-            Task { await self.respond(to: line) }
+            let response = Task { await self.response(to: line) }
+            lastReply.withLock { last in
+                let previous = last
+                last = Task {
+                    await previous?.value
+                    await self.send(await response.value)
+                }
+            }
         }
     }
 
-    private func respond(to line: Data) async {
-        let response: ControlResponse
-        if let request = try? ControlCodec.decode(ControlRequest.self, from: line) {
-            response = await handler(request)
-        } else {
-            response = .failure(id: "", error: ControlError(code: "bad_request", message: "Request is not valid JSON."))
+    private func reply(_ response: ControlResponse) {
+        lastReply.withLock { last in
+            let previous = last
+            last = Task {
+                await previous?.value
+                await self.send(response)
+            }
+        }
+    }
+
+    private func response(to line: Data) async -> ControlResponse {
+        guard let request = try? ControlCodec.decode(ControlRequest.self, from: line) else {
+            return .failure(id: "", error: ControlError(code: "bad_request", message: "Request is not valid JSON."))
         }
+        return await handler(request)
+    }
+
+    /// Returns once the reply has left, so closing the connection afterwards cannot drop it.
+    private func send(_ response: ControlResponse) async {
         guard let data = try? ControlCodec.encodeLine(response) else { return }
-        connection.send(content: data, completion: .contentProcessed { _ in })
+        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
+            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
+        }
     }
 }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times. Expected: every run passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "fix: answer every control request, in order, before closing"
```

## Task 2: Terminal methods in the control API

**Files:** Create `Sources/CanopyCore/Control/TermMethods.swift`, `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`. Modify `TerminalEmulator.swift`, `Pane.swift`, `TerminalStore.swift`, `WorkspaceError.swift`, `WorkspaceControlHandler.swift`, `SwiftTermEmulator.swift`, `AppModel.swift`, and the test fake.

**Interfaces:** `TermMethod`, `TermInfo`, `TermListParams`, `TermNewParams`, `TermNewResult`, `TermSendParams`, `TermReadParams`, `TermReadResult`, `TermCloseParams`; `TerminalEmulator.screenText()`, `recentText(lines:)`; `Pane.fixedTitle`, `Pane.type(_:)`; `TerminalStore.fits`, `openTerminal(for:tabNamed:newTab:)`; `RowLifecycle.terminalInfo`, `newTerminal`, `sendToTerminal`, `readTerminal`, `closeTerminal`; errors `pane_not_found` and `pane_busy`.

- [ ] **Step 1: Write the failing test**

`Tests/CanopyCoreTests/ControlServerTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -138,6 +138,56 @@ struct ControlServerTests {
             ]), as: RowRemoveResult.self)
     }
 
+    @Test func termCommandsDriveTerminals() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let (_, server, client, _) = try await startServer(dir)
+        defer { server.stop() }
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+        let target = TargetHint(repo: "demo", row: "main")
+        func read(_ pane: String) async -> String {
+            (try? await call(client, TermMethod.read, TermReadParams(pane: pane), as: TermReadResult.self))?.text ?? ""
+        }
+
+        let first = try await call(
+            client, TermMethod.new, TermNewParams(target: target, title: "Server"), as: TermNewResult.self)
+        let second = try await call(
+            client, TermMethod.new, TermNewParams(target: target, run: "echo from-second"), as: TermNewResult.self)
+        #expect(first.tab == second.tab)
+        #expect(await eventually { await read(second.pane).contains("from-second") })
+
+        _ = try await call(
+            client, TermMethod.send, TermSendParams(pane: first.pane, text: "echo typed-in", enter: true),
+            as: JSONValue.self)
+        #expect(await eventually { await read(first.pane).contains("typed-in") })
+
+        let listed = try await call(client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
+        #expect(listed.map(\.pane) == [first.pane, second.pane])
+        #expect(listed.first?.title == "Server")
+        #expect(listed.first?.folder == repo)
+
+        _ = try await call(
+            client, TermMethod.send, TermSendParams(pane: second.pane, text: "sleep 30", enter: true),
+            as: JSONValue.self)
+        #expect(
+            await eventually {
+                let panes = try? await call(client, TermMethod.list, TermListParams(all: true), as: [TermInfo].self)
+                return panes?.last?.foreground == "sleep"
+            })
+        await #expect(throws: ControlError.self) {
+            try await call(client, TermMethod.close, TermCloseParams(pane: second.pane), as: JSONValue.self)
+        }
+        for pane in [first.pane, second.pane] {
+            _ = try await call(client, TermMethod.close, TermCloseParams(pane: pane, force: true), as: JSONValue.self)
+        }
+        #expect(try await call(client, TermMethod.list, TermListParams(all: true), as: [TermInfo].self).isEmpty)
+
+        let missing = try await offPool {
+            try client.send(ControlRequest(method: TermMethod.read, params: try .from(TermReadParams(pane: "p999"))))
+        }
+        #expect(missing.error?.code == "pane_not_found")
+    }
+
     @Test func errorsCarryCodes() async throws {
         let dir = try TempDir()
         let (_, server, client, _) = try await startServer(dir)
```

`Tests/CanopyCoreTests/Support/FakeTerminal.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/Support/FakeTerminal.swift
+++ b/Tests/CanopyCoreTests/Support/FakeTerminal.swift
@@ -17,6 +17,21 @@ final class FakeEmulator: TerminalEmulator {
         shown.append(data)
     }
 
+    /// What a terminal would show, roughly: escape sequences removed and lines split on newlines.
+    var lines: [String] {
+        let plain = text.replacingOccurrences(of: "\u{1b}\\[[0-9;?!]*[A-Za-z]", with: "", options: .regularExpression)
+            .replacingOccurrences(of: "\r", with: "")
+        return TerminalText.trimmingTrailingBlankLines(plain.components(separatedBy: "\n"))
+    }
+
+    func screenText() -> String {
+        lines.suffix(size.rows).joined(separator: "\n")
+    }
+
+    func recentText(lines count: Int) -> String {
+        lines.suffix(count).joined(separator: "\n")
+    }
+
     func type(_ text: String) {
         onInput?(Data(text.utf8))
     }
```

- [ ] **Step 2: Run it to see it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter termCommandsDriveTerminals`
Expected: build failure, `cannot find 'TermMethod' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -236,7 +236,9 @@ final class AppModel {
     // MARK: Grid
 
     /// The size of the selected tab's grid, for the add rule and for finding neighbors.
-    var gridSize = CGSize(width: 1000, height: 700)
+    var gridSize = CGSize(width: 1000, height: 700) {
+        didSet { terminals.fits = addRuleFits() }
+    }
     @ObservationIgnored private lazy var config = GlobalConfig.load(from: home.configFile)
 
     /// The least room a pane may shrink to: 20 columns and 5 rows, plus its padding and header.
@@ -251,12 +253,17 @@ final class AppModel {
     /// ⌘D. Adds a pane by the add rule, keeping panes at least `minPaneColumns` wide on a line.
     func splitPane() {
         guard let row = selectedRow, !row.isMissing else { return }
+        terminals.addPane(for: context(for: row), fits: addRuleFits())
+        focusSelectedTerminal()
+    }
+
+    /// Whether a line of that many panes keeps each at least `minPaneColumns` wide in the current grid.
+    private func addRuleFits() -> (Int) -> Bool {
         let padding = TerminalContainerView.padding
         let minimumWidth =
             Double(config.minPaneColumns) * SwiftTermEmulator.cellSize.width + padding.left + padding.right
         let width = gridSize.width
-        terminals.addPane(for: context(for: row), fits: { width / Double($0) >= minimumWidth })
-        focusSelectedTerminal()
+        return { width / Double($0) >= minimumWidth }
     }
 
     /// ⌘⌥ and an arrow.
```

`Sources/CanopyApp/Terminal/SwiftTermEmulator.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
+++ b/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
@@ -45,6 +45,21 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         return TerminalSize(columns: terminal.cols, rows: terminal.rows)
     }
 
+    func screenText() -> String {
+        let terminal = terminalView.getTerminal()
+        let rows = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
+        return TerminalText.trimmingTrailingBlankLines(rows).joined(separator: "\n")
+    }
+
+    func recentText(lines count: Int) -> String {
+        let text = String(decoding: terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
+        let lines = TerminalText.trimmingTrailingBlankLines(
+            text.components(separatedBy: "\n").map {
+                $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
+            })
+        return lines.suffix(max(count, 0)).joined(separator: "\n")
+    }
+
     /// Gives the terminal the keyboard, if it is on screen.
     func focus() {
         view.window?.makeFirstResponder(view)
```

`Sources/CanopyCore/Control/TermMethods.swift` (new):

```swift
public enum TermMethod {
    public static let list = "term.list"
    public static let new = "term.new"
    public static let send = "term.send"
    public static let read = "term.read"
    public static let close = "term.close"
}

/// One terminal as `canopy term list` shows it.
public struct TermInfo: Codable, Sendable, Equatable {
    public var pane: String
    public var repo: String
    public var row: String
    public var rowPath: String
    public var tab: String
    public var title: String
    public var folder: String
    /// The program in the foreground, such as `claude`, or the shell when it is idle.
    public var foreground: String?
    public var exited: Int32?
}

public struct TermListParams: Codable, Sendable {
    public var target: TargetHint
    public var all: Bool

    public init(target: TargetHint = TargetHint(), all: Bool = false) {
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct TermNewParams: Codable, Sendable {
    public var target: TargetHint
    /// Adds the pane to the tab with this name, opening it if the row has none.
    public var tab: String?
    public var newTab: Bool
    public var run: String?
    public var title: String?

    public init(
        target: TargetHint = TargetHint(), tab: String? = nil, newTab: Bool = false, run: String? = nil,
        title: String? = nil
    ) {
        self.target = target
        self.tab = tab
        self.newTab = newTab
        self.run = run
        self.title = title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        tab = try container.decodeIfPresent(String.self, forKey: .tab)
        newTab = try container.decodeIfPresent(Bool.self, forKey: .newTab) ?? false
        run = try container.decodeIfPresent(String.self, forKey: .run)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

public struct TermNewResult: Codable, Sendable, Equatable {
    public var pane: String
    public var tab: String
}

public struct TermSendParams: Codable, Sendable {
    public var pane: String
    public var text: String
    public var enter: Bool

    public init(pane: String, text: String, enter: Bool = false) {
        self.pane = pane
        self.text = text
        self.enter = enter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        text = try container.decode(String.self, forKey: .text)
        enter = try container.decodeIfPresent(Bool.self, forKey: .enter) ?? false
    }
}

public struct TermReadParams: Codable, Sendable {
    public var pane: String
    /// The last this many lines, scrollback included. Nil reads the visible screen.
    public var lines: Int?

    public init(pane: String, lines: Int? = nil) {
        self.pane = pane
        self.lines = lines
    }
}

public struct TermReadResult: Codable, Sendable, Equatable {
    public var text: String
}

public struct TermCloseParams: Codable, Sendable {
    public var pane: String
    public var force: Bool

    public init(pane: String, force: Bool = false) {
        self.pane = pane
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
+++ b/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
@@ -102,6 +102,35 @@ public struct WorkspaceControlHandler: Sendable {
             let params = try request.decodeParams(RowAdoptParams.self)
             return try .from(try await workspace.adopt(path: params.path))
 
+        case TermMethod.list:
+            let params = try request.decodeParams(TermListParams.self)
+            let snapshot = await workspace.snapshot
+            // Every row's terminals with --all, or when no row resolves.
+            let row = params.all ? nil : try? TargetResolver.row(for: params.target, in: snapshot)
+            let names = Dictionary(snapshot.repos.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
+            return try .from(await rows.terminalInfo(rowPath: row?.path, repoNames: names))
+
+        case TermMethod.new:
+            let params = try request.decodeParams(TermNewParams.self)
+            let snapshot = await workspace.snapshot
+            let row = try TargetResolver.row(for: params.target, in: snapshot)
+            guard !row.isMissing else { throw WorkspaceError.pathNotFound(row.path) }
+            let repoName = snapshot.repo(path: row.repoPath)?.name ?? ""
+            return try .from(await rows.newTerminal(row, repoName: repoName, params))
+
+        case TermMethod.send:
+            let params = try request.decodeParams(TermSendParams.self)
+            try await rows.sendToTerminal(params)
+            return .object(["pane": .string(params.pane)])
+
+        case TermMethod.read:
+            return try .from(try await rows.readTerminal(request.decodeParams(TermReadParams.self)))
+
+        case TermMethod.close:
+            let params = try request.decodeParams(TermCloseParams.self)
+            try await rows.closeTerminal(params)
+            return .object(["pane": .string(params.pane)])
+
         default:
             throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
         }
```

`Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift` (new):

```swift
import Foundation

/// What `canopy term` does, on the main actor where terminals live.
extension RowLifecycle {
    /// Terminals in one row, or in every row when `rowPath` is nil.
    public func terminalInfo(rowPath: String?, repoNames: [String: String]) -> [TermInfo] {
        let paths = rowPath.map { [$0] } ?? terminals.tabsByRow.keys.sorted()
        return paths.flatMap { path in
            terminals.tabs(inRow: path).flatMap { tab in
                tab.paneList.map { pane in
                    pane.refreshTitle()
                    var exited: Int32?
                    if case .exited(let code) = pane.status { exited = code }
                    return TermInfo(
                        pane: pane.id.description, repo: repoNames[pane.context.repoPath] ?? pane.context.repoName,
                        row: pane.context.rowName, rowPath: path, tab: tab.name, title: pane.title,
                        folder: pane.currentDirectory ?? pane.startDirectory ?? path,
                        foreground: pane.foreground?.name, exited: exited)
                }
            }
        }
    }

    public func newTerminal(_ row: Row, repoName: String, _ params: TermNewParams) async -> TermNewResult {
        let context = PaneContext(row: row, repoName: repoName)
        let (tab, pane) = terminals.openTerminal(for: context, tabNamed: params.tab, newTab: params.newTab)
        if let title = params.title { pane.fixedTitle = title }
        if let run = params.run { await pane.run(run) }
        return TermNewResult(pane: pane.id.description, tab: tab.name)
    }

    public func sendToTerminal(_ params: TermSendParams) throws {
        let pane = try terminal(params.pane)
        pane.type(params.text + (params.enter ? "\r" : ""))
    }

    public func readTerminal(_ params: TermReadParams) throws -> TermReadResult {
        let pane = try terminal(params.pane)
        let text = params.lines.map { pane.emulator.recentText(lines: $0) } ?? pane.emulator.screenText()
        return TermReadResult(text: text)
    }

    public func closeTerminal(_ params: TermCloseParams) throws {
        let pane = try terminal(params.pane)
        if pane.isBusy, !params.force {
            throw WorkspaceError.paneBusy(params.pane, program: pane.foreground?.name ?? "A program")
        }
        terminals.closePane(pane.id)
    }

    private func terminal(_ id: String) throws -> Pane {
        guard let paneID = PaneID(id), let pane = terminals.pane(paneID) else { throw WorkspaceError.paneNotFound(id) }
        return pane
    }
}
```

`Sources/CanopyCore/Terminal/Pane.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/Pane.swift
+++ b/Sources/CanopyCore/Terminal/Pane.swift
@@ -19,6 +19,10 @@ public final class Pane: Identifiable {
     public let emulator: any TerminalEmulator
     public private(set) var status = Status.running
     public private(set) var title = ""
+    /// A title given with `canopy term new --title`. It wins over what the program sets.
+    public var fixedTitle: String? {
+        didSet { refreshTitle() }
+    }
     @ObservationIgnored private let settings: ShellSettings
     @ObservationIgnored private var process: PtyProcess?
     @ObservationIgnored private var programTitle: ProgramTitle?
@@ -70,6 +74,12 @@ public final class Pane: Identifiable {
         process?.write(command + "\r")
     }
 
+    /// Sends text as if typed, for `canopy term send`. An exited pane ignores it.
+    public func type(_ text: String) {
+        guard case .running = status else { return }
+        process?.write(text)
+    }
+
     /// Starts a new shell in the same folder after the last one exited.
     public func restart() {
         guard case .exited = status, !isClosed else { return }
@@ -92,6 +102,10 @@ public final class Pane: Identifiable {
     /// Reads the foreground process again. The app calls it while the pane is on screen.
     /// A pane whose process exited keeps its last title.
     public func refreshTitle() {
+        if let fixedTitle {
+            title = fixedTitle
+            return
+        }
         guard let process else { return }
         let resolved = PaneTitle.resolve(programTitle, foreground: process.foreground)
         if !resolved.isEmpty {
```

`Sources/CanopyCore/Terminal/TerminalEmulator.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/TerminalEmulator.swift
+++ b/Sources/CanopyCore/Terminal/TerminalEmulator.swift
@@ -14,6 +14,10 @@ public protocol TerminalEmulator: AnyObject {
     var onTitle: ((String) -> Void)? { get set }
     /// Shows what the process wrote.
     func feed(_ data: Data)
+    /// The visible screen as plain text, one line per row, without trailing blank lines.
+    func screenText() -> String
+    /// The last `count` lines, scrollback included, as plain text.
+    func recentText(lines count: Int) -> String
 }
 
 @MainActor
@@ -90,3 +94,13 @@ public enum BusyTerminals {
             : "\(names.count) terminals are running processes: \(list). Quitting stops them."
     }
 }
+
+public enum TerminalText {
+    public static func trimmingTrailingBlankLines(_ lines: [String]) -> [String] {
+        var lines = lines
+        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
+            lines.removeLast()
+        }
+        return lines
+    }
+}
```

`Sources/CanopyCore/Terminal/TerminalStore.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/TerminalStore.swift
+++ b/Sources/CanopyCore/Terminal/TerminalStore.swift
@@ -45,6 +45,9 @@ public final class TerminalStore {
     public var preferredSize = TerminalSize.standard
     /// Called after any change worth saving: tabs, names, layouts, focus, or selection.
     @ObservationIgnored public var onChange: () -> Void = {}
+    /// The add rule's width check for panes added without the window's help, as by `canopy term new`.
+    /// The app keeps it in step with the grid's width.
+    @ObservationIgnored public var fits: (Int) -> Bool = { $0 <= 2 }
     @ObservationIgnored public let settings: ShellSettings
     @ObservationIgnored private let engine: any TerminalEngine
     @ObservationIgnored private var nextPane = 1
@@ -157,6 +160,22 @@ public final class TerminalStore {
         guard let tab = selectedTab(inRow: context.rowPath) else {
             return openTab(for: context).focused
         }
+        return addPane(to: tab, for: context, fits: fits)
+    }
+
+    /// Opens a terminal where `canopy term new` asks: in a new tab, in the tab with `name` (opening it if the row
+    /// has none by that name), or in the row's selected tab.
+    public func openTerminal(for context: PaneContext, tabNamed name: String?, newTab: Bool) -> (TerminalTab, Pane) {
+        let named = name.flatMap { name in tabs(inRow: context.rowPath).first { $0.name == name } }
+        if newTab || (name != nil && named == nil) || selectedTab(inRow: context.rowPath) == nil {
+            let tab = openTab(for: context, name: name)
+            return (tab, tab.focused)
+        }
+        let tab = named ?? selectedTab(inRow: context.rowPath)!
+        return (tab, addPane(to: tab, for: context, fits: fits))
+    }
+
+    private func addPane(to tab: TerminalTab, for context: PaneContext, fits: (Int) -> Bool) -> Pane {
         let pane = makePane(context, command: .shell, directory: nil)
         tab.panes[pane.id] = pane
         tab.layout = tab.layout.adding(pane.id, fits: fits)
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/WorkspaceError.swift
+++ b/Sources/CanopyCore/Workspace/WorkspaceError.swift
@@ -17,6 +17,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case badConfig(String, reason: String)
     case teardownFailed(Int32)
     case teardownStopped
+    case paneNotFound(String)
+    case paneBusy(String, program: String)
     case git(GitError)
 
     public var code: String {
@@ -39,6 +41,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .badConfig: "bad_config"
         case .teardownFailed: "teardown_failed"
         case .teardownStopped: "teardown_stopped"
+        case .paneNotFound: "pane_not_found"
+        case .paneBusy: "pane_busy"
         case .git: "git_failed"
         }
     }
@@ -65,6 +69,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .teardownFailed(let code):
             "Teardown failed with exit code \(code). Its tab shows why. Pass --force to remove the row anyway."
         case .teardownStopped: "Teardown stopped because its tab was closed. The row was not removed."
+        case .paneNotFound(let id): "No terminal \(id). Run `canopy term list --all`."
+        case .paneBusy(let id, let program): "\(program) is still running in \(id). Pass --force to close it anyway."
         case .git(let error): error.description
         }
     }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times. Expected: every run passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: list, open, type into, read, and close terminals over the control API"
```

## Task 3: `canopy term` and `canopy agent-guide`

**Files:** Create `Sources/CanopyCLI/TermCommand.swift`, `Sources/CanopyCLI/AgentGuide.swift`. Modify `Sources/CanopyCLI/CanopyCLI.swift`, `scripts/e2e.sh`.

- [ ] **Step 1: Write the commands and the e2e steps**

`Sources/CanopyCLI/AgentGuide.swift` (new):

```swift
import ArgumentParser

struct AgentGuide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide", abstract: "Print a manual for agents driving Canopy.")

    func run() {
        print(Self.text)
    }

    static let text = """
        # Canopy for agents

        Canopy shows git worktrees as rows, each with tabs of terminals. You drive it with `canopy`.
        Add `--json` to any command for machine-readable output. Every command exits non-zero on failure,
        and with `--json` prints {"error": {"code", "message"}}.

        ## Where commands act

        Commands about a repo or row use, in order: `--repo` and `--row` (or a row argument, a branch or a path),
        then CANOPY_REPO and CANOPY_ROW_PATH from your environment, then the worktree containing your current folder.
        Inside a Canopy terminal you rarely need flags. CANOPY_PANE is your own terminal's ID, such as p12.

        ## Rows

            canopy row list [--all]                       rows, and other tools' worktrees with --all
            canopy row new <branch> [--from <ref>] [--run <cmd>] [--no-setup] [--select]
            canopy row rm [<branch>] [--force] [--delete-branch]
            canopy row select [<branch>]

        `row new` creates the branch and worktree, runs the repo's setup commands from .canopy/config.json in a
        Setup tab, waits for them, then types `--run` into a new terminal. If setup fails, the row stays, the
        command is not run, and `row new` exits 1. `row rm` runs teardown first, then removes the worktree.

        ## Terminals

            canopy term list [--all]                      ID, row, tab, process, title, and folder
            canopy term new [--tab <name> | --new-tab] [--run <cmd>] [--title <t>]
            canopy term send <id> <text> [--enter]        type text, then Return with --enter
            canopy term read <id> [--lines N]             the screen, or the last N lines with scrollback
            canopy term close <id> [--force]              --force if a program still runs in it

        ## Examples

        Start a parallel agent on a fix in its own row, then check on it:

            canopy row new fix/login-redirect --run 'claude "fix the login redirect, ticket FL-123"'
            canopy term list --row fix/login-redirect
            canopy term read p12 --lines 40

        Run a dev server next to your own terminal and watch it:

            canopy term new --tab Server --run 'bun dev' --title 'dev server'
            canopy term read p13

        Clean up when the work is merged:

            canopy row rm fix/login-redirect --delete-branch
        """
}
```

`Sources/CanopyCLI/CanopyCLI.swift` (modify):

```diff
--- a/Sources/CanopyCLI/CanopyCLI.swift
+++ b/Sources/CanopyCLI/CanopyCLI.swift
@@ -8,7 +8,7 @@ struct CanopyCLI: AsyncParsableCommand {
         commandName: "canopy",
         abstract: "Drive Canopy from the command line.",
         version: CanopyVersion.current,
-        subcommands: [Status.self, RepoCommand.self, RowCommand.self]
+        subcommands: [Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, AgentGuide.self]
     )
 }
```

`Sources/CanopyCLI/TermCommand.swift` (new):

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct TermCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "term",
        abstract: "Open, drive, and read terminals.",
        subcommands: [List.self, New.self, Send.self, Read.self, Close.self]
    )

    struct RowOptions: ParsableArguments {
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @Option(help: "Row branch or path. Defaults to the row you are in.")
        var row: String?

        var hint: TargetHint { Client.hint(repo: repo, row: row) }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the terminals in the row you are in, or in every row.")

        @OptionGroup var rowOptions: RowOptions
        @Flag(help: "List terminals in every row.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.list, TermListParams(target: rowOptions.hint, all: all))
            try client.print(result) {
                let panes = try result.decode([TermInfo].self)
                return Table.render(
                    ["ID", "ROW", "TAB", "PROCESS", "TITLE", "FOLDER"],
                    panes.map { pane in
                        let process = pane.exited.map { "exited (\($0))" } ?? pane.foreground ?? ""
                        return [pane.pane, pane.row, pane.tab, process, pane.title, pane.folder]
                    }
                )
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a terminal in the row you are in and optionally run a command in it.",
            discussion: "It joins the row's selected tab by the add rule unless --tab or --new-tab says otherwise."
        )

        @OptionGroup var rowOptions: RowOptions
        @Option(help: "Add it to the tab with this name, opening that tab if needed.")
        var tab: String?
        @Flag(help: "Open it in a new tab.")
        var newTab = false
        @Option(name: .customLong("run"), help: "Command to type into it once its shell is ready.")
        var command: String?
        @Option(help: "Title for its header instead of the running program's.")
        var title: String?
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if tab != nil && newTab { throw ValidationError("Pass --tab or --new-tab, not both.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                TermMethod.new,
                TermNewParams(target: rowOptions.hint, tab: tab, newTab: newTab, run: command, title: title))
            try client.print(result) {
                let opened = try result.decode(TermNewResult.self)
                return "Opened \(opened.pane) in tab \(opened.tab)."
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Type text into a terminal.")

        @Argument(help: "Terminal ID, such as p12.")
        var id: String
        @Argument(help: "Text to type.")
        var text: String
        @Flag(help: "Press Return after the text.")
        var enter = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.send, TermSendParams(pane: id, text: text, enter: enter))
            try client.print(result) { "Sent to \(id)." }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a terminal's screen, or its last lines including scrollback, as plain text.")

        @Argument(help: "Terminal ID, such as p12.")
        var id: String
        @Option(help: "Print the last this many lines, scrollback included, instead of the visible screen.")
        var lines: Int?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.read, TermReadParams(pane: id, lines: lines))
            try client.print(result) { try result.decode(TermReadResult.self).text }
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a terminal.")

        @Argument(help: "Terminal ID, such as p12.")
        var id: String
        @Flag(help: "Close it even while a program runs in it.")
        var force = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.close, TermCloseParams(pane: id, force: force))
            try client.print(result) { "Closed \(id)." }
        }
    }
}
```

`scripts/e2e.sh` (modify):

```diff
--- a/scripts/e2e.sh
+++ b/scripts/e2e.sh
@@ -147,6 +147,25 @@ done
 [[ ! -d "$CANOPY_HOME/worktrees/demo/feat-self" ]] || fail "the row's own agent could not remove it"
 grep -qx feat/self "$work/teardown.log" || fail "teardown did not run for the self-removed row"
 
+step "canopy term opens, types into, reads, lists, and closes terminals"
+"$cli" row new feat/term --repo demo --no-setup >/dev/null
+pane=$("$cli" term new --repo demo --row feat/term --run 'echo from-term' --json |
+    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
+wait_for_text() {
+    for _ in $(seq 1 100); do
+        "$cli" term read "$pane" | grep -q "$1" && return 0
+        sleep 0.1
+    done
+    return 1
+}
+wait_for_text from-term || fail "term read did not show the --run output"
+"$cli" term send "$pane" 'echo sent-text' --enter >/dev/null
+wait_for_text sent-text || fail "term send did not reach the terminal"
+"$cli" term list --repo demo --row feat/term --json | grep -q "\"$pane\"" || fail "term list is missing $pane"
+"$cli" term close "$pane" >/dev/null
+if "$cli" term list --all --json | grep -q "\"$pane\""; then fail "closed terminal is still listed"; fi
+"$cli" agent-guide | grep -q "canopy term read" || fail "agent-guide is missing term read"
+
 step "errors are machine-readable"
 if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
 grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"
```

- [ ] **Step 2: Run everything**

Run: `make lint && make build && make test && make e2e`
Expected: `e2e passed`, including the step "canopy term opens, types into, reads, lists, and closes terminals".

- [ ] **Step 3: Commit, push, and open the PR**

```bash
git add Sources scripts
git commit -m "feat: canopy term and canopy agent-guide"
git push -u origin feat/term-commands
```

## After Review

An independent review found no blockers. One commit on the branch, `fix: address review of terminal commands`, fixes what it found, and the branch is the reference for it:
- `term read` maps cells through the terminal, so wide and combined characters survive and empty cells read as spaces, and it reads the live screen rather than wherever the user scrolled.
- Pane IDs keep counting across launches (`AppState.nextPane`), and `term send`, `read`, and `close` never launch the app.
- `term list` reports a target that does not resolve instead of listing every terminal.
- A running setup or teardown counts as busy, sending to an exited pane is an error (`pane_exited`), and terminals opened from the CLI leave tab selection and focus alone.
- The control server stops reading after refusing an over-long line, and closes a connection that errored at once.
- The agent guide matches the CLI.
