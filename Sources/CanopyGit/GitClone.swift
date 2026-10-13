import CanopySystem
import Foundation

/// A clone, or one of its worktrees, and how git runs in it: on this machine, or on a host through ssh.
public struct GitClone: Sendable {
    public typealias Runner =
        @Sendable (_ arguments: [String], _ folder: String, _ timeout: Duration?) async throws ->
        String

    public var path: String
    private let runner: Runner

    /// `run` runs git with `arguments` in `folder`, returning its output or throwing a `GitError`.
    public init(path: String, run: @escaping Runner) {
        self.path = path
        self.runner = run
    }

    /// git on this machine, with `environment` and no prompts for credentials: none on a terminal, and no helper
    /// program, which could wait for an answer nobody gives.
    public static func local(
        path: String, executable: String = "/usr/bin/git",
        environment: [String: String] = ProcessInfo.processInfo
            .environment
    ) -> GitClone {
        var environment = environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        let fixed = environment
        return GitClone(path: path) { arguments, folder, timeout in
            try await onOwnThread {
                Result { () throws(GitError) -> String in
                    let result: SubprocessResult
                    do {
                        result = try Subprocess.run(
                            executable, arguments, environment: fixed, directory: folder, timeout: timeout)
                    } catch {
                        throw GitError(arguments: arguments, exitCode: -1, stderr: "\(error)")
                    }
                    guard result.status == 0, !result.timedOut else {
                        throw GitError(
                            arguments: arguments, exitCode: result.status,
                            stderr: String(decoding: result.stderr, as: UTF8.self), timedOut: result.timedOut)
                    }
                    return String(decoding: result.stdout, as: UTF8.self)
                }
            }.get()
        }
    }

    /// The same git, in another folder, such as a worktree of this clone.
    public func at(_ folder: String) -> GitClone {
        GitClone(path: folder, run: runner)
    }

    @discardableResult
    public func run(_ arguments: [String], timeout: Duration? = nil) async throws -> String {
        try await runner(arguments, path, timeout)
    }

    public func succeeds(_ arguments: [String]) async -> Bool {
        (try? await run(arguments)) != nil
    }

    /// Like `succeeds`, but a host that cannot be reached fails rather than reading as "no".
    public func succeedsOnHost(_ arguments: [String]) async throws -> Bool {
        do {
            try await run(arguments)
            return true
        } catch let error as GitError where error.hostUnreachable {
            throw error
        } catch {
            return false
        }
    }
}
