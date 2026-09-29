import Darwin
import Foundation

/// A token piped into `canopy ticket connect`: its first line, or everything up to the end of input.
public enum TokenInput {
    public enum Failure: Error, Equatable {
        /// Neither a whole line nor the end of input arrived before the time limit.
        case timedOut
        /// The line is longer than any token.
        case tooLong
        /// Reading failed, in the system's words.
        case failed(String)
    }

    static let longestLine = 64 * 1024

    /// Reads one byte at a time up to the first newline, so whatever follows stays for the next reader. Gives up after
    /// `timeout` without a whole line, so a pipe that never closes does not hang the command.
    public static func read(from fd: Int32, timeout: Duration) throws(Failure) -> String {
        let deadline = ContinuousClock.now + timeout
        var line: [UInt8] = []
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw .timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(
                clamping: max(
                    1, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw failure(errno)
            }
            guard ready > 0 else { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 { throw failure(EBADF) }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw failure(errno)
            }
            if count == 0 || byte == 0x0A { break }
            line.append(byte)
            guard line.count <= longestLine else { throw .tooLong }
        }
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func failure(_ code: Int32) -> Failure {
        .failed(String(cString: strerror(code)))
    }
}
