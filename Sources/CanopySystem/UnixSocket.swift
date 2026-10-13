import CSystemShims
import Dispatch
import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public enum UnixSocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case folderNotPrivate(String)
    case alreadyRunning(String)
    case system(String, errno: Int32)
    case timedOut
    case closed
    case lineTooLong

    public var description: String {
        switch self {
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .folderNotPrivate(let path): "\(path) is not a folder of this user's alone."
        case .alreadyRunning(let path): "Something already listens on \(path)."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .timedOut: "The other side did not answer in time."
        case .closed: "The connection is closed."
        case .lineTooLong: "The other side sent a line too long to read."
        }
    }
}

/// Listens on a Unix socket that only this user can reach, and hands each connection to `accept` on a thread of its
/// own, so a call that runs as long as it likes holds up no other.
public final class UnixListener: Sendable {
    public let path: String
    private let source: SendableSource
    private let socketClosed = DispatchSemaphore(value: 0)
    /// The socket file this listener made, so closing never removes one a later listener made at the same path.
    private let file: (device: UInt64, inode: UInt64)
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// Makes the socket's folder this user's alone, refuses a path something already answers on, and replaces a socket
    /// file nothing answers on, as one a killed process left.
    public init(path: String, accept: @escaping @Sendable (UnixConnection) -> Void) throws {
        let address = try UnixAddress(path)
        try Self.makePrivateFolder((path as NSString).deletingLastPathComponent)
        if FileManager.default.fileExists(atPath: path) {
            if let live = try? UnixConnection.connect(path: path) {
                live.close()
                throw UnixSocketError.alreadyRunning(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, streamSocket | closeOnExecSocket, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno: errno) }
        var info = stat()
        do {
            let bound = address.withSockaddr { Foundation.bind(fd, $0, $1) }
            guard bound == 0 else { throw UnixSocketError.system("bind", errno: errno) }
            guard chmod(path, 0o600) == 0, listen(fd, 64) == 0, lstat(path, &info) == 0 else {
                let code = errno
                unlink(path)
                throw UnixSocketError.system("listen", errno: code)
            }
            makeNonBlocking(fd)
        } catch {
            _ = Foundation.close(fd)
            throw error
        }
        self.path = path
        file = (UInt64(info.st_dev), UInt64(info.st_ino))
        let queue = DispatchQueue(label: "canopy.unix-listener")
        queue.setSpecific(key: Self.queueKey, value: true)
        let socketClosed = socketClosed
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = canopy_accept_closing_on_exec(fd)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                let connection = UnixConnection(fd: client)
                let thread = Thread { accept(connection) }
                thread.name = "canopy.unix-connection"
                thread.start()
            }
        }
        source.setCancelHandler {
            _ = Foundation.close(fd)
            socketClosed.signal()
        }
        source.resume()
        self.source = SendableSource(source)
    }

    /// Stops listening and removes the socket file. Connections it accepted stay open. Safe to call more than once.
    public func close() {
        guard stopListening() else { return }
        var info = stat()
        if lstat(path, &info) == 0, UInt64(info.st_dev) == file.device, UInt64(info.st_ino) == file.inode {
            unlink(path)
        }
    }

    private func stopListening() -> Bool {
        guard !source.isCancelled else { return false }
        source.cancel()
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            socketClosed.wait()
            socketClosed.signal()
        }
        return true
    }

    /// Makes `folder` if needed and leaves it to this user alone, so no one else can reach a socket in it.
    static func makePrivateFolder(_ folder: String) throws {
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
            chmod(folder, 0o700) == 0
        else { throw UnixSocketError.folderNotPrivate(folder) }
    }
}

/// A connected Unix socket, read a line at a time by one thread and written by any, waiting in poll(2) and never
/// inside read(2) or write(2), and never raising SIGPIPE.
public final class UnixConnection: Sendable {
    /// A request may carry a hook's whole input, but not more than this.
    public static let longestLine = 16 << 20

    private let fd: Int32
    private let buffer = Mutex(Data())
    private let writing = Mutex(())
    private let closed = Atomic(false)

    init(fd: Int32) {
        self.fd = fd
        makeNonBlocking(fd)
        #if canImport(Darwin)
            try? setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
    }

    deinit {
        _ = Foundation.close(fd)
    }

    public static func connect(path: String) throws -> UnixConnection {
        let address = try UnixAddress(path)
        let fd = socket(AF_UNIX, streamSocket | closeOnExecSocket, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno: errno) }
        guard address.withSockaddr({ Foundation.connect(fd, $0, $1) }) == 0 else {
            let code = errno
            _ = Foundation.close(fd)
            throw UnixSocketError.system("connect", errno: code)
        }
        return UnixConnection(fd: fd)
    }

    /// The next line without its newline, waiting until `deadline`, or forever when it is nil. A last line the other
    /// side ended without a newline still comes, then nil once it has closed its side.
    public func readLine(deadline: ContinuousClock.Instant?) throws -> Data? {
        while true {
            let line = buffer.withLock { buffer -> Data? in
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            if let line { return line }
            guard buffer.withLock({ $0.count }) <= Self.longestLine else { throw UnixSocketError.lineTooLong }
            let chunk = try read(deadline: deadline)
            if chunk.isEmpty {
                return buffer.withLock { buffer in
                    defer { buffer.removeAll() }
                    return buffer.isEmpty ? nil : buffer
                }
            }
            buffer.withLock { $0.append(chunk) }
        }
    }

    /// Writes all of `data`, waiting for room until `deadline`. Writes from several threads go one after another.
    public func write(_ data: Data, deadline: ContinuousClock.Instant?) throws {
        try writing.withLock { _ in
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard !closed.load(ordering: .acquiring) else { throw UnixSocketError.closed }
                    let sent = sendBytes(fd, raw.baseAddress! + offset, raw.count - offset)
                    if sent >= 0 {
                        offset += sent
                        continue
                    }
                    let code = errno
                    guard code == EINTR || code == EAGAIN || code == EWOULDBLOCK else {
                        throw UnixSocketError.system("send", errno: code)
                    }
                    try wait(for: Int16(POLLOUT), deadline: deadline)
                }
            }
        }
    }

    /// Whether the other side hangs up within `timeout`. What it sends meanwhile stays to be read.
    public func hungUp(within timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if closed.load(ordering: .acquiring) { return true }
            do {
                try wait(for: Int16(POLLIN), deadline: deadline)
            } catch UnixSocketError.timedOut {
                return false
            } catch {
                return true
            }
            var byte: UInt8 = 0
            let peeked = recv(fd, &byte, 1, Int32(MSG_PEEK))
            if peeked == 0 { return true }
            if peeked > 0 { return false }
            if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { return true }
        }
    }

    /// Ends the connection both ways. A thread waiting on it wakes; the descriptor closes once nothing holds the
    /// connection, so it is never reused under a thread still polling it.
    public func close() {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        shutdown(fd, Int32(SHUT_RDWR))
    }

    private func read(deadline: ContinuousClock.Instant?) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            guard !closed.load(ordering: .acquiring) else { throw UnixSocketError.closed }
            let count = recv(fd, &chunk, chunk.count, 0)
            if count >= 0 { return Data(chunk[0..<count]) }
            let code = errno
            guard code == EINTR || code == EAGAIN || code == EWOULDBLOCK else {
                if code == ECONNRESET { return Data() }
                throw UnixSocketError.system("recv", errno: code)
            }
            try wait(for: Int16(POLLIN), deadline: deadline)
        }
    }

    /// Returns once `event` may be ready, or the other side hung up, or throws once `deadline` passes.
    private func wait(for event: Int16, deadline: ContinuousClock.Instant?) throws {
        var request = pollfd(fd: fd, events: event, revents: 0)
        while true {
            var limit: Int32 = -1
            if let deadline {
                let left = deadline - .now
                guard left > .zero else { throw UnixSocketError.timedOut }
                limit = Int32(clamping: Int((left / .milliseconds(1)).rounded(.up)))
            }
            let ready = poll(&request, 1, limit)
            if ready > 0 { return }
            if ready < 0 && errno != EINTR && errno != EAGAIN { throw UnixSocketError.system("poll", errno: errno) }
        }
    }
}

/// A Unix socket's address.
private struct UnixAddress {
    private var address = sockaddr_un()

    init(_ path: String) throws {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.pathTooLong(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafeBytes(of: address) { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
