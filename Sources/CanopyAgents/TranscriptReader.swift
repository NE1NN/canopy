import CanopyWire
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
        var bytesRead: Int

        public init(entries: [TranscriptEntry], older: Int?, bytesRead: Int = 0) {
            self.entries = entries
            self.older = older
            self.bytesRead = bytesRead
        }
    }

    static let firstRead = 64 * 1024
    /// After the page's last line, how far to look for the results of its last calls.
    static let resultsWindow = 256 * 1024

    /// The `limit` newest entries ending at byte `before`, or at the last complete line. With `maxSpan`, it reads no
    /// further back than that many bytes, and returns what they hold.
    public static func page(of url: URL, before: Int?, limit: Int, maxSpan: Int? = nil) throws -> Page {
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
                    ? try page(of: url, before: end - tail.count, limit: limit, maxSpan: maxSpan)
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
            if located.count > limit || start == 0 || maxSpan.map({ span >= $0 }) == true {
                var kept = located.suffix(limit)
                guard let first = kept.first else {
                    return Page(entries: [], older: start > 0 ? start : nil, bytesRead: bytesRead)
                }
                // A line can hold several entries, and a page starts at a line, so it takes all of its first line's.
                if let lineStart = located.firstIndex(where: { $0.line == first.line }) {
                    kept = located[lineStart...]
                }
                let older = start + lines[first.line].offset
                return Page(entries: kept.map(\.entry), older: older > 0 ? older : nil, bytesRead: bytesRead)
            }
            span *= 2
        }
    }

    /// Raw lines, for a chat that builds its own items from them.
    public struct LinePage: Sendable, Equatable {
        /// Oldest first.
        public var lines: [Data]
        /// Where the next older page ends, or nil at the start of the file.
        public var older: Int?
    }

    /// At least `minimumLines` complete lines ending at byte `before`, or at the last complete line, or as many as
    /// there are. It reads from the end in chunks from 64 KB, doubling until it has enough.
    public static func linePage(of url: URL, before: Int?, minimumLines: Int) throws -> LinePage {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.missing }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var end = min(before ?? size, size)
        if before == nil {
            // A line still being written is not part of the transcript yet. Find the last newline.
            var probe = firstRead
            while true {
                let tail = try read(handle, from: max(0, end - probe), to: end)
                if let lastNewline = tail.lastIndex(of: 0x0A) {
                    end = end - tail.count + (lastNewline - tail.startIndex) + 1
                    break
                }
                if end - probe <= 0 { return LinePage(lines: [], older: nil) }
                probe *= 2
            }
        }
        var span = firstRead
        while true {
            let start = max(0, end - span)
            let lines = completeLines(try read(handle, from: start, to: end), dropFirst: start > 0)
            if lines.count >= minimumLines || start == 0 {
                guard let first = lines.first else { return LinePage(lines: [], older: start > 0 ? start : nil) }
                let older = start + first.offset
                return LinePage(lines: lines.map(\.line), older: older > 0 ? older : nil)
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
