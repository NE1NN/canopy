import CanopyAgents
import CanopyGit
import CanopySystem
import CanopyWire
import Foundation

extension BoxDaemon {
    /// How long a fetch before making a row may take.
    static let fetchTimeout = Duration.seconds(60)

    /// Makes a row by the Mac's branch rules: a branch the clone has, fast-forwarded when it is only behind origin,
    /// then origin's, then a new one from `base` or origin's default branch, in `~/.canopy/worktrees/<repo>/`.
    public func rowNew(_ params: BoxRowNewParams) async throws -> BoxRowNewResult {
        let requestedAt = ContinuousClock.now
        let clone = try clonePath(of: params.repo)
        return try await inQueue(clone) {
            try await self.rowNewNow(
                params, repo: self.repoName(params.repo) ?? params.repo, clone: clone, since: requestedAt)
        }
    }

    /// Removes a row's worktree, ends its panes, and forgets it. A missing row's worktree is pruned.
    @discardableResult
    public func rowRemove(_ params: BoxRowRemoveParams) async throws -> [String] {
        let path = Paths.canonical(params.path)
        if isMain(path) { throw BoxErrors.cannotRemoveMain }
        guard let row = state.rows.first(where: { $0.path == path }) else { throw BoxErrors.rowNotFound(params.path) }
        if !params.force {
            let running = state.panes.filter { $0.rowPath == path }.compactMap { pane in
                activity[pane.id].flatMap { $0.busy ? ($0.foreground ?? "A program") : nil }
            }
            var seen = Set<String>()
            let programs = running.filter { seen.insert($0).inserted }
            if !programs.isEmpty {
                throw BoxErrors.rowBusy(row.branch ?? (row.path as NSString).lastPathComponent, programs: programs)
            }
        }
        guard config != nil else { throw BoxErrors.notConfigured() }
        // A repo taken out of the settings still has its rows, removed through the worktree's own clone.
        let known = try? clonePath(of: row.repo)
        let found: String? =
            if let known { known } else { await cloneHolding(row.path) }
        guard let clone = found else {
            await forgetRow(row)
            return [
                "\(row.repo) is no longer in this host's settings and the row's folder is gone, so it was forgotten."
            ]
        }
        return try await inQueue(clone) {
            try await self.rowRemoveNow(row, clone: clone, force: params.force, deleteBranch: params.deleteBranch)
        }
    }

    /// The clone a worktree belongs to, from its git directory, or nil when the folder is gone or not one.
    private func cloneHolding(_ worktree: String) async -> String? {
        guard FileManager.default.fileExists(atPath: worktree),
            let common = try? await git(worktree).run(["rev-parse", "--git-common-dir"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !common.isEmpty
        else { return nil }
        let gitDirectory = common.hasPrefix("/") ? common : worktree + "/" + common
        return Paths.canonical((gitDirectory as NSString).deletingLastPathComponent)
    }

    private func forgetRow(_ row: StoredRow) async {
        for pane in state.panes where pane.rowPath == row.path { await tmux.killSession(pane.id) }
        state.panes.removeAll { $0.rowPath == row.path }
        state.rows.removeAll { $0.path == row.path }
        state.prs[row.path] = nil
        changed()
        wakeWaiters()
    }

    /// The repo's name as config.json spells it, matching any case.
    func repoName(_ name: String) -> String? {
        guard let repos = config?.repos else { return nil }
        if repos[name] != nil { return name }
        return repos.keys.sorted().first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func clonePath(of repo: String) throws -> String {
        guard config != nil else { throw BoxErrors.notConfigured() }
        guard let name = repoName(repo), let path = config?.repos[name] else { throw BoxErrors.repoNotFound(repo) }
        return Paths.canonical(path)
    }

    /// Runs `work` after everything queued for the clone before it, so rows made and removed in one clone never race.
    func inQueue<T: Sendable>(_ clone: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = cloneQueues[clone]
        let task = Task {
            await previous?.value
            return try await work()
        }
        cloneQueues[clone] = Task { _ = try? await task.value }
        return try await task.value
    }

    private func rowNewNow(
        _ params: BoxRowNewParams, repo: String, clone: String, since requestedAt: ContinuousClock.Instant
    )
        async throws -> BoxRowNewResult
    {
        let git = git(clone)
        let rules = BranchRules(clone: git)
        return try await BoxErrors.mapped {
            try await rules.requireValidName(params.branch)
            await reconcile()
            try refuseIfCheckedOut(params.branch, repo: repo)
            var warnings: [String] = []
            let hasOrigin = await git.succeeds(["remote", "get-url", "origin"])
            var fetchFailure: String?
            if hasOrigin {
                fetchFailure = await fetchUnlessFresh(git, since: requestedAt)
                if let fetchFailure { warnings.append("\(fetchFailure), so the row starts from local refs.") }
            }
            let choice = try await rules.choose(
                params.branch, base: params.base, existing: params.existing, hasOrigin: hasOrigin,
                fetchFailure: fetchFailure)
            if choice.branch != params.branch { try refuseIfCheckedOut(choice.branch, repo: repo) }
            let parent = paths.worktrees(repo: repo)
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let known = Set(allRows.map(\.path))
            let folder = Paths.canonical(
                BranchSlug.folder(for: choice.branch, in: URL(fileURLWithPath: parent)) {
                    known.contains(Paths.canonical($0.path)) || FileManager.default.fileExists(atPath: $0.path)
                }.path)
            makingRows.insert(folder)
            defer { makingRows.remove(folder) }
            do {
                try await git.run(["worktree", "add", "--quiet"] + choice.worktreeArguments(folder: folder))
            } catch let error as GitError
                where error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree")
            {
                throw BoxErrors.checkedOutElsewhere(choice.branch)
            }
            state.rows.removeAll { $0.path == folder }
            state.rows.append(StoredRow(path: folder, repo: repo, branch: choice.branch))
            var notes = choice.notes
            let worktree = git.at(folder)
            if let step = choice.fastForward {
                do {
                    try await worktree.run(["merge", "--ff-only", "--quiet", step.commit])
                    notes.append(
                        "Fast-forwarded \(step.branch) by \(BranchRules.commits(step.count)) to match \(step.name).")
                } catch {
                    warnings.append(
                        "Could not fast-forward \(step.branch) to \(step.name), so it starts as it was: \(error)")
                }
            }
            let head = try? await worktree.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = state.rows.firstIndex(where: { $0.path == folder }) { state.rows[index].head = head }
            changed()
            let row = boxRow(state.rows.first { $0.path == folder } ?? StoredRow(path: folder, repo: repo))
            return BoxRowNewResult(
                row: row, source: choice.source, base: choice.start, notes: notes, warnings: warnings + choice.warnings)
        }
    }

    /// Fails when a row of the repo that is not missing has the branch checked out.
    private func refuseIfCheckedOut(_ branch: String, repo: String) throws {
        guard let holder = allRows.first(where: { $0.repo == repo && $0.branch == branch && !$0.missing }) else {
            return
        }
        throw isMain(holder.path)
            ? BoxErrors.checkedOut(branch, mainAt: holder.path) : BoxErrors.checkedOut(branch, rowAt: holder.path)
    }

    /// Rows made together share one fetch: one that finished after this request was made covers it, failure and all.
    private func fetchUnlessFresh(_ git: GitClone, since requestedAt: ContinuousClock.Instant) async -> String? {
        if let last = lastFetch[git.path], last.finishedAt > requestedAt { return last.failure }
        var failure: String?
        do {
            try await git.run(["fetch", "--quiet", "--prune", "origin"], timeout: Self.fetchTimeout)
        } catch let error as GitError where error.timedOut {
            failure = "git fetch timed out"
        } catch {
            failure = "git fetch failed: \(error)"
        }
        lastFetch[git.path] = (.now, failure)
        return failure
    }

    private func rowRemoveNow(_ row: StoredRow, clone: String, force: Bool, deleteBranch: Bool) async throws
        -> [String]
    {
        let git = git(clone)
        try await BoxErrors.mapped {
            if row.missing || !FileManager.default.fileExists(atPath: row.path) {
                try await git.run(["worktree", "prune"])
            } else {
                do {
                    try await git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [row.path])
                } catch let error as GitError where error.stderr.contains("modified or untracked files") {
                    throw BoxErrors.worktreeDirty(row.path)
                }
            }
        }
        for pane in state.panes where pane.rowPath == row.path {
            await tmux.killSession(pane.id)
        }
        state.panes.removeAll { $0.rowPath == row.path }
        state.rows.removeAll { $0.path == row.path }
        state.prs[row.path] = nil
        changed()
        wakeWaiters()
        guard deleteBranch, let branch = row.branch else { return [] }
        do {
            try await git.run(["branch", "-D", branch])
        } catch {
            return ["Removed the row, but could not delete branch \(branch): \(error)"]
        }
        return []
    }
}
