import Foundation
import Testing

@testable import CanopyCore

struct SubprocessTests {
    /// Dispatch's threads block most signals, and so does every thread they start, like the one `onOwnThread` runs git
    /// and gh on. A child inherited that mask, so git and gh ignored SIGTERM, SIGINT, and SIGHUP.
    @Test func aChildEndsOnSIGTERMWhenStartedFromAThreadThatBlocksSignals() async throws {
        let dir = try TempDir()
        var every = sigset_t()
        sigfillset(&every)
        let sleeper = Sleeper(in: dir, blocking: every)
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGTERM)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    /// An ignored signal stays ignored across exec, so a child would inherit any the app ignores.
    @Test func aChildDoesNotIgnoreASignalThisProcessIgnores() async throws {
        let dir = try TempDir()
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let sleeper = Sleeper(in: dir)
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGPIPE)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGPIPE)
    }
}

/// A `sleep 60` started through `Subprocess.run` on a thread of its own that blocks `signals`. It writes its pid to a
/// file first, since `Subprocess.run` returns only once it exits.
private struct Sleeper {
    let pidFile: String
    let result: Task<SubprocessResult, any Error>

    init(in dir: TempDir, blocking signals: sigset_t = sigset_t()) {
        let pidFile = dir.sub("sleeper.pid")
        self.pidFile = pidFile
        result = Task {
            try await offPool {
                var mask = signals
                pthread_sigmask(SIG_BLOCK, &mask, nil)
                return try Subprocess.run(
                    "/bin/bash", ["-c", "echo $$ > '\(pidFile)'; exec /bin/sleep 60"], environment: [:],
                    directory: nil, timeout: .seconds(20))
            }
        }
    }

    func pid() async -> pid_t? {
        var pid: pid_t?
        _ = await eventually {
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return pid
    }
}
