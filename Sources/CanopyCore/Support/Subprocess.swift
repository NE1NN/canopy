import Foundation
import Synchronization

public struct SubprocessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
}

public struct SubprocessError: Error, Sendable, Equatable, CustomStringConvertible {
    public var executable: String
    public var code: Int32

    public var description: String {
        "Could not start \(executable): \(String(cString: strerror(code)))"
    }
}

public enum Subprocess {
    /// Runs a program in its own process group with stdin from /dev/null and no inherited descriptors.
    /// On timeout the whole group is killed, including grandchildren (such as ssh under git fetch)
    /// that would otherwise keep the output pipes open forever.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?,
        timeout: Duration?
    ) throws -> SubprocessResult {
        var output: [Int32] = [0, 0]
        var errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw SubprocessError(executable: executable, code: errno) }
        guard pipe(&errors) == 0 else {
            close(output[0])
            close(output[1])
            throw SubprocessError(executable: executable, code: errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(output[1])
        close(errors[1])
        guard spawned == 0 else {
            close(output[0])
            close(errors[0])
            throw SubprocessError(executable: executable, code: spawned)
        }

        let child = pid
        let errorDescriptor = errors[0]
        // The child is only reaped under this lock, so the timer never signals a reused process group.
        let reaped = Mutex(false)
        let timedOut = Mutex(false)
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds) {
                reaped.withLock { reaped in
                    guard !reaped else { return }
                    timedOut.withLock { $0 = true }
                    kill(-child, SIGKILL)
                }
            }
        }

        let errorData = Mutex(Data())
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            let data = FileHandle(fileDescriptor: errorDescriptor, closeOnDealloc: true).readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }
        let outputData = FileHandle(fileDescriptor: output[0], closeOnDealloc: true).readDataToEndOfFile()
        group.wait()

        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        var status: Int32 = 0
        reaped.withLock { reaped in
            waitpid(child, &status, 0)
            reaped = true
        }

        let signal = status & 0x7f
        return SubprocessResult(
            status: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
            stdout: outputData,
            stderr: errorData.withLock { $0 },
            timedOut: timedOut.withLock { $0 }
        )
    }
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
