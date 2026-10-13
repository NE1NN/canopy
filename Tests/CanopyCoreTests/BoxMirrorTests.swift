import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// An upgraded host's panes and agents on the Mac, from its canopy-box's snapshots.
@MainActor
struct BoxMirrorTests {
    let dir: TempDir
    let workspace: Workspace
    let terminals: TerminalStore
    let mirror: BoxMirror
    static let rowPath = "/home/u/.canopy/0/worktrees/demo/feat-a"

    init() async throws {
        dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        try HostsConfigFile(url: workspace.home.configFile).save(
            "box", HostEntry(repos: ["demo": "/home/u/demo"], box: true))
        terminals = Fixture.terminals(dir)
        mirror = BoxMirror(workspace: workspace, terminals: terminals)
    }

    func update(_ panes: [BoxPane], rows: [String] = [rowPath]) async -> BoxUpdate {
        let snapshot = BoxSnapshot(
            rows: [BoxRow(path: "/home/u/demo", repo: "demo", isMain: true)]
                + rows.map { BoxRow(path: $0, repo: "demo", branch: "feat/a") },
            panes: panes)
        await workspace.applyBoxSnapshot(snapshot, host: "box")
        return BoxUpdate(host: "box", snapshot: snapshot, goneRows: [])
    }

    static func pane(_ id: String, _ agent: AgentState = .none, unseen: Bool = false) -> BoxPane {
        BoxPane(id: id, rowPath: rowPath, folder: rowPath, agent: agent, unseen: unseen, since: 1_700_000_000)
    }

    @Test func aBoxPaneOpensATabInItsRow() async throws {
        defer { terminals.closeAll() }
        await mirror.apply(await update([Self.pane("b1")]))
        let pane = try #require(terminals.panes.first)
        #expect(pane.remoteSession == "b1")
        #expect(pane.context.remote?.host == "box")
        #expect(pane.context.remote?.path == Self.rowPath)
        // A second snapshot opens no second tab.
        await mirror.apply(await update([Self.pane("b1")]))
        #expect(terminals.panes.count == 1)
    }

    @Test func anAgentFromTheBoxShowsOnItsPane() async throws {
        defer { terminals.closeAll() }
        await mirror.apply(await update([Self.pane("b1", .working)]))
        let pane = try #require(terminals.panes.first)
        #expect(pane.agent.state == .working)
        await mirror.apply(await update([Self.pane("b1", .done, unseen: true)]))
        #expect(pane.agent.state == .done)
        #expect(pane.agent.dot == .done)
    }

    @Test func aClosedPaneIsNotReopenedByAnOldSnapshot() async throws {
        defer { terminals.closeAll() }
        await mirror.apply(await update([Self.pane("b1")]))
        mirror.closedAtTheMac("b1", host: "box")
        terminals.closePane(try #require(terminals.panes.first).id)
        await mirror.apply(await update([Self.pane("b1")]))
        #expect(terminals.panes.isEmpty)
    }

    @Test func aRowGoneFromTheBoxClosesItsTabs() async throws {
        defer { terminals.closeAll() }
        await mirror.apply(await update([Self.pane("b1")]))
        let standIn = try #require(terminals.panes.first?.context.rowPath)
        await mirror.apply(BoxUpdate(host: "box", snapshot: BoxSnapshot(), goneRows: [standIn]))
        #expect(terminals.tabs(inRow: standIn).isEmpty)
    }
}
