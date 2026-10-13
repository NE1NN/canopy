import CanopyWire
import Foundation

/// Why `row new`'s branch rules refused a branch.
public enum BranchError: Error, Sendable, Equatable {
    case invalidBranch(String)
    case invalidBase(String)
    /// `existing` asked for a branch that is neither local nor on origin. `fetchFailure` says why origin may be stale.
    case branchNotFound(String, fetchFailure: String?)
}

/// How an existing branch compares with what it is brought up to date with, and what may need the user.
public struct BranchReport: Sendable, Equatable {
    public var notes: [String] = []
    public var warnings: [String] = []
    /// Set when the branch is only behind, so it can be fast-forwarded once its row has it checked out.
    public var fastForward: FastForward?

    public init(notes: [String] = [], warnings: [String] = [], fastForward: FastForward? = nil) {
        self.notes = notes
        self.warnings = warnings
        self.fastForward = fastForward
    }
}

public struct FastForward: Sendable, Equatable {
    public var branch: String
    public var commit: String
    /// How messages show where `commit` came from, such as origin/feat/x.
    public var name: String
    public var count: Int

    public init(branch: String, commit: String, name: String, count: Int) {
        self.branch = branch
        self.commit = commit
        self.name = name
        self.count = count
    }
}

/// The branch a new row checks out, where it comes from, and what to say about it.
public struct BranchChoice: Sendable, Equatable {
    public var branch: String
    public var source: BranchSource
    /// Where a new branch starts, such as origin/main.
    public var start: String?
    public var notes: [String]
    public var warnings: [String]
    /// To run in the row once it has the branch checked out.
    public var fastForward: FastForward?

    /// What follows `git worktree add` to make the row in `folder`.
    public func worktreeArguments(folder: String) -> [String] {
        switch source {
        case .local: [folder, branch]
        case .origin: ["--track", "-b", branch, folder, "origin/\(branch)"]
        case .new: ["--no-track", "-b", branch, folder, start ?? "HEAD"]
        }
    }
}

/// The rules `row new` picks a branch by, in one clone: a branch the clone has, fast-forwarded when it is only behind
/// origin, then origin's, then a new one from a base or origin's default branch. The same for rows on this Mac, rows
/// on hosts, and canopy-box.
public struct BranchRules: Sendable {
    public let clone: GitClone

    public init(clone: GitClone) {
        self.clone = clone
    }

    /// The branch for `requested`, with what to say about it. `fetchFailure` is why the fetch before it failed, if it
    /// did. A host that cannot be reached fails as a `GitError`.
    public func choose(
        _ requested: String, base: String?, existing: Bool, hasOrigin: Bool, fetchFailure: String?
    ) async throws -> BranchChoice {
        var choice: BranchChoice
        if let local = try await existingBranch(requested, under: "refs/heads/") {
            choice = BranchChoice(branch: local, source: .local, notes: [], warnings: [])
        } else if hasOrigin, let remote = try await existingBranch(requested, under: "refs/remotes/origin/") {
            choice = BranchChoice(branch: remote, source: .origin, notes: [], warnings: [])
        } else {
            guard !existing else { throw BranchError.branchNotFound(requested, fetchFailure: fetchFailure) }
            let start = try await startPoint(base, hasOrigin: hasOrigin)
            choice = BranchChoice(branch: requested, source: .new, start: start, notes: [], warnings: [])
        }
        if choice.branch != requested { choice.notes.append("Using \(choice.branch), the branch's own spelling.") }
        guard choice.source == .local, hasOrigin else { return choice }
        let remote = "refs/remotes/origin/\(choice.branch)"
        if try await clone.succeedsOnHost(["show-ref", "--verify", "--quiet", remote]) {
            let report = await compare(
                choice.branch, with: remote, named: "origin/\(choice.branch)", resetTo: "origin/\(choice.branch)")
            choice.notes += report.notes
            choice.warnings += report.warnings
            choice.fastForward = report.fastForward
        } else if fetchFailure == nil, let warning = await goneUpstreamWarning(choice.branch) {
            choice.warnings.append(warning)
        }
        return choice
    }

    /// A host that cannot be reached fails as such, not as a bad name.
    public func requireValidName(_ branch: String) async throws {
        guard !branch.hasPrefix("-"), branch != "HEAD",
            try await clone.succeedsOnHost(["check-ref-format", "refs/heads/\(branch)"])
        else { throw BranchError.invalidBranch(branch) }
    }

    /// `--branch` would expand "@{-1}" to the previous branch, and a leading "-" would read as an option.
    public func isValidName(_ branch: String) async -> Bool {
        guard !branch.hasPrefix("-"), branch != "HEAD" else { return false }
        return await clone.succeeds(["check-ref-format", "refs/heads/\(branch)"])
    }

    /// The branch `name` finds under `prefix`, such as "refs/heads/", in its own spelling, or nil. Names that differ
    /// only in case share one ref file on a case-insensitive file system, where a branch made with the other spelling
    /// would hide a packed one, so any case finds the branch. Fails only when the clone is on a host that did not
    /// answer, which says nothing about the branch.
    public func existingBranch(_ name: String, under prefix: String) async throws -> String? {
        let listed: String
        do {
            listed = try await clone.run(["for-each-ref", "--format=%(refname)", prefix])
        } catch let error as GitError where error.hostUnreachable {
            throw error
        } catch {
            return nil
        }
        let refs = listed.split(separator: "\n").map(String.init)
        let ref =
            refs.first { $0 == prefix + name }
            ?? refs.first { $0.caseInsensitiveCompare(prefix + name) == .orderedSame }
        return ref.map { String($0.dropFirst(prefix.count)) }
    }

    /// Where a new branch starts: `base`, which must name a commit, or origin's default branch.
    public func startPoint(_ base: String?, hasOrigin: Bool) async throws -> String {
        guard let base else { return try await defaultBase(hasOrigin: hasOrigin) }
        guard !base.hasPrefix("-"),
            try await clone.succeedsOnHost(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"])
        else { throw BranchError.invalidBase(base) }
        return base
    }

    public func defaultBase(hasOrigin: Bool) async throws -> String {
        guard hasOrigin, let branch = try await defaultBranch() else { return "HEAD" }
        return "origin/" + branch
    }

    /// The branch `origin/HEAD` points at, such as `main`, or nil when the repo has none. Fails only when the clone is
    /// on a host that did not answer.
    public func defaultBranch() async throws -> String? {
        let head: String
        do {
            head = try await clone.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        } catch let error as GitError where error.hostUnreachable {
            throw error
        } catch {
            return nil
        }
        let name = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasPrefix("origin/"), name.count > "origin/".count else { return nil }
        return String(name.dropFirst("origin/".count))
    }

    /// How the local `branch` compares with `target`, from one read of each. A branch that is only behind gets a
    /// fast-forward to run once its row has it checked out, where git knows no other worktree holds it. A branch with
    /// commits of its own is never moved. `name` is how messages show `target`, and `resetTo` is what the fix commands
    /// name.
    public func compare(_ branch: String, with target: String, named name: String, resetTo: String) async
        -> BranchReport
    {
        func commit(_ ref: String) async -> String? {
            try? await clone.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let local = await commit("refs/heads/\(branch)"), let other = await commit(target),
            let counts = try? await clone.run(["rev-list", "--left-right", "--count", "\(local)...\(other)"]),
            case let parts = counts.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }), parts.count == 2
        else { return BranchReport() }
        let (ahead, behind) = (parts[0], parts[1])
        switch (ahead, behind) {
        case (0, 0):
            return BranchReport()
        case (0, _):
            return BranchReport(fastForward: FastForward(branch: branch, commit: other, name: name, count: behind))
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
    public func goneUpstreamWarning(_ branch: String) async -> String? {
        guard
            let line = try? await clone.run(
                ["for-each-ref", "--format=%(upstream:short)%00%(upstream:track)", "refs/heads/\(branch)"])
        else { return nil }
        let fields = line.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == "[gone]" else { return nil }
        return "\(branch) tracked \(fields[0]), which is gone, so it was probably merged and deleted."
    }

    public static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}
