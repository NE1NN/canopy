import Foundation
import Testing

@testable import CanopyCore

struct SocketStreamTests {
    /// Both ends of a connected socket pair, closed when the test ends.
    final class Pair: Sendable {
        let near: Int32
        let far: Int32

        init() throws {
            var ends: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
            near = ends[0]
            far = ends[1]
        }

        deinit {
            close(near)
            close(far)
        }
    }

    @Test func stopsWaitingAtTheDeadline() async throws {
        let pair = try Pair()
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: ControlClientError.timedOut) {
            try await offPool { try SocketStream(fd: pair.near, deadline: .now + .milliseconds(300)).read() }
        }

        #expect(clock.now - start >= .milliseconds(300))
        #expect(clock.now - start < .seconds(10))
    }

    /// The CLI waits without a deadline for requests that take as long as they take, such as `canopy row new`.
    @Test func waitsWithoutADeadlineUntilDataArrives() async throws {
        let pair = try Pair()
        let stream = SocketStream(fd: pair.near, deadline: nil)

        async let received = offPool { try stream.read() }
        try await Task.sleep(for: .milliseconds(300))
        _ = "late".withCString { write(pair.far, $0, 4) }

        #expect(String(decoding: try await received, as: UTF8.self) == "late")
    }

    @Test func readsNothingOnceTheOtherSideCloses() async throws {
        let pair = try Pair()
        _ = "last".withCString { write(pair.far, $0, 4) }
        shutdown(pair.far, SHUT_WR)
        let stream = SocketStream(fd: pair.near, deadline: .now + .seconds(20))

        let (first, second) = try await offPool { (try stream.read(), try stream.read()) }

        #expect(String(decoding: first, as: UTF8.self) == "last")
        #expect(second.isEmpty)
    }

    /// As in the suite: the socket is drained while a read is already waiting for the reply.
    @Test func readsAReplyAfterADrainMidWait() async throws {
        let pair = try Pair()
        let stream = SocketStream(fd: pair.near, deadline: .now + .seconds(60))

        async let received = offPool { try stream.read() }
        try await Task.sleep(for: .milliseconds(100))
        let drained = try await offPool { drainSocket(pair.near) }
        if drained {
            _ = "reply".withCString { write(pair.far, $0, 5) }
        } else {
            // Ends the read now rather than at its deadline.
            shutdown(pair.far, SHUT_WR)
        }

        try #require(drained)

        #expect(String(decoding: try await received, as: UTF8.self) == "reply")
    }

    /// A write that fills the socket's buffer has to wait for the other side, and a write that sleeps on a drained
    /// socket fails with EBADF.
    @Test func writesMoreThanTheBufferHoldsOnADrainedSocket() async throws {
        let pair = try Pair()
        try #require(try await offPool { drainSocket(pair.near) })
        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let far = SocketStream(fd: pair.far, deadline: .now + .seconds(60))

        async let received = offPool { () throws -> Data in
            var received = Data()
            while received.count < payload.count {
                let chunk = try far.read()
                if chunk.isEmpty { break }
                received.append(chunk)
            }
            return received
        }
        let wrote = try await offPool {
            Result { try SocketStream(fd: pair.near, deadline: .now + .seconds(60)).write(payload) }
        }
        shutdown(pair.near, SHUT_WR)

        try wrote.get()
        #expect(try await received == payload)
    }
}
