import Foundation

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

    /// Where Homebrew puts gh, searched after PATH for when the login PATH could not be read.
    public static let homebrewFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// With no environment, gh gets this process's environment with the user's login PATH.
    public init(
        environment: [String: String]? = nil, timeout: Duration = .seconds(30),
        fallbackFolders: [String] = homebrewFolders
    ) {
        self.environment = environment
        self.timeout = timeout
        self.fallbackFolders = fallbackFolders
    }

    public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: lookUpBlocking(repo: repo, branches: branches))
            }
        }
    }

    private func lookUpBlocking(repo: GitHubRepo, branches: [String]) -> PRLookup {
        var environment = environment ?? GitEnvironment.current
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard
            let executable = (folders + fallbackFolders).lazy.map({ $0 + "/gh" }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { return .ghMissing }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"

        let query = PRQuery.build(repo: repo, branches: branches)
        let result: SubprocessResult
        do {
            result = try Subprocess.run(
                executable, ["api", "graphql", "-f", "query=\(query)"], environment: environment, directory: nil,
                timeout: timeout)
        } catch {
            return .failed("\(error)")
        }
        if result.timedOut { return .failed("gh did not answer in time.") }
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
        if result.status == 4 || message.contains("HTTP 401") { return .notLoggedIn }
        guard result.status == 0 else {
            let line = message.split(separator: "\n").last.map(String.init) ?? "gh exited with \(result.status)."
            return .failed(line.hasPrefix("gh: ") ? String(line.dropFirst(4)) : line)
        }
        do {
            return .found(try PRQuery.parse(result.stdout, repo: repo, branches: branches))
        } catch {
            return .failed("gh returned a reply Canopy could not read.")
        }
    }
}
