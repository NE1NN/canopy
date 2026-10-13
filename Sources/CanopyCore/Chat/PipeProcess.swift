import Darwin
import Foundation
import Synchronization

/// A process talking over pipes a line at a time, such as `claude -p` with stream-json. It runs in a session and
/// process group of its own, so ending it ends the tools it started. Lines, then the exit status, arrive on the main
/// actor, and reading runs at most a few batches ahead of them.
public final class PipeProcess: @unchecked Sendable {
    public typealias LinesHandler = @MainActor @Sendable ([Data]) -> Void
    public typealias ExitHandler = @MainActor @Sendable (Int32) -> Void

    /// How many of stderr's last lines it keeps.
    public static let errorLines = 50

    private struct State {
        var input: Int32
        var exited = false
        var onLines: LinesHandler?
        var onExit: ExitHandler?
        var errors: [String] = []
    }

    public let pid: pid_t
    private let state: Mutex<State>
    private let readQueue = DispatchQueue(label: "canopy.pipe.read")
    private let writeQueue = DispatchQueue(label: "canopy.pipe.write")
    // Touched only on readQueue.
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var pending = Data()
    private var pendingErrors = Data()
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private let inFlight = DispatchSemaphore(value: 4)

    public init(_ launch: TerminalLaunch, onLines: @escaping LinesHandler, onExit: @escaping ExitHandler) throws {
        guard access(launch.executable, X_OK) == 0 else {
            throw PtySpawnError(executable: launch.executable, code: errno)
        }
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            let code = errno
            for fd in input + output + errors where fd >= 0 { close(fd) }
            throw PtySpawnError(executable: launch.executable, code: code)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, launch.directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // As in Subprocess: signals back at their defaults, and a session of its own, which has no terminal.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var every = sigset_t()
        sigfillset(&every)
        posix_spawnattr_setsigdefault(&attributes, &every)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = launch.arguments.map { strdup($0) } + [nil]
        let envp = launch.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, launch.executable, &actions, &attributes, argv, envp)
        close(input[0])
        close(output[1])
        close(errors[1])
        guard spawned == 0 else {
            close(input[1])
            close(output[0])
            close(errors[0])
            throw PtySpawnError(executable: launch.executable, code: spawned)
        }
        self.pid = pid
        // A write after the program closed its input fails with EPIPE instead of killing Canopy with SIGPIPE.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        for fd in [input[1], output[0], errors[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(output[0], F_SETFL, fcntl(output[0], F_GETFL) | O_NONBLOCK)
        _ = fcntl(errors[0], F_SETFL, fcntl(errors[0], F_GETFL) | O_NONBLOCK)
        state = Mutex(State(input: input[1], onLines: onLines, onExit: onExit))
        let (out, err) = (output[0], errors[0])
        readQueue.async { self.watch(output: out, errors: err) }
    }

    /// Writes `data` in order behind earlier writes. Nothing happens once the program has closed its input.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { self.writeAll(data) }
    }

    /// Closes the program's input once earlier writes are in, which `claude -p` takes as the end of the session.
    public func closeInput() {
        writeQueue.async {
            self.state.withLock { state in
                if state.input >= 0 {
                    close(state.input)
                    state.input = -1
                }
            }
        }
    }

    /// Stderr's last lines, oldest first.
    public func errorTail() -> [String] {
        state.withLock { $0.errors }
    }

    /// Ends the program and everything in its process group: SIGTERM now, then SIGKILL if it has not exited after
    /// `grace`. Its exit is still reported.
    public func terminate(grace: Duration = .seconds(3)) {
        closeInput()
        state.withLock { state in
            if !state.exited { kill(-pid, SIGTERM) }
        }
        readQueue.asyncAfter(deadline: .now() + grace / .seconds(1)) {
            self.state.withLock { state in
                // Until the exit is reaped the pid and its group cannot be reused, so the signal reaches only them.
                if !state.exited { kill(-self.pid, SIGKILL) }
            }
        }
    }

    // MARK: writeQueue

    private func writeAll(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let (count, code) = state.withLock { state -> (Int, Int32) in
                guard state.input >= 0 else { return (-1, EBADF) }
                let count = data.withUnsafeBytes {
                    Darwin.write(state.input, $0.baseAddress! + offset, $0.count - offset)
                }
                return (count, errno)
            }
            if count > 0 {
                offset += count
            } else if code != EINTR {
                return
            }
        }
    }

    // MARK: readQueue

    private func watch(output: Int32, errors: Int32) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: output, queue: readQueue)
        reader.setEventHandler { self.drainOutput(output) }
        reader.setCancelHandler { close(output) }
        let errorReader = DispatchSource.makeReadSource(fileDescriptor: errors, queue: readQueue)
        errorReader.setEventHandler { self.drainErrors(errors) }
        errorReader.setCancelHandler { close(errors) }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        exit.setEventHandler { self.finish(output: output, errors: errors) }
        outputSource = reader
        errorSource = errorReader
        exitSource = exit
        reader.activate()
        errorReader.activate()
        exit.activate()
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            finish(output: output, errors: errors)
        }
    }

    /// Reads what is there into `into`, returning the byte count and whether the pipe reached its end.
    private func read(_ fd: Int32, into data: inout Data) -> (Int, Bool) {
        var total = 0
        while total < 262_144 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                total += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return (total, count == 0 || errno != EAGAIN)
            }
        }
        return (total, false)
    }

    @discardableResult
    private func drainOutput(_ fd: Int32) -> Int {
        guard outputSource != nil else { return 0 }
        let (count, ended) = read(fd, into: &pending)
        var lines = Self.split(&pending)
        if ended {
            if !pending.isEmpty { lines.append(pending) }
            pending = Data()
            outputSource?.cancel()
            outputSource = nil
        }
        deliver(lines)
        return count
    }

    private func drainErrors(_ fd: Int32) {
        guard errorSource != nil else { return }
        let (_, ended) = read(fd, into: &pendingErrors)
        var lines = Self.split(&pendingErrors)
        if ended {
            if !pendingErrors.isEmpty { lines.append(pendingErrors) }
            pendingErrors = Data()
            errorSource?.cancel()
            errorSource = nil
        }
        guard !lines.isEmpty else { return }
        state.withLock { state in
            state.errors.append(contentsOf: lines.map { String(decoding: $0, as: UTF8.self) })
            if state.errors.count > Self.errorLines { state.errors.removeFirst(state.errors.count - Self.errorLines) }
        }
    }

    private func deliver(_ lines: [Data]) {
        guard !lines.isEmpty, let handler = state.withLock({ $0.onLines }) else { return }
        inFlight.wait()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(lines) }
            self.inFlight.signal()
        }
    }

    /// Takes the complete lines out of `data`, leaving a partial last line in it.
    static func split(_ data: inout Data) -> [Data] {
        guard let last = data.lastIndex(of: 0x0A) else { return [] }
        let lines = data[data.startIndex..<last].split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { Data($0) }
        data = Data(data[data.index(after: last)...])
        return lines.filter { !$0.isEmpty }
    }

    private func finish(output: Int32, errors: Int32) {
        guard exitSource != nil else { return }
        let reaped = state.withLock { state -> Int32? in
            var status: Int32 = 0
            var result: pid_t
            var code: Int32 = 0
            repeat {
                result = waitpid(pid, &status, WNOHANG)
                code = errno
            } while result == -1 && code == EINTR
            guard result == pid || (result == -1 && code == ECHILD) else { return nil }
            state.exited = true
            return status
        }
        guard let status = reaped else {
            readQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { self.finish(output: output, errors: errors) }
            return
        }
        exitSource?.cancel()
        exitSource = nil
        // Take what it wrote before exiting, but stop if something it left behind keeps the pipe open and writing.
        var rounds = 0
        while rounds < 16, outputSource != nil, drainOutput(output) > 0 {
            rounds += 1
        }
        if errorSource != nil { drainErrors(errors) }
        if outputSource != nil {
            if !pending.isEmpty { deliver([pending]) }
            pending = Data()
            outputSource?.cancel()
            outputSource = nil
        }
        errorSource?.cancel()
        errorSource = nil
        writeQueue.async {
            self.state.withLock { state in
                if state.input >= 0 {
                    close(state.input)
                    state.input = -1
                }
            }
        }
        let handler = state.withLock { state in
            defer {
                state.onLines = nil
                state.onExit = nil
            }
            return state.onExit
        }
        if let handler {
            let code = PtyProcess.exitCode(fromWaitStatus: status)
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(code) } }
        }
    }
}
