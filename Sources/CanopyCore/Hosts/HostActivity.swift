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
/// Every few seconds it also lists each host's listening ports and forwards those of its remote rows to the Mac. A host's
/// probes run one at a time, so they hold one of its ssh sessions at most, which `host add`'s MaxSessions warning
/// counts on.
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
    /// Each host's forwards being made from its last ports probe, which take no ssh session, so probes go on.
    private var forwarding: [String: Task<Void, Never>] = [:]
    private var lastPorts: [String: ContinuousClock.Instant] = [:]
    /// The hosts a probe is under way on, which another call skips.
    private var probing: Set<String> = []

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
            guard probing.insert(alias).inserted else { continue }
            defer { probing.remove(alias) }
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
            await probePorts(on: connection)
        }
    }

    /// Ports just stopped on a host leave the panel at once, and the host's ports are read again on its next probe.
    public func portsStopped(_ ports: Set<UInt16>, on alias: String) {
        lastPorts[alias] = nil
        guard let groups = remotePorts[alias] else { return }
        remotePorts[alias] = groups.compactMap { group in
            let left = group.ports.filter { !ports.contains($0.port) }
            return left.isEmpty ? nil : PortGroup(rowPath: group.rowPath, ports: left)
        }
    }

    /// The host's listening ports, once `portsEvery` has passed, read right after its session probe so the two never
    /// hold a session each. Its own short timeout keeps a stuck `ss` from holding up the next session probe for long.
    /// A probe that fails, or whose `ss` failed, keeps what the last one found and its forwards, and a host without
    /// `ss` lists none.
    private func probePorts(on connection: HostConnection) async {
        let alias = connection.alias
        let now = ContinuousClock.now
        guard forwarding[alias] == nil, lastPorts[alias].map({ now - $0 >= portsEvery }) ?? true else { return }
        lastPorts[alias] = now
        guard
            let result = await connection.probe(
                HostProbe.command(homeID: workspace.homeID, ports: true), timeout: .seconds(10)),
            result.status == 0, let report = try? HostProbe.decode(result.stdout), let ports = report.ports
        else { return }
        forwarding[alias] = Task {
            await self.forward(ports, shells: report.shells, on: connection)
            self.forwarding[alias] = nil
        }
    }

    /// Gives the host's ports to its remote rows and forwards the rows' ports to the Mac.
    private func forward(_ ports: [RemoteListeningPort], shells: [String: Int32], on connection: HostConnection) async {
        let alias = connection.alias
        let rows = await workspace.remoteRows(on: alias)
        var sessions: [String: String] = [:]
        for pane in terminals.panes where pane.context.remote?.host == alias {
            if let session = pane.remoteSession { sessions[session] = pane.context.rowPath }
        }
        let byRow = RemotePortAttribution.assign(ports, rows: rows, sessions: sessions, shells: shells)
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
