import CanopyWire
import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public enum PhoneTestClientError: Error, Equatable {
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case closed
    case timedOut
}

/// A phone, as far as a phone listener can tell: newline-delimited JSON over TCP. Its calls block, so tests make them
/// through `offPool`.
public final class PhoneTestClient: Sendable {
    private let fd: Int32
    private let buffer = Mutex(Data())

    public init(host: String = "127.0.0.1", port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamSocket
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else {
            throw PhoneTestClientError.connectFailed(errno: errno)
        }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, streamSocket, 0)
        guard fd >= 0 else { throw PhoneTestClientError.connectFailed(errno: errno) }
        // Before connecting, as macOS refuses it once the server has hung up.
        #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard Foundation.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            let code = errno
            close(fd)
            throw PhoneTestClientError.connectFailed(errno: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    public func send(_ method: String, _ params: JSONValue? = nil, id: String = UUID().uuidString) throws {
        try sendRaw(ControlCodec.encodeLine(ControlRequest(method: method, params: params, id: id)))
    }

    public func sendRaw(_ data: Data) throws {
        let deadline = ContinuousClock.now + .seconds(20)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                    let written = Foundation.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                #else
                    let written = Foundation.send(
                        fd, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if written >= 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EINTR {
                    try wait(for: POLLOUT, until: deadline)
                } else {
                    throw PhoneTestClientError.writeFailed(errno: errno)
                }
            }
        }
    }

    /// Closes the sending side, as a phone does that has said all it will.
    public func finishSending() {
        _ = shutdown(fd, Int32(SHUT_WR))
    }

    /// Sends a request and waits for its answer, skipping events.
    public func call(_ method: String, _ params: JSONValue? = nil) throws -> ControlResponse {
        let id = UUID().uuidString
        try send(method, params, id: id)
        while let message = try next() {
            if case .response(let response) = message, response.id == id { return response }
        }
        throw PhoneTestClientError.closed
    }

    /// The next line from the server, or nil once it has closed the connection.
    public func next(timeout: Duration = .seconds(20)) throws -> PhoneMessage? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let line = buffer.withLock { buffer -> Data? in
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            if let line { return try PhoneMessage(line: line) }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.withLock { $0.append(contentsOf: chunk[0..<count]) }
            } else if count == 0 {
                return nil
            } else if errno == EAGAIN || errno == EINTR {
                try wait(for: POLLIN, until: deadline)
            } else {
                return nil
            }
        }
    }

    /// Whether nothing arrives for `duration`, with the connection still open.
    public func isQuiet(for duration: Duration) throws -> Bool {
        do {
            _ = try next(timeout: duration)
            return false
        } catch PhoneTestClientError.timedOut {
            return true
        }
    }

    /// Reads until the server closes the connection, returning what came before.
    public func untilClosed(timeout: Duration = .seconds(20)) throws -> [PhoneMessage] {
        var messages: [PhoneMessage] = []
        while let message = try next(timeout: timeout) { messages.append(message) }
        return messages
    }

    private func wait(for event: Int32, until deadline: ContinuousClock.Instant) throws {
        let left = deadline - .now
        guard left > .zero else { throw PhoneTestClientError.timedOut }
        var request = pollfd(fd: fd, events: Int16(event), revents: 0)
        let limit = Int32(clamping: Int((left / .milliseconds(1)).rounded(.up)))
        if poll(&request, 1, limit) == 0 { throw PhoneTestClientError.timedOut }
    }
}

extension PhoneMessage {
    public var response: ControlResponse? {
        if case .response(let response) = self { response } else { nil }
    }

    public var event: PhoneEvent? {
        if case .event(let event) = self { event } else { nil }
    }
}

extension Data {
    public init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

#if canImport(Glibc)
    private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
    private let streamSocket = SOCK_STREAM
#endif
