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
/// counts on, and each host's run apart from the others', so a slow host holds up no other.
@MainActor
public final class HostMonitor {
    /// How often a host's worktrees are listed again, in its session probes.
    private let listEvery: Int

    let workspace: Workspace
    let terminals: TerminalStore
    /// The ports of each connected host's remote rows, a group for each row with any, in sidebar order.
    public private(set) var remotePorts: [String: [PortGroup]] = [:]
    private let portsEvery: Duration
    /// How long a ports listing counts as use after it was read, as a host whose `ss` keeps failing keeps its last.
    private let portsStaleAfter: Duration
    private let clock: any HostClock
    /// Each host's session probes that it answered.
    private(set) var probes: [String: Int] = [:]
    /// Each host's worktree listing under way. It can wait behind a row being made, so probes go on without it.
    private var listing: [String: Task<Void, Never>] = [:]
    /// Each host's kept reports being replayed, which can each take seconds.
    private var replaying: [String: Task<Void, Never>] = [:]
    /// Each host's forwards being made from its last ports probe, which take no ssh session, so probes go on.
    private var forwarding: [String: Task<Void, Never>] = [:]
    private var lastPorts: [String: ContinuousClock.Instant] = [:]
    /// When each host's ports were last listed.
    private var listed: [String: ContinuousClock.Instant] = [:]
    /// Each host's probes under way, its session probe and then its ports, which another round skips.
    private var probing: [String: Task<Void, Never>] = [:]

    /// Whether no work a round started is still under way.
    var isSettled: Bool { probing.isEmpty && listing.isEmpty && replaying.isEmpty && forwarding.isEmpty }

    public init(
        workspace: Workspace, terminals: TerminalStore, portsEvery: Duration = .seconds(5),
        portsStaleAfter: Duration = .seconds(60), listEvery: Int = 15, clock: any HostClock = SystemHostClock()
    ) {
        self.workspace = workspace
        self.terminals = terminals
        self.listEvery = max(listEvery, 1)
        self.portsEvery = portsEvery
        self.portsStaleAfter = portsStaleAfter
        self.clock = clock
    }

    /// Starts a round every `interval` until cancelled, without waiting for the last, so a host still probing is
    /// skipped and a slow one holds up no other. Once cancelled, it cancels the work its rounds started and returns
    /// when that is done, so none outlives it.
    public func watch(every interval: Duration) async {
        await withDiscardingTaskGroup { group in
            while !Task.isCancelled {
                group.addTask { await self.probe() }
                try? await Task.sleep(for: interval)
            }
        }
        await settle()
    }

    /// Cancels the work rounds started, and waits for it. Each task leaves its list as it ends.
    func settle() async {
        while let task = probing.values.first ?? listing.values.first ?? replaying.values.first
            ?? forwarding.values.first
        {
            task.cancel()
            await task.value
        }
    }

    /// One round: every connected host's sessions, onto its panes, then its ports when they are due. Each host's
    /// probes run in a sequence of their own, one after another, and a host whose last sequence still runs is skipped.
    /// Returns once the session probes it started are done, without waiting for any ports probe.
    public func probe() async {
        let connected = await workspace.connectedHosts()
        let aliases = Set(connected.map(\.alias))
        for alias in Set(remotePorts.keys).union(lastPorts.keys) where !aliases.contains(alias) {
            remotePorts[alias] = nil
            lastPorts[alias] = nil
            listed[alias] = nil
            probes[alias] = nil
        }
        var sessions: [Task<Bool, Never>] = []
        for connection in connected {
            let alias = connection.alias
            guard probing[alias] == nil else { continue }
            let probed = Task { await self.probeSessions(on: connection) }
            sessions.append(probed)
            probing[alias] = Task {
                let answered = await withTaskCancellationHandler {
                    await probed.value
                } onCancel: {
                    probed.cancel()
                }
                if answered, !Task.isCancelled { await self.probePorts(on: connection) }
                self.probing[alias] = nil
            }
        }
        let started = sessions
        await withTaskCancellationHandler {
            for probed in started { _ = await probed.value }
        } onCancel: {
            for probed in started { probed.cancel() }
        }
    }

    /// The host's sessions, onto its panes. Returns whether the host answered.
    private func probeSessions(on connection: HostConnection) async -> Bool {
        let alias = connection.alias
        guard
            let result = await connection.probe(HostProbe.command(homeID: workspace.homeID), timeout: .seconds(10)),
            result.status == 0, let report = try? HostProbe.decode(result.stdout)
        else { return false }
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
        await connection.panesActive(
            attached: summary.attached, busy: summary.busy, serving: serves(alias),
            quietFor: summary.quietFor)
        let probed = probes[alias, default: 0] + 1
        probes[alias] = probed
        if probed % listEvery == 0, listing[alias] == nil {
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
        return true
    }

    /// Whether a remote row of the host serves a port someone could be browsing from the Mac: one with a forward, in
    /// a listing recent enough to trust. A server that died while `ss` kept failing would otherwise keep the host up.
    private func serves(_ alias: String) -> Bool {
        guard let listed = listed[alias], clock.now - listed < portsStaleAfter else { return false }
        return remotePorts[alias]?.contains { $0.ports.contains { $0.remote?.local != nil } } == true
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
    /// hold a session each. Its own short timeout keeps a stuck `ss` from holding up the host's next session probe for
    /// long, and other hosts' probes never wait for it.
    /// A probe that fails, or whose `ss` failed, keeps what the last one found and its forwards, and a host without
    /// `ss` lists none.
    private func probePorts(on connection: HostConnection) async {
        let alias = connection.alias
        let now = clock.now
        guard forwarding[alias] == nil, lastPorts[alias].map({ now - $0 >= portsEvery }) ?? true else { return }
        lastPorts[alias] = now
        guard
            let result = await connection.probe(
                HostProbe.command(homeID: workspace.homeID, ports: true), timeout: .seconds(10)),
            result.status == 0, let report = try? HostProbe.decode(result.stdout), let ports = report.ports
        else { return }
        listed[alias] = clock.now
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
        // A master that stopped during the round leaves the ports as they showed until the next round, read soon.
        guard let forwards else {
            lastPorts[alias] = nil
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
