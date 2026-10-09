import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// Which ports `ports stop` and the panel stop, and where their pids are signalled.
struct PortStopsTests {
    func local(_ number: UInt16, _ pids: pid_t...) -> RowPort {
        RowPort(port: number, processes: pids.map { ListeningPort(port: number, pid: $0, process: "p\($0)") })
    }

    func remote(_ number: UInt16, on host: String, mac: UInt16?, _ pids: pid_t...) -> RowPort {
        RowPort(
            port: number, processes: pids.map { ListeningPort(port: number, pid: $0, process: "p\($0)") },
            remote: RemotePort(host: host, local: mac, error: mac == nil ? "Port forwarding failed" : nil))
    }

    @Test func aHostsPidsGoToThatHostAndOnlyThisMacsGoToTheLocalStopper() {
        let stops = PortStops([
            local(3000, 40, 41), remote(5173, on: "box", mac: 5174, 40), remote(8080, on: "other", mac: nil, 7),
            remote(9000, on: "box", mac: 9000, 41, 42),
        ])

        #expect(
            stops.local == [
                ListeningPort(port: 3000, pid: 40, process: "p40"), .init(port: 3000, pid: 41, process: "p41"),
            ])
        #expect(
            stops.remote == [
                .init(host: "box", port: 5173, pids: [40]), .init(host: "other", port: 8080, pids: [7]),
                .init(host: "box", port: 9000, pids: [41, 42]),
            ])
    }

    @Test func aRemotePortHasNoLocalStopEvenWhenItsPidsAreThisMacsToo() {
        let stops = PortStops([remote(5173, on: "box", mac: 5173, getpid())])

        #expect(stops.local.isEmpty)
        #expect(stops.remote.map(\.pids) == [[getpid()]])
    }

    @Test func aNumberMatchesAPortBeforeAMacPort() {
        let groups = [
            PortGroup(rowPath: "/w/a", ports: [local(5174, 10)]),
            PortGroup(
                rowPath: "/r/b",
                ports: [remote(5173, on: "box", mac: 5174, 20), remote(8000, on: "box", mac: 8001, 21)]),
        ]

        #expect(PortStops.matching(5174, in: groups).map(\.port.port) == [5174])
        #expect(PortStops.matching(5173, in: groups).map(\.rowPath) == ["/r/b"])
        #expect(PortStops.matching(8001, in: groups).map(\.port.port) == [8000])
        #expect(PortStops.matching(5175, in: groups).isEmpty)
    }

    @Test func otherPortsOfAProcessAreOnlyItsOwnHosts() {
        let groups = [
            PortGroup(rowPath: "/w/a", ports: [local(3000, 10), local(3001, 10)]),
            PortGroup(
                rowPath: "/r/b",
                ports: [remote(5173, on: "box", mac: 5173, 10), remote(5174, on: "box", mac: 5175, 10)]),
            PortGroup(rowPath: "/r/c", ports: [remote(6000, on: "other", mac: 6000, 10)]),
        ]

        #expect(groups.otherPorts(of: local(3000, 10)) == [3001])
        #expect(groups.otherPorts(of: remote(5173, on: "box", mac: 5173, 10)) == [5174])
        #expect(groups.otherPorts(of: remote(6000, on: "other", mac: 6000, 10)) == [])
    }

    /// The panel's badge and the CLI's table say the same of a port.
    @Test func aPortsLabelNamesTheMacPortWhenItDiffersOrSaysItIsNotForwarded() {
        #expect(local(3000, 1).label == "3000")
        #expect(remote(5173, on: "box", mac: 5173, 1).label == "5173")
        #expect(remote(5173, on: "box", mac: 5174, 1).label == "5173 → 5174")
        #expect(remote(5173, on: "box", mac: nil, 1).label == "5173 (not forwarded)")
        let info = PortInfo(
            repo: nil, row: "r", rowPath: "/r", port: 5173, pid: 1, process: "node", host: "box", localPort: 5174)
        #expect(info.label == "5173 → 5174")
        #expect(remote(5173, on: "box", mac: nil, 1).forwardProblem == "Port forwarding failed")
        #expect(remote(5173, on: "box", mac: 5174, 1).forwardProblem == nil)
        #expect(local(3000, 1).forwardProblem == nil)
    }

    @Test func theMacReachesALocalPortAsItIsAndARemoteOneThroughItsForward() {
        #expect(local(3000, 1).macPort == 3000)
        #expect(remote(5173, on: "box", mac: 5174, 1).macPort == 5174)
        #expect(remote(5173, on: "box", mac: nil, 1).macPort == nil)
    }
}

/// Stands in for this Mac's ports: records every stop, and signals nothing.
final class RecordingLocalPorts: Sendable {
    let stops = Mutex<[[ListeningPort]]>([])
    let scanned: @Sendable () -> [ListeningPort]

    init(scan: @escaping @Sendable () -> [ListeningPort] = { PortScanner.listeningPorts() }) {
        scanned = scan
    }

    var ports: LocalPorts {
        LocalPorts(
            scan: scanned, parent: ProcessTable.parent(of:), folder: ProcessTable.folder(of:),
            stop: { [self] ports in
                stops.withLock { $0.append(ports) }
                return PortStopper.Outcome(killed: [])
            })
    }

    var calls: [[ListeningPort]] { stops.withLock { $0 } }
}

extension RemotePortForwardingTests {
    @MainActor
    func handler(_ setup: Setup, localPorts: RecordingLocalPorts) -> (WorkspaceControlHandler, RowLifecycle) {
        let rows = RowLifecycle(
            workspace: setup.remote.workspace, terminals: setup.terminals, hostMonitor: setup.monitor,
            localPorts: localPorts.ports)
        let plugins = PluginHost(
            workspace: setup.remote.workspace, terminals: setup.terminals, plugins: [], secrets: MemorySecretStore(),
            bundleID: "test", trash: FolderMovingTrash(into: setup.remote.dir.sub("trash")))
        return (WorkspaceControlHandler(rows: rows, plugins: plugins, ui: RecordingUI()), rows)
    }

    func call<T: Decodable>(
        _ handler: WorkspaceControlHandler, _ method: String, _ params: some Encodable, as: T.Type
    ) async throws -> T {
        let response = await handler.handle(ControlRequest(method: method, params: try .from(params)))
        if let error = response.error { throw error }
        return try #require(response.result).decode(T.self)
    }

    /// The command line of a pid this Mac runs, which the fake host's processes are.
    static func command(of pid: Int32) throws -> String {
        let result = try Subprocess.run(
            "/bin/ps", ["-o", "command=", "-p", "\(pid)"], environment: Fixture.environment, directory: nil,
            timeout: .seconds(10))
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(.enabled(if: RemoteSessionTests.tmux != nil, "needs tmux: brew install tmux"))
    func portsInARemoteRowListTheirHostAndMacPort() async throws {
        let setup = try await Setup()
        defer { setup.endSessions() }
        let port = FakeSSHForwardTests.freePort(count: 2)
        let localPorts = RecordingLocalPorts()
        let (handler, rows) = handler(setup, localPorts: localPorts)
        try setup.serve(port)
        #expect(await setup.forwarded(port) != nil)

        let listed = try await call(
            handler, PortMethod.list, PortsListParams(target: TargetHint(envRowPath: setup.row.path)),
            as: [PortInfo].self)

        #expect(listed.map(\.port) == [Int(port)])
        #expect(listed.first?.host == "box")
        #expect(listed.first?.localPort == Int(port) + 1)
        #expect(listed.first?.forwardError == nil)
        #expect(listed.first?.process.lowercased().hasPrefix("python") == true)
        // The forward's proxy holds the Mac port on this Mac, but works in /, so no local row claims it.
        let groups = await rows.portGroups()
        let local = groups.flatMap(\.ports).filter { $0.remote == nil }.map(\.port)
        #expect(!local.contains(port + 1))
        #expect(groups.map(\.rowPath) == [setup.row.path])
        await setup.stop()
    }

    @Test(.enabled(if: RemoteSessionTests.tmux != nil, "needs tmux: brew install tmux"))
    func stoppingARemotePortStopsItOnTheHostAndSignalsNothingHere() async throws {
        let setup = try await Setup()
        defer { setup.endSessions() }
        let port = FakeSSHForwardTests.freePort(count: 2)
        let localPorts = RecordingLocalPorts()
        let (handler, _) = handler(setup, localPorts: localPorts)
        try setup.serve(port)
        let found = try #require(await setup.forwarded(port))
        let pid = try #require(found.processes.first?.pid)
        #expect(try Self.command(of: pid).contains("http.server \(port)"))

        let stopped = try await call(
            handler, PortMethod.stop, PortsStopParams(port: Int(port), target: TargetHint(envRowPath: setup.row.path)),
            as: PortsStopResult.self)

        #expect(stopped.stopped.map(\.pid) == [pid])
        #expect(stopped.stopped.first?.host == "box")
        #expect(stopped.killed.isEmpty)
        #expect(await eventually { LocalPortChooser.isFree(port) })
        #expect(localPorts.calls.isEmpty)
        #expect(setup.monitor.remotePorts["box"]?.flatMap(\.ports).contains { $0.port == port } != true)
        await setup.stop()
    }

    /// A server that restarted since the last probe has a pid the host will not signal, so nothing is reported as
    /// stopped, and the new server goes on.
    @Test(.enabled(if: RemoteSessionTests.tmux != nil, "needs tmux: brew install tmux"))
    func stoppingAPortWhoseServerRestartedSinceTheProbeReportsNothingStopped() async throws {
        let setup = try await Setup()
        defer { setup.endSessions() }
        let port = FakeSSHForwardTests.freePort(count: 2)
        let localPorts = RecordingLocalPorts()
        let (handler, _) = handler(setup, localPorts: localPorts)
        try setup.serve(port)
        let old = try #require(await setup.forwarded(port)?.processes.first?.pid)
        try setup.keys(["C-c"])
        try setup.serve(port)
        // The fake host's processes are this Mac's, so the scan sees the new server.
        #expect(
            await eventually {
                let pids = PortScanner.listeningPorts().filter { $0.port == port }.map(\.pid)
                return !pids.isEmpty && !pids.contains(old)
            })

        let stopped = try await call(
            handler, PortMethod.stop, PortsStopParams(port: Int(port), target: TargetHint(envRowPath: setup.row.path)),
            as: PortsStopResult.self)

        #expect(stopped.stopped.isEmpty)
        #expect(stopped.killed.isEmpty)
        #expect(!LocalPortChooser.isFree(port))
        #expect(localPorts.calls.isEmpty)
        await setup.stop()
    }

    @Test(.enabled(if: RemoteSessionTests.tmux != nil, "needs tmux: brew install tmux"))
    func stoppingARemotePortByItsMacPortStopsItOnTheHost() async throws {
        let setup = try await Setup()
        defer { setup.endSessions() }
        let port = FakeSSHForwardTests.freePort(count: 2)
        let localPorts = RecordingLocalPorts()
        let (handler, rows) = handler(setup, localPorts: localPorts)
        try setup.serve(port)
        let found = try #require(await setup.forwarded(port))
        let mac = try #require(found.remote?.local)
        let pid = try #require(found.processes.first?.pid)
        #expect(try Self.command(of: pid).contains("http.server \(port)"))

        let stopped = try await call(
            handler, PortMethod.stop, PortsStopParams(port: Int(mac), target: TargetHint(envRowPath: setup.row.path)),
            as: PortsStopResult.self)

        #expect(stopped.stopped.map(\.pid) == [pid])
        #expect(stopped.stopped.first?.localPort == Int(mac))
        #expect(await eventually { LocalPortChooser.isFree(port) })
        #expect(localPorts.calls.isEmpty)
        // The panel's stop goes the same way.
        try setup.serve(port)
        #expect(await setup.forwarded(port) != nil)
        await rows.stopPorts([port], inRow: setup.row.path)
        #expect(await eventually { LocalPortChooser.isFree(port) })
        #expect(localPorts.calls.isEmpty)
        await setup.stop()
    }

    /// The master holds its forwards' sockets on this Mac, so the local scan would find them in whichever row the
    /// master's folder is. A scan stand-in reports the master on a port in the main row, beside a server there.
    @Test(.enabled(if: RemoteSessionTests.tmux != nil, "needs tmux: brew install tmux"))
    func theMastersPidIsNotInTheLocalGroups() async throws {
        let setup = try await Setup()
        defer { setup.endSessions() }
        let master = try #require(await setup.connection.masterPID)
        let server: pid_t = 999_999
        let main = setup.remote.repo
        let scan = RecordingLocalPorts(scan: {
            [
                ListeningPort(port: 40001, pid: master, process: "ssh"),
                ListeningPort(port: 40002, pid: server, process: "node"),
            ]
        })
        var ports = scan.ports
        ports.parent = { _ in nil }
        ports.folder = { _ in main }
        let rows = RowLifecycle(
            workspace: setup.remote.workspace, terminals: setup.terminals, hostMonitor: setup.monitor,
            localPorts: ports)

        let groups = await rows.portGroups()

        #expect(groups.map(\.rowPath) == [main])
        #expect(groups.flatMap(\.ports).map(\.port) == [40002])
        await setup.stop()
    }
}
