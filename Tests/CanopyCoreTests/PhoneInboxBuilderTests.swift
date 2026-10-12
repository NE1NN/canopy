import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PhoneInboxBuilderTests {
    @MainActor
    struct Setup {
        let terminals: TerminalStore
        let snapshot: WorkspaceSnapshot
        let main: Row
        let feature: Row
        let external: Row
        let ticket: PluginRow

        init(_ dir: TempDir) throws {
            let repo = dir.sub("canopy")
            main = Row(repoPath: repo, path: repo, branch: "main", head: nil, rowClass: .main)
            var feature = Row(repoPath: repo, path: dir.sub("feat"), branch: "feat/phone", head: nil, rowClass: .canopy)
            feature.pullRequest = PullRequest(
                number: 42, title: "Phone", url: "https://github.com/o/canopy/pull/42", state: .draft, updatedAt: "")
            self.feature = feature
            external = Row(
                repoPath: repo, path: dir.sub("other"), branch: "spike", head: nil, rowClass: .external,
                externalTag: .other)
            ticket = PluginRow(plugin: "tickets", item: "0853", title: "#0853", path: dir.sub("ticket"))
            for path in [main.path, feature.path, external.path, ticket.path] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            snapshot = WorkspaceSnapshot(
                repos: [RepoSnapshot(path: repo, name: "canopy", rows: [main, feature], external: [external])],
                plugins: [
                    PluginSection(
                        info: PluginInfo(id: "tickets", name: "Tickets", symbol: "ticket", itemName: "Ticket"),
                        isOn: true, rows: [ticket]),
                    PluginSection(info: PluginInfo(id: "off", name: "Off", symbol: "x"), isOn: false),
                ])
            terminals = Fixture.terminals(dir)
        }
    }

    @Test func listsEveryRowInSidebarOrderWithItsAgents() throws {
        let dir = try TempDir()
        let setup = try Setup(dir)
        defer { setup.terminals.closeAll() }
        let working = setup.terminals.openTab(for: PaneContext(row: setup.feature, repoName: "canopy")).pane
        let idle = setup.terminals.openTab(for: PaneContext(row: setup.feature, repoName: "canopy")).pane
        let asking = setup.terminals.openTab(for: PaneContext(pluginRow: setup.ticket)).pane
        working.report(AgentReport(state: .working), now: Date(timeIntervalSince1970: 100))
        asking.report(AgentReport(state: .waiting), now: Date(timeIntervalSince1970: 200))
        _ = idle

        let inbox = PhoneInboxBuilder.inbox(setup.snapshot, terminals: setup.terminals)
        #expect(inbox.rows.map(\.name) == ["main", "feat/phone", "spike", "#0853"])
        let feature = try #require(inbox.rows.first { $0.name == "feat/phone" })
        #expect(feature.agents == [PhoneAgent(pane: working.id.description, state: .working, since: 100)])
        #expect(feature.repo == "canopy" && feature.plugin == nil && !feature.isMain)
        #expect(feature.pr == nil)
        let ticket = try #require(inbox.rows.last)
        #expect(ticket.plugin == "Ticket" && ticket.repo == nil)
        #expect(ticket.agents.map(\.state) == [.waiting])
        #expect(inbox.rows.first?.isMain == true)
    }

    @Test func backgroundAgentsSayWhatTheyWaitOn() throws {
        let dir = try TempDir()
        let setup = try Setup(dir)
        defer { setup.terminals.closeAll() }
        let pane = setup.terminals.openTab(for: PaneContext(row: setup.main, repoName: "canopy")).pane
        pane.report(AgentReport(state: .background, backgroundTasks: ["make e2e"]))
        let agent = try #require(
            PhoneInboxBuilder.inbox(setup.snapshot, terminals: setup.terminals).rows[0].agents.first)
        #expect(agent.backgroundTasks == ["make e2e"])
    }

    @Test func aDoneAgentStaysUnseenUntilTheAuthorLooks() throws {
        let dir = try TempDir()
        let setup = try Setup(dir)
        defer { setup.terminals.closeAll() }
        let pane = setup.terminals.openTab(for: PaneContext(row: setup.main, repoName: "canopy")).pane
        pane.report(AgentReport(state: .done))
        #expect(PhoneInboxBuilder.inbox(setup.snapshot, terminals: setup.terminals).rows[0].agents[0].unseen)
        pane.markSeen()
        #expect(!PhoneInboxBuilder.inbox(setup.snapshot, terminals: setup.terminals).rows[0].agents[0].unseen)
    }

    @Test func rowsComeBySectionWithTheirPRs() throws {
        let dir = try TempDir()
        let setup = try Setup(dir)
        defer { setup.terminals.closeAll() }
        let result = PhoneInboxBuilder.rows(setup.snapshot, terminals: setup.terminals)
        #expect(result.sections.map(\.name) == ["canopy", "Tickets"])
        #expect(result.sections.map(\.isPlugin) == [false, true])
        #expect(result.sections[0].rows.map(\.name) == ["main", "feat/phone", "spike"])
        #expect(
            result.sections[0].rows[1].pr
                == PhonePR(number: 42, state: .draft, title: "Phone", url: "https://github.com/o/canopy/pull/42"))
    }
}
