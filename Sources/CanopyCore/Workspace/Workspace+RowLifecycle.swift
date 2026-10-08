import Foundation

/// Where a new row's branch came from.
public enum BranchSource: String, Codable, Sendable {
    /// A local branch was checked out.
    case local
    /// A branch on origin was checked out as a new local branch tracking it.
    case origin
    /// Nothing matched, so a new branch was created.
    case new
}

public struct CreatedRow: Sendable, Equatable {
    public var row: Row
    public var source: BranchSource
    /// Where a new branch started, such as origin/main.
    public var base: String?
    /// The pull request the row was started from.
    public var pullRequest: PullRequest?
    /// What Canopy did along the way, such as fast-forwarding the branch.
    public var notes: [String]
    /// What may need fixing, such as a branch that has diverged from origin.
    public var warnings: [String]
}

/// The group a row being created goes into.
struct JoiningGroup: Sendable, Equatable {
    var repoPath: String
    var group: String
}

struct FetchAttempt: Sendable {
    var finishedAt: ContinuousClock.Instant
    /// Why the fetch failed, such as "git fetch timed out".
    var failure: String?
}

extension Workspace {
    /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/. An existing local branch is checked out,
    /// after a fast-forward if it is only behind origin. A branch only on origin is tracked. Anything else is created
    /// from `base` (default: origin's default branch), unless `existing` asks to fail instead.
    /// With `group`, the row goes straight to the end of that group, which must exist. With `link`, the row is tied to
    /// a plugin's item, which the caller has already resolved.
    public func createRow(
        repoPath: String, branch: String, base: String? = nil, existing: Bool = false, group: String? = nil,
        link: PluginLink? = nil
    ) async throws -> CreatedRow {
        let requestedAt = ContinuousClock.now
        return try await createRow(repoPath: repoPath, joining: group) {
            try await self.createRowNow(
                repoPath: repoPath, branch: branch, base: base, existing: existing, group: group, link: link,
                requestedAt: requestedAt)
        }
    }

    /// Runs `create` in the repo's git queue, then logs the new row's move into the group it joined. `create` checks
    /// the group again once it is its turn, since the group can go away while it waits.
    func createRow(
        repoPath: String, joining group: String?, _ create: @escaping @Sendable () async throws -> CreatedRow
    ) async throws -> CreatedRow {
        if let group {
            _ = try joiningGroup(group, repoPath: repoPath)
        }
        var created = try await serialized(repoPath: repoPath, create)
        // After `create`, which logged the row's creation, so its move into the group is logged second.
        if let joining = rowsJoiningGroups.removeValue(forKey: created.row.path) {
            created.row = snapshot.row(path: created.row.path) ?? created.row
            if let joined = created.row.group {
                record(ActivityType.rowMoved, created.row, data: ["from": .null, "to": .string(joined)])
            } else if !groupExists(joining.group, repoPath: repoPath) {
                created.warnings.append(
                    "Group \(joining.group) went away while the row was being created, so the row is ungrouped.")
            }
        }
        return created
    }

    /// Removes a Canopy row's worktree, or un-adopts an adopted row without touching its files.
    /// Returns warnings about what failed after the row was gone, such as deleting its branch.
    @discardableResult
    public func removeRow(path: String, force: Bool = false, deleteBranch: Bool = false) async throws -> [String] {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        return try await serialized(repoPath: row.repoPath) {
            try await self.removeRowNow(path: path, force: force, deleteBranch: deleteBranch)
        }
    }

    private func createRowNow(
        repoPath: String,
        branch requested: String,
        base: String?,
        existing: Bool,
        group: String?,
        link: PluginLink?,
        requestedAt: ContinuousClock.Instant
    ) async throws -> CreatedRow {
        _ = try entryIndex(repoPath: repoPath)
        let joining = try group.map { try joiningGroup($0, repoPath: repoPath) }
        guard FileManager.default.fileExists(atPath: repoPath) else {
            throw WorkspaceError.pathNotFound(repoPath)
        }
        try await requireValidBranchName(requested, repoPath: repoPath)
        // Fails before fetching, since a row that has the branch will still have it after. The snapshot trails a
        // checkout that just switched branch by a moment, so a refusal waits for a fresh look.
        if holder(of: requested, repoPath: repoPath) != nil {
            await refresh(repoPath: repoPath)
            if let holder = holder(of: requested, repoPath: repoPath), !holder.isMissing {
                throw WorkspaceError.branchCheckedOut(requested, row: holder)
            }
        }

        var notes: [String] = []
        var warnings: [String] = []
        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
        var fetchFailure: String?
        if hasOrigin {
            fetchFailure = await fetchUnlessFresh(repoPath: repoPath, since: requestedAt)
            if let fetchFailure { warnings.append("\(fetchFailure), so the row starts from local refs.") }
        }

        let branch: String
        let source: BranchSource
        var start: String?
        if let local = await existingBranch(requested, under: "refs/heads/", repoPath: repoPath) {
            (branch, source) = (local, .local)
        } else if hasOrigin,
            let remote = await existingBranch(requested, under: "refs/remotes/origin/", repoPath: repoPath)
        {
            (branch, source) = (remote, .origin)
        } else {
            guard !existing else { throw WorkspaceError.branchNotFound(requested, fetchFailure: fetchFailure) }
            (branch, source) = (requested, .new)
            start = try await startPoint(base, in: RepoGit(git: git, path: repoPath), hasOrigin: hasOrigin)
        }
        if source != .local {
            // A PR bound to an old branch of this name is not the new branch's.
            try forgetPullRequest(of: branch, repoPath: repoPath)
        }
        if branch != requested {
            notes.append("Using \(branch), the branch's own spelling.")
        }
        try await claim(branch: branch, repoPath: repoPath)

        var fastForward: FastForward?
        if source == .local, hasOrigin {
            let remote = "refs/remotes/origin/\(branch)"
            if await git.succeeds(["show-ref", "--verify", "--quiet", remote], in: repoPath) {
                let report = await compare(
                    branch, with: remote, named: "origin/\(branch)", resetTo: "origin/\(branch)", repoPath: repoPath)
                notes += report.notes
                warnings += report.warnings
                fastForward = report.fastForward
            } else if fetchFailure == nil, let warning = await goneUpstreamWarning(branch, repoPath: repoPath) {
                warnings.append(warning)
            }
        }

        let added = try await addRow(
            repoPath: repoPath, branch: branch, joining: joining, link: link, fastForward: fastForward
        ) { folder in
            switch source {
            case .local: [folder, branch]
            case .origin: ["--track", "-b", branch, folder, "origin/\(branch)"]
            case .new: ["--no-track", "-b", branch, folder, start ?? "HEAD"]
            }
        }
        return CreatedRow(
            row: added.row, source: source, base: start, pullRequest: nil, notes: notes + added.report.notes,
            warnings: warnings + added.report.warnings)
    }

    func requireValidBranchName(_ branch: String, repoPath: String) async throws {
        try await requireValidBranchName(branch, in: RepoGit(git: git, path: repoPath))
    }

    /// A host that cannot be reached fails as such, not as a bad name.
    func requireValidBranchName(_ branch: String, in clone: RepoGit) async throws {
        guard !branch.hasPrefix("-"), branch != "HEAD",
            try await clone.succeedsOnHost(["check-ref-format", "refs/heads/\(branch)"])
        else { throw WorkspaceError.invalidBranch(branch) }
    }

    func isValidBranchName(_ branch: String, repoPath: String) async -> Bool {
        await isValidBranchName(branch, in: RepoGit(git: git, path: repoPath))
    }

    /// `--branch` would expand "@{-1}" to the previous branch, and a leading "-" would read as an option.
    func isValidBranchName(_ branch: String, in clone: RepoGit) async -> Bool {
        guard !branch.hasPrefix("-"), branch != "HEAD" else { return false }
        return await clone.succeeds(["check-ref-format", "refs/heads/\(branch)"])
    }

    func startPoint(_ base: String?, in clone: RepoGit, hasOrigin: Bool) async throws -> String {
        guard let base else { return await defaultBase(in: clone, hasOrigin: hasOrigin) }
        guard !base.hasPrefix("-"), await clone.succeeds(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"])
        else {
            throw WorkspaceError.invalidBase(base)
        }
        return base
    }

    /// Runs `git worktree add` into a new folder under the repo's Canopy folder, then `fastForward` in it, and lists
    /// the row last among the repo's rows, or last in the group it is `joining`, and tied to `link`'s item.
    /// `arguments` gets the folder and returns what follows `worktree add`. The report says how the fast-forward went,
    /// and warns when a checkout hook failed after git had made the worktree.
    func addRow(
        repoPath: String, branch: String, joining: String? = nil, link: PluginLink? = nil,
        fastForward: FastForward? = nil, arguments: (String) -> [String]
    ) async throws -> (row: Row, report: BranchReport) {
        let dirName = state.repos[try entryIndex(repoPath: repoPath)].dirName
        // A worktree whose folder was deleted keeps its path until it is pruned, so git would refuse to reuse it.
        await refresh(repoPath: repoPath)
        let registered = Set(snapshot.repo(path: repoPath)?.allRows.map(\.path) ?? [])
        let parent = home.worktreesRoot.appending(path: dirName)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = BranchSlug.folder(for: branch, in: parent) {
            registered.contains(Paths.canonical($0.path)) || FileManager.default.fileExists(atPath: $0.path)
        }

        let path = Paths.canonical(folder.path)
        rowsJoiningGroups[path] = joining.map { JoiningGroup(repoPath: repoPath, group: $0) }
        // `createRow` takes the path back out once it has logged the move, unless creating the row fails.
        var created = false
        defer { if !created { rowsJoiningGroups[path] = nil } }
        changingRows[path] = .current
        rowsBeingLinked[path] = link
        defer { finishChanging([path], repoPath: repoPath) }
        var report = BranchReport()
        do {
            try await git.run(["worktree", "add"] + arguments(folder.path), in: repoPath)
        } catch let error as GitError {
            if error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree") {
                await refresh(repoPath: repoPath)
                throw WorkspaceError.branchCheckedOut(branch, row: holder(of: branch, repoPath: repoPath))
            }
            // A failing post-checkout hook makes git exit non-zero after the worktree is complete.
            await refresh(repoPath: repoPath)
            guard snapshot.row(path: path)?.branch == branch else { throw WorkspaceError.git(error) }
            report.warnings.append("git worktree add reported an error, but the worktree was created: \(error)")
        }

        if let current = try? entryIndex(repoPath: repoPath), !state.repos[current].holds(path) {
            state.repos[current].place(path, joining: rowsJoiningGroups[path]?.group)
        }
        if let link {
            state.plugins[link.plugin, default: PluginEntry()].links[path] = link.item
        }
        try save()
        await refresh(repoPath: repoPath)
        guard var row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        created = true
        if let fastForward {
            let done = await self.fastForward(fastForward, in: row)
            report.notes += done.notes
            report.warnings += done.warnings
            row = snapshot.row(path: path) ?? row
        }
        return (row, report)
    }

    private func removeRowNow(path: String, force: Bool, deleteBranch: Bool) async throws -> [String] {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        switch row.rowClass {
        case .main:
            throw WorkspaceError.cannotRemoveMain
        case .external:
            throw WorkspaceError.notManaged(path)
        case .remote:
            return try await removeRemoteRow(standIn: path, force: force, deleteBranch: deleteBranch)
        case .adopted:
            try await unadopt(path: path)
            return []
        case .canopy:
            var arguments = ["worktree", "remove"]
            if force { arguments.append("--force") }
            arguments.append(path)
            changingRows[path] = .current
            defer { finishChanging([path], repoPath: row.repoPath) }
            do {
                try await git.run(arguments, in: row.repoPath)
            } catch let error as GitError {
                // git may have removed part of the row before it failed.
                await refresh(repoPath: row.repoPath)
                if error.stderr.contains("modified or untracked files") {
                    throw WorkspaceError.worktreeDirty(path)
                }
                throw WorkspaceError.git(error)
            }
            if let index = try? entryIndex(repoPath: row.repoPath) {
                state.repos[index].forget(path)
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
                } catch {
                    return ["Removed the row, but could not delete branch \(branch): \(error)"]
                }
                try? forgetPullRequest(of: branch, repoPath: row.repoPath)
            }
            return []
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
    /// Returns why the fetch failed, or nil. Pruning drops branches deleted on origin, which are no longer on it.
    func fetchUnlessFresh(repoPath: String, since requestedAt: ContinuousClock.Instant) async -> String? {
        await fetchUnlessFresh(RepoGit(git: git, path: repoPath), key: repoPath, since: requestedAt)
    }

    /// `key` names the clone among every clone Canopy fetches, here and on hosts.
    func fetchUnlessFresh(_ clone: RepoGit, key: String, since requestedAt: ContinuousClock.Instant) async -> String? {
        if let attempt = lastFetch[key], attempt.finishedAt > requestedAt {
            return attempt.failure
        }
        var failure: String?
        do {
            try await clone.run(["fetch", "--quiet", "--prune", "origin"], timeout: fetchTimeout)
        } catch let error as GitError where error.hostUnreachable {
            failure = "git fetch could not reach the host: \(error)"
        } catch let error as GitError where error.timedOut {
            failure = "git fetch timed out"
        } catch {
            failure = "git fetch failed: \(error)"
        }
        lastFetch[key] = FetchAttempt(finishedAt: .now, failure: failure)
        return failure
    }

    /// Whether the repo still has a group of that name. A row being created into it may have been moved out since.
    private func groupExists(_ name: String, repoPath: String) -> Bool {
        state.repos.first { $0.path == repoPath }?.groupIndex(named: name) != nil
    }

    /// The stored name of the group a new row is to join, which must exist.
    func joiningGroup(_ name: String, repoPath: String) throws -> String {
        let index = try entryIndex(repoPath: repoPath)
        let entry = state.repos[index]
        return entry.groups[try entry.requireGroup(name, repo: repoName(repoPath))].name
    }

    func entryIndex(repoPath: String) throws -> Int {
        guard let index = state.repos.firstIndex(where: { $0.path == repoPath }) else {
            throw WorkspaceError.repoNotFound(repoPath)
        }
        return index
    }

    func defaultBase(repoPath: String, hasOrigin: Bool) async -> String {
        await defaultBase(in: RepoGit(git: git, path: repoPath), hasOrigin: hasOrigin)
    }

    func defaultBase(in clone: RepoGit, hasOrigin: Bool) async -> String {
        guard hasOrigin, let branch = await defaultBranch(in: clone) else { return "HEAD" }
        return "origin/" + branch
    }

    /// The branch `origin/HEAD` points at, such as `main`, or nil when the repo has none.
    public nonisolated func defaultBranch(repoPath: String) async -> String? {
        await defaultBranch(in: RepoGit(git: git, path: repoPath))
    }

    nonisolated func defaultBranch(in clone: RepoGit) async -> String? {
        guard let head = try? await clone.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        else { return nil }
        let name = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasPrefix("origin/"), name.count > "origin/".count else { return nil }
        return String(name.dropFirst("origin/".count))
    }
}
