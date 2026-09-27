import Testing

@testable import CanopyCore

struct WorktreeListParserTests {
    @Test func parsesMainLinkedDetachedAndPrunable() {
        let output = [
            "worktree /r/main", "HEAD aaa", "branch refs/heads/main", "",
            "worktree /r/wt one", "HEAD bbb", "branch refs/heads/fix/login", "locked", "",
            "worktree /r/detached", "HEAD ccc", "detached", "",
            "worktree /r/gone", "HEAD ddd", "branch refs/heads/old",
            "prunable gitdir file points to non-existent location",
            "", "",
        ].joined(separator: "\0")

        let worktrees = WorktreeListParser.parse(output)

        #expect(
            worktrees == [
                Worktree(path: "/r/main", head: "aaa", branch: "main"),
                Worktree(path: "/r/wt one", head: "bbb", branch: "fix/login", isLocked: true),
                Worktree(path: "/r/detached", head: "ccc", isDetached: true),
                Worktree(path: "/r/gone", head: "ddd", branch: "old", isPrunable: true),
            ]
        )
    }

    @Test func parsesBareMain() {
        let output = ["worktree /r/bare.git", "bare", "", ""].joined(separator: "\0")
        #expect(WorktreeListParser.parse(output) == [Worktree(path: "/r/bare.git", isBare: true)])
    }

    @Test func emptyOutputHasNoWorktrees() {
        #expect(WorktreeListParser.parse("").isEmpty)
    }

    @Test func parsesRealGitOutput() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: dir.sub("wt"))

        let output = try await Fixture.git.run(["worktree", "list", "--porcelain", "-z"], in: repo)
        let worktrees = WorktreeListParser.parse(output)

        #expect(worktrees.map(\.branch) == ["main", "feat/x"])
        #expect(Paths.canonical(worktrees[0].path) == repo)
    }
}
