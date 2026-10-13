import CanopyTestSupport
import Foundation
import Synchronization

@testable import CanopyCore

/// A phone, as far as the listener can tell: newline-delimited JSON over TCP. Its calls block, so tests make them
/// through `offPool`.
final class PhoneTestClient: Sendable {
    private let fd: Int32
    private let buffer = Mutex(Data())

    init(host: String = "127.0.0.1", port: UInt16) throws {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
            ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else {
            throw ControlClientError.connectFailed(errno: errno)
        }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.connectFailed(errno: errno) }
        guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            let code = errno
            close(fd)
            throw ControlClientError.connectFailed(errno: code)
        }
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    func send(_ method: String, _ params: JSONValue? = nil, id: String = UUID().uuidString) throws {
        try sendRaw(ControlCodec.encodeLine(ControlRequest(method: method, params: params, id: id)))
    }

    func sendRaw(_ data: Data) throws {
        try SocketStream(fd: fd, deadline: .now + .seconds(20)).write(data)
    }

    /// Sends a request and waits for its answer, skipping events.
    func call(_ method: String, _ params: JSONValue? = nil) throws -> ControlResponse {
        let id = UUID().uuidString
        try send(method, params, id: id)
        while let message = try next() {
            if case .response(let response) = message, response.id == id { return response }
        }
        throw ControlClientError.connectionClosed
    }

    /// The next line from the Mac, or nil once it has closed the connection.
    func next(timeout: Duration = .seconds(20)) throws -> PhoneMessage? {
        let stream = SocketStream(fd: fd, deadline: .now + timeout)
        while true {
            let line = buffer.withLock { buffer -> Data? in
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            if let line { return try PhoneMessage(line: line) }
            let chunk: Data
            do {
                chunk = try stream.read()
            } catch ControlClientError.connectionClosed {
                return nil
            }
            guard !chunk.isEmpty else { return nil }
            buffer.withLock { $0.append(chunk) }
        }
    }

    /// Whether nothing arrives for `duration`, with the connection still open.
    func isQuiet(for duration: Duration) throws -> Bool {
        do {
            _ = try next(timeout: duration)
            return false
        } catch ControlClientError.timedOut {
            return true
        }
    }

    /// Reads until the Mac closes the connection, returning what came before.
    func untilClosed(timeout: Duration = .seconds(20)) throws -> [PhoneMessage] {
        var messages: [PhoneMessage] = []
        while let message = try next(timeout: timeout) { messages.append(message) }
        return messages
    }
}

extension PhoneMessage {
    var response: ControlResponse? {
        if case .response(let response) = self { response } else { nil }
    }

    var event: PhoneEvent? {
        if case .event(let event) = self { event } else { nil }
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
