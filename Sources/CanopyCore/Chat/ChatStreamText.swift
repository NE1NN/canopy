import Foundation

/// The text Claude is writing, parsed a block at a time: blocks before the last blank line outside a code fence are
/// settled and parsed once, and each redraw parses only what follows.
public struct ChatStreamText: Equatable, Sendable {
    public private(set) var text = ""
    /// Settled blocks, then the growing one's.
    public private(set) var blocks: [ChatBlock] = []
    /// How many of `blocks` will not change.
    public private(set) var settledCount = 0
    private var settledLength = 0
    private var settledBlocks: [ChatBlock] = []

    public init() {}

    /// The size of the block still growing, which each redraw lays out again.
    public var growingLength: Int { text.utf8.count - settledLength }

    public mutating func append(_ delta: String) {
        text += delta
        let utf8 = Array(text.utf8)
        // What came before the last settled block cannot change, and no fence is open there.
        if let boundary = Self.lastBoundary(in: utf8, from: settledLength), boundary > settledLength {
            let chunk = String(decoding: utf8[settledLength..<boundary], as: UTF8.self)
            settledBlocks += ChatMarkdown.parse(chunk)
            settledLength = boundary
        }
        settledCount = settledBlocks.count
        let tail = Self.withoutUnderline(Array(utf8[settledLength...]))
        blocks = settledBlocks + ChatMarkdown.parse(String(decoding: tail, as: UTF8.self))
    }

    /// The growing text without a last line of only `-` or `=` under a line of text. Markdown reads that as the
    /// underline of a heading, so the start of a list item or rule would show the line above as a heading until the
    /// next word came.
    static func withoutUnderline(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        guard let newline = bytes.lastIndex(of: 0x0A) else { return bytes[...] }
        let last = bytes[(newline + 1)...].filter { $0 != 0x20 }
        guard let mark = last.first, mark == 0x2D || mark == 0x3D, last.allSatisfy({ $0 == mark }) else {
            return bytes[...]
        }
        let above = bytes[..<newline]
        let lineAbove = above[((above.lastIndex(of: 0x0A) ?? -1) + 1)...]
        guard lineAbove.contains(where: { $0 != 0x20 && $0 != 0x09 }), !isInFence(above) else { return bytes[...] }
        return bytes[...newline]
    }

    /// Whether a code fence is open at the end of `bytes`.
    private static func isInFence(_ bytes: ArraySlice<UInt8>) -> Bool {
        var fence: (character: UInt8, length: Int)?
        for line in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == 0x20 }
            guard let character = trimmed.first, character == 0x60 || character == 0x7E else { continue }
            let length = trimmed.prefix { $0 == character }.count
            if let open = fence {
                if character == open.character, length >= open.length,
                    trimmed.dropFirst(length).allSatisfy({ $0 == 0x20 })
                {
                    fence = nil
                }
            } else if length >= 3 {
                fence = (character, length)
            }
        }
        return fence != nil
    }

    /// Just past the last blank line that is not inside a code fence, looking from `start`, which is outside one.
    static func lastBoundary(in bytes: [UInt8], from start: Int = 0) -> Int? {
        // The open fence's character and length: a fence closes only with the same character, at least as long, and
        // nothing after it but spaces.
        var fence: (character: UInt8, length: Int)?
        var boundary: Int?
        var lineStart = start
        // A settled block ends with a blank line.
        var previousBlank = start > 0
        for index in start...bytes.count {
            guard index == bytes.count || bytes[index] == 0x0A else { continue }
            let line = bytes[lineStart..<index]
            let trimmed = Array(line.drop { $0 == 0x20 })
            if let character = trimmed.first, character == 0x60 || character == 0x7E {
                let length = trimmed.prefix { $0 == character }.count
                let rest = trimmed.dropFirst(length)
                if let open = fence {
                    if character == open.character, length >= open.length, rest.allSatisfy({ $0 == 0x20 }) {
                        fence = nil
                    }
                } else if length >= 3 {
                    fence = (character, length)
                }
            }
            let blank = line.allSatisfy { $0 == 0x20 || $0 == 0x09 }
            if blank, fence == nil, !previousBlank, index < bytes.count, lineStart > 0 { boundary = index + 1 }
            previousBlank = blank
            lineStart = index + 1
        }
        return boundary
    }
}
