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

    public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
        let query = PRQuery.build(repo: repo, branches: branches)
        switch await run(["api", "graphql", "-f", "query=\(query)"], timeout: timeout) {
        case .failure(.ghMissing): return .ghMissing
        case .failure(.notLoggedIn): return .notLoggedIn
        case .failure(.failed(let message)): return .failed(message)
        case .success(let reply):
            guard let found = try? PRQuery.parse(reply, branches: branches) else { return .failed(Self.unreadable) }
            return .found(found)
        }
    }

    /// Clones with `gh repo clone`, which uses the user's login and preferred git protocol, into `folder`, which must
    /// not exist yet. git reports progress to stderr, which `handle` reads. Nil when it cloned.
    public func clone(_ repo: String, into folder: String, handle: SubprocessHandle) async -> GHFailure? {
        switch await run(["repo", "clone", repo, folder, "--", "--progress"], timeout: nil, handle: handle) {
        case .success: nil
        case .failure(let failure): failure
        }
    }

    /// The user's repos and their organizations' repos, most recently pushed first.
    public func viewerRepos() async -> Result<[GitHubRepoSummary], GHFailure> {
        switch await run(["api", "graphql", "-f", "query=\(RepoListQuery.text)"], timeout: timeout) {
        case .failure(let failure): return .failure(failure)
        case .success(let reply):
            guard let repos = try? RepoListQuery.parse(reply) else { return .failure(.failed(Self.unreadable)) }
            return .success(repos)
        }
    }

    private static let unreadable = "gh returned a reply Canopy could not read."

    /// Runs gh off the Swift concurrency pool and returns what it printed.
    private func run(
        _ arguments: [String], timeout: Duration?, handle: SubprocessHandle? = nil
    ) async -> Result<Data, GHFailure> {
        await onOwnThread { runBlocking(arguments, timeout: timeout, handle: handle) }
    }

    private func runBlocking(
        _ arguments: [String], timeout: Duration?, handle: SubprocessHandle?
    ) -> Result<Data, GHFailure> {
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
                executable, arguments, environment: environment, directory: nil, timeout: timeout, handle: handle)
        } catch {
            return .failure(.failed("\(error)"))
        }
        if result.timedOut { return .failure(.failed("gh did not answer in time.")) }
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
        if result.status == 4 || message.contains("HTTP 401") { return .failure(.notLoggedIn) }
        guard result.status == 0 else {
            // git rewrites progress lines with a carriage return, so those end lines too.
            let line = message.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init)
            return .failure(.failed(line.map(Self.withoutPrefix) ?? "gh exited with \(result.status)."))
        }
        return .success(result.stdout)
    }

    /// gh's and git's own names for a message, which Canopy's messages do not need.
    private static func withoutPrefix(_ line: String) -> String {
        for prefix in ["gh: ", "fatal: ", "error: "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }
}
