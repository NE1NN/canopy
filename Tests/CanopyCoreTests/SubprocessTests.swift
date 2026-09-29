import Foundation
import Testing

@testable import CanopyCore

struct SubprocessTests {
    /// Dispatch's threads block most signals, and so does every thread they start, like the one `onOwnThread` runs git
    /// and gh on. A child inherited that mask, so git and gh held SIGTERM, SIGINT, and SIGHUP pending and ran on.
    @Test func aChildEndsOnSIGTERMWhenStartedFromAThreadThatBlocksSignals() async throws {
        let dir = try TempDir()
        var every = sigset_t()
        sigfillset(&every)
        let sleeper = Sleeper(in: dir, mask: every)
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGTERM)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    /// An ignored signal stays ignored across exec, so a child would inherit any the app ignores, like the SIGINT and
    /// SIGQUIT a script's background job starts with. SIGUSR2 stands in for them, since no other test touches it.
    @Test func aChildDoesNotIgnoreASignalThisProcessIgnores() async throws {
        let dir = try TempDir()
        let previous = signal(SIGUSR2, SIG_IGN)
        defer { signal(SIGUSR2, previous) }
        let sleeper = Sleeper(in: dir, mask: sigset_t())
        let pid = try #require(await sleeper.pid())

        kill(pid, SIGUSR2)
        let result = try await sleeper.result.value

        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGUSR2)
    }

    /// In a background group of the terminal the app was started from, a child with default signals stopped as soon as
    /// it touched that terminal, as an interactive login shell does. In a session of its own it has no terminal at all.
    @Test func aChildRunsInASessionOfItsOwn() async throws {
        let dir = try TempDir()
        let sleeper = Sleeper(in: dir)
        let pid = try #require(await sleeper.pid())

        #expect(getsid(pid) == pid)
        #expect(getpgid(pid) == pid)
        kill(pid, SIGKILL)
        _ = try await sleeper.result.value
    }
}

/// A `sleep 60` started through `Subprocess.run` on a thread of its own, which sets `mask` in place of the one it
/// inherited. It writes its pid to a file first, since `Subprocess.run` returns only once it exits.
private struct Sleeper {
    let pidFile: String
    let result: Task<SubprocessResult, any Error>

    init(in dir: TempDir, mask: sigset_t = sigset_t()) {
        let pidFile = dir.sub("sleeper.pid")
        self.pidFile = pidFile
        result = Task {
            try await offPool {
                var mask = mask
                pthread_sigmask(SIG_SETMASK, &mask, nil)
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
