import Foundation
import Testing

@testable import CanopyTickets

struct TokenInputTests {
    func pipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        _ = Darwin.pipe(&fds)
        return (fds[0], fds[1])
    }

    func send(_ text: String, to fd: Int32) {
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    func rest(of fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &buffer, buffer.count)
        return String(decoding: buffer[..<max(0, count)], as: UTF8.self)
    }

    @Test func aLineIsEnoughAndWhatFollowsItStaysUnread() throws {
        let (reading, writing) = pipe()
        defer { close(reading); close(writing) }
        send("tok-1\nmore", to: writing)
        #expect(try TokenInput.read(from: reading, timeout: .seconds(5)) == "tok-1")
        #expect(rest(of: reading) == "more")
    }

    @Test func aFileIsReadOnlyUpToItsFirstNewline() throws {
        let dir = try TempDir()
        let path = dir.sub("token")
        try "tok-3\nnext-line\n".write(toFile: path, atomically: true, encoding: .utf8)
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        #expect(try TokenInput.read(from: fd, timeout: .seconds(5)) == "tok-3")
        #expect(lseek(fd, 0, SEEK_CUR) == 6)
    }

    @Test func theEndOfInputEndsTheToken() throws {
        let (reading, writing) = pipe()
        defer { close(reading) }
        send(" tok-2 ", to: writing)
        close(writing)
        #expect(try TokenInput.read(from: reading, timeout: .seconds(5)) == "tok-2")
    }

    @Test func aPipeThatNeverSendsGivesUp() throws {
        let (reading, writing) = pipe()
        defer { close(reading); close(writing) }
        let start = ContinuousClock.now
        #expect(throws: TokenInput.Failure.timedOut) { try TokenInput.read(from: reading, timeout: .milliseconds(200)) }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func partOfALineIsNeverTakenForTheToken() throws {
        let (reading, writing) = pipe()
        defer { close(reading); close(writing) }
        send("tok-", to: writing)
        #expect(throws: TokenInput.Failure.timedOut) { try TokenInput.read(from: reading, timeout: .milliseconds(200)) }
    }

    @Test func aClosedDescriptorFailsAtOnce() throws {
        let (reading, writing) = pipe()
        close(reading)
        close(writing)
        let start = ContinuousClock.now
        #expect {
            try TokenInput.read(from: reading, timeout: .seconds(5))
        } throws: {
            if case .failed = $0 as? TokenInput.Failure { true } else { false }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aLineLongerThanATokenFails() throws {
        let dir = try TempDir()
        let path = dir.sub("huge")
        try String(repeating: "a", count: 70_000).write(toFile: path, atomically: true, encoding: .utf8)
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        #expect(throws: TokenInput.Failure.tooLong) { try TokenInput.read(from: fd, timeout: .seconds(5)) }
    }
}
