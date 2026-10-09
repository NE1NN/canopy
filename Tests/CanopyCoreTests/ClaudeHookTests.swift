import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct ClaudeHookTests {
    let started = Date(timeIntervalSince1970: 2_000)

    func report(_ json: String) -> AgentReport? {
        ClaudeHookMapping.report(from: Data(json.utf8), startedAt: started)
    }

    func expected(
        _ state: AgentState?, _ event: String, question: Bool = false, takesOver: Bool = false,
        releases: Bool = false, backgroundTasks: [String] = []
    ) -> AgentReport {
        AgentReport(
            state: state, session: "abc123", event: event, at: started, question: question, takesOver: takesOver,
            releases: releases, backgroundTasks: backgroundTasks)
    }

    @Test func sessionsTakeAndLetGoOfThePane() {
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "SessionStart", "source": "startup"}"#)
                == expected(nil, "SessionStart"))
        for source in ["resume", "clear", "compact", "fork"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "SessionStart", "source": "\#(source)"}"#)
                    == expected(nil, "SessionStart", takesOver: true))
        }
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "SessionEnd", "reason": "clear"}"#)
                == expected(AgentState.none, "SessionEnd", releases: true))
    }

    @Test func promptsAndToolCallsMeanWorking() {
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "UserPromptSubmit", "prompt": "Write a function"}"#)
                == expected(.working, "UserPromptSubmit"))
        for event in ["PostToolUse", "PostToolUseFailure"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "\#(event)", "tool_name": "Bash"}"#)
                    == expected(.working, event))
            // A background subagent keeps calling tools while the main agent waits on a question.
            #expect(
                report(
                    #"{"session_id": "abc123", "hook_event_name": "\#(event)", "tool_name": "Bash", "agent_id": "def456"}"#
                )
                    == nil)
        }
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "ElicitationResult"}"#)
                == expected(.working, "ElicitationResult"))
    }

    @Test func questionsPermissionsAndDialogsMeanWaiting() {
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "PreToolUse", "tool_name": "\#(tool)"}"#)
                    == expected(.waiting, "PreToolUse"))
        }
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "PreToolUse", "tool_name": "Bash"}"#) == nil)
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "rm -rf node_modules"}}"#
            )
                == expected(.waiting, "PermissionRequest"))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "agent_id": "def456"}"#
            )
                == nil)
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "Notification", "notification_type": "\#(type)"}"#)
                    == expected(.waiting, "Notification"))
        }
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "Elicitation"}"#) == expected(.waiting, "Elicitation"))
    }

    @Test func otherNotificationsAndEventsMapToNothing() {
        // A background session finishing is not this pane's agent, which Stop reports.
        for type in ["idle_prompt", "auth_success", "elicitation_complete", "agent_completed"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "Notification", "notification_type": "\#(type)"}"#)
                    == nil)
        }
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "SubagentStop", "agent_id": "def456"}"#) == nil)
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "SomeFutureEvent"}"#) == nil)
        #expect(report("not json") == nil)
        #expect(report("") == nil)
        #expect(report(#"["SessionStart"]"#) == nil)
    }

    @Test func aTurnEndsDoneOnAQuestionOrStillWorking() {
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "I've completed the refactoring.", "background_tasks": []}"#
            )
                == expected(.done, "Stop"))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Done.\n\nShould I push it?\n"}"#
            )
                == expected(.waiting, "Stop", question: true))
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "Stop"}"#) == expected(.done, "Stop"))
        for type in ["subagent", "workflow"] {
            #expect(
                report(
                    #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Waiting on it.", "background_tasks": [{"id": "t1", "type": "\#(type)", "status": "running"}]}"#
                )
                    == expected(.working, "Stop"))
        }
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "StopFailure", "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached?"}"#
            )
                == expected(.done, "StopFailure"))
    }

    @Test func aTurnThatEndsWithShellsRunningIsBackground() {
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "The 40-second sleep is running in the background. I'll wait for it to finish and report the output.", "background_tasks": [{"id": "bybwi8u6r", "type": "shell", "status": "running", "description": "Sleep 40 seconds then print finished", "command": "sleep 40 && echo finished"}]}"#
            )
                == expected(.background, "Stop", backgroundTasks: ["Sleep 40 seconds then print finished"]))
        // A label falls back to the command, then the type.
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "The server runs.", "background_tasks": [{"id": "t1", "type": "monitor", "status": "running", "description": " ", "command": "bun dev"}, {"id": "t2", "type": "remote_job"}]}"#
            )
                == expected(.background, "Stop", backgroundTasks: ["bun dev", "remote_job"]))
        // Finished tasks do not count.
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "All done.", "background_tasks": [{"id": "t1", "type": "shell", "status": "completed", "command": "npm test"}]}"#
            )
                == expected(.done, "Stop"))
    }

    @Test func oddTasksAreSkippedAndFinishedSubagentsDoNotCount() {
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "background_tasks": [{"type": "subagent", "status": "running"}, null, "x"]}"#
            )
                == expected(.working, "Stop"))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "background_tasks": [7, {"type": "shell", "status": 3, "command": ["npm"], "description": "Run the tests"}]}"#
            )
                == expected(.background, "Stop", backgroundTasks: ["Run the tests"]))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "background_tasks": [{"type": "subagent", "status": "completed"}]}"#
            )
                == expected(.done, "Stop"))
    }

    @Test func aQuestionOrASubagentWinsOverShells() {
        let shell = #"{"id": "t1", "type": "shell", "status": "running", "command": "npm test"}"#
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Tests run. Should I push?", "background_tasks": [\#(shell)]}"#
            )
                == expected(.waiting, "Stop", question: true))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Both run.", "background_tasks": [\#(shell), {"id": "t2", "type": "subagent", "status": "running"}]}"#
            )
                == expected(.working, "Stop"))
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

    @Test func aFieldThatChangedShapeReadsAsMissing() {
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Done.", "background_tasks": {"count": 2}}"#
            )
                == expected(.done, "Stop"))
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "SessionStart", "source": 7}"#)
                == expected(nil, "SessionStart"))
        #expect(report(#"{"session_id": 12, "hook_event_name": "UserPromptSubmit"}"#)?.state == .working)
    }

    @Test func theQuestionRuleReadsTheLastLine() {
        for message in [
            "Want me to go on?", "Should I proceed?**", "Is that right?\n\n", "(or should I skip it?)", "Push it? ",
            "Which one: `a` or `b`?`", "“Ready?”", "続けますか？", "First line\r\nSecond?",
        ] {
            #expect(ClaudeHookMapping.endsOnQuestion(message), "\(message)")
        }
        for message in [
            "Done.", "Should I? No, it is done.", "What next?\nNothing, it is merged.", "", "\n\n", "?\n```",
        ] {
            #expect(!ClaudeHookMapping.endsOnQuestion(message), "\(message)")
        }
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
