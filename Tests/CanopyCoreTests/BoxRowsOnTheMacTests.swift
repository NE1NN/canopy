import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// An upgraded host's rows, as its canopy-box's snapshots say.
struct BoxRowsOnTheMacTests {
    func setUp(_ dir: TempDir) async throws -> (Workspace, String) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        try HostsConfigFile(url: workspace.home.configFile).save(
            "box", HostEntry(repos: ["demo": "/home/u/demo"], box: true))
        return (workspace, repo)
    }

    static func snapshot(_ rows: [String]) -> BoxSnapshot {
        BoxSnapshot(
            rows: [BoxRow(path: "/home/u/demo", repo: "demo", branch: "main", isMain: true)]
                + rows.map {
                    BoxRow(path: "/home/u/.canopy/0/worktrees/demo/\($0)", repo: "demo", branch: $0, head: "abc")
                })
    }

    @Test func aSnapshotsRowsBecomeRemoteRows() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let updates = await workspace.boxUpdates()
        await workspace.applyBoxSnapshot(Self.snapshot(["feat-a", "feat-b"]), host: "box")
        let rows = try #require(await workspace.snapshot.repo(path: repo)?.rows)
        #expect(rows.map(\.rowClass) == [.main, .remote, .remote])
        #expect(
            rows.compactMap(\.remotePath) == [
                "/home/u/.canopy/0/worktrees/demo/feat-a", "/home/u/.canopy/0/worktrees/demo/feat-b",
            ])
        #expect(FileManager.default.fileExists(atPath: rows[1].path + "/remote.json"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.snapshot.rows.count == 3)
    }

    @Test func aRowGoneFromTheBoxIsForgotten() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        await workspace.applyBoxSnapshot(Self.snapshot(["feat-a", "feat-b"]), host: "box")
        let standIn = try #require(await workspace.snapshot.repo(path: repo)?.rows.last?.path)
        let updates = await workspace.boxUpdates()
        await workspace.applyBoxSnapshot(Self.snapshot(["feat-a"]), host: "box")
        #expect(await workspace.snapshot.repo(path: repo)?.rows.count == 2)
        #expect(!FileManager.default.fileExists(atPath: standIn))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.goneRows == [standIn])
    }

    @Test func aHostThatIsNotUpgradedIgnoresSnapshots() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        try HostsConfigFile(url: workspace.home.configFile).save("box", HostEntry(repos: ["demo": "/home/u/demo"]))
        await workspace.applyBoxSnapshot(Self.snapshot(["feat-a"]), host: "box")
        #expect(await workspace.snapshot.repo(path: repo)?.rows.count == 1)
    }

    @Test func theBoxSettingIsSavedOnlyWhenOn() throws {
        let dir = try TempDir()
        let file = HostsConfigFile(url: URL(fileURLWithPath: dir.sub("config.json")))
        try file.save("a", HostEntry(repos: [:], box: true))
        try file.save("b", HostEntry(repos: [:]))
        let text = try String(contentsOfFile: dir.sub("config.json"), encoding: .utf8)
        #expect(text.components(separatedBy: "\"box\"").count == 2)
        let loaded = HostsConfig.load(from: URL(fileURLWithPath: dir.sub("config.json")))
        #expect(loaded.hosts["a"]?.box == true)
        #expect(loaded.hosts["b"]?.box == false)
    }
}
