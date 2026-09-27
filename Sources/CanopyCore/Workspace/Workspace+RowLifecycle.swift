import Foundation

public struct CreatedRow: Sendable, Equatable {
    public var row: Row
    public var warnings: [String]
}

extension Workspace {
    /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/.
    /// An existing local branch is checked out, a branch only on origin is tracked,
    /// and anything else is created from `base` (default: origin's default branch).
    public func createRow(repoPath: String, branch: String, base: String? = nil) async throws -> CreatedRow {
        try await serialized(repoPath: repoPath) {
            try await self.createRowNow(repoPath: repoPath, branch: branch, base: base)
        }
    }

    /// Removes a Canopy row's worktree, or un-adopts an adopted row without touching its files.
    public func removeRow(path: String, force: Bool = false, deleteBranch: Bool = false) async throws {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        try await serialized(repoPath: row.repoPath) {
            try await self.removeRowNow(path: path, force: force, deleteBranch: deleteBranch)
        }
    }

    private func createRowNow(repoPath: String, branch: String, base: String?) async throws -> CreatedRow {
        let index = try entryIndex(repoPath: repoPath)
        let dirName = state.repos[index].dirName
        var warnings: [String] = []

        guard await git.succeeds(["check-ref-format", "--branch", branch], in: repoPath) else {
            throw WorkspaceError.invalidBranch(branch)
        }
        if snapshot.repo(path: repoPath)?.allRows.contains(where: { $0.branch == branch }) == true {
            throw WorkspaceError.branchCheckedOut(branch)
        }

        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
        if hasOrigin {
            do {
                try await git.run(["fetch", "--quiet", "origin"], in: repoPath)
            } catch {
                warnings.append("git fetch failed, so the row starts from local refs: \(error)")
            }
        }

        let parent = home.worktreesRoot.appending(path: dirName)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = BranchSlug.folder(for: branch, in: parent) { FileManager.default.fileExists(atPath: $0.path) }

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
                start = base
            } else {
                start = await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin)
            }
            arguments += ["--no-track", "-b", branch, folder.path, start]
        }

        do {
            try await git.run(arguments, in: repoPath)
        } catch let error as GitError {
            if error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree") {
                throw WorkspaceError.branchCheckedOut(branch)
            }
            throw WorkspaceError.git(error)
        }

        let path = Paths.canonical(folder.path)
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
            if deleteBranch, let branch = row.branch {
                do {
                    try await git.run(["branch", "-D", branch], in: row.repoPath)
                } catch let error as GitError {
                    throw WorkspaceError.git(error)
                }
            }
            if let index = try? entryIndex(repoPath: row.repoPath) {
                state.repos[index].rowOrder.removeAll { $0 == path }
            }
            if state.selectedRowPath == path {
                state.selectedRowPath = nil
            }
            try save()
            await refresh(repoPath: row.repoPath)
        }
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
