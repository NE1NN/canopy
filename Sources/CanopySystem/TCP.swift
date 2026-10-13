import CSystemShims
import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public enum TCPError: Error, Equatable, CustomStringConvertible {
    case invalidAddress(String)
    case system(String, errno: Int32)
    case closed

    public var description: String {
        switch self {
        case .invalidAddress(let address): "\(address) is not a numeric IPv4 or IPv6 address."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .closed: "The connection is closed."
        }
    }
}

public struct TCPOptions: Sendable {
    /// How long a connection may be idle before the first probe, then how far apart probes go, and how many go
    /// unanswered before the connection counts as gone. All in seconds but the count.
    public struct Keepalive: Sendable, Equatable {
        public var idle: Int32
        public var interval: Int32
        public var count: Int32

        public init(idle: Int32, interval: Int32, count: Int32) {
            self.idle = idle
            self.interval = interval
            self.count = count
        }
    }

    public var keepalive: Keepalive?

    public init(keepalive: Keepalive? = nil) {
        self.keepalive = keepalive
    }

    // Darwin calls the idle time TCP_KEEPALIVE. Swift's Glibc and Musl imports leave out netinet/tcp.h's numbers.
    #if canImport(Darwin)
        static let keepaliveIdleOption = TCP_KEEPALIVE
        static let keepaliveIntervalOption = TCP_KEEPINTVL
        static let keepaliveCountOption = TCP_KEEPCNT
    #else
        static let keepaliveIdleOption: Int32 = 4
        static let keepaliveIntervalOption: Int32 = 5
        static let keepaliveCountOption: Int32 = 6
    #endif
}

/// Listens on one numeric address and port, and hands each connection it accepts to `accept`, on a queue of its own.
public final class TCPListener: Sendable {
    public let address: String
    public let port: UInt16
    private let source: SendableSource
    private let queue: DispatchQueue
    /// Signalled once the socket is closed, so a listener closed outside its queue lets go of the port before `close`
    /// returns.
    private let socketClosed = DispatchSemaphore(value: 0)
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// `port` 0 takes any free port. The address may be taken again at once after an earlier listener on it closed.
    public init(
        address: String, port: UInt16, options: TCPOptions = TCPOptions(),
        accept: @escaping @Sendable (TCPConnection) -> Void
    ) throws {
        guard let endpoint = SocketAddress(address, port: port) else { throw TCPError.invalidAddress(address) }
        let fd = socket(endpoint.family, streamSocket | closeOnExecSocket, 0)
        guard fd >= 0 else { throw TCPError.system("socket", errno: errno) }
        do {
            try setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            if endpoint.family == AF_INET6 { try setOption(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, 1) }
            let bound = endpoint.withSockaddr { Foundation.bind(fd, $0, $1) }
            guard bound == 0 else { throw TCPError.system("bind", errno: errno) }
            guard listen(fd, 64) == 0 else { throw TCPError.system("listen", errno: errno) }
            self.port = try SocketAddress.local(of: fd).port
            makeNonBlocking(fd)
        } catch {
            _ = Foundation.close(fd)
            throw error
        }
        self.address = address
        let queue = DispatchQueue(label: "canopy.tcp-listener")
        queue.setSpecific(key: Self.queueKey, value: true)
        self.queue = queue
        let socketClosed = socketClosed
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = canopy_accept_closing_on_exec(fd)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                accept(TCPConnection(fd: client, options: options))
            }
        }
        source.setCancelHandler {
            _ = Foundation.close(fd)
            socketClosed.signal()
        }
        source.resume()
        self.source = SendableSource(source)
    }

    /// Stops listening, and once called from outside the listener's own handler, returns with the port free.
    /// Connections it accepted stay open. Safe to call more than once.
    public func close() {
        guard !source.isCancelled else { return }
        source.cancel()
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            socketClosed.wait()
            // Lets another close that passed the check at the same moment return too.
            socketClosed.signal()
        }
    }
}

/// A connected TCP socket: chunks arrive through `receive`, and sends leave in order. Its state is touched only on its
/// own serial queue, and a send waits for room without holding a thread, so a peer that stops reading holds up only
/// its own sends.
public final class TCPConnection: @unchecked Sendable {
    public let localAddress: String
    let fd: Int32
    private let queue = DispatchQueue(label: "canopy.tcp-connection")
    private var closed = false
    private var reading: DispatchSourceRead?
    /// The receive handler while reading, told once if a failed send closes the connection.
    private var reader: (@Sendable (Data?, (any Error)?) -> Void)?
    private var writing: DispatchSourceWrite?
    private var writingSuspended = true
    /// Sources not yet cancelled. The socket closes once none is left.
    private var openSources = 0
    private var pending: [Pending] = []

    private struct Pending {
        var data: Data
        var sent = 0
        var continuation: CheckedContinuation<Void, any Error>
    }

    init(fd: Int32, options: TCPOptions) {
        self.fd = fd
        makeNonBlocking(fd)
        #if canImport(Darwin)
            try? setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        if let keepalive = options.keepalive {
            try? setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
            try? setOption(fd, Int32(IPPROTO_TCP), TCPOptions.keepaliveIdleOption, keepalive.idle)
            try? setOption(fd, Int32(IPPROTO_TCP), TCPOptions.keepaliveIntervalOption, keepalive.interval)
            try? setOption(fd, Int32(IPPROTO_TCP), TCPOptions.keepaliveCountOption, keepalive.count)
        }
        localAddress = (try? SocketAddress.local(of: fd).host) ?? ""
    }

    /// Connects to a numeric address, blocking until it does or fails.
    public static func connect(
        to address: String, port: UInt16, options: TCPOptions = TCPOptions()
    ) throws -> TCPConnection {
        guard let endpoint = SocketAddress(address, port: port) else { throw TCPError.invalidAddress(address) }
        let fd = socket(endpoint.family, streamSocket | closeOnExecSocket, 0)
        guard fd >= 0 else { throw TCPError.system("socket", errno: errno) }
        var result: Int32
        repeat {
            result = endpoint.withSockaddr { Foundation.connect(fd, $0, $1) }
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            _ = Foundation.close(fd)
            throw TCPError.system("connect", errno: code)
        }
        return TCPConnection(fd: fd, options: options)
    }

    /// Calls `handler` with each chunk that arrives, then once with nil when the other side closes, or with an error,
    /// after which it calls it no more. Nothing is called once `close` has run.
    public func receive(_ handler: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        queue.async { [self] in
            guard !closed, reading == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while !closed {
                    let count = Foundation.read(fd, &buffer, buffer.count)
                    if count > 0 {
                        handler(Data(buffer[0..<count]), nil)
                    } else if count == 0 {
                        stopReading()
                        handler(nil, nil)
                        return
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        return
                    } else {
                        let code = errno
                        stopReading()
                        handler(nil, TCPError.system("read", errno: code))
                        return
                    }
                }
            }
            adopt(source)
            reading = source
            reader = handler
            source.resume()
        }
    }

    /// Returns once all of `data` has gone to the kernel, or throws `closed` if the connection closes first.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: TCPError.closed) }
                pending.append(Pending(data: data, continuation: continuation))
                if pending.count == 1 { flush() }
            }
        }
    }

    /// Closes the socket. Sends still waiting throw `closed`. Safe to call more than once, from any thread.
    public func close() {
        queue.async { [self] in closeNow() }
    }

    func socketOption(_ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, level, name, &value, &size)
        return value
    }

    private func flush() {
        while var first = pending.first {
            let written = first.data.withUnsafeBytes { bytes in
                sendBytes(fd, bytes.baseAddress! + first.sent, bytes.count - first.sent)
            }
            if written >= 0 {
                first.sent += written
                if first.sent < first.data.count {
                    pending[0] = first
                    continue
                }
                pending.removeFirst()
                first.continuation.resume()
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                waitForRoom()
                return
            }
            // The peer reset or vanished. Network.framework said so through the connection's state; here the reader
            // hears it, so whoever holds the connection lets go of it.
            closeNow(failure: TCPError.system("send", errno: errno))
            return
        }
        if let writing, !writingSuspended {
            writing.suspend()
            writingSuspended = true
        }
    }

    private func waitForRoom() {
        if writing == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in flush() }
            adopt(source)
            writing = source
        }
        if writingSuspended {
            writing?.resume()
            writingSuspended = false
        }
    }

    /// The socket closes once every source made for it is cancelled, so none watches a descriptor reused meanwhile.
    private func adopt(_ source: any DispatchSourceProtocol) {
        openSources += 1
        source.setCancelHandler { [self] in
            openSources -= 1
            if openSources == 0, closed { _ = Foundation.close(fd) }
        }
    }

    private func stopReading() {
        reading?.cancel()
        reading = nil
        reader = nil
    }

    private func closeNow(failure: (any Error)? = nil) {
        guard !closed else { return }
        closed = true
        if let failure, let reader {
            self.reader = nil
            reader(nil, failure)
        }
        _ = shutdown(fd, Int32(SHUT_RDWR))
        stopReading()
        if let writing {
            // A suspended source never runs its cancel handler.
            if writingSuspended { writing.resume() }
            writing.cancel()
            self.writing = nil
        }
        if openSources == 0 { _ = Foundation.close(fd) }
        let waiting = pending
        pending = []
        for send in waiting { send.continuation.resume(throwing: TCPError.closed) }
    }
}

/// A dispatch source a `Sendable` type keeps and only ever cancels, which is safe from any thread.
private struct SendableSource: @unchecked Sendable {
    let source: any DispatchSourceProtocol

    init(_ source: any DispatchSourceProtocol) {
        self.source = source
    }

    var isCancelled: Bool { source.isCancelled }

    func cancel() {
        source.cancel()
    }
}

#if canImport(Glibc)
    private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
    private let streamSocket = SOCK_STREAM
#endif

// Linux marks a descriptor close-on-exec as it is made, so a child spawned on another thread at that moment never
// inherits it. Darwin's spawns close every descriptor anyway, with POSIX_SPAWN_CLOEXEC_DEFAULT.
#if canImport(Glibc)
    private let closeOnExecSocket = Int32(SOCK_CLOEXEC.rawValue)
#elseif canImport(Musl)
    private let closeOnExecSocket = SOCK_CLOEXEC
#else
    private let closeOnExecSocket: Int32 = 0
#endif

private func sendBytes(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Foundation.send(fd, bytes, count, 0)
    #else
        Foundation.send(fd, bytes, count, Int32(MSG_NOSIGNAL))
    #endif
}

private func makeNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
}

private func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) throws {
    var value = value
    guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw TCPError.system("setsockopt", errno: errno)
    }
}

/// A numeric IPv4 or IPv6 address and a port.
struct SocketAddress {
    private var storage = sockaddr_storage()
    let family: Int32

    init?(_ address: String, port: UInt16) {
        // Darwin's inet_pton takes a scope such as fe80::1%en0, which the listener's rules about addresses never mean.
        guard !address.contains("%") else { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            family = AF_INET
            var socket = sockaddr_in()
            #if canImport(Darwin)
                socket.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            socket.sin_family = sa_family_t(AF_INET)
            socket.sin_port = port.bigEndian
            socket.sin_addr = v4
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: socket, as: sockaddr_in.self) }
        } else if inet_pton(AF_INET6, address, &v6) == 1 {
            family = AF_INET6
            var socket = sockaddr_in6()
            #if canImport(Darwin)
                socket.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            socket.sin6_family = sa_family_t(AF_INET6)
            socket.sin6_port = port.bigEndian
            socket.sin6_addr = v6
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: socket, as: sockaddr_in6.self) }
        } else {
            return nil
        }
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let size = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
        return withUnsafeBytes(of: storage) { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(size))
        }
    }

    /// The numeric address and port a socket is bound to.
    static func local(of fd: Int32) throws -> (host: String, port: UInt16) {
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutableBytes(of: &storage) { raw in
            getsockname(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), &size)
        }
        guard result == 0 else { throw TCPError.system("getsockname", errno: errno) }
        return withUnsafeBytes(of: storage) { raw in
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if Int32(storage.ss_family) == AF_INET6 {
                var socket = raw.load(as: sockaddr_in6.self)
                inet_ntop(AF_INET6, &socket.sin6_addr, &text, socklen_t(text.count))
                return (numeric(text), UInt16(bigEndian: socket.sin6_port))
            }
            var socket = raw.load(as: sockaddr_in.self)
            inet_ntop(AF_INET, &socket.sin_addr, &text, socklen_t(text.count))
            return (numeric(text), UInt16(bigEndian: socket.sin_port))
        }
    }
}

private func numeric(_ text: [CChar]) -> String {
    String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
