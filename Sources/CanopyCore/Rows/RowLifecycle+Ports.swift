import Foundation

/// Ports for the panel and `canopy ports`, on the main actor where the terminals' shells are known.
extension RowLifecycle {
    /// Every row's ports, in sidebar order: each repo's rows, then its other worktrees, then the rows of each plugin
    /// that is on. Ports in the system's random range are left out. Local rows' ports come from a scan of this Mac,
    /// which leaves out the hosts' masters, whose sockets are their forwards; remote rows' come from their hosts'
    /// last probes.
    public func portGroups() async -> [PortGroup] {
        let snapshot = await workspace.snapshot
        let worktrees = snapshot.repos.flatMap(\.allRows)
        let order = worktrees.map(\.path) + snapshot.activePlugins.flatMap(\.rows).map(\.path)
        let remoteRows = Set(worktrees.filter { $0.host != nil }.map(\.path))
        let rows = order.filter { !remoteRows.contains($0) }
        let shells = terminals.tabsByRow.filter { !remoteRows.contains($0.key) }.mapValues { tabs in
            tabs.flatMap(\.paneList).compactMap(\.pid)
        }
        let masters = await workspace.masterPIDs()
        let localPorts = localPorts
        let local = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let random = PortScanner.randomPortRange()
                let ports = localPorts.scan().filter { !random.contains($0.port) && !masters.contains($0.pid) }
                continuation.resume(
                    returning: PortAttribution.assign(
                        ports, rows: rows, shells: shells, parent: localPorts.parent, folder: localPorts.folder))
            }
        }
        var byRow = Dictionary(local.map { ($0.rowPath, $0) }, uniquingKeysWith: { first, _ in first })
        let remote = hostMonitor?.remotePorts.values.flatMap { $0 } ?? []
        for group in remote where remoteRows.contains(group.rowPath) {
            byRow[group.rowPath] = group
        }
        return order.compactMap { byRow[$0] }
    }

    /// One row's ports, or every row's when `rowPath` is nil, with a line for each process on a port.
    public func portInfo(rowPath: String?) async -> [PortInfo] {
        let groups = await portGroups()
        let snapshot = await workspace.snapshot
        return groups.filter { rowPath == nil || $0.rowPath == rowPath }.flatMap { group in
            group.ports.flatMap { info(of: $0, inRow: group.rowPath, snapshot) }
        }
    }

    private func info(of port: RowPort, inRow rowPath: String, _ snapshot: WorkspaceSnapshot) -> [PortInfo] {
        let row = snapshot.sidebarRow(path: rowPath)
        let repo = row?.worktree.flatMap { snapshot.repo(path: $0.repoPath)?.name }
        return port.processes.map { process in
            PortInfo(
                repo: repo, plugin: row?.pluginRow?.plugin, row: row?.displayName ?? rowPath, rowPath: rowPath,
                port: Int(port.port), pid: process.pid, process: process.process, host: port.remote?.host,
                localPort: port.remote?.local.map(Int.init), forwardError: port.remote?.error)
        }
    }

    /// Stops what listens on a port in one row, or in any row when `rowPath` is nil. A remote row's port is found by
    /// its port on the host or its Mac port. A port that belongs to no row is not Canopy's to stop, and one in another
    /// row is refused, since it is most likely another agent's server.
    public func stopPort(_ number: Int, rowPath: String?) async throws -> PortsStopResult {
        guard let port = UInt16(exactly: number) else { throw WorkspaceError.portNotFound(number) }
        let groups = await portGroups()
        let holding = PortStops.matching(port, in: groups.filter { rowPath == nil || $0.rowPath == rowPath })
        guard !holding.isEmpty else {
            if let other = PortStops.matching(port, in: groups).first {
                let row = await workspace.snapshot.sidebarRow(path: other.rowPath)
                throw WorkspaceError.portInOtherRow(number, row: row?.displayName ?? other.rowPath)
            }
            throw WorkspaceError.portNotFound(number)
        }
        let snapshot = await workspace.snapshot
        let outcome = await stop(holding.map(\.port))
        // A stop that went nowhere is an error, while one that went through somewhere says what failed beside it.
        if let first = outcome.failures.first, !outcome.stoppedAnything { throw first.error }
        let stopped = holding.flatMap { info(of: $0.port, inRow: $0.rowPath, snapshot) }.filter { info in
            info.host.map { outcome.remote[$0]?.contains(info.pid) == true } ?? true
        }
        return PortsStopResult(
            port: number, stopped: stopped, killed: outcome.killed,
            failures: outcome.failures.isEmpty
                ? nil
                : outcome.failures.map {
                    PortStopFailure(
                        host: $0.host, port: Int($0.port),
                        error: ($0.error as? WorkspaceError).map(ControlError.init)
                            ?? ControlError(code: "internal", message: "\($0.error)"))
                })
    }

    /// Stops what listens on these ports in a row, as found by a scan now rather than when the panel last looked, so a
    /// server that restarted since is still the one stopped and no pid is signalled after it was reused. A remote row's
    /// ports are as its host's last probe found them, and the host checks each pid still listens before signalling it.
    public func stopPorts(_ numbers: Set<UInt16>, inRow path: String) async {
        let group = await portGroups().first { $0.rowPath == path }
        let outcome = await stop(group?.ports.filter { numbers.contains($0.port) } ?? [])
        for failure in outcome.failures {
            Workspace.hostLog.error(
                "Could not stop port \(failure.port) on \(failure.host, privacy: .public): \(String(describing: failure.error), privacy: .public)"
            )
        }
    }

    private struct Outcome {
        /// The pids each host signalled, which this Mac's scan does not need, being as of now.
        var remote: [String: Set<Int32>] = [:]
        var killed: [PortProcess] = []
        /// Whether this Mac's processes were stopped, or a host answered for its own.
        var stoppedAnything = false
        var failures: [(host: String, port: UInt16, error: any Error)] = []
    }

    /// The one place ports are stopped: this Mac's processes here, and a host's on that host, never here.
    /// A host that fails leaves the others going, and the outcome says which failed.
    private func stop(_ ports: [RowPort]) async -> Outcome {
        let stops = PortStops(ports)
        var outcome = Outcome()
        if !stops.local.isEmpty {
            outcome.killed = await localPorts.stop(stops.local).killed.map { PortProcess(pid: $0, host: nil) }
            outcome.stoppedAnything = true
        }
        for remote in stops.remote {
            do {
                let stopped = try await workspace.stopRemotePort(remote.port, pids: remote.pids, on: remote.host)
                outcome.remote[remote.host, default: []].formUnion(stopped.stopped)
                outcome.killed += stopped.killed.map { PortProcess(pid: $0, host: remote.host) }
                outcome.stoppedAnything = true
                hostMonitor?.portsStopped([remote.port], on: remote.host)
            } catch {
                outcome.failures.append((remote.host, remote.port, error))
            }
        }
        return outcome
    }
}
