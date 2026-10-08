import Foundation

/// How the workspace reaches hosts: which ssh, with what environment, on what clock. Tests pass a stand-in ssh.
public struct HostTooling: Sendable {
    public var sshExecutable: String
    public var environment: @Sendable () -> [String: String]
    public var clock: any HostClock

    public init(
        sshExecutable: String = SSHCommand.executable(),
        environment: @escaping @Sendable () -> [String: String] = { GitEnvironment.current },
        clock: any HostClock = SystemHostClock()
    ) {
        self.sshExecutable = sshExecutable
        self.environment = environment
        self.clock = clock
    }
}

extension Workspace {
    /// The hosts config.json names now.
    public nonisolated var hosts: HostsConfig {
        HostsConfig.load(from: home.configFile)
    }

    /// The connection to a host config.json names, made when first asked for.
    public func connection(for alias: String) async throws -> HostConnection {
        let hosts = self.hosts.hosts
        guard let entry = hosts[alias] else {
            throw WorkspaceError.hostNotFound(alias, known: hosts.keys.sorted())
        }
        return await connection(alias, entry)
    }

    func connection(_ alias: String, _ entry: HostEntry) async -> HostConnection {
        if let existing = hostConnections[alias] {
            await existing.update(entry)
            return existing
        }
        let ssh = ssh(for: alias)
        try? FileManager.default.createDirectory(
            atPath: (ssh.controlPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let connection = HostConnection(
            alias: alias, entry: entry, ssh: ssh,
            launcher: SubprocessHostLauncher(environment: hostTooling.environment),
            clock: hostTooling.clock, activity: activity)
        hostConnections[alias] = connection
        return connection
    }

    nonisolated func ssh(for alias: String) -> SSHCommand {
        SSHCommand(
            executable: hostTooling.sshExecutable,
            controlPath: HostPaths.controlSocket(home: home, homeID: homeID, alias: alias), alias: alias)
    }

    /// git in a folder on a host, through its master.
    nonisolated func remoteGit(_ alias: String) -> GitRunner {
        GitRunner.remote(ssh(for: alias), environment: hostTooling.environment())
    }

    /// Checks the host, installs Canopy's files there, and saves it. Adding a host again updates it: `repos` join the
    /// ones it has, and `wake` and `idleDetachMinutes` replace theirs when given.
    @discardableResult
    public func addHost(
        alias: String, repos requested: [String: String], wake: String?, idleDetachMinutes: Int?
    ) async throws -> HostInfo {
        guard !alias.isEmpty, !alias.hasPrefix("-"), !alias.contains(where: \.isWhitespace) else {
            throw WorkspaceError.hostUnknown(alias)
        }
        let snapshot = self.snapshot
        var names: [String: String] = [:]
        for (name, path) in requested {
            guard let repo = TargetResolver.match(repo: name, in: snapshot) else {
                throw WorkspaceError.repoNotFound(name)
            }
            names[repo.name] = path
        }
        var entry = hosts.hosts[alias] ?? HostEntry()
        if let wake { entry.wake = wake }
        if let idleDetachMinutes { entry.idleDetachMinutes = max(idleDetachMinutes, 0) }
        let connection = await connection(alias, entry)
        do {
            try await connection.connect()
        } catch WorkspaceError.hostUnreachable(_, let reason) where reason.contains("Could not resolve hostname") {
            throw WorkspaceError.hostUnknown(alias)
        }
        let facts = HostChecks.parse(try await output(of: HostChecks.factsCommand, on: connection))
        let problems = HostChecks.problems(facts)
        guard problems.isEmpty else { throw WorkspaceError.hostUnfit(alias, missing: problems) }
        for (name, path) in names {
            let clone = HostChecks.resolve(path, home: facts.home)
            // Empty at a checkout's top, however the path reaches it, and a path to its parent above anywhere inside.
            let up = try? await remoteGit(alias).run(["rev-parse", "--show-cdup"], in: clone)
            guard up?.trimmingCharacters(in: .newlines) == "" else {
                throw WorkspaceError.cloneNotFound(alias, path: clone)
            }
            entry.repos[name] = clone
        }
        try await installFiles(on: connection)
        try HostsConfigFile(url: home.configFile).save(alias, entry)
        await connection.update(entry)
        activity.record(ActivityType.hostAdded, data: ["host": .string(alias)])
        var added = await info(alias, entry)
        added.warnings = HostChecks.warnings(facts, alias: alias)
        return added
    }

    /// Writes Canopy's files on the host unless it has this version of them.
    func installFiles(on connection: HostConnection) async throws {
        let installed = try await output(of: HostFiles.versionCommand, on: connection)
        guard installed.trimmingCharacters(in: .whitespacesAndNewlines) != HostFiles.version else { return }
        _ = try await output(of: HostFiles.installCommand(server: HostPaths.tmuxServer(homeID: homeID)), on: connection)
    }

    /// What a command printed on the host, failing with its message when it fails.
    func output(of remote: [String], on connection: HostConnection, timeout: Duration = .seconds(60)) async throws
        -> String
    {
        let result = try await connection.run(remote, timeout: timeout)
        let errors = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 255 || result.timedOut {
            throw WorkspaceError.hostUnreachable(connection.alias, reason: errors.isEmpty ? "ssh failed." : errors)
        }
        guard result.status == 0 else {
            throw WorkspaceError.hostCommandFailed(
                connection.alias, reason: errors.isEmpty ? "exit \(result.status)" : errors)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Forgets a host without rows. Its files on the host stay.
    public func removeHost(alias: String) async throws {
        guard hosts.hosts[alias] != nil else {
            throw WorkspaceError.hostNotFound(alias, known: hosts.hosts.keys.sorted())
        }
        let rows = state.repos.flatMap(\.remote).filter { $0.host == alias }.map(\.standIn)
        guard rows.isEmpty else { throw WorkspaceError.hostHasRows(alias, rows: rows) }
        try HostsConfigFile(url: home.configFile).remove(alias)
        await hostConnections.removeValue(forKey: alias)?.stop()
        activity.record(ActivityType.hostRemoved, data: ["host": .string(alias)])
    }

    public func hostListing() async -> HostListing {
        let config = hosts
        var infos: [HostInfo] = []
        for (alias, entry) in config.hosts.sorted(by: { $0.key < $1.key }) {
            infos.append(await info(alias, entry))
        }
        return HostListing(hosts: infos, warnings: config.warnings)
    }

    func info(_ alias: String, _ entry: HostEntry) async -> HostInfo {
        let connection = hostConnections[alias]
        return HostInfo(
            alias: alias, state: await connection?.state ?? .idle, repos: entry.repos, wake: entry.wake,
            idleDetachMinutes: entry.idleDetachMinutes,
            rows: state.repos.flatMap(\.remote).filter { $0.host == alias }.map(\.standIn),
            tmuxServer: HostPaths.tmuxServer(homeID: homeID), error: await connection?.lastError)
    }

    /// Lets every host go, as Canopy quits. Sessions on hosts only detach.
    public func stopHosts() async {
        for connection in hostConnections.values {
            await connection.stop()
        }
        hostConnections.removeAll()
    }
}

extension Workspace {
    public var pendingSessionKills: [String: [String]] {
        state.pendingSessionKills
    }

    /// Readies a connected host once per connection: Canopy's files at this version, and sessions closed while it was
    /// away ended.
    public func prepareHost(_ connection: HostConnection) async throws {
        let alias = connection.alias
        let generation = await connection.generation
        guard preparedHosts[alias] != generation else { return }
        try await installFiles(on: connection)
        if let pending = state.pendingSessionKills[alias], !pending.isEmpty {
            _ = try await output(of: killCommand(pending), on: connection)
            state.pendingSessionKills[alias] = nil
            try? save()
        }
        preparedHosts[alias] = generation
    }

    /// Ends tmux sessions on a host. One that is not connected keeps them for its next connection, rather than being
    /// woken for it.
    public func killSessions(_ sessions: [String], on alias: String) async {
        guard !sessions.isEmpty else { return }
        if let connection = hostConnections[alias], await connection.state == .connected,
            (try? await output(of: killCommand(sessions), on: connection)) != nil
        {
            return
        }
        var pending = state.pendingSessionKills[alias] ?? []
        pending += sessions.filter { !pending.contains($0) }
        state.pendingSessionKills[alias] = pending
        try? save()
    }

    private func killCommand(_ sessions: [String]) -> [String] {
        ["sh", "-c", #"s=$0; for n; do tmux -u -L "$s" kill-session -t "=$n" 2>/dev/null; done; true"#]
            + [HostPaths.tmuxServer(homeID: homeID)] + sessions
    }

    /// Types `text` and Return into a session, once the host has it, as a pane's `--run` does. Gives up quietly after
    /// two minutes, as typing into a local shell that never comes up does.
    public func sendKeys(_ text: String, to session: String, on alias: String) async {
        guard let connection = try? await connection(for: alias) else { return }
        let server = HostPaths.tmuxServer(homeID: homeID)
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            let result = try? await connection.run(
                ["tmux", "-u", "-L", server, "has-session", "-t", "=\(session)"], timeout: .seconds(15))
            if result?.status == 0 { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = try? await connection.run(
            [
                "sh", "-c",
                #"tmux -u -L "$0" send-keys -t "=$1:" -l "$2" && tmux -u -L "$0" send-keys -t "=$1:" Enter"#,
                server, session, text,
            ],
            timeout: .seconds(15))
    }

    /// The ssh command line that joins a remote pane's session, or starts it in `folder`.
    public func attachCommand(
        host alias: String, repoPath: String, session: String, folder: String, pane: String, rowName: String
    ) async throws -> [String] {
        let target = try await remoteTarget(repoPath: repoPath, host: alias)
        let row = state.repos.first { $0.path == repoPath }?.remote.first {
            $0.host == alias && Paths.isInside(folder, $0.path)
        }
        let environment = RemoteAttach.environment(
            pane: pane, rowName: rowName, repoName: target.repoName, host: alias, rowPath: row?.path ?? folder,
            clone: target.clone)
        let tmux = RemoteAttach.tmuxCommand(
            server: HostPaths.tmuxServer(homeID: homeID), session: session, folder: folder, environment: environment)
        return ssh(for: alias).attach(tmux)
    }
}

extension Workspace {
    /// The hosts whose master is up.
    public func connectedHosts() async -> [HostConnection] {
        var connected: [HostConnection] = []
        for connection in hostConnections.values where await connection.state == .connected {
            connected.append(connection)
        }
        return connected
    }

    /// Lists the host's worktrees again for every repo with rows there.
    public func refreshRemote(host alias: String) async {
        let repos = state.repos.filter { $0.remote.contains { $0.host == alias } }.map(\.path)
        for repo in repos {
            await refreshRemote(repoPath: repo, host: alias)
        }
    }
}

extension Workspace {
    /// Stops masters a Canopy that crashed on this home left running, which would keep their hosts awake for good.
    func stopStaleMasters() async {
        let launcher = SubprocessHostLauncher(environment: hostTooling.environment)
        for alias in hosts.hosts.keys {
            let ssh = ssh(for: alias)
            guard FileManager.default.fileExists(atPath: ssh.controlPath) else { continue }
            _ = await launcher.run(ssh.control("exit"), timeout: .seconds(5))
        }
    }
}
