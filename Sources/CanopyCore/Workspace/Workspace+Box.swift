import Foundation

/// An upgraded host's snapshot, after its rows are applied, for what shows its panes and agents.
public struct BoxUpdate: Sendable {
    public var host: String
    public var snapshot: BoxSnapshot
    /// Stand-ins of rows the box no longer has, whose terminals close.
    public var goneRows: [String]
}

extension Workspace {
    /// Each upgraded host's snapshots, as they come.
    public func boxUpdates() -> AsyncStream<BoxUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: BoxUpdate.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        boxObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.forgetBoxObserver(id) } }
        return stream
    }

    private func forgetBoxObserver(_ id: UUID) {
        boxObservers[id] = nil
    }

    /// The link to an upgraded host's canopy-box, or nil for a host that is not upgraded.
    public func boxLink(for alias: String) -> BoxLink? {
        guard hosts.hosts[alias]?.box == true else { return nil }
        return boxLinks[alias]
    }

    /// Brings up an upgraded host's link once per connection: the forward to its `box.sock` through the master, and
    /// the link itself, which connects and reconnects on its own.
    public func ensureBoxLink(_ connection: HostConnection) async {
        let alias = connection.alias
        guard hosts.hosts[alias]?.box == true, await connection.state == .connected else { return }
        let generation = await connection.generation
        if boxInstalled[alias] != generation {
            // Once per connection: brings the host's canopy-box up to this build and starts it if it stopped, as
            // after a reboot without lingering. Cheap when it runs and matches.
            do {
                _ = try await BoxInstall.install(on: connection, homeID: homeID, binaries: hostTooling.boxBinaries)
                boxInstalled[alias] = generation
            } catch {
                Self.hostLog.error(
                    "Canopy isn't running on \(alias, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        if boxForwarded[alias] != generation {
            let local = HostPaths.boxSocket(home: home, homeID: homeID, alias: alias)
            try? FileManager.default.createDirectory(
                atPath: (local as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            unlink(local)
            guard let hostHome = try? await connection.home(),
                let result = await connection.forwardSocket(
                    local: local, remote: "\(hostHome)/.canopy/\(homeID)/box/box.sock"),
                result.status == 0
            else { return }
            boxForwarded[alias] = generation
        }
        guard boxLinks[alias] == nil else { return }
        let link = BoxLink(alias: alias, socketPath: HostPaths.boxSocket(home: home, homeID: homeID, alias: alias)) {
            [weak self] in
            BoxConfig(host: alias, repos: self?.hosts.hosts[alias]?.repos ?? [:])
        }
        boxLinks[alias] = link
        await link.start()
        boxWatchers[alias] = Task { [weak self] in
            for await snapshot in await link.snapshots() {
                await self?.applyBoxSnapshot(snapshot, host: alias)
            }
        }
    }

    /// Stops an upgraded host's link, as when the host goes back or is removed.
    /// The forward stays for the rest of the connection: ssh would take the same forward again as done without
    /// binding it again.
    public func stopBoxLink(_ alias: String) async {
        boxWatchers.removeValue(forKey: alias)?.cancel()
        await boxLinks.removeValue(forKey: alias)?.stop()
    }

    /// Makes the host's remote rows the box's rows other than its clones: stand-ins for new ones, branches and heads
    /// brought up to date, and rows the box no longer has forgotten. Tells `boxUpdates` after.
    func applyBoxSnapshot(_ snapshot: BoxSnapshot, host alias: String) async {
        guard let entry = hosts.hosts[alias], entry.box, !upgradingHosts.contains(alias) else { return }
        var changed = false
        var gone: [String] = []
        var touched: Set<String> = []
        for (repoName, _) in entry.repos {
            guard let index = state.repos.firstIndex(where: { self.repoName($0.path) == repoName }) else { continue }
            var repoChanged = false
            let rows = snapshot.rows.filter { !$0.isMain && $0.repo == repoName }
            let paths = Set(rows.map(\.path))
            for row in rows {
                if let position = state.repos[index].remote.firstIndex(where: {
                    $0.host == alias && $0.path == row.path
                }) {
                    var updated = state.repos[index].remote[position]
                    updated.branch = row.branch
                    updated.head = row.head
                    updated.missing = row.missing
                    if updated != state.repos[index].remote[position] {
                        state.repos[index].remote[position] = updated
                        repoChanged = true
                    }
                } else {
                    let entry = RemoteRowEntry(
                        host: alias, path: row.path,
                        standIn: standInPath(
                            alias: alias, dirName: state.repos[index].dirName,
                            leaf: (row.path as NSString).lastPathComponent),
                        branch: row.branch, head: row.head, missing: row.missing)
                    try? entry.makeStandIn()
                    state.repos[index].remote.removeAll { $0.standIn == entry.standIn }
                    state.repos[index].remote.append(entry)
                    state.repos[index].place(entry.standIn, joining: nil)
                    repoChanged = true
                }
            }
            let leaving = state.repos[index].remote.filter { $0.host == alias && !paths.contains($0.path) }
            for row in leaving {
                state.repos[index].remote.removeAll { $0.standIn == row.standIn }
                state.repos[index].forget(row.standIn)
                try? FileManager.default.removeItem(atPath: row.standIn)
                if state.selectedRowPath == row.standIn { state.selectedRowPath = nil }
                gone.append(row.standIn)
                repoChanged = true
            }
            if repoChanged {
                changed = true
                touched.insert(state.repos[index].path)
            }
        }
        if changed {
            try? save()
            for repoPath in touched { await refresh(repoPath: repoPath) }
        }
        let update = BoxUpdate(host: alias, snapshot: snapshot, goneRows: gone)
        for observer in boxObservers.values { observer.yield(update) }
    }

    /// Makes a row on an upgraded host through its canopy-box, by the box's copy of the same branch rules.
    func createBoxRow(
        repoPath: String, host alias: String, branch: String, base: String?, existing: Bool, group: String?
    ) async throws -> CreatedRow {
        let target = try await remoteTarget(repoPath: repoPath, host: alias)
        try await target.connection.connect()
        await ensureBoxLink(target.connection)
        guard let link = boxLinks[alias], await link.waitUntilConnected(within: .seconds(30)) else {
            throw WorkspaceError.hostUnreachable(alias, reason: "canopy-box on \(alias) is not answering.")
        }
        let joining = try group.map { try joiningGroup($0, repoPath: repoPath) }
        let made: BoxRowNewResult = try await link.call(
            BoxMethod.rowNew,
            BoxRowNewParams(repo: target.repoName, branch: branch, base: base, existing: existing))
        let index = try entryIndex(repoPath: repoPath)
        let entry = RemoteRowEntry(
            host: alias, path: made.row.path,
            standIn: standInPath(
                alias: alias, dirName: state.repos[index].dirName, leaf: (made.row.path as NSString).lastPathComponent),
            branch: made.row.branch, head: made.row.head)
        if state.repos[index].remote.contains(where: { $0.host == alias && $0.path == entry.path }) {
            state.repos[index].remote.removeAll { $0.host == alias && $0.path == entry.path }
        }
        try await addRemoteRow(entry, repoPath: repoPath, joining: joining)
        let row = snapshot.row(path: entry.standIn) ?? Row(remote: entry, repoPath: repoPath)
        record(ActivityType.rowCreated, row, data: remoteData(row, ["class": .string(RowClass.remote.rawValue)]))
        return CreatedRow(
            row: row, source: made.source, base: made.base, pullRequest: nil, notes: made.notes,
            warnings: made.warnings)
    }

    /// Removes a row on an upgraded host through its canopy-box. Returns its warnings.
    func removeBoxRow(_ entry: RemoteRowEntry, force: Bool, deleteBranch: Bool) async throws -> [String] {
        let connection = try await connection(for: entry.host)
        try await connection.connect()
        await ensureBoxLink(connection)
        guard let link = boxLinks[entry.host], await link.waitUntilConnected(within: .seconds(30)) else {
            throw WorkspaceError.hostUnreachable(entry.host, reason: "canopy-box on \(entry.host) is not answering.")
        }
        do {
            let removed: BoxRowRemoveResult = try await link.call(
                BoxMethod.rowRemove, BoxRowRemoveParams(path: entry.path, force: force, deleteBranch: deleteBranch))
            return removed.warnings
        } catch let error as ControlError where error.code == "worktree_dirty" {
            throw WorkspaceError.worktreeDirty(entry.standIn)
        } catch let error as ControlError where error.code == "row_not_found" {
            // Gone from the box already, as when it was removed there meanwhile.
            return []
        }
    }
}

extension Workspace {
    /// Switches a host over to canopy-box: installs it, starts it, sends the Mac's settings, and hands it the host's
    /// rows and `panes`. No session is touched. The host is marked upgraded only once the box has taken it all.
    public func upgradeHost(_ alias: String, panes: [BoxAdoptedPane]) async throws -> HostUpgradeResult {
        guard var entry = hosts.hosts[alias] else {
            throw WorkspaceError.hostNotFound(alias, known: hosts.hosts.keys.sorted())
        }
        let connection = await connection(alias, entry)
        try await connection.connect()
        try await prepareHost(connection)
        let report = try await BoxInstall.install(on: connection, homeID: homeID, binaries: hostTooling.boxBinaries)
        boxInstalled[alias] = await connection.generation
        let saved = entry
        entry.box = true
        try HostsConfigFile(url: home.configFile).save(alias, entry)
        upgradingHosts.insert(alias)
        defer { upgradingHosts.remove(alias) }
        do {
            await ensureBoxLink(connection)
            guard let link = boxLinks[alias], await link.waitUntilConnected(within: .seconds(30)) else {
                throw WorkspaceError.hostUnreachable(alias, reason: "canopy-box on \(alias) did not answer.")
            }
            let rows = remoteRows(on: alias).compactMap { row -> BoxAdoptedRow? in
                guard let repo = state.repos.first(where: { $0.remote.contains { $0.standIn == row.standIn } }) else {
                    return nil
                }
                return BoxAdoptedRow(repo: repoName(repo.path), path: row.path, branch: row.branch)
            }
            let adopted: BoxAdoptResult = try await link.call(
                BoxMethod.adopt, BoxAdoptParams(rows: rows, panes: panes, nextPane: 1))
            // The box names each row by its real path, which differs from the Mac's when the host reaches its home
            // through a link, and its snapshots name them so from now on.
            for (given, taken) in zip(rows, adopted.rows) where given.path != taken {
                for index in state.repos.indices {
                    for position in state.repos[index].remote.indices
                    where state.repos[index].remote[position].host == alias
                        && state.repos[index].remote[position].path == given.path
                    {
                        state.repos[index].remote[position].path = taken
                    }
                }
            }
            try? save()
            // From now on the host's relay sends hooks and calls to the box, which has the panes they name.
            _ = try await output(of: markCommand(adopted: true), on: connection)
            activity.record(ActivityType.hostUpgraded, data: ["host": .string(alias)])
            var warnings: [String] = []
            if !adopted.missing.isEmpty {
                warnings.append(
                    "\(alias) no longer has the sessions of \(adopted.missing.joined(separator: ", ")), so they were left out."
                )
            }
            if !report.systemd {
                warnings.append(
                    "systemd's user manager does not answer on \(alias), so canopy-box runs as a plain process and "
                        + "will not start again after the host restarts.")
            } else if report.lingering == false {
                warnings.append(
                    "Lingering is off on \(alias), so canopy-box stops when no one is logged in. "
                        + "Run `sudo loginctl enable-linger $USER` there once.")
            }
            return HostUpgradeResult(
                alias: alias, rows: adopted.rows.count, panes: adopted.panes.count, missing: adopted.missing,
                warnings: warnings)
        } catch {
            // As before the upgrade: the relay talks to the app, and no daemon waits on the host for panes it lacks.
            try? HostsConfigFile(url: home.configFile).save(alias, saved)
            await stopBoxLink(alias)
            _ = try? await output(of: markCommand(adopted: false), on: connection)
            try? await BoxInstall.stop(on: connection, homeID: homeID)
            throw error
        }
    }

    /// Switches a host back: the box hands back its rows and panes, stops, and the Mac tracks the host again. Returns
    /// what the box gave back.
    public func undoUpgrade(_ alias: String) async throws -> (HostUpgradeResult, BoxReleaseResult) {
        guard var entry = hosts.hosts[alias] else {
            throw WorkspaceError.hostNotFound(alias, known: hosts.hosts.keys.sorted())
        }
        guard entry.box else { throw WorkspaceError.hostCommandFailed(alias, reason: "\(alias) is not upgraded.") }
        let connection = await connection(alias, entry)
        try await connection.connect()
        await ensureBoxLink(connection)
        guard let link = boxLinks[alias], await link.waitUntilConnected(within: .seconds(30)) else {
            throw WorkspaceError.hostUnreachable(alias, reason: "canopy-box on \(alias) did not answer.")
        }
        // The box's snapshot after it lets go has no rows, which must not read as rows removed.
        upgradingHosts.insert(alias)
        defer { upgradingHosts.remove(alias) }
        // Hooks go to the app again before the box lets go, so none lands on a box that no longer has its pane.
        _ = try await output(of: markCommand(adopted: false), on: connection)
        let released: BoxReleaseResult = try await link.call(BoxMethod.release, JSONValue.object([:]))
        entry.box = false
        try HostsConfigFile(url: home.configFile).save(alias, entry)
        await stopBoxLink(alias)
        restoreReleasedRows(released.rows, host: alias)
        var warnings: [String] = []
        do {
            try await BoxInstall.stop(on: connection, homeID: homeID)
        } catch {
            warnings.append("canopy-box on \(alias) may still run: \(error)")
        }
        activity.record(ActivityType.hostDowngraded, data: ["host": .string(alias)])
        return (
            HostUpgradeResult(
                alias: alias, rows: released.rows.count, panes: released.panes.count, warnings: warnings), released
        )
    }

    /// Writes or removes `adopted` in this home's box folder on the host, which the relay reads.
    func markCommand(adopted: Bool) -> [String] {
        let script =
            adopted
            ? #"mkdir -p "$HOME/.canopy/$0/box" && touch "$HOME/.canopy/$0/box/adopted""#
            : #"rm -f "$HOME/.canopy/$0/box/adopted""#
        return ["sh", "-c", script, homeID]
    }

    /// Rows the box gave back that the Mac has no entry for, as one made on the box while no snapshot reached the Mac.
    func restoreReleasedRows(_ rows: [BoxAdoptedRow], host alias: String) {
        var touched = Set<String>()
        for row in rows {
            guard remoteRow(host: alias, path: row.path) == nil,
                let index = state.repos.firstIndex(where: { repoName($0.path) == row.repo })
            else { continue }
            let entry = RemoteRowEntry(
                host: alias, path: row.path,
                standIn: standInPath(
                    alias: alias, dirName: state.repos[index].dirName, leaf: (row.path as NSString).lastPathComponent),
                branch: row.branch, head: nil)
            try? entry.makeStandIn()
            state.repos[index].remote.append(entry)
            state.repos[index].place(entry.standIn, joining: nil)
            touched.insert(state.repos[index].path)
        }
        guard !touched.isEmpty else { return }
        try? save()
        Task { for path in touched { await self.refresh(repoPath: path) } }
    }
}
