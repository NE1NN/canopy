import Foundation

/// Splits a byte stream into newline-delimited lines.
struct LineBuffer {
    /// A line longer than this is not a request anyone meant to send.
    static let maximumLine = 1 << 20

    private var pending = Data()

    /// The complete lines in what has arrived so far, or nil once the unfinished line is longer than `maximumLine`.
    mutating func append(_ data: Data) -> [Data]? {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<newline]))
            pending = Data(pending[pending.index(after: newline)...])
        }
        guard pending.count <= Self.maximumLine else {
            pending = Data()
            return nil
        }
        return lines
    }
}
