import Foundation
import Testing

@testable import CanopyCore

/// Plugin rows and plugin methods through the control socket, as the CLI sends them.
struct PluginControlTests {
    struct Setup: Sendable {
        let workspace: Workspace
        let server: ControlServer
        let client: ControlClient
        let ui: RecordingUI
        let host: PluginHost
        let repo: String
        let home: CanopyHome
    }

    /// A workspace with the demo repo, a test plugin that config.json turns on unless `on` is false, and the control
    /// server in front of both.
    func start(_ dir: TempDir, on: Bool = true, plugin: TestPlugin = TestPlugin()) async throws -> Setup {
        let repo = try await Fixture.repo(in: dir)
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        try (on ? #"{"plugins": {"t": {}}}"# : "{}").write(to: home.configFile, atomically: true, encoding: .utf8)
        let workspace = Workspace(home: home, git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let ui = RecordingUI()
        let (rows, host) = await MainActor.run {
            let terminals = Fixture.terminals(dir)
            let host = PluginHost(
                workspace: workspace, terminals: terminals, plugins: [plugin], secrets: MemorySecretStore(),
                bundleID: "test", trash: MovingTrash(into: dir.sub("trash")))
            host.ui = ui
            return (RowLifecycle(workspace: workspace, terminals: terminals), host)
        }
        await host.start()
        let handler = WorkspaceControlHandler(rows: rows, plugins: host, ui: ui)
        let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
        try await server.start()
        return Setup(
            workspace: workspace, server: server, client: ControlClient(socketPath: home.socketPath, timeout: 60),
            ui: ui, host: host, repo: repo, home: home)
    }

    func stop(_ setup: Setup) {
        setup.server.stop()
        Task { @MainActor in setup.host.terminals.closeAll() }
    }

    func call<T: Decodable & Sendable>(
        _ setup: Setup, _ method: String, _ params: some Encodable, as: T.Type
    ) async throws -> T {
        let response = try await send(setup, method, params)
        if let error = response.error { throw error }
        return try #require(response.result).decode(T.self)
    }

    func send(_ setup: Setup, _ method: String, _ params: some Encodable) async throws -> ControlResponse {
        let request = ControlRequest(method: method, params: try .from(params))
        let client = setup.client
        return try await offPool { try client.send(request) }
    }

    func errorCode(_ setup: Setup, _ method: String, _ params: some Encodable) async throws -> String? {
        try await send(setup, method, params).error?.code
    }

    func newRow(_ setup: Setup, _ reference: String) async throws -> PluginRow {
        try await call(
            setup, PluginMethod.new, PluginNewParams(plugin: "t", reference: reference), as: PluginRowCreated.self
        ).row
    }

    @Test func listEnableAndDisableOverTheSocket() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, on: false)
        defer { stop(setup) }

        var listed = try await call(setup, PluginMethod.list, JSONValue.null, as: [PluginListing].self)
        #expect(listed.map(\.on) == [false])

        let enabled = try await call(
            setup, PluginMethod.enable, PluginEnableParams(plugin: "t", fields: ["url": "u"]), as: PluginListing.self)
        #expect(enabled.on && enabled.status == "3 items")
        listed = try await call(setup, PluginMethod.list, JSONValue.null, as: [PluginListing].self)
        #expect(listed.map(\.on) == [true])

        let disabled = try await call(
            setup, PluginMethod.disable, PluginDisableParams(plugin: "t"), as: PluginListing.self)
        #expect(!disabled.on)
        #expect(
            try await errorCode(setup, PluginMethod.enable, PluginEnableParams(plugin: "nope")) == "plugin_not_found")
    }

    @Test func itemsTakeFiltersByIdAndRefuseUnknownOnes() async throws {
        let dir = try TempDir()
        let plugin = TestPlugin()
        let setup = try await start(dir, plugin: plugin)
        defer { stop(setup) }
        let row = try await newRow(setup, "i2")

        let items = try await call(
            setup, PluginMethod.items, PluginItemsParams(plugin: "t", query: "i", filters: ["mine", "closed"]),
            as: [PluginItem].self)

        #expect(items.map(\.id) == ["i1", "i2", "i3"])
        #expect(items.map(\.row?.path) == [nil, row.path, nil])
        #expect(await plugin.queries == [PluginQuery(text: "i", choice: "mine", toggles: ["closed"], fresh: true)])
        _ = try await call(setup, PluginMethod.items, PluginItemsParams(plugin: "t"), as: [PluginItem].self)
        #expect(await plugin.queries.last?.choice == "all")
        let both = PluginItemsParams(plugin: "t", filters: ["mine", "all"])
        #expect(try await errorCode(setup, PluginMethod.items, both) == "bad_params")
        let unknown = PluginItemsParams(plugin: "t", filters: ["open"])
        #expect(try await errorCode(setup, PluginMethod.items, unknown) == "bad_params")
    }

    @Test func aPluginThatIsOffRefusesItemsAndRows() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, on: false)
        defer { stop(setup) }

        #expect(try await errorCode(setup, PluginMethod.items, PluginItemsParams(plugin: "t")) == "plugin_off")
        #expect(
            try await errorCode(setup, PluginMethod.new, PluginNewParams(plugin: "t", reference: "i1")) == "plugin_off")
    }

    @Test func newListSelectAndRemoveAPluginRow() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }

        let created = try await call(
            setup, PluginMethod.new,
            PluginNewParams(plugin: "t", reference: "i1", run: #"echo "$CANOPY_ITEM" > got"#, select: true),
            as: PluginRowCreated.self)
        let row = created.row
        #expect(created.pane != nil)
        #expect(setup.ui.selected.withLock { $0 } == [row.path])
        #expect(await eventually { (try? String(contentsOfFile: row.path + "/got", encoding: .utf8)) == "i1\n" })

        let rows = try await call(setup, ControlMethod.rowList, RowListParams(), as: [SidebarRow].self)
        #expect(rows.map(\.displayName) == ["main", "title-i1"])
        #expect(rows.last == .plugin(row))
        let json = try await call(setup, ControlMethod.rowList, RowListParams(), as: [[String: JSONValue]].self)
        #expect(json.last?["plugin"] == "t" && json.last?["item"] == "i1" && json.last?["path"] == .string(row.path))

        let selected = try await call(
            setup, ControlMethod.rowSelect, RowRefParams(target: TargetHint(row: row.path)), as: SidebarRow.self)
        #expect(selected == .plugin(row))

        let removed = try await call(
            setup, ControlMethod.rowRemove, RowRemoveParams(target: TargetHint(envRowPath: row.path)),
            as: RowRemoveResult.self)
        #expect(removed.row == .plugin(row))
        #expect(removed.trashedTo?.hasPrefix(dir.sub("trash")) == true)
        #expect(try await call(setup, ControlMethod.rowList, RowListParams(), as: [SidebarRow].self).count == 1)
    }

    @Test func aSecondNewForTheItemNamesTheRow() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")

        let response = try await send(setup, PluginMethod.new, PluginNewParams(plugin: "t", reference: "title-i1"))

        #expect(response.error?.code == "item_has_row")
        #expect(response.error?.message.contains(row.path) == true)
    }

    @Test func removingAPluginRowRefusesToDeleteABranch() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")

        let params = RowRemoveParams(target: TargetHint(row: row.path), deleteBranch: true)
        #expect(try await errorCode(setup, ControlMethod.rowRemove, params) == "bad_params")
    }

    @Test func rowListWithARepoLeavesPluginRowsOut() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        _ = try await newRow(setup, "i1")

        let rows = try await call(setup, ControlMethod.rowList, RowListParams(repo: "demo"), as: [SidebarRow].self)

        #expect(rows.map(\.displayName) == ["main"])
    }

    @Test func termNewAndListInAPluginRowFromItsFolder() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")
        try FileManager.default.removeItem(atPath: row.path)

        let opened = try await call(
            setup, TermMethod.new, TermNewParams(target: TargetHint(cwd: row.path + "/deeper")), as: TermNewResult.self)
        let listed = try await call(
            setup, TermMethod.list, TermListParams(target: TargetHint(envRowPath: row.path)), as: [TermInfo].self)

        #expect(listed.map(\.pane) == [opened.pane])
        #expect(listed.first?.plugin == "t" && listed.first?.repo == nil && listed.first?.row == "title-i1")
        #expect(FileManager.default.fileExists(atPath: row.path + "/item.txt"))
    }

    @Test func prShowOnAPluginRowSaysItHasNoPR() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")

        let params = PRShowParams(target: TargetHint(envRowPath: row.path))
        #expect(try await errorCode(setup, ControlMethod.prShow, params) == "no_pr_lookup")
    }

    @Test func pluginRowsMoveOnlyBeforeOrAfterEachOther() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let one = try await newRow(setup, "i1")
        let two = try await newRow(setup, "i2")
        let main = try #require(await setup.workspace.snapshot.repos.first?.rows.first)

        let moved = try await call(
            setup, ControlMethod.rowMove, RowMoveParams(target: TargetHint(row: two.path), before: one.path),
            as: RowMoveResult.self)
        #expect(moved.moved && moved.row == .plugin(two) && moved.from == nil)
        #expect(await setup.workspace.snapshot.section("t")?.rows.map(\.item) == ["i2", "i1"])

        let group = RowMoveParams(target: TargetHint(row: one.path), group: "Review")
        #expect(try await errorCode(setup, ControlMethod.rowMove, group) == "bad_params")
        let intoRepo = RowMoveParams(target: TargetHint(row: one.path), after: main.path)
        #expect(try await errorCode(setup, ControlMethod.rowMove, intoRepo) == "invalid_anchor")
        let fromRepo = RowMoveParams(target: TargetHint(repo: "demo", row: "main"), after: one.path)
        #expect(try await errorCode(setup, ControlMethod.rowMove, fromRepo) == "invalid_anchor")
    }

    @Test func anUnresolvableLinkFailsBeforeGitRuns() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }

        let unknown = RowNewParams(
            target: TargetHint(repo: "demo"), branch: "fix/a", link: RowLinkParams(plugin: "t", reference: "nope"))
        #expect(try await errorCode(setup, ControlMethod.rowNew, unknown) == "item_not_found")
        let noPlugin = RowNewParams(
            target: TargetHint(repo: "demo"), branch: "fix/a", link: RowLinkParams(plugin: "x", reference: "i1"))
        #expect(try await errorCode(setup, ControlMethod.rowNew, noPlugin) == "plugin_not_found")

        #expect(await setup.workspace.snapshot.repos.first?.rows.count == 1)
        #expect(!(await Fixture.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/fix/a"], in: setup.repo)))
    }

    @Test func aLinkedRowNewLogsTheLink() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }

        let created = try await call(
            setup, ControlMethod.rowNew,
            RowNewParams(
                target: TargetHint(repo: "demo"), branch: "fix/a",
                link: RowLinkParams(plugin: "t", reference: "title-i2")),
            as: RowNewResult.self)

        #expect(created.row.link == PluginLink(plugin: "t", item: "i2"))
        let event = await logged(setup.workspace, "row").first
        #expect(event?.data["link"] == .object(["plugin": "t", "item": "i2"]))
    }

    @Test func pluginMethodsGetTheirTargetRow() async throws {
        let dir = try TempDir()
        let plugin = TestPlugin()
        let setup = try await start(dir, plugin: plugin)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")

        let inRow = try await call(
            setup, "t.echo", JSONValue.object(["target": try .from(TargetHint(cwd: row.path))]), as: JSONValue.self)
        let outside = try await call(setup, "t.echo", JSONValue.object([:]), as: JSONValue.self)

        #expect(inRow == .object(["method": "t.echo", "row": "i1"]))
        #expect(outside == .object(["method": "t.echo", "row": .null]))
        #expect(await plugin.handled.first?.target.cwd == row.path)
        #expect(try await errorCode(setup, "t.fail", JSONValue.null) == "test_failed")
        #expect(try await errorCode(setup, "nobody.echo", JSONValue.null) == "unknown_method")
    }

    @Test func readOnlyPluginMethodsAreNotLoggedAndTokensNeverAre() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }

        _ = try await call(setup, PluginMethod.list, JSONValue.null, as: JSONValue.self)
        _ = try await call(setup, PluginMethod.items, PluginItemsParams(plugin: "t"), as: JSONValue.self)
        _ = try await call(setup, "t.peek", JSONValue.null, as: JSONValue.self)
        let secret: JSONValue = .object([
            "token": "s3cret", "url": "u", "nested": .object(["token": "x", "keep": 1]),
            "list": .array([.object(["token": "y"])]),
        ])
        _ = try await call(setup, "t.echo", secret, as: JSONValue.self)

        await setup.workspace.activity.flush()
        let calls = activityEvents(setup.workspace.activity.folder).filter { $0.type == ActivityType.cliCall }
        #expect(calls.compactMap { $0.data["method"] } == ["t.echo"])
        #expect(
            calls.first?.data["params"]
                == .object(["url": "u", "nested": .object(["keep": 1]), "list": .array([.object([:])])]))
        let files = try FileManager.default.contentsOfDirectory(atPath: setup.workspace.activity.folder.path)
        for file in files {
            let text = try String(contentsOf: setup.workspace.activity.folder.appending(path: file), encoding: .utf8)
            #expect(!text.contains("s3cret"))
        }
    }
}
