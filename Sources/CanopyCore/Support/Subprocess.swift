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

/// Lets other threads stop a running subprocess and read what it has written to stderr so far.
public final class SubprocessHandle: Sendable {
    private struct State {
        var pid: pid_t?
        var errors: Int32 = -1
        var cancelled = false
    }

    private let state = Mutex(State())

    public init() {}

    public var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    /// True from when the process starts until it has exited.
    public var isRunning: Bool {
        state.withLock { $0.pid != nil }
    }

    /// Kills the process and everything it started. One that has not started yet is killed as it starts.
    public func cancel() {
        state.withLock { state in
            state.cancelled = true
            if let pid = state.pid { kill(-pid, SIGKILL) }
        }
    }

    /// Up to the last `limit` bytes of stderr so far. Empty before the process starts and after it exits.
    public func errorOutput(last limit: Int = 4096) -> Data {
        state.withLock { state in
            guard state.errors >= 0 else { return Data() }
            var info = stat()
            guard fstat(state.errors, &info) == 0 else { return Data() }
            let count = min(Int(info.st_size), limit)
            var buffer = [UInt8](repeating: 0, count: count)
            let read = pread(state.errors, &buffer, count, info.st_size - off_t(count))
            return read > 0 ? Data(buffer[0..<read]) : Data()
        }
    }

    /// The process is at worst a zombie until it is reaped, so its pid and group cannot be reused before `exited`.
    fileprivate func started(pid: pid_t, errors: Int32) {
        state.withLock { state in
            state.pid = pid
            state.errors = errors
            if state.cancelled { kill(-pid, SIGKILL) }
        }
    }

    fileprivate func exited() {
        state.withLock { state in
            state.pid = nil
            state.errors = -1
        }
    }
}

private typealias KeventCall = (
    Int32, UnsafePointer<kevent>?, Int32, UnsafeMutablePointer<kevent>?, Int32, UnsafePointer<timespec>?
) -> Int32

public enum Subprocess {
    /// Runs a program in its own process group with stdin from /dev/null and no inherited descriptors,
    /// blocking the calling thread until it exits. On timeout the whole group is killed.
    /// Call it through `onOwnThread`, not on a Dispatch global queue, whose threads run out.
    ///
    /// Output goes to unlinked temporary files rather than pipes: a background process the child leaves
    /// behind (a daemon started by a shell's rc files, say) can keep a pipe open forever, but a file is
    /// simply read up to its current end once the child has exited.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?,
        timeout: Duration?,
        handle: SubprocessHandle? = nil
    ) throws -> SubprocessResult {
        let output = try temporaryFile(for: executable)
        defer { close(output) }
        let errors = try temporaryFile(for: executable)
        defer { close(errors) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, errors, 2)
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
        guard spawned == 0 else { throw SubprocessError(executable: executable, code: spawned) }
        handle?.started(pid: pid, errors: errors)

        // Until waitpid reaps it, the child is at worst a zombie, so its pid and process group cannot be reused.
        let timedOut = !waitForExit(pid, timeout: timeout)
        if timedOut {
            kill(-pid, SIGKILL)
        }
        handle?.exited()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}

        let signal = status & 0x7f
        return SubprocessResult(
            status: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
            stdout: contents(of: output),
            stderr: contents(of: errors),
            timedOut: timedOut
        )
    }

    /// Waits for `pid` to exit without reaping it. Returns false if the timeout passed first.
    private static func waitForExit(_ pid: pid_t, timeout: Duration?) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return true }
        defer { close(queue) }
        var change = Darwin.kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil)
        var event = Darwin.kevent()
        // Typed to pick the kevent(2) function over the kevent struct's initializer.
        let watch: KeventCall = kevent
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while true {
            let count: Int32
            if let deadline {
                let left = max(deadline - ContinuousClock.now, .zero).components
                var limit = timespec(tv_sec: Int(left.seconds), tv_nsec: Int(left.attoseconds / 1_000_000_000))
                count = watch(queue, &change, 1, &event, 1, &limit)
            } else {
                count = watch(queue, &change, 1, &event, 1, nil)
            }
            if count > 0 { return true }
            if count == 0 { return false }
            if errno == ESRCH { return true }  // Already exited before the watch was added.
            guard errno == EINTR else { return true }
        }
    }

    private static func temporaryFile(for executable: String) throws -> Int32 {
        var template = Array((NSTemporaryDirectory() + "canopy-output.XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw SubprocessError(executable: executable, code: errno) }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        return descriptor
    }

    private static func contents(of descriptor: Int32) -> Data {
        lseek(descriptor, 0, SEEK_SET)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 || errno != EINTR {
                return data
            }
        }
    }
}
