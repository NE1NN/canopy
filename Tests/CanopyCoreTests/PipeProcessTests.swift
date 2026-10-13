import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

@MainActor
final class LineRecorder {
    var lines: [String] = []
    var exitCode: Int32?
}

@MainActor
struct PipeProcessTests {
    let environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]

    func start(_ script: String, environment: [String: String]? = nil, directory: String = "/") throws -> (
        PipeProcess, LineRecorder
    ) {
        let recorder = LineRecorder()
        let launch = TerminalLaunch(
            executable: "/bin/sh", arguments: ["sh", "-c", script], environment: environment ?? self.environment,
            directory: directory)
        let process = try PipeProcess(
            launch,
            onLines: { recorder.lines += $0.map { String(decoding: $0, as: UTF8.self) } },
            onExit: { recorder.exitCode = $0 })
        return (process, recorder)
    }

    @Test func deliversLinesThenTheExitCode() async throws {
        let (_, recorder) = try start("printf 'one\\ntwo\\nthree'; exit 3")

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.lines == ["one", "two", "three"])
        #expect(recorder.exitCode == 3)
    }

    @Test func answersWhatItIsSent() async throws {
        let (process, recorder) = try start(#"while read -r line; do echo "got:$line"; done"#)

        process.write(Data("a\nb\n".utf8))
        process.write(Data("c\n".utf8))

        #expect(await eventually { recorder.lines.count == 3 })
        #expect(recorder.lines == ["got:a", "got:b", "got:c"])
        process.closeInput()
        #expect(await eventually { recorder.exitCode == 0 })
    }

    @Test func keepsLongLinesWholeAndManyLinesInOrder() async throws {
        let (_, recorder) = try start(
            "head -c 300000 /dev/zero | tr '\\0' x; echo; i=0; while [ $i -lt 5000 ]; do echo $i; i=$((i+1)); done")

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.lines.count == 5001)
        #expect(recorder.lines.first?.count == 300_000)
        #expect(recorder.lines.dropFirst().map { Int($0) } == (0..<5000).map { $0 })
    }

    @Test func keepsTheEndOfStderr() async throws {
        let (process, recorder) = try start("i=0; while [ $i -lt 80 ]; do echo err$i >&2; i=$((i+1)); done; exit 1")

        #expect(await eventually { recorder.exitCode == 1 })
        let tail = process.errorTail()
        #expect(tail.count == PipeProcess.errorLines)
        #expect(tail.first == "err30")
        #expect(tail.last == "err79")
        #expect(recorder.lines.isEmpty)
    }

    @Test func startsInTheFolderWithTheEnvironment() async throws {
        let dir = try TempDir()
        let (_, recorder) = try start(
            #"echo "$(pwd -P)|$CANOPY_X""#, environment: ["PATH": "/usr/bin:/bin", "CANOPY_X": "yes"],
            directory: dir.path)

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.lines == ["\(dir.path)|yes"])
    }

    /// Ending a chat ends the tools its agent started, which run in the agent's process group.
    @Test func terminateEndsTheProcessAndWhatItStarted() async throws {
        let dir = try TempDir()
        let marker = dir.sub("child.pid")
        let (process, recorder) = try start("sleep 300 & echo $! > '\(marker)'; echo started; wait")
        #expect(await eventually { recorder.lines == ["started"] })
        let child = try #require(
            pid_t(String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        process.terminate()

        #expect(await eventually { recorder.exitCode != nil })
        #expect(await eventually { kill(child, 0) != 0 })
    }

    /// A program that ignores SIGTERM is killed after the grace period.
    @Test func terminateKillsAProgramThatWillNotStop() async throws {
        let (process, recorder) = try start("trap '' TERM; echo ready; while :; do sleep 1; done")
        #expect(await eventually { recorder.lines == ["ready"] })

        process.terminate(grace: .milliseconds(300))

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.exitCode == 128 + SIGKILL)
    }

    @Test func writingAfterItExitedDoesNothing() async throws {
        let (process, recorder) = try start("exit 0")
        #expect(await eventually { recorder.exitCode == 0 })

        process.write(Data("late\n".utf8))
        process.closeInput()
        process.terminate()

        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.lines.isEmpty)
    }

    @Test func refusesAMissingProgram() {
        let launch = TerminalLaunch(
            executable: "/no/such/program", arguments: ["program"], environment: environment, directory: "/")

        #expect(throws: PtySpawnError.self) {
            try PipeProcess(launch, onLines: { _ in }, onExit: { _ in })
        }
    }
}
