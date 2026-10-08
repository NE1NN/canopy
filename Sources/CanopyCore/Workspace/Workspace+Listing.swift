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
        guard FileManager.default.fileExists(atPath: repoPath) else { throw WorkspaceError.pathNotFound(repoPath) }
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
    /// itself, one on its head branch that is not bound to another PR. These are also how the PR badges find a row's
    /// PR. A worktree whose folder is gone holds nothing, since `row new` takes its branch back.
    func pullRequestHolders(repoPath: String, repo: GitHubRepo) -> (ListedPullRequest) -> BranchHolder? {
        let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing && $0.branch != nil } ?? []
        let bound = boundPullRequests(repoPath: repoPath, branches: rows.compactMap(\.branch), repo: repo)
        return { pr in
            let row =
                rows.first { $0.branch.flatMap { bound[$0] } == pr.number }
                ?? (pr.isFork ? nil : rows.first { $0.branch == pr.headBranch && bound[pr.headBranch] == nil })
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

        // A local branch whose upstream is its namesake on origin, as most are, gets its counts from this one call.
        let output: String
        do {
            output = try await git.run(
                [
                    "for-each-ref",
                    "--format=%(refname)%00%(objectname)%00%(committerdate:unix)%00%(upstream)%00"
                        + "%(upstream:track,nobracket)",
                    "refs/heads/",
                ] + (hasOrigin ? ["refs/remotes/origin/"] : []),
                in: repoPath)
        } catch let error as GitError {
            throw WorkspaceError.git(error)
        }
        var local: [String: (commit: String, date: Date)] = [:]
        var origin: [String: (commit: String, date: Date)] = [:]
        var tracked: [String: (ahead: Int, behind: Int)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let seconds = TimeInterval(fields[2]) else { continue }
            let tip = (commit: fields[1], date: Date(timeIntervalSince1970: seconds))
            if fields[0].hasPrefix("refs/heads/") {
                let name = String(fields[0].dropFirst("refs/heads/".count))
                local[name] = tip
                if fields[3] == "refs/remotes/origin/\(name)" { tracked[name] = Self.counts(fields[4]) }
            } else if fields[0] != "refs/remotes/origin/HEAD" {
                origin[String(fields[0].dropFirst("refs/remotes/origin/".count))] = tip
            }
        }

        let search = SearchText(query)
        // Remote rows hold branches in their host's clone, which this Mac's git does not know.
        let rows = snapshot.repo(path: repoPath)?.allRows.filter { !$0.isMissing && $0.host == nil } ?? []
        var branches: [ListedBranch] = []
        for name in Set(local.keys).union(origin.keys) where search.matches([name]) {
            let here = local[name]
            let there = origin[name]
            var branch = ListedBranch(
                name: name, location: here == nil ? .origin : there == nil ? .local : .both,
                committedAt: max(here?.date ?? .distantPast, there?.date ?? .distantPast).formatted(.iso8601),
                row: rows.first { $0.branch == name }.map(BranchHolder.init))
            if let here, let there {
                if here.commit == there.commit {
                    (branch.ahead, branch.behind) = (0, 0)
                } else if let counts = tracked[name] {
                    (branch.ahead, branch.behind) = counts
                } else {
                    (branch.ahead, branch.behind) = await aheadBehind(here.commit, there.commit, repoPath: repoPath)
                }
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

    /// Reads `ahead 1, behind 2`, `ahead 1`, `behind 2`, or nothing, as `%(upstream:track,nobracket)` writes them.
    static func counts(_ track: String) -> (ahead: Int, behind: Int)? {
        guard track != "gone" else { return nil }
        var counts = (ahead: 0, behind: 0)
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { return nil }
            switch words[0] {
            case "ahead": counts.ahead = count
            case "behind": counts.behind = count
            default: return nil
            }
        }
        return counts
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
