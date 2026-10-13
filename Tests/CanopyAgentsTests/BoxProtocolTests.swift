import CanopyWire
import Foundation
import Testing

@testable import CanopyAgents

struct BoxProtocolTests {
    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }

    @Test func aPanesAgentRoundTripsWithEveryField() throws {
        var agent = PaneAgent()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        _ = agent.apply(
            AgentReport(state: .working, session: "s1", event: "UserPromptSubmit", at: started), now: started)
        _ = agent.apply(
            AgentReport(
                state: .waiting, session: "s1", event: "PermissionRequest", at: started + 5,
                transcriptPath: "/t.jsonl", prompt: AgentPrompt(kind: .permission, tool: "Bash", detail: "ls")),
            now: started + 5)
        let decoded = try roundTrip(agent)
        #expect(decoded == agent)
        // What it last changed at still orders reports: an older hook is ignored after the round trip.
        var restored = decoded
        #expect(
            restored.apply(AgentReport(state: .done, session: "s1", event: "Stop", at: started + 1), now: started + 6)
                == nil)
        #expect(restored.state == .waiting)
    }

    @Test func aPanesAgentFromAnEmptyObjectIsNone() throws {
        let agent = try JSONDecoder().decode(PaneAgent.self, from: Data("{}".utf8))
        #expect(agent == PaneAgent())
    }

    @Test func aSnapshotRoundTripsAndLeavesOutWhatIsNil() throws {
        let pane = BoxPane(
            id: "b1", rowPath: "/h/.canopy/worktrees/demo/feat-x", folder: "/h/.canopy/worktrees/demo/feat-x",
            foreground: "claude", title: "Fixing", busy: true, agent: .working, unseen: false, backgroundTasks: [],
            transcriptPath: nil, prompt: nil, since: 1_700_000_000, lastLine: nil)
        let row = BoxRow(
            path: "/h/demo", repo: "demo", branch: "main", head: "abc", isMain: true, missing: false, pr: nil)
        let snapshot = BoxSnapshot(rows: [row], panes: [pane])
        #expect(try roundTrip(snapshot) == snapshot)
        let json = String(decoding: try JSONEncoder().encode(pane), as: UTF8.self)
        #expect(!json.contains("prompt"))
        #expect(!json.contains("transcriptPath"))
        #expect(!json.contains("lastLine"))
    }

    @Test func aSnapshotFromANewerDaemonStillDecodes() throws {
        let line = """
            {"rows": [{"path": "/r", "repo": "demo", "isMain": true, "missing": false, "colour": "green"}],
             "panes": [], "weather": "fine"}
            """
        let snapshot = try JSONDecoder().decode(BoxSnapshot.self, from: Data(line.utf8))
        #expect(snapshot.rows.map(\.path) == ["/r"])
    }

    @Test func adoptAndReleaseRoundTrip() throws {
        let adopted = BoxAdoptParams(
            rows: [BoxAdoptedRow(repo: "demo", path: "/h/.canopy/worktrees/demo/x", branch: "x")],
            panes: [BoxAdoptedPane(id: "p4", rowPath: "/h/.canopy/worktrees/demo/x", folder: "/h", agent: PaneAgent())],
            nextPane: 5)
        #expect(try roundTrip(adopted) == adopted)
        let result = BoxAdoptResult(rows: ["/h/.canopy/worktrees/demo/x"], panes: ["p4"], missing: ["p9"])
        #expect(try roundTrip(result) == result)
        let released = BoxReleaseResult(rows: adopted.rows, panes: adopted.panes, nextPane: 7)
        #expect(try roundTrip(released) == released)
    }

    @Test func eventsAndResponsesAreToldApart() throws {
        let event = BoxEvent(event: BoxEvent.snapshot, subscription: "r1", data: .object([:]))
        let line = try ControlCodec.encodeLine(event)
        guard case .event(let decoded) = try BoxMessage(line: line.dropLast()) else {
            Issue.record("not an event")
            return
        }
        #expect(decoded == event)
        let response = ControlResponse.success(id: "r2", result: .bool(true))
        guard case .response(let back) = try BoxMessage(line: try ControlCodec.encodeLine(response).dropLast()) else {
            Issue.record("not a response")
            return
        }
        #expect(back == response)
    }
}
