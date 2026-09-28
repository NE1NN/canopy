import Foundation

/// Why gh could not do what it was asked.
public enum GHFailure: Error, Sendable, Equatable {
    case ghMissing
    case notLoggedIn
    case failed(String)
}

public enum PRLookup: Sendable, Equatable {
    /// Each looked-up branch that has a PR.
    case found([String: PullRequest])
    case ghMissing
    case notLoggedIn
    case failed(String)
}

/// Asks GitHub about pull requests through the user's own `gh`, so Canopy never handles a token.
public struct GitHubCLI: Sendable {
    private let environment: [String: String]?
    private let timeout: Duration
    private let fallbackFolders: [String]
    private let sshConfigFile: String?

    /// Where Homebrew puts gh, searched after PATH for when the login PATH could not be read.
    public static let homebrewFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// With no environment, gh gets this process's environment with the user's login PATH.
    public init(
        environment: [String: String]? = nil, timeout: Duration = .seconds(30),
        fallbackFolders: [String] = homebrewFolders, sshConfigFile: String? = nil
    ) {
        self.environment = environment
        self.timeout = timeout
        self.fallbackFolders = fallbackFolders
        self.sshConfigFile = sshConfigFile
    }

    /// The GitHub repo behind a remote, following SSH host aliases the way git would.
    public func repo(forRemote url: String) async -> GitHubRepo? {
        let environment = environment ?? ProcessInfo.processInfo.environment
        return await onOwnThread {
            GitHubRepo(remoteURL: url) {
                SSHConfig.hostName(for: $0, configFile: sshConfigFile, environment: environment)
            }
        }
    }

    /// `numbers` holds the PR bound to a branch whose name cannot find it.
    public func pullRequests(repo: GitHubRepo, branches: [String], numbers: [String: Int] = [:]) async -> PRLookup {
        let query = PRQuery.build(repo: repo, branches: branches, numbers: numbers)
        switch await run(["api", "graphql", "-f", "query=\(query)"]) {
        case .failure(.ghMissing): return .ghMissing
        case .failure(.notLoggedIn): return .notLoggedIn
        case .failure(.failed(let message)): return .failed(message)
        case .success(let reply):
            guard let found = try? PRQuery.parse(reply, branches: branches) else { return .failed(Self.unreadable) }
            return .found(found)
        }
    }

    /// One pull request of `repo`, with what starting a row from it needs. Nil when the repo has no such PR.
    public func pullRequest(repo: GitHubRepo, number: Int) async -> Result<PullRequestHead?, GHFailure> {
        switch await run(["api", "graphql", "-f", "query=\(PRHeadQuery.build(repo: repo, number: number))"]) {
        case .failure(.failed(let message)) where message.hasPrefix("Could not resolve to a PullRequest"):
            return .success(nil)
        case .failure(let failure):
            return .failure(failure)
        case .success(let reply):
            guard let head = try? PRHeadQuery.parse(reply) else { return .failure(.failed(Self.unreadable)) }
            return .success(head)
        }
    }

    private static let unreadable = "gh returned a reply Canopy could not read."

    /// Runs gh off the Swift concurrency pool and returns what it printed.
    private func run(_ arguments: [String]) async -> Result<Data, GHFailure> {
        await onOwnThread { runBlocking(arguments) }
    }

    private func runBlocking(_ arguments: [String]) -> Result<Data, GHFailure> {
        var environment = environment ?? GitEnvironment.current
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard
            let executable = (folders + fallbackFolders).lazy.map({ $0 + "/gh" }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { return .failure(.ghMissing) }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"

        let result: SubprocessResult
        do {
            result = try Subprocess.run(
                executable, arguments, environment: environment, directory: nil, timeout: timeout)
        } catch {
            return .failure(.failed("\(error)"))
        }
        if result.timedOut { return .failure(.failed("gh did not answer in time.")) }
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
        if result.status == 4 || message.contains("HTTP 401") { return .failure(.notLoggedIn) }
        guard result.status == 0 else {
            let line = message.split(separator: "\n").last.map(String.init) ?? "gh exited with \(result.status)."
            return .failure(.failed(line.hasPrefix("gh: ") ? String(line.dropFirst(4)) : line))
        }
        return .success(result.stdout)
    }
}
