import Foundation

public struct CreatedRow: Sendable, Equatable {
    public var row: Row
    public var warnings: [String]
}

struct FetchAttempt: Sendable {
    var finishedAt: ContinuousClock.Instant
    var warning: String?
}

extension Workspace {
    /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/.
    /// An existing local branch is checked out, a branch only on origin is tracked,
    /// and anything else is created from `base` (default: origin's default branch).
    public func createRow(repoPath: String, branch: String, base: String? = nil) async throws -> CreatedRow {
        let requestedAt = ContinuousClock.now
        return try await serialized(repoPath: repoPath) {
            try await self.createRowNow(repoPath: repoPath, branch: branch, base: base, requestedAt: requestedAt)
        }
    }

    /// Removes a Canopy row's worktree, or un-adopts an adopted row without touching its files.
    public func removeRow(path: String, force: Bool = false, deleteBranch: Bool = false) async throws {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        try await serialized(repoPath: row.repoPath) {
            try await self.removeRowNow(path: path, force: force, deleteBranch: deleteBranch)
        }
    }

    private func createRowNow(
        repoPath: String,
        branch: String,
        base: String?,
        requestedAt: ContinuousClock.Instant
    ) async throws -> CreatedRow {
        let index = try entryIndex(repoPath: repoPath)
        let dirName = state.repos[index].dirName
        var warnings: [String] = []

        guard FileManager.default.fileExists(atPath: repoPath) else {
            throw WorkspaceError.pathNotFound(repoPath)
        }
        // `--branch` would expand "@{-1}" to the previous branch, and a leading "-" would read as an option.
        guard !branch.hasPrefix("-"), branch != "HEAD",
            await git.succeeds(["check-ref-format", "refs/heads/\(branch)"], in: repoPath)
        else {
            throw WorkspaceError.invalidBranch(branch)
        }
        if snapshot.repo(path: repoPath)?.allRows.contains(where: { $0.branch == branch }) == true {
            throw WorkspaceError.branchCheckedOut(branch)
        }

        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
        if hasOrigin, let warning = await fetchUnlessFresh(repoPath: repoPath, since: requestedAt) {
            warnings.append(warning)
        }

        // A worktree whose folder was deleted keeps its path until it is pruned, so git would refuse to reuse it.
        await refresh(repoPath: repoPath)
        let registered = Set(snapshot.repo(path: repoPath)?.allRows.map(\.path) ?? [])
        let parent = home.worktreesRoot.appending(path: dirName)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = BranchSlug.folder(for: branch, in: parent) {
            registered.contains(Paths.canonical($0.path)) || FileManager.default.fileExists(atPath: $0.path)
        }

        var arguments = ["worktree", "add"]
        if await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoPath) {
            arguments += [folder.path, branch]
        } else if hasOrigin,
            await git.succeeds(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: repoPath)
        {
            arguments += ["--track", "-b", branch, folder.path, "origin/\(branch)"]
        } else {
            let start: String
            if let base {
                guard !base.hasPrefix("-"),
                    await git.succeeds(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoPath)
                else {
                    throw WorkspaceError.invalidBase(base)
                }
                start = base
            } else {
                start = await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin)
            }
            arguments += ["--no-track", "-b", branch, folder.path, start]
        }

        let path = Paths.canonical(folder.path)
        do {
            try await git.run(arguments, in: repoPath)
        } catch let error as GitError {
            if error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree") {
                throw WorkspaceError.branchCheckedOut(branch)
            }
            // A failing post-checkout hook makes git exit non-zero after the worktree is complete.
            await refresh(repoPath: repoPath)
            guard snapshot.row(path: path)?.branch == branch else { throw WorkspaceError.git(error) }
            warnings.append("git worktree add reported an error, but the worktree was created: \(error)")
        }

        if let current = try? entryIndex(repoPath: repoPath), !state.repos[current].rowOrder.contains(path) {
            state.repos[current].rowOrder.append(path)
            try save()
        }
        await refresh(repoPath: repoPath)
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        return CreatedRow(row: row, warnings: warnings)
    }

    private func removeRowNow(path: String, force: Bool, deleteBranch: Bool) async throws {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        switch row.rowClass {
        case .main:
            throw WorkspaceError.cannotRemoveMain
        case .external:
            throw WorkspaceError.notManaged(path)
        case .adopted:
            try await unadopt(path: path)
        case .canopy:
            var arguments = ["worktree", "remove"]
            if force { arguments.append("--force") }
            arguments.append(path)
            do {
                try await git.run(arguments, in: row.repoPath)
            } catch let error as GitError {
                if error.stderr.contains("modified or untracked files") {
                    throw WorkspaceError.worktreeDirty(path)
                }
                throw WorkspaceError.git(error)
            }
            if let index = try? entryIndex(repoPath: row.repoPath) {
                state.repos[index].rowOrder.removeAll { $0 == path }
            }
            if state.selectedRowPath == path {
                state.selectedRowPath = nil
            }
            try save()
            await refresh(repoPath: row.repoPath)
            // Last, so a branch that cannot be deleted still leaves the row fully removed.
            if deleteBranch, let branch = row.branch {
                do {
                    try await git.run(["branch", "-D", branch], in: row.repoPath)
                } catch let error as GitError {
                    throw WorkspaceError.git(error)
                }
            }
        }
    }

    /// Whether `git worktree remove` would refuse the row without `--force`: modified or untracked files.
    public func hasUncommittedChanges(path: String) async throws -> Bool {
        do {
            return !(try await git.run(["status", "--porcelain", "-z"], in: path)).isEmpty
        } catch let error as GitError {
            throw WorkspaceError.git(error)
        }
    }

    /// Parallel creates queue behind each other, so a fetch that finished after this request was made
    /// already covers it. Its outcome, including a failure, is reused rather than waiting on the network again.
    private func fetchUnlessFresh(repoPath: String, since requestedAt: ContinuousClock.Instant) async -> String? {
        if let attempt = lastFetch[repoPath], attempt.finishedAt > requestedAt {
            return attempt.warning
        }
        var warning: String?
        do {
            try await git.run(["fetch", "--quiet", "origin"], in: repoPath, timeout: fetchTimeout)
        } catch let error as GitError where error.timedOut {
            warning = "git fetch timed out, so the row starts from local refs."
        } catch {
            warning = "git fetch failed, so the row starts from local refs: \(error)"
        }
        lastFetch[repoPath] = FetchAttempt(finishedAt: .now, warning: warning)
        return warning
    }

    func entryIndex(repoPath: String) throws -> Int {
        guard let index = state.repos.firstIndex(where: { $0.path == repoPath }) else {
            throw WorkspaceError.repoNotFound(repoPath)
        }
        return index
    }

    func defaultBase(repoPath: String, hasOrigin: Bool) async -> String {
        if hasOrigin,
            let head = try? await git.run(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repoPath)
        {
            return head.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "HEAD"
    }
}
