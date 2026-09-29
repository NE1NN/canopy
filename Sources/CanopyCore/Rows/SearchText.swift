import Foundation

/// Text typed to narrow a list: an item matches when each word appears in one of its fields, ignoring case.
public struct SearchText: Sendable, Equatable {
    public let words: [String]

    public init(_ text: String?) {
        words = (text ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { words.isEmpty }

    public func matches(_ fields: [String]) -> Bool {
        words.allSatisfy { word in fields.contains { $0.range(of: word, options: .caseInsensitive) != nil } }
    }
}
