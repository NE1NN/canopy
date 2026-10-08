import Foundation

/// A remote pane as the app sees it, for its host's idle detach.
public struct HostPaneSample: Sendable, Equatable {
    public var session: String
    /// Its attach command still runs.
    public var isRunning: Bool
    public var lastInput: Date

    public init(session: String, isRunning: Bool, lastInput: Date) {
        self.session = session
        self.isRunning = isRunning
        self.lastInput = lastInput
    }
}

public struct HostActivitySummary: Sendable, Equatable {
    /// Panes whose attach command runs and whose session the host has.
    public var attached: Int
    public var busy: Bool
    /// Since a key was last typed into any of them.
    public var quietFor: Duration
}

public enum HostActivity {
    public static func summary(panes: [HostPaneSample], sessions: [String: SessionActivity], now: Date)
        -> HostActivitySummary
    {
        let attached = panes.filter { $0.isRunning && sessions[$0.session] != nil }
        let busy = attached.contains { sessions[$0.session]?.busy == true }
        let lastInput = attached.map(\.lastInput).max() ?? .distantPast
        let quiet = max(now.timeIntervalSince(lastInput), 0)
        return HostActivitySummary(
            attached: attached.count, busy: busy, quietFor: .seconds(quiet.isFinite ? quiet : 0))
    }
}

/// Probes connected hosts for what their sessions do, and tells each host what its panes are up to.
@MainActor
public final class HostMonitor {
    /// How often the hosts' worktrees are listed again, in probes.
    static let listEvery = 15

    let workspace: Workspace
    let terminals: TerminalStore
    private var probes = 0
    /// Each host's worktree listing under way. It can wait behind a row being made, so probes go on without it.
    private var listing: [String: Task<Void, Never>] = [:]

    public init(workspace: Workspace, terminals: TerminalStore) {
        self.workspace = workspace
        self.terminals = terminals
    }

    /// One round: every connected host's sessions, onto its panes.
    public func probe() async {
        probes += 1
        let server = HostPaths.tmuxServer(homeID: workspace.homeID)
        for connection in await workspace.connectedHosts() {
            let alias = connection.alias
            guard let result = await connection.probe(HostProbe.command(server: server), timeout: .seconds(10)),
                result.status == 0, let sessions = try? HostProbe.decode(result.stdout)
            else { continue }
            let panes = terminals.panes.filter { $0.context.remote?.host == alias }
            var samples: [HostPaneSample] = []
            for pane in panes {
                guard let session = pane.remoteSession else { continue }
                pane.remoteActivity = sessions[session]
                var running = false
                if case .running = pane.status { running = true }
                samples.append(HostPaneSample(session: session, isRunning: running, lastInput: pane.lastInput))
            }
            let summary = HostActivity.summary(panes: samples, sessions: sessions, now: Date())
            await connection.panesActive(attached: summary.attached, busy: summary.busy, quietFor: summary.quietFor)
            if probes % Self.listEvery == 0, listing[alias] == nil {
                let workspace = workspace
                listing[alias] = Task {
                    await workspace.refreshRemote(host: alias)
                    self.listing[alias] = nil
                }
            }
        }
    }
}
