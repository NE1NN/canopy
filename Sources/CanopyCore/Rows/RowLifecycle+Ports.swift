import Foundation

/// Ports for the panel and `canopy ports`, on the main actor where the terminals' shells are known.
extension RowLifecycle {
    /// Every row's ports, in sidebar order: each repo's rows, then its other worktrees.
    public func portGroups() async -> [PortGroup] {
        let rows = await workspace.snapshot.repos.flatMap(\.allRows).map(\.path)
        let shells = terminals.tabsByRow.mapValues { tabs in tabs.flatMap(\.paneList).compactMap(\.pid) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: PortAttribution.assign(
                        PortScanner.listeningPorts(), rows: rows, shells: shells, parent: ProcessTable.parent(of:),
                        folder: ProcessTable.folder(of:)))
            }
        }
    }

    /// One row's ports, or every row's when `rowPath` is nil.
    public func portInfo(rowPath: String?) async -> [PortInfo] {
        let groups = await portGroups()
        let snapshot = await workspace.snapshot
        return groups.filter { rowPath == nil || $0.rowPath == rowPath }.flatMap { group in
            let row = snapshot.row(path: group.rowPath)
            let repo = row.flatMap { snapshot.repo(path: $0.repoPath)?.name } ?? ""
            return group.ports.map { port in
                PortInfo(
                    repo: repo, row: row?.displayName ?? group.rowPath, rowPath: group.rowPath, port: Int(port.port),
                    pid: port.pid, process: port.process)
            }
        }
    }

    /// Stops what listens on a port, if the port belongs to a row. Anything else is not Canopy's to stop.
    public func stopPort(_ number: Int) async throws -> PortsStopResult {
        let holding = await portInfo(rowPath: nil).filter { $0.port == number }
        guard !holding.isEmpty else { throw WorkspaceError.portNotFound(number) }
        let outcome = await PortStopper().stop(
            holding.map { ListeningPort(port: UInt16($0.port), pid: $0.pid, process: $0.process) })
        return PortsStopResult(port: number, stopped: holding, killed: outcome.killed)
    }

}
