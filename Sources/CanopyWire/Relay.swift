import Foundation

/// What the host's `canopy` relay sends the app: one JSON line per connection.
public struct RelayRequest: Codable, Sendable, Equatable {
    public var version: String
    public var args: [String]
    /// The relay's working folder on the host.
    public var cwd: String
    /// The relay's `CANOPY_*` variables.
    public var env: [String: String]
    /// Standard input, base64, when it was not a terminal.
    public var stdin: String?
    /// Seconds since the relay started, so a report is dated by when its hook ran rather than when the app got it.
    public var age: Double?

    public init(
        version: String, args: [String], cwd: String, env: [String: String], stdin: String?, age: Double?
    ) {
        self.version = version
        self.args = args
        self.cwd = cwd
        self.env = env
        self.stdin = stdin
        self.age = age
    }

    public var input: Data? { stdin.flatMap { Data(base64Encoded: $0) } }
}

/// What the app answers a relay with. Output is base64, since a CLI's output need not be UTF-8.
public struct RelayReply: Codable, Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var status: Int32
    /// Why the app ran nothing, such as `relay_outdated`. The relay prints stderr either way.
    public var code: String?

    public init(stdout: Data, stderr: Data, status: Int32, code: String? = nil) {
        self.stdout = stdout.base64EncodedString()
        self.stderr = stderr.base64EncodedString()
        self.status = status
        self.code = code
    }

    public static func failure(_ message: String, status: Int32 = 1, code: String? = nil) -> RelayReply {
        let line = message.hasSuffix("\n") ? message : message + "\n"
        return RelayReply(stdout: Data(), stderr: Data(line.utf8), status: status, code: code)
    }
}

/// How the host's relay reads standard input for one of the CLI's commands. Only the commands that read it on the Mac
/// get any, so a relayed command never takes input meant for what runs after it, as in `while read`, and never waits
/// on a pipe nobody writes to. The host's `canopy-host` is rendered from `commands`.
public enum RelayInput: String, Sendable, CaseIterable {
    /// What arrives within a hook's budget, as `agent-hook` reads Claude's report to its end.
    case hookReport = "hook"
    /// The first line, as `ticket connect` reads a token: byte by byte, within the same wait and length as
    /// `TokenInput`, so what follows stays for the next reader.
    case firstLine = "line"

    /// The CLI's commands that read standard input, by their words.
    public static let commands: [(words: [String], input: RelayInput)] = [
        (["agent-hook"], .hookReport), (["ticket", "connect"], .firstLine),
    ]

    /// The CLI's help flags, with which a command prints its help and reads nothing.
    public static let helpFlags: Set<String> = ["-h", "--help", "--help-hidden"]

    /// How the command `arguments` name reads standard input, or nil for one that reads none. Options among the
    /// command's words are passed over.
    public static func reading(_ arguments: [String]) -> RelayInput? {
        guard !arguments.prefix(while: { $0 != "--" }).contains(where: helpFlags.contains) else { return nil }
        let words = arguments.filter { !$0.hasPrefix("-") }
        return commands.first { words.starts(with: $0.words) }?.input
    }

    /// `commands` as JSON, which the host's script reads as a Python literal, so with no `\/` for a slash, which
    /// Python reads as an invalid escape.
    public static var literal: String { literal(of: commands) }

    public static func literal(of commands: [(words: [String], input: RelayInput)]) -> String {
        let pairs: [[Any]] = commands.map { [$0.words, $0.input.rawValue] }
        let data =
            (try? JSONSerialization.data(withJSONObject: pairs, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
