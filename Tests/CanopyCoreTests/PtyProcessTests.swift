import Foundation
import Testing

@testable import CanopyCore

@MainActor
final class PtyRecorder {
    var output = Data()
    var exitCode: Int32?
    var text: String { String(decoding: output, as: UTF8.self) }
}

@MainActor
struct PtyProcessTests {
    let environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory()]

    func start(_ arguments: [String], environment: [String: String]? = nil, directory: String = "/") throws -> (
        PtyProcess, PtyRecorder
    ) {
        let recorder = PtyRecorder()
        let launch = TerminalLaunch(
            executable: arguments[0], arguments: arguments, environment: environment ?? self.environment,
            directory: directory)
        let process = try PtyProcess(
            launch, size: .standard,
            onOutput: { recorder.output.append($0) },
            onExit: { recorder.exitCode = $0 }
        )
        return (process, recorder)
    }

    @Test func deliversOutputThenExitCode() async throws {
        let (_, recorder) = try start(["/bin/sh", "-c", "printf hello; exit 3"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.exitCode == 3)
        #expect(recorder.text == "hello")
    }

    @Test func reportsProcessesThatExitAtOnce() async throws {
        for _ in 0..<20 {
            let (_, recorder) = try start(["/usr/bin/true"])
            #expect(await eventually { recorder.exitCode == 0 })
        }
    }

    @Test func startsInTheFolderWithTheEnvironment() async throws {
        let dir = try TempDir()
        let folder = dir.sub("with space")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let (_, recorder) = try start(
            ["/bin/sh", "-c", #"printf '%s|%s' "$(pwd -P)" "$CANOPY_X""#],
            environment: ["PATH": "/usr/bin:/bin", "CANOPY_X": "yes"], directory: folder)

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text == "\(folder)|yes")
    }

    @Test func childGetsNoInheritedDescriptors() async throws {
        // F_DUPFD takes the lowest free number from 200 up, so it never replaces a descriptor another test uses.
        let original = open("/dev/null", O_RDONLY)
        let leaked = fcntl(original, F_DUPFD, 200)
        defer {
            close(original)
            close(leaked)
        }

        let (_, recorder) = try start(["/bin/sh", "-c", "ls /dev/fd"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(!recorder.text.split(whereSeparator: \.isWhitespace).contains("\(leaked)"))
    }

    @Test func childGetsDefaultSignalHandling() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }

        // With SIGPIPE ignored, `yes` would print "Broken pipe" and exit 1 instead of dying from the signal.
        let (_, recorder) = try start(["/bin/bash", "-c", "yes | head -1 >/dev/null; echo status=${PIPESTATUS[0]}"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.contains("status=141"))
    }

    @Test func largeOutputArrivesWholeAndInOrder() async throws {
        let (_, recorder) = try start(["/usr/bin/seq", "1", "200000"])

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.hasSuffix("199999\r\n200000\r\n"))
        #expect(recorder.text.components(separatedBy: "\r\n").count == 200_001)
    }

    @Test func inputReachesTheProcess() async throws {
        let (process, recorder) = try start(["/bin/sh", "-c", #"read line; printf 'got:%s' "$line""#])

        process.write("hi\r")

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.contains("got:hi"))
    }

    @Test func resizeReachesTheProcess() async throws {
        let (process, recorder) = try start(["/bin/sh", "-c", "sleep 0.3; stty size"])

        process.resize(TerminalSize(columns: 132, rows: 40))

        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.text.contains("40 132"))
    }

    @Test func foregroundAndPromptFollowTheShell() async throws {
        let (process, recorder) = try start(["/bin/bash", "--noprofile", "--norc", "-i"])

        #expect(await eventually { process.isAtPrompt })
        #expect(process.foreground?.name == "bash")
        // Long enough that a loaded machine cannot finish it between two polls.
        process.write("sleep 30\r")
        #expect(await eventually { process.foreground?.name == "sleep" })
        #expect(!process.isAtPrompt)

        process.terminate()
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.exitCode == nil)
    }

    @Test func terminateEndsTheWholeProcessGroup() async throws {
        let (process, _) = try start(["/bin/sh", "-c", "sleep 30 & sleep 30"])
        let group = process.pid
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(-group, 0) == 0)

        process.terminate()

        #expect(await eventually { kill(-group, 0) == -1 && errno == ESRCH })
    }

    @Test func terminalHandlesUTF8Input() async throws {
        // The program stays up after printing, so the check does not race its output against its exit. On a CI
        // runner, stty's output once went missing when it exited straight away.
        let (process, recorder) = try start(["/bin/sh", "-c", "stty -a; sleep 30"])

        #expect(await eventually { recorder.text.split(whereSeparator: \.isWhitespace).contains("iutf8") })
        process.terminate()
    }

    @Test func missingExecutableThrows() {
        #expect(throws: PtySpawnError.self) { try start(["/nonexistent/shell"]) }
    }

    @Test func exitCodeDecodesSignals() {
        #expect(PtyProcess.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(PtyProcess.exitCode(fromWaitStatus: SIGHUP) == 129)
    }
}
