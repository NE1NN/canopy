import CanopyTestSupport
import Foundation
import Synchronization
import Testing

@testable import CanopySystem

struct TCPTests {
    /// Everything a listener's connections received, by connection, and the connections themselves.
    final class Server: Sendable {
        let listener: TCPListener
        let connections = Shared<[TCPConnection]>([])
        let received = Shared<[Int: Data]>([:])
        let closed = Shared<Set<Int>>([])

        /// With `echo`, each connection sends back what it receives.
        init(address: String = "127.0.0.1", port: UInt16 = 0, options: TCPOptions = TCPOptions(), echo: Bool = false)
            throws
        {
            let connections = self.connections
            let received = self.received
            let closed = self.closed
            listener = try TCPListener(address: address, port: port, options: options) { connection in
                let index = connections.withLock { list in
                    list.append(connection)
                    return list.count - 1
                }
                connection.receive { data, _ in
                    guard let data else {
                        closed.withLock { _ = $0.insert(index) }
                        return
                    }
                    received.withLock { $0[index, default: Data()].append(data) }
                    if echo { Task { try? await connection.send(data) } }
                }
            }
        }

        func first() async -> TCPConnection? {
            _ = await eventually { connections.withLock { !$0.isEmpty } }
            return connections.withLock { $0.first }
        }
    }

    /// What a client connection received.
    final class Inbox: Sendable {
        let data = Shared(Data())
        let ended = Shared(false)

        init(_ connection: TCPConnection) {
            let data = self.data
            let ended = self.ended
            connection.receive { chunk, _ in
                if let chunk { data.withLock { $0.append(chunk) } } else { ended.withLock { $0 = true } }
            }
        }

        var text: String { String(decoding: data.withLock { $0 }, as: UTF8.self) }
    }

    @Test func listensOnAnyFreePort() throws {
        let server = try Server()
        defer { server.listener.close() }
        #expect(server.listener.port > 0)
        #expect(server.listener.address == "127.0.0.1")
    }

    @Test func echoesBothWays() async throws {
        let server = try Server(echo: true)
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        defer { client.close() }
        let inbox = Inbox(client)

        try await client.send(Data("hello\n".utf8))
        try await client.send(Data("again\n".utf8))

        #expect(await eventually { inbox.text == "hello\nagain\n" })
        #expect(client.localAddress == "127.0.0.1")
        #expect(await server.first()?.localAddress == "127.0.0.1")
    }

    @Test func reportsTheOtherSidesClose() async throws {
        let server = try Server()
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        try await client.send(Data("last words".utf8))
        client.close()

        #expect(await eventually { server.closed.withLock { $0.contains(0) } })
        #expect(server.received.withLock { $0[0] } == Data("last words".utf8))
    }

    @Test func aSendAfterCloseFails() async throws {
        let server = try Server()
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        client.close()

        await #expect(throws: TCPError.closed) { try await client.send(Data("late".utf8)) }
    }

    /// A listener that closed while a connection was open leaves its port in TIME_WAIT, which must not keep the next
    /// listener off it, as when Tailscale's address comes back.
    @Test func bindsAgainAtOnceAfterClosing() async throws {
        let first = try Server()
        let port = first.listener.port
        let client = try TCPConnection.connect(to: "127.0.0.1", port: port)
        let accepted = try #require(await first.first())
        // Both closes run later on their connections' queues, so wait for them before the listener goes: until then
        // the port still has a live connection on it, which is not what this test is about.
        client.close()
        #expect(await eventually { first.closed.withLock { $0.contains(0) } })
        accepted.close()
        await #expect(throws: TCPError.closed) { try await accepted.send(Data("after close".utf8)) }
        first.listener.close()

        let again = try Server(port: port)
        defer { again.listener.close() }
        #expect(again.listener.port == port)
    }

    @Test(arguments: ["localhost", "", "999.1.1.1", "fe80::1%nowhere"])
    func refusesAnAddressThatIsNotNumeric(_ address: String) {
        #expect(throws: TCPError.invalidAddress(address)) {
            try TCPListener(address: address, port: 0) { _ in }
        }
    }

    @Test func appliesKeepalive() async throws {
        let options = TCPOptions(keepalive: TCPOptions.Keepalive(idle: 30, interval: 10, count: 3))
        let server = try Server(options: options)
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        defer { client.close() }
        let accepted = try #require(await server.first())

        #expect(accepted.socketOption(SOL_SOCKET, SO_KEEPALIVE) != 0)
        #expect(accepted.socketOption(Int32(IPPROTO_TCP), TCPOptions.keepaliveIdleOption) == 30)
        #expect(accepted.socketOption(Int32(IPPROTO_TCP), TCPOptions.keepaliveIntervalOption) == 10)
        #expect(accepted.socketOption(Int32(IPPROTO_TCP), TCPOptions.keepaliveCountOption) == 3)
    }

    /// A phone that stops reading fills its socket's buffers, and the server's sends to it wait. They must wait for
    /// that phone alone.
    @Test func aStalledReaderBlocksNoOtherConnection() async throws {
        let server = try Server(echo: true)
        defer { server.listener.close() }
        let stalled = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        defer { stalled.close() }
        let toStalled = try #require(await server.first())
        let flood = Task { try await toStalled.send(Data(repeating: 0x61, count: 8 << 20)) }

        let other = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        defer { other.close() }
        let inbox = Inbox(other)
        try await other.send(Data("still here\n".utf8))

        #expect(await eventually(timeout: .seconds(2)) { inbox.text == "still here\n" })
        flood.cancel()
        toStalled.close()
        await #expect(throws: TCPError.closed) { try await flood.value }
    }

    @Test func bindsIPv6Loopback() async throws {
        let server = try Server(address: "::1", echo: true)
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "::1", port: server.listener.port)
        defer { client.close() }
        let inbox = Inbox(client)
        try await client.send(Data("six\n".utf8))

        #expect(await eventually { inbox.text == "six\n" })
        #expect(client.localAddress == "::1")
    }
}

extension TCPTests {
    /// A send that fails, as when the peer reset or vanished, closes the connection, and whoever reads it must hear
    /// so, or it would wait on a connection that is gone.
    @Test func aFailedSendTellsTheReader() async throws {
        let server = try Server()
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        defer { client.close() }
        let accepted = try #require(await server.first())
        // Shutting down its own writing side makes the next send fail at once, while reads see nothing.
        _ = shutdown(accepted.fd, Int32(SHUT_WR))

        await #expect(throws: (any Error).self) { try await accepted.send(Data("lost".utf8)) }

        #expect(await eventually { server.closed.withLock { $0.contains(0) } })
    }

    @Test func sendingNothingReturns() async throws {
        let server = try Server()
        defer { server.listener.close() }
        let client = try TCPConnection.connect(to: "127.0.0.1", port: server.listener.port)
        defer { client.close() }

        try await client.send(Data())
    }

    @Test func closingAListenerTwiceAtOnceReturns() async throws {
        let server = try Server()
        let listener = server.listener

        async let first: Void = offPool { listener.close() }
        async let second: Void = offPool { listener.close() }
        _ = try await (first, second)
    }
}
