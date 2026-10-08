import Foundation
import Synchronization

public enum HostRelayServerError: Error, Equatable, CustomStringConvertible {
    case socketPathTooLong(String)
    case folderNotPrivate(String)
    case listenFailed(String, errno: Int32)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path): "Socket path is longer than macOS allows: \(path)"
        case .folderNotPrivate(let path): "\(path) is not a folder of this user's alone."
        case .listenFailed(let path, let code): "Could not listen on \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Serves one host's relayed CLI calls on the Unix socket ssh forwards the host's relay to: one request per
/// connection, each on a thread of its own, since a call lasts as long as its CLI runs. A call whose relay hangs up is
/// cancelled, which stops its CLI.
/// A request of the current version is acknowledged as soon as it is read, before it runs, since sshd on the host
/// accepts a connection even while this Mac sleeps: a relay that hears nothing knows the call never reached the app.
public final class HostRelayServer: Sendable {
    public typealias Handler = @Sendable (RelayRequest, _ host: String) async -> RelayReply

    /// A request holds its stdin, so it may be long, but not this long.
    static let maximumRequest = 16 << 20
    /// The relay sends its request as it connects and reads its reply at once, so a longer wait means it is stuck.
    static let transferWait: Duration = .seconds(60)
    /// The line a request of the current version gets before its reply. A relay of another version gets the reply
    /// alone, so an older relay never reads a line it does not expect.
    static let acknowledgement = Data("{\"ack\": true}\n".utf8)

    public let socketPath: String
    public let host: String
    /// The relay version this server acknowledges, which is the one the handler runs.
    let version: String
    private let handler: Handler

    private struct State {
        var started = false
        var stopped = false
        /// Written to as the server stops, to wake the thread that accepts connections.
        var wake: Int32 = -1
        /// The socket file this server made, so stopping never removes one a later server made at the same path.
        var socket: (device: dev_t, inode: ino_t)?
        var calls: [UUID: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    public init(
        socketPath: String, host: String, version: String = HostFiles.version, handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.host = host
        self.version = version
        self.handler = handler
    }

    /// Listens on the socket, readable by this user alone, in place of any file at its path. A server starts once.
    public func start() throws {
        guard socketPath.utf8.count < HostPaths.socketPathLimit else {
            throw HostRelayServerError.socketPathTooLong(socketPath)
        }
        let claimed = state.withLock { state in
            defer { state.started = true }
            return !state.started && !state.stopped
        }
        guard claimed else { return }
        let listener: Int32
        var pipe: [Int32] = [-1, -1]
        do {
            try Self.makePrivateFolder((socketPath as NSString).deletingLastPathComponent)
            unlink(socketPath)
            listener = try listen()
            guard Darwin.pipe(&pipe) == 0 else {
                let code = errno
                close(listener)
                unlink(socketPath)
                throw HostRelayServerError.listenFailed(socketPath, errno: code)
            }
        } catch {
            state.withLock { $0.started = false }
            throw error
        }
        for fd in pipe + [listener] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var info = stat()
        let socket = lstat(socketPath, &info) == 0 ? (device: info.st_dev, inode: info.st_ino) : nil
        let (woken, wake) = (pipe[0], pipe[1])
        let stopped = state.withLock { state in
            guard !state.stopped else { return true }
            state.wake = wake
            state.socket = socket
            return false
        }
        guard !stopped else {
            // Stopped while starting, so stop() found nothing to stop.
            for fd in pipe + [listener] { close(fd) }
            unlink(socketPath)
            return
        }
        let thread = Thread { self.accept(on: listener, until: woken) }
        thread.name = "canopy.host-relay"
        thread.start()
    }

    /// Stops listening and cancels the calls running. A call cancelled this way answers nothing.
    public func stop() {
        let (wake, socket, calls) = state.withLock { state in
            let taken = (state.wake, state.socket, Array(state.calls.values))
            state.stopped = true
            state.wake = -1
            state.socket = nil
            state.calls = [:]
            return taken
        }
        if wake >= 0 {
            var byte: UInt8 = 0
            _ = write(wake, &byte, 1)
            close(wake)
        }
        for call in calls { call.cancel() }
        var info = stat()
        if let socket, lstat(socketPath, &info) == 0, info.st_dev == socket.device, info.st_ino == socket.inode {
            unlink(socketPath)
        }
    }

    /// Makes `folder` if needed and leaves it to this user alone, so no one else can reach the socket in it while it
    /// is being made.
    static func makePrivateFolder(_ folder: String) throws {
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
            chmod(folder, 0o700) == 0
        else { throw HostRelayServerError.folderNotPrivate(folder) }
    }

    private func listen() throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostRelayServerError.listenFailed(socketPath, errno: errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            if bound == 0 { unlink(socketPath) }
            throw HostRelayServerError.listenFailed(socketPath, errno: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func accept(on listener: Int32, until woken: Int32) {
        defer {
            close(listener)
            close(woken)
        }
        var watched = [
            pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
            pollfd(fd: woken, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            let ready = poll(&watched, 2, -1)
            if ready < 0 {
                guard errno == EINTR || errno == EAGAIN else { return }
                continue
            }
            if watched[1].revents != 0 { return }
            guard watched[0].revents != 0 else { continue }
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else {
                // Out of descriptors, say. The connection waits in the backlog rather than spinning this thread.
                if errno != EAGAIN && errno != EINTR && errno != ECONNABORTED { usleep(100_000) }
                continue
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { self.serve(connection) }
            thread.name = "canopy.host-relay-call"
            thread.start()
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        let reply: RelayReply
        switch Self.readRequest(connection) {
        case .gone:
            return
        case .invalid(let message):
            reply = .failure(message, code: "bad_request")
        case .request(let request):
            if acknowledges(request) {
                let stream = SocketStream(fd: connection, deadline: .now + Self.transferWait)
                // A relay that missed the acknowledgement keeps a hook's report, so the call must not run either.
                guard (try? stream.write(Self.acknowledgement)) != nil else { return }
            }
            guard let answered = run(request, on: connection) else { return }
            reply = answered
        }
        guard var line = try? JSONEncoder().encode(reply) else { return }
        line.append(0x0A)
        try? SocketStream(fd: connection, deadline: .now + Self.transferWait).write(line)
    }

    func acknowledges(_ request: RelayRequest) -> Bool {
        request.version == version
    }

    /// Runs the call until it answers, or cancels it once the relay hangs up and returns nil.
    private func run(_ request: RelayRequest, on connection: Int32) -> RelayReply? {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return .failure("Canopy is out of resources.", code: "relay_failed") }
        for fd in pipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        defer { for fd in pipe { close(fd) } }
        let (done, finished) = (pipe[0], pipe[1])
        let answer = Answer()
        let id = UUID()
        let handler = self.handler
        let host = self.host
        let task = Task {
            let reply = await handler(request, host)
            answer.reply.withLock { $0 = reply }
            var byte: UInt8 = 0
            _ = write(finished, &byte, 1)
        }
        let running = state.withLock { state in
            guard !state.stopped else { return false }
            state.calls[id] = task
            return true
        }
        if !running { task.cancel() }
        let hungUp = !running || Self.waitForAnswer(done, whileConnected: connection)
        if hungUp { task.cancel() }
        // The task holds the pipe until it has written to it, and a cancelled one still finishes.
        Self.wait(for: done)
        state.withLock { _ = $0.calls.removeValue(forKey: id) }
        return hungUp ? nil : answer.reply.withLock { $0 }
    }

    /// Waits until `done` is readable, returning true if `connection` hung up first.
    private static func waitForAnswer(_ done: Int32, whileConnected connection: Int32) -> Bool {
        var watched = [
            pollfd(fd: done, events: Int16(POLLIN), revents: 0),
            pollfd(fd: connection, events: Int16(POLLIN), revents: 0),
        ]
        var discard = [UInt8](repeating: 0, count: 4096)
        while true {
            let ready = poll(&watched, 2, -1)
            if ready < 0 {
                guard errno == EINTR || errno == EAGAIN else { return true }
                continue
            }
            if watched[0].revents != 0 { return false }
            let events = Int32(watched[1].revents)
            if events & (POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
            guard events & POLLIN != 0 else { continue }
            // The relay sends nothing after its request, so what is readable now is its end of the connection.
            let count = recv(connection, &discard, discard.count, MSG_DONTWAIT)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { return true }
        }
    }

    private static func wait(for done: Int32) {
        var watched = pollfd(fd: done, events: Int16(POLLIN), revents: 0)
        while poll(&watched, 1, -1) < 0 && (errno == EINTR || errno == EAGAIN) {}
    }

    private enum Received {
        case request(RelayRequest)
        case invalid(String)
        case gone
    }

    private static func readRequest(_ connection: Int32) -> Received {
        let stream = SocketStream(fd: connection, deadline: .now + transferWait)
        var received = Data()
        while true {
            guard let chunk = try? stream.read(), !chunk.isEmpty else { return .gone }
            if let newline = chunk.firstIndex(of: 0x0A) {
                received.append(chunk[chunk.startIndex..<newline])
                break
            }
            received.append(chunk)
            if received.count > maximumRequest { return .invalid("The request is too long.") }
        }
        guard let request = try? JSONDecoder().decode(RelayRequest.self, from: received) else {
            return .invalid("Canopy could not read the request.")
        }
        return .request(request)
    }
}

private final class Answer: Sendable {
    let reply = Mutex<RelayReply?>(nil)
}
