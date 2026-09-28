# Canopy Activity Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record what happens in Canopy, and who did it, as one JSON line per event in a file per day, and print it with `canopy log`.

**Architecture:** `CanopyCore` gets one `ActivityLog` writer that appends on a dispatch queue of its own, so recording never waits for the disk.
The workspace logs repo, row, and PR changes by comparing each worktree list and PR lookup with the one before, and marks the rows it changes itself so each change is logged once with the right source.
Panes log terminals opening and exiting, and read the reports a small zsh startup shim prints after each command.
Who acted flows through a task-local `ActivitySource`, which the control API sets to `cli` for the work each request does.
`canopy log` reads the files directly, so it works while Canopy is not running.

**Tech Stack:** Swift 6.2, Foundation, zsh 5.9 (`preexec`, `precmd`, `zsh/datetime`), swift-argument-parser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Activity log", `CANOPY_HOME` under "Data folder", and `canopy log` under "Commands".

## Global Constraints

- Each event is one JSON line appended to `CANOPY_HOME/activity/<local date>.jsonl`.
  The folder has mode 0700 and the files 0600.
- Fields go in the order `ts`, `type`, `repo`, `row`, `path`, `source`, `data`.
  `ts` is local time with milliseconds and the UTC offset, such as `2026-09-27T21:15:03.123+10:00`.
- `source` is `ui`, `cli`, or `git` (detected from outside Canopy).
- One writer in the app serializes all appends.
  Readers skip a trailing partial line.
- Each row change is logged once with the right `source`.
- Command logging covers zsh panes only, leaves the user's setup unchanged, and `"logCommands": false` in `config.json` turns it off.
- `canopy log` reads the activity files directly, so it works while the app is not running.
- Never block a Swift concurrency thread: writes happen on a dispatch queue.

## Review Focus

1. **The user's own zsh setup must load unchanged under the shim**, including a `.zshenv` that moves `ZDOTDIR` elsewhere, the history file macOS sets up, and options such as `ksh_arrays` that change how arrays read.
   Pinned by `theUsersStartupFilesLoadAsUsual`, `aZDOTDIRSetInTheUsersZshenvIsFollowed`, and `theUsersOwnHooksKeepRunningWhateverTheirOptions` in Task 5.
2. **Commands holding `;`, `%`, newlines, or control characters** must be logged exactly as typed.
   Pinned by `decodesEncodedText` and the `echo 'a;b' "%d"` command in `commandsAreLoggedWithTheirExitCodeFolderAndDuration` in Task 5.
3. **A refresh that lands in the middle of a change**, such as `git worktree add` halfway through or the repo folder being moved, must not log a row twice, detached, or at the wrong path.
   Pinned by `aRowCanopyIsStillCreatingIsLoggedOnceItIsDone`, `aWorktreeGitIsStillCreatingIsLoggedOnceItIsDone`, and `aRepoMovedWhileGitListsItShowsAsMissing` in Task 2.
4. **Relaunching, a repo coming back after it went missing, or `gh` logging back in** must not log everything that already existed as new.
   Pinned by `rowsThatWereThereAtLaunchAreNotLogged` and `aRepoThatComesBackLogsOnlyWhatChangedWhileItWasGone` in Task 2, and `pullRequestsSeenAgainAfterAnOutageAreNotLoggedAsNew` in Task 3.
5. **Output that replays a report**, such as `cat` of a recorded session, must not log a command nobody ran.
   Pinned by `reportsWithoutTheShellsTokenAreIgnored` in Task 5.

---

## Task 1: Write activity events to a file per day

**Files:** Create `Sources/CanopyCore/Activity/ActivityEvent.swift`, `Sources/CanopyCore/Activity/ActivityLog.swift`.
Modify `JSONValue.swift` (string, integer, and boolean literals), `GlobalConfig.swift` (`logCommands`), and `CanopyHome.swift` (`activityFolder`).
Test `Tests/CanopyCoreTests/ActivityLogTests.swift`.

**Interfaces:** Produces `ActivitySource` (`ui`, `cli`, `git`, and the task-local `ActivitySource.current`), `ActivityType` constants such as `ActivityType.rowCreated`, `ActivityEvent` (`ts`, `type`, `repo`, `row`, `path`, `source`, `data: [String: JSONValue]`, `date`, and `ActivityEvent.timestamp(in:)`), `Calendar.localGregorian(in:)`, `ActivityLog(folder:logsCommands:)` with `record(_:repo:row:path:source:data:at:)`, `flush() async`, `flushNow()`, and `folder`, and `CanopyHome.activityFolder`.
The test helpers `activityLines(_:)` and `activityEvents(_:)` read a folder back.

`record` takes the time and picks the day's file when it is called, then hands the line to a serial queue, so events land in the order they were recorded and callers never wait for the disk.
Each append opens the file with `O_APPEND`, writes one whole line, and closes it, so a user deleting a file or a new day starting needs no bookkeeping.
`JSONEncoder` does not keep declaration order, so the line is put together field by field in the spec's order, with `data` keys sorted.
File names use the Gregorian calendar in the local time zone, whatever calendar the user picked.
The default source is `ActivitySource.current`, read in the caller's task: unstructured `Task {}` inherits it, so work a CLI request starts later, like setup finishing, stays `cli`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ActivityLogTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// The lines of every activity file in `folder`, oldest file first.
func activityLines(_ folder: URL) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return files.sorted().flatMap { file in
        ((try? String(contentsOf: folder.appending(path: file), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

func activityEvents(_ folder: URL) -> [ActivityEvent] {
    activityLines(folder).compactMap { try? JSONDecoder().decode(ActivityEvent.self, from: Data($0.utf8)) }
}

struct ActivityLogTests {
    @Test func writesOneLineInTheSpecsFieldOrder() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        log.record(
            ActivityType.rowCreated, repo: "demo", row: "fix/login", path: "/w/fix-login", source: .cli,
            data: ["class": "canopy"])
        await log.flush()

        let line = try #require(activityLines(log.folder).first)
        #expect(activityLines(log.folder).count == 1)
        let keys = ["ts", "type", "repo", "row", "path", "source", "data"].map { "\"\($0)\":" }
        let positions = try keys.map { key in try #require(line.range(of: key)).lowerBound }
        #expect(positions == positions.sorted())
        #expect(line.contains(#""source":"cli","data":{"class":"canopy"}}"#))
        let event = try #require(activityEvents(log.folder).first)
        #expect(event.ts.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}([+-]\d\d:\d\d|Z)/) != nil)
        #expect(event.date != nil)
        #expect(event.type == "row.created" && event.repo == "demo" && event.row == "fix/login")
    }

    @Test func leavesOutWhatAnEventIsNotAbout() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        log.record(ActivityType.cliCall, data: ["method": "term.send"])
        await log.flush()

        let line = try #require(activityLines(log.folder).first)
        #expect(!line.contains("\"repo\"") && !line.contains("\"row\"") && !line.contains("\"path\""))
    }

    @Test func filesAreNamedByLocalDateAndPrivate() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))
        let date = try #require(
            Calendar.localGregorian().date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 23)))

        log.record(ActivityType.repoAdded, repo: "demo", at: date)
        log.record(ActivityType.repoRemoved, repo: "demo", at: date.addingTimeInterval(3600))
        await log.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: log.folder.path).sorted()
        #expect(files == ["2026-09-27.jsonl", "2026-09-28.jsonl"])
        let file = try FileManager.default.attributesOfItem(atPath: log.folder.appending(path: files[0]).path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: log.folder.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func sourceIsTheUIUnlessACallerSaysOtherwise() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        log.record(ActivityType.repoAdded)
        await ActivitySource.$current.withValue(.cli) {
            log.record(ActivityType.repoAdded)
            // Work a CLI request starts later, such as setup finishing, keeps its source.
            await Task { log.record(ActivityType.repoAdded) }.value
        }
        await log.flush()

        #expect(activityEvents(log.folder).map(\.source) == [.ui, .cli, .cli])
    }

    @MainActor
    @Test func keepsTheOrderEventsWereRecordedIn() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        for number in 0..<200 {
            log.record(ActivityType.termOpened, data: ["pane": .string("p\(number)")])
        }
        await log.flush()

        #expect(activityEvents(log.folder).map(\.data["pane"]) == (0..<200).map { .string("p\($0)") })
    }

    @Test func commandsAreLeftOutWhenCommandLoggingIsOff() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")), logsCommands: false)

        log.record(ActivityType.termCommand, data: ["cmd": "export TOKEN=secret"])
        log.record(ActivityType.termExited, data: ["pane": "p1", "code": 0])
        await log.flush()

        #expect(activityEvents(log.folder).map(\.type) == ["term.exited"])
    }

    @Test func commandLoggingIsOnUnlessConfigTurnsItOff() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("config.json"))
        #expect(GlobalConfig.load(from: url).logCommands)

        try #"{"logCommands": false}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(!GlobalConfig.load(from: url).logCommands)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 80)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ActivityLogTests`
Expected: does not compile, `ActivityLog`, `ActivityEvent`, and `ActivityType` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Activity/ActivityEvent.swift` (new):

```swift
import Foundation

/// Who made a change: the user in Canopy's window, an agent or script through `canopy`, or something outside Canopy.
public enum ActivitySource: String, Codable, Sendable {
    /// Canopy's window, including what is typed in its terminals.
    case ui
    /// A `canopy` command.
    case cli
    /// A change Canopy noticed rather than made, such as git run in any terminal, or a PR changing on GitHub.
    case git

    /// Who is acting now. The control API runs each request as `.cli`, and work a request starts inherits it.
    @TaskLocal public static var current = ActivitySource.ui
}

public enum ActivityType {
    public static let repoAdded = "repo.added"
    public static let repoRemoved = "repo.removed"
    public static let rowCreated = "row.created"
    public static let rowAdopted = "row.adopted"
    public static let rowRemoved = "row.removed"
    public static let rowBranchChanged = "row.branch_changed"
    public static let prOpened = "pr.opened"
    public static let prStateChanged = "pr.state_changed"
    public static let termOpened = "term.opened"
    public static let termExited = "term.exited"
    public static let termCommand = "term.command"
    public static let cliCall = "cli.call"
}

extension Calendar {
    /// Log files are named by local date in the Gregorian calendar, whatever calendar the user picked.
    static func localGregorian(in zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}

/// One line of the activity log.
public struct ActivityEvent: Codable, Sendable, Equatable {
    /// Local time with milliseconds and the UTC offset, such as 2026-09-27T21:15:03.123+10:00.
    public var ts: String
    public var type: String
    public var repo: String?
    public var row: String?
    public var path: String?
    public var source: ActivitySource
    public var data: [String: JSONValue]

    public init(
        date: Date, type: String, repo: String? = nil, row: String? = nil, path: String? = nil,
        source: ActivitySource, data: [String: JSONValue] = [:]
    ) {
        self.ts = date.formatted(Self.timestamp(in: .current))
        self.type = type
        self.repo = repo
        self.row = row
        self.path = path
        self.source = source
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decode(String.self, forKey: .ts)
        type = try container.decode(String.self, forKey: .type)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        row = try container.decodeIfPresent(String.self, forKey: .row)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        source = try container.decode(ActivitySource.self, forKey: .source)
        data = try container.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
    }

    public var date: Date? {
        try? Self.timestamp(in: .gmt).parse(ts)
    }

    /// How `ts` is written. Reading it back honors the offset it carries, whatever the zone here.
    static func timestamp(in zone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: zone)
    }

    /// The event as one line of JSON, with its fields in a fixed order so the files read well.
    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json(_ value: some Encodable) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var fields = [("ts", try json(ts)), ("type", try json(type))]
        for (key, value) in [("repo", repo), ("row", row), ("path", path)] {
            if let value { fields.append((key, try json(value))) }
        }
        fields += [("source", try json(source)), ("data", try json(data))]
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}
```

`Sources/CanopyCore/Activity/ActivityLog.swift` (new):

```swift
import Foundation

/// Appends activity events to one JSON Lines file per local day. Events are written one at a time on a queue of
/// their own, in the order they were recorded, so recording never waits for the disk.
public final class ActivityLog: Sendable {
    public let folder: URL
    /// False when config.json turns command logging off. `term.command` events are then dropped.
    public let logsCommands: Bool
    private let queue = DispatchQueue(label: "canopy.activity-log")

    public init(folder: URL, logsCommands: Bool = true) {
        self.folder = folder
        self.logsCommands = logsCommands
    }

    /// `date` stamps the event and picks the day's file. It is when `record` is called unless a test says otherwise.
    public func record(
        _ type: String, repo: String? = nil, row: String? = nil, path: String? = nil,
        source: ActivitySource = .current, data: [String: JSONValue] = [:], at date: Date = Date()
    ) {
        guard logsCommands || type != ActivityType.termCommand else { return }
        let event = ActivityEvent(date: date, type: type, repo: repo, row: row, path: path, source: source, data: data)
        let file = folder.appending(path: Self.fileName(for: date))
        queue.async { self.append(event, to: file) }
    }

    /// Returns once everything recorded so far is written.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Blocks until everything recorded so far is written, for quitting.
    public func flushNow() {
        queue.sync {}
    }

    /// Such as 2026-09-27.jsonl.
    static func fileName(for date: Date) -> String {
        let day = Calendar.localGregorian().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    private func append(_ event: ActivityEvent, to file: URL) {
        guard let line = try? event.jsonLine() else { return }
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
```

`Sources/CanopyCore/Control/JSONValue.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/JSONValue.swift
+++ b/Sources/CanopyCore/Control/JSONValue.swift
@@ -52,3 +52,17 @@ public enum JSONValue: Codable, Sendable, Equatable {
         try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
     }
 }
+
+extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
+    public init(stringLiteral value: String) {
+        self = .string(value)
+    }
+
+    public init(integerLiteral value: Int) {
+        self = .number(Double(value))
+    }
+
+    public init(booleanLiteral value: Bool) {
+        self = .bool(value)
+    }
+}
```

`Sources/CanopyCore/State/GlobalConfig.swift` (modify):

```diff
--- a/Sources/CanopyCore/State/GlobalConfig.swift
+++ b/Sources/CanopyCore/State/GlobalConfig.swift
@@ -4,14 +4,18 @@ import Foundation
 public struct GlobalConfig: Codable, Sendable, Equatable {
     /// The add rule starts a new line of panes rather than make any narrower than this many columns.
     public var minPaneColumns: Int
+    /// Whether commands run in zsh terminals go into the activity log. Commands can contain secrets.
+    public var logCommands: Bool
 
-    public init(minPaneColumns: Int = 80) {
+    public init(minPaneColumns: Int = 80, logCommands: Bool = true) {
         self.minPaneColumns = minPaneColumns
+        self.logCommands = logCommands
     }
 
     public init(from decoder: any Decoder) throws {
         let container = try decoder.container(keyedBy: CodingKeys.self)
         minPaneColumns = max(try container.decodeIfPresent(Int.self, forKey: .minPaneColumns) ?? 80, 20)
+        logCommands = try container.decodeIfPresent(Bool.self, forKey: .logCommands) ?? true
     }
 
     public static func load(from url: URL) -> GlobalConfig {
```

`Sources/CanopyCore/Support/CanopyHome.swift` (modify):

```diff
--- a/Sources/CanopyCore/Support/CanopyHome.swift
+++ b/Sources/CanopyCore/Support/CanopyHome.swift
@@ -36,6 +36,8 @@ public struct CanopyHome: Sendable, Equatable {
     public var stateFile: URL { root.appending(path: "state.json") }
     public var configFile: URL { root.appending(path: "config.json") }
     public var worktreesRoot: URL { root.appending(path: "worktrees") }
+    /// One JSON Lines file of activity events per local day.
+    public var activityFolder: URL { root.appending(path: "activity") }
     public var socketPath: String { root.appending(path: "canopy.sock").path }
     /// Held by the one app instance that owns this home.
     public var appLockPath: String { root.appending(path: "app.lock").path }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`.
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: write activity events to a file per day"
```

## Task 2: Log repo and row changes with who made them

**Files:** Modify `Sources/CanopyCore/Workspace/Workspace.swift` and `Workspace+RowLifecycle.swift`.
Test `Tests/CanopyCoreTests/RowActivityTests.swift`.

**Interfaces:**
- Consumes `ActivityLog`, `ActivityType`, and `ActivitySource.current` from Task 1.
- Produces `Workspace.activity` (a `nonisolated let`, and an `activity:` init parameter that defaults to a log in the home), `Workspace.record(_:_:source:data:)`, which fills `repo`, `row`, and `path` from a `Row`, and `Workspace.isBeingCreated(_:)`.
  The test helper `logged(_:_:)` flushes a workspace's log and returns its events of the given kinds.

Every successful worktree list is compared with the one before it, kept per repo in `rowBaselines`.
A path that appears is `row.created`, one that goes is `row.removed`, and a path whose branch differs is `row.branch_changed`, with `null` for a detached HEAD.
The first list after launch, adding, or relocating a repo has nothing to compare with and logs nothing, and a missing repo or failed list keeps the baseline, so a repo that comes back only logs what changed while it was gone.
git lists a worktree halfway through `git worktree add` with a detached, all-zero HEAD, so such a row waits until it is whole rather than being logged detached and then again when its branch lands.
A branch with no commits yet also has an all-zero HEAD, but it is named, so it is not held back.
Before Canopy runs `git worktree add`, `git worktree remove`, or `git worktree prune`, it puts the row's path in `changingRows` with `ActivitySource.current`, and refreshes leave that path out of the comparison.
When the operation ends, whether it worked or not, `finishChanging` logs how the row ended up against the baseline with that source, and takes it into the baseline.
A prune or remove that fails refreshes first, since git may have changed some rows before it failed.
If git reports the main checkout somewhere other than the registered path, the folder moved after git started in it, so that refresh shows the repo as missing instead of logging its main row as removed and created.
Adopting and un-adopting change only Canopy's own state, so they log directly, and class changes are not diffed.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/RowActivityTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// Everything the workspace logged so far, of the given kinds, such as "row".
func logged(_ workspace: Workspace, _ prefixes: String...) async -> [ActivityEvent] {
    await workspace.activity.flush()
    return activityEvents(workspace.activity.folder).filter { event in
        prefixes.contains { event.type.hasPrefix($0 + ".") }
    }
}

struct RowActivityTests {
    func setUp(_ dir: TempDir) async throws -> (Workspace, String) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (workspace, repo)
    }

    @Test func addingAndRemovingAReposAreLogged() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        try await workspace.addRepo(path: repo)
        try await workspace.removeRepo(path: repo)

        let events = await logged(workspace, "repo", "row")
        #expect(events.map(\.type) == ["repo.added", "repo.removed"])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.path == repo && $0.source == .ui })
    }

    @Test func rowsCanopyChangesAreLoggedOnceWithWhoAskedForThem() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)

        let first = try await workspace.createRow(repoPath: repo, branch: "feat/a").row
        let second = try await ActivitySource.$current.withValue(.cli) {
            try await workspace.createRow(repoPath: repo, branch: "feat/b").row
        }
        try await ActivitySource.$current.withValue(.cli) { _ = try await workspace.removeRow(path: first.path) }
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created", "row.created", "row.removed"])
        #expect(events.map(\.source) == [.ui, .cli, .cli])
        #expect(events.map(\.path) == [first.path, second.path, first.path])
        #expect(events.map(\.row) == ["feat/a", "feat/b", "feat/a"])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.data["class"] == "canopy" })
    }

    @Test func changesMadeWithPlainGitAreLoggedAsGit() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let path = dir.sub("elsewhere")

        try await Fixture.worktree(repo: repo, branch: "feat/x", at: path)
        await workspace.refresh(repoPath: repo)
        try await Fixture.git.run(["switch", "--quiet", "-c", "feat/y"], in: path)
        await workspace.refresh(repoPath: repo)
        try await Fixture.git.run(["switch", "--quiet", "--detach"], in: path)
        await workspace.refresh(repoPath: repo)
        try await Fixture.git.run(["worktree", "remove", path], in: repo)
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        try #require(events.map(\.type) == ["row.created", "row.branch_changed", "row.branch_changed", "row.removed"])
        #expect(events.allSatisfy { $0.source == .git && $0.path == path })
        #expect(events[0].data["class"] == "external")
        #expect(events[1].data == ["from": "feat/x", "to": "feat/y"])
        #expect(events[2].data == ["from": "feat/y", "to": .null])
    }

    @Test func rowsThatWereThereAtLaunchAreNotLogged() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        let first = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await first.start()
        try await first.addRepo(path: repo)
        await first.stop()

        let second = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await second.start()
        await second.refreshAll()

        #expect(await logged(second, "row").isEmpty)
    }

    @Test func aRepoThatComesBackLogsOnlyWhatChangedWhileItWasGone() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        _ = try await workspace.createRow(repoPath: repo, branch: "feat/a")

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.isMissing == true)
        try FileManager.default.moveItem(atPath: dir.sub("moved"), toPath: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await logged(workspace, "row").map(\.type) == ["row.created"])
    }

    @Test func aRowCanopyIsStillCreatingIsLoggedOnceItIsDone() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let path = dir.sub("home/worktrees/demo/feat-a")
        let paused = dir.sub("paused")
        // After adding the worktree, git leaves it detached until the test lets go, as if still setting it up.
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ $1 == worktree && $2 == add ]]; then
                    /usr/bin/git "$@" || exit
                    /usr/bin/git -C '\(path)' switch --quiet --detach
                    touch '\(paused)'
                    while [[ -f '\(paused)' ]]; do sleep 0.05; done
                    exec /usr/bin/git -C '\(path)' switch --quiet feat/a
                fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        async let created = ActivitySource.$current.withValue(.cli) {
            try await workspace.createRow(repoPath: repo, branch: "feat/a")
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: paused) })
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.row(path: path)?.branch == nil)
        try FileManager.default.removeItem(atPath: paused)
        _ = try await created
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created"])
        #expect(events.first?.row == "feat/a" && events.first?.source == .cli)
    }

    @Test func aWorktreeGitIsStillCreatingIsLoggedOnceItIsDone() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        try await Fixture.git.run(["branch", "feat/x"], in: repo)
        let path = dir.sub("elsewhere")
        let admin = repo + "/.git/worktrees/elsewhere"
        // How `git worktree add` leaves a worktree until it has checked the branch out: an all-zero HEAD. Written
        // HEAD first, so a refresh the watcher starts meanwhile never sees the worktree any other way.
        try FileManager.default.createDirectory(atPath: admin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try (String(repeating: "0", count: 40) + "\n").write(toFile: admin + "/HEAD", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: admin + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(admin)\n".write(toFile: path + "/.git", atomically: true, encoding: .utf8)
        try "\(path)/.git\n".write(toFile: admin + "/gitdir", atomically: true, encoding: .utf8)

        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.row(path: path) != nil)
        #expect(await logged(workspace, "row").isEmpty)
        try "ref: refs/heads/feat/x\n".write(toFile: admin + "/HEAD", atomically: true, encoding: .utf8)
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created"])
        #expect(events.first?.row == "feat/x" && events.first?.source == .git)
    }

    @Test func aRepoMovedWhileGitListsItShowsAsMissing() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let moveNow = dir.sub("move-now")
        // git follows its folder if it moves after git started in it, and reports the new place.
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ $1 == worktree && $2 == list && -f '\(moveNow)' ]]; then
                    rm '\(moveNow)'
                    mv "$PWD" '\(dir.sub("moved"))'
                fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        FileManager.default.createFile(atPath: moveNow, contents: Data())
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.isMissing == true)
        try FileManager.default.moveItem(atPath: dir.sub("moved"), toPath: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await workspace.snapshot.repos.first?.rows.map(\.path) == [repo])
        #expect(await logged(workspace, "row").isEmpty)
    }

    @Test func adoptingAndUnadoptingAreLogged() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let path = dir.sub("elsewhere")
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: path)
        await workspace.refresh(repoPath: repo)

        _ = try await ActivitySource.$current.withValue(.cli) { try await workspace.adopt(path: path) }
        try await workspace.removeRow(path: path)

        let events = await logged(workspace, "row").dropFirst()
        #expect(events.map(\.type) == ["row.adopted", "row.removed"])
        #expect(events.map(\.source) == [.cli, .ui])
        #expect(events.allSatisfy { $0.path == path && $0.row == "feat/x" && $0.data["class"] == "adopted" })
    }

    @Test func pruningIsLoggedAsTheCallersChange() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/a").row
        try FileManager.default.removeItem(atPath: row.path)
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.row(path: row.path)?.isMissing == true)

        try await ActivitySource.$current.withValue(.cli) { try await workspace.prune(repoPath: repo) }

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created", "row.removed"])
        #expect(events.map(\.source) == [.ui, .cli])
    }

    @Test func aPruneThatFailsLogsWhatItRemovedAsTheCallers() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        // git prunes, then reports an error, as when it could not remove every stale entry.
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ $1 == worktree && $2 == prune ]]; then /usr/bin/git "$@"; exit 1; fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/a").row
        try FileManager.default.removeItem(atPath: row.path)
        await workspace.refresh(repoPath: repo)

        await #expect(throws: WorkspaceError.self) {
            try await ActivitySource.$current.withValue(.cli) { try await workspace.prune(repoPath: repo) }
        }
        await workspace.refresh(repoPath: repo)

        #expect(await logged(workspace, "row").map(\.source) == [.ui, .cli])
    }

    @Test func aRepoWithNoCommitsYetIsNotLoggedAsNewOnceItHasOne() async throws {
        let dir = try TempDir()
        let repo = dir.sub("empty")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await Fixture.git.run(["init", "--quiet", "-b", "main"], in: repo)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        try await Fixture.git.run(
            [
                "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--quiet", "--allow-empty", "-m",
                "first",
            ],
            in: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await logged(workspace, "row").isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter RowActivityTests`
Expected: does not compile, `Workspace` has no `activity`.
Once it has one, every test fails with no events logged.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift
+++ b/Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift
@@ -91,6 +91,8 @@ extension Workspace {
         }
 
         let path = Paths.canonical(folder.path)
+        changingRows[path] = .current
+        defer { finishChanging([path], repoPath: repoPath) }
         do {
             try await git.run(arguments, in: repoPath)
         } catch let error as GitError {
@@ -126,9 +128,13 @@ extension Workspace {
             var arguments = ["worktree", "remove"]
             if force { arguments.append("--force") }
             arguments.append(path)
+            changingRows[path] = .current
+            defer { finishChanging([path], repoPath: row.repoPath) }
             do {
                 try await git.run(arguments, in: row.repoPath)
             } catch let error as GitError {
+                // git may have removed part of the row before it failed.
+                await refresh(repoPath: row.repoPath)
                 if error.stderr.contains("modified or untracked files") {
                     throw WorkspaceError.worktreeDirty(path)
                 }
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -4,6 +4,7 @@ import Foundation
 /// the workspace only persists which repos are registered, adopted paths, and row order.
 public actor Workspace {
     public nonisolated let home: CanopyHome
+    public nonisolated let activity: ActivityLog
     let git: GitRunner
     let fetchTimeout: Duration
     var lastFetch: [String: FetchAttempt] = [:]
@@ -18,6 +19,11 @@ public actor Workspace {
     var instanceLock: InstanceLock?
     var subscribers: [UUID: AsyncStream<WorkspaceSnapshot>.Continuation] = [:]
     public private(set) var loadNotice: String?
+    /// Each repo's rows as of the last worktree list git gave, which the next one is compared with to log changes.
+    var rowBaselines: [String: [Row]] = [:]
+    /// Rows Canopy is creating, removing, or pruning, with who asked. git can list a row halfway through a change, so
+    /// refreshes leave these out of the comparison, and the operation logs how each one ended up.
+    var changingRows: [String: ActivitySource] = [:]
 
     let github: GitHubCLI
     let prTiming: PRTiming
@@ -35,9 +41,10 @@ public actor Workspace {
 
     public init(
         home: CanopyHome, git: GitRunner = GitRunner(), fetchTimeout: Duration = .seconds(60),
-        github: GitHubCLI = GitHubCLI(), prTiming: PRTiming = .standard
+        github: GitHubCLI = GitHubCLI(), prTiming: PRTiming = .standard, activity: ActivityLog? = nil
     ) {
         self.home = home
+        self.activity = activity ?? ActivityLog(folder: home.activityFolder)
         self.git = git
         self.fetchTimeout = fetchTimeout
         self.github = github
@@ -122,6 +129,7 @@ public actor Workspace {
         let dirName = RepoNaming.dirName(for: mainPath, taken: Set(state.repos.map(\.dirName)))
         state.repos.append(RepoEntry(path: mainPath, dirName: dirName))
         try save()
+        activity.record(ActivityType.repoAdded, repo: snapshot.repo(path: mainPath)?.name, path: mainPath)
         await watch(repoPath: mainPath)
         await refresh(repoPath: mainPath)
         return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
@@ -131,13 +139,16 @@ public actor Workspace {
         guard let index = state.repos.firstIndex(where: { $0.path == path }) else {
             throw WorkspaceError.repoNotFound(path)
         }
+        let name = snapshot.repo(path: path)?.name
         state.repos.remove(at: index)
         watchers[path] = nil
         pendingRefreshes.removeValue(forKey: path)?.cancel()
         refreshQueues[path] = nil
         repoSnapshots[path] = nil
+        rowBaselines[path] = nil
         forgetPullRequests(repoPath: path)
         try save()
+        activity.record(ActivityType.repoRemoved, repo: name, path: path)
         publish()
     }
 
@@ -160,6 +171,7 @@ public actor Workspace {
         pendingRefreshes.removeValue(forKey: path)?.cancel()
         refreshQueues[path] = nil
         repoSnapshots[path] = nil
+        rowBaselines[path] = nil
         forgetPullRequests(repoPath: path)
         try save()
         await watch(repoPath: mainPath)
@@ -183,19 +195,25 @@ public actor Workspace {
         state.repos[index].adopted.append(canonical)
         try save()
         await refresh(repoPath: row.repoPath)
-        return snapshot.row(path: canonical) ?? row
+        let adopted = snapshot.row(path: canonical) ?? row
+        record(ActivityType.rowAdopted, adopted, data: ["class": .string(RowClass.adopted.rawValue)])
+        return adopted
     }
 
     public func unadopt(path: String) async throws {
         guard let index = state.repos.firstIndex(where: { $0.adopted.contains(path) }) else {
             throw WorkspaceError.rowNotFound(path)
         }
+        let row = snapshot.row(path: path)
         state.repos[index].adopted.removeAll { $0 == path }
         state.repos[index].rowOrder.removeAll { $0 == path }
         if state.selectedRowPath == path {
             state.selectedRowPath = nil
         }
         try save()
+        if let row {
+            record(ActivityType.rowRemoved, row, data: ["class": .string(RowClass.adopted.rawValue)])
+        }
         await refresh(repoPath: state.repos[index].path)
     }
 
@@ -234,12 +252,23 @@ public actor Workspace {
     }
 
     public func prune(repoPath: String) async throws {
-        try await serialized(repoPath: repoPath) {
-            do {
-                try await self.git.run(["worktree", "prune"], in: repoPath)
-            } catch let error as GitError {
-                throw WorkspaceError.git(error)
+        let missing = snapshot.repo(path: repoPath)?.allRows.filter(\.isMissing).map(\.path) ?? []
+        for path in missing {
+            changingRows[path] = .current
+        }
+        defer { finishChanging(missing, repoPath: repoPath) }
+        do {
+            try await serialized(repoPath: repoPath) {
+                do {
+                    try await self.git.run(["worktree", "prune"], in: repoPath)
+                } catch let error as GitError {
+                    throw WorkspaceError.git(error)
+                }
             }
+        } catch {
+            // git may have pruned some rows before it failed, and they are the caller's doing too.
+            await refresh(repoPath: repoPath)
+            throw error
         }
         await refresh(repoPath: repoPath)
     }
@@ -286,12 +315,20 @@ public actor Workspace {
         // The await above let other calls run, so read the entry again before using it.
         guard let index = state.repos.firstIndex(where: { $0.path == repoPath }) else { return }
         let current = state.repos[index]
+        let worktrees = WorktreeListParser.parse(output)
+        // git follows a folder that moves after it started in it, and reports where the folder went.
+        guard worktrees.first.map({ Paths.canonical($0.path) }) == current.path else {
+            repoSnapshots[current.path] = RepoSnapshot(path: current.path, name: "", isMissing: true)
+            publish()
+            return
+        }
         let rows = classifier.rows(
-            for: WorktreeListParser.parse(output),
+            for: worktrees,
             repoPath: current.path,
             adopted: Set(current.adopted),
             fileExists: { FileManager.default.fileExists(atPath: $0) }
         )
+        recordRowChanges(repoPath: current.path, rows: rows)
         let managed = rows.filter { $0.rowClass == .canopy || $0.rowClass == .adopted }
         let order = RowOrdering.reconcile(order: current.rowOrder, present: managed.map(\.path))
         if order != current.rowOrder {
@@ -311,6 +348,78 @@ public actor Workspace {
         }
     }
 
+    // MARK: Activity
+
+    /// Logs rows that appeared, went away, or moved to another branch since git last listed the repo's worktrees.
+    /// Rows Canopy is changing, and rows git is still creating, wait until they are done. The first list after launch,
+    /// adding the repo, or relocating it has nothing to compare with, so it logs nothing.
+    private func recordRowChanges(repoPath: String, rows: [Row]) {
+        let unsettled = Set(changingRows.keys).union(rows.filter(Self.isBeingCreated).map(\.path))
+        let settled = rows.filter { !unsettled.contains($0.path) }
+        guard let before = rowBaselines[repoPath] else {
+            rowBaselines[repoPath] = settled
+            return
+        }
+        rowBaselines[repoPath] = settled + before.filter { unsettled.contains($0.path) }
+        let previous = Dictionary(before.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
+        for row in settled {
+            if let old = previous[row.path] {
+                recordBranchChange(from: old, to: row, source: .git)
+            } else {
+                record(ActivityType.rowCreated, row, source: .git, data: ["class": .string(row.rowClass.rawValue)])
+            }
+        }
+        let present = Set(rows.map(\.path))
+        for row in before where !unsettled.contains(row.path) && !present.contains(row.path) {
+            record(ActivityType.rowRemoved, row, source: .git, data: ["class": .string(row.rowClass.rawValue)])
+        }
+    }
+
+    /// Logs how rows Canopy changed ended up, as of the last refresh, and compares them from there on.
+    func finishChanging(_ paths: [String], repoPath: String) {
+        for path in paths {
+            guard let source = changingRows.removeValue(forKey: path), var baseline = rowBaselines[repoPath],
+                let repo = repoSnapshots[repoPath], !repo.isMissing
+            else { continue }
+            let old = baseline.first { $0.path == path }
+            let new = repo.allRows.first { $0.path == path && !Self.isBeingCreated($0) }
+            switch (old, new) {
+            case (nil, let row?):
+                record(ActivityType.rowCreated, row, source: source, data: ["class": .string(row.rowClass.rawValue)])
+            case (let row?, nil):
+                record(ActivityType.rowRemoved, row, source: source, data: ["class": .string(row.rowClass.rawValue)])
+            case (let old?, let row?):
+                recordBranchChange(from: old, to: row, source: source)
+            case (nil, nil):
+                break
+            }
+            baseline.removeAll { $0.path == path }
+            baseline += new.map { [$0] } ?? []
+            rowBaselines[repoPath] = baseline
+        }
+    }
+
+    private func recordBranchChange(from old: Row, to row: Row, source: ActivitySource) {
+        guard old.branch != row.branch else { return }
+        record(
+            ActivityType.rowBranchChanged, row, source: source,
+            data: ["from": old.branch.map(JSONValue.string) ?? .null, "to": row.branch.map(JSONValue.string) ?? .null])
+    }
+
+    /// `git worktree add` lists a new worktree with a detached, all-zero HEAD until it has checked the branch out.
+    /// A branch with no commits yet also has an all-zero HEAD, but it is named.
+    static func isBeingCreated(_ row: Row) -> Bool {
+        row.branch == nil && row.head.map { !$0.isEmpty && $0.allSatisfy { $0 == "0" } } ?? false
+    }
+
+    func record(
+        _ type: String, _ row: Row, source: ActivitySource = .current, data: [String: JSONValue] = [:]
+    ) {
+        activity.record(
+            type, repo: snapshot.repo(path: row.repoPath)?.name, row: row.displayName, path: row.path, source: source,
+            data: data)
+    }
+
     // MARK: Internals
 
     func mainCheckout(for path: String) async throws -> String {
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`.
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: log repo and row changes with who made them"
```

## Task 3: Log pull requests opening and changing state

**Files:** Modify `Sources/CanopyCore/Workspace/Workspace.swift` and `Workspace+PullRequests.swift`.
Test `Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift`.

**Interfaces:** Consumes `Workspace.record` and `logged(_:_:)` from Task 2, and `FakeGH` from the PR badge tests.

Each lookup GitHub answered is compared with the one before, kept per repo in `prBaselines`.
Only branches both lookups asked about count, so a row made a moment ago for a branch that already has a PR logs nothing.
A new PR number on a branch is `pr.opened`, and the same number in another state is `pr.state_changed`.
Among closed PRs a branch shows the most recently updated, so a new number that is merged or closed after an earlier PR is not an opening.
A lookup `gh` could not make leaves the baseline alone, so PRs showing again after `gh auth login` are not new.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift
+++ b/Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift
@@ -350,4 +350,71 @@ struct PullRequestWorkspaceTests {
             try await workspace.pullRequest(for: row, refresh: false)
         }
     }
+
+    @Test func openingAndStateChangesAreLogged() async throws {
+        let dir = try TempDir()
+        let (workspace, gh, repo) = try await setUp(dir)
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        gh.answer([0: (5, "MERGED"), 1: (7, "OPEN")])
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        let events = await logged(workspace, "pr")
+        try #require(events.map(\.type) == ["pr.state_changed", "pr.opened"])
+        #expect(events.allSatisfy { $0.source == .git && $0.repo == "demo" })
+        #expect(events.map(\.row) == ["feat/a", "feat/b"])
+        #expect(events.map(\.path) == [dir.sub("home/worktrees/demo/feat-a"), dir.sub("home/worktrees/demo/feat-b")])
+        #expect(
+            events[0].data == [
+                "number": 5, "from": "open", "to": "merged", "url": "https://github.com/NE1NN/canopy/pull/5",
+            ])
+        #expect(
+            events[1].data == [
+                "number": 7, "title": "PR 7", "state": "open", "url": "https://github.com/NE1NN/canopy/pull/7",
+            ])
+    }
+
+    @Test func pullRequestsSeenAgainAfterAnOutageAreNotLoggedAsNew() async throws {
+        let dir = try TempDir()
+        let (workspace, gh, repo) = try await setUp(dir)
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        gh.fail(exitCode: 4, "To get started with GitHub CLI, please run:  gh auth login")
+        await workspace.refreshPullRequests(repoPath: repo)
+        gh.answer([0: (5, "OPEN")])
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        #expect(await logged(workspace, "pr").isEmpty)
+    }
+
+    @Test func aBranchsFirstLookupIsNotLoggedAsOpening() async throws {
+        let dir = try TempDir()
+        let (workspace, gh, repo) = try await setUp(dir)
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        gh.answer([0: (5, "OPEN"), 2: (9, "OPEN")])
+        try await Fixture.worktree(repo: repo, branch: "feat/c", at: dir.sub("home/worktrees/demo/feat-c"))
+        await workspace.refresh(repoPath: repo)
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        #expect(await pullRequest(workspace, dir.sub("home/worktrees/demo/feat-c"))?.number == 9)
+        #expect(await logged(workspace, "pr").isEmpty)
+    }
+
+    @Test func anOlderClosedPullRequestTakingOverIsNotLoggedAsOpening() async throws {
+        let dir = try TempDir()
+        let (workspace, gh, repo) = try await setUp(dir)
+        gh.answer([0: (7, "CLOSED")])
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        // A comment on closed #3 makes it the branch's most recently updated PR.
+        gh.answer([0: (3, "CLOSED")])
+        await workspace.refreshPullRequests(repoPath: repo)
+        gh.answer([0: (9, "OPEN")])
+        await workspace.refreshPullRequests(repoPath: repo)
+
+        let events = await logged(workspace, "pr")
+        #expect(events.map(\.type) == ["pr.opened"])
+        #expect(events.first?.data["number"] == 9)
+    }
 }
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PullRequestWorkspaceTests`
Expected: `openingAndStateChangesAreLogged` fails with no events.
The other two pass already, and they fail if either guard in Step 3 is removed.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Workspace/Workspace+PullRequests.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace+PullRequests.swift
+++ b/Sources/CanopyCore/Workspace/Workspace+PullRequests.swift
@@ -145,11 +145,44 @@ extension Workspace {
         case .notLoggedIn: entry = RepoPullRequests(source: .notLoggedIn, branches: branches)
         case .failed(let message): entry.source = .failed(message)
         }
+        recordPullRequestChanges(repoPath: repoPath, entry: entry)
         guard entry != pullRequests[repoPath] else { return }
         pullRequests[repoPath] = entry
         publish()
     }
 
+    /// Logs PRs that opened or changed state since the last lookup GitHub answered. A branch that lookup did not ask
+    /// about, such as a row made a moment ago, has nothing to compare with. A lookup gh could not make changes nothing,
+    /// so PRs coming back after `gh auth login` are not logged as new.
+    private func recordPullRequestChanges(repoPath: String, entry: RepoPullRequests) {
+        guard entry.source == .github else { return }
+        defer { prBaselines[repoPath] = entry }
+        guard let before = prBaselines[repoPath] else { return }
+        let rows = repoSnapshots[repoPath]?.rows.filter(Self.looksUpPullRequest) ?? []
+        for branch in entry.branches where before.branches.contains(branch) {
+            guard let pr = entry.found[branch], let row = rows.first(where: { $0.branch == branch }) else { continue }
+            let number = JSONValue.number(Double(pr.number))
+            if let old = before.found[branch], old.number == pr.number {
+                guard old.state != pr.state else { continue }
+                record(
+                    ActivityType.prStateChanged, row, source: .git,
+                    data: [
+                        "number": number, "from": .string(old.state.rawValue), "to": .string(pr.state.rawValue),
+                        "url": .string(pr.url),
+                    ])
+            } else if before.found[branch] == nil || [.open, .draft].contains(pr.state) {
+                // Among closed PRs the branch shows the most recently updated, so one can take over from another
+                // without anything being opened.
+                record(
+                    ActivityType.prOpened, row, source: .git,
+                    data: [
+                        "number": number, "title": .string(pr.title), "state": .string(pr.state.rawValue),
+                        "url": .string(pr.url),
+                    ])
+            }
+        }
+    }
+
     func startPullRequests() {
         prStopped = false
         prTimer?.cancel()
@@ -196,6 +229,7 @@ extension Workspace {
 
     func forgetPullRequests(repoPath: String) {
         pullRequests[repoPath] = nil
+        prBaselines[repoPath] = nil
         prBranchesRequested[repoPath] = nil
         afterPush.removeValue(forKey: repoPath)?.task.cancel()
     }
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -28,6 +28,8 @@ public actor Workspace {
     let github: GitHubCLI
     let prTiming: PRTiming
     var pullRequests: [String: RepoPullRequests] = [:]
+    /// Each repo's last lookup GitHub answered, which the next one is compared with to log PRs opening and changing.
+    var prBaselines: [String: RepoPullRequests] = [:]
     /// The branches each repo's latest lookup asked about, set when it is queued.
     var prBranchesRequested: [String: [String]] = [:]
     var prQueues: [String: Task<Void, Never>] = [:]
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`.
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: log pull requests opening and changing state"
```

## Task 4: Log terminals opening and exiting

**Files:** Modify `Sources/CanopyCore/Terminal/TerminalStore.swift`, `Pane.swift`, and `Sources/CanopyApp/AppModel.swift`.
Test `Tests/CanopyCoreTests/TerminalActivityTests.swift`.

**Interfaces:**
- Consumes `ActivityLog` from Task 1.
- Produces `TerminalStore.activity` (and an `activity:` init parameter that defaults to a log in the shell settings' home), `TerminalStore.followRowNames(in:)`, a `Pane` init parameter `activity:`, and `Pane.record(_:_:)`, which adds the pane ID and the row.
  The test helper `logged(_:_:)` gets an overload for a `TerminalStore`.

A pane logs `term.opened` each time a shell or script starts, including a restart, and `term.exited` with the code when it ends.
A pane closed while running reports `Pane.closedExitCode`, 129, once.
A pane keeps the repo and row names it opened with, so the app calls `followRowNames(in:)` with each snapshot, and a row switched to another branch is logged, and listed by `canopy term list`, by its name now.
The app now makes one `ActivityLog` from `config.json` and hands it to both the workspace and the terminals, and flushes it at quit after the terminals close.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/TerminalActivityTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
func logged(_ terminals: TerminalStore, _ prefix: String) async -> [ActivityEvent] {
    await terminals.activity.flush()
    return activityEvents(terminals.activity.folder).filter { $0.type.hasPrefix(prefix + ".") }
}

@MainActor
struct TerminalActivityTests {
    @Test func openingAndExitingAreLogged() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
        await pane.run("exit 3")
        #expect(await eventually { pane.status == .exited(3) })

        let events = await logged(terminals, "term")
        #expect(events.map(\.type) == ["term.opened", "term.exited"])
        #expect(events.map(\.data) == [["pane": "p1"], ["pane": "p1", "code": 3]])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.row == "feat/x" && $0.path == dir.path })
        #expect(events.allSatisfy { $0.source == .ui })
    }

    @Test func aTerminalClosedThroughTheCLIIsLoggedAsItsDoing() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = ActivitySource.$current.withValue(.cli) { terminals.openTab(for: Fixture.context(dir.path)).focused }
        ActivitySource.$current.withValue(.cli) { terminals.closePane(pane.id) }

        let events = await logged(terminals, "term")
        #expect(events.map(\.type) == ["term.opened", "term.exited"])
        #expect(events.map(\.source) == [.cli, .cli])
        #expect(events.last?.data["code"] == .number(Double(Pane.closedExitCode)))
    }

    @Test func restartingAShellLogsItOpeningAgain() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
        await pane.run("exit 0")
        #expect(await eventually { pane.status == .exited(0) })
        pane.screen.type("\r")

        #expect(await logged(terminals, "term").map(\.type) == ["term.opened", "term.exited", "term.opened"])
    }

    @Test func eventsNameTheRowAsItIsNow() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        // The row's checkout moved to another branch, and a second repo with the same folder name was added.
        let row = Row(repoPath: "/r/demo", path: dir.path, branch: "feat/y", head: nil, rowClass: .canopy)
        terminals.followRowNames(
            in: WorkspaceSnapshot(repos: [RepoSnapshot(path: "/r/demo", name: "demo (r)", rows: [row])]))
        terminals.closePane(pane.id)

        let exited = await logged(terminals, "term").last
        #expect(exited?.row == "feat/y" && exited?.repo == "demo (r)")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter TerminalActivityTests`
Expected: does not compile, `TerminalStore` has no `activity`.
Once it has one, every test fails with no events logged.

- [ ] **Step 3: Implement**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -10,6 +10,7 @@ final class AppModel {
     let workspace: Workspace
     let terminals: TerminalStore
     let rows: RowLifecycle
+    let activity: ActivityLog
     private(set) var snapshot = WorkspaceSnapshot()
     private(set) var toast: String?
     var selectedRowPath: String? {
@@ -23,9 +24,14 @@ final class AppModel {
 
     init(home: CanopyHome) {
         self.home = home
-        let workspace = Workspace(home: home)
+        let config = GlobalConfig.load(from: home.configFile)
+        let activity = ActivityLog(folder: home.activityFolder, logsCommands: config.logCommands)
+        let workspace = Workspace(home: home, activity: activity)
         let terminals = TerminalStore(
-            engine: SwiftTermEngine(), settings: .current(home: home, cliDirectory: Self.bundledCLIDirectory()))
+            engine: SwiftTermEngine(), settings: .current(home: home, cliDirectory: Self.bundledCLIDirectory()),
+            activity: activity)
+        self.config = config
+        self.activity = activity
         self.workspace = workspace
         self.terminals = terminals
         self.rows = RowLifecycle(workspace: workspace, terminals: terminals)
@@ -79,6 +85,7 @@ final class AppModel {
         server?.stop()
         server = nil
         terminals.closeAll()
+        activity.flushNow()
     }
 
     private func startControlServer() async {
@@ -322,7 +329,7 @@ final class AppModel {
     var gridSize = CGSize(width: 1000, height: 700) {
         didSet { terminals.fits = addRuleFits() }
     }
-    @ObservationIgnored private lazy var config = GlobalConfig.load(from: home.configFile)
+    @ObservationIgnored private let config: GlobalConfig
 
     /// The least room a pane may shrink to: 20 columns and 5 rows, plus its padding and header.
     var minimumPaneSize: CGSize {
@@ -494,6 +501,7 @@ final class AppModel {
     private func apply(_ snapshot: WorkspaceSnapshot) {
         self.snapshot = snapshot
         terminals.closeRowsGone(from: snapshot)
+        terminals.followRowNames(in: snapshot)
         if terminalsRestored, !deferredTerminals.isEmpty {
             restoreDeferredTerminals()
         }
```

`Sources/CanopyCore/Terminal/Pane.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/Pane.swift
+++ b/Sources/CanopyCore/Terminal/Pane.swift
@@ -24,6 +24,7 @@ public final class Pane: Identifiable {
         didSet { refreshTitle() }
     }
     @ObservationIgnored private let settings: ShellSettings
+    @ObservationIgnored private let activity: ActivityLog
     @ObservationIgnored private var process: PtyProcess?
     @ObservationIgnored private var programTitle: ProgramTitle?
     @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
@@ -35,12 +36,13 @@ public final class Pane: Identifiable {
 
     init(
         id: PaneID, context: PaneContext, command: PaneCommand, settings: ShellSettings,
-        emulator: any TerminalEmulator, directory: String? = nil
+        emulator: any TerminalEmulator, activity: ActivityLog, directory: String? = nil
     ) {
         self.id = id
         self.context = context
         self.startDirectory = directory
         self.settings = settings
+        self.activity = activity
         self.emulator = emulator
         emulator.onInput = { [weak self] in self?.input($0) }
         emulator.onResize = { [weak self] in self?.process?.resize($0) }
@@ -143,6 +145,7 @@ public final class Pane: Identifiable {
                 onExit: { [weak self] in self?.processExited($0) }
             )
             status = .running
+            record(ActivityType.termOpened)
             // Name the pane after what was launched. Reading the foreground now could catch the child
             // between fork and exec, still named after Canopy.
             title = (launch.executable as NSString).lastPathComponent
@@ -166,11 +169,18 @@ public final class Pane: Identifiable {
         refreshTitle()
     }
 
+    private func record(_ type: String, _ data: [String: JSONValue] = [:]) {
+        activity.record(
+            type, repo: context.repoName, row: context.rowName, path: context.rowPath,
+            data: data.merging(["pane": .string(id.description)]) { value, _ in value })
+    }
+
     private func processExited(_ code: Int32) {
         // A closed pane already reported its exit. An exit status that was on its way when it closed changes nothing.
         if isClosed, case .exited = status { return }
         process = nil
         status = .exited(code)
+        record(ActivityType.termExited, ["code": .number(Double(code))])
         // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
         emulator.feed(Data("\u{1b}[?25l".utf8))
         let waiters = exitWaiters
```

`Sources/CanopyCore/Terminal/TerminalStore.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/TerminalStore.swift
+++ b/Sources/CanopyCore/Terminal/TerminalStore.swift
@@ -49,6 +49,7 @@ public final class TerminalStore {
     /// The app keeps it in step with the grid's width.
     @ObservationIgnored public var fits: (Int) -> Bool = { $0 <= 2 }
     @ObservationIgnored public let settings: ShellSettings
+    @ObservationIgnored public let activity: ActivityLog
     @ObservationIgnored private let engine: any TerminalEngine
     @ObservationIgnored private var nextPane = 1
     @ObservationIgnored private var nextTab = 1
@@ -56,9 +57,10 @@ public final class TerminalStore {
     /// that went away.
     @ObservationIgnored private var seenRows: Set<String> = []
 
-    public init(engine: any TerminalEngine, settings: ShellSettings) {
+    public init(engine: any TerminalEngine, settings: ShellSettings, activity: ActivityLog? = nil) {
         self.engine = engine
         self.settings = settings
+        self.activity = activity ?? ActivityLog(folder: settings.home.activityFolder)
     }
 
     /// The number the next pane gets, saved so IDs keep counting up across launches.
@@ -288,6 +290,17 @@ public final class TerminalStore {
         }
     }
 
+    /// Keeps each pane's repo and row names in step with the sidebar, so a row whose checkout moved to another branch
+    /// is logged and listed by its name now. Shells already running keep the CANOPY_ROW they started with.
+    public func followRowNames(in snapshot: WorkspaceSnapshot) {
+        for pane in panes {
+            guard let row = snapshot.row(path: pane.context.rowPath), let repo = snapshot.repo(path: row.repoPath)
+            else { continue }
+            if pane.context.rowName != row.displayName { pane.context.rowName = row.displayName }
+            if pane.context.repoName != repo.name { pane.context.repoName = repo.name }
+        }
+    }
+
     /// Closes every terminal in a repo's rows, for when the repo is unregistered.
     public func closeRows(ofRepo repoPath: String) {
         for (path, tabs) in tabsByRow where tabs.first?.repoPath == repoPath {
@@ -372,6 +385,6 @@ public final class TerminalStore {
         defer { nextPane += 1 }
         return Pane(
             id: PaneID(nextPane), context: context, command: command, settings: settings,
-            emulator: engine.makeEmulator(size: preferredSize), directory: directory)
+            emulator: engine.makeEmulator(size: preferredSize), activity: activity, directory: directory)
     }
 }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`.
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: log terminals opening and exiting"
```

## Task 5: Log commands run in zsh terminals

**Files:** Create `Sources/CanopyCore/Terminal/CommandMarks.swift` and `ZshIntegration.swift`.
Modify `ShellSettings.swift`, `Pane.swift`, `CanopyHome.swift` (`zshShimFolder`), and `Sources/CanopyApp/AppModel.swift`.
Test `Tests/CanopyCoreTests/CommandLoggingTests.swift`, with `Fixture.zshTerminals` added to `Tests/CanopyCoreTests/Support/FakeTerminal.swift`.

**Interfaces:**
- Consumes `Pane.record` from Task 4, and gives it a `source:` parameter, since reports always come from the terminal.
- Produces `CommandMark` (`command`, `directory`, `exitCode`, `durationMs`), `CommandMarkScanner(token:)` with `scan(_:) -> [CommandMark]`, `ZshIntegration.install(in:) -> String` and `ZshIntegration.reportCode`, `ShellSettings.logsCommands`, and `ShellSettings.interactiveShell(environment:directory:commandToken:)`.

zsh starts with `ZDOTDIR` pointing at `CANOPY_HOME/shell/zsh`, whose `.zshenv` defines Canopy's functions first, so no alias from the user's files can reach into them.
It then unsets `ZDOTDIR` and sources the user's own `.zshenv`, so zsh reads the user's `.zprofile`, `.zshrc`, and `.zlogin` from their usual place, and macOS's `/etc/zshrc` puts history in `~/.zsh_history` as usual.
Both hooks go in straight away, and each puts the other back if the user's `.zshrc` replaced its list.
`preexec` skips a command starting with a space under `hist_ignore_space`, and one matching `HISTORY_IGNORE`, since zsh keeps both out of the history file.
`precmd` prints one OSC 6973 report per command with the command, the folder it started in, the exit code, and the time from `EPOCHREALTIME`, percent-encoding `%`, `;`, and control characters in pure zsh so no process is forked.
zsh restores `$?` for each `precmd` hook, so hook order does not change the exit code.
Every function runs `emulate -L zsh` first, so an option like `ksh_arrays` in the user's `.zshrc` cannot change what it does, such as which hooks stay in a list.
Each shell gets a fresh token in `CANOPY_COMMAND_TOKEN`, which the shim moves into a shell variable, so a report replayed by other output does not match.
The pane scans its output for reports before the emulator draws it, skipping to each ESC with `memchr`, so the scan is independent of SwiftTerm, and stops once the pane is closed, whose exit is already logged.
SwiftTerm draws nothing for an OSC it does not know and puts no cap on its length, and the app registers an empty handler for 6973 so SwiftTerm does not log it as unknown.
The shim sends no OSC 133 marks: SwiftTerm fresh-lines on a prompt mark, which would hide zsh's `%` after output with no final newline.
`interactiveShell` writes the shim again, if it changed or went missing, each time it starts zsh, and leaves `ZDOTDIR` alone if writing fails, since zsh pointed at an empty folder would skip the user's startup files.

- [ ] **Step 1: Write the failing tests**

The scanner tests feed made-up output.
The zsh tests start real zsh with a private HOME holding the user's startup files.
Waiting for a command's output must look for text that differs from the typed line zsh echoes, which is why the barrier prints `done-42` from `echo done-$((40 + 2))`.

`Tests/CanopyCoreTests/CommandLoggingTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// A report as the zsh shim prints it after a command.
func commandMark(
    token: String = "t0k", exit: String = "0", ms: String = "12", command: String = "ls", cwd: String = "/tmp",
    end: String = "\u{07}"
) -> Data {
    Data("\u{1b}]6973;command;\(token);\(exit);\(ms);\(command);\(cwd)\(end)".utf8)
}

struct CommandMarkScannerTests {
    let ls = CommandMark(command: "ls", directory: "/tmp", exitCode: 0, durationMs: 12)

    @Test func findsAReportAmongOtherOutput() {
        var scanner = CommandMarkScanner(token: "t0k")
        let output = Data("hi \u{1b}[31mred\u{1b}[0m\r\n".utf8) + commandMark() + Data("\u{1b}]0;title\u{07}$ ".utf8)

        #expect(scanner.scan(output) == [ls])
    }

    @Test func findsAReportSplitAtAnyByte() {
        let output = Data("before\u{1b}[1m".utf8) + commandMark() + Data("after".utf8)
        for split in 0...output.count {
            var scanner = CommandMarkScanner(token: "t0k")
            let found = scanner.scan(output.prefix(split)) + scanner.scan(output.dropFirst(split))
            #expect(found == [ls], "split at \(split)")
        }
    }

    @Test func acceptsEitherTerminator() {
        var scanner = CommandMarkScanner(token: "t0k")

        #expect(scanner.scan(commandMark(end: "\u{1b}\\")) == [ls])
    }

    @Test func decodesEncodedText() {
        var scanner = CommandMarkScanner(token: "t0k")
        let report = commandMark(
            exit: "130", ms: "", command: "echo 'a%3Bb' %25d%0Anext%1B", cwd: "/tmp/caf\u{e9} \u{2713}")

        #expect(
            scanner.scan(report) == [
                CommandMark(command: "echo 'a;b' %d\nnext\u{1b}", directory: "/tmp/caf\u{e9} \u{2713}", exitCode: 130)
            ])
    }

    @Test func ignoresReportsThatAreNotThisShells() {
        var scanner = CommandMarkScanner(token: "t0k")
        let others = [
            commandMark(token: "forged"), commandMark(exit: "zero"), Data("\u{1b}]6973;command;t0k;0;1;ls\u{07}".utf8),
            Data("\u{1b}]69730;command;t0k;0;1;ls;/tmp\u{07}".utf8), Data("\u{1b}]52;c;aGk=\u{07}".utf8),
        ]

        #expect(scanner.scan(others.reduce(Data(), +)).isEmpty)
        #expect(scanner.scan(commandMark()) == [ls])
    }

    @Test func dropsAReportCutShortByAnotherSequence() {
        var scanner = CommandMarkScanner(token: "t0k")
        let cut = Data("\u{1b}]6973;command;t0k;0".utf8) + Data("\u{1b}[31m".utf8)
        let cancelled = Data("\u{1b}]6973;command;t0k;0;1;ls;/tmp\u{18}".utf8)

        #expect(scanner.scan(cut + cancelled + commandMark()) == [ls])
    }

    @Test func ignoresReportsTooLongToBeReal() {
        var scanner = CommandMarkScanner(token: "t0k")

        #expect(scanner.scan(commandMark(command: String(repeating: "x", count: 70_000))).isEmpty)
        #expect(scanner.scan(commandMark()) == [ls])
    }
}

@MainActor
struct ZshCommandLoggingTests {
    func commands(_ terminals: TerminalStore) async -> [ActivityEvent] {
        await logged(terminals, "term").filter { $0.type == ActivityType.termCommand }
    }

    /// Types `command`, then waits for its output to show `marker`, which must differ from the typed line zsh echoes.
    func run(_ pane: Pane, _ command: String, until marker: String) async -> Bool {
        await pane.run(command)
        return await eventually { pane.screen.text.contains(marker) }
    }

    static let barrier = "echo done-$((40 + 2))"

    /// Runs a last command and waits until it is logged, so every command before it is too.
    func barrier(_ pane: Pane, _ terminals: TerminalStore) async -> Bool {
        await pane.run(Self.barrier)
        return await eventually { await commands(terminals).last?.data["cmd"] == .string(Self.barrier) }
    }

    @Test func commandsAreLoggedWithTheirExitCodeFolderAndDuration() async throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(atPath: dir.sub("sub"), withIntermediateDirectories: true)
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "alias hello='echo hi-from-alias'"])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(await run(pane, "hello", until: "hi-from-alias"))
        await pane.run("(exit 3)")
        await pane.run("cd sub && sleep 0.3")
        await pane.run(#"echo 'a;b' "%d""#)
        #expect(await eventually { await commands(terminals).count == 4 })

        let events = await commands(terminals)
        #expect(events.map(\.data["cmd"]) == ["hello", "(exit 3)", "cd sub && sleep 0.3", #"echo 'a;b' "%d""#])
        #expect(events.map(\.data["exit"]) == [0, 3, 0, 0])
        #expect(events.map(\.data["cwd"]) == [dir.path, dir.path, dir.path, dir.sub("sub")].map(JSONValue.string))
        #expect(events.allSatisfy { $0.data["pane"] == "p1" && $0.row == "feat/x" && $0.source == .ui })
        guard case .number(let slept) = events[2].data["durationMs"] else {
            Issue.record("no duration")
            return
        }
        #expect(slept >= 300 && slept < 5_000)
    }

    @Test func theUsersStartupFilesLoadAsUsual() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(
            dir,
            files: [
                ".zshenv": "export FROM_ZSHENV=1", ".zprofile": "export FROM_ZPROFILE=1",
                ".zshrc": "export FROM_ZSHRC=1", ".zlogin": "export FROM_ZLOGIN=1",
            ])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let check =
            #"print -r -- "check:$FROM_ZSHENV$FROM_ZPROFILE$FROM_ZSHRC$FROM_ZLOGIN:${ZDOTDIR-unset}:"#
            + #"${CANOPY_COMMAND_TOKEN-none}:$HISTFILE""#
        #expect(await run(pane, check, until: "check:1111:unset:none:\(dir.sub("user-home"))/.zsh_history"))
    }

    @Test func aZDOTDIRSetInTheUsersZshenvIsFollowed() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(
            dir,
            files: [
                ".zshenv": "export ZDOTDIR=$HOME/.config/zsh",
                ".config/zsh/.zshrc": "alias hello='echo hi-from-config'",
            ])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(await run(pane, "hello", until: "hi-from-config"))
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == ["hello"] })
    }

    @Test func theUsersOwnHooksKeepRunningWhateverTheirOptions() async throws {
        let dir = try TempDir()
        let zshrc = """
            setopt ksh_arrays
            user_hook() { print -r -- ran >> $HOME/hook.log }
            precmd_functions+=(user_hook)
            """
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": zshrc])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        await pane.run("echo one")
        #expect(await barrier(pane, terminals))

        let runs = (try? String(contentsOfFile: dir.sub("user-home/hook.log"), encoding: .utf8)) ?? ""
        #expect(runs.split(separator: "\n").count == 3, "the hook ran at \(runs.count / 4) prompts")
        #expect(await commands(terminals).map(\.data["cmd"]) == ["echo one", .string(Self.barrier)])
    }

    @Test func aZshrcThatResetsTheHookListsStillHasItsCommandsLogged() async throws {
        for reset in ["precmd_functions=(user_hook)", "preexec_functions=(user_hook)"] {
            let dir = try TempDir()
            let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "user_hook() { :; }\n" + reset])
            defer { terminals.closeAll() }
            let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

            await pane.run("echo one")
            #expect(await barrier(pane, terminals), "\(reset)")
            #expect(await commands(terminals).map(\.data["cmd"]) == ["echo one", .string(Self.barrier)], "\(reset)")
        }
    }

    @Test func aShimDeletedWhileCanopyRunsIsWrittenAgain() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "alias hello='echo hi-from-alias'"])
        defer { terminals.closeAll() }
        let first = terminals.openTab(for: Fixture.context(dir.path)).focused
        #expect(await run(first, "echo first-$((40 + 2))", until: "first-42"))
        try FileManager.default.removeItem(at: terminals.settings.home.zshShimFolder)

        let pane = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })
        #expect(await run(pane, "hello", until: "hi-from-alias"))
        #expect(await eventually { await commands(terminals).last?.data["cmd"] == "hello" })
    }

    @Test func commandsHistoryIgnoreMatchesAreLeftOut() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "HISTORY_IGNORE='(*secret*|ls)'"])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        await pane.run("echo my-secret-one")
        await pane.run("ls")
        await pane.run("echo public-two")
        #expect(await barrier(pane, terminals))

        #expect(await commands(terminals).map(\.data["cmd"]) == ["echo public-two", .string(Self.barrier)])
    }

    @Test func commandsStartingWithASpaceAreLeftOutUnderHistIgnoreSpace() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "setopt hist_ignore_space"])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        await pane.run(" echo secret-one")
        await pane.run("echo public-two")
        #expect(await barrier(pane, terminals))

        #expect(await commands(terminals).map(\.data["cmd"]) == ["echo public-two", .string(Self.barrier)])
    }

    @Test func reportsWithoutTheShellsTokenAreIgnored() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let forge = #"printf '\e]6973;command;forged;0;1;fake;/\a'"#
        await pane.run(forge)
        #expect(await barrier(pane, terminals))

        #expect(await commands(terminals).map(\.data["cmd"]) == [.string(forge), .string(Self.barrier)])
    }

    @Test func zshIsLeftAloneWhenCommandLoggingIsOff() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, logsCommands: false)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(await run(pane, #"print -r -- "zd:${ZDOTDIR-unset}""#, until: "zd:unset"))
        #expect(await run(pane, Self.barrier, until: "done-42"))

        #expect(await commands(terminals).isEmpty)
    }

    @Test func onlyZshShellsGetTheShim() throws {
        let dir = try TempDir()
        var settings = Fixture.shellSettings(dir)
        settings.logsCommands = true

        let bash = settings.interactiveShell(environment: [:], directory: "/", commandToken: "t0k")
        settings.shell = "/bin/zsh"
        let zsh = settings.interactiveShell(environment: [:], directory: "/", commandToken: "t0k")
        let script = settings.script("true", environment: [:], directory: "/")

        #expect(bash.environment["ZDOTDIR"] == nil && bash.environment["CANOPY_COMMAND_TOKEN"] == nil)
        #expect(zsh.environment["ZDOTDIR"] == settings.home.zshShimFolder.path)
        #expect(zsh.environment["CANOPY_COMMAND_TOKEN"] == "t0k")
        #expect(script.environment["ZDOTDIR"] == nil)
    }
}
```

`Tests/CanopyCoreTests/Support/FakeTerminal.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/Support/FakeTerminal.swift
+++ b/Tests/CanopyCoreTests/Support/FakeTerminal.swift
@@ -65,6 +65,26 @@ extension Fixture {
         TerminalStore(engine: FakeEngine(), settings: shellSettings(dir))
     }
 
+    /// zsh with a private HOME holding `files` as the user's own startup files, keyed by path under HOME, and
+    /// Canopy's startup shim unless command logging is off.
+    @MainActor
+    static func zshTerminals(_ dir: TempDir, files: [String: String] = [:], logsCommands: Bool = true) throws
+        -> TerminalStore
+    {
+        let home = dir.sub("user-home")
+        for (name, text) in files {
+            let path = home + "/" + name
+            try FileManager.default.createDirectory(
+                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
+            try text.write(toFile: path, atomically: true, encoding: .utf8)
+        }
+        var settings = shellSettings(dir)
+        settings.shell = "/bin/zsh"
+        settings.baseEnvironment = ["HOME": home, "USER": NSUserName()]
+        settings.logsCommands = logsCommands
+        return TerminalStore(engine: FakeEngine(), settings: settings)
+    }
+
     static func context(_ path: String, branch: String = "feat/x", repoPath: String = "/r/demo") -> PaneContext {
         PaneContext(
             row: Row(repoPath: repoPath, path: path, branch: branch, head: nil, rowClass: .canopy), repoName: "demo")
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'CommandMarkScannerTests|ZshCommandLoggingTests'`
Expected: does not compile, `CommandMarkScanner`, `CommandMark`, `ZshIntegration`, and `ShellSettings.logsCommands` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -28,7 +28,9 @@ final class AppModel {
         let activity = ActivityLog(folder: home.activityFolder, logsCommands: config.logCommands)
         let workspace = Workspace(home: home, activity: activity)
         let terminals = TerminalStore(
-            engine: SwiftTermEngine(), settings: .current(home: home, cliDirectory: Self.bundledCLIDirectory()),
+            engine: SwiftTermEngine(),
+            settings: .current(
+                home: home, cliDirectory: Self.bundledCLIDirectory(), logsCommands: config.logCommands),
             activity: activity)
         self.config = config
         self.activity = activity
```

`Sources/CanopyApp/Terminal/SwiftTermEmulator.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
+++ b/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
@@ -36,6 +36,8 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         view = terminalView
         super.init()
         terminalView.terminalDelegate = self
+        // Panes read the zsh shim's command reports from the output before it gets here.
+        terminalView.getTerminal().registerOscHandler(code: ZshIntegration.reportCode) { _ in }
         terminalView.installColors(Self.palette)
         applyAppearance(NSApp.effectiveAppearance)
     }
```

`Sources/CanopyCore/Support/CanopyHome.swift` (modify):

```diff
--- a/Sources/CanopyCore/Support/CanopyHome.swift
+++ b/Sources/CanopyCore/Support/CanopyHome.swift
@@ -38,6 +38,8 @@ public struct CanopyHome: Sendable, Equatable {
     public var worktreesRoot: URL { root.appending(path: "worktrees") }
     /// One JSON Lines file of activity events per local day.
     public var activityFolder: URL { root.appending(path: "activity") }
+    /// ZDOTDIR for zsh terminals while command logging is on.
+    public var zshShimFolder: URL { root.appending(path: "shell/zsh") }
     public var socketPath: String { root.appending(path: "canopy.sock").path }
     /// Held by the one app instance that owns this home.
     public var appLockPath: String { root.appending(path: "app.lock").path }
```

`Sources/CanopyCore/Terminal/CommandMarks.swift` (new):

```swift
import Foundation

/// A command that finished in a zsh terminal, as Canopy's startup shim reports it.
struct CommandMark: Sendable, Equatable {
    var command: String
    /// The folder the command started in.
    var directory: String
    var exitCode: Int32
    /// Nil when zsh could not time it.
    var durationMs: Int?

    init(command: String, directory: String, exitCode: Int32, durationMs: Int? = nil) {
        self.command = command
        self.directory = directory
        self.exitCode = exitCode
        self.durationMs = durationMs
    }
}

/// Finds the shim's reports in a terminal's output: `ESC ] 6973 ; command ; token ; exit ; ms ; command ; folder BEL`,
/// with the text percent-encoded. A report can be split across reads. Reports without the shell's token are ignored,
/// so output that happens to replay one, such as `cat` of a recorded session, logs nothing.
struct CommandMarkScanner {
    private enum State {
        case ground
        case escape
        case osc
        case oscEscape
    }

    private static let code = Array("\(ZshIntegration.reportCode);".utf8)
    /// A longer report is not one the shim wrote for a command anyone typed.
    private static let limit = 65_536

    let token: String
    private var state = State.ground
    /// How much of an OSC's start matched "6973;", or nil once it is some other OSC.
    private var matched: Int? = 0
    private var payload: [UInt8] = []

    init(token: String) {
        self.token = token
    }

    mutating func scan(_ data: some DataProtocol) -> [CommandMark] {
        var marks: [CommandMark] = []
        for region in data.regions {
            region.withUnsafeBytes { raw in
                scan(raw.bindMemory(to: UInt8.self), into: &marks)
            }
        }
        return marks
    }

    private mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>, into marks: inout [CommandMark]) {
        guard let base = bytes.baseAddress else { return }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch state {
            case .ground:
                // Most output has no escape sequences worth reading, so skip straight to the next ESC.
                guard let found = memchr(base + index, 0x1B, bytes.count - index) else { return }
                index = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + 1
                state = .escape
                continue
            case .escape:
                if byte == 0x5D {
                    state = .osc
                    matched = 0
                    payload.removeAll(keepingCapacity: true)
                } else if byte != 0x1B {
                    state = .ground
                }
            case .osc:
                switch byte {
                case 0x07:
                    finish(into: &marks)
                case 0x1B:
                    state = .oscEscape
                case 0x18, 0x1A:
                    // CAN and SUB cancel a sequence.
                    state = .ground
                default:
                    collect(byte)
                }
            case .oscEscape:
                guard byte == 0x5C else {
                    // The ESC began another sequence, which this byte continues.
                    state = .escape
                    continue
                }
                finish(into: &marks)
            }
            index += 1
        }
    }

    private mutating func collect(_ byte: UInt8) {
        // Terminals ignore control characters inside an OSC, and the shim never sends them.
        guard byte >= 0x20, let count = matched else { return }
        if count < Self.code.count {
            matched = byte == Self.code[count] ? count + 1 : nil
        } else if payload.count < Self.limit {
            payload.append(byte)
        } else {
            matched = nil
        }
    }

    private mutating func finish(into marks: inout [CommandMark]) {
        state = .ground
        if matched == Self.code.count, let mark = parse(payload) {
            marks.append(mark)
        }
    }

    private func parse(_ payload: [UInt8]) -> CommandMark? {
        let fields = payload.split(separator: 0x3B, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        guard fields.count == 6, fields[0] == "command", fields[1] == token, let exitCode = Int32(fields[2]),
            let command = fields[4].removingPercentEncoding, let directory = fields[5].removingPercentEncoding
        else { return nil }
        return CommandMark(command: command, directory: directory, exitCode: exitCode, durationMs: Int(fields[3]))
    }
}
```

`Sources/CanopyCore/Terminal/Pane.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/Pane.swift
+++ b/Sources/CanopyCore/Terminal/Pane.swift
@@ -30,6 +30,8 @@ public final class Pane: Identifiable {
     @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
     @ObservationIgnored private var isClosed = false
     @ObservationIgnored private var isScript = false
+    /// Reads the shell's command reports, while commands are logged.
+    @ObservationIgnored private var commandMarks: CommandMarkScanner?
 
     /// The folder the shell starts in, when restored into one other than the row's.
     public let startDirectory: String?
@@ -133,15 +135,19 @@ public final class Pane: Identifiable {
     private func start(_ command: PaneCommand) {
         if case .script = command { isScript = true } else { isScript = false }
         let environment = PaneEnvironment.build(settings: settings, context: context, pane: id)
+        // A new secret for each shell, so only reports this shell prints count.
+        let token = settings.reportsCommands ? UUID().uuidString : nil
         let launch =
             switch command {
-            case .shell: settings.interactiveShell(environment: environment, directory: directory)
+            case .shell:
+                settings.interactiveShell(environment: environment, directory: directory, commandToken: token)
             case .script(let script): settings.script(script, environment: environment, directory: directory)
             }
+        commandMarks = launch.environment["CANOPY_COMMAND_TOKEN"].map(CommandMarkScanner.init(token:))
         do {
             process = try PtyProcess(
                 launch, size: emulator.size,
-                onOutput: { [weak self] in self?.emulator.feed($0) },
+                onOutput: { [weak self] in self?.output($0) },
                 onExit: { [weak self] in self?.processExited($0) }
             )
             status = .running
@@ -155,6 +161,21 @@ public final class Pane: Identifiable {
         }
     }
 
+    private func output(_ data: Data) {
+        // A closed pane already logged its exit, and output still on its way from before then comes after it.
+        let marks = isClosed ? [] : commandMarks?.scan(data) ?? []
+        for mark in marks {
+            var report: [String: JSONValue] = [
+                "cmd": .string(mark.command), "cwd": .string(mark.directory), "exit": .number(Double(mark.exitCode)),
+            ]
+            if let duration = mark.durationMs {
+                report["durationMs"] = .number(Double(duration))
+            }
+            record(ActivityType.termCommand, report, source: .ui)
+        }
+        emulator.feed(data)
+    }
+
     private func input(_ data: Data) {
         switch status {
         case .running:
@@ -169,9 +190,9 @@ public final class Pane: Identifiable {
         refreshTitle()
     }
 
-    private func record(_ type: String, _ data: [String: JSONValue] = [:]) {
+    private func record(_ type: String, _ data: [String: JSONValue] = [:], source: ActivitySource = .current) {
         activity.record(
-            type, repo: context.repoName, row: context.rowName, path: context.rowPath,
+            type, repo: context.repoName, row: context.rowName, path: context.rowPath, source: source,
             data: data.merging(["pane": .string(id.description)]) { value, _ in value })
     }
```

`Sources/CanopyCore/Terminal/ShellSettings.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/ShellSettings.swift
+++ b/Sources/CanopyCore/Terminal/ShellSettings.swift
@@ -13,22 +13,27 @@ public struct ShellSettings: Sendable, Equatable {
     public var home: CanopyHome
     /// LANG for terminals when the app has none, as Terminal sets it.
     public var language: String
+    /// Whether zsh terminals start through Canopy's shim, which reports the commands they run. Off with
+    /// "logCommands": false in config.json.
+    public var logsCommands: Bool
 
     public init(
         shell: String,
         baseEnvironment: [String: String],
         cliDirectory: String?,
         home: CanopyHome,
-        language: String = "en_US.UTF-8"
+        language: String = "en_US.UTF-8",
+        logsCommands: Bool = false
     ) {
         self.shell = shell
         self.baseEnvironment = baseEnvironment
         self.cliDirectory = cliDirectory
         self.home = home
         self.language = language
+        self.logsCommands = logsCommands
     }
 
-    public static func current(home: CanopyHome, cliDirectory: String?) -> ShellSettings {
+    public static func current(home: CanopyHome, cliDirectory: String?, logsCommands: Bool) -> ShellSettings {
         ShellSettings(
             shell: LoginShell.path(),
             baseEnvironment: ProcessInfo.processInfo.environment,
@@ -36,13 +41,28 @@ public struct ShellSettings: Sendable, Equatable {
             home: home,
             language: LoginShell.language(for: Locale.current.identifier) {
                 FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)")
-            }
+            },
+            logsCommands: logsCommands
         )
     }
 
-    /// An interactive login shell, started the way Terminal starts one: argv[0] is "-zsh".
-    public func interactiveShell(environment: [String: String], directory: String) -> TerminalLaunch {
-        TerminalLaunch(
+    /// Whether interactive shells report the commands they run. Only zsh has a shim.
+    var reportsCommands: Bool {
+        logsCommands && Self.name(of: shell) == "zsh"
+    }
+
+    /// An interactive login shell, started the way Terminal starts one: argv[0] is "-zsh". zsh starts through
+    /// Canopy's shim while commands are logged, and signs its reports with `commandToken`.
+    public func interactiveShell(
+        environment: [String: String], directory: String, commandToken: String? = nil
+    ) -> TerminalLaunch {
+        var environment = environment
+        // Written again if it went missing: zsh pointed at a folder without it would skip the user's startup files.
+        if reportsCommands, let commandToken, let folder = try? ZshIntegration.install(in: home) {
+            environment["ZDOTDIR"] = folder
+            environment["CANOPY_COMMAND_TOKEN"] = commandToken
+        }
+        return TerminalLaunch(
             executable: shell, arguments: ["-" + Self.name(of: shell)], environment: environment, directory: directory)
     }
```

`Sources/CanopyCore/Terminal/ZshIntegration.swift` (new):

```swift
import Foundation

/// Canopy's zsh startup shim, which reports each command that finishes to the activity log. zsh terminals start with
/// ZDOTDIR pointing at its folder. It puts ZDOTDIR back and loads the user's .zshenv, so zsh then reads the user's
/// .zprofile, .zshrc, and .zlogin from their usual place, and the user's setup is unchanged.
public enum ZshIntegration {
    /// The private OSC code of the shim's command reports.
    public static let reportCode = 6973

    /// Writes the shim into CANOPY_HOME/shell/zsh, if it changed, and returns the folder for ZDOTDIR.
    public static func install(in home: CanopyHome) throws -> String {
        try home.ensureExists()
        let folder = home.zshShimFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: ".zshenv")
        if (try? String(contentsOf: file, encoding: .utf8)) != script {
            try script.write(to: file, atomically: true, encoding: .utf8)
        }
        return folder.path
    }

    static let script = #"""
        # Written by Canopy, which starts zsh with ZDOTDIR pointing here. This puts ZDOTDIR back and loads your own
        # .zshenv, so zsh reads your .zprofile, .zshrc, and .zlogin as usual. It also reports each command that
        # finishes to Canopy's activity log. "logCommands": false in Canopy's config.json turns this off.

        builtin typeset -g _canopy_token=${CANOPY_COMMAND_TOKEN-}
        builtin unset CANOPY_COMMAND_TOKEN ZDOTDIR

        # Defined before your .zshenv runs, so none of your aliases can reach into them.
        if [[ -n $_canopy_token && -o interactive ]]; then
            builtin zmodload -F zsh/datetime p:EPOCHREALTIME 2>/dev/null

            # Percent-encodes %, ;, and control characters, so any text fits in a report.
            _canopy_encode() {
                builtin emulate -L zsh
                local text=$1 code
                text=${text//\%/%25}
                text=${text//;/%3B}
                for code in {1..31} 127; do
                    text=${text//${(#)code}/%${(l:2::0:)$(( [##16] code ))}}
                done
                typeset -g _canopy_encoded=$text
            }

            # Each hook puts the other back if the user's .zshrc replaced its list, so logging survives that.
            _canopy_preexec() {
                # A leading space keeps a command out of history under hist_ignore_space, so out of the log too.
                local skip=0
                [[ -o hist_ignore_space ]] && skip=1
                builtin emulate -L zsh
                (( ${precmd_functions[(I)_canopy_precmd]} )) || precmd_functions+=(_canopy_precmd)
                (( skip )) && [[ $1 == ' '* ]] && return
                # zsh never writes lines matching HISTORY_IGNORE to the history file.
                [[ -n ${HISTORY_IGNORE-} && $1 == ${~HISTORY_IGNORE} ]] && return
                typeset -g _canopy_command=$1 _canopy_cwd=$PWD _canopy_started=${EPOCHREALTIME-}
            }

            _canopy_precmd() {
                local code=$?
                builtin emulate -L zsh
                (( ${preexec_functions[(I)_canopy_preexec]} )) || preexec_functions+=(_canopy_preexec)
                [[ -n ${_canopy_command+set} ]] || return 0
                local ms=
                if [[ -n $_canopy_started && -n ${EPOCHREALTIME-} ]]; then
                    local -i elapsed
                    (( elapsed = (EPOCHREALTIME - _canopy_started) * 1000 ))
                    ms=$elapsed
                fi
                _canopy_encode $_canopy_command
                local command=$_canopy_encoded
                _canopy_encode $_canopy_cwd
                builtin print -rn -- $'\e]\#(reportCode);command;'"$_canopy_token;$code;$ms;$command;$_canopy_encoded"$'\a'
                builtin unset _canopy_command _canopy_cwd _canopy_started
            }

            precmd_functions+=(_canopy_precmd)
            preexec_functions+=(_canopy_preexec)
        fi

        [[ -f $HOME/.zshenv ]] && builtin source $HOME/.zshenv
        """#
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`.
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: log commands run in zsh terminals"
```

## Task 6: Log CLI calls that change something

**Files:** Modify `Sources/CanopyCore/Control/ControlMethods.swift` and `WorkspaceControlHandler.swift`.
Test `Tests/CanopyCoreTests/ControlServerTests.swift`, whose `startServer` gains `logsCommands:`.

**Interfaces:** Consumes `Workspace.activity` from Task 2.
Produces `ControlMethod.readOnly`.

The handler runs each request inside `ActivitySource.$current.withValue(.cli)`, so everything the request does, and every task it starts, logs as `cli`.
It then logs `cli.call` with the method, the params as sent, and the error code if the call failed.
Calls that only read are left out, since agents poll `term read` and `term list` every few seconds.
While command logging is off, the `run` and `text` params are dropped, since they are commands typed into terminals, and either is dropped anyway when it starts with a space, as zsh does with history.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlServerTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -13,11 +13,12 @@ final class RecordingUI: ControlUIBridge {
 }
 
 struct ControlServerTests {
-    func startServer(_ dir: TempDir, github: GitHubCLI = GitHubCLI()) async throws
+    func startServer(_ dir: TempDir, github: GitHubCLI = GitHubCLI(), logsCommands: Bool = true) async throws
         -> (Workspace, ControlServer, ControlClient, RecordingUI)
     {
         let home = CanopyHome(path: dir.sub("home"))
-        let workspace = Workspace(home: home, git: Fixture.git, github: github)
+        let activity = ActivityLog(folder: home.activityFolder, logsCommands: logsCommands)
+        let workspace = Workspace(home: home, git: Fixture.git, github: github, activity: activity)
         try await workspace.start()
         let ui = RecordingUI()
         let rows = await MainActor.run { RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)) }
@@ -287,6 +288,82 @@ struct ControlServerTests {
         _ = try await call(client, TermMethod.close, TermCloseParams(pane: pane.pane, force: true), as: JSONValue.self)
     }
 
+    @Test func callsThatChangeSomethingAreLoggedAsTheCLIs() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let (workspace, server, client, _) = try await startServer(dir)
+        defer { server.stop() }
+
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+        let params = RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", setup: false, run: "echo hi")
+        let created = try await call(client, ControlMethod.rowNew, params, as: RowNewResult.self)
+        _ = try await call(client, ControlMethod.rowList, RowListParams(), as: [Row].self)
+        _ = try await call(
+            client, TermMethod.read, TermReadParams(pane: try #require(created.pane)), as: JSONValue.self)
+        await #expect(throws: ControlError.self) {
+            _ = try await call(
+                client, ControlMethod.rowNew, RowNewParams(target: TargetHint(repo: "demo"), branch: "bad name"),
+                as: JSONValue.self)
+        }
+
+        let events = await logged(workspace, "repo", "row", "cli")
+        #expect(events.map(\.type) == ["repo.added", "cli.call", "row.created", "cli.call", "cli.call"])
+        #expect(events.allSatisfy { $0.source == .cli })
+        let calls = events.filter { $0.type == ActivityType.cliCall }
+        try #require(calls.map(\.data["method"]) == ["repo.add", "row.new", "row.new"])
+        #expect(calls[1].data["params"] == (try JSONValue.from(params)))
+        #expect(calls.map(\.data["error"]) == [nil, nil, "invalid_branch"])
+    }
+
+    @Test func commandTextIsLeftOutOfCallsWhenCommandLoggingIsOff() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let (workspace, server, client, _) = try await startServer(dir, logsCommands: false)
+        defer { server.stop() }
+
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+        let created = try await call(
+            client, ControlMethod.rowNew,
+            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", setup: false, run: "echo secret-run"),
+            as: RowNewResult.self)
+        _ = try await call(
+            client, TermMethod.send, TermSendParams(pane: try #require(created.pane), text: "echo secret-text"),
+            as: JSONValue.self)
+
+        let calls = await logged(workspace, "cli")
+        try #require(calls.count == 3)
+        guard case .object(let rowNew) = calls[1].data["params"], case .object(let send) = calls[2].data["params"]
+        else {
+            Issue.record("params are not objects")
+            return
+        }
+        #expect(rowNew["branch"] == "feat/cli" && rowNew["run"] == nil)
+        #expect(send["pane"] == .string(created.pane!) && send["text"] == nil)
+    }
+
+    @Test func textStartingWithASpaceIsLeftOutOfCalls() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let (workspace, server, client, _) = try await startServer(dir)
+        defer { server.stop() }
+
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+        let created = try await call(
+            client, ControlMethod.rowNew,
+            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", setup: false, run: "true"),
+            as: RowNewResult.self)
+        let pane = try #require(created.pane)
+        _ = try await call(client, TermMethod.send, TermSendParams(pane: pane, text: " hunter2"), as: JSONValue.self)
+        _ = try await call(client, TermMethod.send, TermSendParams(pane: pane, text: "ls"), as: JSONValue.self)
+
+        let sends = await logged(workspace, "cli").filter { $0.data["method"] == "term.send" }
+        let texts = sends.map { event -> JSONValue? in
+            guard case .object(let params) = event.data["params"] else { return nil }
+            return params["text"]
+        }
+        #expect(texts == [nil, "ls"])
+    }
+
     @Test func errorsCarryCodes() async throws {
         let dir = try TempDir()
         let (_, server, client, _) = try await startServer(dir)
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ControlServerTests`
Expected: `callsThatChangeSomethingAreLoggedAsTheCLIs` fails with no `cli.call` events and `ui` sources, and the other new test fails its count.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Control/ControlMethods.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/ControlMethods.swift
+++ b/Sources/CanopyCore/Control/ControlMethods.swift
@@ -12,6 +12,11 @@ public enum ControlMethod {
     public static let rowAdopt = "row.adopt"
     public static let prShow = "pr.show"
 
+    /// Methods that only read, which the activity log leaves out: agents poll some of them every few seconds.
+    public static let readOnly: Set<String> = [
+        status, repoList, rowList, prShow, TermMethod.list, TermMethod.read, PortMethod.list,
+    ]
+
     /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo, so they
     /// can take minutes. Creating and removing rows also wait for setup or teardown, which can run for as long as
     /// a build does and cannot be cancelled, so the CLI waits for them without a limit. A PR lookup can queue
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
+++ b/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
@@ -27,6 +27,12 @@ public struct WorkspaceControlHandler: Sendable {
                 )
             )
         }
+        let response = await ActivitySource.$current.withValue(.cli) { await respond(to: request) }
+        record(request, response)
+        return response
+    }
+
+    private func respond(to request: ControlRequest) async -> ControlResponse {
         do {
             return .success(id: request.id, result: try await result(for: request))
         } catch let error as WorkspaceError {
@@ -38,6 +44,26 @@ public struct WorkspaceControlHandler: Sendable {
         }
     }
 
+    /// Logs calls that change something, with their params as sent and the error code if they failed. Commands typed
+    /// into terminals are left out while command logging is off, and so is text starting with a space, which zsh keeps
+    /// out of history under hist_ignore_space.
+    private func record(_ request: ControlRequest, _ response: ControlResponse) {
+        guard !ControlMethod.readOnly.contains(request.method) else { return }
+        var params = request.params ?? .object([:])
+        if case .object(var fields) = params {
+            for key in ["run", "text"] {
+                guard case .string(let typed) = fields[key] else { continue }
+                if !workspace.activity.logsCommands || typed.hasPrefix(" ") { fields[key] = nil }
+            }
+            params = .object(fields)
+        }
+        var data: [String: JSONValue] = ["method": .string(request.method), "params": params]
+        if let error = response.error {
+            data["error"] = .string(error.code)
+        }
+        workspace.activity.record(ActivityType.cliCall, source: .cli, data: data)
+    }
+
     private func result(for request: ControlRequest) async throws -> JSONValue {
         switch request.method {
         case ControlMethod.status:
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`.
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: log CLI calls that change something"
```

## Task 7: `canopy log`

**Files:** Create `Sources/CanopyCore/Activity/ActivityReader.swift` and `Sources/CanopyCLI/LogCommand.swift`.
Modify `CanopyCLI.swift`, `AgentGuide.swift`, `scripts/e2e.sh`, and the spec.
Test `Tests/CanopyCoreTests/ActivityReaderTests.swift`.

**Interfaces:**
- Consumes `ActivityEvent` and `ActivityLog.fileName(for:)` from Task 1.
- Produces `ActivityReader.events(in:since:until:types:)`, `LogTime.parse(_:now:)` with `LogTimeError`, and `ActivityEvent.localTime` and `summary`.

The reader opens only the files a day either side of the range, in case the time zone moved, and drops whatever follows a file's last newline, which is a line still being written.
Lines the log wrote start with `ts`, so the reader checks the time before decoding the rest, and sorts what it keeps by time, stably.
A type matches itself or any type it starts with followed by a dot, so `row` is every row event but `row.cr` is nothing.
`LogTime` takes a span back from now (`30m`, `2h`, `3d`, `1w`), `now`, `today`, `yesterday`, a date, a local date and time, a time today, or full ISO 8601, and refuses dates that do not exist, like the 31st of September.
A time the clocks skip when daylight saving starts moves forward to one that exists.
`summary` shows control characters in caret form, like `^[`, so a command cannot break the table or reach the terminal.
`canopy log` defaults to the last 24 hours, prints a table of time, type, source, repo, row, and details, and prints a JSON array with `--json`.
The e2e run checks sources end to end, runs a failing command in a real zsh pane when the login shell is zsh, and reads the log after the app has quit.
The spec's "Activity log" section now says how the shim works, why it sends no OSC 133, which calls are left out, and what `logCommands` covers.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ActivityReaderTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

struct ActivityReaderTests {
    static var calendar: Calendar { .localGregorian() }

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func write(_ lines: [String], to folder: URL, day: String, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: folder.appending(path: "\(day).jsonl"), atomically: true, encoding: .utf8)
    }

    func line(_ type: String, at date: Date, data: [String: JSONValue] = [:]) throws -> String {
        try ActivityEvent(date: date, type: type, source: .git, data: data).jsonLine()
    }

    @Test func readsEventsInOrderAcrossDays() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        try write([try line("row.created", at: Self.date(27, 23))], to: folder, day: "2026-09-27")
        try write([try line("row.removed", at: Self.date(28, 1))], to: folder, day: "2026-09-28")

        let events = ActivityReader.events(in: folder, since: Self.date(27, 22), until: nil)

        #expect(events.map(\.type) == ["row.created", "row.removed"])
    }

    @Test func skipsAPartialLastLineAndLinesItCannotRead() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        let lines = [
            try line("row.created", at: Self.date(28, 1)), "not json", #"{"ts": "2026-09-28T01:00:00.000+10:00"}"#,
            try line("row.removed", at: Self.date(28, 2)), #"{"ts":"2026-09-28T03:0"#,
        ]
        try write(lines, to: folder, day: "2026-09-28", trailingNewline: false)

        let events = ActivityReader.events(in: folder, since: Self.date(27, 0), until: nil)

        #expect(events.map(\.type) == ["row.created", "row.removed"])
    }

    @Test func filtersByTimeAndType() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        let lines = [
            try line("row.created", at: Self.date(28, 1)), try line("term.command", at: Self.date(28, 2)),
            try line("row.removed", at: Self.date(28, 3)), try line("row.branch_changed", at: Self.date(28, 4)),
        ]
        try write(lines, to: folder, day: "2026-09-28")
        let read = { (since: Date, until: Date?, types: [String]) in
            ActivityReader.events(in: folder, since: since, until: until, types: types).map(\.type)
        }

        #expect(read(Self.date(28, 2), nil, []) == ["term.command", "row.removed", "row.branch_changed"])
        #expect(read(Self.date(28, 0), Self.date(28, 3), []) == ["row.created", "term.command"])
        #expect(read(Self.date(28, 0), nil, ["row"]) == ["row.created", "row.removed", "row.branch_changed"])
        #expect(read(Self.date(28, 0), nil, ["term.command", "row.removed"]) == ["term.command", "row.removed"])
        #expect(read(Self.date(28, 0), nil, ["row.cr"]).isEmpty)
    }

    @Test func eventsComeOutInTimeOrder() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        // After moving west, events land in the file of a date that has already passed elsewhere.
        try write([try line("row.removed", at: Self.date(28, 3))], to: folder, day: "2026-09-27")
        try write([try line("row.created", at: Self.date(28, 1))], to: folder, day: "2026-09-28")

        let events = ActivityReader.events(in: folder, since: Self.date(27, 0), until: nil)

        #expect(events.map(\.type) == ["row.created", "row.removed"])
    }

    @Test func aMissingFolderHasNoEvents() throws {
        let dir = try TempDir()

        #expect(
            ActivityReader.events(in: URL(fileURLWithPath: dir.sub("none")), since: .distantPast, until: nil).isEmpty)
    }

    @Test func readsTheTimesPeopleType() throws {
        let now = Self.date(28, 15, 45)
        let parse = { (text: String) in try LogTime.parse(text, now: now) }

        #expect(try parse("30m") == now.addingTimeInterval(-1800))
        #expect(try parse("45s") == now.addingTimeInterval(-45))
        #expect(try parse("2h") == now.addingTimeInterval(-7200))
        #expect(try parse("3d") == Self.calendar.date(byAdding: .day, value: -3, to: now))
        #expect(try parse("1w") == Self.calendar.date(byAdding: .day, value: -7, to: now))
        #expect(try parse("now") == now)
        #expect(try parse("today") == Self.date(28, 0))
        #expect(try parse("yesterday") == Self.date(27, 0))
        #expect(try parse("2026-09-27") == Self.date(27, 0))
        #expect(try parse("2026-09-27T14:30") == Self.date(27, 14, 30))
        #expect(try parse("2026-09-27 14:30:15") == Self.date(27, 14, 30).addingTimeInterval(15))
        #expect(try parse("9:05") == Self.date(28, 9, 5))
        #expect(try parse("2026-09-27T11:15:03Z") == Date(timeIntervalSince1970: 1_790_507_703))
        #expect(try parse("2026-09-27T21:15:03.500+10:00") == Date(timeIntervalSince1970: 1_790_507_703.5))
        // Days that start with the clocks going forward, when midnight or 2:30 never happens.
        let santiago = try #require(TimeZone(identifier: "America/Santiago"))
        let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
        let noMidnight = try LogTime.parse("2026-09-06", now: now, timeZone: santiago)
        #expect(
            Calendar.localGregorian(in: santiago).dateComponents([.day, .hour], from: noMidnight)
                == .init(day: 6, hour: 1))
        let noHalfPastTwo = try LogTime.parse("2026-10-04T02:30", now: now, timeZone: sydney)
        #expect(
            Calendar.localGregorian(in: sydney).dateComponents([.day, .hour], from: noHalfPastTwo)
                == .init(day: 4, hour: 3))
        for text in ["soon", "2026-13-01", "2026-09-31", "25:00", "9:60", "9:5", "30", "-2h"] {
            #expect(throws: LogTimeError.self, "\(text)") { try parse(text) }
        }
    }

    @Test func eachKindOfEventReadsAsOneLine() {
        let date = Self.date(28, 14, 2)
        let summary = { (type: String, data: [String: JSONValue]) in
            ActivityEvent(date: date, type: type, path: "/r/demo", source: .ui, data: data).summary
        }

        #expect(summary("repo.added", [:]) == "/r/demo")
        #expect(summary("row.created", ["class": "canopy"]) == "canopy")
        #expect(summary("row.branch_changed", ["from": "feat/y", "to": .null]) == "feat/y -> detached")
        #expect(
            summary("pr.opened", ["number": 12, "title": "Fix it", "state": "draft", "url": "https://x/12"])
                == "#12 draft: Fix it https://x/12")
        #expect(summary("pr.state_changed", ["number": 12, "from": "open", "to": "merged"]) == "#12 open -> merged")
        #expect(summary("term.opened", ["pane": "p3"]) == "p3")
        #expect(summary("term.exited", ["pane": "p3", "code": 129]) == "p3 exit 129")
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "make\nmake test", "exit": 2, "durationMs": 83_250])
                == "p3 exit 2 in 1m23s: make \u{21b5} make test")
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "ls", "exit": 0, "durationMs": 45]) == "p3 exit 0 in 45ms: ls"
        )
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "printf 'a\tb\u{1b}[31m'", "exit": 0])
                == "p3 exit 0: printf 'a b^[[31m'")
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "ls", "exit": 0, "durationMs": 1240])
                == "p3 exit 0 in 1.2s: ls")
        #expect(
            summary(
                "cli.call",
                [
                    "method": "row.new", "error": "invalid_branch",
                    "params": .object(["branch": "bad name", "target": .object(["cwd": "/"])]),
                ]) == #"row.new {"branch":"bad name"} failed: invalid_branch"#)
        #expect(ActivityEvent(date: date, type: "x", source: .ui).localTime == "2026-09-28 14:02:00")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ActivityReaderTests`
Expected: does not compile, `ActivityReader`, `LogTime`, and `ActivityEvent.summary` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCLI/AgentGuide.swift` (modify):

```diff
--- a/Sources/CanopyCLI/AgentGuide.swift
+++ b/Sources/CanopyCLI/AgentGuide.swift
@@ -62,6 +62,17 @@ struct AgentGuide: ParsableCommand {
         right after a push. `--refresh` asks GitHub now, for example right after `gh pr create`.
         `row list --json` also carries each row's PR as "pr" when it has one.
 
+        ## Activity
+
+            canopy log [--since <when>] [--until <when>] [--type <t>]   what happened, oldest first
+
+        Canopy logs repos and rows coming and going, rows switching branch, PRs opening and changing state, terminals
+        opening and exiting, each command that finishes in a zsh terminal with its exit code and duration, and each
+        canopy call that changes something. Each event's source says whether it came from the Canopy window (ui), a
+        canopy command (cli), or outside Canopy (git). `--since` defaults to 24 hours ago and takes 30m, 2h, 3d, today,
+        yesterday, 2026-09-27, or 2026-09-27T14:30. `--type row` matches every row event, `--type term.command` one.
+        `canopy log` reads the log files directly, so it works while Canopy is not running.
+
         ## Examples
 
         Start a parallel agent on a fix in its own row, then check on it:
@@ -74,6 +85,10 @@ struct AgentGuide: ParsableCommand {
             pane=$(canopy term new --tab Server --run 'bun dev' --title 'dev server' --json | jq -r .pane)
             canopy term read "$pane"
 
+        See which commands failed in the last hour, in any row:
+
+            canopy log --since 1h --type term.command --json | jq '.[] | select(.data.exit != 0) | .data.cmd'
+
         Clean up when the work is merged:
 
             canopy row rm fix/login-redirect --delete-branch
```

`Sources/CanopyCLI/CanopyCLI.swift` (modify):

```diff
--- a/Sources/CanopyCLI/CanopyCLI.swift
+++ b/Sources/CanopyCLI/CanopyCLI.swift
@@ -10,7 +10,7 @@ struct CanopyCLI: AsyncParsableCommand {
         version: CanopyVersion.current,
         subcommands: [
             Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, PortsCommand.self, PRCommand.self,
-            AgentGuide.self,
+            LogCommand.self, AgentGuide.self,
         ]
     )
 }
```

`Sources/CanopyCLI/LogCommand.swift` (new):

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Print what happened in Canopy, oldest first.",
        discussion: """
            Canopy logs repos and rows coming and going, rows switching branch, pull requests opening and changing \
            state, terminals opening and exiting, commands that finish in zsh terminals, and canopy calls that \
            change something. It reads the log files in CANOPY_HOME/activity directly, so it works while Canopy \
            is not running.

            Times can be 30s, 15m, 2h, 3d, 1w, today, yesterday, a date like 2026-09-27, a local time like \
            2026-09-27T14:30 or 14:30, or a full ISO 8601 timestamp.
            """
    )

    @Option(help: "Start here. Defaults to 24 hours ago.")
    var since = "24h"
    @Option(help: "Stop before this time.")
    var until: String?
    @Option(
        help: ArgumentHelp(
            "Only events of this type, such as term.command, or of this kind, such as row. Repeat or separate with commas.",
            valueName: "type"))
    var type: [String] = []
    @OptionGroup var output: OutputOptions

    func run() throws {
        let client = Client(json: output.json)
        let since: Date
        let until: Date?
        do {
            since = try LogTime.parse(self.since)
            until = try self.until.map { try LogTime.parse($0) }
        } catch let error as LogTimeError {
            client.fail(ControlError(code: "bad_params", message: error.description))
        }
        let types = type.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let events = ActivityReader.events(
            in: client.home.activityFolder, since: since, until: until, types: types.filter { !$0.isEmpty })
        try client.print(try .from(events)) {
            guard !events.isEmpty else { return "No activity." }
            return Table.render(
                ["TIME", "TYPE", "SOURCE", "REPO", "ROW", "DETAILS"],
                events.map { [$0.localTime, $0.type, $0.source.rawValue, $0.repo ?? "", $0.row ?? "", $0.summary] }
            )
        }
    }
}
```

`Sources/CanopyCore/Activity/ActivityReader.swift` (new):

```swift
import Foundation

/// Reads the activity log files directly, so `canopy log` works while Canopy is not running.
public enum ActivityReader {
    /// Events from `since` up to but not including `until`, oldest first. `types` keeps events whose type is one of
    /// them, or starts with one and a dot, so "row" matches every row event.
    public static func events(in folder: URL, since: Date, until: Date?, types: [String] = []) -> [ActivityEvent] {
        // Files hold events by the local date they were recorded on, so a day either side covers a changed time zone.
        let first = ActivityLog.fileName(for: since.addingTimeInterval(-86_400))
        let last = until.map { ActivityLog.fileName(for: $0.addingTimeInterval(86_400)) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { name in name.hasSuffix(".jsonl") && name >= first && last.map { name <= $0 } ?? true }
            .sorted()
        let decoder = JSONDecoder()
        var events: [(date: Date, event: ActivityEvent)] = []
        for name in names {
            guard let data = FileManager.default.contents(atPath: folder.appending(path: name).path) else { continue }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            // Whatever follows the last newline is a line the writer has not finished.
            lines.removeLast()
            for line in lines {
                let inRange = { (date: Date) in date >= since && until.map { date < $0 } ?? true }
                // Most lines of a day's file are outside a short range, so check the time before decoding the rest.
                if let date = timestamp(of: line), !inRange(date) { continue }
                guard let event = try? decoder.decode(ActivityEvent.self, from: Data(line)), let date = event.date,
                    inRange(date),
                    types.isEmpty || types.contains(where: { event.type == $0 || event.type.hasPrefix($0 + ".") })
                else { continue }
                events.append((date, event))
            }
        }
        // A moved clock can put an event in an earlier file than events recorded before it.
        return events.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element.event)
    }

    private static let prefix = Array(#"{"ts":""#.utf8)

    /// The time of a line the log wrote, which always starts with `ts`.
    private static func timestamp(of line: Data.SubSequence) -> Date? {
        guard line.starts(with: prefix) else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        guard let end = line[start...].firstIndex(of: 0x22) else { return nil }
        return try? ActivityEvent.timestamp(in: .gmt).parse(String(decoding: line[start..<end], as: UTF8.self))
    }
}

public struct LogTimeError: Error, Equatable, CustomStringConvertible {
    public var text: String

    public var description: String {
        "Cannot read \"\(text)\" as a time. Use 30m, 2h, 3d, 1w, today, yesterday, 2026-09-27, 2026-09-27T14:30, or 14:30."
    }
}

/// The times `canopy log --since` and `--until` take: a span back from now, a day, a local date and time, a time today,
/// or a full ISO 8601 timestamp.
public enum LogTime {
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Date {
        let calendar = Calendar.localGregorian(in: timeZone)
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch lowered {
        case "now": return now
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        default: break
        }
        if let span = lowered.wholeMatch(of: /(\d{1,6})([smhdw])/), let count = Int(span.1) {
            let seconds = ["s": 1, "m": 60, "h": 3600][String(span.2)]
            if let seconds { return now.addingTimeInterval(-Double(count * seconds)) }
            let days = span.2 == "w" ? count * 7 : count
            if let date = calendar.date(byAdding: .day, value: -days, to: now) { return date }
        }
        if let match = lowered.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})(?:[t ](\d{1,2}):(\d{2})(?::(\d{2}))?)?/) {
            let parts = [match.1, match.2, match.3, match.4 ?? "0", match.5 ?? "0", match.6 ?? "0"].map {
                Int($0) ?? -1
            }
            if let date = local(parts, calendar) { return date }
        } else if let match = lowered.wholeMatch(of: /(\d{1,2}):(\d{2})(?::(\d{2}))?/) {
            let today = calendar.dateComponents([.year, .month, .day], from: now)
            let parts =
                [today.year ?? 0, today.month ?? 0, today.day ?? 0]
                + [match.1, match.2, match.3 ?? "0"].map { Int($0) ?? -1 }
            if let date = local(parts, calendar) { return date }
        } else {
            for fractional in [true, false] {
                let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: fractional)
                if let date = try? style.parse(text.trimmingCharacters(in: .whitespaces)) { return date }
            }
        }
        throw LogTimeError(text: text)
    }

    /// Year, month, day, hour, minute, and second as a local date, or nil if they name no real day, like the 31st of
    /// September. A time the clocks skip, as when daylight saving starts, moves forward to one that exists.
    private static func local(_ parts: [Int], _ calendar: Calendar) -> Date? {
        guard (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5]) else { return nil }
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let date = calendar.date(from: components) else { return nil }
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return [day.year, day.month, day.day] == parts.prefix(3).map(Optional.some) ? date : nil
    }
}

extension ActivityEvent {
    /// When it happened, in this machine's time zone, such as 2026-09-27 21:15:03.
    public var localTime: String {
        guard let date else { return ts }
        let parts = Calendar.localGregorian().dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// What the event's data says, in a few words, for `canopy log`. Control characters show as `^[` and the like,
    /// so a command cannot break the table or reach the terminal.
    public var summary: String {
        String(
            details.unicodeScalars.flatMap { scalar -> [Character] in
                switch scalar.value {
                case 0x09: [" "]
                case 0x00..<0x20: ["^", Character(Unicode.Scalar(UInt8(scalar.value + 0x40)))]
                case 0x7F: ["^", "?"]
                default: [Character(scalar)]
                }
            })
    }

    private var details: String {
        let pane = text("pane") ?? ""
        switch type {
        case ActivityType.repoAdded, ActivityType.repoRemoved:
            return path ?? ""
        case ActivityType.rowCreated, ActivityType.rowAdopted, ActivityType.rowRemoved:
            return text("class") ?? ""
        case ActivityType.rowBranchChanged:
            return "\(text("from") ?? "detached") -> \(text("to") ?? "detached")"
        case ActivityType.prOpened:
            return "#\(number("number") ?? 0) \(text("state") ?? ""): \(text("title") ?? "") \(text("url") ?? "")"
        case ActivityType.prStateChanged:
            return "#\(number("number") ?? 0) \(text("from") ?? "") -> \(text("to") ?? "")"
        case ActivityType.termOpened:
            return pane
        case ActivityType.termExited:
            return "\(pane) exit \(number("code") ?? 0)"
        case ActivityType.termCommand:
            let took = number("durationMs").map { " in \(Self.duration(milliseconds: $0))" } ?? ""
            let command = (text("cmd") ?? "").replacingOccurrences(of: "\n", with: " \u{21b5} ")
            return "\(pane) exit \(number("exit") ?? 0)\(took): \(command)"
        case ActivityType.cliCall:
            var params = data["params"]
            if case .object(var fields) = params {
                fields["target"] = nil
                params = fields.isEmpty ? nil : .object(fields)
            }
            let failed = text("error").map { " failed: \($0)" } ?? ""
            return [text("method"), params.map(Self.compact)].compactMap { $0 }.joined(separator: " ") + failed
        default:
            return data.isEmpty ? "" : Self.compact(.object(data))
        }
    }

    private func text(_ key: String) -> String? {
        if case .string(let value) = data[key] { value } else { nil }
    }

    private func number(_ key: String) -> Int? {
        if case .number(let value) = data[key] { Int(value) } else { nil }
    }

    static func duration(milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return String(format: "%.1fs", Double(milliseconds) / 1000) }
        let seconds = milliseconds / 1000
        if seconds < 3600 { return String(format: "%dm%02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh%02dm", seconds / 3600, seconds % 3600 / 60)
    }

    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
```

`docs/superpowers/specs/2026-09-27-canopy-design.md` (modify):

```diff
--- a/docs/superpowers/specs/2026-09-27-canopy-design.md
+++ b/docs/superpowers/specs/2026-09-27-canopy-design.md
@@ -234,7 +234,7 @@ A session exposes:
 - its NSView, its shell PID, and its current title
 - writing input and resizing
 - reading the visible screen and the last N lines of scrollback as plain text
-- events for title changes, bell, process exit with code, and shell integration marks
+- events for title changes, bell, and process exit with code
 
 Nothing outside the SwiftTerm implementation imports SwiftTerm.
 
@@ -484,10 +484,12 @@ Every command exits non-zero on failure.
 | `canopy ports [--all]` | list ports for the resolved row, or for all rows with `--all` or when no row resolves |
 | `canopy ports stop <port>` | stop the process holding a port |
 | `canopy pr [--refresh]` | show the current row's PR |
-| `canopy log [--since <when>] [--until <when>] [--type <t>]` | print activity events |
+| `canopy log [--since <when>] [--until <when>] [--type <t>]` | print activity events, from 24 hours ago by default |
 | `canopy agent-guide` | print a manual written for agents |
 
 `canopy log` reads the activity files directly, so it works while the app is not running.
+Times can be a span back from now such as `30m`, `2h`, or `3d`, `today`, `yesterday`, a date, a local date and time, a time today, or a full ISO 8601 timestamp.
+`--type` takes a type such as `term.command`, or a kind such as `row` for every row event.
 
 `canopy agent-guide` explains rows, target resolution, and the commands, with worked examples such as spawning a parallel agent:
 
@@ -505,38 +507,63 @@ One line in a global `CLAUDE.md` pointing at `canopy agent-guide` is enough for
 Each event is one JSON line appended to `CANOPY_HOME/activity/<local date>.jsonl`.
 
 ```json
-{"ts": "2026-09-27T21:15:03.123+10:00", "type": "row.created", "repo": "solis-v1", "row": "fix/login", "path": "...", "source": "cli", "data": {}}
+{"ts": "2026-09-27T21:15:03.123+10:00", "type": "row.created", "repo": "solis-v1", "row": "fix/login", "path": "...", "source": "cli", "data": {"class": "canopy"}}
 ```
 
-`source` is `ui`, `cli`, or `git` (detected from outside Canopy).
+`source` is `ui` for what is done in Canopy's window, including commands typed in its terminals, `cli` for a `canopy` command, or `git` for a change Canopy noticed rather than made, such as git run in any terminal, Canopy's own included, or a PR changing on GitHub.
+`repo`, `row`, and `path` are left out when an event is not about one, as for `cli.call`.
 One writer in the app serializes all appends.
-Readers skip a trailing partial line.
+Readers skip a trailing partial line and any line they cannot read.
 
 ### Events
 
 | Type | Recorded when | `data` |
 |---|---|---|
 | `repo.added`, `repo.removed` | a repo is registered or unregistered | |
-| `row.created`, `row.adopted`, `row.removed` | a row appears, is adopted, or goes away | `class` |
-| `row.branch_changed` | a row's HEAD moves to another branch | `from`, `to` |
-| `pr.opened` | a row goes from no PR to a PR | `number`, `url` |
-| `pr.state_changed` | a PR moves between draft, open, merged, and closed | `number`, `from`, `to` |
-| `term.opened`, `term.exited` | a pane starts or its shell exits | `pane`, `code` |
+| `row.created`, `row.adopted`, `row.removed` | a row appears, is adopted, or goes away, including being un-adopted | `class` |
+| `row.branch_changed` | a row's HEAD moves to another branch | `from`, `to`, null when detached |
+| `pr.opened` | a row's branch goes from no PR, or a closed one, to a new PR | `number`, `title`, `state`, `url` |
+| `pr.state_changed` | a PR moves between draft, open, merged, and closed | `number`, `from`, `to`, `url` |
+| `term.opened`, `term.exited` | a pane's shell starts, including a restart, or exits | `pane`, `code` |
 | `term.command` | a command finishes in a zsh pane | `pane`, `cmd`, `cwd`, `exit`, `durationMs` |
-| `cli.call` | the CLI makes a request | `method`, `params` |
+| `cli.call` | a `canopy` request changes something | `method`, `params`, `error` when it failed |
 
-When Canopy creates or removes a row itself, it marks the path as expected before calling git.
-The watcher then skips that path, so each row change is logged once with the right `source`.
+Row and PR changes are found by comparing each worktree list and each PR lookup with the one before.
+The first one after launching or adding a repo only sets the baseline, so what already existed is not logged.
+A PR lookup `gh` could not make keeps the baseline, so PRs coming back after `gh auth login` are not logged as new.
+Among closed PRs a branch shows the most recently updated, so one closed PR taking over from another is not an opening.
+
+git lists a worktree halfway through `git worktree add` with a detached, all-zero HEAD, so such a row is compared only once it is whole.
+When Canopy creates, removes, or prunes a row itself, it marks the path with the source that asked before calling git, and refreshes leave the path alone until the operation ends.
+The operation then logs how the row ended up, so each row change is logged once with the right `source`.
+If git reports the main checkout somewhere other than where it was registered, the folder moved while git ran, and the repo shows as missing.
+
+`cli.call` leaves out requests that only read: `status`, `repo list`, `row list`, `term list`, `term read`, `ports`, and `pr`.
+Agents poll some of them every few seconds, which would bury everything else.
 
 ### Command logging
 
 Canopy starts zsh with `ZDOTDIR` pointing at `CANOPY_HOME/shell/zsh`.
-The shim files there restore the user's original `ZDOTDIR` and source the user's own `.zshenv`, `.zprofile`, `.zshrc`, and `.zlogin` first, so the user's setup is unchanged.
-They then add `preexec` and `precmd` hooks that emit OSC 133 prompt and command marks, plus a private OSC sequence carrying the command text.
-The terminal engine turns these into `term.command` events.
+The `.zshenv` there puts `ZDOTDIR` back and sources the user's own `.zshenv`, so zsh then reads the user's `.zprofile`, `.zshrc`, and `.zlogin` from their usual place, and the user's setup is unchanged.
+It adds `preexec` and `precmd` hooks.
+After each command, `precmd` prints one private OSC 6973 sequence carrying the command, the folder it started in, its exit code, and its duration, percent-encoded.
+The pane reads these from its output before the terminal engine draws it, and records `term.command`.
+
+Each shell gets a random token in `CANOPY_COMMAND_TOKEN`.
+The shim takes it out of the environment and puts it in every report, so output that happens to replay a report, such as `cat` of a recorded session, is ignored.
+Each hook puts the other back if the user's `.zshrc` replaces its list, and the app writes the shim again before starting zsh if it went missing, since zsh pointed at an empty folder would skip the user's startup files.
+A zsh started inside the pane, including `exec zsh`, runs without the shim, so its commands are not logged.
+
+The shim sends no OSC 133 marks.
+SwiftTerm acts on them, and a prompt mark sent from `precmd` starts a fresh line before zsh can show its `%` after output that did not end in a newline.
+Nothing in Canopy reads them yet.
 
 Commands can contain secrets.
-The log never leaves the machine, only the user can read it, and `"logCommands": false` in `config.json` turns command logging off.
+The log never leaves the machine and only the user can read it.
+A command starting with a space is left out when the user has `hist_ignore_space` set, and one matching `HISTORY_IGNORE` is left out too, as zsh keeps both out of the history file.
+`zshaddhistory` hooks are not consulted.
+`cli.call` events leave out `run` and `text` params that start with a space for the same reason.
+`"logCommands": false` in `config.json` turns command logging off from the next launch: zsh starts without the shim, and `cli.call` events leave out the `run` and `text` params.
 
 ## Error handling
 
@@ -593,6 +620,5 @@ If SwiftTerm fails, a follow-up `docs` PR amends this spec before PR 2.
   The layout math lives in `CanopyCore` as pure functions so it can be tested without UI.
 - **Single process** means quitting stops every agent.
   Mitigated by the quit confirmation and dev builds with their own data folder.
-- **Private OSC handling in SwiftTerm** is assumed, not verified.
-  The spike checks it.
-  If it is missing, command events come from parsing OSC 133 marks alone and the command text is read from the screen.
+- **Private OSC handling in SwiftTerm** is not needed.
+  Panes read the shim's command reports from the output before the engine draws it, so logging works whatever the engine.
```

`scripts/e2e.sh` (modify):

```diff
--- a/scripts/e2e.sh
+++ b/scripts/e2e.sh
@@ -217,6 +217,36 @@ else
     echo "skipped: needs gh logged in and an origin on GitHub with a merged PR"
 fi
 
+step "canopy log shows what happened, with who did it"
+"$cli" log --json > "$work/log.json"
+/usr/bin/python3 - "$work/log.json" <<'EOF' || fail "canopy log is missing events"
+import json, sys
+events = json.load(open(sys.argv[1]))
+seen = {(e["type"], e["source"]) for e in events}
+need = {("repo.added", "cli"), ("row.created", "cli"), ("row.created", "git"), ("row.removed", "cli"),
+        ("term.opened", "cli"), ("cli.call", "cli")}
+missing = need - seen
+if missing:
+    sys.exit(f"missing {sorted(missing)}")
+if any(e["type"] == "cli.call" and e["data"]["method"] in ("row.list", "term.read") for e in events):
+    sys.exit("read-only calls were logged")
+EOF
+"$cli" log --type row.created | grep -q "feat/plain" || fail "canopy log does not show the plain git row"
+
+step "commands that finish in a zsh terminal are logged"
+if [[ "$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')" == */zsh ]]; then
+    "$cli" term new --repo demo --row feat/term --run '(exit 7)' >/dev/null
+    for _ in $(seq 1 100); do
+        "$cli" log --type term.command | grep -q "exit 7 in .*: (exit 7)" && break
+        sleep 0.1
+    done
+    "$cli" log --type term.command | grep -q "exit 7 in .*: (exit 7)" || fail "the command was not logged"
+    [[ -f "$CANOPY_HOME/shell/zsh/.zshenv" ]] || fail "the zsh shim is missing"
+else
+    echo "skipped: the login shell is not zsh"
+fi
+"$cli" agent-guide | grep -q "canopy log" || fail "agent-guide is missing canopy log"
+
 step "errors are machine-readable"
 if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
 grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"
@@ -227,5 +257,15 @@ if CANOPY_APP=/nonexistent CANOPY_HOME="$work/nobody" "$cli" row list --json > "
 fi
 grep -q '"app_unavailable"' "$work/err2.json" || fail "no JSON error when the app cannot be launched"
 
+step "canopy log works while Canopy is not running"
+kill "$(app_pid)"
+for _ in $(seq 1 50); do
+    [[ -z "$(app_pid)" ]] && break
+    sleep 0.1
+done
+[[ -z "$(app_pid)" ]] || fail "the app did not quit"
+"$cli" log --type repo.added | grep -q demo || fail "canopy log needs the app"
+[[ -z "$(app_pid)" ]] || fail "canopy log launched the app"
+
 echo
 echo "e2e passed"
```

- [ ] **Step 4: Run the tests and the end-to-end run**

Run: `make lint && make test && make e2e`.
Expected: every test passes, and e2e ends with "e2e passed".

- [ ] **Step 5: Commit**

```bash
git add Sources Tests scripts docs
git commit -m "feat: canopy log prints the activity log"
```

## After Review

The fixes below are folded into the tasks above, so each task's code is the version that shipped.

Running the whole suite many times turned up two races in Task 2, each now pinned by a test that forces it:
- A refresh that ran during `git worktree add` saw the new row detached with an all-zero HEAD, and logged it as created and then as switching branch.
  Rows Canopy is changing are now left out of refreshes until the operation logs how they ended up, and rows git is still creating wait until they are whole.
- A refresh whose `git worktree list` started just before the repo folder moved saw git follow the folder, and logged the main row as removed and created at the new path.
  A main checkout reported away from where it was registered now shows the repo as missing.

Reading the design again turned up two more:
- Panes kept the row name they opened with, so after `git switch` their events, and `canopy term list`, named the old branch.
  The app now updates pane names from each snapshot.
- The hook installer read `precmd_functions` without `emulate -L zsh`, so a `.zshrc` with `ksh_arrays` lost its own hooks.

An independent review found no blockers.
Its findings, and what was done:
- A `.zshrc` that replaces `precmd_functions` threw away the installer, turning logging off.
  Both hooks now go in at once and each puts the other back.
- A shim folder deleted while Canopy ran left new zsh panes without the user's startup files.
  The shim is written again, if needed, before each zsh starts, and zsh starts plainly if that fails.
- A closed PR taking over from another closed PR as the branch's most recently updated was logged as opened.
  `pr.opened` now needs no earlier PR, or a new one that is open or a draft.
- A branch with no commits yet has an all-zero HEAD too, so its row was held back as if still being created and then logged as new.
  Only a detached all-zero HEAD is held back now.
- A prune or remove that failed partway did not refresh first, so rows git had already changed were later logged with source `git`.
- `canopy log --since` rejected dates whose midnight daylight saving skips, as in Santiago.
  Skipped times now move forward.
- `canopy log` decoded every line of two days' files.
  It now checks each line's time first, about 0.5 seconds for 150,000 lines in a debug build, and sorts by time, which a changed time zone can disturb.
- Control characters in a logged command now show as `^[` and the like, so they cannot break the table or reach the terminal.
- Lines matching `HISTORY_IGNORE` are left out like those `hist_ignore_space` hides, and `cli.call` drops `run` and `text` params that start with a space.
- A pane that is closed stops reading reports, so no `term.command` lands after its `term.exited`.
- The app registers an empty OSC 6973 handler, so debug builds no longer print "Unknown OSC code" after every command.
- The spec now says the operation logs Canopy's own row changes, that `git` covers git run in Canopy's terminals too, that nested and `exec`'d zsh shells are not logged, and that `zshaddhistory` hooks are not consulted.
- Tests that expected `.ui`, the default source, now run under `.cli`, so they fail if the stored source is ignored.

Two suggestions were not taken:
- Making `activity:` required on `Workspace` and `TerminalStore`.
  The app passes one log to both.
  A second writer on the same folder could only reorder whole lines, since each append is one `O_APPEND` write, and the defaults keep every test's log inside its own home.
- Turning `ControlMethod.readOnly` into a list of methods to log.
  A new method that changes something should be logged until someone decides otherwise.
