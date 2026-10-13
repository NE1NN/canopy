import CSystemShims
import Foundation
import Synchronization

public struct SubprocessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
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

    /// Sends `number` to the process alone, such as SIGTERM to ask it to stop. Nothing once it has exited.
    public func signal(_ number: Int32) {
        state.withLock { state in
            if let pid = state.pid { kill(pid, number) }
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

    /// Reaps the child if it has exited, holding the lock, so `cancel` never signals a pid that is free to be reused.
    /// With `wait`, blocks until it exits.
    fileprivate func reap(_ pid: pid_t, wait: Bool) -> Int32? {
        state.withLock { state in
            var status: Int32 = 0
            var reaped: pid_t
            repeat {
                reaped = waitpid(pid, &status, wait ? 0 : WNOHANG)
            } while reaped == -1 && errno == EINTR
            guard reaped != 0 else { return nil }
            state.pid = nil
            state.errors = -1
            return status
        }
    }
}

#if canImport(Darwin)
    private typealias KeventCall = (
        Int32, UnsafePointer<kevent>?, Int32, UnsafeMutablePointer<kevent>?, Int32, UnsafePointer<timespec>?
    ) -> Int32
#endif

public enum Subprocess {
    /// Runs a program in a session of its own, with no controlling terminal, stdin from `stdin` or else /dev/null, no
    /// inherited descriptors, and every signal unblocked and at its default, blocking the calling thread until it exits.
    /// On timeout the session's process group, the child and everything it started, is killed.
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
        stdin: Data? = nil,
        handle: SubprocessHandle? = nil
    ) throws -> SubprocessResult {
        let input = try stdin.map { try inputFile(holding: $0, for: executable) }
        defer { input.map { _ = close($0) } }
        let output = try temporaryFile(for: executable)
        defer { close(output) }
        let errors = try temporaryFile(for: executable)
        defer { close(errors) }

        // A pointer on Darwin, a struct on Glibc and Musl.
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t?
        #else
            var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let input {
            posix_spawn_file_actions_adddup2(&actions, input, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, errors, 2)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        #if canImport(Darwin)
            var attributes: posix_spawnattr_t?
        #else
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Dispatch's threads, and threads they start, block most signals, a child inherits the caller's mask, and an
        // ignored signal stays ignored across exec. With its signals back at their defaults, a child in a background
        // group of a terminal the app was started from would stop the moment it touched that terminal, so it gets a
        // session of its own, which has no terminal.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var every = sigset_t()
        sigfillset(&every)
        posix_spawnattr_setsigdefault(&attributes, &every)
        #if canImport(Darwin)
            let flags =
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        #else
            // Linux has no POSIX_SPAWN_CLOEXEC_DEFAULT, so every descriptor open now is marked close-on-exec instead.
            // One another thread opens after this without O_CLOEXEC can still reach the child.
            closeOnExec()
            // glibc declares POSIX_SPAWN_SETSID only under _GNU_SOURCE, which Swift's import leaves out; it is 0x80
            // there and in musl.
            let flags = 0x80 | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))

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
        #if canImport(Darwin)
            let timedOut = !waitForExit(pid, timeout: timeout)
            if timedOut {
                kill(-pid, SIGKILL)
            }
            handle?.exited()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        #else
            let (status, timedOut) = reap(pid, timeout: timeout, handle: handle ?? SubprocessHandle())
        #endif

        let signal = status & 0x7f
        return SubprocessResult(
            status: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
            stdout: contents(of: output),
            stderr: contents(of: errors),
            timedOut: timedOut
        )
    }

    #if !canImport(Darwin)
        /// Polls until `pid` exits, reaping it under the handle's lock, or kills its group once the timeout passes.
        /// Linux's way to wait without reaping, `waitid` with `WNOWAIT`, reports through a `siginfo_t` whose layout
        /// differs between Glibc and Musl.
        private static func reap(_ pid: pid_t, timeout: Duration?, handle: SubprocessHandle) -> (Int32, Bool) {
            let deadline = timeout.map { ContinuousClock.now + $0 }
            while true {
                if let status = handle.reap(pid, wait: false) { return (status, false) }
                if let deadline, ContinuousClock.now >= deadline {
                    kill(-pid, SIGKILL)
                    return (handle.reap(pid, wait: true) ?? 0, true)
                }
                usleep(5_000)
            }
        }

        /// Marks every descriptor above stderr close-on-exec.
        private static func closeOnExec() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else { return }
            for descriptor in names.compactMap(Int32.init) where descriptor > 2 {
                let flags = fcntl(descriptor, F_GETFD)
                if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
            }
        }
    #endif

    #if canImport(Darwin)
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
    #endif

    private static func temporaryFile(for executable: String) throws -> Int32 {
        var template = Array((NSTemporaryDirectory() + "canopy-output.XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { canopy_mkstemp_closing_on_exec($0.baseAddress!) }
        guard descriptor >= 0 else { throw SubprocessError(executable: executable, code: errno) }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        return descriptor
    }

    private static func inputFile(holding data: Data, for executable: String) throws -> Int32 {
        let descriptor = try temporaryFile(for: executable)
        let failure: Int32? = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if errno != EINTR {
                    return errno
                }
            }
            return nil
        }
        if let failure {
            close(descriptor)
            throw SubprocessError(executable: executable, code: failure)
        }
        lseek(descriptor, 0, SEEK_SET)
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
