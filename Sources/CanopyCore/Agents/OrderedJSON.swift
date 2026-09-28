import Foundation

public struct OrderedJSONError: Error, Equatable, CustomStringConvertible {
    public var offset: Int
    public var reason: String

    public var description: String {
        "\(reason) at byte \(offset)"
    }
}

/// JSON that keeps its keys in order and its numbers as written, so a file can be edited and written back as it
/// was apart from the edit.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The number's text as written, such as `1e2`.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    /// An object's value for `key`, the last one when a file repeats it, as JavaScript's `JSON.parse` reads it.
    /// Setting nil removes that key, and setting a new key adds it at the end.
    public subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.last { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.lastIndex(where: { $0.key == key }) {
                if let newValue {
                    members[index].value = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.offset == parser.bytes.count else { throw parser.error("Unexpected text after the JSON") }
        return value
    }

    /// Two-space indentation, as JavaScript's `JSON.stringify(value, null, 2)` writes it, without a final newline.
    public func formatted() -> String {
        var text = ""
        write(to: &text, indent: "")
        return text
    }

    private func write(to text: inout String, indent: String) {
        let inner = indent + "  "
        switch self {
        case .object(let members) where members.isEmpty:
            text += "{}"
        case .object(let members):
            text += "{\n"
            for (index, member) in members.enumerated() {
                text += inner + Self.quoted(member.key) + ": "
                member.value.write(to: &text, indent: inner)
                text += index == members.count - 1 ? "\n" : ",\n"
            }
            text += indent + "}"
        case .array(let items) where items.isEmpty:
            text += "[]"
        case .array(let items):
            text += "[\n"
            for (index, item) in items.enumerated() {
                text += inner
                item.write(to: &text, indent: inner)
                text += index == items.count - 1 ? "\n" : ",\n"
            }
            text += indent + "]"
        case .string(let string):
            text += Self.quoted(string)
        case .number(let number):
            text += number
        case .bool(let bool):
            text += bool ? "true" : "false"
        case .null:
            text += "null"
        }
    }

    /// Escapes the way `JSON.stringify` does: quotes, backslashes, and control characters only.
    static func quoted(_ string: String) -> String {
        var text = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\u{8}": text += "\\b"
            case "\u{c}": text += "\\f"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case let control where control.value < 0x20: text += String(format: "\\u%04x", control.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        func error(_ reason: String) -> OrderedJSONError {
            OrderedJSONError(offset: offset, reason: reason)
        }

        var current: UInt8? {
            offset < bytes.count ? bytes[offset] : nil
        }

        mutating func skipWhitespace() {
            while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
                offset += 1
            }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard current == byte else { throw error("Expected \(Character(UnicodeScalar(byte)))") }
            offset += 1
        }

        mutating func value() throws -> OrderedJSON {
            guard let byte = current else { throw error("Expected a value") }
            switch byte {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw error("Expected a value")
            }
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let expected = Array(word.utf8)
            guard bytes.count - offset >= expected.count, Array(bytes[offset..<offset + expected.count]) == expected
            else { throw error("Expected \(word)") }
            offset += expected.count
            return value
        }

        mutating func object() throws -> OrderedJSON {
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                offset += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw error("Expected a key") }
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                members.append(Member(key, try value()))
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    offset += 1
                    continue
                }
                try expect(UInt8(ascii: "}"))
                return .object(members)
            }
        }

        mutating func array() throws -> OrderedJSON {
            try expect(UInt8(ascii: "["))
            var items: [OrderedJSON] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                offset += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    offset += 1
                    continue
                }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var scalars = String.UnicodeScalarView()
            var start = offset
            func flush(upTo end: Int) throws {
                guard end > start else { return }
                guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else {
                    throw error("Invalid UTF-8")
                }
                scalars.append(contentsOf: text.unicodeScalars)
            }
            while let byte = current {
                switch byte {
                case UInt8(ascii: "\""):
                    try flush(upTo: offset)
                    offset += 1
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush(upTo: offset)
                    offset += 1
                    scalars.append(try escape())
                    start = offset
                case 0..<0x20:
                    throw error("Control character in a string")
                default:
                    offset += 1
                }
            }
            throw error("Unterminated string")
        }

        mutating func escape() throws -> UnicodeScalar {
            guard let byte = current else { throw error("Unterminated escape") }
            offset += 1
            switch byte {
            case UInt8(ascii: "\""): return "\""
            case UInt8(ascii: "\\"): return "\\"
            case UInt8(ascii: "/"): return "/"
            case UInt8(ascii: "b"): return "\u{8}"
            case UInt8(ascii: "f"): return "\u{c}"
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "u"):
                let high = try hex4()
                if (0xD800..<0xDC00).contains(high) {
                    try expect(UInt8(ascii: "\\"))
                    try expect(UInt8(ascii: "u"))
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low),
                        let scalar = UnicodeScalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
                    else { throw error("Invalid surrogate pair") }
                    return scalar
                }
                guard let scalar = UnicodeScalar(high) else { throw error("Invalid \\u escape") }
                return scalar
            default:
                throw error("Invalid escape")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - offset >= 4,
                let text = String(bytes: bytes[offset..<offset + 4], encoding: .ascii),
                let value = UInt32(text, radix: 16)
            else { throw error("Invalid \\u escape") }
            offset += 4
            return value
        }

        mutating func number() throws -> String {
            let start = offset
            func digits() -> Int {
                let from = offset
                while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                    offset += 1
                }
                return offset - from
            }
            if current == UInt8(ascii: "-") { offset += 1 }
            if current == UInt8(ascii: "0") {
                offset += 1
            } else if digits() == 0 {
                throw error("Invalid number")
            }
            if current == UInt8(ascii: ".") {
                offset += 1
                guard digits() > 0 else { throw error("Invalid number") }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                offset += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { offset += 1 }
                guard digits() > 0 else { throw error("Invalid number") }
            }
            if let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                throw error("Invalid number")
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
    }
}
