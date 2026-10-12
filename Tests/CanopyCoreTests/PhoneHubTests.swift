import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PhoneHubTests {
    @MainActor
    final class Harness {
        let terminals: TerminalStore
        let hub: PhoneHub
        let updates: AsyncStream<WorkspaceSnapshot>.Continuation
        let row: Row
        let sent = Shared<[PhoneInbox]>([])

        init(_ dir: TempDir, poll: Duration = .seconds(60)) throws {
            row = Row(repoPath: dir.sub("r"), path: dir.sub("r"), branch: "main", head: nil, rowClass: .main)
            try FileManager.default.createDirectory(atPath: row.path, withIntermediateDirectories: true)
            terminals = Fixture.terminals(dir)
            let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceSnapshot.self)
            updates = continuation
            hub = PhoneHub(
                terminals: terminals,
                snapshot: WorkspaceSnapshot(repos: [RepoSnapshot(path: row.path, name: "r", rows: [row])]),
                updates: stream, pollInterval: poll, coalescing: .milliseconds(20))
            hub.start()
        }

        func subscribe(after inbox: PhoneInbox? = nil) -> UUID {
            let sent = self.sent
            return hub.subscribe(after: inbox ?? hub.inbox) { inbox in sent.withLock { $0.append(inbox) } }
        }

        var count: Int { sent.withLock { $0.count } }
        var last: PhoneInbox? { sent.withLock { $0.last } }

        func close() {
            hub.stop()
            terminals.closeAll()
        }
    }

    @Test func sendsTheInboxWhenAnAgentChanges() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        defer { harness.close() }
        let pane = harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane
        _ = harness.subscribe()

        pane.report(AgentReport(state: .working))
        #expect(await eventually { harness.last?.rows.first?.agents.first?.state == .working })
        pane.report(AgentReport(state: .waiting))
        #expect(await eventually { harness.last?.rows.first?.agents.first?.state == .waiting })
        #expect(harness.count == 2)
    }

    @Test func sendsNothingWhenNothingChanged() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir, poll: .milliseconds(20))
        defer { harness.close() }
        _ = harness.subscribe()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.count == 0)
    }

    @Test func catchesUpASubscriberWhoseInboxIsStale() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        defer { harness.close() }
        let stale = harness.hub.inbox
        let pane = harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane
        pane.report(AgentReport(state: .working))
        _ = harness.subscribe(after: stale)
        #expect(await eventually { harness.last?.rows.first?.agents.first?.state == .working })
    }

    @Test func rowsComingAndGoingAreSent() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        defer { harness.close() }
        _ = harness.subscribe()
        let added = Row(
            repoPath: harness.row.path, path: dir.sub("new"), branch: "feat/new", head: nil, rowClass: .canopy)
        harness.updates.yield(
            WorkspaceSnapshot(repos: [RepoSnapshot(path: harness.row.path, name: "r", rows: [harness.row, added])]))
        #expect(await eventually { harness.last?.rows.map(\.name) == ["main", "feat/new"] })
    }

    @Test func seeingADoneAgentIsSentOnTheNextPoll() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir, poll: .milliseconds(100))
        defer { harness.close() }
        let pane = harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane
        _ = harness.subscribe()
        pane.report(AgentReport(state: .done))
        #expect(await eventually { harness.last?.rows.first?.agents.first?.unseen == true })
        // Seeing a pane sends no agent event, so only the poll can carry it.
        pane.markSeen()
        #expect(await eventually { harness.last?.rows.first?.agents.first?.unseen == false })
    }

    @Test func unsubscribingStopsTheStream() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        defer { harness.close() }
        let pane = harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane
        let id = harness.subscribe()
        harness.hub.unsubscribe(id)
        pane.report(AgentReport(state: .working))
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.count == 0)
    }

    @Test func manyChangesAtOnceGoOutAsOne() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        defer { harness.close() }
        let panes = (0..<5).map { _ in
            harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane
        }
        _ = harness.subscribe()
        for pane in panes { pane.report(AgentReport(state: .working)) }
        #expect(await eventually { harness.last?.rows.first?.agents.count == 5 })
        #expect(harness.count == 1)
    }
}
