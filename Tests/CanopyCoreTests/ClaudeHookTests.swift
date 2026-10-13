import CanopyTestSupport
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// What `canopy agent-hook` sends to the app for a hook.
struct AgentHookTests {
    let started = Date(timeIntervalSince1970: 2_000)

    func expected(
        _ state: AgentState?, _ event: String, question: Bool = false, takesOver: Bool = false,
        releases: Bool = false, backgroundTasks: [String] = [], prompt: AgentPrompt? = nil
    ) -> AgentReport {
        AgentReport(
            state: state, session: "abc123", event: event, at: started, question: question, takesOver: takesOver,
            releases: releases, backgroundTasks: backgroundTasks, prompt: prompt)
    }

    @Test func aBackgroundReportCarriesItsWorkToTheApp() throws {
        let input =
            #"{"session_id": "abc123", "hook_event_name": "Stop", "background_tasks": [{"type": "shell", "status": "running", "command": "npm test"}]}"#
        let hook = try #require(
            AgentHook.request(
                input: Data(input.utf8), environment: ["CANOPY_PANE": "p3", "CANOPY_HOME": "/tmp/h"],
                startedAt: started))
        let params = try #require(hook.request.params).decode(TermStateParams.self)
        #expect(params.state == .background)
        #expect(params.report.backgroundTasks == ["npm test"])
        // Params without the field, as from an older CLI, still read, and other reports leave it out.
        let done = try JSONValue.from(TermStateParams(pane: "p3", state: .done))
        if case .object(let fields) = done { #expect(fields["backgroundTasks"] == nil) }
        #expect(try done.decode(TermStateParams.self).backgroundTasks.isEmpty)
    }

    @Test func theHookBuildsItsRequestOnlyInsideCanopy() throws {
        let input = Data(
            #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Done."}"#.utf8)
        let environment = ["CANOPY_PANE": "p12", "CANOPY_HOME": "/tmp/canopy-home"]

        let built = try #require(AgentHook.request(input: input, environment: environment, startedAt: started))
        #expect(built.socketPath == "/tmp/canopy-home/canopy.sock")
        #expect(built.request.method == TermMethod.state)
        let params = try #require(built.request.params).decode(TermStateParams.self)
        #expect(params.pane == "p12")
        #expect(params.report == expected(.done, "Stop"))

        #expect(AgentHook.request(input: input, environment: ["CANOPY_PANE": "p12"], startedAt: started) == nil)
        #expect(AgentHook.request(input: input, environment: ["CANOPY_HOME": "/tmp/x"], startedAt: started) == nil)
        #expect(
            AgentHook.request(
                input: input, environment: ["CANOPY_PANE": "", "CANOPY_HOME": "/tmp/x"], startedAt: started)
                == nil)
        #expect(AgentHook.request(input: Data("{}".utf8), environment: environment, startedAt: started) == nil)
    }

    @Test func aRelayedHookIsDatedByWhenItRanOnTheHost() throws {
        let input = Data(#"{"session_id": "abc123", "hook_event_name": "Stop"}"#.utf8)
        func at(_ startedAtVariable: String?) throws -> Double? {
            var environment = ["CANOPY_PANE": "p12", "CANOPY_HOME": "/tmp/canopy-home"]
            environment["CANOPY_STARTED_AT"] = startedAtVariable
            let built = try #require(AgentHook.request(input: input, environment: environment, startedAt: started))
            return try #require(built.request.params).decode(TermStateParams.self).at
        }

        let fractional = try #require(try at("1791460000.123456"))
        #expect(abs(fractional - 1_791_460_000.123456) < 1e-5)
        #expect(try at("1791460000") == 1_791_460_000)
        for malformed in ["", "soon", "nan", "inf", "-inf", "1791460000s"] {
            #expect(try at(malformed) == started.timeIntervalSince1970, "\(malformed)")
        }
        #expect(try at(nil) == started.timeIntervalSince1970)
    }

    @Test func postingWaitsAtMostASecondForTheApp() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let received = Mutex<[String]>([])
        let server = ControlServer(socketPath: home.socketPath) { request in
            received.withLock { $0.append(request.method) }
            if request.method == "slow" {
                try? await Task.sleep(for: .seconds(3))
            }
            return .success(id: request.id, result: .null)
        }
        try await server.start()
        defer { server.stop() }

        let socketPath = home.socketPath
        try await offPool { try ControlClient(socketPath: socketPath).post(ControlRequest(method: "term.state")) }
        #expect(await eventually { received.withLock { $0 } == ["term.state"] })

        // An app that takes 3 seconds to answer holds the hook for about a second, however slow the machine. Timed on
        // the posting thread: a test task waits for a thread of the busy concurrency pool before it can read a clock.
        let slow = try await offPool {
            try ContinuousClock().measure {
                try ControlClient(socketPath: socketPath).post(ControlRequest(method: "slow"))
            }
        }
        #expect(slow >= .milliseconds(900) && slow < .milliseconds(2900))
        #expect(await eventually { received.withLock { $0 } == ["term.state", "slow"] })
    }

    @Test func aProcessStartTimeOrdersProcesses() throws {
        let own = try #require(ProcessTable.startTime(of: getpid()))
        #expect(own <= Date())
        #expect(own > Date().addingTimeInterval(-86_400))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let childStart = try #require(ProcessTable.startTime(of: child.processIdentifier))
        #expect(childStart > own)
        #expect(ProcessTable.startTime(of: 999_999) == nil)
    }

    @Test func postingFailsFastWhenTheAppIsNotRunning() async throws {
        let dir = try TempDir()
        let socketPath = dir.sub("canopy.sock")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: ControlClientError.connectFailed(errno: ENOENT)) {
                try ControlClient(socketPath: socketPath).post(ControlRequest(method: "term.state"))
            }
        }
        #expect(elapsed < .seconds(1))
    }
}
