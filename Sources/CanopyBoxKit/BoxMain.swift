import CanopyAgents
import CanopyGit
import CanopyServer
import CanopySystem
import CanopyWire
import Dispatch
import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// `canopy-box`'s commands: `version`, and `serve`, which runs the daemon for one Canopy home until SIGTERM or SIGINT.
public enum BoxMain {
    static let usage =
        "usage: canopy-box version | serve --home-id <id> [--root <folder>] | status --home-id <id> [--root <folder>]"
    /// How often panes are read, the busy file is touched, and kept reports are looked for.
    static let pollEvery = Duration.seconds(2)
    static let replayEvery = Duration.seconds(30)
    static let phoneEvery = Duration.seconds(5)

    /// The phone server on the box's tailnet addresses, with the host's name and port from the Mac's settings.
    static func phoneServer(daemon: BoxDaemon, paths: BoxPaths, environment: [String: String]) -> PhoneServer {
        let config = BoxDaemon.load(BoxConfig.self, from: paths.configFile)
        let log = paths.folder + "/activity.jsonl"
        // `phone-listen`, `<address> <port>`, puts the listener on an address of a test's choosing, as the hosts e2e
        // does on loopback; the tailnet otherwise.
        let (address, port) = loopbackOverride(paths.folder + "/phone-listen")
        return PhoneServer(
            source: BoxPhoneSource(daemon: daemon),
            settings: PhoneServerSettings(
                registryFile: URL(fileURLWithPath: paths.folder + "/phones.json"),
                serverName: {
                    BoxDaemon.load(BoxConfig.self, from: paths.configFile)?.host ?? ProcessInfo.processInfo.hostName
                },
                kind: PhoneServerKind.box,
                wake: { phoneWake(paths) },
                agentCommand: {
                    PhoneAgentCommand.chosen(BoxDaemon.load(BoxConfig.self, from: paths.configFile)?.agentCommand)
                },
                version: CanopyVersion.current,
                port: port ?? config?.phonePort ?? PhonePort.standard,
                addresses: { address.map { [$0] } ?? TailnetAddresses.current() },
                tailnetName: { await TailnetAddresses.name(environment: environment) },
                closedReason: { "Tailscale is not running on this host, so phones cannot reach it." },
                statusNote: address.map { "Listening on \($0) for tests, from box/phone-listen, not on the tailnet." },
                record: { activity in appendActivity(activity, to: log) }))
    }

    /// A test's `<address> <port>` in `file`, its address loopback only, so no file can move anything off the box.
    static func loopbackOverride(_ file: String) -> (address: String?, port: UInt16?) {
        let words = (try? String(contentsOfFile: file, encoding: .utf8))?
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let address = words?.first.flatMap { TailnetAddresses.loopback([$0]).first }
        let port = words.flatMap { $0.count > 1 ? UInt16($0[1]) : nil }
        return (address, port)
    }

    /// What hello gives phones to start the box: the Mac's key and the instance it starts, or nil without either.
    static func phoneWake(_ paths: BoxPaths) -> PhoneWake? {
        guard let key = BoxDaemon.load(BoxWakeKey.self, from: paths.wakeFile),
            let instance = BoxDaemon.load(InstanceIdentity.self, from: paths.instanceFile)
        else { return nil }
        return PhoneWake(
            accessKeyID: key.accessKeyID, secretAccessKey: key.secretAccessKey, instanceID: instance.instanceID,
            region: instance.region)
    }

    static let instanceEvery = Duration.seconds(60)

    /// How big the activity log grows before it moves to `.1`, replacing the one there, so the two stay under 10 MB.
    static let activityLimit = 5 * 1024 * 1024
    /// Phones' calls are recorded at once from their connections; one at a time, an entry is never split or lost to
    /// the log moving aside.
    private static let activityWrites = Mutex(())

    /// One JSON line per phone event, with the Mac's types: `phone.paired`, `phone.removed`, and `phone.call`. A write
    /// that fails, as on a full disk, loses the entry rather than the daemon.
    static func appendActivity(_ activity: PhoneActivity, to path: String, limit: Int = activityLimit) {
        let (type, data): (String, [String: JSONValue]) =
            switch activity {
            case .paired(let phone): ("phone.paired", ["phone": .string(phone)])
            case .removed(let phone): ("phone.removed", ["phone": .string(phone)])
            case .call(let data): ("phone.call", data)
            }
        let entry: JSONValue = .object([
            "at": .number(Date().timeIntervalSince1970), "type": .string(type), "data": .object(data),
        ])
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        activityWrites.withLock { _ in write(line, to: path, limit: limit) }
    }

    private static func write(_ line: Data, to path: String, limit: Int) {
        let files = FileManager.default
        if let size = (try? files.attributesOfItem(atPath: path))?[.size] as? Int, size >= limit {
            try? files.removeItem(atPath: path + ".1")
            try? files.moveItem(atPath: path, toPath: path + ".1")
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? BoxFiles.write(line, to: path)
        }
    }

    /// Runs a command, returning its exit status. `serve` returns only when it cannot start.
    public static func run(_ arguments: [String]) async -> Int32 {
        switch arguments.first {
        case "version":
            print(CanopyVersion.current)
            return 0
        case "serve":
            return await serve(Array(arguments.dropFirst()))
        case "status":
            // Whether a daemon answers for the home: 0 when one does, 1 when none.
            guard let (homeID, root) = homeOptions(Array(arguments.dropFirst())) else {
                printError(usage)
                return 2
            }
            let paths = BoxPaths(root: Paths.canonical(root), homeID: homeID)
            guard let live = try? UnixConnection.connect(path: paths.socket) else { return 1 }
            live.close()
            return 0
        default:
            printError(usage)
            return 2
        }
    }

    /// `--home-id <id> [--root <folder>]`, or nil when they are not that.
    static func homeOptions(_ arguments: [String]) -> (homeID: String, root: String)? {
        var homeID: String?
        var root = ProcessInfo.processInfo.environment["HOME"] ?? Paths.homeDirectory
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch (flag, rest.popFirst()) {
            case ("--home-id", let value?): homeID = value
            case ("--root", let value?): root = value
            default: return nil
            }
        }
        guard let homeID, !homeID.isEmpty,
            homeID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return (homeID, root)
    }

    private static func serve(_ arguments: [String]) async -> Int32 {
        guard let (homeID, root) = homeOptions(arguments) else {
            printError(usage)
            return 2
        }
        signal(SIGPIPE, SIG_IGN)
        let paths = BoxPaths(root: Paths.canonical(root), homeID: homeID)
        // One daemon per home, held until it exits: two started at the same moment would both pass the socket check
        // below, and both load and save the home's state before one lost the socket.
        try? FileManager.default.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
        guard let lock = try? InstanceLock(path: paths.folder + "/serve.lock") else {
            printError("canopy-box already runs for this home.")
            return 1
        }
        defer { withExtendedLifetime(lock) {} }
        // The machine's name may take a DNS lookup on first use, which must not hold the daemon's actor.
        _ = await onOwnThread { BoxDaemon.machineNames }
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        let tmux = Tmux(
            server: HostLayout.tmuxServer(homeID: homeID),
            config: FileManager.default.fileExists(atPath: paths.tmuxConf) ? paths.tmuxConf : nil,
            environment: environment)
        let git = Tmux.find("git", path: environment["PATH"]) ?? "/usr/bin/git"
        let gitEnvironment = environment
        let daemon = BoxDaemon(paths: paths, tmux: tmux) {
            GitClone.local(path: $0, executable: git, environment: gitEnvironment)
        }
        // Checked before starting, which saves state, so a second serve never writes over the first one's.
        if let live = try? UnixConnection.connect(path: paths.socket) {
            live.close()
            printError("canopy-box already runs for this home, on \(paths.socket).")
            return 1
        }
        await daemon.start()
        let phones = phoneServer(daemon: daemon, paths: paths, environment: environment)
        await phones.refresh()
        let server: BoxServer
        do {
            server = try BoxServer(daemon: daemon, socketPath: paths.socket, phones: phones)
        } catch UnixSocketError.alreadyRunning(let path) {
            printError("canopy-box already runs for this home, on \(path).")
            return 1
        } catch {
            printError("canopy-box could not listen on \(paths.socket): \(error)")
            return 1
        }
        let stops = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                server.close()
                exit(0)
            }
            source.resume()
            return source
        }
        await daemon.replayPending()
        await withDiscardingTaskGroup { group in
            group.addTask {
                // The tailnet's addresses can change, as when Tailscale comes up after the daemon.
                while true {
                    try? await Task.sleep(for: phoneEvery)
                    await phones.refresh()
                    await daemon.setPhonesConnected(await phones.status().phones.contains(where: \.connected))
                }
            }
            group.addTask {
                while true {
                    await daemon.pollPanes()
                    try? await Task.sleep(for: pollEvery)
                }
            }
            group.addTask {
                while true {
                    await daemon.tickBusy()
                    try? await Task.sleep(for: BoxDaemon.busyEvery)
                }
            }
            group.addTask {
                while true {
                    try? await Task.sleep(for: replayEvery)
                    await daemon.replayPending()
                }
            }
            group.addTask {
                await daemon.learnInstance(again: true)
                while true {
                    try? await Task.sleep(for: instanceEvery)
                    await daemon.learnInstance()
                }
            }
        }
        withExtendedLifetime(stops) {}
        return 0
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
