import Foundation

/// A command that finished in a zsh terminal, as Canopy's startup shim reports it.
struct CommandMark: Sendable, Equatable {
    var command: String
    /// The folder the command started in.
    var directory: String
    var exitCode: Int32
    /// Nil when zsh could not time it.
    var durationMs: Int?

    init(command: String, directory: String, exitCode: Int32, durationMs: Int? = nil) {
        self.command = command
        self.directory = directory
        self.exitCode = exitCode
        self.durationMs = durationMs
    }
}

/// Finds the shim's reports in a terminal's output: `ESC ] 6973 ; command ; token ; exit ; ms ; command ; folder BEL`,
/// with the text percent-encoded. A report can be split across reads. Reports without the shell's token are ignored,
/// so output that happens to replay one, such as `cat` of a recorded session, logs nothing.
struct CommandMarkScanner {
    private enum State {
        case ground
        case escape
        case osc
        case oscEscape
    }

    private static let code = Array("\(ZshIntegration.reportCode);".utf8)
    /// A longer report is not one the shim wrote for a command anyone typed.
    private static let limit = 65_536

    let token: String
    private var state = State.ground
    /// How much of an OSC's start matched "6973;", or nil once it is some other OSC.
    private var matched: Int? = 0
    private var payload: [UInt8] = []

    init(token: String) {
        self.token = token
    }

    mutating func scan(_ data: some DataProtocol) -> [CommandMark] {
        var marks: [CommandMark] = []
        for region in data.regions {
            region.withUnsafeBytes { raw in
                scan(raw.bindMemory(to: UInt8.self), into: &marks)
            }
        }
        return marks
    }

    private mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>, into marks: inout [CommandMark]) {
        guard let base = bytes.baseAddress else { return }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch state {
            case .ground:
                // Most output has no escape sequences worth reading, so skip straight to the next ESC.
                guard let found = memchr(base + index, 0x1B, bytes.count - index) else { return }
                index = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + 1
                state = .escape
                continue
            case .escape:
                if byte == 0x5D {
                    state = .osc
                    matched = 0
                    payload.removeAll(keepingCapacity: true)
                } else if byte != 0x1B {
                    state = .ground
                }
            case .osc:
                switch byte {
                case 0x07:
                    finish(into: &marks)
                case 0x1B:
                    state = .oscEscape
                case 0x18, 0x1A:
                    // CAN and SUB cancel a sequence.
                    state = .ground
                default:
                    collect(byte)
                }
            case .oscEscape:
                guard byte == 0x5C else {
                    // The ESC began another sequence, which this byte continues.
                    state = .escape
                    continue
                }
                finish(into: &marks)
            }
            index += 1
        }
    }

    private mutating func collect(_ byte: UInt8) {
        // Terminals ignore control characters inside an OSC, and the shim never sends them.
        guard byte >= 0x20, let count = matched else { return }
        if count < Self.code.count {
            matched = byte == Self.code[count] ? count + 1 : nil
        } else if payload.count < Self.limit {
            payload.append(byte)
        } else {
            matched = nil
        }
    }

    private mutating func finish(into marks: inout [CommandMark]) {
        state = .ground
        if matched == Self.code.count, let mark = parse(payload) {
            marks.append(mark)
        }
    }

    private func parse(_ payload: [UInt8]) -> CommandMark? {
        let fields = payload.split(separator: 0x3B, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        guard fields.count == 6, fields[0] == "command", fields[1] == token, let exitCode = Int32(fields[2]),
            let command = fields[4].removingPercentEncoding, let directory = fields[5].removingPercentEncoding
        else { return nil }
        return CommandMark(command: command, directory: directory, exitCode: exitCode, durationMs: Int(fields[3]))
    }
}
