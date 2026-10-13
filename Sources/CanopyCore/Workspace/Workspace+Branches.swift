import Foundation

extension GitClone {
    /// A clone git runs in through `git`: this Mac's, or one on a host, through the host's master.
    init(git: GitRunner, path: String) {
        self.init(path: path) { arguments, folder, timeout in
            try await git.run(arguments, in: folder, timeout: timeout)
        }
    }
}

extension Workspace {
    /// The clone of a repo on this Mac.
    nonisolated func localClone(_ repoPath: String) -> GitClone {
        GitClone(git: git, path: repoPath)
    }

    nonisolated func branchRules(_ repoPath: String) -> BranchRules {
        BranchRules(clone: localClone(repoPath))
    }

    /// The branch `name` finds under `prefix`, such as "refs/heads/", in its own spelling, or nil.
    func existingBranch(_ name: String, under prefix: String, repoPath: String) async -> String? {
        try? await branchRules(repoPath).existingBranch(name, under: prefix)
    }

    /// The worktree on this Mac, or on `host`, that has `branch` checked out, as of the last refresh. Each machine's
    /// git only knows its own worktrees, so a row elsewhere never holds the branch.
    func holder(of branch: String, repoPath: String, host: String? = nil) -> Row? {
        snapshot.repo(path: repoPath)?.allRows.first { $0.branch == branch && $0.host == host }
    }

    /// Fails unless `branch` is free to check out, naming where it is checked out. A worktree whose folder was deleted
    /// still holds its branch, and git would refuse the add, so git forgets that one worktree. Other missing rows stay
    /// until the user prunes them.
    func claim(branch: String, repoPath: String) async throws {
        await refresh(repoPath: repoPath)
        guard let holder = holder(of: branch, repoPath: repoPath) else { return }
        guard holder.isMissing else { throw WorkspaceError.branchCheckedOut(branch, row: holder) }
        changingRows[holder.path] = .current
        defer { finishChanging([holder.path], repoPath: repoPath) }
        do {
            try await git.run(["worktree", "remove", holder.path], in: repoPath)
        } catch {
            await refresh(repoPath: repoPath)
            throw WorkspaceError.branchCheckedOut(branch, row: holder)
        }
        await refresh(repoPath: repoPath)
    }

    /// How the local `branch` compares with `target`, as `BranchRules.compare` says.
    func compare(
        _ branch: String, with target: String, named name: String, resetTo: String, repoPath: String
    ) async -> BranchReport {
        await branchRules(repoPath).compare(branch, with: target, named: name, resetTo: resetTo)
    }

    /// Runs a fast-forward `compare` asked for, in the row that now has the branch checked out.
    func fastForward(_ step: FastForward, in row: Row) async -> BranchReport {
        do {
            try await git.run(["merge", "--ff-only", "--quiet", step.commit], in: row.path)
            await refresh(repoPath: row.repoPath)
            return BranchReport(
                notes: ["Fast-forwarded \(step.branch) by \(Self.commits(step.count)) to match \(step.name)."])
        } catch {
            return BranchReport(
                warnings: ["Could not fast-forward \(step.branch) to \(step.name), so it starts as it was: \(error)"])
        }
    }

    static func commits(_ count: Int) -> String {
        BranchRules.commits(count)
    }

    /// Runs `body`, turning `row new`'s branch rules refusing a branch into the workspace's errors.
    func branchErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as BranchError {
            switch error {
            case .invalidBranch(let name): throw WorkspaceError.invalidBranch(name)
            case .invalidBase(let base): throw WorkspaceError.invalidBase(base)
            case .branchNotFound(let name, let failure):
                throw WorkspaceError.branchNotFound(name, fetchFailure: failure)
            }
        }
    }
}
