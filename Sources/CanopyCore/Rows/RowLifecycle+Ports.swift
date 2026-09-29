import Foundation

/// Ports for the panel and `canopy ports`, on the main actor where the terminals' shells are known.
extension RowLifecycle {
    /// Every row's ports, in sidebar order: each repo's rows, then its other worktrees, then the rows of each plugin
    /// that is on. Ports in the system's random range are left out.
    public func portGroups() async -> [PortGroup] {
        let snapshot = await workspace.snapshot
        let rows = snapshot.repos.flatMap(\.allRows).map(\.path) + snapshot.activePlugins.flatMap(\.rows).map(\.path)
        let shells = terminals.tabsByRow.mapValues { tabs in tabs.flatMap(\.paneList).compactMap(\.pid) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let random = PortScanner.randomPortRange()
                let ports = PortScanner.listeningPorts().filter { !random.contains($0.port) }
                continuation.resume(
                    returning: PortAttribution.assign(
                        ports, rows: rows, shells: shells, parent: ProcessTable.parent(of:),
                        folder: ProcessTable.folder(of:)))
            }
        }
    }

    /// One row's ports, or every row's when `rowPath` is nil, with a line for each process on a port.
    public func portInfo(rowPath: String?) async -> [PortInfo] {
        let groups = await portGroups()
        let snapshot = await workspace.snapshot
        return groups.filter { rowPath == nil || $0.rowPath == rowPath }.flatMap { group in
            let row = snapshot.sidebarRow(path: group.rowPath)
            let repo = row?.worktree.flatMap { snapshot.repo(path: $0.repoPath)?.name }
            return group.ports.flatMap(\.processes).map { port in
                PortInfo(
                    repo: repo, plugin: row?.pluginRow?.plugin, row: row?.displayName ?? group.rowPath,
                    rowPath: group.rowPath, port: Int(port.port), pid: port.pid, process: port.process)
            }
        }
    }

    /// Stops what listens on a port in one row, or in any row when `rowPath` is nil. A port that belongs to no row is
    /// not Canopy's to stop, and one in another row is refused, since it is most likely another agent's server.
    public func stopPort(_ number: Int, rowPath: String?) async throws -> PortsStopResult {
        let everywhere = await portInfo(rowPath: nil).filter { $0.port == number }
        let holding = everywhere.filter { rowPath == nil || $0.rowPath == rowPath }
        guard !holding.isEmpty else {
            if let other = everywhere.first { throw WorkspaceError.portInOtherRow(number, row: other.row) }
            throw WorkspaceError.portNotFound(number)
        }
        let outcome = await PortStopper().stop(
            holding.map { ListeningPort(port: UInt16($0.port), pid: $0.pid, process: $0.process) })
        return PortsStopResult(port: number, stopped: holding, killed: outcome.killed)
    }

    /// Stops what listens on these ports in a row, as found by a scan now rather than when the panel last looked, so a
    /// server that restarted since is still the one stopped and no pid is signalled after it was reused.
    public func stopPorts(_ numbers: Set<UInt16>, inRow path: String) async {
        let group = await portGroups().first { $0.rowPath == path }
        let holding = group?.ports.filter { numbers.contains($0.port) }.flatMap(\.processes) ?? []
        _ = await PortStopper().stop(holding)
    }
}
