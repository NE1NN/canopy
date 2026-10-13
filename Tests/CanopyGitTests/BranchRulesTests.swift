import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyGit

struct BranchRulesTests {
    /// A clone of an origin with `main`, and a second clone that pushes to it, as another machine would.
    struct Repos {
        let dir: TempDir
        let clone: String
        let other: String
        var rules: BranchRules { BranchRules(clone: GitFixture.clone(clone)) }

        init() async throws {
            dir = try TempDir()
            clone = try await GitFixture.repo(in: dir, origin: true)
            other = dir.sub("other")
            try await GitFixture.git(["clone", "--quiet", dir.sub("demo-origin.git"), other], in: dir.path)
            try await GitFixture.git(["config", "user.email", "test@example.com"], in: other)
            try await GitFixture.git(["config", "user.name", "Test"], in: other)
        }

        func fetch() async throws {
            try await GitFixture.git(["fetch", "--quiet", "--prune", "origin"], in: clone)
        }
    }

    @Test func aLocalBranchIsCheckedOut() async throws {
        let repos = try await Repos()
        try await GitFixture.git(["branch", "feat/x"], in: repos.clone)
        let choice = try await repos.rules.choose(
            "feat/x", base: nil, existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(choice.source == .local)
        #expect(choice.branch == "feat/x")
        #expect(choice.worktreeArguments(folder: "/w") == ["/w", "feat/x"])
    }

    @Test func aBranchOnlyOnOriginIsTracked() async throws {
        let repos = try await Repos()
        try await GitFixture.git(["push", "--quiet", "origin", "HEAD:refs/heads/feat/y"], in: repos.other)
        try await repos.fetch()
        let choice = try await repos.rules.choose(
            "feat/y", base: nil, existing: true, hasOrigin: true, fetchFailure: nil)
        #expect(choice.source == .origin)
        #expect(choice.worktreeArguments(folder: "/w") == ["--track", "-b", "feat/y", "/w", "origin/feat/y"])
    }

    @Test func anythingElseStartsFromOriginsDefaultBranch() async throws {
        let repos = try await Repos()
        let choice = try await repos.rules.choose(
            "feat/new", base: nil, existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(choice.source == .new)
        #expect(choice.start == "origin/main")
        #expect(choice.worktreeArguments(folder: "/w") == ["--no-track", "-b", "feat/new", "/w", "origin/main"])
        let based = try await repos.rules.choose(
            "feat/b", base: "main", existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(based.start == "main")
    }

    @Test func existingFailsForANewBranch() async throws {
        let repos = try await Repos()
        await #expect(throws: BranchError.branchNotFound("nope", fetchFailure: "git fetch timed out")) {
            try await repos.rules.choose(
                "nope", base: nil, existing: true, hasOrigin: true, fetchFailure: "git fetch timed out")
        }
    }

    @Test func aBranchOnlyBehindIsFastForwarded() async throws {
        let repos = try await Repos()
        try await GitFixture.git(["branch", "feat/ff"], in: repos.clone)
        try await GitFixture.git(["push", "--quiet", "origin", "HEAD:refs/heads/feat/ff"], in: repos.clone)
        try await GitFixture.git(["fetch", "--quiet", "origin", "feat/ff"], in: repos.other)
        try await GitFixture.git(["switch", "--quiet", "-c", "feat/ff", "FETCH_HEAD"], in: repos.other)
        let ahead = try await GitFixture.commit(in: repos.other, "two")
        try await GitFixture.git(["push", "--quiet", "origin", "feat/ff"], in: repos.other)
        try await repos.fetch()
        let choice = try await repos.rules.choose(
            "feat/ff", base: nil, existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(choice.source == .local)
        #expect(
            choice.fastForward == FastForward(branch: "feat/ff", commit: ahead, name: "origin/feat/ff", count: 1))
    }

    @Test func aDivergedBranchWarnsAndStays() async throws {
        let repos = try await Repos()
        try await GitFixture.git(["push", "--quiet", "origin", "HEAD:refs/heads/feat/d"], in: repos.clone)
        try await GitFixture.git(["fetch", "--quiet", "origin", "feat/d"], in: repos.other)
        try await GitFixture.git(["switch", "--quiet", "-c", "feat/d", "FETCH_HEAD"], in: repos.other)
        try await GitFixture.commit(in: repos.other, "theirs")
        try await GitFixture.git(["push", "--quiet", "origin", "feat/d"], in: repos.other)
        try await repos.fetch()
        try await GitFixture.git(["switch", "--quiet", "-c", "feat/d", "main"], in: repos.clone)
        try await GitFixture.commit(in: repos.clone, "mine")
        try await GitFixture.git(["switch", "--quiet", "main"], in: repos.clone)
        let choice = try await repos.rules.choose(
            "feat/d", base: nil, existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(choice.fastForward == nil)
        #expect(choice.warnings.count == 1)
        #expect(choice.warnings.first?.hasPrefix("feat/d and origin/feat/d have diverged") == true)
    }

    @Test func theBranchsOwnSpellingWins() async throws {
        let repos = try await Repos()
        try await GitFixture.git(["branch", "Feat/Case"], in: repos.clone)
        let choice = try await repos.rules.choose(
            "feat/case", base: nil, existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(choice.branch == "Feat/Case")
        #expect(choice.notes.contains("Using Feat/Case, the branch's own spelling."))
    }

    @Test func aGoneUpstreamWarns() async throws {
        let repos = try await Repos()
        try await GitFixture.git(["switch", "--quiet", "-c", "feat/gone"], in: repos.clone)
        try await GitFixture.git(["push", "--quiet", "-u", "origin", "feat/gone"], in: repos.clone)
        try await GitFixture.git(["switch", "--quiet", "main"], in: repos.clone)
        try await GitFixture.git(["push", "--quiet", "origin", "--delete", "feat/gone"], in: repos.other)
        try await repos.fetch()
        let choice = try await repos.rules.choose(
            "feat/gone", base: nil, existing: false, hasOrigin: true, fetchFailure: nil)
        #expect(
            choice.warnings == [
                "feat/gone tracked origin/feat/gone, which is gone, so it was probably merged and deleted."
            ])
    }

    @Test func aBadNameAndABadBaseFail() async throws {
        let repos = try await Repos()
        for bad in ["-x", "HEAD", "a..b", "bad name"] {
            await #expect(throws: BranchError.invalidBranch(bad)) { try await repos.rules.requireValidName(bad) }
        }
        await #expect(throws: BranchError.invalidBase("nowhere")) {
            try await repos.rules.choose("feat/z", base: "nowhere", existing: false, hasOrigin: true, fetchFailure: nil)
        }
    }

    @Test func withoutOriginItStartsFromHead() async throws {
        let dir = try TempDir()
        let repo = try await GitFixture.repo(in: dir)
        let choice = try await BranchRules(clone: GitFixture.clone(repo)).choose(
            "feat/local", base: nil, existing: false, hasOrigin: false, fetchFailure: nil)
        #expect(choice.start == "HEAD")
    }
}
