import Foundation
import Testing

@testable import CanopyCore

/// `row new <branch>`: which branch it picks, and how an existing branch is brought up to date.
struct ExistingBranchTests {
    let git = Fixture.git

    /// A repo whose origin is a local bare repo, and a second clone of that origin for someone else's pushes.
    func setUp(_ dir: TempDir) async throws -> (repo: String, other: String, workspace: Workspace) {
        let repo = try await Fixture.repo(in: dir, origin: true)
        let other = dir.sub("other")
        try await git.run(["clone", "--quiet", dir.sub("demo-origin.git"), other])
        try await git.run(["config", "user.email", "other@example.com"], in: other)
        try await git.run(["config", "user.name", "Other"], in: other)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (repo, other, workspace)
    }

    func commit(_ count: Int, in path: String) async throws {
        for index in 1...count {
            try await git.run(["commit", "--quiet", "--allow-empty", "-m", "commit \(index)"], in: path)
        }
    }

    func head(_ ref: String, in path: String) async throws -> String {
        try await git.run(["rev-parse", ref], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func saysWhichBranchItUsed() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/local"], in: repo)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/remote"], in: other)

        let local = try await workspace.createRow(repoPath: repo, branch: "feat/local")
        let remote = try await workspace.createRow(repoPath: repo, branch: "feat/remote")
        let new = try await workspace.createRow(repoPath: repo, branch: "feat/new")

        #expect(local.source == .local && local.base == nil)
        #expect(remote.source == .origin && remote.base == nil)
        #expect(new.source == .new && new.base == "origin/main")
        #expect(try await workspace.createRow(repoPath: repo, branch: "feat/based", base: "main").base == "main")
    }

    @Test func existingRefusesANameThatMatchesNothing() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/theirs"], in: other)

        await #expect(throws: WorkspaceError.branchNotFound("feat/typo", fetchFailure: nil)) {
            try await workspace.createRow(repoPath: repo, branch: "feat/typo", existing: true)
        }
        #expect(!(await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/typo"], in: repo)))
        #expect(try await workspace.createRow(repoPath: repo, branch: "feat/theirs", existing: true).source == .origin)
    }

    @Test func existingSaysWhenOriginCouldNotBeAsked() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["remote", "set-url", "origin", dir.sub("nowhere.git")], in: repo)

        await #expect {
            try await workspace.createRow(repoPath: repo, branch: "feat/typo", existing: true)
        } throws: { error in
            guard case WorkspaceError.branchNotFound("feat/typo", let failure?) = error else { return false }
            return failure.hasPrefix("git fetch failed")
                && (error as? WorkspaceError)?.message.contains(failure) == true
        }
    }

    @Test func fastForwardsABranchThatIsOnlyBehind() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/x"], in: repo)
        try await git.run(["switch", "--quiet", "-c", "feat/x"], in: other)
        try await commit(2, in: other)
        try await git.run(["push", "--quiet", "origin", "feat/x"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(created.source == .local)
        #expect(try await head("HEAD", in: created.row.path) == (try await head("HEAD", in: other)))
        #expect(created.notes == ["Fast-forwarded feat/x by 2 commits to match origin/feat/x."])
        #expect(created.warnings.isEmpty)
    }

    @Test func keepsCommitsThatAreOnlyLocal() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/x"], in: repo)
        try await git.run(["switch", "--quiet", "-c", "feat/x"], in: repo)
        try await commit(1, in: repo)
        try await git.run(["switch", "--quiet", "main"], in: repo)
        let local = try await head("feat/x", in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(try await head("HEAD", in: created.row.path) == local)
        #expect(created.notes == ["feat/x has 1 commit that is not on origin/feat/x yet."])
        #expect(created.warnings.isEmpty)
    }

    @Test func neverResetsADivergedBranch() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/x"], in: repo)
        try await git.run(["branch", "feat/x", "main"], in: repo)
        try await git.run(["switch", "--quiet", "feat/x"], in: repo)
        try await commit(1, in: repo)
        try await git.run(["switch", "--quiet", "main"], in: repo)
        let local = try await head("feat/x", in: repo)
        try await git.run(["fetch", "--quiet"], in: other)
        try await git.run(["switch", "--quiet", "feat/x"], in: other)
        try await commit(2, in: other)
        try await git.run(["push", "--quiet", "origin", "feat/x"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(try await head("HEAD", in: created.row.path) == local)
        #expect(created.notes.isEmpty)
        let warning = try #require(created.warnings.first)
        #expect(warning.contains("have diverged"))
        #expect(warning.contains("1 commit here") && warning.contains("2 commits on origin/feat/x"))
        #expect(warning.contains("git rebase origin/feat/x") && warning.contains("git reset --hard origin/feat/x"))
    }

    @Test func warnsWhenABranchsUpstreamIsGone() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/merged"], in: repo)
        try await git.run(["push", "--quiet", "-u", "origin", "feat/merged"], in: repo)
        try await git.run(["push", "--quiet", "origin", "--delete", "feat/merged"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/merged")

        #expect(created.source == .local)
        #expect(
            created.warnings == [
                "feat/merged tracked origin/feat/merged, which is gone, so it was probably merged and deleted."
            ])
    }

    @Test func aBranchDeletedOnOriginIsNotOnOrigin() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["push", "--quiet", "origin", "HEAD:feat/old"], in: other)
        try await git.run(["fetch", "--quiet"], in: repo)
        try await git.run(["push", "--quiet", "origin", "--delete", "feat/old"], in: other)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/old")

        #expect(created.source == .new)
    }

    @Test func prunesAWorktreeWhoseFolderWasDeleted() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        let gone = try await workspace.createRow(repoPath: repo, branch: "feat/held")
        let other = try await workspace.createRow(repoPath: repo, branch: "feat/other")
        try FileManager.default.removeItem(atPath: gone.row.path)
        try FileManager.default.removeItem(atPath: other.row.path)
        await workspace.refresh(repoPath: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/held")

        #expect(created.source == .local)
        #expect(FileManager.default.fileExists(atPath: created.row.path))
        #expect(await workspace.snapshot.repos.first?.rows.filter { $0.branch == "feat/held" }.count == 1)
        // Only the worktree that held the branch goes. Other missing rows stay until the user prunes them.
        #expect(await workspace.snapshot.row(path: other.row.path)?.isMissing == true)
    }

    @Test func neverMovesABranchThatIsBeingRebasedElsewhere() async throws {
        let dir = try TempDir()
        let (repo, other, workspace) = try await setUp(dir)
        try await git.run(["worktree", "add", "--quiet", "-b", "feat/x", dir.sub("rebasing"), "main"], in: repo)
        try await commit(2, in: dir.sub("rebasing"))
        try await git.run(["push", "--quiet", "origin", "feat/x"], in: repo)
        try await git.run(["fetch", "--quiet"], in: other)
        try await git.run(["switch", "--quiet", "feat/x"], in: other)
        try await commit(1, in: other)
        try await git.run(["push", "--quiet", "origin", "feat/x"], in: other)
        // Mid-rebase, git lists the worktree as detached, though it still holds feat/x.
        var environment = Fixture.environment
        environment["GIT_SEQUENCE_EDITOR"] = "sed -i '' '1s/^pick/edit/'"
        try await GitRunner(executable: Fixture.gitPath, environment: environment).run(
            ["rebase", "--quiet", "-i", "HEAD~2"], in: dir.sub("rebasing"))
        let before = try await head("refs/heads/feat/x", in: repo)

        await #expect {
            try await workspace.createRow(repoPath: repo, branch: "feat/x")
        } throws: { error in
            guard case WorkspaceError.branchCheckedOut("feat/x", _) = error else { return false }
            return true
        }
        #expect(try await head("refs/heads/feat/x", in: repo) == before)
    }

    @Test func namesTheRowThatHasTheBranch() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        let first = try await workspace.createRow(repoPath: repo, branch: "feat/a")

        await #expect(throws: WorkspaceError.branchCheckedOut("feat/a", row: first.row)) {
            try await workspace.createRow(repoPath: repo, branch: "feat/a")
        }
        let message = WorkspaceError.branchCheckedOut("feat/a", row: first.row).message
        #expect(message.contains(first.row.path) && message.contains("canopy row select feat/a"))
    }

    @Test func namesTheMainCheckout() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        let main = try #require(await workspace.snapshot.row(path: repo))

        await #expect(throws: WorkspaceError.branchCheckedOut("main", row: main)) {
            try await workspace.createRow(repoPath: repo, branch: "main")
        }
        #expect(WorkspaceError.branchCheckedOut("main", row: main).message.contains("main checkout at \(repo)"))
    }

    @Test func pointsAtAdoptingAnotherToolsWorktree() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        await workspace.refresh(repoPath: repo)
        let theirs = try #require(await workspace.snapshot.row(path: dir.sub("theirs")))

        await #expect(throws: WorkspaceError.branchCheckedOut("feat/theirs", row: theirs)) {
            try await workspace.createRow(repoPath: repo, branch: "feat/theirs", existing: true)
        }
        #expect(
            WorkspaceError.branchCheckedOut("feat/theirs", row: theirs).message.contains(
                "canopy row adopt \(dir.sub("theirs"))"))
    }

    @Test(arguments: [false, true]) func usesABranchsOwnSpelling(packed: Bool) async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/lower"], in: repo)
        try await git.run(["commit", "--quiet", "--allow-empty", "-m", "main moves on"], in: repo)
        if packed {
            try await git.run(["pack-refs", "--all"], in: repo)
        }
        let before = try await head("feat/lower", in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "Feat/Lower")

        #expect(created.row.branch == "feat/lower")
        #expect(created.source == .local)
        #expect(created.notes == ["Using feat/lower, the branch's own spelling."])
        #expect(try await head("feat/lower", in: repo) == before)
    }
}
