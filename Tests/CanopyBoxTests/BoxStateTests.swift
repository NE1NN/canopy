import CanopyAgents
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

struct BoxStateTests {
    @Test func eachCloneIsItsReposMainRow() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let rows = await daemon.snapshot().rows
        #expect(rows == [BoxRow(path: home.clone, repo: "demo", branch: "main", head: rows.first?.head, isMain: true)])
        #expect(rows.first?.head?.count == 40)
    }

    @Test func anUnconfiguredBoxHasNoRows() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon(configured: false)
        #expect(await daemon.snapshot() == BoxSnapshot())
        #expect(await daemon.isConfigured == false)
    }

    @Test func anUnknownWorktreeUnderTheFolderBecomesARow() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/x")
        let daemon = try await home.daemon()
        let row = await daemon.snapshot().rows.first { !$0.isMain }
        #expect(row?.path == path)
        #expect(row?.branch == "feat/x")
        #expect(row?.repo == "demo")
    }

    @Test func aWorktreeOutsideTheFolderIsLeftOut() async throws {
        let home = try await BoxTestHome()
        try await home.worktree("elsewhere", under: home.dir.sub("other"))
        let daemon = try await home.daemon()
        #expect(await daemon.snapshot().rows.map(\.isMain) == [true])
    }

    @Test func aSavedRowWhoseWorktreeIsGoneIsMissing() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/gone")
        _ = try await home.daemon()
        try FileManager.default.removeItem(atPath: path)
        try await GitFixture.git(["worktree", "prune"], in: home.clone)
        let restarted = try await home.daemon()
        let row = await restarted.snapshot().rows.first { $0.path == path }
        #expect(row?.missing == true)
    }

    @Test func aRestartKeepsPanesAndAgents() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/a")
        try await home.session("b3", in: path)
        let daemon = try await home.daemon()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        await daemon.report(
            pane: "b3", AgentReport(state: .working, session: "s", event: "UserPromptSubmit", at: started))
        let restarted = try await home.daemon()
        let pane = await restarted.snapshot().panes.first
        #expect(pane?.id == "b3")
        #expect(pane?.rowPath == path)
        #expect(pane?.agent == .working)
        #expect(await restarted.nextPane >= 4)
    }

    @Test func anUnknownSessionBecomesAPaneOfItsRow() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/s")
        try FileManager.default.createDirectory(atPath: path + "/sub", withIntermediateDirectories: true)
        try await home.session("p7", in: path + "/sub")
        try await home.session("stray", in: "/")
        let daemon = try await home.daemon()
        let panes = await daemon.snapshot().panes
        #expect(panes.map(\.id) == ["p7"])
        #expect(panes.first?.rowPath == path)
        #expect(await daemon.nextPane == 1)
    }

    @Test func aSavedPaneWhoseSessionIsGoneIsDropped() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/d")
        try await home.session("b1", in: path)
        _ = try await home.daemon()
        await home.server.tmux.killSession("b1")
        let restarted = try await home.daemon()
        #expect(await restarted.snapshot().panes.isEmpty)
        #expect(await restarted.nextPane == 2)
    }

    @Test func aDamagedStateFileIsRebuilt() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/r")
        try await home.session("b2", in: path)
        try FileManager.default.createDirectory(atPath: home.paths.folder, withIntermediateDirectories: true)
        try Data("{\"rows\": [tru".utf8).write(to: URL(fileURLWithPath: home.paths.stateFile))
        let daemon = try await home.daemon()
        let snapshot = await daemon.snapshot()
        #expect(snapshot.rows.map(\.path) == [home.clone, path])
        #expect(snapshot.panes.map(\.id) == ["b2"])
        #expect(await daemon.nextPane == 3)
    }

    @Test func theStateFileIsTheUsersAlone() async throws {
        let home = try await BoxTestHome()
        _ = try await home.daemon()
        var info = stat()
        #expect(lstat(home.paths.stateFile, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(lstat(home.paths.folder, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func adoptTakesRowsPanesAndTheNextNumber() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/m", under: home.dir.sub("mac-made"))
        try await home.session("p4", in: path)
        let daemon = try await home.daemon()
        var agent = PaneAgent()
        _ = agent.apply(AgentReport(state: .done, session: "s"), now: Date())
        let result = await daemon.adopt(
            BoxAdoptParams(
                rows: [BoxAdoptedRow(repo: "demo", path: path, branch: "feat/m")],
                panes: [
                    BoxAdoptedPane(id: "p4", rowPath: path, folder: path, agent: agent),
                    BoxAdoptedPane(id: "p9", rowPath: path, folder: path, agent: PaneAgent()),
                ], nextPane: 12))
        #expect(result == BoxAdoptResult(rows: [path], panes: ["p4"], missing: ["p9"]))
        let snapshot = await daemon.snapshot()
        #expect(snapshot.rows.map(\.path) == [home.clone, path])
        #expect(snapshot.panes.map(\.id) == ["p4"])
        #expect(snapshot.panes.first?.agent == .done)
        #expect(snapshot.panes.first?.unseen == true)
        #expect(await daemon.nextPane == 12)
        // A restart keeps an adopted row that is not under the worktrees folder.
        let restarted = try await home.daemon()
        #expect(await restarted.snapshot().rows.map(\.path) == [home.clone, path])
    }

    @Test func releaseHandsEverythingBack() async throws {
        let home = try await BoxTestHome()
        let path = try await home.worktree("feat/rel")
        try await home.session("b5", in: path)
        let daemon = try await home.daemon()
        let released = await daemon.release()
        #expect(released.rows == [BoxAdoptedRow(repo: "demo", path: path, branch: "feat/rel")])
        #expect(released.panes.map(\.id) == ["b5"])
        #expect(released.nextPane == 6)
        #expect(await daemon.snapshot().panes.isEmpty)
        #expect(await home.server.tmux.hasSession("b5"))
    }

    @Test func changesComeWithTheSnapshotAtOnce() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        var changes = await daemon.changes().makeAsyncIterator()
        let first = await changes.next()
        #expect(first?.rows.count == 1)
    }
}
