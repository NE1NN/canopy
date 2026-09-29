import Foundation
import Testing

@testable import CanopyTickets

struct TokenInputTests {
    func pipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        _ = Darwin.pipe(&fds)
        return (fds[0], fds[1])
    }

    @Test func aLineIsEnoughEvenWhileThePipeStaysOpen() throws {
        let (reading, writing) = pipe()
        defer { close(reading); close(writing) }
        _ = "tok-1\nmore".withCString { write(writing, $0, 10) }
        #expect(try TokenInput.read(from: reading, timeout: .seconds(5)) == "tok-1")
    }

    @Test func theEndOfInputEndsTheToken() throws {
        let (reading, writing) = pipe()
        defer { close(reading) }
        _ = " tok-2 ".withCString { write(writing, $0, 7) }
        close(writing)
        #expect(try TokenInput.read(from: reading, timeout: .seconds(5)) == "tok-2")
    }

    @Test func aPipeThatNeverSendsGivesUp() throws {
        let (reading, writing) = pipe()
        defer { close(reading); close(writing) }
        let start = ContinuousClock.now
        #expect(throws: TokenInput.TimedOut.self) { try TokenInput.read(from: reading, timeout: .milliseconds(200)) }
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
