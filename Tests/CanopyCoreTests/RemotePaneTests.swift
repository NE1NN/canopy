import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// Records what remote panes ask of their host.
@MainActor
final class RecordingRemoteHooks: RemotePaneHooks {
    var sent: [(session: String, text: String)] = []
    var killed: [[String]] = []

    func run(_ text: String, in pane: Pane) async {
        sent.append((pane.remoteSession ?? "", text))
    }

    func closed(_ panes: [Pane]) {
        killed.append(panes.compactMap(\.remoteSession))
    }
}

@MainActor
struct RemotePaneTests {
    func remoteContext(_ dir: TempDir) throws -> PaneContext {
        let standIn = dir.sub("stand-in")
        try FileManager.default.createDirectory(atPath: standIn, withIntermediateDirectories: true)
        var row = Row(
            remote: RemoteRowEntry(
                host: "box", path: "/home/u/.canopy/worktrees/demo/feat-x", standIn: standIn, branch: "feat/x",
                head: nil),
            repoPath: "/r/demo")
        row.group = nil
        return PaneContext(row: row, repoName: "demo")
    }

    @Test func aRemoteRowsPaneAttachesToASessionNamedAfterIt() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: try remoteContext(dir)).focused

        #expect(pane.context.remote == PaneRemote(host: "box", path: "/home/u/.canopy/worktrees/demo/feat-x"))
        #expect(pane.command == .remoteAttach)
        #expect(pane.remoteSession == pane.id.description)
        #expect(Fixture.context(dir.path).remote == nil)
    }

    @Test func savingAndRestoringKeepsTheSessionAndTheFolderOnTheHost() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = try remoteContext(dir)
        let pane = terminals.openTab(for: context).focused
        pane.remoteActivity = SessionActivity(busy: false, foreground: "bash", folder: "/home/u/elsewhere")

        let saved = try #require(terminals.saved()[context.rowPath])
        let restored = Fixture.terminals(dir)
        defer { restored.closeAll() }
        restored.continueNumbering(from: 50)
        restored.restore(saved, for: context)

        #expect(saved.tabs[0].layout.leaves == [SavedPane(folder: "/home/u/elsewhere", session: pane.id.description)])
        let again = try #require(restored.tabs(inRow: context.rowPath).first?.focused)
        #expect(again.remoteSession == pane.id.description)
        #expect(again.remoteFolder == "/home/u/elsewhere")
        #expect(again.id != pane.id)
    }

    @Test func aRemotePaneIsBusyWhileTheHostSaysAProgramRuns() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: try remoteContext(dir)).focused

        #expect(!pane.isBusy)
        pane.remoteActivity = SessionActivity(busy: true, foreground: "claude", folder: "/w")
        #expect(pane.isBusy)
        #expect(pane.foreground?.name == "claude")
        #expect(pane.currentDirectory == "/w")
        pane.remoteActivity = nil
        #expect(!pane.isBusy)
    }

    @Test func runTypesThroughTheHostAndClosingKillsSessionsButQuittingDoesNot() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let hooks = RecordingRemoteHooks()
        terminals.remoteHooks = hooks
        let context = try remoteContext(dir)
        let first = terminals.openTab(for: context).focused
        let second = terminals.openTab(for: context).focused

        await first.run("claude --full")
        terminals.closePane(first.id)
        terminals.closeAll()

        #expect(hooks.sent.map(\.session) == [first.id.description])
        #expect(hooks.sent.map(\.text) == ["claude --full"])
        #expect(hooks.killed == [[first.id.description]])
        _ = second
    }

    @Test func closingARowKillsEachOfItsSessions() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let hooks = RecordingRemoteHooks()
        terminals.remoteHooks = hooks
        let context = try remoteContext(dir)
        let first = terminals.openTab(for: context).focused
        let second = terminals.openTab(for: context).focused

        terminals.closeRow(path: context.rowPath)

        #expect(hooks.killed.flatMap { $0 }.sorted() == [first.id.description, second.id.description].sorted())
    }
}

struct RemoteAttachTests {
    @Test func tmuxStartsOrJoinsTheSessionInItsFolderWithThePanesVariables() throws {
        let command = RemoteAttach.tmuxCommand(
            server: "canopy-abcd1234", session: "p7", folder: "/home/u/my work",
            environment: ["CANOPY_PANE": "p7", "CANOPY_ROW_PATH": "/home/u/my work"])

        let dir = try TempDir()
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(toFile: dir.sub("tmux"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.sub("tmux"))
        let result = try Subprocess.run(
            "/bin/sh", ["-c", SSHCommand.shellQuoted(command)],
            environment: ["HOME": "/home/u", "PATH": dir.path + ":/usr/bin:/bin"], directory: nil, timeout: .seconds(10)
        )

        let words = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(
            words == [
                "-L", "canopy-abcd1234", "-f", "/home/u/.canopy/tmux.conf", "new-session", "-A", "-s", "p7", "-c",
                "/home/u/my work", "-e", "CANOPY_PANE=p7", "-e", "CANOPY_ROW_PATH=/home/u/my work",
            ])
    }

    @Test func aRemotePanesVariablesNameTheHostAndItsPaths() {
        let environment = RemoteAttach.environment(
            pane: "p7", rowName: "feat/x", repoName: "demo", host: "box", rowPath: "/home/u/wt", clone: "/home/u/demo")

        #expect(environment["CANOPY_ROW_PATH"] == "/home/u/wt")
        #expect(environment["CANOPY_ROOT_PATH"] == "/home/u/demo")
        #expect(environment["CANOPY_HOST"] == "box")
        #expect(environment["CANOPY_PANE"] == "p7")
        #expect(environment["CANOPY_REPO"] == "demo")
        #expect(environment["CANOPY_ROW"] == "feat/x")
        #expect(environment["TERM_PROGRAM"] == "Canopy")
        #expect(environment["CANOPY_HOME"] == nil)
        #expect(environment["ZDOTDIR"] == nil)
    }

    @Test func whatHappensWhenSSHEnds() {
        #expect(RemoteAttach.next(status: 0, state: .connected, host: "box").action == .end)
        let detached = RemoteAttach.next(status: 255, state: .detached, host: "box")
        #expect(detached.action == .waitForReturn)
        #expect(detached.message == "Detached so box can sleep. Press Return to reconnect.")
        #expect(
            RemoteAttach.next(status: 255, state: .idle, host: "box")
                == HostNextResult(action: .reconnect, message: "Lost box, reconnecting…"))
        #expect(RemoteAttach.next(status: 1, state: .connected, host: "box").action == .waitForReturn)
    }
}

struct Unreachable: Error, CustomStringConvertible {
    var description: String { "Could not connect to Canopy: Connection refused" }
}

/// Plays the app and the terminal for the attach loop.
final class AttachScript: @unchecked Sendable {
    /// Calls to `attach` that fail as an app that is not listening yet does, before `attaches` are answered.
    var refusals = 0
    var attaches: [HostAttachResult]
    var nexts: [HostNextResult]
    var lines: [String?]
    var printed: [String] = []
    var ran: [[String]] = []
    var statuses: [Int32]

    init(attaches: [HostAttachResult], nexts: [HostNextResult], lines: [String?] = [], statuses: [Int32]) {
        self.attaches = attaches
        self.nexts = nexts
        self.lines = lines
        self.statuses = statuses
    }

    var loop: RemoteAttachLoop {
        RemoteAttachLoop(
            attach: {
                if self.refusals > 0 {
                    self.refusals -= 1
                    throw Unreachable()
                }
                return self.attaches.removeFirst()
            },
            next: { _ in self.nexts.removeFirst() },
            runSSH: { argv in
                self.ran.append(argv)
                return self.statuses.removeFirst()
            },
            print: { self.printed.append($0) },
            readLine: { self.lines.isEmpty ? nil : self.lines.removeFirst() },
            pause: { _ in })
    }
}

struct RemoteAttachLoopTests {
    @Test func waitingMessagesPrintOnceAndTheLoopEndsWithTheSession() async {
        let script = AttachScript(
            attaches: [
                HostAttachResult(waiting: "Starting box…"), HostAttachResult(waiting: "Starting box…"),
                HostAttachResult(ready: ["ssh", "box"]),
            ],
            nexts: [HostNextResult(action: .end)], statuses: [0])

        let code = await script.loop.run()

        #expect(code == 0)
        #expect(script.printed == ["Starting box…"])
        #expect(script.ran == [["ssh", "box"]])
    }

    @Test func aDroppedConnectionReconnectsAndADetachWaitsForReturn() async {
        let script = AttachScript(
            attaches: [HostAttachResult(ready: ["a"]), HostAttachResult(ready: ["b"]), HostAttachResult(ready: ["c"])],
            nexts: [
                HostNextResult(action: .reconnect, message: "Lost box, reconnecting…"),
                HostNextResult(
                    action: .waitForReturn, message: "Detached so box can sleep. Press Return to reconnect."),
                HostNextResult(action: .end),
            ],
            lines: ["some typing"], statuses: [255, 255, 0])

        let code = await script.loop.run()

        #expect(code == 0)
        #expect(script.ran == [["a"], ["b"], ["c"]])
        #expect(script.printed == ["Lost box, reconnecting…", "Detached so box can sleep. Press Return to reconnect."])
        #expect(script.lines.isEmpty)
    }

    @Test func aHostThatStaysDownWaitsForReturnAndTheEndOfInputStops() async {
        let script = AttachScript(
            attaches: [HostAttachResult(failed: "Could not reach box: timed out")], nexts: [], lines: [nil],
            statuses: [])

        let code = await script.loop.run()

        #expect(code == 1)
        #expect(script.printed == ["Could not reach box: timed out", "Press Return to try again."])
    }
}

extension RemoteAttachLoopTests {
    @Test func anAppStillStartingIsWaitedForWithoutAskingForReturn() async {
        let script = AttachScript(
            attaches: [HostAttachResult(ready: ["ssh"])], nexts: [HostNextResult(action: .end)], statuses: [0])
        script.refusals = 3

        let code = await script.loop.run()

        #expect(code == 0)
        #expect(script.printed == ["Waiting for Canopy…"])
        #expect(script.ran == [["ssh"]])
    }

    @Test func anAppThatNeverAnswersAsksForReturn() async {
        let script = AttachScript(attaches: [], nexts: [], lines: [nil], statuses: [])
        script.refusals = 1000

        let code = await script.loop.run()

        #expect(code == 1)
        #expect(
            script.printed == [
                "Waiting for Canopy…", "Could not connect to Canopy: Connection refused", "Press Return to try again.",
            ])
    }
}
