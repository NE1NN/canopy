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

/// Probes connected hosts for what their sessions do, tells each host what its panes are up to, and replays the hook
/// reports a host kept, so an agent that finished while the app was away shows it without its pane attaching again.
/// Every few seconds it also lists each host's listening ports and forwards those of its remote rows to the Mac.
@MainActor
public final class HostMonitor {
    /// How often the hosts' worktrees are listed again, in probes.
    static let listEvery = 15

    let workspace: Workspace
    let terminals: TerminalStore
    /// The ports of each connected host's remote rows, a group for each row with any, in sidebar order.
    public private(set) var remotePorts: [String: [PortGroup]] = [:]
    private let portsEvery: Duration
    private var probes = 0
    /// Each host's worktree listing under way. It can wait behind a row being made, so probes go on without it.
    private var listing: [String: Task<Void, Never>] = [:]
    /// Each host's kept reports being replayed, which can each take seconds.
    private var replaying: [String: Task<Void, Never>] = [:]
    /// Each host's ports round under way, which the session probe never waits for, and when the last one started.
    private var portsRound: [String: Task<Void, Never>] = [:]
    private var lastPorts: [String: ContinuousClock.Instant] = [:]

    public init(workspace: Workspace, terminals: TerminalStore, portsEvery: Duration = .seconds(5)) {
        self.workspace = workspace
        self.terminals = terminals
        self.portsEvery = portsEvery
    }

    /// One round: every connected host's sessions, onto its panes.
    public func probe() async {
        probes += 1
        let command = HostProbe.command(homeID: workspace.homeID)
        let connected = await workspace.connectedHosts()
        let aliases = Set(connected.map(\.alias))
        for alias in Set(remotePorts.keys).union(lastPorts.keys) where !aliases.contains(alias) {
            remotePorts[alias] = nil
            lastPorts[alias] = nil
        }
        for connection in connected {
            let alias = connection.alias
            startPortsRound(on: connection)
            guard let result = await connection.probe(command, timeout: .seconds(10)),
                result.status == 0, let report = try? HostProbe.decode(result.stdout)
            else { continue }
            let sessions = report.sessions
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
            if !report.pending.isEmpty, replaying[alias] == nil {
                let workspace = workspace
                replaying[alias] = Task {
                    for pane in report.pending {
                        await workspace.replayKeptReport(pane: pane, on: connection)
                    }
                    self.replaying[alias] = nil
                }
            }
        }
    }

    private func startPortsRound(on connection: HostConnection) {
        let alias = connection.alias
        let now = ContinuousClock.now
        guard portsRound[alias] == nil, lastPorts[alias].map({ now - $0 >= portsEvery }) ?? true else { return }
        lastPorts[alias] = now
        portsRound[alias] = Task {
            await self.refreshPorts(on: connection)
            self.portsRound[alias] = nil
        }
    }

    /// The host's listening ports, given to its remote rows, with the rows' ports forwarded to the Mac. A probe that
    /// fails keeps what the last one found, and a host without `ss` lists none.
    private func refreshPorts(on connection: HostConnection) async {
        let alias = connection.alias
        guard
            let result = await connection.probe(
                HostProbe.command(homeID: workspace.homeID, ports: true), timeout: .seconds(30)),
            result.status == 0, let report = try? HostProbe.decode(result.stdout)
        else { return }
        let rows = await workspace.remoteRows(on: alias)
        var sessions: [String: String] = [:]
        for pane in terminals.panes where pane.context.remote?.host == alias {
            if let session = pane.remoteSession { sessions[session] = pane.context.rowPath }
        }
        let byRow = RemotePortAttribution.assign(report.ports, rows: rows, sessions: sessions, shells: report.shells)
        let forwards = await workspace.forwardPorts(byRow.values.flatMap { $0 }, on: connection)
        guard await connection.state == .connected else {
            remotePorts[alias] = nil
            return
        }
        remotePorts[alias] = rows.compactMap { row in
            byRow[row.standIn].map { ports in
                PortGroup(
                    rowPath: row.standIn,
                    ports: ports.map { port in
                        RowPort(
                            port: port.port,
                            processes: port.processes.map {
                                ListeningPort(port: port.port, pid: $0.pid, process: $0.name)
                            }.sorted { $0.pid < $1.pid },
                            remote: RemotePort(
                                host: alias, local: forwards[port.port]?.local, error: forwards[port.port]?.error))
                    })
            }
        }
    }
}
