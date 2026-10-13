import CanopySystem
import Foundation

public struct TmuxError: Error, Equatable, CustomStringConvertible {
    public var arguments: [String]
    public var message: String

    public var description: String {
        "tmux \(arguments.first ?? "") failed: \(message)"
    }
}

/// One pane of a tmux server: the session it is the only pane of, as every Canopy session has one window and pane.
public struct TmuxPane: Sendable, Equatable {
    public var session: String
    /// The shell's pid, or the command's when the session runs one.
    public var pid: Int32
    /// The foreground program's name, as tmux sees it.
    public var command: String
    /// The foreground program's folder.
    public var folder: String
    /// The folder the session started in.
    public var start: String
    public var title: String
}

/// One tmux server, as `tmux -L <server>` names it, with Canopy's config.
public struct Tmux: Sendable {
    public let server: String
    public let config: String?
    public let environment: [String: String]
    public let executable: String

    /// Each call gets this long, so a stuck tmux cannot hold the daemon.
    static let timeout = Duration.seconds(10)

    public init(server: String, config: String?, environment: [String: String]) {
        self.server = server
        self.config = config
        self.environment = environment
        executable = Self.find("tmux", path: environment["PATH"]) ?? "/usr/bin/tmux"
    }

    /// The first executable `name` on `path`.
    static func find(_ name: String, path: String?) -> String? {
        (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `-u`: under a locale that is not UTF-8 tmux would print tabs and other characters as underscores.
    var baseArguments: [String] {
        ["-u", "-L", server] + (config.map { ["-f", $0] } ?? [])
    }

    /// Starts a detached session in `folder`, with `environment` for its first shell. `command` runs in place of the
    /// shell, through `sh -c`, which only tests need.
    public func newSession(
        _ name: String, folder: String, environment variables: [String: String], command: String? = nil
    ) async throws {
        let variables = variables.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
        try await run(["new-session", "-d", "-s", name, "-c", folder] + variables + (command.map { [$0] } ?? []))
    }

    public func hasSession(_ name: String) async -> Bool {
        (try? await run(["has-session", "-t", "=\(name)"])) != nil
    }

    public func killSession(_ name: String) async {
        _ = try? await run(["kill-session", "-t", "=\(name)"])
    }

    /// Every pane of every session. None when no server runs.
    public func panes() async throws -> [TmuxPane] {
        let format =
            "#{session_name}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{session_path}\t#{pane_title}"
        let listed: String
        do {
            listed = try await run(["list-panes", "-a", "-F", format])
        } catch let error as TmuxError where Self.noServer(error.message) {
            return []
        }
        return listed.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let pid = Int32(fields[1]) else { return nil }
            return TmuxPane(
                session: String(fields[0]), pid: pid, command: String(fields[2]), folder: String(fields[3]),
                start: String(fields[4]), title: String(fields[5]))
        }
    }

    /// The pane's visible screen, or its last `lines` lines with scrollback, as plain text or with `escapes` for
    /// colours. Trailing blank lines are left out.
    public func capture(_ name: String, lines: Int?, escapes: Bool = false) async throws -> String {
        var arguments = ["capture-pane", "-p", "-t", "=\(name):"]
        if escapes { arguments.append("-e") }
        if let lines { arguments += ["-S", "-\(max(lines, 1))"] }
        var rows = try await run(arguments).components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        if let lines { rows = Array(rows.suffix(lines)) }
        return rows.joined(separator: "\n")
    }

    /// Types text as it is, never reading words such as `Enter` as keys.
    public func sendText(_ text: String, to name: String) async throws {
        guard !text.isEmpty else { return }
        try await run(["send-keys", "-t", "=\(name):", "-l", "--", Self.literal(text)])
    }

    /// tmux reads an argument ending in `;` as the end of a command, and one ending in `\;` as ending in `;`.
    static func literal(_ argument: String) -> String {
        argument.hasSuffix(";") ? argument.dropLast() + "\\;" : argument
    }

    /// Sends bytes exactly, as a terminal sends a key.
    public func sendBytes(_ bytes: Data, to name: String) async throws {
        guard !bytes.isEmpty else { return }
        try await run(["send-keys", "-t", "=\(name):", "-H"] + bytes.map { String(format: "%02x", $0) })
    }

    /// Pastes text as one paste, bracketed when the program asked for that, with newlines as Return.
    public func paste(_ text: String, to name: String) async throws {
        let buffer = "canopy-\(name)"
        try await run(["load-buffer", "-b", buffer, "-"], stdin: Data(text.utf8))
        try await run(["paste-buffer", "-p", "-d", "-b", buffer, "-t", "=\(name):"])
    }

    static func noServer(_ message: String) -> Bool {
        message.contains("no server running") || message.contains("error connecting to")
            || message.contains("No such file or directory")
    }

    @discardableResult
    func run(_ arguments: [String], stdin: Data? = nil) async throws -> String {
        let executable = executable
        let all = baseArguments + arguments
        let environment = environment
        let result = await onOwnThread {
            Result {
                try Subprocess.run(
                    executable, all, environment: environment, directory: nil, timeout: Self.timeout, stdin: stdin)
            }
        }
        let ran: SubprocessResult
        do {
            ran = try result.get()
        } catch {
            throw TmuxError(arguments: arguments, message: "\(error)")
        }
        guard ran.status == 0, !ran.timedOut else {
            let message = String(decoding: ran.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TmuxError(
                arguments: arguments,
                message: ran.timedOut ? "timed out" : message.isEmpty ? "exit \(ran.status)" : message)
        }
        return String(decoding: ran.stdout, as: UTF8.self)
    }
}
