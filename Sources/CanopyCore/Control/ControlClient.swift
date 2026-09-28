import Foundation

public enum ControlClientError: Error, Equatable, CustomStringConvertible {
    case socketPathTooLong(String)
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case connectionClosed
    case timedOut

    public var isAppNotRunning: Bool {
        if case .connectFailed(let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }

    public var description: String {
        switch self {
        case .socketPathTooLong(let path): "Socket path is longer than macOS allows: \(path)"
        case .connectFailed(let code): "Could not connect to Canopy: \(String(cString: strerror(code)))"
        case .writeFailed(let code): "Could not send to Canopy: \(String(cString: strerror(code)))"
        case .connectionClosed: "Canopy closed the connection before replying."
        case .timedOut: "Canopy did not reply in time. The request may still finish; check `canopy row list`."
        }
    }
}

/// A blocking client for one request at a time. The CLI makes a single call per run.
public struct ControlClient: Sendable {
    public var socketPath: String
    /// How long to wait for the reply. Nil waits as long as the app takes.
    public var timeout: TimeInterval?

    public init(socketPath: String, timeout: TimeInterval? = 120) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public static func canConnect(socketPath: String) -> Bool {
        guard let fd = try? connect(to: socketPath) else { return false }
        close(fd)
        return true
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }

        if let timeout {
            var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        }

        try Self.write(try ControlCodec.encodeLine(request), to: fd)

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !received.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { throw ControlClientError.connectionClosed }
            if count < 0 && errno == EINTR { continue }
            if count < 0 {
                throw errno == EAGAIN ? ControlClientError.timedOut : ControlClientError.connectionClosed
            }
            received.append(contentsOf: chunk[0..<count])
        }
        let line = received.prefix { $0 != 0x0A }
        return try ControlCodec.decode(ControlResponse.self, from: Data(line))
    }

    /// Sends a request whose reply does not matter, for hooks that must never hold up what runs them. It waits at
    /// most `timeout` seconds for the reply, because the app can lose a request from a client that closed before
    /// the app read it.
    public func post(_ request: ControlRequest, timeout: TimeInterval = 1) throws {
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        try Self.write(try ControlCodec.encodeLine(request), to: fd)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 || chunk[0..<count].contains(0x0A) { return }
        }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written < 0 { throw ControlClientError.writeFailed(errno: errno) }
                offset += written
            }
        }
    }

    static func connect(to path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlClientError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.connectFailed(errno: errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw ControlClientError.connectFailed(errno: code)
        }
        return fd
    }
}
