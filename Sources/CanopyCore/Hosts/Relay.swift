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
    static let helpFlags: Set<String> = ["-h", "--help", "--help-hidden"]

    /// How the command `arguments` name reads standard input, or nil for one that reads none. Options among the
    /// command's words are passed over.
    public static func reading(_ arguments: [String]) -> RelayInput? {
        guard !arguments.prefix(while: { $0 != "--" }).contains(where: helpFlags.contains) else { return nil }
        let words = arguments.filter { !$0.hasPrefix("-") }
        return commands.first { words.starts(with: $0.words) }?.input
    }

    /// `commands` as JSON, which the host's script reads as a Python literal, so with no `\/` for a slash, which
    /// Python reads as an invalid escape.
    static var literal: String { literal(of: commands) }

    static func literal(of commands: [(words: [String], input: RelayInput)]) -> String {
        let pairs: [[Any]] = commands.map { [$0.words, $0.input.rawValue] }
        let data =
            (try? JSONSerialization.data(withJSONObject: pairs, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum RelayPaths {
    /// The Mac folder for a host's `remote` folder: the stand-in of the remote row holding it, with the same tail.
    /// Anything else becomes `home`, so the CLI targets nothing by folder and never reads a host path as a Mac one.
    public static func local(_ remote: String, rows: [RemoteRowEntry], home: String) -> String {
        guard let components = components(remote) else { return home }
        var best: (row: RemoteRowEntry, depth: Int)?
        for row in rows {
            guard let root = Self.components(row.path), !root.isEmpty, components.starts(with: root),
                root.count > best?.depth ?? 0
            else { continue }
            best = (row, root.count)
        }
        guard let best else { return home }
        let tail = components.dropFirst(best.depth)
        return tail.isEmpty ? best.row.standIn : best.row.standIn + "/" + tail.joined(separator: "/")
    }

    /// An absolute path's components, or nil for a relative path or one with `..`, whose tail could leave the stand-in.
    private static func components(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").filter { $0 != "." }
        return components.contains("..") ? nil : components
    }
}

public enum RelayRun {
    /// The host a CLI run came from through its relay, from the `CANOPY_HOST` that `environment(for:)` sets.
    /// A local pane never has it.
    public static func host(in environment: [String: String]) -> String? {
        environment["CANOPY_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The variables the CLI reads from the pane it runs in, the only ones of a request that cross over. Others would
    /// mislead or steer the CLI on this Mac by what a program on the host chose: the host's PATH or HOME, or
    /// `CANOPY_APP`, `CANOPY_SSH`, and `CANOPY_SOCKET`.
    public static let paneVariables: Set<String> = [
        "CANOPY_PANE", "CANOPY_REPO", "CANOPY_ROW_PATH", "CANOPY_PLUGIN", "CANOPY_ITEM",
    ]

    /// The environment for the app's CLI running a host's request: the request's `paneVariables`, this Mac's PATH,
    /// HOME, and TMPDIR, and the home, host, and time the app sets.
    public static func environment(
        for request: RelayRequest, host: String, rows: [RemoteRowEntry], home: CanopyHome, receivedAt: Date,
        shellEnvironment: [String: String] = GitEnvironment.current
    ) -> [String: String] {
        var environment = request.env.filter { paneVariables.contains($0.key) }
        environment[CanopyHome.environmentKey] = home.root.path
        environment["CANOPY_HOST"] = host
        if let rowPath = environment["CANOPY_ROW_PATH"] {
            let hostRows = rows.filter { $0.host == host }
            environment["CANOPY_ROW_PATH"] = RelayPaths.local(rowPath, rows: hostRows, home: home.root.path)
        }
        if let age = request.age, age.isFinite, age >= 0 {
            environment["CANOPY_STARTED_AT"] = String(receivedAt.timeIntervalSince1970 - age)
        }
        for key in ["PATH", "HOME", "TMPDIR"] {
            environment[key] = shellEnvironment[key]
        }
        return environment
    }

    /// The folder the app's CLI runs a host's request in: the request's, translated, or the nearest folder above it
    /// in the same stand-in, since a stand-in holds only what Canopy put there. Without one, the home.
    public static func folder(for request: RelayRequest, host: String, rows: [RemoteRowEntry], home: CanopyHome)
        -> String
    {
        let rows = rows.filter { $0.host == host }
        var folder = RelayPaths.local(request.cwd, rows: rows, home: home.root.path)
        let standIn = rows.map(\.standIn).filter { folder == $0 || folder.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        guard let standIn else { return home.root.path }
        var isFolder: ObjCBool = false
        while folder.count >= standIn.count {
            if FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue {
                return folder
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return home.root.path
    }
}
