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

    /// The repo's local branches and origin's, newest commit first, each with the row or worktree that has it. With
    /// `fetch`, origin is fetched first, unless a fetch that finished after this call was made covers it. A query keeps
    /// the branches whose name holds each of its words, with one named exactly that, in any case, first.
    public func listBranches(repoPath: String, query: String? = nil, fetch: Bool = true) async throws -> BranchListing {
        let requestedAt = ContinuousClock.now
        _ = try entryIndex(repoPath: repoPath)
        guard FileManager.default.fileExists(atPath: repoPath) else { throw WorkspaceError.pathNotFound(repoPath) }
        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
        var warnings: [String] = []
        if fetch, hasOrigin {
            // In the repo's git queue, since pruning rewrites refs that creating a row may be writing too.
            let failure = try await serialized(repoPath: repoPath) {
                await self.fetchUnlessFresh(repoPath: repoPath, since: requestedAt)
            }
            if let failure { warnings.append("\(failure), so the list shows what Canopy last saw of origin.") }
        }

        let output: String
        do {
            output = try await git.run(
                ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(committerdate:unix)", "refs/heads/"]
                    + (hasOrigin ? ["refs/remotes/origin/"] : []),
                in: repoPath)
        } catch let error as GitError {
            throw WorkspaceError.git(error)
        }
        var local: [String: (commit: String, date: Date)] = [:]
        var origin: [String: (commit: String, date: Date)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let seconds = TimeInterval(fields[2]) else { continue }
            let tip = (commit: fields[1], date: Date(timeIntervalSince1970: seconds))
            if fields[0].hasPrefix("refs/heads/") {
                local[String(fields[0].dropFirst("refs/heads/".count))] = tip
            } else if fields[0] != "refs/remotes/origin/HEAD" {
                origin[String(fields[0].dropFirst("refs/remotes/origin/".count))] = tip
            }
        }

        let search = SearchText(query)
        let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing } ?? []
        var branches: [ListedBranch] = []
        for name in Set(local.keys).union(origin.keys) where search.matches([name]) {
            let here = local[name]
            let there = origin[name]
            var branch = ListedBranch(
                name: name, location: here == nil ? .origin : there == nil ? .local : .both,
                committedAt: max(here?.date ?? .distantPast, there?.date ?? .distantPast).formatted(.iso8601),
                row: rows.first { $0.branch == name }.map(BranchHolder.init))
            if let here, let there {
                (branch.ahead, branch.behind) =
                    here.commit == there.commit
                    ? (0, 0) : await aheadBehind(here.commit, there.commit, repoPath: repoPath)
            }
            branches.append(branch)
        }
        let typed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        branches.sort { a, b in
            let aExact = a.name.caseInsensitiveCompare(typed) == .orderedSame
            let bExact = b.name.caseInsensitiveCompare(typed) == .orderedSame
            if aExact != bExact { return aExact }
            if a.committedAt != b.committedAt { return a.committedAt > b.committedAt }
            return a.name < b.name
        }
        return BranchListing(
            branches: branches, defaultBase: await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin),
            warnings: warnings)
    }

    /// How many commits `local` has that `other` does not, and the other way round. Nil when git cannot say.
    private func aheadBehind(_ local: String, _ other: String, repoPath: String) async -> (Int?, Int?) {
        guard
            let counts = try? await git.run(
                ["rev-list", "--left-right", "--count", "\(local)...\(other)"], in: repoPath)
        else { return (nil, nil) }
        let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (nil, nil)
    }
}
