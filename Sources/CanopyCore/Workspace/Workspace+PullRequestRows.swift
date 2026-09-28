import Foundation

extension Workspace {
    /// Creates a row on a pull request's branch, from the repo itself or from a fork, with `gh pr checkout`'s rules for
    /// naming the local branch and setting what it tracks. `branch` names the local branch instead. With `group`, the
    /// row goes straight to the end of that group, which must exist.
    public func createRow(
        repoPath: String, pullRequest reference: PRReference, branch: String? = nil, group: String? = nil
    ) async throws -> CreatedRow {
        _ = try entryIndex(repoPath: repoPath)
        // Checked before asking GitHub, and again once it is this row's turn.
        if let group {
            _ = try joiningGroup(group, repoPath: repoPath)
        }
        guard FileManager.default.fileExists(atPath: repoPath) else {
            throw WorkspaceError.pathNotFound(repoPath)
        }
        if let branch {
            try await requireValidBranchName(branch, repoPath: repoPath)
        }
        guard let origin = await gitHubRemote("origin", repoPath: repoPath) else {
            throw WorkspaceError.notOnGitHub(snapshot.repo(path: repoPath)?.name ?? repoPath)
        }
        if let repo = reference.repo, !repo.matches(origin.repo) {
            throw WorkspaceError.pullRequestInOtherRepo(repo.nameWithOwner, origin: origin.repo.nameWithOwner)
        }
        let head: PullRequestHead
        switch await github.pullRequest(repo: origin.repo, number: reference.number) {
        case .success(let found?):
            head = found
        case .success(nil):
            throw WorkspaceError.pullRequestNotFound(reference.number, repo: origin.repo.nameWithOwner)
        case .failure(let failure):
            throw WorkspaceError(failure)
        }
        return try await createRow(repoPath: repoPath, joining: group) {
            try await self.createPullRequestRowNow(
                repoPath: repoPath, head: head, origin: origin, branch: branch, group: group)
        }
    }

    private func createPullRequestRowNow(
        repoPath: String, head: PullRequestHead, origin: GitHubRemote, branch requested: String?, group: String?
    ) async throws -> CreatedRow {
        let number = head.pullRequest.number
        let joining = try group.map { try joiningGroup($0, repoPath: repoPath) }
        // A fork's branch is not on origin, and a merged PR's branch is often deleted, but origin keeps every PR's head.
        let fromPullRef = head.isCrossRepository || !head.branchExists
        let target = fromPullRef ? "refs/canopy/pr/\(number)" : "refs/remotes/origin/\(head.branch)"
        let source = fromPullRef ? "refs/pull/\(number)/head" : "refs/heads/\(head.branch)"
        do {
            try await git.run(
                ["fetch", "--quiet", "--no-tags", "origin", "+\(source):\(target)"], in: repoPath, timeout: fetchTimeout
            )
        } catch let error as GitError {
            // A fetch can be stopped after it wrote the ref.
            if fromPullRef { _ = try? await git.run(["update-ref", "-d", target], in: repoPath) }
            throw WorkspaceError.pullRequestFetchFailed(number, reason: "\(error)")
        }
        do {
            let created = try await checkOut(
                head, from: target, fromPullRef: fromPullRef, origin: origin, branch: requested, joining: joining,
                repoPath: repoPath)
            if fromPullRef { _ = try? await git.run(["update-ref", "-d", target], in: repoPath) }
            return created
        } catch {
            if fromPullRef { _ = try? await git.run(["update-ref", "-d", target], in: repoPath) }
            throw error
        }
    }

    /// Checks out the PR's head, fetched to `target`, in a new row.
    private func checkOut(
        _ head: PullRequestHead, from target: String, fromPullRef: Bool, origin: GitHubRemote,
        branch requested: String?, joining: String?, repoPath: String
    ) async throws -> CreatedRow {
        let number = head.pullRequest.number
        var notes: [String] = []
        var warnings: [String] = []
        if [.merged, .closed].contains(head.pullRequest.state) {
            warnings.append("PR #\(number) is \(head.pullRequest.state.rawValue), not open.")
        }
        if !head.isCrossRepository, !head.branchExists {
            warnings.append(
                "PR #\(number)'s branch \(head.branch) is gone from origin, so the row starts at the PR's last commit.")
        }

        let (name, exists) = try await localBranch(for: head, origin: origin, requested: requested, repoPath: repoPath)
        try await claim(branch: name, repoPath: repoPath)
        let source: BranchSource
        let added: (row: Row, report: BranchReport)
        if exists {
            // The temporary ref is gone by the time anyone reads the fix commands, so they name the commit.
            let fetched = try? await git.run(["rev-parse", target], in: repoPath).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let report = await compare(
                name, with: target, named: fromPullRef ? "PR #\(number)'s head" : "origin/\(head.branch)",
                resetTo: fromPullRef ? fetched ?? head.commit : "origin/\(head.branch)", repoPath: repoPath)
            notes += report.notes
            warnings += report.warnings
            added = try await addRow(
                repoPath: repoPath, branch: name, joining: joining, fastForward: report.fastForward
            ) { [$0, name] }
            source = .local
        } else {
            // Tracking is set by hand, since `--track` needs a fetch refspec that covers the head, and a shallow or
            // single-branch clone has none.
            do {
                try await git.run(["branch", "--no-track", name, target], in: repoPath)
            } catch let error as GitError {
                throw WorkspaceError.git(error)
            }
            do {
                warnings += try await track(
                    name, head: head, origin: origin, fromPullRef: fromPullRef, repoPath: repoPath)
                added = try await addRow(repoPath: repoPath, branch: name, joining: joining) { [$0, name] }
            } catch {
                // Deleting the branch also drops the tracking set for it.
                _ = try? await git.run(["branch", "-D", name], in: repoPath)
                throw error
            }
            source = .origin
        }
        try bind(name, to: head, origin: origin, repoPath: repoPath)
        return CreatedRow(
            row: added.row, source: source, base: nil, pullRequest: head.pullRequest, notes: notes + added.report.notes,
            warnings: warnings + added.report.warnings)
    }

    /// The local branch for the PR, and whether it exists already and is the PR's. The head's name comes first. A fork's
    /// head falls back to `<owner>/<head>` when that name is the default branch or an unrelated branch, as in gh, and a
    /// head Canopy cannot use as a branch name, or a fork GitHub no longer reports, to `pr/<number>`.
    private func localBranch(
        for head: PullRequestHead, origin: GitHubRemote, requested: String?, repoPath: String
    ) async throws -> (name: String, exists: Bool) {
        let number = head.pullRequest.number
        let candidates: [String]
        if let requested {
            candidates = [requested]
        } else if !(await isValidBranchName(head.branch, repoPath: repoPath)) {
            candidates = ["pr/\(number)"]
        } else if !head.isCrossRepository {
            candidates = [head.branch]
        } else {
            let prefixed = head.headRepo.map { "\($0.owner)/\(head.branch)" } ?? "pr/\(number)"
            candidates = head.branch == head.defaultBranch ? [prefixed] : [head.branch, prefixed]
        }
        for candidate in candidates {
            guard let local = await existingBranch(candidate, under: "refs/heads/", repoPath: repoPath) else {
                return (candidate, false)
            }
            // A same-repo PR's head is the branch of that name, the way `row new <head>` would take it.
            if requested == nil && !head.isCrossRepository && candidate == head.branch {
                return (local, true)
            }
            if await tracks(local, head: head, origin: origin, repoPath: repoPath) {
                return (local, true)
            }
        }
        throw WorkspaceError.branchExists(candidates, pr: number)
    }

    /// Whether `branch` tracks the PR: its head on origin, or its branch in the repo it comes from.
    private func tracks(_ branch: String, head: PullRequestHead, origin: GitHubRemote, repoPath: String) async -> Bool {
        func config(_ key: String) async -> String? {
            try? await git.run(["config", "--get", "branch.\(branch).\(key)"], in: repoPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let remote = await config("remote"), let merge = await config("merge") else { return false }
        let expected: GitHubRepo?
        if merge == "refs/pull/\(head.pullRequest.number)/head" {
            expected = origin.repo
        } else if merge == "refs/heads/\(head.branch)" {
            expected = head.isCrossRepository ? head.headRepo : origin.repo
        } else {
            expected = nil
        }
        guard let expected else { return false }
        // A branch's remote is a remote's name, or a URL, which is what gh pr checkout sets for a fork.
        if let named = await gitHubRemote(remote, repoPath: repoPath) {
            return named.repo.matches(expected)
        }
        return await github.repo(forRemote: remote)?.matches(expected) == true
    }

    /// Sets what a branch made from a PR's head tracks, the way gh pr checkout does, and returns warnings about pushing.
    /// A same-repo PR's branch tracks the head on origin. When maintainers can push to a fork, the branch pulls from and
    /// pushes to the fork. Otherwise it pulls the PR's head from origin, and cannot push.
    private func track(
        _ name: String, head: PullRequestHead, origin: GitHubRemote, fromPullRef: Bool, repoPath: String
    ) async throws -> [String] {
        let number = head.pullRequest.number
        var settings = [("remote", "origin"), ("merge", "refs/pull/\(number)/head")]
        var warnings: [String] = []
        if !fromPullRef {
            settings = [("remote", "origin"), ("merge", "refs/heads/\(head.branch)")]
            if name != head.branch {
                warnings.append(
                    "\(name) tracks origin/\(head.branch) under another name, so plain git push fails. "
                        + "Push with `git push origin HEAD:\(head.branch)`.")
            }
        } else if head.isCrossRepository, head.maintainerCanModify, let fork = head.headRepo,
            let url = fork.url(replacingRepoIn: origin.url)
        {
            settings = [("remote", url), ("pushRemote", url), ("merge", "refs/heads/\(head.branch)")]
            if name != head.branch {
                warnings.append(
                    "\(name) is named differently from the fork's branch \(head.branch), so plain git push fails. "
                        + "Push with `git push \(url) HEAD:\(head.branch)`.")
            }
        } else {
            let tracking = "\(name) tracks the PR on origin, where git pull works but git push does not."
            if !head.isCrossRepository {
                warnings.append("\(tracking) `git push -u origin HEAD:\(head.branch)` puts the branch back on origin.")
            } else {
                let reason =
                    head.headRepo.map { "\($0.owner)'s fork does not let maintainers push to it" }
                    ?? "The fork PR #\(number) came from is gone"
                warnings.append(
                    "\(reason), so \(tracking) To push, use a branch of your own: "
                        + "`git push -u origin HEAD:<new branch>`.")
            }
        }
        do {
            for (key, value) in settings {
                try await git.run(["config", "branch.\(name).\(key)", value], in: repoPath)
            }
        } catch let error as GitError {
            throw WorkspaceError.git(error)
        }
        return warnings
    }

    /// Saves the PR for a branch whose name cannot find it, so its row gets the PR's badge, and forgets any other.
    private func bind(_ name: String, to head: PullRequestHead, origin: GitHubRemote, repoPath: String) throws {
        guard let index = try? entryIndex(repoPath: repoPath) else { return }
        let binding =
            head.isCrossRepository || name != head.branch
            ? PRBinding(number: head.pullRequest.number, repo: origin.repo.nameWithOwner) : nil
        guard state.repos[index].prBindings[name] != binding else { return }
        state.repos[index].prBindings[name] = binding
        try save()
        _ = queuePullRequestRefresh(repoPath: repoPath)
    }
}
