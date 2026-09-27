import Foundation
import Testing

@testable import CanopyCore

struct RowLifecycleTests {
    let git = GitRunner()

    /// The caller owns `dir`; releasing it deletes the folder mid-test.
    func setUp(_ dir: TempDir, origin: Bool = true) async throws -> (String, Workspace) {
        let repo = try await Fixture.repo(in: dir, origin: origin)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")))
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (repo, workspace)
    }

    @Test func createsNewBranchFromOriginDefault() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/new")

        #expect(created.row.path == dir.sub("home/worktrees/demo/feat-new"))
        #expect(created.row.rowClass == .canopy)
        #expect(created.warnings.isEmpty)
        let base = try await git.run(["rev-parse", "origin/main"], in: repo)
        let head = try await git.run(["rev-parse", "HEAD"], in: created.row.path)
        #expect(head == base)
        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main", "feat/new"])
    }

    @Test func homeGivenThroughSymlinkStillClassifiesAsCanopy() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        // TempDir paths start with /private/var; /var is a symlink to it. The home folder does not exist yet.
        let aliasedHome = dir.sub("home").replacingOccurrences(of: "/private/var/", with: "/var/")
        #expect(aliasedHome != dir.sub("home"))
        let workspace = Workspace(home: CanopyHome(path: aliasedHome))
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/aliased")

        #expect(created.row.rowClass == .canopy)
    }

    @Test func checksOutExistingLocalBranch() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/local"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/local")

        #expect(created.row.branch == "feat/local")
    }

    @Test func tracksBranchThatOnlyExistsOnOrigin() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/remote"], in: repo)
        try await git.run(["push", "--quiet", "origin", "feat/remote"], in: repo)
        try await git.run(["branch", "-D", "feat/remote"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/remote")

        let upstream = try await git.run(["rev-parse", "--abbrev-ref", "feat/remote@{upstream}"], in: created.row.path)
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/feat/remote")
    }

    @Test func worksWithoutOrigin() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir, origin: false)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/offline")

        #expect(created.row.branch == "feat/offline")
    }

    @Test func honorsExplicitBase() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await git.run(["commit", "--quiet", "--allow-empty", "-m", "second"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/based", base: "main")

        let expected = try await git.run(["rev-parse", "main"], in: repo)
        #expect(try await git.run(["rev-parse", "HEAD"], in: created.row.path) == expected)
    }

    @Test func rejectsInvalidAndCheckedOutBranches() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)

        await #expect(throws: WorkspaceError.invalidBranch("bad name")) {
            try await workspace.createRow(repoPath: repo, branch: "bad name")
        }
        await #expect(throws: WorkspaceError.branchCheckedOut("main")) {
            try await workspace.createRow(repoPath: repo, branch: "main")
        }
    }

    @Test func slugCollisionGetsSuffix() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try FileManager.default.createDirectory(
            atPath: dir.sub("home/worktrees/demo/feat-a"), withIntermediateDirectories: true)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/a")

        #expect(created.row.path == dir.sub("home/worktrees/demo/feat-a-2"))
    }

    @Test func parallelCreatesShareOneFetch() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let log = dir.sub("fetches.log")
        let git = try Fixture.git(in: dir, before: #"[[ "$1" == "fetch" ]] && { echo fetch >> "\#(log)"; sleep 1; }"#)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        async let first = workspace.createRow(repoPath: repo, branch: "feat/one")
        async let second = workspace.createRow(repoPath: repo, branch: "feat/two")
        async let third = workspace.createRow(repoPath: repo, branch: "feat/three")
        _ = try await [first, second, third]

        let fetches = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
        #expect(fetches.count == 1)
    }

    @Test func stalledFetchStillCreatesTheRow() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let git = try Fixture.git(in: dir, before: #"[[ "$1" == "fetch" ]] && sleep 30"#)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git, fetchTimeout: .milliseconds(500))
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/offline")

        #expect(created.row.branch == "feat/offline")
        #expect(created.warnings.contains { $0.contains("timed out") })
    }

    @Test func parallelCreatesInOneRepoAllSucceed() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        for branch in ["feat/remote-a", "feat/remote-b"] {
            try await git.run(["branch", branch], in: repo)
            try await git.run(["push", "--quiet", "origin", branch], in: repo)
            try await git.run(["branch", "-D", branch], in: repo)
        }

        // Two branches share the folder slug "feat-a", and two need tracking config written.
        async let first = workspace.createRow(repoPath: repo, branch: "feat/a")
        async let second = workspace.createRow(repoPath: repo, branch: "feat-a")
        async let third = workspace.createRow(repoPath: repo, branch: "feat/remote-a")
        async let fourth = workspace.createRow(repoPath: repo, branch: "feat/remote-b")
        let created = try await [first, second, third, fourth]

        #expect(Set(created.map(\.row.path)).count == 4)
        #expect(created.allSatisfy { $0.warnings.isEmpty })
        #expect(await workspace.snapshot.repos.first?.rows.count == 5)
    }

    @Test func removesCleanRowAndOptionallyItsBranch() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        let created = try await workspace.createRow(repoPath: repo, branch: "feat/done")

        try await workspace.removeRow(path: created.row.path, deleteBranch: true)

        #expect(!FileManager.default.fileExists(atPath: created.row.path))
        #expect(!(await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/done"], in: repo)))
        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main"])
    }

    @Test func dirtyRowNeedsForce() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        let created = try await workspace.createRow(repoPath: repo, branch: "feat/dirty")
        try "x".write(toFile: created.row.path + "/new.txt", atomically: true, encoding: .utf8)

        await #expect(throws: WorkspaceError.worktreeDirty(created.row.path)) {
            try await workspace.removeRow(path: created.row.path)
        }
        try await workspace.removeRow(path: created.row.path, force: true)
        #expect(!FileManager.default.fileExists(atPath: created.row.path))
    }

    @Test func removingAdoptedRowOnlyUnadopts() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        _ = try await workspace.adopt(path: dir.sub("theirs"))

        try await workspace.removeRow(path: dir.sub("theirs"))

        #expect(FileManager.default.fileExists(atPath: dir.sub("theirs")))
        #expect(await workspace.snapshot.repos.first?.external.map(\.branch) == ["feat/theirs"])
    }

    @Test func mainAndExternalRowsCannotBeRemoved() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        await workspace.refresh(repoPath: repo)

        await #expect(throws: WorkspaceError.cannotRemoveMain) {
            try await workspace.removeRow(path: repo)
        }
        await #expect(throws: WorkspaceError.notManaged(dir.sub("theirs"))) {
            try await workspace.removeRow(path: dir.sub("theirs"))
        }
    }
}
