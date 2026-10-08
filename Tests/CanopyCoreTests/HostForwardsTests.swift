import Foundation
import Testing

@testable import CanopyCore

/// Forwards through a stand-in ssh that records each command, on a Mac where every port is free.
struct HostForwardsTests {
    struct Host {
        let launcher = FakeHostLauncher()
        let connection: HostConnection

        init(_ alias: String, in dir: TempDir) {
            connection = HostConnection(
                alias: alias, entry: HostEntry(repos: [:]),
                ssh: SSHCommand(executable: "/usr/bin/ssh", controlPath: dir.sub("cm-\(alias)"), alias: alias),
                launcher: launcher, clock: TestHostClock(),
                activity: ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity-\(alias)"))),
                isPortFree: { _ in true })
        }
    }

    static func port(_ number: UInt16, on address: String = "127.0.0.1") -> RemoteListeningPort {
        RemoteListeningPort(port: number, address: address, processes: [])
    }

    @Test func twoHostsWantingTheSameMacPortGetTwoPorts() async throws {
        let dir = try TempDir()
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        let first = Host("box", in: dir)
        let second = Host("other", in: dir)
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

    @Test func aFailedForwardMovesToTheNextPortAndKeepsSshsMessageOnceItGivesUp() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        host.launcher.refuse([5173])

        let moved = await host.connection.forwardPorts([Self.port(5173)], taken: [])

        #expect(moved == [5173: PortForward(local: 5174, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173", "5174:127.0.0.1:5173"])

        host.launcher.refuseEveryPort(true)
        let refused = await host.connection.forwardPorts([Self.port(8080)], taken: [])

        #expect(refused[8080] == PortForward(local: nil, error: FakeHostLauncher.refusal))
        #expect(refused[5173] == nil)
        let tries = host.launcher.localForwards("forward").dropFirst(2)
        #expect(tries.count == HostForwards.tries)
        #expect(tries.first == "8080:127.0.0.1:8080")
        #expect(tries.last == "8099:127.0.0.1:8080")
        // The next round tries again.
        host.launcher.refuseEveryPort(false)
        let later = await host.connection.forwardPorts([Self.port(8080)], taken: [])
        #expect(later == [8080: PortForward(local: 8080, error: nil)])
    }

    @Test func theChooserSkipsPortsTakenOrBusyAndGivesUpPastTheTop() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()

        let forwards = await host.connection.forwardPorts([Self.port(65534), Self.port(65535)], taken: [65535])

        #expect(forwards[65534] == PortForward(local: 65534, error: nil))
        #expect(forwards[65535]?.local == nil)
        #expect(forwards[65535]?.error?.contains("65535") == true)
    }

    @Test func aForwardIsMadeOnceAndCancelledWhenItsPortGoes() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()

        _ = await host.connection.forwardPorts([Self.port(5173), Self.port(3000, on: "::1")], taken: [])
        _ = await host.connection.forwardPorts([Self.port(5173), Self.port(3000, on: "::1")], taken: [])
        let left = await host.connection.forwardPorts([Self.port(3000, on: "::1")], taken: [])

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
        _ = await host.connection.forwardPorts([Self.port(3000, on: "::1")], taken: [])

        let moved = await host.connection.forwardPorts([Self.port(3000, on: "0.0.0.0")], taken: [])

        #expect(moved == [3000: PortForward(local: 3000, error: nil)])
        #expect(host.launcher.localForwards("cancel") == ["3000:[::1]:3000"])
        #expect(host.launcher.localForwards("forward") == ["3000:[::1]:3000", "3000:127.0.0.1:3000"])
    }

    @Test func aStoppedMasterForgetsItsForwardsAndTheNextMasterMakesThemAgain() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()
        _ = await host.connection.forwardPorts([Self.port(5173)], taken: [])

        await host.connection.detach()

        #expect(await host.connection.forwardedPorts.isEmpty)
        #expect(await host.connection.forwardPorts([Self.port(5173)], taken: []).isEmpty)
        try await host.connection.connect()
        let again = await host.connection.forwardPorts([Self.port(5173)], taken: [])
        #expect(again == [5173: PortForward(local: 5173, error: nil)])
        #expect(host.launcher.localForwards("forward") == ["5173:127.0.0.1:5173", "5173:127.0.0.1:5173"])
        #expect(host.launcher.localForwards("cancel").isEmpty)
    }

    @Test func roundsAtTheSameTimeNeverMakeTwoForwardsForOnePort() async throws {
        let dir = try TempDir()
        let host = Host("box", in: dir)
        try await host.connection.connect()

        async let first = host.connection.forwardPorts([Self.port(5173)], taken: [])
        async let second = host.connection.forwardPorts([Self.port(5173)], taken: [])
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
