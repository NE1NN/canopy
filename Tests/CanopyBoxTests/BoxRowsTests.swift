import CanopyAgents
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

struct BoxRowsTests {
    @Test func aNewRowGoesUnderTheWorktreesFolder() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let folder = home.paths.worktrees(repo: "demo")
        try FileManager.default.createDirectory(atPath: folder + "/feat-x", withIntermediateDirectories: true)
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/x"))
        #expect(made.row.path == folder + "/feat-x-2")
        #expect(made.row.branch == "feat/x")
        #expect(made.row.head?.count == 40)
        #expect(made.source == .new)
        #expect(made.base == "origin/main")
        #expect(await daemon.snapshot().rows.map(\.path) == [home.clone, folder + "/feat-x-2"])
        let listed = try await GitFixture.git(["worktree", "list", "--porcelain"], in: home.clone)
        #expect(listed.contains("worktree \(folder)/feat-x-2"))
    }

    @Test func aRowForTheMainBranchSaysTheMainRowHasIt() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        await #expect(
            throws: ControlError(
                code: "branch_checked_out",
                message: "Branch main is checked out in the main checkout at \(home.clone).")
        ) { try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "main")) }
    }

    @Test func aBranchWithARowSaysWhere() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/twice"))
        await #expect(
            throws: ControlError(
                code: "branch_checked_out", message: "Branch feat/twice already has a row at \(made.row.path).")
        ) { try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/twice")) }
    }

    @Test func twoRowsAtOnceBothLand() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        async let first = daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/one"))
        async let second = daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/two"))
        let made = try await [first, second]
        #expect(Set(made.map(\.row.branch)) == ["feat/one", "feat/two"])
        #expect(await daemon.snapshot().rows.count == 3)
    }

    @Test func badNamesBasesAndReposFailAsOnTheMac() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        await #expect(throws: ControlError(code: "invalid_branch", message: "Not a valid branch name: a..b")) {
            try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "a..b"))
        }
        await #expect(throws: ControlError(code: "invalid_base", message: "No commit matches --from nowhere.")) {
            try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/b", base: "nowhere"))
        }
        await #expect(
            throws: ControlError(
                code: "branch_not_found",
                message: "No branch nope here or on origin. Leave out --existing to create it.")
        ) { try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "nope", existing: true)) }
        await #expect(
            throws: ControlError(
                code: "repo_not_found", message: "No registered repo matches \"other\". Run `canopy repo list`.")
        ) { try await daemon.rowNew(BoxRowNewParams(repo: "other", branch: "x")) }
    }

    @Test func removingADirtyRowNeedsForce() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/dirty"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: made.row.path + "/new.txt"))
        await #expect(
            throws: ControlError(
                code: "worktree_dirty",
                message: "\(made.row.path) has uncommitted changes. Pass --force to remove it anyway.")
        ) { try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path)) }
        #expect(try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path, force: true)) == [])
        #expect(!FileManager.default.fileExists(atPath: made.row.path))
        #expect(await daemon.snapshot().rows.count == 1)
    }

    @Test func removingARowEndsItsPanes() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/panes"))
        try await home.session("b9", in: made.row.path)
        await daemon.start()
        #expect(await daemon.snapshot().panes.map(\.id) == ["b9"])
        _ = try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path, force: true))
        #expect(await daemon.snapshot().panes.isEmpty)
        #expect(!(await home.server.tmux.hasSession("b9")))
    }

    @Test func theMainRowCannotBeRemoved() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        await #expect(
            throws: ControlError(code: "cannot_remove_main", message: "The main checkout cannot be removed.")
        ) { try await daemon.rowRemove(BoxRowRemoveParams(path: home.clone)) }
        await #expect(
            throws: ControlError(code: "row_not_found", message: "No row matches \"/nowhere\". Run `canopy row list`.")
        ) { try await daemon.rowRemove(BoxRowRemoveParams(path: "/nowhere")) }
    }

    @Test func aMissingRowIsPrunedOnRemove() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/gone"))
        try FileManager.default.removeItem(atPath: made.row.path)
        await daemon.start()
        #expect(await daemon.snapshot().rows.last?.missing == true)
        _ = try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path))
        #expect(await daemon.snapshot().rows.count == 1)
        let listed = try await GitFixture.git(["worktree", "list"], in: home.clone)
        #expect(!listed.contains("feat-gone"))
    }

    @Test func deleteBranchDeletesIt() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/del"))
        _ = try await daemon.rowRemove(BoxRowRemoveParams(path: made.row.path, deleteBranch: true))
        let branches = try await GitFixture.git(["branch", "--list", "feat/del"], in: home.clone)
        #expect(branches.isEmpty)
    }

    @Test func anUnconfiguredBoxHasNoRepos() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon(configured: false)
        await #expect(throws: ControlError.self) {
            try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "x"))
        }
    }
}
