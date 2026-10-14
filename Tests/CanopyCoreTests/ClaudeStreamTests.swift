import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// `scripts/fake-claude-stream.py`, run through python3 so no freshly written file is executed.
enum FakeClaude {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/fake-claude-stream.py").path

    static func launch(home: String, folder: String, _ arguments: [String] = [], environment: [String: String] = [:])
        -> TerminalLaunch
    {
        TerminalLaunch(
            executable: "/usr/bin/python3",
            arguments: ["python3", "-I", script] + ClaudeLaunch.arguments(model: "sonnet", mode: "default") + arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": home, "FAKE_CLAUDE_DELAY": "0"].merging(environment) {
                $1
            },
            directory: folder)
    }
}

@MainActor
final class StreamRecorder {
    var events: [ClaudeEvent] = []
    var exit: (code: Int32, errors: [String])?

    var texts: [String] {
        events.compactMap {
            if case .result(let result) = $0 { result.text } else { nil }
        }
    }

    var toolRequests: [ClaudeToolRequest] {
        events.compactMap {
            if case .toolRequest(let request) = $0 { request } else { nil }
        }
    }
}

@MainActor
struct ClaudeStreamTests {
    let dir: TempDir

    init() throws {
        dir = try TempDir()
    }

    func start(_ launch: TerminalLaunch? = nil) throws -> (ClaudeStream, StreamRecorder) {
        let recorder = StreamRecorder()
        let stream = ClaudeStream()
        stream.onEvent = { recorder.events.append($0) }
        stream.onExit = { recorder.exit = ($0, $1) }
        try stream.start(launch ?? FakeClaude.launch(home: dir.path, folder: dir.path))
        return (stream, recorder)
    }

    @Test func startsWithTheCommandsClaudeOffers() async throws {
        let (stream, _) = try start()

        #expect(await eventually { !stream.commands.isEmpty })
        #expect(
            stream.commands == [
                ClaudeCommand(name: "compact", description: "Clear history but keep a summary", argumentHint: ""),
                ClaudeCommand(name: "greet", description: "Say the greeting (project)", argumentHint: "<name>"),
            ])
        stream.stop()
    }

    @Test func sendsMessagesAndStreamsTheReply() async throws {
        let (stream, recorder) = try start()

        stream.send([.text("say hello there")])

        #expect(await eventually { recorder.texts == ["hello there"] })
        let deltas = recorder.events.compactMap {
            if case .textDelta(_, let text) = $0 { text } else { nil }
        }
        #expect(deltas == ["hello ", "there"])
        #expect(
            recorder.events.contains {
                if case .initialized(let info) = $0 { info.cwd == dir.path } else { false }
            })
        stream.stop()
    }

    @Test func answersAPermissionPrompt() async throws {
        let (stream, recorder) = try start()

        stream.send([.text("run ls -la")])
        #expect(await eventually { recorder.toolRequests.count == 1 })
        let request = try #require(recorder.toolRequests.first)
        #expect(request.tool == "Bash")
        #expect(request.input["command"] == "ls -la")
        stream.answer(ClaudeInput.allow(request: request.id, input: request.input))

        #expect(await eventually { recorder.texts == ["It ran."] })
        stream.stop()
    }

    @Test func requestsReturnWhatClaudeAnswers() async throws {
        let (stream, recorder) = try start()

        let answer = try await stream.request("set_permission_mode", ["mode": "plan"])

        #expect(answer == .object(["mode": "plan"]))
        #expect(
            await eventually {
                recorder.events.contains { $0 == .status(ClaudeStatus(activity: nil, mode: "plan", compacted: nil)) }
            })
        await #expect(throws: ClaudeStreamError.refused("Unsupported control request: rewind_files")) {
            try await stream.request("rewind_files")
        }
        stream.stop()
    }

    /// A control request Canopy does not handle is answered with an error at once, so Claude never waits on it.
    @Test func refusesRequestsItDoesNotHandle() async throws {
        let (stream, recorder) = try start()

        stream.send([.text("callback")])

        #expect(await eventually { recorder.texts.first?.hasPrefix("answered: ") == true })
        #expect(recorder.texts.first?.contains("mcp_message") == true)
        stream.stop()
    }

    @Test func reportsAnExitWithTheEndOfStderr() async throws {
        let (stream, recorder) = try start()

        stream.send([.text("crash")])

        #expect(await eventually { recorder.exit != nil })
        #expect(recorder.exit?.code == 1)
        #expect(recorder.exit?.errors == ["boom: something broke"])
        #expect(!stream.isRunning)
    }

    @Test func aRequestNobodyAnswersTimesOut() async throws {
        let silent = TerminalLaunch(
            executable: "/bin/sh", arguments: ["sh", "-c", "cat > /dev/null"], environment: ["PATH": "/usr/bin:/bin"],
            directory: dir.path)
        let (stream, _) = try start(silent)

        await #expect(throws: ClaudeStreamError.timedOut) {
            try await stream.request("interrupt", timeout: .milliseconds(200))
        }
        stream.stop()
    }

    @Test func stoppingFailsRequestsStillWaiting() async throws {
        let silent = TerminalLaunch(
            executable: "/bin/sh", arguments: ["sh", "-c", "cat > /dev/null"], environment: ["PATH": "/usr/bin:/bin"],
            directory: dir.path)
        let (stream, recorder) = try start(silent)

        let answer = Task { try await stream.request("interrupt") }
        try await Task.sleep(for: .milliseconds(100))
        stream.stop()

        await #expect(throws: ClaudeStreamError.notRunning) { try await answer.value }
        #expect(await eventually { recorder.exit != nil })
        #expect(throws: ClaudeStreamError.notRunning) { try stream.requireRunning() }
    }

    @Test func buildsClaudeCodesArguments() {
        #expect(
            ClaudeLaunch.arguments(model: "opus", mode: "acceptEdits", resume: "s-1") == [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                "--model", "opus", "--permission-mode", "acceptEdits", "--resume", "s-1",
            ])
        #expect(
            ClaudeLaunch.script(arguments: ["-p", "--model", "it's"])
                == "exec claude '-p' '--model' 'it'\\''s'")
    }
}
