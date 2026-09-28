import Foundation

/// What bringing an existing branch up to date did, and what may need the user.
struct BranchReport: Sendable, Equatable {
    var notes: [String] = []
    var warnings: [String] = []
}

extension Workspace {
    /// The branch `name` finds under `prefix`, such as "refs/heads/", in its own spelling, or nil. On a case-insensitive
    /// file system a loose ref typed in another case opens the same file, so `Feat` finds `feat`, and git would then
    /// check out a second name for one ref.
    func existingBranch(_ name: String, under prefix: String, repoPath: String) async -> String? {
        guard await git.succeeds(["show-ref", "--verify", "--quiet", prefix + name], in: repoPath) else { return nil }
        let listed =
            (try? await git.run(["for-each-ref", "--format=%(refname)", prefix], in: repoPath))?
            .split(separator: "\n").map(String.init) ?? []
        let ref =
            listed.first { $0 == prefix + name }
            ?? listed.first { $0.caseInsensitiveCompare(prefix + name) == .orderedSame } ?? prefix + name
        return String(ref.dropFirst(prefix.count))
    }

    /// The worktree that has `branch` checked out, as of the last refresh.
    func holder(of branch: String, repoPath: String) -> Row? {
        snapshot.repo(path: repoPath)?.allRows.first { $0.branch == branch }
    }

    /// Fails unless `branch` is free to check out, naming where it is checked out. A worktree whose folder was deleted
    /// still holds its branch until it is pruned, and git would refuse the add, so that one is pruned instead.
    func claim(branch: String, repoPath: String) async throws {
        await refresh(repoPath: repoPath)
        guard let holder = holder(of: branch, repoPath: repoPath) else { return }
        guard holder.isMissing else { throw WorkspaceError.branchCheckedOut(branch, row: holder) }
        try await pruneNow(repoPath: repoPath)
        if let holder = self.holder(of: branch, repoPath: repoPath) {
            throw WorkspaceError.branchCheckedOut(branch, row: holder)
        }
    }

    /// Fast-forwards the local `branch` to `target` when it is only behind, and says how the two compare otherwise.
    /// Never resets: a branch with commits of its own stays where it is. `name` is how messages show `target`, and
    /// `resetTo` is what the fix commands name.
    func bringUpToDate(
        _ branch: String, with target: String, named name: String, resetTo: String, repoPath: String
    ) async -> BranchReport {
        let local = "refs/heads/\(branch)"
        guard
            let counts = try? await git.run(
                ["rev-list", "--left-right", "--count", "\(local)...\(target)"], in: repoPath),
            case let parts = counts.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }), parts.count == 2
        else { return BranchReport() }
        let (ahead, behind) = (parts[0], parts[1])
        switch (ahead, behind) {
        case (0, 0):
            return BranchReport()
        case (0, _):
            do {
                let old = try await git.run(["rev-parse", local], in: repoPath).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let new = try await git.run(["rev-parse", "\(target)^{commit}"], in: repoPath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The old value makes the update fail rather than move a branch that changed since it was read.
                try await git.run(
                    ["update-ref", "-m", "canopy: fast-forward to \(name)", local, new, old], in: repoPath)
                return BranchReport(notes: ["Fast-forwarded \(branch) by \(Self.commits(behind)) to match \(name)."])
            } catch {
                return BranchReport(warnings: [
                    "Could not fast-forward \(branch) to \(name), so it starts as it was: \(error)"
                ])
            }
        case (_, 0):
            let verb = ahead == 1 ? "is" : "are"
            return BranchReport(notes: ["\(branch) has \(Self.commits(ahead)) that \(verb) not on \(name) yet."])
        default:
            let here = ahead == 1 ? "is" : "are"
            let there = behind == 1 ? "is" : "are"
            return BranchReport(warnings: [
                "\(branch) and \(name) have diverged: \(Self.commits(ahead)) here \(here) not on \(name), and "
                    + "\(Self.commits(behind)) on \(name) \(there) not here. Canopy left \(branch) as it was. "
                    + "To keep the local commits, run `git rebase \(resetTo)` in the row. "
                    + "To drop them, run `git reset --hard \(resetTo)`."
            ])
        }
    }

    /// A warning when `branch` tracks a remote branch that no longer exists, which usually means it was merged.
    func goneUpstreamWarning(_ branch: String, repoPath: String) async -> String? {
        guard
            let line = try? await git.run(
                ["for-each-ref", "--format=%(upstream:short)%00%(upstream:track)", "refs/heads/\(branch)"],
                in: repoPath)
        else { return nil }
        let fields = line.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == "[gone]" else { return nil }
        return "\(branch) tracked \(fields[0]), which is gone, so it was probably merged and deleted."
    }

    static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}
