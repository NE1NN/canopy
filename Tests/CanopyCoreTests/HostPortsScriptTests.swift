import Foundation
import Testing

@testable import CanopyCore

/// `canopy-host probe --ports` and `stop-port` on the fake host, with `scripts/fake-ss` playing iproute2's `ss`.
struct HostPortsScriptTests {
    static let fakeSS = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/fake-ss").path

    struct Setup {
        let dir: TempDir
        let host: FakeHost
        let homeID = "test-\(UUID().uuidString.prefix(6))"
        /// The lines the stand-in `ss` prints.
        let lines: String
        let path: String

        /// Without `ss`, the host's PATH has none, as this Mac has none.
        init(ss: Bool = true) throws {
            dir = try TempDir()
            let bin = dir.sub("ss-bin")
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            // A link to a file that has run before, since this Mac's security scanner can hold a new file's first run.
            try FileManager.default.createSymbolicLink(
                atPath: bin + "/ss", withDestinationPath: HostPortsScriptTests.fakeSS)
            path = (ss ? bin + ":" : "") + "/opt/homebrew/bin:/usr/bin:/bin"
            host = try FakeHost(in: dir, path: path)
            lines = dir.sub("ss-lines")
            try HostFilesTests().install(host, homeID: homeID)
        }

        var environment: [String: String] {
            host.environment.merging(["FAKE_SS_LINES": lines]) { $1 }
        }

        func write(_ lines: [String]) throws {
            try (lines.joined(separator: "\n") + "\n").write(toFile: self.lines, atomically: true, encoding: .utf8)
        }

        /// The probe as the app runs it, through ssh.
        func probe(ports: Bool = true) async throws -> SubprocessResult {
            let argv = host.ssh.exec(HostProbe.command(homeID: homeID, ports: ports))
            let environment = environment
            return try await offPool {
                try Subprocess.run(
                    argv[0], Array(argv.dropFirst()), environment: environment, directory: nil, timeout: .seconds(30))
            }
        }

        /// The fake host reads folders with `lsof`, which a loaded machine can keep past the helper's wait for it, and
        /// a folder the helper could not read is left out.
        func probeUntilFoldersAreRead() async throws -> [RemoteListeningPort] {
            var ports: [RemoteListeningPort] = []
            _ = await eventually {
                guard let result = try? await probe(), result.status == 0,
                    let report = try? HostProbe.decode(result.stdout)
                else { return false }
                ports = report.ports ?? []
                return !ports.isEmpty && ports.allSatisfy { $0.processes.allSatisfy { $0.folder != nil } }
            }
            return ports
        }

        /// `canopy-host` with some of its constants set first, such as a short wait.
        func run(
            _ arguments: [String], setting constants: [String: String] = [:], environment extra: [String: String] = [:]
        ) async throws -> SubprocessResult {
            let module = dir.sub("canopy_host.py")
            try HostFiles.script.write(toFile: module, atomically: true, encoding: .utf8)
            let assignments = constants.sorted { $0.key < $1.key }.map { "canopy_host.\($0.key) = \($0.value)" }
            let program =
                (["import sys", "sys.path.insert(0, sys.argv[1])", "import canopy_host"] + assignments + [
                    "sys.exit(canopy_host.main(sys.argv[2:]))"
                ]).joined(separator: "\n")
            var environment = environment.merging(extra) { $1 }
            environment["HOME"] = host.home
            environment["PATH"] = path
            let directory = dir.path
            let variables = environment
            return try await offPool {
                try Subprocess.run(
                    "/usr/bin/python3", ["-I", "-c", program, directory] + arguments, environment: variables,
                    directory: nil, timeout: .seconds(30))
            }
        }

        func stop(port: UInt16, pids: [pid_t], wait: Double? = nil) async throws -> SubprocessResult {
            try await run(
                ["stop-port", "--port", "\(port)", "--pid"] + pids.map { "\($0)" },
                setting: wait.map { ["STOP_WAIT": "\($0)"] } ?? [:])
        }
    }

    /// A process of the test's own that sleeps in a folder, for `ss` lines to name.
    static func sleeper(in folder: String) throws -> Process {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @Test func theProbeListsListeningPortsWithTheirAddressProcessesAncestorsAndFolders() async throws {
        let setup = try Setup()
        let server = try Self.sleeper(in: setup.dir.sub("work/app"))
        defer { server.terminate() }
        let helper = try Self.sleeper(in: setup.dir.sub("work/helper"))
        defer { helper.terminate() }
        let a = server.processIdentifier
        let b = helper.processIdentifier
        let random = PortScanner.randomPortRange()
        let ephemeral = random.lowerBound + 10
        // As `ss -ltnpH` prints them on Ubuntu 24.04.
        try setup.write([
            #"LISTEN 0 5 127.0.0.1:18431 0.0.0.0:* users:(("python3",pid=\#(a),fd=3))"#,
            #"LISTEN 0 5 [::1]:18432 [::]:* users:(("python3",pid=\#(a),fd=4))"#,
            #"LISTEN 0 511 *:5173 *:* users:(("node",pid=\#(a),fd=20),("node",pid=\#(b),fd=20),("node",pid=\#(a),fd=21))"#,
            #"LISTEN 0 4096 [::]:8080 [::]:* users:(("python3",pid=\#(b),fd=6))"#,
            #"LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("python3",pid=\#(b),fd=5))"#,
            #"LISTEN 0 511 [fe80::1]%eth0:3000 [::]:* users:(("node",pid=\#(b),fd=7))"#,
            #"LISTEN 0 511 [::1]:3000 [::]:* users:(("node",pid=\#(b),fd=8))"#,
            #"LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("resolved",pid=\#(a),fd=9))"#,
            #"LISTEN 0 128 [::]:22 [::]:*"#,
            #"LISTEN 0 4096 127.0.0.54:9000 0.0.0.0:*"#,
            #"LISTEN 0 5 127.0.0.1:\#(ephemeral) 0.0.0.0:* users:(("node",pid=\#(a),fd=10))"#,
        ])

        let ports = try await setup.probeUntilFoldersAreRead()

        #expect(ports.map(\.port) == [53, 3000, 5173, 8080, 18431, 18432])
        let byPort = Dictionary(uniqueKeysWithValues: ports.map { ($0.port, $0) })
        #expect(byPort[18431]?.address == "127.0.0.1")
        #expect(byPort[18432]?.address == "::1")
        #expect(byPort[5173]?.address == "0.0.0.0")
        #expect(byPort[8080]?.address == "0.0.0.0")
        #expect(byPort[3000]?.address == "::1")
        #expect(byPort[53]?.address == "127.0.0.53")
        #expect(byPort[5173]?.processes.map(\.pid) == [a, b])
        #expect(byPort[5173]?.processes.map(\.name) == ["node", "node"])
        #expect(byPort[8080]?.processes.map(\.pid) == [b])
        let python = try #require(byPort[18431]?.processes.first)
        #expect(python.name == "python3")
        #expect(python.ancestors.first == getpid())
        #expect(python.ancestors.last == 1)
        #expect(python.folder.map(Self.real) == Self.real(setup.dir.sub("work/app")))
        #expect(byPort[5173]?.processes.last?.folder.map(Self.real) == Self.real(setup.dir.sub("work/helper")))
    }

    /// Linux names its range in /proc, which this Mac lacks, so the test points the helper at a file of its own.
    @Test func portsInTheHostsEphemeralRangeAreLeftOut() async throws {
        let setup = try Setup()
        let server = try Self.sleeper(in: setup.dir.sub("work"))
        defer { server.terminate() }
        let pid = server.processIdentifier
        let range = setup.dir.sub("ip_local_port_range")
        try "32768\t60999\n".write(toFile: range, atomically: true, encoding: .utf8)
        try setup.write(
            [32767, 32768, 40000, 60999, 61000].map {
                #"LISTEN 0 5 127.0.0.1:\#($0) 0.0.0.0:* users:(("node",pid=\#(pid),fd=3))"#
            })

        let result = try await setup.run(
            ["probe", "--server", "none-\(setup.homeID)", "--home-id", setup.homeID, "--ports"],
            setting: ["PORT_RANGE_FILE": "'\(range)'"])

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(try HostProbe.decode(result.stdout).ports?.map(\.port) == [32767, 61000])
    }

    /// The probe runs every 2 seconds, and a host whose `ss` is missing still shows its sessions.
    @Test func withoutSSThereAreNoPorts() async throws {
        let setup = try Setup(ss: false)

        let result = try await setup.probe()

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        let output = try #require(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        #expect((output["ports"] as? [Any])?.isEmpty == true)
        #expect(try HostProbe.decode(result.stdout) == HostProbe.Report(sessions: [:], pending: [], ports: []))
        let withoutPorts = try await setup.probe(ports: false)
        let unasked = try #require(try JSONSerialization.jsonObject(with: withoutPorts.stdout) as? [String: Any])
        #expect(unasked["ports"] == nil)
    }

    /// A busy host's `ss` can fail or take too long, which says nothing about its ports, so the app keeps what it had.
    @Test func whenSSFailsOrTakesTooLongThePortsAreUnknown() async throws {
        let failing = try Setup()
        let slow = try Setup()
        try slow.write([])
        let arguments = { (setup: Setup) in
            ["probe", "--server", "none-\(setup.homeID)", "--home-id", setup.homeID, "--ports"]
        }

        let failed = try await failing.run(arguments(failing))
        let late = try await slow.run(
            arguments(slow), setting: ["TOOL_WAIT": "0.3"], environment: ["FAKE_SS_SLEEP": "5"])

        for result in [failed, late] {
            #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
            let output = try #require(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
            #expect(output.keys.contains("ports"))
            #expect(output["ports"] is NSNull)
            #expect(try HostProbe.decode(result.stdout).ports == nil)
        }
    }

    @Test(.enabled(if: HostFilesTests.tmux != nil, "needs tmux: brew install tmux"))
    func aProcessStartedInASessionListsItsShellAmongItsAncestors() async throws {
        let setup = try Setup()
        let server = HostPaths.tmuxServer(homeID: setup.homeID)
        let tmux = try #require(HostFilesTests.tmux)
        let folder = setup.dir.sub("work")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        _ = try Subprocess.run(
            tmux, ["-L", server, "-f", "/dev/null", "new-session", "-d", "-s", "p1", "-c", folder, "/bin/sh"],
            environment: Fixture.environment, directory: nil, timeout: .seconds(10))
        defer {
            _ = try? Subprocess.run(
                tmux, ["-L", server, "kill-server"], environment: Fixture.environment, directory: nil,
                timeout: .seconds(10))
        }
        try setup.write([])
        var shell: Int32?
        _ = await eventually {
            shell = (try? HostProbe.decode(try await setup.probe().stdout))?.shells["p1"]
            return shell != nil
        }
        let shellPID = try #require(shell)
        _ = try Subprocess.run(
            tmux, ["-L", server, "send-keys", "-t", "p1", "/bin/sleep 4242", "Enter"],
            environment: Fixture.environment, directory: nil, timeout: .seconds(10))
        var child: Int32?
        _ = await eventually {
            child = try? await offPool { try Self.child(of: shellPID, running: "sleep 4242") }
            return child != nil
        }
        let pid = try #require(child)
        try setup.write([#"LISTEN 0 5 127.0.0.1:18431 0.0.0.0:* users:(("sleep",pid=\#(pid),fd=3))"#])

        let ports = try await setup.probeUntilFoldersAreRead()

        let process = try #require(ports.first?.processes.first)
        #expect(process.pid == pid)
        #expect(process.ancestors.first == shellPID)
        #expect(process.folder.map(Self.real) == Self.real(folder))
    }

    static func child(of parent: Int32, running command: String) throws -> Int32? {
        let listed = try Subprocess.run(
            "/bin/ps", ["-A", "-o", "pid=,ppid=,command="], environment: Fixture.environment, directory: nil,
            timeout: .seconds(10))
        for line in String(decoding: listed.stdout, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if fields.count == 3, Int32(fields[1]) == parent, fields[2].hasSuffix(command) {
                return Int32(fields[0])
            }
        }
        return nil
    }

    @Test func stopPortStopsAListenerAndLeavesAPidNotOnThePortAlone() async throws {
        let setup = try Setup()
        let listener = try await ListeningChild.start()
        defer { listener.process.terminate() }
        let other = try await ListeningChild.start()
        defer { other.process.terminate() }
        try setup.write([
            #"LISTEN 0 5 127.0.0.1:\#(listener.port.port) 0.0.0.0:* users:(("perl",pid=\#(listener.port.pid),fd=3))"#,
            #"LISTEN 0 5 127.0.0.1:\#(other.port.port) 0.0.0.0:* users:(("perl",pid=\#(other.port.pid),fd=3))"#,
        ])

        let result = try await setup.stop(port: listener.port.port, pids: [listener.port.pid, other.port.pid])

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(
            String(decoding: result.stdout, as: UTF8.self)
                == #"{"stopped": [\#(listener.port.pid)], "killed": []}"# + "\n")
        #expect(await eventually { !listener.process.isRunning })
        #expect(listener.process.terminationReason == .uncaughtSignal)
        #expect(listener.process.terminationStatus == SIGTERM)
        try await Task.sleep(for: .milliseconds(200))
        #expect(other.process.isRunning)
    }

    @Test func stopPortKillsAListenerThatIgnoresSIGTERM() async throws {
        let setup = try Setup()
        let listener = try await ListeningChild.start(onSIGTERM: .ignore)
        defer { listener.process.terminate() }
        let pid = listener.port.pid
        try setup.write([#"LISTEN 0 5 127.0.0.1:\#(listener.port.port) 0.0.0.0:* users:(("perl",pid=\#(pid),fd=3))"#])

        let result = try await setup.stop(port: listener.port.port, pids: [pid], wait: 0.3)

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(
            String(decoding: result.stdout, as: UTF8.self) == #"{"stopped": [\#(pid)], "killed": [\#(pid)]}"# + "\n")
        #expect(await eventually { !listener.process.isRunning })
        #expect(listener.process.terminationStatus == SIGKILL)
    }

    /// Without `ss` the helper cannot tell who listens, so it signals nobody and says so.
    @Test func stopPortWithoutSSSignalsNothingAndFails() async throws {
        let setup = try Setup(ss: false)
        let listener = try await ListeningChild.start()
        defer { listener.process.terminate() }

        let result = try await setup.stop(port: listener.port.port, pids: [listener.port.pid])

        #expect(result.status == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("ss"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(listener.process.isRunning)
    }

    @Test func theHelperTakesPortsOnlyAfterTheProbesArgumentsAndStopPortOnlyNumbers() async throws {
        let setup = try Setup()
        let wrong = [
            ["probe", "--ports", "--server", "s", "--home-id", setup.homeID],
            ["probe", "--server", "s", "--home-id", setup.homeID, "--ports", "--ports"],
            ["probe", "--server", "s", "--home-id", setup.homeID, "--all"],
            ["stop-port", "--port", "5173"],
            ["stop-port", "--port", "5173", "--pid"],
            ["stop-port", "--port", "x", "--pid", "12"],
            ["stop-port", "--port", "70000", "--pid", "12"],
            ["stop-port", "--port", "5173", "--pid", "12", "-9"],
            ["stop-port", "--pid", "12", "--port", "5173"],
        ]

        for arguments in wrong {
            let result = try await setup.run(arguments)

            #expect(result.status == 2, "\(arguments)")
            #expect(String(decoding: result.stderr, as: UTF8.self).hasPrefix("usage: canopy-host"), "\(arguments)")
        }
    }

    @Test func probeOutputWithPortsAndShellsDecodes() throws {
        let output = Data(
            #"""
            {"sessions": [{"name": "p3", "pid": 41, "busy": false, "foreground": "bash", "folder": "/w", "title": ""}],
             "pending": [],
             "ports": [{"port": 5173, "address": "::1", "processes": [
                {"pid": 812, "name": "node", "ancestors": [800, 41, 1], "folder": "/w/web"},
                {"pid": 813, "name": "node", "ancestors": [812, 800, 41, 1], "folder": null}]}]}
            """#.utf8)

        let report = try HostProbe.decode(output)

        #expect(report.shells == ["p3": 41])
        #expect(
            report.ports == [
                RemoteListeningPort(
                    port: 5173, address: "::1",
                    processes: [
                        RemoteProcess(pid: 812, name: "node", ancestors: [800, 41, 1], folder: "/w/web"),
                        RemoteProcess(pid: 813, name: "node", ancestors: [812, 800, 41, 1], folder: nil),
                    ])
            ])
        #expect(HostProbe.command(homeID: "h1").contains { $0.contains("--ports") } == false)
        #expect(HostProbe.command(homeID: "h1", ports: true)[2].hasSuffix(#"--home-id "$0" --ports"#))
    }
}
