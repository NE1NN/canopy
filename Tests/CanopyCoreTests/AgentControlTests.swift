import Foundation
import Testing

@testable import CanopyCore

extension ControlServerTests {
    func error(_ client: ControlClient, _ method: String, _ params: JSONValue) async throws -> String? {
        try await offPool { try client.send(ControlRequest(method: method, params: params)) }.error?.code
    }

    @Test func agentStatesAreReportedListedAndWaitedOn() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")
        let pane = try await call(client, TermMethod.new, TermNewParams(target: target), as: TermNewResult.self).pane

        let working = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .working), as: TermStateResult.self)
        #expect(working == TermStateResult(pane: pane, state: .working))
        let listed = try await call(client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
        #expect(listed.map(\.agent) == [.working])

        // The first session to report takes the pane, and another session's reports are ignored.
        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .working, session: "s1"),
            as: TermStateResult.self)
        let ignored = try await call(
            client, TermMethod.state,
            TermStateParams(
                pane: pane, state: .done, session: "nested", event: "Stop", at: Date().timeIntervalSince1970),
            as: TermStateResult.self)
        #expect(ignored.state == .working)

        let waiting = Task {
            try await call(
                client, TermMethod.wait, TermWaitParams(panes: [pane], target: .any, timeout: 20),
                as: TermWaitResult.self)
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .done, session: "s1", event: "Stop"),
            as: TermStateResult.self)
        #expect(try await waiting.value == TermWaitResult(pane: pane, state: .done))

        // A background report carries its work into the list, and only a wait for background returns on it.
        _ = try await call(
            client, TermMethod.state,
            TermStateParams(pane: pane, state: .background, session: "s1", event: "Stop", backgroundTasks: ["bun dev"]),
            as: TermStateResult.self)
        let background = try await call(
            client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
        #expect(background.map(\.agent) == [.background])
        #expect(background.map(\.backgroundTasks) == [["bun dev"]])
        let reached = try await call(
            client, TermMethod.wait, TermWaitParams(panes: [pane], target: .background, timeout: 5),
            as: TermWaitResult.self)
        #expect(reached == TermWaitResult(pane: pane, state: .background))
        await #expect(throws: (any Error).self) {
            try await call(
                client, TermMethod.wait, TermWaitParams(panes: [pane], target: .any, timeout: 0.2),
                as: TermWaitResult.self)
        }

        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: AgentState.none), as: TermStateResult.self)
        let cleared = try await call(client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
        #expect(cleared.map(\.agent) == [nil])
        let encoded = try JSONValue.from(cleared[0])
        if case .object(let fields) = encoded {
            #expect(fields["agent"] == nil)
            #expect(fields["backgroundTasks"] == nil)
        }

        // Panes log through the terminal store's own log, which this helper does not flush.
        #expect(await eventually { await logged(workspace, "agent").count == 4 })
        let events = await logged(workspace, "agent")
        #expect(events.map(\.type) == ["agent.working", "agent.done", "agent.background", "agent.cleared"])
        #expect(events.allSatisfy { $0.source == .cli })
    }

    @Test func agentRequestsFailWithCodes() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let pane = try await call(
            client, TermMethod.new, TermNewParams(target: TargetHint(repo: "demo", row: "main")),
            as: TermNewResult.self
        ).pane

        let id = JSONValue.string(pane)
        #expect(
            try await error(client, TermMethod.state, .object(["pane": "p999", "state": "done"])) == "pane_not_found")
        #expect(try await error(client, TermMethod.state, .object(["pane": id, "state": "busy"])) == "bad_params")
        #expect(try await error(client, TermMethod.state, .object(["pane": id])) == "bad_params")
        #expect(try await error(client, TermMethod.wait, .object(["panes": .array([]), "timeout": 1])) == "bad_params")
        #expect(
            try await error(client, TermMethod.wait, .object(["panes": .array([id]), "timeout": -1])) == "bad_params")
        #expect(
            try await error(client, TermMethod.wait, .object(["panes": .array([id]), "for": "idle"])) == "bad_params")
        #expect(try await error(client, TermMethod.wait, .object(["panes": .array(["p999"])])) == "pane_not_found")
        #expect(
            try await error(client, TermMethod.wait, .object(["panes": .array([id]), "timeout": .number(0.1)]))
                == "wait_timeout")
        // A timeout past any sensible length is cut to a year rather than overflowing.
        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .done), as: TermStateResult.self)
        #expect(
            try await call(
                client, TermMethod.wait, TermWaitParams(panes: [pane], timeout: 1e300), as: TermWaitResult.self
            ).state == .done)
    }

    @Test func agentRequestsStayOutOfCLICalls() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let pane = try await call(
            client, TermMethod.new, TermNewParams(target: TargetHint(repo: "demo", row: "main")),
            as: TermNewResult.self
        ).pane

        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .done), as: TermStateResult.self)
        _ = try await call(
            client, TermMethod.wait, TermWaitParams(panes: [pane]), as: TermWaitResult.self)

        let calls = await logged(workspace, "cli").map { $0.data["method"] }
        #expect(calls == ["repo.add", "term.new"])
    }
}
