import Foundation
import Testing

@testable import CanopyCore

/// Folding repos, groups, and plugin sections through the control socket, as the CLI sends it.
struct FoldControlTests {
    let base = ControlServerTests()
    let plugins = PluginControlTests()

    func send(_ client: ControlClient, _ method: String, _ params: some Encodable) async throws -> ControlResponse {
        let request = ControlRequest(method: method, params: try .from(params))
        return try await offPool { try client.send(request) }
    }

    @Test func reposFoldOverTheSocketAndOnlyTheCallsAreLogged() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let demo = RepoFoldParams(target: TargetHint(repo: "demo"))

        #expect(
            try await base.call(client, ControlMethod.repoList, JSONValue.null, as: [RepoInfo].self).first?.collapsed
                == false)
        for _ in 1...2 {
            let folded = try await base.call(client, ControlMethod.repoCollapse, demo, as: RepoInfo.self)
            #expect(folded.name == "demo" && folded.collapsed)
        }
        #expect(
            try await base.call(client, ControlMethod.repoList, JSONValue.null, as: [RepoInfo].self).first?.collapsed
                == true)
        // The repo a command runs in, when no repo is named.
        let inside = RepoFoldParams(target: TargetHint(cwd: repo))
        #expect(try await base.call(client, ControlMethod.repoExpand, inside, as: RepoInfo.self).collapsed == false)
        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == false)

        let unknown = try await send(
            client, ControlMethod.repoCollapse, RepoFoldParams(target: TargetHint(repo: "nope")))
        #expect(unknown.error?.code == "repo_not_found")
        let untargeted = try await send(client, ControlMethod.repoCollapse, JSONValue.object([:]))
        #expect(untargeted.error?.code == "missing_target")

        let events = await logged(workspace, "repo", "row", "group", "cli")
        #expect(events.filter { $0.type != ActivityType.cliCall }.map(\.type) == [ActivityType.repoAdded])
        let methods = events.compactMap { event -> String? in
            guard case .string(let method) = event.data["method"] else { return nil }
            return method
        }
        #expect(
            methods == [
                ControlMethod.repoAdd, ControlMethod.repoCollapse, ControlMethod.repoCollapse,
                ControlMethod.repoExpand, ControlMethod.repoCollapse, ControlMethod.repoCollapse,
            ])
    }

    @Test func groupsFoldOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        try await workspace.createGroup(repoPath: repo, name: "Review")
        let demo = TargetHint(repo: "demo")

        for _ in 1...2 {
            let folded = try await base.call(
                client, GroupMethod.collapse, GroupParams(target: demo, name: " review "), as: GroupInfo.self)
            #expect(folded == GroupInfo(repo: "demo", repoPath: repo, name: "Review", collapsed: true, rows: []))
        }
        let listed = try await base.call(client, GroupMethod.list, GroupListParams(repo: "demo"), as: [GroupInfo].self)
        #expect(listed.map(\.collapsed) == [true])
        let open = try await base.call(
            client, GroupMethod.expand, GroupParams(target: demo, name: "REVIEW"), as: GroupInfo.self)
        #expect(open.collapsed == false)

        let missing = try await send(client, GroupMethod.collapse, GroupParams(target: demo, name: "Nope"))
        #expect(missing.error?.code == "group_not_found")
        #expect(await logged(workspace, "group").map(\.type) == [ActivityType.groupCreated])
    }

    @Test func pluginsFoldOverTheSocket() async throws {
        let dir = try TempDir()
        let setup = try await plugins.start(dir)
        defer { plugins.stop(setup) }

        for _ in 1...2 {
            let folded = try await plugins.call(
                setup, PluginMethod.collapse, PluginFoldParams(plugin: "t"), as: PluginListing.self)
            #expect(folded.id == "t" && folded.collapsed)
        }
        let listed = try await plugins.call(setup, PluginMethod.list, JSONValue.null, as: [PluginListing].self)
        #expect(listed.map(\.collapsed) == [true])
        let open = try await plugins.call(
            setup, PluginMethod.expand, PluginFoldParams(plugin: "t"), as: PluginListing.self)
        #expect(open.collapsed == false)
        #expect(
            try await plugins.errorCode(setup, PluginMethod.collapse, PluginFoldParams(plugin: "nope"))
                == "plugin_not_found")
    }

    @Test func selectingOverTheSocketUnfolds() async throws {
        let dir = try TempDir()
        let setup = try await plugins.start(dir)
        defer { plugins.stop(setup) }
        let (workspace, repo) = (setup.workspace, setup.repo)
        let demo = TargetHint(repo: "demo")
        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)

        let quiet = try await plugins.call(
            setup, ControlMethod.rowNew, RowNewParams(target: demo, branch: "feat/quiet"), as: RowNewResult.self)
        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == true)
        _ = try await plugins.call(
            setup, ControlMethod.rowNew, RowNewParams(target: demo, branch: "feat/shown", select: true),
            as: RowNewResult.self)
        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == false)

        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)
        _ = try await plugins.call(
            setup, ControlMethod.rowSelect, RowRefParams(target: TargetHint(row: quiet.row.path)), as: Row.self)
        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == false)
        #expect(setup.ui.selected.withLock { $0 }.last == quiet.row.path)

        try await workspace.setPluginCollapsed("t", collapsed: true)
        _ = try await plugins.newRow(setup, "i1")
        #expect(await workspace.snapshot.section("t")?.collapsed == true)
        let selected = try await plugins.call(
            setup, PluginMethod.new, PluginNewParams(plugin: "t", reference: "i2", select: true),
            as: PluginRowCreated.self
        ).row
        #expect(await workspace.snapshot.section("t")?.collapsed == false)
        #expect(setup.ui.selected.withLock { $0 }.last == selected.path)
    }
}
