import Foundation

public enum PRState: String, Codable, Sendable {
    case open, draft, merged, closed
}

public struct PullRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: PRState
    public var updatedAt: String

    public init(number: Int, title: String, url: String, state: PRState, updatedAt: String) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// The GitHub repository behind an `origin` remote.
public struct GitHubRepo: Sendable, Equatable {
    public var owner: String
    public var name: String

    public var nameWithOwner: String { "\(owner)/\(name)" }

    static let hosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]

    /// Reads https, ssh, and scp-style GitHub remotes. `sshHostName` says which host an SSH alias, such as the
    /// github-work people set up for a second account, connects to. Anything else has no GitHub repo.
    public init?(remoteURL: String, sshHostName: (String) -> String? = { _ in nil }) {
        guard let remote = Self.split(remoteURL) else { return nil }
        let host =
            Self.hosts.contains(remote.host) || !remote.isSSH ? remote.host : sshHostName(remote.host)?.lowercased()
        guard let host, Self.hosts.contains(host) else { return nil }
        var path = remote.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    /// The host and path of a URL remote, `scheme://[user@]host[:port]/path`, or an scp-style one, `[user@]host:path`.
    private static func split(_ remoteURL: String) -> (host: String, path: String, isSSH: Bool)? {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = url.range(of: "://") {
            let scheme = url[..<separator.lowerBound].lowercased()
            let rest = url[separator.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var host = rest[..<slash]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
            let path = String(rest[rest.index(after: slash)...])
            return (host.lowercased(), path, scheme == "ssh" || scheme == "git+ssh")
        }
        // A colon after a slash is part of a local path, like ./a:b.
        guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
        var host = url[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        return (host.lowercased(), String(url[url.index(after: colon)...]), true)
    }
}

/// One GraphQL request per repo, with an aliased pull request search per branch.
public enum PRQuery {
    public static func build(repo: GitHubRepo, branches: [String]) -> String {
        let fields = branches.enumerated().map { index, branch in
            """
            b\(index): pullRequests(headRefName: \(literal(branch)), first: 100, \
            orderBy: {field: UPDATED_AT, direction: DESC}) \
            { nodes { number title url state isDraft updatedAt isCrossRepository } }
            """
        }
        return "query { repository(owner: \(literal(repo.owner)), name: \(literal(repo.name))) { "
            + fields.joined(separator: " ") + " } }"
    }

    /// Each branch's PR: its open PR if there is one, otherwise its most recently updated. PRs from forks that
    /// happen to use the same branch name are ignored. Comparing names instead would drop every PR of a repo that was
    /// renamed, since GitHub answers for the old name with the new one.
    public static func parse(_ data: Data, branches: [String]) throws -> [String: PullRequest] {
        struct Node: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var isCrossRepository: Bool
        }
        struct Connection: Decodable { var nodes: [Node] }
        struct Response: Decodable {
            struct Payload: Decodable { var repository: [String: Connection]? }
            var data: Payload?
        }
        let found = try JSONDecoder().decode(Response.self, from: data).data?.repository ?? [:]
        var result: [String: PullRequest] = [:]
        for (index, branch) in branches.enumerated() {
            let nodes = (found["b\(index)"]?.nodes ?? []).filter { !$0.isCrossRepository }
            guard
                let chosen = nodes.first(where: { $0.state == "OPEN" })
                    ?? nodes.max(by: { $0.updatedAt < $1.updatedAt })
            else { continue }
            let state: PRState =
                switch chosen.state {
                case "OPEN": chosen.isDraft ? .draft : .open
                case "MERGED": .merged
                default: .closed
                }
            result[branch] = PullRequest(
                number: chosen.number, title: chosen.title, url: chosen.url, state: state, updatedAt: chosen.updatedAt)
        }
        return result
    }

    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
