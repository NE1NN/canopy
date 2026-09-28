import Foundation
import Testing

@testable import CanopyCore

struct WorkspaceGroupTests {
    /// A workspace with the demo repo and a Canopy row for each branch. Returns the rows' paths by branch.
    func setUp(_ dir: TempDir, branches: [String] = []) async throws -> (Workspace, String, [String: String]) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        var paths: [String: String] = [:]
        for branch in branches {
            paths[branch] = try await workspace.createRow(repoPath: repo, branch: branch).row.path
        }
        return (workspace, repo, paths)
    }

    func arrangement(_ workspace: Workspace) async -> [String] {
        await workspace.snapshot.repos.first?.rows.map { row in
            row.group.map { "\($0)/\(row.displayName)" } ?? row.displayName
        }
            ?? []
    }

    @Test func newRowsJoinTheUngroupedRowsAndGroupsHoldTheirs() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b", "feat/c"])

        let created = try await workspace.createGroup(repoPath: repo, name: " Review ")
        #expect(created == GroupInfo(repo: "demo", repoPath: repo, name: "Review", collapsed: false, rows: []))
        _ = try await workspace.moveRow(path: try #require(paths["feat/b"]), to: .group("review"))
        _ = try await workspace.moveRow(path: try #require(paths["feat/a"]), to: .group("Review"))
        _ = try await workspace.createRow(repoPath: repo, branch: "feat/d")

        #expect(await arrangement(workspace) == ["main", "feat/c", "feat/d", "Review/feat/b", "Review/feat/a"])
        #expect(await workspace.snapshot.repos.first?.groups == [GroupSnapshot(name: "Review", collapsed: false)])
        let groups = await workspace.groups(repoPath: repo)
        #expect(groups.map(\.name) == ["Review"])
        #expect(groups.first?.rows.map(\.branch) == ["feat/b", "feat/a"])
    }

    @Test func groupsSurviveRelaunchAndBranchSwitches() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        let path = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: path, to: .group("Review"))
        try await workspace.setGroupCollapsed(repoPath: repo, name: "review", collapsed: true)

        try await Fixture.git.run(["switch", "--quiet", "-c", "feat/renamed"], in: path)
        await workspace.refresh(repoPath: repo)
        #expect(await arrangement(workspace) == ["main", "feat/b", "Review/feat/renamed"])
        await workspace.stop()

        let relaunched = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await relaunched.start()
        #expect(await arrangement(relaunched) == ["main", "feat/b", "Review/feat/renamed"])
        #expect(await relaunched.snapshot.repos.first?.groups == [GroupSnapshot(name: "Review", collapsed: true)])
    }

    @Test func rowsGoneFromGitLeaveTheirGroupButGroupsStay() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a"])
        let path = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: path, to: .group("Review"))

        try await Fixture.git.run(["worktree", "remove", path], in: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await arrangement(workspace) == ["main"])
        #expect(await workspace.groups(repoPath: repo).map(\.name) == ["Review"])
        try await Fixture.git.run(["worktree", "add", "--quiet", path, "feat/a"], in: repo)
        await workspace.refresh(repoPath: repo)
        #expect(await arrangement(workspace) == ["main", "feat/a"])
    }

    @Test func aMissingRepoKeepsItsGroups() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: try #require(paths["feat/a"]), to: .group("Review"))

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)
        let missing = try #require(await workspace.snapshot.repo(path: repo))
        #expect(missing.isMissing && missing.rows.isEmpty)
        #expect(missing.groups == [GroupSnapshot(name: "Review", collapsed: false)])

        try FileManager.default.moveItem(atPath: dir.sub("moved"), toPath: repo)
        await workspace.refresh(repoPath: repo)
        #expect(await arrangement(workspace) == ["main", "Review/feat/a"])
    }

    @Test func unadoptingARowTakesItOutOfItsGroup() async throws {
        let dir = try TempDir()
        let (workspace, repo, _) = try await setUp(dir)
        let path = dir.sub("elsewhere")
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: path)
        await workspace.refresh(repoPath: repo)
        _ = try await workspace.adopt(path: path)
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: path, to: .group("Review"))
        #expect(await arrangement(workspace) == ["main", "Review/feat/other"])

        try await workspace.unadopt(path: path)
        #expect(await arrangement(workspace) == ["main"])

        _ = try await workspace.adopt(path: path)
        #expect(await arrangement(workspace) == ["main", "feat/other"])
    }

    @Test func movingRowsFollowsTheRules() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a"])
        let path = try #require(paths["feat/a"])
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: dir.sub("elsewhere"))
        let otherRepo = try await Fixture.repo(in: dir, name: "other")
        try await workspace.addRepo(path: otherRepo)
        let otherRow = try await workspace.createRow(repoPath: otherRepo, branch: "feat/x").row.path

        await #expect(throws: WorkspaceError.cannotMoveMain) {
            try await workspace.moveRow(path: repo, to: .ungrouped)
        }
        await #expect(throws: WorkspaceError.notManaged(dir.sub("elsewhere"))) {
            try await workspace.moveRow(path: dir.sub("elsewhere"), to: .ungrouped)
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.moveRow(path: path, to: .group("Nope"))
        }
        await #expect(throws: WorkspaceError.invalidAnchor(otherRow)) {
            try await workspace.moveRow(path: path, to: .before(otherRow))
        }
        await #expect(throws: WorkspaceError.invalidAnchor(repo)) {
            try await workspace.moveRow(path: path, to: .after(repo))
        }
        await #expect(throws: WorkspaceError.rowNotFound(dir.sub("nowhere"))) {
            try await workspace.moveRow(path: dir.sub("nowhere"), to: .ungrouped)
        }
    }

    @Test func movesThatChangeNothingLogNothing() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        let a = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")

        let moved = try await ActivitySource.$current.withValue(.cli) {
            try await workspace.moveRow(path: a, to: .group("Review"))
        }
        let again = try await workspace.moveRow(path: a, to: .group("review"))
        let stayed = try await workspace.moveRow(path: try #require(paths["feat/b"]), to: .ungrouped)

        #expect(moved.moved && moved.row.group == "Review")
        #expect(!again.moved && again.row.group == "Review")
        #expect(!stayed.moved)
        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created", "row.created", "row.moved"])
        #expect(events.last?.data == ["from": .null, "to": "Review"])
        #expect(events.last?.source == .cli)
        #expect(events.last?.path == a && events.last?.row == "feat/a" && events.last?.repo == "demo")
    }

    @Test func reordersLogNothing() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b", "feat/c", "feat/d"])
        let path = { (branch: String) in try #require(paths[branch]) }
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: try path("feat/b"), to: .group("Review"))
        _ = try await workspace.moveRow(path: try path("feat/c"), to: .group("Review"))

        #expect(try await workspace.moveRow(path: try path("feat/c"), to: .before(try path("feat/b"))).moved)
        #expect(try await workspace.moveRow(path: try path("feat/d"), to: .before(try path("feat/a"))).moved)
        #expect(await arrangement(workspace) == ["main", "feat/d", "feat/a", "Review/feat/c", "Review/feat/b"])
        #expect(try await workspace.moveRow(path: try path("feat/a"), to: .after(try path("feat/c"))).moved)
        #expect(await arrangement(workspace) == ["main", "feat/d", "Review/feat/c", "Review/feat/a", "Review/feat/b"])
        #expect(try await workspace.moveRow(path: try path("feat/a"), to: .ungrouped).moved)

        let moves = await logged(workspace, "row").filter { $0.type == "row.moved" }
        #expect(moves.map(\.row) == ["feat/b", "feat/c", "feat/a", "feat/a"])
        #expect(
            moves.map(\.data) == [
                ["from": .null, "to": "Review"], ["from": .null, "to": "Review"], ["from": .null, "to": "Review"],
                ["from": "Review", "to": .null],
            ])
    }

    @Test func groupEventsCarryTheRepo() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        try await ActivitySource.$current.withValue(.cli) {
            try await workspace.createGroup(repoPath: repo, name: "Review")
        }
        _ = try await workspace.moveRow(path: try #require(paths["feat/a"]), to: .group("Review"))
        _ = try await workspace.moveRow(path: try #require(paths["feat/b"]), to: .group("Review"))
        let same = try await workspace.renameGroup(repoPath: repo, name: "review", to: "Review")
        let renamed = try await workspace.renameGroup(repoPath: repo, name: "review", to: "Code review")
        let removed = try await workspace.removeGroup(repoPath: repo, name: "CODE REVIEW")

        #expect(same.name == "Review")
        #expect(renamed.name == "Code review" && renamed.rows.map(\.branch) == ["feat/a", "feat/b"])
        #expect(removed.name == "Code review" && removed.rows.map(\.branch) == ["feat/a", "feat/b"])
        #expect(await arrangement(workspace) == ["main", "feat/a", "feat/b"])
        let events = await logged(workspace, "group")
        #expect(events.map(\.type) == ["group.created", "group.renamed", "group.removed"])
        #expect(
            events.map(\.data) == [
                ["name": "Review"], ["from": "Review", "to": "Code review"],
                [
                    "name": "Code review", "rows": 2,
                ],
            ])
        #expect(events.map(\.source) == [.cli, .ui, .ui])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.path == repo && $0.row == nil })
        #expect(await logged(workspace, "row").filter { $0.type == "row.moved" }.count == 2)
    }

    @Test func groupErrorsNameTheRepo() async throws {
        let dir = try TempDir()
        let (workspace, repo, _) = try await setUp(dir)
        try await workspace.createGroup(repoPath: repo, name: "Review")

        await #expect(throws: WorkspaceError.groupExists("Review", repo: "demo")) {
            try await workspace.createGroup(repoPath: repo, name: "REVIEW")
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.removeGroup(repoPath: repo, name: "Nope")
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.renameGroup(repoPath: repo, name: "Nope", to: "Other")
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.setGroupCollapsed(repoPath: repo, name: "Nope", collapsed: true)
        }
        await #expect(throws: WorkspaceError.repoNotFound(dir.sub("nope"))) {
            try await workspace.createGroup(repoPath: dir.sub("nope"), name: "Review")
        }
    }

    @Test func revealingARowUnfoldsItsGroupAndFoldingIsNotLogged() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        let a = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: a, to: .group("Review"))
        try await workspace.setGroupCollapsed(repoPath: repo, name: "Review", collapsed: true)
        #expect(await workspace.snapshot.visibleRows.map(\.displayName) == ["main", "feat/b"])

        try await workspace.revealRow(path: try #require(paths["feat/b"]))
        #expect(await workspace.snapshot.repos.first?.groups.first?.collapsed == true)
        try await workspace.revealRow(path: a)
        #expect(await workspace.snapshot.repos.first?.groups.first?.collapsed == false)
        #expect(await workspace.snapshot.visibleRows.map(\.displayName) == ["main", "feat/b", "feat/a"])

        let events = await logged(workspace, "group", "row").map(\.type)
        #expect(events == ["row.created", "row.created", "group.created", "row.moved"])
    }
}

/// The sidebar order and keyboard stepping, on snapshots built by hand.
struct GroupSnapshotTests {
    static func row(_ repo: String, _ name: String, group: String? = nil, main: Bool = false) -> Row {
        var row = Row(
            repoPath: "/\(repo)", path: main ? "/\(repo)" : "/\(repo)/\(name)", branch: name, head: nil,
            rowClass: main ? .main : .canopy)
        row.group = group
        return row
    }

    /// web: main, a, then Review (b, c) collapsed and Later (d). api: main, e, then Hidden (f) collapsed.
    static let snapshot = WorkspaceSnapshot(repos: [
        RepoSnapshot(
            path: "/web", name: "web",
            rows: [
                row("web", "main", main: true), row("web", "a"), row("web", "b", group: "Review"),
                row("web", "c", group: "Review"), row("web", "d", group: "Later"),
            ],
            groups: [GroupSnapshot(name: "Review", collapsed: true), GroupSnapshot(name: "Later", collapsed: false)]),
        RepoSnapshot(
            path: "/api", name: "api",
            rows: [row("api", "main", main: true), row("api", "e"), row("api", "f", group: "Hidden")],
            groups: [GroupSnapshot(name: "Hidden", collapsed: true)]),
    ])

    @Test func arrangingPutsRowsInSidebarOrder() {
        var entry = RepoEntry(path: "/web", dirName: "web", rowOrder: ["/web/a"])
        entry.groups = [RowGroup(name: "Review", rows: ["/web/c", "/web/b"], collapsed: true)]
        let raw = RepoSnapshot(
            path: "/web", name: "web",
            rows: [
                Self.row("web", "b", group: "Stale"), Self.row("web", "main", main: true), Self.row("web", "c"),
                Self.row("web", "new"), Self.row("web", "a"),
            ])

        let arranged = raw.arranged(by: entry)

        #expect(arranged.rows.map(\.displayName) == ["main", "a", "new", "c", "b"])
        #expect(arranged.rows.map(\.group) == [nil, nil, nil, "Review", "Review"])
        #expect(arranged.groups == [GroupSnapshot(name: "Review", collapsed: true)])
        #expect(arranged.rows(inGroup: "Review").map(\.displayName) == ["c", "b"])
    }

    @Test func collapsedGroupsAreSkippedInTheVisibleOrder() {
        #expect(Self.snapshot.visibleRows.map(\.path) == ["/web", "/web/a", "/web/d", "/api", "/api/e"])
        #expect(Self.snapshot.repos[0].visibleRows.map(\.displayName) == ["main", "a", "d"])
    }

    @Test func steppingFromAHiddenRowContinuesFromItsGroup() {
        let snapshot = Self.snapshot

        #expect(snapshot.steppingRow(from: "/web/b", offset: 1)?.path == "/web/d")
        #expect(snapshot.steppingRow(from: "/web/c", offset: -1)?.path == "/web/a")
        #expect(snapshot.steppingRow(from: "/api/f", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/api/f", offset: 1) == nil)
        #expect(snapshot.steppingRow(from: "/web/a", offset: 1)?.path == "/web/d")
        #expect(snapshot.steppingRow(from: "/web/d", offset: -1)?.path == "/web/a")
        #expect(snapshot.steppingRow(from: "/api/e", offset: 1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/web", offset: -1)?.path == "/web")
        #expect(snapshot.steppingRow(from: nil, offset: 1)?.path == "/web")
        #expect(snapshot.steppingRow(from: nil, offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/elsewhere", offset: 1)?.path == "/web")
    }
}
