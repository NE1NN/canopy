import Foundation

public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String
    public var timedOut = false

    public var description: String {
        if timedOut { return "git \(arguments.first ?? "") timed out" }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(exitCode)" : message
    }
}

public struct GitRunner: Sendable {
    public var executable: String
    private let baseEnvironment: [String: String]?

    /// With no environment, git gets this process's environment with the user's login PATH,
    /// resolved on the first run rather than here, so creating a runner never blocks.
    public init(executable: String = "/usr/bin/git", environment: [String: String]? = nil) {
        self.executable = executable
        self.baseEnvironment = environment
    }

    /// Runs git on a thread of its own. With a timeout, git and everything it started are killed
    /// when it expires, and the error has `timedOut` set.
    @discardableResult
    public func run(_ arguments: [String], in directory: String? = nil, timeout: Duration? = nil) async throws
        -> String
    {
        try await onOwnThread { Result { try runBlocking(arguments, in: directory, timeout: timeout) } }.get()
    }

    /// Runs git and reports only whether it exited 0. For probes like `show-ref --verify`.
    public func succeeds(_ arguments: [String], in directory: String? = nil) async -> Bool {
        (try? await run(arguments, in: directory)) != nil
    }

    private func runBlocking(_ arguments: [String], in directory: String?, timeout: Duration?) throws -> String {
        let result: SubprocessResult
        do {
            let environment =
                baseEnvironment.map { GitEnvironment.build(base: $0, loginPath: nil) } ?? GitEnvironment.current
            result = try Subprocess.run(
                executable, arguments, environment: environment, directory: directory, timeout: timeout)
        } catch let error as SubprocessError {
            throw GitError(arguments: arguments, exitCode: -1, stderr: error.description)
        }
        guard result.status == 0, !result.timedOut else {
            throw GitError(
                arguments: arguments,
                exitCode: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self),
                timedOut: result.timedOut
            )
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
