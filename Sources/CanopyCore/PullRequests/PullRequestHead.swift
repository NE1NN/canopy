import Foundation

/// What starting a row from a pull request needs to know about it.
public struct PullRequestHead: Sendable, Equatable {
    public var pullRequest: PullRequest
    /// The head branch's name, in the repo the PR comes from.
    public var branch: String
    public var commit: String
    /// False once the head branch is deleted, as it usually is after a merge.
    public var branchExists: Bool
    /// Whether the PR comes from a fork.
    public var isCrossRepository: Bool
    /// The repo the head branch lives in. Nil when GitHub no longer reports it, as for a deleted fork.
    public var headRepo: GitHubRepo?
    /// Whether the PR's author lets maintainers push to its branch.
    public var maintainerCanModify: Bool
    /// The base repo's default branch.
    public var defaultBranch: String?
}

/// One GraphQL request for one pull request and its repo's default branch.
public enum PRHeadQuery {
    public static func build(repo: GitHubRepo, number: Int) -> String {
        "query { repository(owner: \(PRQuery.literal(repo.owner)), name: \(PRQuery.literal(repo.name))) { "
            + "defaultBranchRef { name } pullRequest(number: \(number)) { number title url state isDraft updatedAt "
            + "headRefName headRefOid headRef { name } baseRefName isCrossRepository maintainerCanModify "
            + "headRepository { name } headRepositoryOwner { login } } } }"
    }

    /// Nil when the repo has no such pull request.
    public static func parse(_ data: Data) throws -> PullRequestHead? {
        struct Name: Decodable { var name: String }
        struct Login: Decodable { var login: String }
        struct Node: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var updatedAt: String
            var headRefName: String
            var headRefOid: String
            var headRef: Name?
            var isCrossRepository: Bool
            var maintainerCanModify: Bool
            var headRepository: Name?
            var headRepositoryOwner: Login?
        }
        struct Repository: Decodable {
            var defaultBranchRef: Name?
            var pullRequest: Node?
        }
        struct Response: Decodable {
            struct Payload: Decodable { var repository: Repository? }
            var data: Payload?
        }
        let repository = try JSONDecoder().decode(Response.self, from: data).data?.repository
        guard let node = repository?.pullRequest else { return nil }
        var headRepo: GitHubRepo?
        if let owner = node.headRepositoryOwner, let repo = node.headRepository {
            headRepo = GitHubRepo(owner: owner.login, name: repo.name)
        }
        return PullRequestHead(
            pullRequest: PullRequest(
                number: node.number, title: node.title, url: node.url,
                state: PRState(gitHub: node.state, isDraft: node.isDraft), updatedAt: node.updatedAt),
            branch: node.headRefName, commit: node.headRefOid, branchExists: node.headRef != nil,
            isCrossRepository: node.isCrossRepository, headRepo: headRepo,
            maintainerCanModify: node.maintainerCanModify, defaultBranch: repository?.defaultBranchRef?.name)
    }
}
