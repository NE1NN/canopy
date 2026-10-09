import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct TerminalStoreAgentTests {
    /// Two rows: `a` with two tabs, the first split in two, and `b` with one pane.
    @MainActor
    struct Rows {
        let terminals: TerminalStore
        let a: String
        let b: String
        let focused: Pane
        let beside: Pane
        let otherTab: Pane
        let otherRow: Pane
        let firstTab: TerminalTab

        init(_ dir: TempDir) throws {
            a = dir.sub("a")
            b = dir.sub("b")
            for path in [a, b] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            terminals = Fixture.terminals(dir)
            firstTab = terminals.openTab(for: Fixture.context(a)).tab
            beside = terminals.addPane(for: Fixture.context(a), fits: { _ in true })!
            focused = firstTab.paneList[0]
            terminals.focus(focused.id)
            otherTab = terminals.openTab(for: Fixture.context(a), select: false).pane
            otherRow = terminals.openTab(for: Fixture.context(b)).pane
        }
    }

    @Test func aPaneOnScreenIsSeenAtOnce() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)

        for pane in [rows.focused, rows.beside, rows.otherTab, rows.otherRow] {
            pane.report(AgentReport(state: .done))
        }
        #expect(!rows.focused.agent.unseen)
        #expect(!rows.beside.agent.unseen)
        #expect(rows.otherTab.agent.unseen)
        #expect(rows.otherRow.agent.unseen)

        rows.terminals.selectTab(rows.terminals.tabs(inRow: rows.a)[1].id, inRow: rows.a)
        #expect(!rows.otherTab.agent.unseen)
        rows.terminals.viewing.rowPath = rows.b
        #expect(!rows.otherRow.agent.unseen)
    }

    @Test func nothingIsSeenWhileCanopyIsNotFrontmost() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: false)

        rows.focused.report(AgentReport(state: .done))
        #expect(rows.focused.agent.unseen)
        rows.terminals.viewing.isFrontmost = true
        #expect(!rows.focused.agent.unseen)
    }

    @Test func aSoundPlaysUnlessTheAuthorIsFocusedOnThePane() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        var alerts: [(PaneID, AgentState)] = []
        rows.terminals.onAgentAlert = { alerts.append(($0.id, $1)) }
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)

        rows.focused.report(AgentReport(state: .done))
        rows.focused.report(AgentReport(state: .waiting))
        rows.beside.report(AgentReport(state: .working))
        rows.beside.report(AgentReport(state: .done))
        rows.otherTab.report(AgentReport(state: .waiting))
        rows.terminals.viewing.isFrontmost = false
        rows.focused.report(AgentReport(state: .done))

        #expect(alerts.map(\.0) == [rows.beside.id, rows.otherTab.id, rows.focused.id])
        #expect(alerts.map(\.1) == [.done, .waiting, .done])
    }

    @Test func rowsAndTabsShowTheirMostUrgentDot() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }

        #expect(rows.terminals.agentDot(inRow: rows.a) == nil)
        rows.focused.report(AgentReport(state: .working))
        #expect(rows.firstTab.agentDot == .working)
        rows.beside.report(AgentReport(state: .done))
        #expect(rows.firstTab.agentDot == .done)
        rows.otherTab.report(AgentReport(state: .waiting))
        #expect(rows.firstTab.agentDot == .done)
        #expect(rows.terminals.agentDot(inRow: rows.a) == .waiting)
        #expect(rows.terminals.agentDot(inRow: rows.b) == nil)

        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)
        #expect(rows.firstTab.agentDot == .working)
    }

    @Test func backgroundIsTheLeastUrgentDotAndListsItsWork() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        var alerts: [AgentState] = []
        rows.terminals.onAgentAlert = { alerts.append($1) }

        rows.beside.report(AgentReport(state: .background, backgroundTasks: ["bun dev"]))
        rows.otherTab.report(AgentReport(state: .background, backgroundTasks: ["npm test"]))
        #expect(rows.firstTab.agentDot == .background)
        #expect(rows.firstTab.backgroundTasks == ["bun dev"])
        #expect(rows.terminals.backgroundTasks(inRow: rows.a) == ["bun dev", "npm test"])
        rows.focused.report(AgentReport(state: .working))
        #expect(rows.firstTab.agentDot == .working)
        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == .working)
        #expect(rows.terminals.backgroundTasks(inRows: [rows.a, rows.b]) == ["bun dev", "npm test"])
        #expect(rows.terminals.backgroundTasks(inRow: rows.b).isEmpty)
        // Seeing a background pane keeps its ring, and becoming background plays nothing.
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)
        #expect(rows.beside.agent.dot == .background)
        #expect(alerts.isEmpty)
        rows.beside.report(AgentReport(state: .done))
        #expect(alerts == [.done])
    }

    @Test func aGroupShowsTheMostUrgentDotOfItsRows() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }

        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == nil)
        rows.otherRow.report(AgentReport(state: .working))
        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == .working)
        rows.otherTab.report(AgentReport(state: .done))
        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == .done)
        #expect(rows.terminals.agentDot(inRows: [rows.b]) == .working)
        #expect(rows.terminals.agentDot(inRows: []) == nil)
    }

    @Test func aWaitReturnsAtOnceForAFreshState() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.beside.report(AgentReport(state: .waiting))
        rows.otherRow.report(AgentReport(state: .done))

        let any = try await rows.terminals.waitForAgents(
            [rows.focused.id, rows.otherRow.id, rows.beside.id], for: .any, timeout: .seconds(5))
        #expect(any.0.id == rows.otherRow.id && any.1 == .done)
        let waiting = try await rows.terminals.waitForAgents([rows.beside.id], for: .waiting, timeout: .seconds(5))
        #expect(waiting.1 == .waiting)
    }

    @Test func aStateFromBeforeTheLastInputWaitsForTheNextOne() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        let pane = rows.otherRow
        pane.report(AgentReport(state: .done))
        await pane.type("next step", enter: true)

        let waiting = Task { try await rows.terminals.waitForAgents([pane.id], for: .done, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        pane.report(AgentReport(state: .working))
        pane.report(AgentReport(state: .waiting))
        pane.report(AgentReport(state: .done))
        let result = try await waiting.value
        #expect(result.0.id == pane.id && result.1 == .done)
    }

    @Test func aWaitEndsOnTimeoutCloseOrStop() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }

        await #expect(throws: WorkspaceError.waitTimeout(["p1"], "done or waiting")) {
            try await rows.terminals.waitForAgents([rows.focused.id], for: .any, timeout: .milliseconds(50))
        }
        await #expect(throws: WorkspaceError.paneNotFound("p99")) {
            try await rows.terminals.waitForAgents([PaneID(99)], for: .any, timeout: .seconds(5))
        }

        rows.otherTab.report(AgentReport(state: .working))
        let closing = Task {
            try await rows.terminals.waitForAgents([rows.otherTab.id], for: .done, timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        rows.terminals.closePane(rows.otherTab.id)
        await #expect(throws: WorkspaceError.paneClosed(rows.otherTab.id.description)) { try await closing.value }

        rows.beside.report(AgentReport(state: .working))
        let stopping = Task {
            try await rows.terminals.waitForAgents([rows.beside.id], for: .done, timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        await rows.beside.type("\u{3}")
        await #expect(throws: WorkspaceError.agentStopped(rows.beside.id.description)) { try await stopping.value }
    }

    @Test func aCancelledWaitEndsAndStopsWatching() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }

        let waiting = Task {
            try await rows.terminals.waitForAgents([rows.otherRow.id], for: .done, timeout: .seconds(600))
        }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        // Nothing still listens: a finish now reaches no wait.
        rows.otherRow.report(AgentReport(state: .done))
    }

    @Test func onlyAWaitForBackgroundReturnsOnIt() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        let pane = rows.otherRow
        pane.report(AgentReport(state: .background, backgroundTasks: ["sleep 60"]))
        #expect(
            try await rows.terminals.waitForAgents([pane.id], for: .background, timeout: .seconds(5)).1 == .background)

        for target in [AgentWaitTarget.done, .any] {
            let waiting = Task { try await rows.terminals.waitForAgents([pane.id], for: target, timeout: .seconds(20)) }
            try await Task.sleep(for: .milliseconds(100))
            pane.report(AgentReport(state: .working))
            pane.report(AgentReport(state: .background, backgroundTasks: ["sleep 30"]))
            pane.report(AgentReport(state: .working))
            pane.report(AgentReport(state: .done))
            #expect(try await waiting.value.1 == .done)
            pane.report(AgentReport(state: .background))
        }
    }

    @Test func aPaneWithNoAgentCanStartOneDuringAWait() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        let pane = rows.otherRow

        let waiting = Task { try await rows.terminals.waitForAgents([pane.id], for: .done, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        pane.report(AgentReport(state: .working))
        pane.report(AgentReport(state: .done))
        #expect(try await waiting.value.1 == .done)
    }
}
