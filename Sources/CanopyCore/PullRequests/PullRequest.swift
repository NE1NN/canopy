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

    /// Reads https, ssh, and scp-style GitHub remotes. Anything else has no GitHub repo.
    public init?(remoteURL: String) {
        var path = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["git@github.com:", "https://github.com/", "http://github.com/", "ssh://git@github.com/"]
        guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { return nil }
        path = String(path.dropFirst(prefix.count))
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }
}

/// One GraphQL request per repo, with an aliased pull request search per branch.
public enum PRQuery {
    public static func build(repo: GitHubRepo, branches: [String]) -> String {
        let fields = branches.enumerated().map { index, branch in
            """
            b\(index): pullRequests(headRefName: \(literal(branch)), first: 10, \
            orderBy: {field: UPDATED_AT, direction: DESC}) \
            { nodes { number title url state isDraft updatedAt headRepository { nameWithOwner } } }
            """
        }
        return "query { repository(owner: \(literal(repo.owner)), name: \(literal(repo.name))) { "
            + fields.joined(separator: " ") + " } }"
    }

    /// Each branch's PR: its open PR if there is one, otherwise its most recently updated. PRs from forks that
    /// happen to use the same branch name are ignored.
    public static func parse(_ data: Data, repo: GitHubRepo, branches: [String]) throws -> [String: PullRequest] {
        struct Node: Decodable {
            struct Head: Decodable { var nameWithOwner: String }
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var headRepository: Head?
        }
        struct Connection: Decodable { var nodes: [Node] }
        struct Response: Decodable {
            struct Payload: Decodable { var repository: [String: Connection]? }
            var data: Payload?
        }
        let found = try JSONDecoder().decode(Response.self, from: data).data?.repository ?? [:]
        var result: [String: PullRequest] = [:]
        for (index, branch) in branches.enumerated() {
            let nodes = (found["b\(index)"]?.nodes ?? []).filter {
                $0.headRepository?.nameWithOwner.lowercased() == repo.nameWithOwner.lowercased()
            }
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
