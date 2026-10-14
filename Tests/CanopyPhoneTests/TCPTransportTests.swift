import Foundation
import Network
import Synchronization
import Testing

@testable import CanopyPhone

struct TCPTransportTests {
    @Test func linesArriveWholeHoweverTheReadsSplitThem() async throws {
        let mac = try await LoopbackMac.start()
        defer { mac.stop() }
        let channel = try await TCPTransport().connect(host: "127.0.0.1", port: mac.port)
        defer { channel.close() }
        let peer = try await mac.accepted()
        for chunk in ["ab", "c\nde", "f\n\ng\n"] {
            try await peer.send(Data(chunk.utf8))
        }
        var lines: [String] = []
        for try await line in channel.lines {
            lines.append(String(decoding: line, as: UTF8.self))
            if lines.count == 3 { break }
        }
        #expect(lines == ["abc", "def", "g"])
    }

    @Test func whatThePhoneSendsArrives() async throws {
        let mac = try await LoopbackMac.start()
        defer { mac.stop() }
        let channel = try await TCPTransport().connect(host: "127.0.0.1", port: mac.port)
        defer { channel.close() }
        let peer = try await mac.accepted()
        try await channel.send(Data("hello\n".utf8))
        #expect(try await peer.receive(until: "\n") == "hello\n")
    }

    @Test func theMacClosingEndsTheLines() async throws {
        let mac = try await LoopbackMac.start()
        defer { mac.stop() }
        let channel = try await TCPTransport().connect(host: "127.0.0.1", port: mac.port)
        let peer = try await mac.accepted()
        try await peer.send(Data("last\n".utf8))
        peer.close()
        var lines: [String] = []
        for try await line in channel.lines {
            lines.append(String(decoding: line, as: UTF8.self))
        }
        #expect(lines == ["last"])
        await #expect(throws: PhoneTransportError.closed) { try await channel.send(Data("late\n".utf8)) }
    }

    @Test func aPortNothingListensOnIsRefused() async throws {
        let port = try closedPort()
        await #expect(throws: PhoneTransportError.refused) {
            try await TCPTransport().connect(host: "127.0.0.1", port: port)
        }
    }

    @Test func aConnectNobodyWaitsForAnyMoreIsGivenUp() async throws {
        let mac = try await LoopbackMac.start()
        defer { mac.stop() }
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TCPTransport().connect(host: "127.0.0.1", port: mac.port)
        }
        await #expect(throws: CancellationError.self) { try await attempt.value }
    }

    @Test func aNameThatDoesNotResolveIsUnreachable() async throws {
        await #expect {
            try await TCPTransport(timeout: .seconds(10)).connect(host: "nothing.invalid", port: 6974)
        } throws: { error in
            if case .unreachable = error as? PhoneTransportError { return true }
            return false
        }
    }
}

/// A loopback port nothing listens on: bound, then closed at once.
func closedPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            bind(descriptor, address, length) == 0 && getsockname(descriptor, address, &length) == 0
        }
    }
    guard bound else { throw PhoneTransportError.closed }
    return UInt16(bigEndian: address.sin_port)
}

/// A TCP server on 127.0.0.1 that plays the Mac's end of one connection.
final class LoopbackMac: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let connections: AsyncStream<NWConnection>
    private let queue: DispatchQueue

    private init(listener: NWListener, port: UInt16, connections: AsyncStream<NWConnection>, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.connections = connections
        self.queue = queue
    }

    static func start() async throws -> LoopbackMac {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "loopback-mac")
        let (connections, accepted) = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            accepted.yield(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let resume: Result<UInt16, any Error>? =
                    switch state {
                    case .ready: .success(listener.port?.rawValue ?? 0)
                    case .failed(let error): .failure(error)
                    default: nil
                    }
                guard let resume,
                    !resumed.withLock({ was in
                        defer { was = true }; return was
                    })
                else { return }
                continuation.resume(with: resume)
            }
            listener.start(queue: queue)
        }
        return LoopbackMac(listener: listener, port: port, connections: connections, queue: queue)
    }

    func accepted() async throws -> Peer {
        for await connection in connections {
            return Peer(connection: connection)
        }
        throw PhoneTransportError.closed
    }

    func stop() {
        listener.cancel()
    }

    struct Peer: Sendable {
        let connection: NWConnection

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            }
        }

        func receive(until end: String) async throws -> String {
            var text = ""
            while !text.hasSuffix(end) {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: data ?? Data())
                        }
                    }
                }
                guard !data.isEmpty else { break }
                text += String(decoding: data, as: UTF8.self)
            }
            return text
        }

        func close() {
            connection.cancel()
        }
    }
}
