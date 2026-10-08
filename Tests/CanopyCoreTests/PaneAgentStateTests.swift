import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PaneAgentStateTests {
    @Test func reportsChangeThePaneAndAreLogged() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane

        var changes: [AgentChange] = []
        pane.onAgentChange = { _, change in changes.append(change) }
        ActivitySource.$current.withValue(.cli) {
            _ = pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
            _ = pane.report(AgentReport(state: .done, session: "s1", event: "Stop"))
        }

        #expect(pane.agent.state == .done)
        #expect(pane.agent.unseen)
        #expect(changes.map(\.to) == [.working, .done])
        let events = await logged(terminals, "agent")
        #expect(events.map(\.type) == ["agent.working", "agent.done"])
        #expect(
            events.map(\.data) == [
                ["pane": "p1", "from": .null, "via": "UserPromptSubmit", "session": "s1"],
                ["pane": "p1", "from": "working", "via": "Stop", "session": "s1"],
            ])
        #expect(events.allSatisfy { $0.source == .cli && $0.row == "feat/x" && $0.path == dir.path })
    }

    @Test func typingAndSendingReachTheKeyRules() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        _ = pane.report(AgentReport(state: .working))
        pane.screen.type("\u{1b}")
        #expect(pane.agent.state == .none)

        _ = pane.report(AgentReport(state: .waiting, event: "PermissionRequest"))
        await pane.type("", enter: true)
        #expect(pane.agent.state == .working)

        let events = await logged(terminals, "agent")
        #expect(events.map(\.type) == ["agent.working", "agent.cleared", "agent.waiting", "agent.working"])
        #expect(events.map { $0.data["via"] } == ["term.state", "key", "PermissionRequest", "key"])
        #expect(events[1].data["session"] == nil)
    }

    @Test func returnFromTermSendAnswersAPromptOnceItIsIn() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        // `canopy term send <pane> 1 --enter` picks an option: the text alone leaves the prompt, and Return answers it.
        pane.report(AgentReport(state: .waiting, event: "PermissionRequest"))
        await pane.type("1", enter: true)
        #expect(pane.agent.state == .working)
        let events = await logged(terminals, "agent")
        #expect(events.last?.data["via"] == "key")

        // An answer typed at the agent's own input line waits for the next prompt's hook instead.
        pane.report(AgentReport(state: .waiting, event: "Stop", question: true))
        await pane.type("No, it is sunny.", enter: true)
        #expect(pane.agent.state == .waiting)
    }

    @Test func theProgramExitingClearsTheState() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        // cat runs until Control-D, so the test decides when the program exits.
        await pane.run("cat")
        #expect(
            await eventually {
                pane.refreshActivity()
                return pane.isRunningProgram
            })
        _ = pane.report(AgentReport(state: .done, session: "s1", event: "Stop"))
        #expect(pane.agent.state == .done)
        await pane.type("\u{4}")

        #expect(
            await eventually {
                pane.refreshActivity()
                return pane.agent.state == .none
            })
        #expect(pane.agent.session == nil)
        #expect(await logged(terminals, "agent").last?.data["via"] == "exit")
    }

    @Test func focusAndMouseReportsDoNotMakeAStateStale() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        pane.report(AgentReport(state: .done))

        pane.screen.type("\u{1b}[I")
        pane.screen.type("\u{1b}[<64;10;5M")
        #expect(pane.agentIsFresh)
        pane.screen.type("x")
        #expect(!pane.agentIsFresh)
    }

    @Test func anExitWhileNoRefreshRanStillClearsTheState() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        // The window is hidden, so nothing refreshes while the program runs.
        await pane.run("cat")
        #expect(await eventually { pane.isBusy })
        pane.report(AgentReport(state: .done))
        await pane.type("\u{4}")
        #expect(await eventually { !pane.isBusy })

        pane.refreshActivity()
        #expect(pane.agent.state == .none)
    }

    @Test func aStateWithoutAProgramStaysUntilReported() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        _ = pane.report(AgentReport(state: .waiting))
        pane.refreshActivity()
        #expect(pane.agent.state == .waiting)
    }

    @Test func theShellExitingOrThePaneClosingClearsTheState() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let exiting = terminals.openTab(for: Fixture.context(dir.path)).pane
        _ = exiting.report(AgentReport(state: .done))
        await exiting.run("exit 0")
        #expect(await eventually { exiting.agent.state == .none })

        let closing = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })!
        _ = closing.report(AgentReport(state: .working))
        var order: [String] = []
        closing.onClose = { _ in order.append("closed") }
        closing.onAgentChange = { _, change in order.append(change.to.rawValue) }
        terminals.closePane(closing.id)
        #expect(order == ["closed", "none"])
        #expect(closing.agent.state == .none)
    }
}
