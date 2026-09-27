import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct RowSetupTests {
    /// A repo whose main branch commits `config` as `.canopy/config.json`, so new rows get it and start clean.
    /// Commands write to the folder above the repo, `dir`, to keep rows clean for removal.
    func setUp(_ dir: TempDir, config: String?, name: String = "demo") async throws -> (String, RowLifecycle) {
        let repo = try await Fixture.repo(in: dir, name: name)
        if let config {
            try FileManager.default.createDirectory(atPath: repo + "/.canopy", withIntermediateDirectories: true)
            try config.write(toFile: repo + "/.canopy/config.json", atomically: true, encoding: .utf8)
            try await Fixture.git.run(["add", ".canopy"], in: repo)
            try await Fixture.git.run(["commit", "--quiet", "-m", "config"], in: repo)
        }
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (repo, RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)))
    }

    func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    @Test func setupRunsInTheRowWithItsVariablesThenLeavesATerminal() async throws {
        let dir = try TempDir()
        let config = #"""
            {"setup": ["printf '%s|%s|%s|%s|%s' \"$CANOPY_ROOT_PATH\" \"$CANOPY_ROW_PATH\" \"$CANOPY_REPO\" \"$CANOPY_ROW\" \"$(pwd -P)\" > \"$CANOPY_ROOT_PATH/../setup.out\""]}
            """#
        let (repo, rows) = try await setUp(dir, config: config, name: "my repo")
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/setup").row

        let ready = await rows.prepare(row, repoName: "my repo", setup: true, run: nil).value

        #expect(ready.setup == SetupReport(status: .succeeded, exitCode: 0))
        #expect(read(dir.sub("setup.out")) == "\(repo)|\(row.path)|my repo|feat/setup|\(row.path)")
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Terminal"])
    }

    @Test func setupTabOpensBeforePrepareReturns() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["sleep 0.5"]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/slow").row

        let task = rows.prepare(row, repoName: "demo", setup: true, run: nil)

        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Setup"])
        #expect(await task.value.setup.status == .succeeded)
    }

    @Test func failedSetupStaysOpenAndSkipsRun() async throws {
        let dir = try TempDir()
        let config = #"{"setup": ["exit 5", "touch \"$CANOPY_ROOT_PATH/../never\""]}"#
        let (repo, rows) = try await setUp(dir, config: config)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/broken").row

        let ready = await rows.prepare(row, repoName: "demo", setup: true, run: "touch ran").value

        #expect(ready.setup.status == .failed)
        #expect(ready.setup.exitCode == 5)
        #expect(ready.setup.message?.contains("Setup tab") == true)
        #expect(ready.pane == nil)
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Setup"])
        #expect(!FileManager.default.fileExists(atPath: dir.sub("never")))
        #expect(await rows.workspace.snapshot.row(path: row.path) != nil)
    }

    @Test func runStartsOnceSetupSucceeds() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["true"]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/run").row

        let ready = await rows.prepare(
            row, repoName: "demo", setup: true, run: #"echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran""#
        ).value

        let pane = try #require(ready.pane)
        #expect(await eventually { read(dir.sub("ran")) == "\(pane)\n" })
        #expect(rows.terminals.tabs(inRow: row.path).map(\.pane.id) == [pane])
    }

    @Test func runStartsAtOnceWithoutSetupCommands() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/plain").row

        let task = rows.prepare(row, repoName: "demo", setup: true, run: "echo hi")

        #expect(rows.terminals.tabs(inRow: row.path).count == 1)
        let ready = await task.value
        #expect(ready.setup.status == .none)
        #expect(ready.pane == rows.terminals.tabs(inRow: row.path).first?.pane.id)
    }

    @Test func setupCanBeSkipped() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["touch \"$CANOPY_ROOT_PATH/../ran\""]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/skip").row

        let ready = await rows.prepare(row, repoName: "demo", setup: false, run: nil).value

        #expect(ready.setup.status == .skipped)
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.sub("ran")))
    }

    @Test func unreadableConfigFailsSetupAndSaysWhere() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": "bun install"}"#)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/bad").row

        let ready = await rows.prepare(row, repoName: "demo", setup: true, run: "echo hi").value

        #expect(ready.setup.status == .failed)
        #expect(ready.setup.message?.contains(".canopy/config.json") == true)
        #expect(ready.setup.message?.contains("setup") == true)
        #expect(ready.pane == nil)
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }

    @Test func closingTheSetupTabStopsSetup() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["sleep 30"]}"#)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/stop").row
        let task = rows.prepare(row, repoName: "demo", setup: true, run: nil)

        let setupTab = try #require(rows.terminals.tabs(inRow: row.path).first)
        rows.terminals.closeTab(setupTab.id, inRow: row.path)

        let ready = await task.value
        #expect(ready.setup.status == .failed)
        #expect(ready.setup.message == "Setup stopped because its tab was closed.")
    }

    @Test func parallelRunsGetTheirOwnPanes() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }
        let workspace = rows.workspace
        async let first = workspace.createRow(repoPath: repo, branch: "agent/one")
        async let second = workspace.createRow(repoPath: repo, branch: "agent/two")
        async let third = workspace.createRow(repoPath: repo, branch: "agent/three")
        let created = try await [first, second, third].map(\.row)

        let tasks = created.map { row in
            rows.prepare(
                row, repoName: "demo", setup: true,
                run: #"echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../$(basename "$CANOPY_ROW").out""#)
        }
        var panes: [PaneID] = []
        for task in tasks {
            panes.append(try #require(await task.value.pane))
        }

        #expect(Set(panes).count == 3)
        for (row, pane) in zip(created, panes) {
            let file = dir.sub((row.branch! as NSString).lastPathComponent + ".out")
            #expect(await eventually { read(file) == "\(pane)\n" })
        }
    }

    @Test func teardownRunsThenTheRowGoes() async throws {
        let dir = try TempDir()
        let config = #"{"teardown": ["echo \"$CANOPY_ROW\" > \"$CANOPY_ROOT_PATH/../teardown.out\""]}"#
        let (repo, rows) = try await setUp(dir, config: config)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/done").row
        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).pane.pid)

        try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)

        #expect(read(dir.sub("teardown.out")) == "feat/done\n")
        #expect(!FileManager.default.fileExists(atPath: row.path))
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
        #expect(await eventually { processGroupEnded(shell) })
    }

    @Test func failedTeardownKeepsTheRowUnlessForced() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["exit 6"]}"#)
        defer { rows.terminals.closeAll() }
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/stuck").row

        await #expect(throws: WorkspaceError.teardownFailed(6)) {
            try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: row.path))
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Teardown"])

        try await rows.remove(row, repoName: "demo", force: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: row.path))
    }

    @Test func uncommittedChangesStopRemovalBeforeTeardown() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["touch \"$CANOPY_ROOT_PATH/../torn\""]}"#)
        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/dirty").row
        try "x".write(toFile: row.path + "/new.txt", atomically: true, encoding: .utf8)

        await #expect(throws: WorkspaceError.worktreeDirty(row.path)) {
            try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.sub("torn")))
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }

    @Test func removingAMissingRowSkipsTeardown() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["exit 1"]}"#)
        let created = try await rows.workspace.createRow(repoPath: repo, branch: "feat/gone").row
        try FileManager.default.removeItem(atPath: created.path)
        await rows.workspace.refresh(repoPath: repo)
        let row = try #require(await rows.workspace.snapshot.row(path: created.path))
        #expect(row.isMissing)

        try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)

        #expect(await rows.workspace.snapshot.row(path: created.path) == nil)
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }

    @Test func removingAnAdoptedRowClosesItsTerminalsAndKeepsItsFiles() async throws {
        let dir = try TempDir()
        let (repo, rows) = try await setUp(dir, config: #"{"teardown": ["exit 1"]}"#)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        let row = try await rows.workspace.adopt(path: dir.sub("theirs"))
        rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo"))

        try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)

        #expect(FileManager.default.fileExists(atPath: dir.sub("theirs")))
        #expect(rows.terminals.tabs(inRow: row.path).isEmpty)
    }
}
