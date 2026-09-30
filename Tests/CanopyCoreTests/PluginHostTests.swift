import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PluginHostTests {
    struct Setup {
        let host: PluginHost
        let workspace: Workspace
        let terminals: TerminalStore
        let ui: RecordingUI
        let home: CanopyHome
    }

    /// A host on a temporary home whose config.json holds `config`, started, with its terminals closed at the end.
    func start(
        _ dir: TempDir, _ plugins: [TestPlugin], config: String? = nil, trash: (any FolderTrash)? = nil
    ) async throws -> Setup {
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        if let config {
            try config.write(to: home.configFile, atomically: true, encoding: .utf8)
        }
        let workspace = Workspace(home: home, git: Fixture.git)
        try await workspace.start()
        let terminals = Fixture.terminals(dir)
        let host = PluginHost(
            workspace: workspace, terminals: terminals, plugins: plugins, secrets: MemorySecretStore(),
            bundleID: "test", trash: trash ?? FolderMovingTrash(into: dir.sub("trash")))
        let ui = RecordingUI()
        host.ui = ui
        await host.start()
        return Setup(host: host, workspace: workspace, terminals: terminals, ui: ui, home: home)
    }

    func plugin(_ setup: Setup, _ id: String = "t") async -> PluginSection? {
        await setup.workspace.snapshot.section(id)
    }

    func events(_ setup: Setup) async -> [ActivityEvent] {
        await logged(setup.workspace, "plugin")
    }

    @Test func aPluginWithNoSectionStaysOff() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"minPaneColumns": 90}"#)

        #expect(await test.calls.isEmpty)
        #expect(await plugin(setup)?.isOn == false)
        #expect(await setup.workspace.snapshot.activePlugins.isEmpty)
        #expect(await setup.host.list().map(\.on) == [false])
        await #expect(throws: WorkspaceError.pluginOff("Test", command: "canopy plugin enable t")) {
            try await setup.host.createRow("t", reference: "i1", run: nil, select: false)
        }
    }

    @Test func aPluginOffSaysHowToTurnItOnItsOwnWay() async throws {
        let dir = try TempDir()
        let test = TestPlugin(turnOn: "canopy test connect")
        let setup = try await start(dir, [test], config: #"{"minPaneColumns": 90}"#)

        await #expect(throws: WorkspaceError.pluginOff("Test", command: "canopy test connect")) {
            try await setup.host.createRow("t", reference: "i1", run: nil, select: false)
        }
        #expect(
            WorkspaceError.pluginOff("Test", command: "canopy test connect").message.contains("`canopy test connect`"))
    }

    @Test func aPluginInConfigStartsWithItsSection() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let off = TestPlugin(id: "off")
        let setup = try await start(
            dir, [test, off], config: #"{"plugins": {"t": {"x": 1}, "off": {"enabled": false}}}"#)

        #expect(await test.calls == ["start"])
        #expect(await test.configs == [.object(["x": 1])])
        #expect(await off.calls.isEmpty)
        #expect(await setup.workspace.snapshot.activePlugins.map(\.id) == ["t"])
        let listing = await setup.host.list()
        #expect(listing.map(\.id) == ["t", "off"])
        #expect(listing[0].on && listing[0].status == "3 items" && listing[0].filters == test.filters)
        #expect(!listing[1].on && listing[1].status == nil)
        #expect(await events(setup).isEmpty)
    }

    @Test func aPluginThatFailsToStartShowsItsRowsAndWhy() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home, git: Fixture.git)
        try await workspace.start()
        await workspace.registerPlugins([PluginInfo(id: "t", name: "Test", symbol: "star")])
        try await workspace.addPluginRow(PluginRowEntry(item: "i1", title: "one", path: dir.sub("one")), plugin: "t")
        await workspace.stop()

        let setup = try await start(
            dir, [TestPlugin(startError: "No token. Run `x`.")], config: #"{"plugins": {"t": {}}}"#)

        let section = try #require(await plugin(setup))
        #expect(section.isOn)
        #expect(section.warning == "No token. Run `x`.")
        #expect(section.rows.map(\.title) == ["one"])
    }

    @Test func createsARowFromTheSeedIntoItsOwnFolder() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {}}}"#)

        let created = try await ActivitySource.$current.withValue(.cli) {
            try await setup.host.createRow("t", reference: "title-i2", run: nil, select: false)
        }

        let row = created.row
        #expect(row.item == "i2" && row.title == "title-i2" && row.plugin == "t")
        #expect(row.path == Paths.canonical(setup.home.root.path) + "/plugins/t/title-i2")
        #expect(created.pane == nil && created.fillError == nil)
        #expect(try String(contentsOfFile: row.path + "/item.txt", encoding: .utf8) == "i2")
        let permissions = try FileManager.default.attributesOfItem(atPath: row.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        #expect(await test.calls == ["start", "seed i2", "fill i2"])
        #expect(await plugin(setup)?.rows == [row])
        #expect(setup.ui.selected.withLock { $0 }.isEmpty)
        let event = try #require(await events(setup).first)
        #expect(event.type == "plugin.row.created")
        #expect(event.repo == nil && event.row == "title-i2" && event.path == row.path && event.source == .cli)
        #expect(event.data == ["plugin": "t", "item": "i2"])
    }

    @Test func anUnknownItemCreatesNothing() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)

        await #expect { try await setup.host.createRow("t", reference: "nope", run: nil, select: false) } throws: {
            ($0 as? ControlError)?.code == "item_not_found"
        }
        await #expect(throws: WorkspaceError.pluginNotFound("nope")) {
            try await setup.host.createRow("nope", reference: "i1", run: nil, select: false)
        }

        #expect(await plugin(setup)?.rows.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: setup.home.root.path + "/plugins/t/title-nope"))
    }

    @Test func aTakenFolderNameGetsASuffixAndOddNamesStayInside() async throws {
        let dir = try TempDir()
        let folders = ["i1": "same", "i2": "same", "i3": "../x/:y\u{7}"]
        let setup = try await start(dir, [TestPlugin(folders: folders)], config: #"{"plugins": {"t": {}}}"#)
        let root = Paths.canonical(setup.home.root.path) + "/plugins/t/"

        let first = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        let second = try await setup.host.createRow("t", reference: "i2", run: nil, select: false).row
        let odd = try await setup.host.createRow("t", reference: "i3", run: nil, select: false).row

        #expect(first.path == root + "same")
        #expect(second.path == root + "same-2")
        #expect(odd.path == root + "-x--y-")
    }

    @Test func aFolderOfARowWhoseFolderIsGoneIsNotReused() async throws {
        let dir = try TempDir()
        let setup = try await start(
            dir, [TestPlugin(folders: ["i1": "same", "i2": "same"])], config: #"{"plugins": {"t": {}}}"#)
        let first = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        try FileManager.default.removeItem(atPath: first.path)

        let second = try await setup.host.createRow("t", reference: "i2", run: nil, select: false).row

        #expect(second.path == first.path + "-2")
    }

    @Test func aSecondRowForTheSameItemFailsAndLeavesNoFolder() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {}}}"#)
        await test.stallFillsFromNow()

        let first = Task { try await setup.host.createRow("t", reference: "i1", run: nil, select: false) }
        #expect(await eventually { await test.stalledFills == 1 })
        await #expect(throws: WorkspaceError.self) {
            try await setup.host.createRow("t", reference: "i1", run: nil, select: false)
        }
        await test.releaseFills()
        let row = try await first.value.row

        #expect(await plugin(setup)?.rows == [row])
        let folders = try FileManager.default.contentsOfDirectory(atPath: setup.home.root.path + "/plugins/t")
        #expect(folders == ["title-i1"])
    }

    @Test func aRaceForTheSameItemEndsWithOneRowAndOneFolder() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)

        let host = setup.host
        let tasks = (0..<3).map { _ in Task { try await host.createRow("t", reference: "i1", run: nil, select: false) }
        }
        var results: [Result<PluginRowCreated, any Error>] = []
        for task in tasks {
            results.append(await task.result)
        }

        #expect(results.filter { (try? $0.get()) != nil }.count == 1)
        for case .failure(let error) in results {
            #expect((error as? WorkspaceError)?.code == "item_has_row")
        }
        #expect(await plugin(setup)?.rows.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.home.root.path + "/plugins/t").count == 1)
    }

    @Test func aFillThatFailsKeepsTheRowAndSkipsRun() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin(fillError: "Offline.")], config: #"{"plugins": {"t": {}}}"#)
        defer { setup.terminals.closeAll() }

        let created = try await setup.host.createRow("t", reference: "i1", run: "echo hi", select: false)

        #expect(created.fillError == "Offline.")
        #expect(created.pane == nil)
        #expect(await plugin(setup)?.rows.count == 1)
        #expect(setup.terminals.tabs(inRow: created.row.path).isEmpty)
        #expect(await events(setup).map(\.type) == ["plugin.row.created"])
    }

    @Test func runStartsInANewTerminalInTheRowBeforeItIsSelected() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        defer { setup.terminals.closeAll() }

        let created = try await setup.host.createRow(
            "t", reference: "i1", run: #"echo "ran:$CANOPY_ITEM" > ran.txt"#, select: true)

        let pane = try #require(created.pane)
        #expect(setup.terminals.tabs(inRow: created.row.path).flatMap(\.paneList).map(\.id.description) == [pane])
        #expect(setup.ui.selected.withLock { $0 } == [created.row.path])
        #expect(await setup.workspace.snapshot.selectedRowPath == created.row.path)
        #expect(
            await eventually {
                (try? String(contentsOfFile: created.row.path + "/ran.txt", encoding: .utf8)) == "ran:i1\n"
            })
    }

    @Test func removingClosesTerminalsTrashesTheFolderAndLogs() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        defer { setup.terminals.closeAll() }
        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        setup.terminals.openTab(for: PaneContext(pluginRow: row))
        try await setup.workspace.setPluginLink(PluginLink(plugin: "t", item: "i1"), forRow: "/w/fix")

        let removed = try await setup.host.removeRow(row, force: false)

        #expect(removed.row.path == row.path)
        let trashed = try #require(removed.trashedTo)
        #expect(trashed.hasPrefix(dir.sub("trash")))
        #expect(try String(contentsOfFile: trashed + "/item.txt", encoding: .utf8) == "i1")
        #expect(!FileManager.default.fileExists(atPath: row.path))
        #expect(setup.terminals.tabs(inRow: row.path).isEmpty)
        #expect(await plugin(setup)?.rows.isEmpty == true)
        #expect(await setup.workspace.pluginEntry("t")?.links == ["/w/fix": "i1"])
        #expect(await events(setup).map(\.type) == ["plugin.row.created", "plugin.row.removed"])
        #expect(await events(setup).last?.data == ["plugin": "t", "item": "i1"])
    }

    @Test func removingARowWithABusyTerminalAsksFirst() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        defer { setup.terminals.closeAll() }
        let created = try await setup.host.createRow("t", reference: "i1", run: "sleep 30", select: false)
        let pane = try #require(setup.terminals.panes.first { $0.id.description == created.pane })
        #expect(await eventually { pane.isBusy })

        await #expect(throws: WorkspaceError.rowBusy("title-i1", programs: ["sleep"])) {
            try await setup.host.removeRow(created.row, force: false)
        }
        #expect(await plugin(setup)?.rows.count == 1)

        _ = try await setup.host.removeRow(created.row, force: true)
        #expect(await plugin(setup)?.rows.isEmpty == true)
    }

    @Test func aRowWhoseFolderIsGoneIsStillRemoved() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        try FileManager.default.removeItem(atPath: row.path)

        let removed = try await setup.host.removeRow(row, force: false)

        #expect(removed.trashedTo == nil)
        #expect(await plugin(setup)?.rows.isEmpty == true)
    }

    @Test func aMissingFolderIsRecreatedAtStart() async throws {
        let dir = try TempDir()
        let first = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        let row = try await first.host.createRow("t", reference: "i1", run: nil, select: false).row
        await first.host.stop()
        await first.workspace.stop()
        try FileManager.default.removeItem(atPath: row.path)

        let test = TestPlugin()
        _ = try await start(dir, [test], config: #"{"plugins": {"t": {}}}"#)

        #expect(FileManager.default.fileExists(atPath: row.path))
        #expect(await eventually { FileManager.default.fileExists(atPath: row.path + "/item.txt") })
        #expect(await test.calls == ["start", "fill i1"])
    }

    @Test func aMissingFolderIsRecreatedBeforeATerminalOpens() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        try FileManager.default.removeItem(atPath: row.path)

        await setup.host.ensureFolder(row)

        #expect(try String(contentsOfFile: row.path + "/item.txt", encoding: .utf8) == "i1")
    }

    @Test func enableWritesConfigStartsAndLogs() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"zeta": true}"#)

        let listing = try await ActivitySource.$current.withValue(.cli) {
            try await setup.host.enable("t", with: ["url": "u"])
        }

        #expect(listing.on)
        #expect(await test.calls == ["start"])
        #expect(await test.configs == [.object(["url": "u"])])
        #expect(await plugin(setup)?.isOn == true)
        #expect(try PluginConfig.sections(in: setup.home.configFile)["t"] == .object(["url": "u"]))
        #expect(try String(contentsOf: setup.home.configFile, encoding: .utf8).contains(#""zeta": true"#))
        let events = await events(setup)
        #expect(events.map(\.type) == ["plugin.enabled"])
        #expect(events.first?.data == ["plugin": "t"] && events.first?.source == .cli)
        await #expect(throws: WorkspaceError.pluginNotFound("nope")) { try await setup.host.enable("nope") }
    }

    @Test func enablingAgainRestartsOnlyWhenTheSectionChanged() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {"url": "a"}}}"#)

        _ = try await setup.host.enable("t")
        _ = try await setup.host.enable("t", with: ["url": "b"])

        #expect(await test.calls == ["start", "stop", "start"])
        #expect(await test.configs.last == .object(["url": "b"]))
        #expect(await events(setup).isEmpty)
    }

    @Test func turningOffRefusesWhileProgramsRunUnlessForced() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {"url": "u"}}}"#)
        defer { setup.terminals.closeAll() }
        var closing: [String] = []
        setup.host.onClosingRows = { closing += $0 }
        let created = try await setup.host.createRow("t", reference: "i1", run: "sleep 30", select: false)
        let pane = try #require(setup.terminals.panes.first { $0.id.description == created.pane })
        #expect(await eventually { pane.isBusy })

        await #expect(throws: WorkspaceError.pluginBusy("Test", id: "t", programs: ["sleep"])) {
            try await setup.host.disable("t", force: false)
        }
        #expect(try PluginConfig.sections(in: setup.home.configFile)["t"] == .object(["url": "u"]))

        let listing = try await setup.host.disable("t", force: true)

        #expect(!listing.on)
        #expect(closing == [created.row.path])
        #expect(setup.terminals.tabs(inRow: created.row.path).isEmpty)
        #expect(await test.calls == ["start", "seed i1", "fill i1", "stop"])
        #expect(await plugin(setup)?.isOn == false)
        #expect(await plugin(setup)?.rows.count == 1)
        #expect(try PluginConfig.sections(in: setup.home.configFile)["t"] == .object(["url": "u", "enabled": false]))
        #expect(await events(setup).map(\.type) == ["plugin.row.created", "plugin.disabled"])
    }

    @Test func aConfigThatCannotBeWrittenChangesNothing() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: "{not json")

        await #expect { try await setup.host.enable("t") } throws: { ($0 as? WorkspaceError)?.code == "config_invalid" }

        #expect(await test.calls.isEmpty)
        #expect(await plugin(setup)?.isOn == false)
        #expect(try String(contentsOf: setup.home.configFile, encoding: .utf8) == "{not json")
    }

    @Test func theStateStreamFollowsRowsSelectionAndViewing() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {}}}"#)
        let context = try #require(setup.host.context("t"))
        let watching = Task { await test.watch(context) }
        defer { watching.cancel() }
        #expect(await eventually { await test.seenStates.count == 1 })
        #expect(
            await test.seenStates.first == PluginState(isOn: true, rows: [], selectedRow: nil, viewing: PluginViewing())
        )

        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        #expect(await eventually { await test.seenStates.last?.rows == [row] })
        try await setup.workspace.setSelectedRow(path: row.path)
        #expect(await eventually { await test.seenStates.last?.selectedRow == row })
        setup.host.viewing = PluginViewing(isWindowVisible: true, isFrontmost: true)
        #expect(await eventually { await test.seenStates.last?.viewing.isFrontmost == true })
        try await setup.workspace.setSelectedRow(path: "/somewhere/else")
        #expect(await eventually { await test.seenStates.last?.selectedRow == nil })
        #expect(context.state.rows == [row])
    }

    @Test func aPluginSeesItsRowsChangeAsSoonAsTheHostChangesThem() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        let context = try #require(setup.host.context("t"))

        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        #expect(context.state.rows == [row])
        _ = try await setup.host.removeRow(row, force: false)
        #expect(context.state.rows.isEmpty)
    }

    @Test func looksAndWarningsReachTheSnapshot() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        let context = try #require(setup.host.context("t"))
        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        let look = PluginRowLook(label: "#1", accessories: [.dot(.orange, help: "Waiting")])

        await context.setLooks([row.path: look])
        await context.setWarning("Offline. Run `x`.")

        let section = try #require(await plugin(setup))
        #expect(section.rows.first?.look == look)
        #expect(section.warning == "Offline. Run `x`.")
        #expect(context.folder.path == setup.home.root.path + "/plugins/t")
        #expect(context.secrets.service == "test.plugins.t")
    }

    @Test func itemsSayWhichRowEachHas() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {}}}"#)
        let row = try await setup.host.createRow("t", reference: "i2", run: nil, select: false).row

        let items = try await setup.host.items("t", matching: PluginQuery(text: "title", choice: "mine", fresh: false))

        #expect(items.map(\.id) == ["i1", "i2", "i3"])
        #expect(items.map(\.row) == [nil, row, nil])
        #expect(await test.queries == [PluginQuery(text: "title", choice: "mine", fresh: false)])
    }

    @Test func aLinkResolvesThroughItsPlugin() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)

        #expect(
            try await setup.host.resolveLink(plugin: "t", reference: "title-i2") == PluginLink(plugin: "t", item: "i2"))
        await #expect { try await setup.host.resolveLink(plugin: "t", reference: "nope") } throws: {
            ($0 as? ControlError)?.code == "item_not_found"
        }
    }

    @Test func methodsReachThePluginEvenWhileOffWithTheirRow() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let other = TestPlugin(id: "o")
        let setup = try await start(dir, [test, other], config: #"{"plugins": {"t": {}}}"#)
        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row

        #expect(setup.host.handles("t.echo") && setup.host.handles("o.echo") && !setup.host.handles("x.echo"))
        #expect(setup.host.readOnlyMethods == ["t.peek", "o.peek"])
        let echoed = try await setup.host.call("t.echo", params: .object([:]), target: TargetHint(), row: row)
        #expect(echoed == .object(["method": "t.echo", "row": "i1"]))
        let off = try await setup.host.call("o.echo", params: .object([:]), target: TargetHint(), row: row)
        #expect(off == .object(["method": "o.echo", "row": .null]))
        await #expect { try await setup.host.call("t.fail", params: .null, target: TargetHint(), row: nil) } throws: {
            ($0 as? ControlError)?.code == "test_failed"
        }
    }

    @Test func aStartThatFailedWithItsOwnCodeFailsEveryCommandWithIt() async throws {
        let dir = try TempDir()
        let test = TestPlugin(startError: "The Keychain refused: locked.", startCode: "keychain_failed")
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {"url": "u"}}}"#)
        #expect(await plugin(setup)?.warning == "The Keychain refused: locked.")
        let keychainFailed: @Sendable (any Error) -> Bool = {
            ($0 as? ControlError) == ControlError(code: "keychain_failed", message: "The Keychain refused: locked.")
        }
        await #expect(
            performing: { try await setup.host.createRow("t", reference: "i1", run: nil, select: false) },
            throws: keychainFailed)
        await #expect(performing: { try await setup.host.items("t", matching: PluginQuery()) }, throws: keychainFailed)
        await #expect(
            performing: { try await setup.host.resolveLink(plugin: "t", reference: "i1") },
            throws: keychainFailed)
    }

    @Test func enablingAgainRetriesAFailedStart() async throws {
        let dir = try TempDir()
        let test = TestPlugin(startError: "No token.")
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {"url": "u"}}}"#)
        await #expect(throws: WorkspaceError.pluginNotStarted("Test", reason: "No token.")) {
            try await setup.host.createRow("t", reference: "i1", run: nil, select: false)
        }

        await test.setStartError(nil)
        _ = try await setup.host.enable("t", with: ["url": "u"])

        #expect(await test.calls == ["start", "stop", "start"])
        #expect(await plugin(setup)?.warning == nil)
        _ = try await setup.host.createRow("t", reference: "i1", run: nil, select: false)
    }

    @Test func turningOnMakesMissingFoldersBeforeTheRowsShow() async throws {
        let dir = try TempDir()
        let first = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#)
        let row = try await first.host.createRow("t", reference: "i1", run: nil, select: false).row
        _ = try await first.host.disable("t", force: false)
        try FileManager.default.removeItem(atPath: row.path)
        let updates = await first.workspace.updates()
        let watcher = Task {
            for await snapshot in updates where snapshot.section("t")?.isOn == true {
                return FileManager.default.fileExists(atPath: row.path)
            }
            return false
        }

        _ = try await first.host.enable("t")

        #expect(await watcher.value)
        #expect(await eventually { FileManager.default.fileExists(atPath: row.path + "/item.txt") })
    }

    @Test func aSeedsRunStartsNewRowsUnlessTheRequestGivesOne() async throws {
        let dir = try TempDir()
        let setup = try await start(
            dir, [TestPlugin(defaultRun: #"echo seeded > run.txt"#)], config: #"{"plugins": {"t": {}}}"#)
        defer { setup.terminals.closeAll() }

        let seeded = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        let asked = try await setup.host.createRow("t", reference: "i2", run: "echo asked > run.txt", select: false).row

        #expect(
            await eventually { (try? String(contentsOfFile: seeded.path + "/run.txt", encoding: .utf8)) == "seeded\n" })
        #expect(
            await eventually { (try? String(contentsOfFile: asked.path + "/run.txt", encoding: .utf8)) == "asked\n" })
    }

    @Test func aRowMadeWhileItsPluginTurnsOffGetsNoTerminal() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {}}}"#)
        defer { setup.terminals.closeAll() }
        await test.stallFillsFromNow()

        let creating = Task { try await setup.host.createRow("t", reference: "i1", run: "sleep 30", select: false) }
        #expect(await eventually { await test.stalledFills == 1 })
        _ = try await setup.host.disable("t", force: true)
        await test.releaseFills()
        let created = try await creating.value

        #expect(created.pane == nil)
        #expect(setup.terminals.tabs(inRow: created.row.path).isEmpty)
    }

    @Test func aTrashThatFailsKeepsTheRowAndItsTerminals() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()], config: #"{"plugins": {"t": {}}}"#, trash: RefusingTrash())
        defer { setup.terminals.closeAll() }
        let row = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        setup.terminals.openTab(for: PaneContext(pluginRow: row))

        await #expect { try await setup.host.removeRow(row, force: false) } throws: {
            ($0 as? WorkspaceError)?.code == "trash_failed"
        }

        #expect(setup.terminals.tabs(inRow: row.path).count == 1)
        #expect(await plugin(setup)?.rows.count == 1)
    }

    @Test func folderNamesIgnoreCaseAndStayShort() async throws {
        let dir = try TempDir()
        let long = String(repeating: "é", count: 300)
        let setup = try await start(
            dir, [TestPlugin(folders: ["i1": "Foo", "i2": "foo", "i3": long])], config: #"{"plugins": {"t": {}}}"#)
        let first = try await setup.host.createRow("t", reference: "i1", run: nil, select: false).row
        try FileManager.default.removeItem(atPath: first.path)

        let second = try await setup.host.createRow("t", reference: "i2", run: nil, select: false).row
        let third = try await setup.host.createRow("t", reference: "i3", run: nil, select: false).row

        #expect(second.path.hasSuffix("/foo-2"))
        #expect((third.path as NSString).lastPathComponent.utf8.count <= 200)
    }

    @Test func setConfigWritesOneKeyAndKeepsThePluginRunning() async throws {
        let dir = try TempDir()
        let test = TestPlugin()
        let setup = try await start(dir, [test], config: #"{"plugins": {"t": {"url": "u"}}}"#)
        let context = try #require(setup.host.context("t"))

        try await context.setConfig("repo", to: "demo")
        #expect(context.config == .object(["url": "u", "repo": "demo"]))
        #expect(try PluginConfig.sections(in: setup.home.configFile)["t"] == .object(["url": "u", "repo": "demo"]))
        // The section as written counts as unchanged, so enabling with it restarts nothing.
        _ = try await setup.host.enable("t", with: ["repo": "demo"])

        try await context.setConfig("repo", to: nil)
        #expect(context.config == .object(["url": "u"]))
        await #expect { try await context.setConfig("enabled", to: false) } throws: {
            ($0 as? ControlError)?.code == "bad_params"
        }
        #expect(context.config == .object(["url": "u"]))
        #expect(await test.calls == ["start"])
    }

    @Test func aContextFindsReposByNameOrPathWithTheirDefaultBranch() async throws {
        let dir = try TempDir()
        let setup = try await start(dir, [TestPlugin()])
        let cloned = try await Fixture.repo(in: dir, name: "cloned", origin: true)
        let local = try await Fixture.repo(in: dir, name: "local")
        _ = try await setup.workspace.addRepo(path: cloned)
        _ = try await setup.workspace.addRepo(path: local)
        let context = try #require(setup.host.context("t"))

        #expect(await context.repos().map(\.name) == ["cloned", "local"])
        #expect(await context.repo(named: "cloned")?.path == cloned)
        #expect(await context.repo(named: local)?.name == "local")
        #expect(await context.repo(named: "nope") == nil)
        #expect(await context.defaultBranch(ofRepo: cloned) == "main")
        #expect(await context.defaultBranch(ofRepo: local) == nil)
    }
}
