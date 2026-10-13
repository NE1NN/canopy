import CanopyAgents
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

struct BoxPanesTests {
    func contents(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func newPanesCountUpFromTheSavedNumber() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let first = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let second = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        #expect([first, second] == ["b1", "b2"])
        #expect(await home.server.tmux.hasSession("b2"))
        let restarted = try await home.daemon()
        #expect(try await restarted.paneNew(BoxPaneNewParams(rowPath: home.clone)) == "b3")
        await #expect(throws: BoxErrors.rowNotFound("/nowhere")) {
            try await daemon.paneNew(BoxPaneNewParams(rowPath: "/nowhere"))
        }
    }

    @Test func aPaneGetsTheVariablesARemotePaneGetsAndRunsItsCommand() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/env"))
        let out = home.dir.sub("env.txt")
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: made.row.path, command: "env > \(out)"))
        #expect(await eventually { contents(out)?.contains("CANOPY_PANE=") == true })
        let lines = Set((contents(out) ?? "").split(separator: "\n").map(String.init))
        #expect(lines.contains("CANOPY_PANE=\(pane)"))
        #expect(lines.contains("CANOPY_HOST=box"))
        #expect(lines.contains("CANOPY_REPO=demo"))
        #expect(lines.contains("CANOPY_ROW=feat/env"))
        #expect(lines.contains("CANOPY_ROW_PATH=\(made.row.path)"))
        #expect(lines.contains("CANOPY_ROOT_PATH=\(home.clone)"))
        #expect(lines.contains("CANOPY_HOME_ID=\(BoxTestHome.homeID)"))
        #expect(lines.contains("CANOPY_SOCKET=\(home.paths.appSocket)"))
        #expect(lines.contains("CANOPY_CLI=\(home.paths.bin)/canopy"))
        let path = lines.first { $0.hasPrefix("PATH=") } ?? ""
        #expect(path.split(separator: ":").contains { $0.hasSuffix(home.paths.bin) })
        #if os(Linux)
            // macOS's login profile puts the system's folders first, which Linux's leaves alone.
            #expect(path.hasPrefix("PATH=\(home.paths.bin):"))
        #endif
    }

    @Test func sendTypesTextThenReturnApart() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let out = home.dir.sub("typed.txt")
        try await daemon.send(pane: pane, text: "stty raw -echo; head -c 6 > \(out)", enter: true)
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        try await daemon.send(pane: pane, text: "hi 'x'", enter: true)
        #expect(ContinuousClock.now - started >= .milliseconds(200))
        #expect(await eventually { contents(out) == "hi 'x'" })
        await #expect(throws: BoxErrors.paneNotFound("b99")) {
            try await daemon.send(pane: "b99", text: "x", enter: false)
        }
    }

    @Test func keysGoInOneAtATime() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let out = home.dir.sub("keys.bin")
        try await daemon.send(pane: pane, text: "stty raw -echo; head -c 3 > \(out)", enter: true)
        try await Task.sleep(for: .milliseconds(500))
        try await daemon.keys(BoxKeysParams(pane: pane, keys: ["\u{1b}[B", "\r"]))
        #expect(await eventually { FileManager.default.contents(atPath: out) == Data([0x1B, 0x5B, 0x42]) })
    }

    @Test func readGivesTheScreenOrTheLastLines() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone, command: "seq 1 50"))
        #expect(await eventually { (try? await daemon.read(pane: pane, lines: 2))?.hasPrefix("50\n") == true })
        #expect(try await daemon.read(pane: pane, lines: nil).contains("49\n50"))
    }

    @Test func closingAPaneKillsItsSession() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        try await daemon.paneClose(pane)
        #expect(!(await home.server.tmux.hasSession(pane)))
        #expect(await daemon.snapshot().panes.isEmpty)
    }

    @Test func aPaneWhoseSessionEndsLeaves() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        try await daemon.send(pane: pane, text: "exit", enter: true)
        #expect(await eventually { !(await home.server.tmux.hasSession(pane)) })
        await daemon.pollPanes()
        #expect(await daemon.snapshot().panes.isEmpty)
    }

    @Test func thePollFillsForegroundTitleAndBusy() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        try await daemon.send(
            pane: pane, text: "printf '\\033]2;Building\\007'; echo done-$((40 + 2)); sleep 30", enter: true)
        #expect(
            await eventually {
                await daemon.pollPanes()
                let shown = await daemon.snapshot().panes.first
                return shown?.busy == true && shown?.foreground == "sleep" && shown?.title == "Building"
                    && shown?.lastLine == "done-42"
            })
    }

    @Test func waitReturnsAPaneAlreadyThere() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        let reached = try await daemon.wait(panes: [pane], for: .any, timeout: .seconds(5))
        #expect(reached.pane == pane && reached.state == .done)
    }

    @Test func waitIgnoresAStateFromBeforeInput() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        try await daemon.send(pane: pane, text: "next", enter: false)
        let waiting = Task { try await daemon.wait(panes: [pane], for: .done, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        await daemon.report(pane: pane, AgentReport(state: .working, session: "s"))
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        let reached = try await waiting.value
        #expect(reached.state == .done)
    }

    @Test func waitFailsWhenThePaneClosesOrItsAgentStops() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let other = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: other, AgentReport(state: .working, session: "s"))
        let closing = Task { try await daemon.wait(panes: [pane], for: .any, timeout: .seconds(20)) }
        let stopping = Task { try await daemon.wait(panes: [other], for: .any, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        try await daemon.paneClose(pane)
        await daemon.report(pane: other, AgentReport(state: AgentState.none, session: "s", releases: true))
        await #expect(throws: ControlError(code: "pane_closed", message: "\(pane) closed during the wait.")) {
            try await closing.value
        }
        await #expect(
            throws: ControlError(
                code: "agent_stopped",
                message:
                    "The agent in \(other) stopped without finishing: it exited, was interrupted, or was set to none.")
        ) { try await stopping.value }
    }

    @Test func waitTimesOut() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await #expect(
            throws: ControlError(
                code: "wait_timeout", message: "\(pane) did not become done or waiting before the timeout.")
        ) { try await daemon.wait(panes: [pane], for: .any, timeout: .milliseconds(200)) }
    }
}
