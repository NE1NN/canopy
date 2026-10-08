import Foundation
import Testing

@testable import CanopyCore

struct RemoteRowStateTests {
    func setUp(_ dir: TempDir) async throws -> (Workspace, String) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (workspace, repo)
    }

    func entry(_ home: CanopyHome, branch: String, host: String = "box") -> RemoteRowEntry {
        let slug = BranchSlug.slug(for: branch)
        return RemoteRowEntry(
            host: host, path: "/home/u/.canopy/worktrees/demo/\(slug)",
            standIn: home.remoteRoot.appending(path: "\(host)/demo/\(slug)").path, branch: branch, head: "abc")
    }

    @Test func anOldStateFileLoadsWithNoRemoteRows() throws {
        let data = Data(#"{"path": "/r", "dirName": "r", "adopted": [], "rowOrder": []}"#.utf8)
        let entry = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(entry.remote.isEmpty)
    }

    @Test func remoteRowsListAfterTheMainRowWithTheirHostAndRemotePath() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let remote = entry(workspace.home, branch: "feat/x")

        try await workspace.addRemoteRow(remote, repoPath: repo)

        let rows = try #require(await workspace.snapshot.repo(path: repo)?.rows)
        #expect(rows.map(\.rowClass) == [.main, .remote])
        #expect(rows[1].path == remote.standIn)
        #expect(rows[1].host == "box")
        #expect(rows[1].remotePath == remote.path)
        #expect(rows[1].branch == "feat/x")
        #expect(!rows[1].isMissing)
        #expect(FileManager.default.fileExists(atPath: remote.standIn + "/remote.json"))
    }

    @Test func aRefreshOfTheLocalRepoKeepsRemoteRowsInTheirOrderAndGroups() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let local = try await workspace.createRow(repoPath: repo, branch: "feat/local").row.path
        let first = entry(workspace.home, branch: "feat/a")
        let second = entry(workspace.home, branch: "feat/b")
        try await workspace.addRemoteRow(first, repoPath: repo)
        try await workspace.addRemoteRow(second, repoPath: repo)
        try await workspace.createGroup(repoPath: repo, name: "Box")
        _ = try await workspace.moveRow(path: second.standIn, to: .group("Box"))
        _ = try await workspace.moveRow(path: first.standIn, to: .before(local))

        await workspace.refresh(repoPath: repo)

        let rows = try #require(await workspace.snapshot.repo(path: repo)?.rows)
        #expect(rows.map(\.path) == [repo, first.standIn, local, second.standIn])
        #expect(rows.last?.group == "Box")
        let relaunched = Workspace(home: workspace.home, git: Fixture.git)
        await workspace.stop()
        try await relaunched.start()
        #expect(
            await relaunched.snapshot.repo(path: repo)?.rows.map(\.path) == [
                repo, first.standIn, local, second.standIn,
            ])
    }

    @Test func aStandInDeletedOutsideCanopyIsMadeAgain() throws {
        let dir = try TempDir()
        let remote = entry(CanopyHome(path: dir.sub("home")), branch: "feat/x")
        try remote.makeStandIn()
        try FileManager.default.removeItem(atPath: remote.standIn)

        try remote.makeStandIn()

        let saved = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: remote.standIn + "/remote.json")))
        #expect(saved == ["host": "box", "path": remote.path])
        let mode = try FileManager.default.attributesOfItem(atPath: remote.standIn)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func aRemoteRowDoesNotHoldItsBranchForLocalRows() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let remote = entry(workspace.home, branch: "feat/x")
        try await workspace.addRemoteRow(remote, repoPath: repo)

        let local = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(local.row.rowClass == .canopy)
        #expect(await workspace.holder(of: "feat/x", repoPath: repo, host: "box")?.path == remote.standIn)
        #expect(await workspace.holder(of: "feat/x", repoPath: repo)?.path == local.row.path)
    }

    @Test func remoteRowsFindTheirSavedEntryByStandInOrByHostAndPath() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let remote = entry(workspace.home, branch: "feat/x")
        try await workspace.addRemoteRow(remote, repoPath: repo)

        #expect(await workspace.remoteRow(standIn: remote.standIn) == remote)
        #expect(await workspace.remoteRow(host: "box", path: remote.path) == remote)
        #expect(await workspace.remoteRow(host: "other", path: remote.path) == nil)
    }
}

struct RowMovableTests {
    @Test func canopyAdoptedAndRemoteRowsMoveAndTheRestStay() {
        func row(_ rowClass: RowClass) -> Row {
            Row(repoPath: "/r", path: "/p", branch: "b", head: nil, rowClass: rowClass)
        }
        #expect(row(.canopy).isMovable)
        #expect(row(.adopted).isMovable)
        #expect(row(.remote).isMovable)
        #expect(!row(.main).isMovable)
        #expect(!row(.external).isMovable)
    }
}
