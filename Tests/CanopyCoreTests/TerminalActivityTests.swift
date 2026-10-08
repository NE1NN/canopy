import Foundation
import Testing

@testable import CanopyCore

@MainActor
func logged(_ terminals: TerminalStore, _ prefix: String) async -> [ActivityEvent] {
    await terminals.activity.flush()
    return activityEvents(terminals.activity.folder).filter { $0.type.hasPrefix(prefix + ".") }
}

@MainActor
struct TerminalActivityTests {
    @Test func openingAndExitingAreLogged() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        await pane.run("exit 3")
        #expect(await eventually { pane.status == .exited(3) })

        let events = await logged(terminals, "term")
        #expect(events.map(\.type) == ["term.opened", "term.exited"])
        #expect(events.map(\.data) == [["pane": "p1"], ["pane": "p1", "code": 3]])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.row == "feat/x" && $0.path == dir.path })
        #expect(events.allSatisfy { $0.source == .ui })
    }

    @Test func aTerminalClosedThroughTheCLIIsLoggedAsItsDoing() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = ActivitySource.$current.withValue(.cli) { terminals.openTab(for: Fixture.context(dir.path)).pane }
        ActivitySource.$current.withValue(.cli) { terminals.closePane(pane.id) }

        let events = await logged(terminals, "term")
        #expect(events.map(\.type) == ["term.opened", "term.exited"])
        #expect(events.map(\.source) == [.cli, .cli])
        #expect(events.last?.data["code"] == .number(Double(Pane.closedExitCode)))
    }

    @Test func restartingAShellLogsItOpeningAgain() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        await pane.run("exit 0")
        #expect(await eventually { pane.status == .exited(0) })
        pane.screen.type("\r")

        #expect(await logged(terminals, "term").map(\.type) == ["term.opened", "term.exited", "term.opened"])
    }

    @Test func eventsNameTheRowAsItIsNow() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane

        // The row's checkout moved to another branch, and a second repo with the same folder name was added.
        let row = Row(repoPath: "/r/demo", path: dir.path, branch: "feat/y", head: nil, rowClass: .canopy)
        terminals.followRowNames(
            in: WorkspaceSnapshot(repos: [RepoSnapshot(path: "/r/demo", name: "demo (r)", rows: [row])]))
        terminals.closePane(pane.id)

        let exited = await logged(terminals, "term").last
        #expect(exited?.row == "feat/y" && exited?.repo == "demo (r)")
    }
}
