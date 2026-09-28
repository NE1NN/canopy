import Foundation

public enum PRState: String, Codable, Sendable {
    case open, draft, merged, closed

    /// GitHub's state, with an open draft shown as draft.
    init(gitHub state: String, isDraft: Bool) {
        self =
            switch state {
            case "OPEN": isDraft ? .draft : .open
            case "MERGED": .merged
            default: .closed
            }
    }
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

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// GitHub ignores case in owner and repo names.
    public func matches(_ other: GitHubRepo) -> Bool {
        owner.lowercased() == other.owner.lowercased() && name.lowercased() == other.name.lowercased()
    }

    /// `remoteURL` with this repo's owner and name in place of its own, keeping its scheme, user, host, and `.git`
    /// ending, so a fork is reached the way origin is: over the same protocol, SSH host alias, and URL rewrites.
    public func url(replacingRepoIn remoteURL: String) -> String? {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.split(url) != nil else { return nil }
        let pathStart: String.Index
        if let separator = url.range(of: "://") {
            guard let slash = url[separator.upperBound...].firstIndex(of: "/") else { return nil }
            pathStart = url.index(after: slash)
        } else {
            guard let colon = url.firstIndex(of: ":") else { return nil }
            pathStart = url.index(after: colon)
        }
        var path = url[pathStart...]
        if path.hasSuffix("/") { path.removeLast() }
        return url[..<pathStart] + "\(owner)/\(name)" + (path.hasSuffix(".git") ? ".git" : "")
    }

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
    static let fields = "number title url state isDraft updatedAt isCrossRepository"

    /// `numbers` holds the PR bound to a branch whose name cannot find it, which is asked for by number instead.
    public static func build(repo: GitHubRepo, branches: [String], numbers: [String: Int] = [:]) -> String {
        let aliases = branches.enumerated().map { index, branch in
            if let number = numbers[branch] {
                return "b\(index): pullRequest(number: \(number)) { \(fields) }"
            }
            return """
                b\(index): pullRequests(headRefName: \(literal(branch)), first: 100, \
                orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \(fields) } }
                """
        }
        return "query { repository(owner: \(literal(repo.owner)), name: \(literal(repo.name))) { "
            + aliases.joined(separator: " ") + " } }"
    }

    /// Each branch's PR. A branch asked about by name gets its open PR if there is one, otherwise its most recently
    /// updated, and PRs from forks that happen to use the same branch name are ignored. Comparing names instead would
    /// drop every PR of a repo that was renamed, since GitHub answers for the old name with the new one. A branch
    /// asked about by number gets that PR, from a fork or not.
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
        /// A search by name answers with a connection, and a lookup by number with the PR itself.
        enum Field: Decodable {
            case search([Node])
            case bound(Node)

            init(from decoder: any Decoder) throws {
                if let connection = try? Connection(from: decoder) {
                    self = .search(connection.nodes)
                } else {
                    self = .bound(try Node(from: decoder))
                }
            }
        }
        struct Response: Decodable {
            struct Payload: Decodable { var repository: [String: Field?]? }
            var data: Payload?
        }
        let found = try JSONDecoder().decode(Response.self, from: data).data?.repository ?? [:]
        var result: [String: PullRequest] = [:]
        for (index, branch) in branches.enumerated() {
            let chosen: Node?
            switch found["b\(index)"] ?? nil {
            case .search(let nodes):
                let own = nodes.filter { !$0.isCrossRepository }
                chosen = own.first { $0.state == "OPEN" } ?? own.max { $0.updatedAt < $1.updatedAt }
            case .bound(let node):
                chosen = node
            case nil:
                chosen = nil
            }
            guard let chosen else { continue }
            result[branch] = PullRequest(
                number: chosen.number, title: chosen.title, url: chosen.url,
                state: PRState(gitHub: chosen.state, isDraft: chosen.isDraft), updatedAt: chosen.updatedAt)
        }
        return result
    }

    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
