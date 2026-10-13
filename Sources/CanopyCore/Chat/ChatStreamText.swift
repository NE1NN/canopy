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

    public mutating func append(_ delta: String) {
        text += delta
        let utf8 = Array(text.utf8)
        if let boundary = Self.lastBoundary(in: utf8), boundary > settledLength {
            let chunk = String(decoding: utf8[settledLength..<boundary], as: UTF8.self)
            settledBlocks += ChatMarkdown.parse(chunk)
            settledLength = boundary
        }
        settledCount = settledBlocks.count
        let tail = String(decoding: utf8[settledLength...], as: UTF8.self)
        blocks = settledBlocks + ChatMarkdown.parse(tail)
    }

    /// Just past the last blank line that is not inside a code fence.
    static func lastBoundary(in bytes: [UInt8]) -> Int? {
        // The open fence's character and length: a fence closes only with the same character, at least as long, and
        // nothing after it but spaces.
        var fence: (character: UInt8, length: Int)?
        var boundary: Int?
        var lineStart = 0
        var previousBlank = false
        for index in 0...bytes.count {
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
