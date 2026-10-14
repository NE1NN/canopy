import CanopyAgents
import CanopyGit
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

/// What the final review of canopy-box found, each pinned.
struct BoxReviewTests {
    @Test func aPollThatListedBeforeAPaneWasMadeKeepsIt() async throws {
        let home = try await BoxTestHome(pauses: ["list-panes": 0.8])
        let daemon = try await home.daemon()
        let polling = Task { await daemon.pollPanes() }
        try await Task.sleep(for: .milliseconds(200))
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await polling.value
        #expect(await daemon.snapshot().panes.map(\.id) == [pane])
    }

    @Test func aPollDuringAPanesMakingDoesNotTakeItTwice() async throws {
        let home = try await BoxTestHome(pauses: ["new-session": 0.8])
        let daemon = try await home.daemon()
        let making = Task { try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone)) }
        try await Task.sleep(for: .milliseconds(400))
        await daemon.pollPanes()
        let pane = try await making.value
        #expect(await daemon.snapshot().panes.map(\.id) == [pane])
    }

    @Test func aRowBeingMadeIsNeitherDoubledNorMissing() async throws {
        let home = try await BoxTestHome()
        let slowAdd: @Sendable (String) -> GitClone = { path in
            let real = GitFixture.clone(path)
            return GitClone(path: path) { arguments, folder, timeout in
                let output = try await real.at(folder).run(arguments, timeout: timeout)
                if arguments.starts(with: ["worktree", "add"]) { try await Task.sleep(for: .milliseconds(800)) }
                return output
            }
        }
        let daemon = try await home.daemon(git: slowAdd)
        let making = Task { try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/race")) }
        try await Task.sleep(for: .milliseconds(400))
        try await daemon.configure(home.config)
        let made = try await making.value
        let rows = await daemon.snapshot().rows.filter { !$0.isMain }
        #expect(rows.map(\.path) == [made.row.path])
        #expect(rows.first?.missing == false)
    }

    @Test func aRepeatedPaneInAWaitIsFine() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .working, session: "s"))
        let waiting = Task { try await daemon.wait(panes: [pane, pane], for: .done, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        #expect(try await waiting.value.state == .done)
    }

    @Test func anAgentWhoseProgramEndedWithoutAHookStops() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        try await daemon.send(pane: pane, text: "sleep 2", enter: true)
        #expect(
            await eventually {
                await daemon.pollPanes()
                return await daemon.snapshot().panes.first?.busy == true
            })
        await daemon.report(pane: pane, AgentReport(state: .working, session: "s"))
        #expect(
            await eventually {
                await daemon.pollPanes()
                return await daemon.snapshot().panes.first?.agent == AgentState.none
            })
    }

    @Test func longTextArrivesWhole() async throws {
        let home = try await BoxTestHome()
        let out = home.dir.sub("long.txt")
        let text = String(repeating: "abcdefghij", count: 2_500) + "\nsecond line;"
        // Raw, since a terminal in line mode holds only a few KB of one line.
        try await home.server.tmux.newSession(
            "l", folder: home.dir.path, environment: [:],
            command: "stty raw -echo; touch \(out).ready; head -c \(text.utf8.count) > \(out)"
        )
        #expect(await eventually { FileManager.default.fileExists(atPath: out + ".ready") })
        try await home.server.tmux.sendText(text, to: "l")
        #expect(
            await eventually {
                FileManager.default.contents(atPath: out).map { String(decoding: $0, as: UTF8.self) } == text
            })
    }

    @Test func removingARowWithAProgramRunningNeedsForce() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/busy"))
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: made.row.path, command: "sleep 60"))
        // The shell that starts `sleep` is busy too, for a moment, before it becomes `sleep`.
        #expect(
            await eventually {
                await daemon.pollPanes()
                let info = await daemon.snapshot().panes.first { $0.id == pane }
                return info?.busy == true && info?.foreground == "sleep"
            })
        await #expect(
            throws: ControlError(
                code: "row_busy", message: "sleep is still running in feat/busy. Pass --force to remove the row anyway."
            )
        ) { try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path)) }
        _ = try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path, force: true))
        #expect(!(await home.server.tmux.hasSession(pane)))
    }

    @Test func anotherHomesWorktreesAreLeftAlone() async throws {
        let home = try await BoxTestHome()
        let shared = home.dir.sub(".canopy/worktrees/demo")
        try await home.worktree("feat/theirs", under: shared)
        let daemon = try await home.daemon()
        #expect(await daemon.snapshot().rows.map(\.isMain) == [true])
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/ours"))
        #expect(made.row.path == home.dir.sub(".canopy/\(BoxTestHome.homeID)/worktrees/demo/feat-ours"))
    }

    @Test func aWriterNeverBlocksAndDropsAPeerThatStopsReading() async throws {
        let folder = try TempDir(in: "/tmp")
        let path = folder.sub("w.sock")
        let accepted = Shared<UnixConnection?>(nil)
        let listener = try UnixListener(path: path) { connection in accepted.withLock { $0 = connection } }
        defer { listener.close() }
        let client = try UnixConnection.connect(path: path)
        defer { client.close() }
        #expect(await eventually { accepted.withLock { $0 } != nil })
        let server = try #require(accepted.withLock { $0 })
        // A send that waited on the peer would take the whole wait, well past the limit even on a slow machine.
        let writer = ConnectionWriter(server, wait: .seconds(3))
        let started = ContinuousClock.now
        for _ in 0..<200 { writer.send(Data(repeating: 0x61, count: 64 * 1024)) }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await eventually(timeout: .seconds(10)) { writer.failed })
    }
}

/// What CodeRabbit found on PR 49, each pinned.
struct BoxCodeRabbitTests {
    @Test func aReleasedBoxTakesNothingBackUntilAdoptOrConfigure() async throws {
        let home = try await BoxTestHome()
        try await home.session("b1", in: home.clone)
        try await home.worktree("feat/later")
        let daemon = try await home.daemon()
        _ = await daemon.release()
        await daemon.pollPanes()
        await daemon.start()
        #expect(await daemon.snapshot().panes.isEmpty)
        #expect(await daemon.snapshot().rows.filter { !$0.isMain }.isEmpty)
        try await daemon.configure(home.config)
        await daemon.pollPanes()
        #expect(await daemon.snapshot().panes.map(\.id) == ["b1"])
    }

    @Test func aHugeWaitTimeoutIsRefusedNotATrap() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        func wait(_ timeout: Double) async throws -> ControlResponse {
            await BoxServer.handle(
                ControlRequest(
                    method: BoxMethod.wait,
                    params: try .from(TermWaitParams(panes: [pane], target: .done, timeout: timeout))),
                daemon: daemon)
        }
        for timeout in [-1.0, -0.5] {
            #expect(try await wait(timeout).error?.code == "bad_params", "\(timeout)")
        }
        // Far past any Duration, so it is held to a year; the pane is already done, so it answers at once.
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        #expect(try await wait(1e300).error == nil)
    }

    @Test func aSecondServeLeavesTheStateFileAlone() async throws {
        let dir = try TempDir(in: "/tmp")
        let paths = BoxPaths(root: dir.path, homeID: "abc12347")
        let first = try BoxProcessTests.Running(root: dir.path, homeID: "abc12347", tmuxFolder: dir.path)
        #expect(await eventually { (try? UnixConnection.connect(path: paths.socket)) != nil })
        let before = try FileManager.default.attributesOfItem(atPath: paths.stateFile)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100))
        let refused = try BoxProcessTests.Running(root: dir.path, homeID: "abc12347", tmuxFolder: dir.path)
        #expect(try await refused.result.value.status == 1)
        let after = try FileManager.default.attributesOfItem(atPath: paths.stateFile)[.modificationDate] as? Date
        #expect(before == after)
        #expect(first.handle.isRunning)
    }

    @Test func gitNeverAsksForAPassword() async throws {
        let clone = GitClone.local(path: "/", executable: "/usr/bin/env", environment: ["GIT_ASKPASS": "/bin/helper"])
        let printed = try await clone.run([])
        let lines = Set(printed.split(separator: "\n").map(String.init))
        #expect(lines.contains("GIT_TERMINAL_PROMPT=0"))
        #expect(lines.contains("GIT_ASKPASS="))
    }
}
