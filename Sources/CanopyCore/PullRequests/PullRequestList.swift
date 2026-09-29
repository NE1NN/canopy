import Foundation

/// The row or worktree that has a branch checked out.
public struct BranchHolder: Codable, Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var rowClass: RowClass

    public init(path: String, branch: String?, rowClass: RowClass) {
        self.path = path
        self.branch = branch
        self.rowClass = rowClass
    }

    public init(_ row: Row) {
        self.init(path: row.path, branch: row.branch, rowClass: row.rowClass)
    }

    /// A row Canopy shows, rather than another tool's worktree, which it can only adopt.
    public var isRow: Bool { rowClass != .external }

    enum CodingKeys: String, CodingKey {
        case path, branch
        case rowClass = "class"
    }
}

/// A pull request as `canopy pr list` and the New Row sheet show it.
public struct ListedPullRequest: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: PRState
    /// Nil once GitHub no longer has the author's account.
    public var author: String?
    /// The head branch's name, in the repo the PR comes from.
    public var headBranch: String
    public var isFork: Bool
    public var updatedAt: String
    /// The row or worktree that has the PR's branch checked out.
    public var row: BranchHolder?

    public var id: Int { number }

    public init(
        number: Int, title: String, url: String, state: PRState, author: String?, headBranch: String, isFork: Bool,
        updatedAt: String, row: BranchHolder? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.author = author
        self.headBranch = headBranch
        self.isFork = isFork
        self.updatedAt = updatedAt
        self.row = row
    }

    /// A PR looked up by its number.
    public init(_ head: PullRequestHead) {
        self.init(
            number: head.pullRequest.number, title: head.pullRequest.title, url: head.pullRequest.url,
            state: head.pullRequest.state, author: head.author, headBranch: head.branch,
            isFork: head.isCrossRepository, updatedAt: head.pullRequest.updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case number, title, url, state, author, headBranch, updatedAt, row
        case isFork = "fork"
    }

    /// Writes `"row": null` and `"author": null` rather than leaving the keys out, so agents can test for them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(state, forKey: .state)
        try container.encode(author, forKey: .author)
        try container.encode(headBranch, forKey: .headBranch)
        try container.encode(isFork, forKey: .isFork)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(row, forKey: .row)
    }
}

/// One GraphQL request for a repo's most recently updated pull requests.
public enum PRListQuery {
    public static func build(repo: GitHubRepo, includeClosed: Bool) -> String {
        let states = includeClosed ? "[OPEN, CLOSED, MERGED]" : "[OPEN]"
        return "query { repository(owner: \(PRQuery.literal(repo.owner)), name: \(PRQuery.literal(repo.name))) { "
            + "pullRequests(states: \(states), first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { "
            + "nodes { number title url state isDraft updatedAt headRefName isCrossRepository author { login } } } } }"
    }

    public static func parse(_ data: Data) throws -> [ListedPullRequest] {
        struct Login: Decodable { var login: String }
        struct Node: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var headRefName: String
            var isCrossRepository: Bool
            var author: Login?
        }
        struct Response: Decodable {
            struct Connection: Decodable { var nodes: [Node] }
            struct Repository: Decodable { var pullRequests: Connection }
            struct Payload: Decodable { var repository: Repository }
            var data: Payload
        }
        return try JSONDecoder().decode(Response.self, from: data).data.repository.pullRequests.nodes.map {
            ListedPullRequest(
                number: $0.number, title: $0.title, url: $0.url, state: PRState(gitHub: $0.state, isDraft: $0.isDraft),
                author: $0.author?.login, headBranch: $0.headRefName, isFork: $0.isCrossRepository,
                updatedAt: $0.updatedAt)
        }
    }
}
