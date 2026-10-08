import Foundation

public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String
    public var timedOut = false
    /// ssh could not reach the host git was to run on, so git never ran.
    public var hostUnreachable = false

    public var description: String {
        if timedOut { return "git \(arguments.first ?? "") timed out" }
        if hostUnreachable {
            let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? "ssh could not reach the host" : reason
        }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(exitCode)" : message
    }
}

public struct GitRunner: Sendable {
    public var executable: String
    private let baseEnvironment: [String: String]?
    /// Set for git on a host, which runs through the host's ssh master.
    public private(set) var ssh: SSHCommand?

    /// With no environment, git gets this process's environment with the user's login PATH,
    /// resolved on the first run rather than here, so creating a runner never blocks.
    public init(executable: String = "/usr/bin/git", environment: [String: String]? = nil) {
        self.executable = executable
        self.baseEnvironment = environment
    }

    /// git on a host, run through `ssh`. The environment is ssh's, which needs the login PATH for a ProxyCommand.
    public static func remote(_ ssh: SSHCommand, environment: [String: String]? = nil) -> GitRunner {
        var runner = GitRunner(executable: ssh.executable, environment: environment)
        runner.ssh = ssh
        return runner
    }

    /// Runs git on a thread of its own. With a timeout, git and everything it started are killed when it expires, and
    /// the error has `timedOut` set. `handle` can stop git and read its stderr as it runs.
    @discardableResult
    public func run(
        _ arguments: [String], in directory: String? = nil, timeout: Duration? = nil, handle: SubprocessHandle? = nil
    ) async throws -> String {
        try await onOwnThread { Result { try runBlocking(arguments, in: directory, timeout: timeout, handle: handle) } }
            .get()
    }

    /// Runs git and reports only whether it exited 0. For probes like `show-ref --verify`.
    public func succeeds(_ arguments: [String], in directory: String? = nil) async -> Bool {
        (try? await run(arguments, in: directory)) != nil
    }

    private func runBlocking(
        _ arguments: [String], in directory: String?, timeout: Duration?, handle: SubprocessHandle?
    ) throws -> String {
        let result: SubprocessResult
        do {
            let environment =
                baseEnvironment.map { GitEnvironment.build(base: $0, loginPath: nil) } ?? GitEnvironment.current
            if let ssh {
                let remote =
                    ["env", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C", "git"] + (directory.map { ["-C", $0] } ?? [])
                    + arguments
                let argv = ssh.exec(remote)
                result = try Subprocess.run(
                    argv[0], Array(argv.dropFirst()), environment: environment, directory: nil, timeout: timeout,
                    handle: handle)
            } else {
                result = try Subprocess.run(
                    executable, arguments, environment: environment, directory: directory, timeout: timeout,
                    handle: handle)
            }
        } catch let error as SubprocessError {
            throw GitError(arguments: arguments, exitCode: -1, stderr: error.description)
        }
        guard result.status == 0, !result.timedOut else {
            throw GitError(
                arguments: arguments,
                exitCode: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self),
                timedOut: result.timedOut,
                // ssh exits 255 for its own failures, and git never exits with it.
                hostUnreachable: ssh != nil && result.status == 255
            )
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
