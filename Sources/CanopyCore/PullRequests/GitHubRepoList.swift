import Foundation

/// One of the user's GitHub repos, for picking one to clone.
public struct GitHubRepoSummary: Sendable, Equatable, Identifiable {
    public var nameWithOwner: String
    public var description: String?
    public var isPrivate: Bool
    /// Nil for a repo nothing was ever pushed to.
    public var pushedAt: Date?

    public var id: String { nameWithOwner }

    public init(nameWithOwner: String, description: String?, isPrivate: Bool, pushedAt: Date?) {
        self.nameWithOwner = nameWithOwner
        self.description = description
        self.isPrivate = isPrivate
        self.pushedAt = pushedAt
    }
}

/// The user's own repos and those of their organizations, the 100 most recently pushed.
enum RepoListQuery {
    static let text = """
        query { viewer { repositories(first: 100, orderBy: {field: PUSHED_AT, direction: DESC}, \
        ownerAffiliations: [OWNER, ORGANIZATION_MEMBER]) \
        { nodes { nameWithOwner description isPrivate pushedAt } } } }
        """

    static func parse(_ data: Data) throws -> [GitHubRepoSummary] {
        struct Node: Decodable {
            var nameWithOwner: String
            var description: String?
            var isPrivate: Bool
            var pushedAt: String?
        }
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Viewer: Decodable {
                    struct Connection: Decodable { var nodes: [Node] }
                    var repositories: Connection
                }
                var viewer: Viewer
            }
            var data: Payload
        }
        return try JSONDecoder().decode(Response.self, from: data).data.viewer.repositories.nodes.map {
            GitHubRepoSummary(
                nameWithOwner: $0.nameWithOwner, description: $0.description, isPrivate: $0.isPrivate,
                pushedAt: $0.pushedAt.flatMap { try? Date($0, strategy: .iso8601) })
        }
    }
}
