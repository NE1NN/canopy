import CPty
import Darwin
import Foundation
import Synchronization

public struct TerminalSize: Sendable, Equatable, Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public static let standard = TerminalSize(columns: 80, rows: 24)
}

/// What to run in a new pseudo-terminal.
public struct TerminalLaunch: Sendable, Equatable {
    public var executable: String
    /// The whole argv, starting with argv[0]. A leading "-" in argv[0] makes a shell a login shell.
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

public struct ForegroundProcess: Sendable, Equatable {
    /// The foreground process group, which is also the pid of its leader.
    public var pid: pid_t
    public var name: String
}

public struct PtySpawnError: Error, Sendable, Equatable, CustomStringConvertible {
    public var executable: String
    public var code: Int32

    public var description: String {
        "Could not start \(executable): \(String(cString: strerror(code)))"
    }
}

/// A process running in its own pseudo-terminal. Output, then the exit status, arrive on the main actor.
/// Reading runs at most a few chunks ahead of the screen, so a program that floods the terminal waits for
/// drawing to catch up instead of filling an unbounded buffer, while reading and drawing still overlap.
public final class PtyProcess: @unchecked Sendable {
    public typealias OutputHandler = @MainActor @Sendable (Data) -> Void
    public typealias ExitHandler = @MainActor @Sendable (Int32) -> Void

    private struct State {
        var fd: Int32
        var exited = false
        var onOutput: OutputHandler?
        var onExit: ExitHandler?
    }

    public let pid: pid_t
    /// The descriptor closes only in the read source's cancel handler, and writes hold the lock,
    /// so no write can reach a reused descriptor number.
    private let state: Mutex<State>
    private let readQueue = DispatchQueue(label: "canopy.pty.read")
    private let writeQueue = DispatchQueue(label: "canopy.pty.write")
    // Touched only on readQueue.
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    /// Chunks handed to the main actor but not yet shown. Reading runs ahead of drawing by at most this many.
    private let inFlight = DispatchSemaphore(value: 4)

    public init(
        _ launch: TerminalLaunch,
        size: TerminalSize,
        onOutput: @escaping OutputHandler,
        onExit: @escaping ExitHandler
    ) throws {
        guard access(launch.executable, X_OK) == 0 else {
            throw PtySpawnError(executable: launch.executable, code: errno)
        }
        let argv = launch.arguments.map { strdup($0) } + [nil]
        let envp = launch.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        var master: Int32 = -1
        let pid = canopy_pty_spawn(
            launch.executable, argv, envp, launch.directory,
            UInt16(clamping: size.columns), UInt16(clamping: size.rows), &master)
        guard pid > 0 else { throw PtySpawnError(executable: launch.executable, code: errno) }
        self.pid = pid
        self.state = Mutex(State(fd: master, onOutput: onOutput, onExit: onExit))
        let fd = master
        readQueue.async { self.watch(fd) }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async {
            var offset = 0
            while offset < data.count {
                let (count, code, fd) = self.state.withLock { state -> (Int, Int32, Int32) in
                    guard state.fd >= 0 else { return (-1, EBADF, -1) }
                    let count = data.withUnsafeBytes {
                        Darwin.write(state.fd, $0.baseAddress! + offset, $0.count - offset)
                    }
                    return (count, errno, state.fd)
                }
                if count > 0 {
                    offset += count
                } else if code == EAGAIN {
                    // The program is not reading its input yet. Wait outside the lock so output keeps flowing.
                    var poll = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&poll, 1, 100)
                } else if code != EINTR {
                    return
                }
            }
        }
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    public func resize(_ size: TerminalSize) {
        state.withLock { state in
            guard state.fd >= 0 else { return }
            _ = canopy_pty_resize(state.fd, UInt16(clamping: size.columns), UInt16(clamping: size.rows))
        }
    }

    /// The process group the terminal is running in the foreground, such as `claude` or the shell itself.
    public var foreground: ForegroundProcess? {
        let group = state.withLock { $0.fd >= 0 ? tcgetpgrp($0.fd) : -1 }
        guard group > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
        return ForegroundProcess(pid: group, name: name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// True while the process itself is in the foreground with its line editor waiting for input.
    /// Shells switch the terminal out of canonical mode when their prompt is ready.
    public var isAtPrompt: Bool {
        state.withLock { state in
            guard state.fd >= 0, tcgetpgrp(state.fd) == pid else { return false }
            var attributes = termios()
            return tcgetattr(state.fd, &attributes) == 0 && attributes.c_lflag & tcflag_t(ICANON) == 0
        }
    }

    /// Hangs up the terminal. No more output or exit status is delivered.
    public func terminate() {
        state.withLock { state in
            state.onOutput = nil
            state.onExit = nil
            if !state.exited {
                kill(pid, SIGHUP)
            }
        }
        readQueue.async { self.stopReading() }
    }

    // MARK: readQueue

    private func watch(_ fd: Int32) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        reader.setEventHandler { self.drain() }
        reader.setCancelHandler {
            self.state.withLock { state in
                close(state.fd)
                state.fd = -1
            }
        }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        exit.setEventHandler { self.finish() }
        readSource = reader
        exitSource = exit
        reader.activate()
        exit.activate()
        // A child that exited before the source was armed may never be reported, so look without reaping.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            finish()
        }
    }

    /// Reads what is available, up to 256 KB, and hands it to the main actor. Returns the byte count.
    @discardableResult
    private func drain() -> Int {
        guard readSource != nil else { return 0 }
        let fd = state.withLock { $0.fd }
        var chunk = Data()
        while chunk.count < 262_144 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                chunk.append(contentsOf: buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if count == 0 || errno != EAGAIN {
                    // EOF or EIO: nothing holds the terminal open anymore.
                    stopReading()
                }
                break
            }
        }
        if !chunk.isEmpty, let handler = state.withLock({ $0.onOutput }) {
            let output = chunk
            inFlight.wait()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(output) }
                self.inFlight.signal()
            }
        }
        return chunk.count
    }

    private func finish() {
        guard let exitSource else { return }
        exitSource.cancel()
        self.exitSource = nil
        let status = state.withLock { state -> Int32 in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            state.exited = true
            return status
        }
        // Take what the shell wrote before exiting, but stop if something it left behind keeps writing.
        for _ in 0..<16 where drain() > 0 {}
        stopReading()
        let handler = state.withLock { state in
            defer {
                state.onOutput = nil
                state.onExit = nil
            }
            return state.onExit
        }
        if let handler {
            let code = Self.exitCode(fromWaitStatus: status)
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(code) } }
        }
    }

    private func stopReading() {
        readSource?.cancel()
        readSource = nil
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
