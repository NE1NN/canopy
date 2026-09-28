import Foundation

extension WorkspaceError {
    /// Why gh could not answer, in the sidebar's words.
    init(_ failure: GHFailure) {
        switch failure {
        case .ghMissing: self = .ghUnavailable(RepoPullRequests(source: .ghMissing).warning ?? "")
        case .notLoggedIn: self = .ghUnavailable(RepoPullRequests(source: .notLoggedIn).warning ?? "")
        case .failed(let message): self = .ghFailed(message)
        }
    }
}

extension ListedPullRequest {
    public func matches(_ search: SearchText) -> Bool {
        search.matches(["#\(number)", title, headBranch, author ?? ""])
    }
}

extension Workspace {
    /// The repo's open PRs, most recently updated first, or its 100 most recently updated in any state with
    /// `includeClosed`, each with the row that has it. A query that is a PR number, `#number`, or PR URL looks that PR
    /// up in any state. Other text keeps the PRs whose number, title, head branch, or author holds each of its words.
    public func listPullRequests(
        repoPath: String, query: String? = nil, includeClosed: Bool = false
    ) async throws -> [ListedPullRequest] {
        _ = try entryIndex(repoPath: repoPath)
        guard let origin = await gitHubRemote("origin", repoPath: repoPath) else {
            throw WorkspaceError.notOnGitHub(repoName(repoPath))
        }
        var listed: [ListedPullRequest]
        if let reference = query.flatMap(PRReference.init) {
            if let repo = reference.repo, !repo.matches(origin.repo) {
                throw WorkspaceError.pullRequestInOtherRepo(repo.nameWithOwner, origin: origin.repo.nameWithOwner)
            }
            switch await github.pullRequest(repo: origin.repo, number: reference.number) {
            case .success(let head): listed = head.map { [ListedPullRequest($0)] } ?? []
            case .failure(let failure): throw WorkspaceError(failure)
            }
        } else {
            switch await github.pullRequestList(repo: origin.repo, includeClosed: includeClosed) {
            case .success(let all): listed = all.filter { $0.matches(SearchText(query)) }
            case .failure(let failure): throw WorkspaceError(failure)
            }
        }
        let holders = pullRequestHolders(repoPath: repoPath, repo: origin.repo)
        for index in listed.indices {
            listed[index].row = holders(listed[index])
        }
        return listed
    }

    /// Finds the row or worktree that has a PR's branch: one on a branch bound to the PR, or for a PR from the repo
    /// itself, one on its head branch. These are also how the PR badges find a row's PR. A worktree whose folder is
    /// gone holds nothing, since `row new` takes its branch back.
    func pullRequestHolders(repoPath: String, repo: GitHubRepo) -> (ListedPullRequest) -> BranchHolder? {
        let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing && $0.branch != nil } ?? []
        let bound = boundPullRequests(repoPath: repoPath, branches: rows.compactMap(\.branch), repo: repo)
        return { pr in
            let row =
                rows.first { $0.branch.flatMap { bound[$0] } == pr.number }
                ?? (pr.isFork ? nil : rows.first { $0.branch == pr.headBranch })
            return row.map(BranchHolder.init)
        }
    }
}
