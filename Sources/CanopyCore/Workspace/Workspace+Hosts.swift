import Foundation
import os

/// How the workspace reaches hosts: which ssh, with what environment, on what clock, and which `canopy` runs their
/// relayed calls. Tests pass a stand-in ssh and CLI.
public struct HostTooling: Sendable {
    public var sshExecutable: String
    public var environment: @Sendable () -> [String: String]
    public var clock: any HostClock
    /// The app's bundled CLI. Without one, hosts' calls are refused.
    public var relayCLI: String?
    /// What runs each host's ssh, by alias; nil runs `sshExecutable`.
    public var launcher: (@Sendable (String) -> any HostProcessLauncher)?

    public init(
        sshExecutable: String = SSHCommand.executable(),
        environment: @escaping @Sendable () -> [String: String] = { GitEnvironment.current },
        clock: any HostClock = SystemHostClock(),
        relayCLI: String? = nil,
        launcher: (@Sendable (String) -> any HostProcessLauncher)? = nil
    ) {
        self.sshExecutable = sshExecutable
        self.environment = environment
        self.clock = clock
        self.relayCLI = relayCLI
        self.launcher = launcher
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
            launcher: hostTooling.launcher?(alias) ?? SubprocessHostLauncher(environment: hostTooling.environment),
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

    /// Checks the host, installs Canopy's files and hooks there, and saves it. Adding a host again updates it: `repos`
    /// join the ones it has, and `wake` and `idleDetachMinutes` replace theirs when given.
    @discardableResult
    public func addHost(
        alias: String, repos requested: [String: String], wake: String?, idleDetachMinutes: Int?
    ) async throws -> HostInfo {
        guard !alias.isEmpty, !alias.hasPrefix("-"), !alias.contains(where: \.isWhitespace) else {
            throw WorkspaceError.hostUnknown(alias)
        }
        guard alias != RowTarget.local else { throw WorkspaceError.hostReserved(alias) }
        let snapshot = self.snapshot
        var names: [String: String] = [:]
        for (name, path) in requested {
            guard let repo = TargetResolver.match(repo: name, in: snapshot) else {
                throw WorkspaceError.repoNotFound(name)
            }
            names[repo.name] = path
        }
        let saved = hosts.hosts[alias]
        var entry = saved ?? HostEntry()
        if let wake { entry.wake = wake }
        if let idleDetachMinutes { entry.idleDetachMinutes = max(idleDetachMinutes, 0) }
        // Connecting already uses the new settings, so a new wake command can start the host.
        let connection = await connection(alias, entry)
        let facts: HostFacts
        do {
            facts = try await check(alias, &entry, names: names, on: connection)
            try HostsConfigFile(url: home.configFile).save(alias, entry)
        } catch {
            // A host add that fails leaves the host as config.json has it.
            if let saved {
                await connection.update(saved)
            } else {
                await connection.stop()
                hostConnections[alias] = nil
                preparedHosts[alias] = nil
            }
            throw error
        }
        await connection.update(entry)
        activity.record(ActivityType.hostAdded, data: ["host": .string(alias)])
        var added = await info(alias, entry)
        added.warnings = HostChecks.warnings(facts, alias: alias)
        return added
    }

    /// Checks the host has what Canopy needs and each repo's clone, then installs Canopy's files and hooks there.
    private func check(
        _ alias: String, _ entry: inout HostEntry, names: [String: String], on connection: HostConnection
    )
        async throws -> HostFacts
    {
        // Caught here rather than by the connection, which keeps trying a name that does not resolve for now. A host
        // with a wake command is woken first, since its name may only resolve while it is awake.
        if entry.wake == nil, await connection.isUnknownAlias() { throw WorkspaceError.hostUnknown(alias) }
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
        try await installHooks(on: connection)
        return facts
    }

    /// Writes Canopy's files on the host unless it has this version of them.
    func installFiles(on connection: HostConnection) async throws {
        let installed = try await output(of: HostFiles.versionCommand(homeID: homeID), on: connection)
        guard installed.trimmingCharacters(in: .whitespacesAndNewlines) != HostFiles.version else { return }
        _ = try await output(of: HostFiles.installCommand(homeID: homeID), on: connection)
    }

    /// Adds Canopy's hooks to Claude Code's settings on the host, with the code `canopy hooks install` runs here. They
    /// run `$CANOPY_CLI`, which each home's panes point at that home's relay, so every home on the host shares them.
    /// Settings changed by someone else meanwhile are read and changed again, as here.
    func installHooks(on connection: HostConnection) async throws {
        let alias = connection.alias
        var path = "Claude Code's settings"
        for _ in 0..<3 {
            let printed = try await output(of: HostClaudeSettings.readCommand, on: connection)
            guard let settings = HostClaudeSettings.contents(from: printed) else {
                throw WorkspaceError.hostCommandFailed(alias, reason: "Could not read \(path): \(printed)")
            }
            path = settings.path
            let installed: Data?
            do {
                installed = try ClaudeSettingsFile.installing(into: settings.data)
            } catch JSONFileError.unreadable(let reason) {
                throw WorkspaceError.hostCommandFailed(
                    alias,
                    reason: "\(path) is not settings Claude Code can read (\(reason)). Fix it and add the host again.")
            }
            guard let installed else { return }
            let written = try await output(
                of: HostClaudeSettings.writeCommand(replacing: settings.data, with: installed), on: connection)
            if written.trimmingCharacters(in: .whitespacesAndNewlines) != "changed" { return }
        }
        throw WorkspaceError.hostCommandFailed(alias, reason: "\(path) kept changing while Canopy wrote it.")
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
        preparedHosts[alias] = nil
        portForwarders[alias] = nil
        relayServers.removeValue(forKey: alias)?.stop()
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
        portForwarders.removeAll()
        for server in relayServers.values {
            server.stop()
        }
        relayServers.removeAll()
    }
}

extension Workspace {
    public var pendingSessionKills: [String: [String]] {
        state.pendingSessionKills
    }

    /// Readies a connected host once per connection: Canopy's files at this version, the host's `canopy` forwarded to
    /// this app, and sessions closed while it was away ended.
    public func prepareHost(_ connection: HostConnection) async throws {
        let alias = connection.alias
        let generation = await connection.generation
        if let prepared = preparedHosts[alias], prepared.generation == generation {
            return try await prepared.task.value
        }
        let task = Task { try await self.prepare(connection) }
        preparedHosts[alias] = (generation, task)
        do {
            try await task.value
        } catch {
            // A failed preparation is tried again by the next caller.
            if preparedHosts[alias]?.generation == generation { preparedHosts[alias] = nil }
            throw error
        }
    }

    private func prepare(_ connection: HostConnection) async throws {
        try await installFiles(on: connection)
        await forwardRelay(on: connection)
        let alias = connection.alias
        if let pending = state.pendingSessionKills[alias], !pending.isEmpty {
            _ = try await output(of: killCommand(pending), on: connection)
            // Sessions closed meanwhile wait for the next connection.
            let left = (state.pendingSessionKills[alias] ?? []).filter { !pending.contains($0) }
            state.pendingSessionKills[alias] = left.isEmpty ? nil : left
            try? save()
        }
    }

    static let hostLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ne1nn.Canopy", category: "hosts")

    /// Forwards the host's relay socket to the host's socket here, through the master, for as long as it runs. sshd
    /// leaves the socket's file behind when a connection drops, and will not forward over it, so it goes first. The
    /// socket's folder is the home's own, which the install made with the host's umask, so it is made private here.
    /// Panes work without the forward, only without `canopy`, so a failure is logged rather than failing the attach.
    private func forwardRelay(on connection: HostConnection) async {
        let alias = connection.alias
        do {
            let local = try relayServer(for: alias).socketPath
            let remote = HostPaths.relaySocket(home: try await connection.home(), homeID: homeID)
            _ = try await output(
                of: ["sh", "-c", #"mkdir -p -m 700 "${0%/*}" && chmod 700 "${0%/*}" && rm -f "$0""#, remote],
                on: connection,
                timeout: .seconds(30))
            guard let result = await connection.forward(remote: remote, local: local) else {
                throw WorkspaceError.hostUnreachable(alias, reason: "The connection ended.")
            }
            guard result.status == 0 else {
                let errors = String(decoding: result.stderr, as: UTF8.self)
                throw WorkspaceError.hostCommandFailed(
                    alias, reason: errors.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            Self.hostLog.error(
                "No canopy on \(alias, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The host's socket here, served from the first connection on until the host is removed or Canopy quits.
    private func relayServer(for alias: String) throws -> HostRelayServer {
        if let running = relayServers[alias] { return running }
        let server = HostRelayServer(
            socketPath: HostPaths.hostSocket(home: home, homeID: homeID, alias: alias), host: alias
        ) { [weak self] request, host in
            await self?.relay(request, host: host) ?? .failure("Canopy is quitting.", code: "relay_unavailable")
        }
        try server.start()
        relayServers[alias] = server
        return server
    }

    /// Runs the report a hook on the host kept for the pane while it could not reach this app, so the pane's agent
    /// shows what it did meanwhile. A pane attaching waits for it, so neither step waits long, and a failure is let go.
    public func replayKeptReport(pane: String, on connection: HostConnection) async {
        let command = HostFiles.replayCommand(homeID: homeID, pane: pane)
        guard let result = try? await connection.run(command, timeout: .seconds(10)), result.status == 0,
            !result.stdout.isEmpty,
            let request = try? JSONDecoder().decode(RelayRequest.self, from: result.stdout)
        else { return }
        let alias = connection.alias
        // Kept by the files of the time, which may be older than these: a live relay is asked to run again for that,
        // but a kept report cannot be.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await self.runRelayed(request, host: alias) }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
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
                #"tmux -u -L "$0" send-keys -t "=$1:" -l -- "$2" && tmux -u -L "$0" send-keys -t "=$1:" Enter"#,
                server, session, text,
            ],
            timeout: .seconds(15))
    }

    /// The ssh command line that joins a remote pane's session, or starts it in `folder`.
    public func attachCommand(
        host alias: String, repoPath: String, standIn: String, session: String, folder: String, pane: String,
        rowName: String
    ) async throws -> [String] {
        let target = try await remoteTarget(repoPath: repoPath, host: alias)
        let row = remoteRow(standIn: standIn)
        let environment = RemoteAttach.environment(
            pane: pane, rowName: rowName, repoName: target.repoName, host: alias, rowPath: row?.path ?? folder,
            clone: target.clone, hostHome: try await target.connection.home(), homeID: homeID)
        let tmux = RemoteAttach.tmuxCommand(homeID: homeID, session: session, folder: folder, environment: environment)
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

    /// The pids of the connected hosts' masters, which hold their forwards' sockets on this Mac.
    public func masterPIDs() async -> Set<Int32> {
        var pids = Set<Int32>()
        for connection in hostConnections.values {
            if let pid = await connection.masterPID { pids.insert(pid) }
        }
        return pids
    }

    /// Stops what listens on `port` on the host, signalling only those of `pids` that still listen on it there.
    /// Returns the pids it had to SIGKILL.
    public func stopRemotePort(_ port: UInt16, pids: [Int32], on alias: String) async throws -> [Int32] {
        struct Stopped: Decodable { var killed: [Int32] }
        let connection = try await connection(for: alias)
        let printed = try await output(
            of: HostFiles.stopPortCommand(homeID: homeID, port: port, pids: pids), on: connection,
            timeout: .seconds(30))
        guard let stopped = try? JSONDecoder().decode(Stopped.self, from: Data(printed.utf8)) else {
            throw WorkspaceError.hostCommandFailed(alias, reason: "canopy-host stop-port printed \(printed)")
        }
        return stopped.killed
    }

    /// The host's remote rows, in the order the sidebar has their repos.
    public func remoteRows(on alias: String) -> [RemoteRowEntry] {
        state.repos.flatMap(\.remote).filter { $0.host == alias }
    }

    /// Forwards a host's listening ports to Mac ports, one host at a time, so two hosts never pick the same Mac port.
    /// Nil when the round said nothing of the host's forwards, as when its master stopped meanwhile.
    public func forwardPorts(_ wanted: [RemoteListeningPort], on connection: HostConnection) async
        -> [UInt16: PortForward]?
    {
        portForwarders[connection.alias] = connection
        let previous = forwardingPorts
        let round = Task {
            await previous?.value
            var taken = Set<UInt16>()
            for (alias, other) in portForwarders where alias != connection.alias {
                taken.formUnion(await other.forwardedPorts)
            }
            return await connection.forwardPorts(wanted, taken: taken)
        }
        forwardingPorts = Task { _ = await round.value }
        return await round.value
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
    /// Runs a call a host's relay sent, as its `canopy` would have run on this Mac. It runs as long as the CLI does,
    /// and a cancelled task, as when the relay hangs up, stops the CLI and everything it started.
    public func relay(_ request: RelayRequest, host alias: String) async -> RelayReply {
        guard request.version == HostFiles.version else {
            if let connection = hostConnections[alias] {
                Task { try? await self.installFiles(on: connection) }
            }
            return .failure("Canopy updated its files on \(alias); run it again.", code: "relay_outdated")
        }
        return await runRelayed(request, host: alias)
    }

    /// Runs a relayed call whatever version of the host's files sent it.
    func runRelayed(_ request: RelayRequest, host alias: String) async -> RelayReply {
        let receivedAt = Date()
        guard let cli = hostTooling.relayCLI else {
            return .failure("This Canopy has no canopy CLI to run for \(alias).", code: "relay_unavailable")
        }
        let rows = state.repos.flatMap(\.remote)
        let environment = RelayRun.environment(
            for: request, host: alias, rows: rows, home: home, receivedAt: receivedAt,
            shellEnvironment: hostTooling.environment())
        let folder = RelayRun.folder(for: request, host: alias, rows: rows, home: home)
        let input = request.input
        let handle = SubprocessHandle()
        let result = await withTaskCancellationHandler {
            await onOwnThread {
                Result {
                    try Subprocess.run(
                        cli, request.args, environment: environment, directory: folder, timeout: nil, stdin: input,
                        handle: handle)
                }
            }
        } onCancel: {
            handle.cancel()
        }
        switch result {
        case .success(let run):
            return RelayReply(stdout: run.stdout, stderr: run.stderr, status: run.status)
        case .failure(let error):
            return .failure("\(error)", code: "relay_failed")
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
