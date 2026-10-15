import CanopyAgents
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

struct BoxAgentsTests {
    static func hookInput(_ event: String, session: String = "s1") -> Data {
        Data(#"{"hook_event_name": "\#(event)", "session_id": "\#(session)", "transcript_path": "/t.jsonl"}"#.utf8)
    }

    /// A report the host's relay kept for `pane`, as `canopy-host` writes one.
    static func keep(_ input: Data, pane: String, in home: BoxTestHome, keptSecondsAgo: Double = 5) throws {
        let request: [String: Any] = [
            "version": "old", "args": ["agent-hook"], "cwd": "/",
            "env": ["CANOPY_PANE": pane, "CANOPY_HOME_ID": BoxTestHome.homeID],
            "stdin": input.base64EncodedString(), "age": 0.5, "kept": Date().timeIntervalSince1970 - keptSecondsAgo,
        ]
        try FileManager.default.createDirectory(atPath: home.paths.pending, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: request).write(
            to: URL(fileURLWithPath: home.paths.pending + "/\(pane).json"))
    }

    @Test func aHookMovesThePanesAgent() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let state = await daemon.hook(pane: pane, input: Self.hookInput("UserPromptSubmit"), startedAt: Date())
        #expect(state == .working)
        let shown = await daemon.snapshot().panes.first
        #expect(shown?.agent == .working)
        #expect(shown?.transcriptPath == "/t.jsonl")
        #expect(await daemon.hook(pane: "b99", input: Self.hookInput("Stop"), startedAt: Date()) == nil)
    }

    /// The Mac opens a box row's pane itself, through tmux, and its agent can report before the box's next poll.
    @Test func aHookFromASessionTheBoxHasNotPolledYetCounts() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        try await home.server.tmux.newSession("p7", folder: home.clone, environment: [:])

        let state = await daemon.hook(pane: "p7", input: Self.hookInput("UserPromptSubmit"), startedAt: Date())

        #expect(state == .working)
        #expect(await daemon.snapshot().panes.map(\.id) == ["p7"])
        // A session outside the box's rows is still no pane of the box's.
        try await home.server.tmux.newSession("p8", folder: home.dir.path, environment: [:])
        #expect(await daemon.hook(pane: "p8", input: Self.hookInput("Stop"), startedAt: Date()) == nil)
        // A released box takes no new panes.
        _ = await daemon.release()
        try await home.server.tmux.newSession("p9", folder: home.clone, environment: [:])
        #expect(await daemon.hook(pane: "p9", input: Self.hookInput("Stop"), startedAt: Date()) == nil)
    }

    /// As every pane an older Mac opened did: it gave tmux its stand-in folder, which the host does not have, so tmux
    /// started each session in the home folder.
    @Test func aHookFromASessionStartedOutsideEveryRowCountsForTheRowItsVariablesName() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        try await home.server.tmux.newSession(
            "p7", folder: home.dir.path, environment: ["CANOPY_ROW_PATH": home.clone], command: "exec sleep 60")
        try await home.server.tmux.newSession(
            "p8", folder: home.dir.path, environment: ["CANOPY_ROW_PATH": home.dir.sub("nowhere")],
            command: "exec sleep 60")

        #expect(await daemon.hook(pane: "p7", input: Self.hookInput("UserPromptSubmit"), startedAt: Date()) == .working)
        #expect(await daemon.hook(pane: "p8", input: Self.hookInput("Stop"), startedAt: Date()) == nil)
        let taken = await daemon.snapshot().panes
        #expect(taken.map(\.id) == ["p7"])
        #expect(taken.first?.rowPath == home.clone)
        #expect(taken.first?.folder == home.clone)
    }

    @Test func anOlderHookIsIgnored() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let now = Date()
        await daemon.hook(pane: pane, input: Self.hookInput("Stop"), startedAt: now)
        await daemon.hook(pane: pane, input: Self.hookInput("UserPromptSubmit"), startedAt: now - 2)
        #expect(await daemon.snapshot().panes.first?.agent == .done)
    }

    @Test func escapeClearsAWorkingAgent() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.hook(pane: pane, input: Self.hookInput("UserPromptSubmit"), startedAt: Date())
        try await daemon.keys(BoxKeysParams(pane: pane, keys: ["\u{1b}"]))
        #expect(await daemon.snapshot().panes.first?.agent == AgentState.none)
    }

    @Test func seenClearsTheGreen() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.hook(pane: pane, input: Self.hookInput("Stop"), startedAt: Date())
        #expect(await daemon.snapshot().panes.first?.unseen == true)
        try await daemon.seen(pane: pane)
        #expect(await daemon.snapshot().panes.first?.unseen == false)
        await #expect(throws: BoxErrors.paneNotFound("b99")) { try await daemon.seen(pane: "b99") }
    }

    @Test func prsShowOnTheirRows() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        await daemon.setPRs([home.clone: 46, "/elsewhere": 3])
        #expect(await daemon.snapshot().rows.first?.pr == 46)
    }

    @Test func keptReportsReplayOnStartAndGoAway() async throws {
        let home = try await BoxTestHome()
        try await home.session("b1", in: home.clone)
        try Self.keep(Self.hookInput("Stop"), pane: "b1", in: home)
        let daemon = try await home.daemon()
        await daemon.replayPending()
        let pane = await daemon.snapshot().panes.first
        #expect(pane?.agent == .done)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.paths.pending)) == [])
    }

    @Test func aKeptReportIsDatedByWhenItsHookRan() async throws {
        let home = try await BoxTestHome()
        try await home.session("b1", in: home.clone)
        let daemon = try await home.daemon()
        await daemon.hook(pane: "b1", input: Self.hookInput("Stop"), startedAt: Date() - 2)
        // Kept five seconds ago, so older than the finish above, which stands.
        try Self.keep(Self.hookInput("UserPromptSubmit"), pane: "b1", in: home, keptSecondsAgo: 5)
        await daemon.replayPending()
        #expect(await daemon.snapshot().panes.first?.agent == .done)
    }

    @Test func aKeptReportForAnUnknownPaneIsDropped() async throws {
        let home = try await BoxTestHome()
        try Self.keep(Self.hookInput("Stop"), pane: "p404", in: home)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: home.paths.pending + "/b7.json"))
        let daemon = try await home.daemon()
        await daemon.replayPending()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.paths.pending)) == [])
    }

    func busyTime(_ home: BoxTestHome) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: home.paths.busyFile))?[.modificationDate] as? Date
    }

    @Test func workingKeepsTheBoxOn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.tickBusy()
        #expect(busyTime(home) == nil)
        await daemon.hook(pane: pane, input: Self.hookInput("UserPromptSubmit"), startedAt: Date())
        await daemon.tickBusy()
        let first = try #require(busyTime(home))
        try await Task.sleep(for: .milliseconds(1100))
        await daemon.tickBusy()
        #expect(try #require(busyTime(home)) > first)
    }

    @Test func backgroundKeepsTheBoxOn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .background, session: "s", backgroundTasks: ["dev server"]))
        await daemon.tickBusy()
        #expect(busyTime(home) != nil)
    }

    @Test func waitingAndDoneDoNotKeepTheBoxOn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let waiting = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let done = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: waiting, AgentReport(state: .working, session: "a"))
        await daemon.tickBusy()
        let touched = try #require(busyTime(home))
        await daemon.report(pane: waiting, AgentReport(state: .waiting, session: "a"))
        await daemon.report(pane: done, AgentReport(state: .done, session: "b"))
        try await Task.sleep(for: .milliseconds(1100))
        await daemon.tickBusy()
        #expect(busyTime(home) == touched)
    }
}
