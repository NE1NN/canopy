import Foundation

/// How an existing branch compares with what it is brought up to date with, and what may need the user.
struct BranchReport: Sendable, Equatable {
    var notes: [String] = []
    var warnings: [String] = []
    /// Set when the branch is only behind, so it can be fast-forwarded once its row has it checked out.
    var fastForward: FastForward?
}

struct FastForward: Sendable, Equatable {
    var branch: String
    var commit: String
    /// How messages show where `commit` came from, such as origin/feat/x.
    var name: String
    var count: Int
}

extension Workspace {
    /// The branch `name` finds under `prefix`, such as "refs/heads/", in its own spelling, or nil. Names that differ
    /// only in case share one ref file on a case-insensitive file system, where a branch made with the other spelling
    /// would hide a packed one, so any case finds the branch.
    func existingBranch(_ name: String, under prefix: String, repoPath: String) async -> String? {
        guard let listed = try? await git.run(["for-each-ref", "--format=%(refname)", prefix], in: repoPath) else {
            return nil
        }
        let refs = listed.split(separator: "\n").map(String.init)
        let ref =
            refs.first { $0 == prefix + name }
            ?? refs.first { $0.caseInsensitiveCompare(prefix + name) == .orderedSame }
        return ref.map { String($0.dropFirst(prefix.count)) }
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

    /// How the local `branch` compares with `target`, from one read of each. A branch that is only behind gets a
    /// fast-forward to run once its row has it checked out, where git knows no other worktree holds it. A branch with
    /// commits of its own is never moved. `name` is how messages show `target`, and `resetTo` is what the fix commands
    /// name.
    func compare(
        _ branch: String, with target: String, named name: String, resetTo: String, repoPath: String
    ) async -> BranchReport {
        func commit(_ ref: String) async -> String? {
            try? await git.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repoPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let local = await commit("refs/heads/\(branch)"), let other = await commit(target),
            let counts = try? await git.run(
                ["rev-list", "--left-right", "--count", "\(local)...\(other)"], in: repoPath),
            case let parts = counts.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }), parts.count == 2
        else { return BranchReport() }
        let (ahead, behind) = (parts[0], parts[1])
        switch (ahead, behind) {
        case (0, 0):
            return BranchReport()
        case (0, _):
            return BranchReport(
                fastForward: FastForward(branch: branch, commit: other, name: name, count: behind))
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
