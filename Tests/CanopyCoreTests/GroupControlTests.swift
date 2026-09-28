import Foundation
import Testing

@testable import CanopyCore

struct GroupControlTests {
    let base = ControlServerTests()

    func send(_ client: ControlClient, _ method: String, _ params: JSONValue) async throws -> ControlResponse {
        try await offPool { try client.send(ControlRequest(method: method, params: params)) }
    }

    @Test func groupsFlowOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let demo = TargetHint(repo: "demo")
        let a = try await base.call(
            client, ControlMethod.rowNew, RowNewParams(target: demo, branch: "feat/a"), as: RowNewResult.self
        ).row

        let created = try await base.call(
            client, GroupMethod.new, GroupParams(target: demo, name: " Review "), as: GroupInfo.self)
        #expect(created == GroupInfo(repo: "demo", repoPath: repo, name: "Review", collapsed: false, rows: []))
        let b = try await base.call(
            client, ControlMethod.rowNew, RowNewParams(target: demo, branch: "feat/b", group: "review"),
            as: RowNewResult.self
        ).row
        #expect(b.group == "Review")
        let moved = try await base.call(
            client, ControlMethod.rowMove, RowMoveParams(target: TargetHint(row: a.path), group: "REVIEW"),
            as: RowMoveResult.self)
        #expect(moved.moved && moved.row.group == "Review" && moved.from == nil)
        let renamed = try await base.call(
            client, GroupMethod.rename, GroupRenameParams(target: demo, name: "review", newName: "Code review"),
            as: GroupInfo.self)
        #expect(renamed.name == "Code review")

        let listed = try await base.call(client, GroupMethod.list, GroupListParams(), as: [GroupInfo].self)
        #expect(listed.map(\.name) == ["Code review"])
        #expect(listed.first?.rows.map(\.branch) == ["feat/b", "feat/a"])
        let rows = try await base.call(client, ControlMethod.rowList, RowListParams(), as: [Row].self)
        #expect(rows.map(\.group) == [nil, "Code review", "Code review"])

        let removed = try await base.call(
            client, GroupMethod.remove, GroupParams(target: TargetHint(cwd: b.path), name: "code review"),
            as: GroupInfo.self)
        #expect(removed.rows.map(\.branch) == ["feat/b", "feat/a"])
        #expect(
            try await base.call(client, GroupMethod.list, GroupListParams(repo: "demo"), as: [GroupInfo].self).isEmpty)

        let taken = try await send(
            client, GroupMethod.new, .from(GroupParams(target: demo, name: "Later")))
        #expect(taken.error == nil)
        let duplicate = try await send(client, GroupMethod.new, .from(GroupParams(target: demo, name: "LATER")))
        #expect(duplicate.error?.code == "group_exists")
        let blank = try await send(client, GroupMethod.new, .from(GroupParams(target: demo, name: "  ")))
        #expect(blank.error?.code == "invalid_group_name")
        let untargeted = try await send(client, GroupMethod.new, .object(["name": "X"]))
        #expect(untargeted.error?.code == "missing_target")

        let methods = await logged(workspace, "cli").compactMap { event -> String? in
            if case .string(let method) = event.data["method"] { method } else { nil }
        }
        #expect(!methods.contains(GroupMethod.list))
        #expect(
            methods.filter { $0.hasPrefix("group.") } == [
                "group.new", "group.rename", "group.remove", "group.new", "group.new", "group.new", "group.new",
            ])
    }

    @Test func rowMoveTakesExactlyOneDestination() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = JSONValue.object(["target": .object(["repo": "demo", "row": "main"])])

        let none = try await send(client, ControlMethod.rowMove, target)
        #expect(none.error?.code == "bad_params")
        let two = try await send(
            client, ControlMethod.rowMove,
            .object(["target": .object(["repo": "demo", "row": "main"]), "group": "X", "noGroup": true]))
        #expect(two.error?.code == "bad_params")
        let main = try await send(
            client, ControlMethod.rowMove,
            .object(["target": .object(["repo": "demo", "row": "main"]), "noGroup": true]))
        #expect(main.error?.code == "cannot_move_main")
    }

    @Test func rowMoveResolvesAnchorsInTheRowsRepo() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let other = try await Fixture.repo(in: dir, name: "other")
        let (workspace, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        for path in [repo, other] {
            _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: path), as: RepoInfo.self)
        }
        for (name, branch) in [("demo", "feat/a"), ("demo", "feat/same"), ("other", "feat/same"), ("other", "feat/c")] {
            _ = try await base.call(
                client, ControlMethod.rowNew, RowNewParams(target: TargetHint(repo: name), branch: branch),
                as: RowNewResult.self)
        }
        func move(after anchor: String) async throws -> ControlResponse {
            try await send(
                client, ControlMethod.rowMove,
                .from(RowMoveParams(target: TargetHint(repo: "demo", row: "feat/a"), after: anchor)))
        }

        let moved = try await move(after: "feat/same")
        #expect(moved.error == nil)
        #expect(await workspace.snapshot.repo(path: repo)?.rows.map(\.displayName) == ["main", "feat/same", "feat/a"])
        #expect(try await move(after: "feat/c").error?.code == "invalid_anchor")
        #expect(try await move(after: "main").error?.code == "invalid_anchor")
        #expect(try await move(after: "feat/a").error?.code == "invalid_anchor")
        #expect(try await move(after: other).error?.code == "invalid_anchor")
        #expect(try await move(after: "feat/nope").error?.code == "row_not_found")
    }

    @Test func rowNewWithAMissingGroupFails() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)

        let response = try await send(
            client, ControlMethod.rowNew,
            .from(RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/a", group: "Nope")))

        #expect(response.error == ControlError(WorkspaceError.groupNotFound("Nope", repo: "demo")))
        #expect(!FileManager.default.fileExists(atPath: dir.sub("home/worktrees/demo/feat-a")))
    }

    @Test func selectingAHiddenRowUnfoldsItsGroup() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, ui) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        try await workspace.createGroup(repoPath: repo, name: "Review")
        let row = try await base.call(
            client, ControlMethod.rowNew,
            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/a", group: "Review"),
            as: RowNewResult.self
        ).row
        try await workspace.setGroupCollapsed(repoPath: repo, name: "Review", collapsed: true)

        _ = try await base.call(
            client, ControlMethod.rowSelect, RowRefParams(target: TargetHint(row: row.path)), as: Row.self)

        #expect(await workspace.snapshot.repo(path: repo)?.groups.first?.collapsed == false)
        #expect(ui.selected.withLock { $0 } == [row.path])
    }
}
