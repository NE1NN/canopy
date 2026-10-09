import Foundation
import Testing

@testable import CanopyCore

/// Forwards through a stand-in ssh that records each command, on a Mac where every port is free.
struct HostForwardsTests {
    struct Host {
        let launcher = FakeHostLauncher()
        let connection: HostConnection

        init(_ alias: String, in dir: TempDir, macPorts: MacPortReservations = MacPortReservations()) {
            connection = HostConnection(
                alias: alias, entry: HostEntry(repos: [:]),
                ssh: SSHCommand(executable: "/usr/bin/ssh", controlPath: dir.sub("cm-\(alias)"), alias: alias),
                launcher: launcher, clock: TestHostClock(),
                activity: ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity-\(alias)"))),
                isPortFree: { _ in true }, macPorts: macPorts)
        }
    }

    static func port(_ number: UInt16, on address: String = "127.0.0.1") -> RemoteListeningPort {
        RemoteListeningPort(port: number, address: address, processes: [])
    }

    @Test func twoHostsWantingTheSameMacPortGetTwoPorts() async throws {
        let dir = try TempDir()
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        let first = Host("box", in: dir, macPorts: workspace.macPorts)
        let second = Host("other", in: dir, macPorts: workspace.macPorts)
        try await first.connection.connect()
        try await second.connection.connect()

        let a = await workspace.forwardPorts([Self.port(5173)], on: first.connection)
        let b = await workspace.forwardPorts([Self.port(5173)], on: second.connection)

        #expect(a == [5173: PortForward(local: 5173, error: nil)])
        #expect(b == [5173: PortForward(local: 5174, error: nil)])
        #expect(first.launcher.localForwards("forward") == ["5173:127.0.0.1:5173"])
        #expect(second.launcher.localForwards("forward") == ["5174:127.0.0.1:5173"])
        #expect(await first.connection.forwardedPorts == [5173])
        #expect(await second.connection.forwardedPorts == [5174])
    }

    /// Hosts forward at the same time, so a slow host holds up no other's forwards, and the Mac port a host is still
    /// forwarding stays its own.
    @Test @MainActor func aSlowHostHoldsUpNoOtherHostsForwards() async throws {
        let hosts = try await HostMonitorRoundTests.Hosts(["slow", "quick"])
        let port = FakeSSHForwardTests.freePort(count: 2)
        let slow = try await hosts.workspace.connection(for: "slow")
        let quick = try await hosts.workspace.connection(for: "quick")
        hosts["slow"].holdForwards = true
        let first = Task { await hosts.workspace.forwardPorts([Self.port(port)], on: slow) }
        #expect(await eventually { hosts["slow"].heldForwardCount() == 1 })

        let second = Task { await hosts.workspace.forwardPorts([Self.port(port)], on: quick) }

        #expect(await eventually { !hosts["quick"].localForwards("forward").isEmpty })
        hosts["slow"].releaseForwards()
        #expect(await second.value == [port: PortForward(local: port + 1, error: nil)])
        #expect(await first.value == [port: PortForward(local: port, error: nil)])
        await hosts.stop()
    }

    /// Removing a host wins over a round of its forwards under way, which keeps nothing of the host afterwards.
    @Test @MainActor func aHostRemovedDuringARoundOfItsForwardsLeavesNothingBehind() async throws {
        let hosts = try await HostMonitorRoundTests.Hosts(["box", "other"])
        let port = FakeSSHForwardTests.freePort(count: 2)
        var box: HostConnection? = try await hosts.workspace.connection(for: "box")
        weak let removed = box
        hosts["box"].holdForwards = true
        var round: Task<[UInt16: PortForward]?, Never>? = Task { [box] in
            await hosts.workspace.forwardPorts([Self.port(port)], on: box!)
        }
        #expect(await eventually { hosts["box"].heldForwardCount() == 1 })

        try await hosts.workspace.removeHost(alias: "box")
        hosts["box"].releaseForwards()

        #expect(await round?.value == nil)
        // As the monitor's round for the host can still be on its way.
        #expect(await hosts.workspace.forwardPorts([Self.port(port)], on: box!) == nil)
        round = nil
        box = nil
        #expect(removed == nil)
        let other = try await hosts.workspace.connection(for: "other")
        #expect(
            await hosts.workspace.forwardPorts([Self.port(port)], on: other) == [port: .init(local: port, error: nil)])
        await hosts.stop()
    }

    @Test func aFailedForwardMovesToTheNextPortAndKeepsSshsMessageOnceItGivesUp() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        host.launcher.refuse([5173])

        let moved = await host.connection.forwardPorts([Self.port(5173)])

        #expect(moved == [5173: PortForward(local: 5174, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173", "5174:127.0.0.1:5173"])

        host.launcher.refuseEveryPort(true)
        let refused = await host.connection.forwardPorts([Self.port(8080)])

        #expect(refused?[8080] == PortForward(local: nil, error: FakeHostLauncher.refusal))
        #expect(refused?[5173] == nil)
        let tries = host.launcher.localForwards("forward").dropFirst(2)
        #expect(tries.count == HostForwards.tries)
        #expect(tries.first == "8080:127.0.0.1:8080")
        #expect(tries.last == "8099:127.0.0.1:8080")
        // The next round tries again.
        host.launcher.refuseEveryPort(false)
        let later = await host.connection.forwardPorts([Self.port(8080)])
        #expect(later == [8080: PortForward(local: 8080, error: nil)])
    }

    @Test func theChooserSkipsPortsTakenOrBusyAndGivesUpPastTheTop() async throws {
        let dir = try TempDir()
        let macPorts = MacPortReservations()
        let host = Host("box", in: dir, macPorts: macPorts)
        let other = Host("other", in: dir, macPorts: macPorts)
        try await host.connection.connect()
        try await other.connection.connect()
        _ = await other.connection.forwardPorts([Self.port(65535)])

        let forwards = await host.connection.forwardPorts([Self.port(65534), Self.port(65535)])

        #expect(forwards?[65534] == PortForward(local: 65534, error: nil))
        #expect(forwards?[65535]?.local == nil)
        #expect(forwards?[65535]?.error?.contains("65535") == true)
    }

    @Test func aForwardIsMadeOnceAndCancelledWhenItsPortGoes() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()

        _ = await host.connection.forwardPorts([Self.port(5173), Self.port(3000, on: "::1")])
        _ = await host.connection.forwardPorts([Self.port(5173), Self.port(3000, on: "::1")])
        let left = await host.connection.forwardPorts([Self.port(3000, on: "::1")])

        #expect(left == [3000: PortForward(local: 3000, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["3000:[::1]:3000", "5173:127.0.0.1:5173"])
        #expect(host.launcher.localForwards("cancel") == ["5173:127.0.0.1:5173"])
        #expect(await host.connection.forwardedPorts == [3000])
    }

    /// A server that moves from `::1` to every address is reached through `127.0.0.1` now, on the Mac port it had.
    @Test func aPortWhoseAddressChangesKeepsItsMacPort() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(3000, on: "::1")])

        let moved = await host.connection.forwardPorts([Self.port(3000, on: "0.0.0.0")])

        #expect(moved == [3000: PortForward(local: 3000, error: nil)])
        #expect(host.launcher.localForwards("cancel") == ["3000:[::1]:3000"])
        #expect(host.launcher.localForwards("forward") == ["3000:[::1]:3000", "3000:127.0.0.1:3000"])
    }

    /// A forward moving to its server's new address keeps its Mac port throughout, so another host forwarding
    /// meanwhile cannot take it and leave a browser tab on it reaching that host's server.
    @Test func aMovingForwardKeepsItsMacPortFromOtherHosts() async throws {
        let dir = try TempDir()
        let macPorts = MacPortReservations()
        let host = Host("box", in: dir, macPorts: macPorts)
        let other = Host("other", in: dir, macPorts: macPorts)
        try await host.connection.connect()
        try await other.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(3000, on: "::1")])
        host.launcher.holdForwards = true
        // The new port's forward comes first, between the moved one's cancel and its forward again.
        let moving = Task { await host.connection.forwardPorts([Self.port(2000), Self.port(3000, on: "0.0.0.0")]) }
        #expect(await eventually { host.launcher.heldForwardCount() == 1 })

        let taking = await other.connection.forwardPorts([Self.port(3000)])
        host.launcher.releaseForwards()

        #expect(taking == [3000: PortForward(local: 3001, error: nil)])
        #expect(await moving.value?[3000] == PortForward(local: 3000, error: nil))
    }

    /// A moved forward that ends up on another Mac port gives its old one back.
    @Test func aMovedForwardOnAnotherPortGivesItsOldOneBack() async throws {
        let dir = try TempDir()
        let macPorts = MacPortReservations()
        let host = Host("box", in: dir, macPorts: macPorts)
        try await host.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(3000, on: "::1")])
        host.launcher.refuse([3000])

        let moved = await host.connection.forwardPorts([Self.port(3000, on: "0.0.0.0")])

        #expect(moved == [3000: PortForward(local: 3001, error: nil)])
        #expect(macPorts.held == [3001])
    }

    /// A forward whose cancel failed may still run in the master, so it is kept and cancelled again next round.
    @Test func aForwardWhoseCancelFailsIsKeptAndCancelledNextRound() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(5173)])
        host.launcher.failCancels = true

        _ = await host.connection.forwardPorts([])

        #expect(await host.connection.forwardedPorts == [5173])
        host.launcher.failCancels = false
        _ = await host.connection.forwardPorts([])
        #expect(host.launcher.localForwards("cancel") == ["5173:127.0.0.1:5173", "5173:127.0.0.1:5173"])
        #expect(await host.connection.forwardedPorts.isEmpty)
    }

    /// A server that moved address while the old forward could not be cancelled keeps that forward, rather than
    /// getting a second one on the next Mac port beside it.
    @Test func aChangedTargetWhoseCancelFailsGetsNoSecondForward() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(3000, on: "::1")])
        host.launcher.failCancels = true

        let kept = await host.connection.forwardPorts([Self.port(3000, on: "0.0.0.0")])

        #expect(kept == [3000: PortForward(local: 3000, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["3000:[::1]:3000"])
        host.launcher.failCancels = false
        let moved = await host.connection.forwardPorts([Self.port(3000, on: "0.0.0.0")])
        #expect(moved == [3000: PortForward(local: 3000, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["3000:[::1]:3000", "3000:127.0.0.1:3000"])
        #expect(await host.connection.forwardedPorts == [3000])
    }

    /// ssh that timed out may still have made the forward, so it is cancelled before the next Mac port is tried.
    @Test func aForwardThatTimesOutIsCancelledBeforeTheNextPort() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        host.launcher.timeOut([5173])

        let moved = await host.connection.forwardPorts([Self.port(5173)])

        #expect(moved == [5173: PortForward(local: 5174, error: nil)])
        let order = host.launcher.commands.compactMap { argv -> String? in
            guard let at = argv.firstIndex(of: "-O"), argv.indices.contains(at + 1), argv[at + 1] != "check",
                let spec = argv.firstIndex(of: "-L").map({ argv[$0 + 1] })
            else { return nil }
            return argv[at + 1] + " " + spec
        }
        #expect(order == ["forward 5173:127.0.0.1:5173", "cancel 5173:127.0.0.1:5173", "forward 5174:127.0.0.1:5173"])
        #expect(await host.connection.forwardedPorts == [5174])
    }

    /// When even that cancel fails, the Mac port stays out of use and is cancelled again on the next round.
    @Test func aForwardThatTimesOutAndCannotBeCancelledIsCancelledNextRound() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        host.launcher.timeOut([5173])
        host.launcher.failCancels = true

        let unsure = await host.connection.forwardPorts([Self.port(5173)])

        #expect(unsure?[5173]?.local == nil)
        #expect(unsure?[5173]?.error != nil)
        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173"])
        #expect(await host.connection.forwardedPorts == [5173])
        host.launcher.failCancels = false
        host.launcher.timeOut([])
        let later = await host.connection.forwardPorts([Self.port(5173)])
        #expect(later == [5173: PortForward(local: 5173, error: nil)])
        #expect(host.launcher.localForwards("cancel") == ["5173:127.0.0.1:5173", "5173:127.0.0.1:5173"])
    }

    /// A wedged master times out every forward and fails every cancel. The port is not tried again until its unsure
    /// forward is cancelled, so it holds one Mac port rather than one more each round.
    @Test func aWedgedMasterHoldsOneMacPortAPort() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        host.launcher.timeOut(Set(5173...5190))
        host.launcher.failCancels = true

        for _ in 0..<3 {
            let round = await host.connection.forwardPorts([Self.port(5173)])
            #expect(round?[5173]?.local == nil)
            #expect(round?[5173]?.error == "ssh did not answer while forwarding port 5173.")
        }

        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173"])
        #expect(await host.connection.forwardedPorts == [5173])
        host.launcher.failCancels = false
        host.launcher.timeOut([])
        #expect(await host.connection.forwardPorts([Self.port(5173)]) == [5173: PortForward(local: 5173, error: nil)])
    }

    @Test func aStoppedMasterForgetsItsForwardsAndTheNextMasterMakesThemAgain() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(5173)])

        await host.connection.detach()

        #expect(await host.connection.forwardedPorts.isEmpty)
        #expect(await host.connection.forwardPorts([Self.port(5173)]) == nil)
        try await host.connection.connect()
        let again = await host.connection.forwardPorts([Self.port(5173)])
        #expect(again == [5173: PortForward(local: 5173, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173", "5173:127.0.0.1:5173"])
        #expect(host.launcher.localForwards("cancel").isEmpty)
    }

    @Test func roundsAtTheSameTimeNeverMakeTwoForwardsForOnePort() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()

        async let first = host.connection.forwardPorts([Self.port(5173)])
        async let second = host.connection.forwardPorts([Self.port(5173)])
        let (a, b) = await (first, second)

        #expect(a == b)
        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173"])
    }

    @Test func checksOutputGivesTheMastersPid() {
        #expect(HostConnection.masterPID(in: Data("Master running (pid=41234)\r\n".utf8)) == 41234)
        #expect(HostConnection.masterPID(in: Data("Control socket connect(x): No such file".utf8)) == nil)
    }
}

/// `scripts/fake-ssh`'s local forwards, which must behave as ssh's for the forwarding tests to mean anything.
struct FakeSSHForwardTests {
    struct Setup {
        let dir: TempDir
        let host: FakeHost
        let connection: HostConnection

        init() async throws {
            dir = try TempDir()
            let host = try FakeHost(in: dir)
            self.host = host
            connection = HostConnection(
                alias: "box", entry: HostEntry(repos: [:]), ssh: host.ssh,
                launcher: SubprocessHostLauncher(environment: { host.environment }),
                activity: ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity"))))
            try await connection.connect()
        }

        func ssh(_ argv: [String]) async throws -> SubprocessResult {
            let environment = host.environment
            return try await offPool {
                try Subprocess.run(
                    argv[0], Array(argv.dropFirst()), environment: environment, directory: nil,
                    timeout: .seconds(30))
            }
        }

        func forward(_ local: UInt16, to port: UInt16) async throws -> SubprocessResult {
            try await ssh(host.ssh.forwardLocal(local: local, target: "127.0.0.1", port: port))
        }
    }

    /// A port below this Mac's random range that nothing holds on either loopback.
    static func freePort(count: UInt16 = 1) -> UInt16 {
        while true {
            let first = UInt16.random(in: 20000..<40000)
            if (first..<first + count).allSatisfy(LocalPortChooser.isFree) { return first }
        }
    }

    /// A Python process of the test's own listening on `address` at `port`.
    static func listener(_ address: String, _ port: UInt16) async throws -> Process {
        let family = address.contains(":") ? "AF_INET6" : "AF_INET"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import socket, time; s = socket.socket(socket.\(family)); s.bind(('\(address)', \(port))); s.listen();"
                + " time.sleep(120)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = await eventually { !LocalPortChooser.isFree(port) || !process.isRunning }
        return process
    }

    @Test func aForwardAnswersOnBothLoopbacksAndAgainIsNoChange() async throws {
        let setup = try await Setup()
        let port = Self.freePort(count: 2)
        let server = try await Self.listener("127.0.0.1", port)
        defer { server.terminate() }

        let made = try await setup.forward(port + 1, to: port)
        let again = try await setup.forward(port + 1, to: port)

        #expect(made.status == 0, "\(String(decoding: made.stderr, as: UTF8.self))")
        #expect(again.status == 0)
        #expect(!LocalPortChooser.isFree(port + 1))
        await setup.connection.stop()
    }

    @Test func aForwardFailsOnlyWhenBothLoopbacksAreTaken() async throws {
        let setup = try await Setup()
        let port = Self.freePort()
        let v4 = try await Self.listener("127.0.0.1", port)
        defer { v4.terminate() }

        let oneTaken = try await setup.forward(port, to: 9)
        _ = try await setup.ssh(setup.host.ssh.cancelLocal(local: port, target: "127.0.0.1", port: 9))
        let v6 = try await Self.listener("::1", port)
        defer { v6.terminate() }
        let bothTaken = try await setup.forward(port, to: 9)

        #expect(oneTaken.status == 0)
        #expect(bothTaken.status == 255)
        #expect(String(decoding: bothTaken.stderr, as: UTF8.self).contains("Port forwarding failed"))
        await setup.connection.stop()
    }

    @Test func cancellingFreesThePortAndCancellingAgainSaysItIsNotForwarded() async throws {
        let setup = try await Setup()
        let port = Self.freePort()
        let cancel = setup.host.ssh.cancelLocal(local: port, target: "127.0.0.1", port: 9)
        #expect(try await setup.forward(port, to: 9).status == 0)

        let cancelled = try await setup.ssh(cancel)
        let again = try await setup.ssh(cancel)

        #expect(cancelled.status == 0)
        #expect(LocalPortChooser.isFree(port))
        #expect(again.status == 0)
        #expect(String(decoding: again.stderr, as: UTF8.self).contains("port not forwarded"))
        await setup.connection.stop()
    }

    /// Each connection through a forward is closed once either end is done, so a forward a browser uses for hours
    /// does not run out of descriptors.
    @Test func aForwardClosesItsConnectionsOnceTheyAreDone() async throws {
        let setup = try await Setup()
        let port = Self.freePort(count: 2)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = URL(fileURLWithPath: setup.dir.path)
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        #expect(await eventually { !LocalPortChooser.isFree(port) })
        #expect(try await setup.forward(port + 1, to: port).status == 0)
        let record = try String(contentsOfFile: setup.host.ssh.controlPath + ".L/\(port + 1)", encoding: .utf8)
        let proxy = try #require(record.split(separator: "\t").first.flatMap { Int32($0) })

        for _ in 0..<10 {
            #expect(try await RemotePortForwardingTests.get(port + 1) == "200")
        }

        // Its two listeners, and nothing of the connections.
        #expect(
            await eventually { (try? Self.sockets(of: proxy)) == 2 }, "\((try? Self.sockets(of: proxy)) ?? -1) sockets")
        await setup.connection.stop()
    }

    /// How many TCP sockets a process of the test's own holds.
    static func sockets(of pid: Int32) throws -> Int {
        let listed = try Subprocess.run(
            "/usr/sbin/lsof", ["-w", "-a", "-p", "\(pid)", "-iTCP", "-F", "f"], environment: Fixture.environment,
            directory: nil, timeout: .seconds(10))
        return String(decoding: listed.stdout, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("f") }.count
    }

    /// The app stops a master by killing it, which runs none of its clean-up.
    @Test func aMasterKilledOutrightTakesItsForwards() async throws {
        let setup = try await Setup()
        let port = Self.freePort()
        #expect(try await setup.forward(port, to: 9).status == 0)
        let pid = try #require(await setup.connection.masterPID)
        let recorded = try String(contentsOfFile: setup.host.ssh.controlPath, encoding: .utf8)
        #expect(recorded.trimmingCharacters(in: .whitespacesAndNewlines) == "\(pid)")

        await setup.connection.stop()

        #expect(await setup.connection.masterPID == nil)
        #expect(await eventually { LocalPortChooser.isFree(port) })
    }
}
