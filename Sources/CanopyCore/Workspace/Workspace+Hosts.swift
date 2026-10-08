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
            let top = try? await remoteGit(alias).run(["rev-parse", "--show-toplevel"], in: clone)
            guard top?.trimmingCharacters(in: .newlines) == clone else {
                throw WorkspaceError.cloneNotFound(alias, path: clone)
            }
            entry.repos[name] = clone
        }
        try await installFiles(on: connection)
        try HostsConfigFile(url: home.configFile).save(alias, entry)
        await connection.update(entry)
        activity.record(ActivityType.hostAdded, data: ["host": .string(alias)])
        return await info(alias, entry)
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

    public func hostInfos() async -> [HostInfo] {
        var infos: [HostInfo] = []
        for (alias, entry) in hosts.hosts.sorted(by: { $0.key < $1.key }) {
            infos.append(await info(alias, entry))
        }
        return infos
    }

    func info(_ alias: String, _ entry: HostEntry) async -> HostInfo {
        let connection = hostConnections[alias]
        return HostInfo(
            alias: alias, state: await connection?.state ?? .idle, repos: entry.repos, wake: entry.wake,
            idleDetachMinutes: entry.idleDetachMinutes,
            rows: state.repos.flatMap(\.remote).filter { $0.host == alias }.map(\.standIn),
            error: await connection?.lastError)
    }

    /// Lets every host go, as Canopy quits. Sessions on hosts only detach.
    public func stopHosts() async {
        for connection in hostConnections.values {
            await connection.stop()
        }
        hostConnections.removeAll()
    }
}
