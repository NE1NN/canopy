import Foundation
import Synchronization

public enum HostState: String, Codable, Sendable {
    /// Not connected, and nothing needs the host.
    case idle
    case connecting
    /// The host's `wake` ran, and the master is retrying.
    case waking
    case connected
    /// It could not connect for five minutes, until something asks for the host again.
    case unreachable
    /// Its panes detached for idleness, so the host can power itself off.
    case detached
}

/// One host's ssh master, which every pane, git call, and probe goes through. It starts when something needs the host,
/// wakes a host that is off, and stops once nothing uses the host, so the host can idle.
public actor HostConnection {
    static let giveUpAfter = Duration.seconds(5 * 60)
    static let retryEvery = Duration.seconds(10)
    static let wakeAtMostEvery = Duration.seconds(2 * 60)
    static let readyWithin = Duration.seconds(20)
    static let checkEvery = Duration.milliseconds(200)
    /// How long a master nothing uses stays up while the host has no attached panes.
    static let unusedFor = Duration.seconds(10 * 60)

    public nonisolated let alias: String
    public nonisolated let ssh: SSHCommand
    public private(set) var entry: HostEntry
    public private(set) var state = HostState.idle
    /// ssh's message from the last failure to connect.
    public private(set) var lastError: String?
    /// Counts masters that came up, so work done once per connection knows when it is a new one.
    public private(set) var generation = 0

    private let launcher: any HostProcessLauncher
    private let clock: any HostClock
    private let activity: ActivityLog
    private var master: (any HostMasterProcess)?
    private var connecting: Task<Void, any Error>?
    private var lastWake: ContinuousClock.Instant?
    private var lastUse: ContinuousClock.Instant
    private var lastBusy: ContinuousClock.Instant
    private var observers: [UUID: AsyncStream<HostState>.Continuation] = [:]
    private var cachedHome: String?

    public init(
        alias: String, entry: HostEntry, ssh: SSHCommand, launcher: any HostProcessLauncher = SubprocessHostLauncher(),
        clock: any HostClock = SystemHostClock(), activity: ActivityLog
    ) {
        self.alias = alias
        self.entry = entry
        self.ssh = ssh
        self.launcher = launcher
        self.clock = clock
        self.activity = activity
        lastUse = clock.now
        lastBusy = clock.now
    }

    public func update(_ entry: HostEntry) {
        self.entry = entry
    }

    /// Yields the current state, then each change.
    public func states() -> AsyncStream<HostState> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostState.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        continuation.yield(state)
        return stream
    }

    /// Returns once the master is up, starting it when it is not. Callers at the same time share one attempt.
    public func connect() async throws {
        lastUse = clock.now
        // A dropped connection takes the socket at once, but its process a moment later. ssh sent through a master
        // that is not answering would connect on its own, around the master.
        if state == .connected, master?.isRunning == true {
            if await launcher.run(ssh.control("check"), timeout: .seconds(5)).status == 0 { return }
            stopMaster(becoming: .idle)
        }
        if let connecting {
            try await connecting.value
            return
        }
        let attempt = Task { try await self.establish() }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    /// Like `connect()`, but returns false once `limit` passes with the master not up yet. The attempt goes on, and the
    /// next caller joins it.
    public func connect(waitingAtMost limit: Duration) async throws -> Bool {
        let attempt = Task { try await self.connect() }
        return try await FirstOf.finished(attempt, within: limit)
    }

    /// Runs `remote` on the host through the master, connecting first.
    public func run(_ remote: [String], timeout: Duration) async throws -> SubprocessResult {
        try await connect()
        lastUse = clock.now
        return await launcher.run(ssh.exec(remote), timeout: timeout)
    }

    /// Whether the master is up and answering but refuses new sessions, as past sshd's MaxSessions. Without starting
    /// one.
    public func refusesSessions() async -> Bool {
        guard state == .connected, master?.isRunning == true,
            await launcher.run(ssh.control("check"), timeout: .seconds(5)).status == 0
        else { return false }
        return await launcher.run(ssh.exec(["true"]), timeout: .seconds(10)).status == 255
    }

    /// Runs `remote` only while the master is up, without counting as use, so watching an idle host never keeps it.
    public func probe(_ remote: [String], timeout: Duration) async -> SubprocessResult? {
        guard state == .connected, master?.isRunning == true else { return nil }
        return await launcher.run(ssh.exec(remote), timeout: timeout)
    }

    /// The host user's home folder, asked once per connection.
    public func home() async throws -> String {
        if let home = cachedHome { return home }
        let result = try await run(["sh", "-c", #"printf %s "$HOME""#], timeout: .seconds(30))
        let home = String(decoding: result.stdout, as: UTF8.self)
        guard result.status == 0, home.hasPrefix("/") else {
            let reason = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.hostUnreachable(alias, reason: reason.isEmpty ? "ssh failed." : reason)
        }
        cachedHome = home
        return home
    }

    /// What the app sees of the host's panes, every probe: how many are attached, whether any runs a program, and how
    /// long since anything was typed into one. Stops a master nothing needs, and detaches quiet panes.
    public func panesActive(attached: Int, busy: Bool, quietFor: Duration) {
        guard state == .connected else { return }
        let now = clock.now
        if busy { lastBusy = now }
        if attached == 0 {
            if now - lastUse >= Self.unusedFor { stopMaster(becoming: .idle) }
            return
        }
        lastUse = now
        let limit = Duration.seconds(entry.idleDetachMinutes * 60)
        guard entry.idleDetachMinutes > 0, !busy, quietFor >= limit, now - lastBusy >= limit else { return }
        stopMaster(becoming: .detached)
        activity.record(ActivityType.hostDetached, data: ["host": .string(alias)])
    }

    /// Detaches the host's panes and lets it go, as idleness does.
    public func detach() {
        guard state == .connected else { return }
        stopMaster(becoming: .detached)
        activity.record(ActivityType.hostDetached, data: ["host": .string(alias)])
    }

    /// Stops the master for good, as Canopy quits. Sessions on the host only detach.
    public func stop() {
        connecting?.cancel()
        stopMaster(becoming: .idle)
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func establish() async throws {
        let deadline = clock.now + Self.giveUpAfter
        set(.connecting)
        while true {
            if try await startMaster() {
                lastError = nil
                generation += 1
                lastUse = clock.now
                lastBusy = clock.now
                set(.connected)
                activity.record(ActivityType.hostConnected, data: ["host": .string(alias)])
                return
            }
            if noRetryCanFix(lastError ?? "") || clock.now >= deadline {
                set(.unreachable)
                activity.record(
                    ActivityType.hostUnreachable,
                    data: ["host": .string(alias), "reason": .string(lastError ?? "")])
                throw WorkspaceError.hostUnreachable(alias, reason: lastError ?? "ssh could not connect.")
            }
            if let wake = entry.wake, lastWake.map({ clock.now - $0 >= Self.wakeAtMostEvery }) ?? true {
                lastWake = clock.now
                set(.waking)
                activity.record(ActivityType.hostWoken, data: ["host": .string(alias)])
                _ = await launcher.runWake(wake)
            }
            try await clock.sleep(for: Self.retryEvery)
        }
    }

    /// ssh's failures that waiting and waking cannot change. A name that does not resolve is not one: the Mac may be
    /// offline for now, or the host's name may only resolve while it is awake.
    private func noRetryCanFix(_ message: String) -> Bool {
        let permanent = [
            "Permission denied", "Host key verification failed", "Bad configuration option", "Bad owner or permissions",
            "Too many authentication failures",
        ]
        return permanent.contains(where: message.contains)
    }

    /// Whether the alias is most likely a typo: ~/.ssh/config gives it no host name or proxy, and the alias does not
    /// resolve as a name.
    public func isUnknownAlias() async -> Bool {
        let config = await launcher.run(ssh.config(), timeout: .seconds(5))
        guard config.status == 0 else { return false }
        let lines = String(decoding: config.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        let hostname = lines.first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst("hostname ".count)) }
        let proxied = lines.contains { $0.hasPrefix("proxycommand ") || $0.hasPrefix("proxyjump ") }
        guard let hostname, hostname.lowercased() == alias.lowercased(), !proxied else { return false }
        return await onOwnThread {
            var found: UnsafeMutablePointer<addrinfo>?
            defer { freeaddrinfo(found) }
            return getaddrinfo(hostname, nil, nil, &found) != 0
        }
    }

    /// Starts a master and waits until ssh says it is up, or it exits. Returns whether it is up.
    private func startMaster() async throws -> Bool {
        master?.stop()
        await clearControlSocket()
        let started = launcher.startMaster(ssh.master())
        master = started
        let deadline = clock.now + Self.readyWithin
        while clock.now < deadline {
            try Task.checkCancellation()
            if await launcher.run(ssh.control("check"), timeout: .seconds(5)).status == 0 {
                watch(started)
                return true
            }
            guard started.isRunning else { break }
            try await clock.sleep(for: Self.checkEvery)
        }
        started.stop()
        let message = started.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = message.isEmpty ? "ssh did not connect within 20 seconds." : message
        return false
    }

    /// A master killed outright leaves its socket behind, and a new master finding it would run without multiplexing,
    /// so nothing could go through it. One that still answers, which nothing here owns, is asked to exit first.
    private func clearControlSocket() async {
        guard FileManager.default.fileExists(atPath: ssh.controlPath) else { return }
        if await launcher.run(ssh.control("check"), timeout: .seconds(5)).status == 0 {
            _ = await launcher.run(ssh.control("exit"), timeout: .seconds(5))
        }
        unlink(ssh.controlPath)
    }

    /// A master that ends on its own, as when the network drops, leaves the host idle for the next caller to connect.
    private func watch(_ started: any HostMasterProcess) {
        Task { [weak self] in
            await started.waitForExit()
            await self?.ended(started)
        }
    }

    private func ended(_ ended: any HostMasterProcess) {
        guard let master, master === ended, state == .connected else { return }
        self.master = nil
        set(.idle)
    }

    private func stopMaster(becoming next: HostState) {
        master?.stop()
        master = nil
        set(next)
    }

    private func set(_ next: HostState) {
        guard state != next else { return }
        state = next
        for observer in observers.values { observer.yield(next) }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }
}

/// Waits for a task without waiting for it to end, which a task group cannot do: it waits for every child.
private enum FirstOf {
    final class Reply: Sendable {
        private let continuation: Mutex<CheckedContinuation<Bool, any Error>?>

        init(_ continuation: CheckedContinuation<Bool, any Error>) {
            self.continuation = Mutex(continuation)
        }

        func send(_ result: Result<Bool, any Error>) {
            continuation.withLock { $0.take() }?.resume(with: result)
        }
    }

    /// Whether `task` finished within `limit`, with its error if it failed. A task still running is left to go on.
    static func finished(_ task: Task<Void, any Error>, within limit: Duration) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let reply = Reply(continuation)
            Task { reply.send(await task.result.map { true }) }
            Task {
                try? await Task.sleep(for: limit)
                reply.send(.success(false))
            }
        }
    }
}
