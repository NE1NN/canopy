import Foundation

/// Reads a Claude Code transcript a page at a time from its end, so the first page of a long session costs one read of
/// its last few hundred kilobytes.
public enum TranscriptReader {
    public enum Failure: Error, Equatable {
        case missing
    }

    public struct Page: Sendable, Equatable {
        /// Oldest first.
        public var entries: [TranscriptEntry]
        /// Where the next older page ends, or nil at the start of the file.
        public var older: Int?
        /// How much of the file this page read, for tests.
        public var bytesRead: Int
    }

    static let firstRead = 64 * 1024
    /// After the page's last line, how far to look for the results of its last calls.
    static let resultsWindow = 256 * 1024

    /// The `limit` newest entries ending at byte `before`, or at the last complete line.
    public static func page(of url: URL, before: Int?, limit: Int) throws -> Page {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.missing }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var end = min(before ?? size, size)
        var bytesRead = 0
        if before == nil {
            // A line still being written is not part of the transcript yet.
            let tail = try read(handle, from: max(0, end - firstRead), to: end)
            bytesRead += tail.count
            guard let lastNewline = tail.lastIndex(of: 0x0A) else {
                return end > firstRead
                    ? try page(of: url, before: end - tail.count, limit: limit)
                    : Page(entries: [], older: nil, bytesRead: bytesRead)
            }
            end = end - tail.count + (lastNewline - tail.startIndex) + 1
        }
        let following = try read(handle, from: end, to: min(size, end + resultsWindow))
        bytesRead += following.count
        let followingLines = completeLines(following, dropFirst: false).map(\.line)

        var span = firstRead
        while true {
            let start = max(0, end - span)
            let chunk = try read(handle, from: start, to: end)
            bytesRead += chunk.count
            let lines = completeLines(chunk, dropFirst: start > 0)
            let located = TranscriptParser.located(from: lines.map(\.line), following: followingLines)
            if located.count > limit || start == 0 {
                let kept = located.suffix(limit)
                guard let first = kept.first else {
                    return Page(entries: [], older: nil, bytesRead: bytesRead)
                }
                let older = start + lines[first.line].offset
                return Page(entries: kept.map(\.entry), older: older > 0 ? older : nil, bytesRead: bytesRead)
            }
            span *= 2
        }
    }

    private static func read(_ handle: FileHandle, from start: Int, to end: Int) throws -> Data {
        guard end > start else { return Data() }
        try handle.seek(toOffset: UInt64(start))
        return try handle.read(upToCount: end - start) ?? Data()
    }

    /// The lines of `chunk` with their offsets in it, leaving out a first line that may have started before it.
    private static func completeLines(_ chunk: Data, dropFirst: Bool) -> [(line: Data, offset: Int)] {
        var lines: [(Data, Int)] = []
        var lineStart = chunk.startIndex
        var skipping = dropFirst
        for index in chunk.indices where chunk[index] == 0x0A {
            if !skipping, index > lineStart {
                lines.append((Data(chunk[lineStart..<index]), lineStart - chunk.startIndex))
            }
            skipping = false
            lineStart = chunk.index(after: index)
        }
        if !skipping, lineStart < chunk.endIndex {
            lines.append((Data(chunk[lineStart..<chunk.endIndex]), lineStart - chunk.startIndex))
        }
        return lines
    }
}
