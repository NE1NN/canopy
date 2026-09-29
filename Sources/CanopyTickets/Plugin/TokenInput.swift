import Darwin
import Foundation

/// A token piped into `canopy ticket connect`: its first line, or everything up to the end of input.
public enum TokenInput {
    /// Nothing arrived before the time limit.
    public struct TimedOut: Error {}

    /// Gives up after `timeout` without a whole line, so a pipe that never closes does not hang the command.
    public static func read(from fd: Int32, timeout: Duration) throws -> String {
        let deadline = ContinuousClock.now + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                if data.isEmpty { throw TimedOut() }
                break
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(
                clamping: max(
                    1, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[..<count])
        }
        let line = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? data[...]
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
