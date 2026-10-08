import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct HostRelayServerTests {
    /// A workspace with the fake host `box`, whose relayed calls run stand-in CLI scripts through /bin/sh, so no
    /// freshly written file is ever exec'd.
    struct Setup {
        let remote: RemoteRowTests.Setup
        let server: HostRelayServer

        init(relayCLI: String? = "/bin/sh", heartbeat: Duration = .seconds(15)) async throws {
            remote = try await RemoteRowTests.Setup(relayCLI: relayCLI)
            let workspace = remote.workspace
            server = HostRelayServer(
                socketPath: HostPaths.hostSocket(home: workspace.home, homeID: workspace.homeID, alias: "box"),
                host: "box", heartbeatInterval: heartbeat, handler: { await workspace.relay($0, host: $1) })
            try server.start()
        }

        var dir: TempDir { remote.dir }

        /// A stand-in CLI: a shell script the relayed call names as its first argument.
        func script(_ name: String, _ body: String) throws -> String {
            let path = dir.sub(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o755)
            return path
        }

        func request(_ args: [String], cwd: String = "/", env: [String: String] = [:], stdin: String? = nil)
            -> RelayRequest
        {
            RelayRequest(
                version: HostFiles.version, args: args, cwd: cwd, env: env,
                stdin: stdin.map { Data($0.utf8).base64EncodedString() }, age: nil)
        }

        func call(_ request: RelayRequest) async throws -> RelayReply {
            let socket = server.socketPath
            return try await offPool { try HostRelayServerTests.call(socket, request) }
        }

        func stop() async {
            server.stop()
            await remote.workspace.stop()
        }
    }

    static func connect(_ socket: String, sending request: RelayRequest) throws -> Int32 {
        let fd = try ControlClient.connect(to: socket)
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try SocketStream(fd: fd, deadline: .now + .seconds(60)).write(line)
        return fd
    }

    static func call(_ socket: String, _ request: RelayRequest) throws -> RelayReply {
        let fd = try connect(socket, sending: request)
        defer { close(fd) }
        return try reply(on: fd)
    }

    /// The reply, after the acknowledgement a request of the current version gets first, and any heartbeats.
    static func reply(on fd: Int32) throws -> RelayReply {
        var lines = try self.lines(on: fd).filter { $0 != HostRelayServer.heartbeat }
        if lines.first == HostRelayServer.acknowledgement { lines.removeFirst() }
        return try JSONDecoder().decode(RelayReply.self, from: try #require(lines.first))
    }

    /// Every line the server sends, each with its newline, until it hangs up, or until `enough` holds for the lines
    /// so far.
    static func lines(on fd: Int32, until enough: ([Data]) -> Bool = { _ in false }) throws -> [Data] {
        let stream = SocketStream(fd: fd, deadline: .now + .seconds(60))
        var received = Data()
        var lines: [Data] = []
        while !enough(lines) {
            let chunk = try stream.read()
            if chunk.isEmpty { break }
            received.append(chunk)
            while let newline = received.firstIndex(of: 0x0A) {
                lines.append(Data(received[received.startIndex...newline]))
                received = Data(received[received.index(after: newline)...])
            }
        }
        return lines
    }

    @Test func aCallRunsTheCLIInTheRowsStandInWithItsArgumentsAndInput() async throws {
        let setup = try await Setup()
        let created = try await setup.remote.workspace.createRemoteRow(
            repoPath: setup.remote.repo, host: "box", branch: "feat/x")
        let remote = try #require(created.row.remotePath)
        try FileManager.default.createDirectory(
            atPath: created.row.path + "/Sources", withIntermediateDirectories: true)
        let cli = try setup.script(
            "cli",
            #"printf '%s\n' "$@"; pwd -P; echo "$CANOPY_ROW_PATH"; echo "$CANOPY_HOST"; echo "$HOME"; cat"#)

        let reply = try await setup.call(
            setup.request(
                [cli, "row", "two words"], cwd: remote + "/Sources",
                env: ["CANOPY_ROW_PATH": remote, "CANOPY_PANE": "p1", "HOME": setup.remote.host.home],
                stdin: "piped"))

        let macHome = try #require(setup.remote.host.environment["HOME"])
        #expect(reply.status == 0)
        #expect(
            reply.output
                == [
                    "row", "two words", created.row.path + "/Sources", created.row.path, "box", macHome, "piped",
                ].joined(separator: "\n"))
        await setup.stop()
    }

    @Test func aFailingRunAnswersItsStatusAndErrors() async throws {
        let setup = try await Setup()
        let cli = try setup.script("cli", "echo oops >&2; exit 7")

        let reply = try await setup.call(setup.request([cli]))

        #expect(reply.status == 7)
        #expect(reply.errors == "oops\n")
        await setup.stop()
    }

    @Test func aRelayOfAnotherVersionIsToldToRunAgainAndTheHostGetsTheseFiles() async throws {
        let setup = try await Setup()
        try await setup.remote.workspace.connection(for: "box").connect()
        let own = setup.remote.host.home + "/.canopy/\(setup.remote.workspace.homeID)"
        let versionFile = own + "/files-version"
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        try Data("0.0.1+old\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        var request = setup.request(["row", "list"])
        request.version = "0.0.1+old"

        let reply = try await setup.call(request)

        #expect(reply.status == 1)
        #expect(reply.code == "relay_outdated")
        #expect(reply.errors == "Canopy updated its files on box; run it again.\n")
        #expect(
            await eventually {
                (try? String(contentsOfFile: versionFile, encoding: .utf8))?.trimmingCharacters(in: .newlines)
                    == HostFiles.version
            })
        await setup.stop()
    }

    /// sshd on the host accepts connections while the Mac sleeps, so the relay needs to hear that the app has a request.
    @Test func aRequestOfTheCurrentVersionIsAcknowledgedBeforeItsReplyAndOneOfAnotherVersionIsNot() async throws {
        let setup = try await Setup()
        let started = setup.dir.sub("started")
        let release = setup.dir.sub("release")
        let cli = try setup.script(
            "cli",
            #"touch "$1"; i=0; while [ ! -e "$2" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done; echo ran"#)
        let socket = setup.server.socketPath
        let running = setup.request([cli, started, release])
        let outdated = RelayRequest(
            version: "0.0.1+old", args: ["row", "list"], cwd: "/", env: [:], stdin: nil, age: nil)

        let fd = try await offPool { try Self.connect(socket, sending: running) }
        defer { close(fd) }
        // Acknowledged while the call is still running.
        let acknowledgement = try await offPool {
            try SocketStream(fd: fd, deadline: .now + .seconds(60)).read()
        }
        #expect(acknowledgement == HostRelayServer.acknowledgement)
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        FileManager.default.createFile(atPath: release, contents: nil)
        let current = try await offPool { try Self.lines(on: fd) }
        let other = try await offPool {
            let fd = try Self.connect(socket, sending: outdated)
            defer { close(fd) }
            return try Self.lines(on: fd)
        }

        #expect(current.count == 1)
        #expect(try JSONDecoder().decode(RelayReply.self, from: current[0]).output == "ran\n")
        #expect(other.count == 1)
        #expect(try JSONDecoder().decode(RelayReply.self, from: other[0]).code == "relay_outdated")
        #expect(setup.server.acknowledges(running))
        #expect(!setup.server.acknowledges(outdated))
        await setup.stop()
    }

    /// While a call runs the relay hears from the app, so it can tell a long call from a Mac that went away.
    @Test func aRunningCallSendsHeartbeatsUntilItsReply() async throws {
        let setup = try await Setup(heartbeat: .milliseconds(50))
        let release = setup.dir.sub("release")
        let cli = try setup.script(
            "cli", #"i=0; while [ ! -e "$1" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done; echo ran"#)
        let socket = setup.server.socketPath
        let request = setup.request([cli, release])
        let heartbeat = HostRelayServer.heartbeat

        let fd = try await offPool { try Self.connect(socket, sending: request) }
        defer { close(fd) }
        let first = try await offPool { try Self.lines(on: fd) { $0.filter { $0 == heartbeat }.count >= 2 } }
        FileManager.default.createFile(atPath: release, contents: nil)
        let rest = try await offPool { try Self.lines(on: fd) }
        let lines = first + rest

        #expect(lines.first == HostRelayServer.acknowledgement)
        let between = lines.dropFirst().dropLast()
        #expect(between.count >= 2 && between.allSatisfy { $0 == heartbeat })
        #expect(try JSONDecoder().decode(RelayReply.self, from: try #require(lines.last)).output == "ran\n")
        await setup.stop()
    }

    @Test func withoutACLIToRunTheCallFails() async throws {
        let setup = try await Setup(relayCLI: nil)

        let reply = try await setup.call(setup.request(["row", "list"]))

        #expect(reply.status == 1)
        #expect(reply.code == "relay_unavailable")
        #expect(reply.errors.contains("canopy"))
        await setup.stop()
    }

    @Test func aRequestThatIsNotJSONIsAnswered() async throws {
        let setup = try await Setup()
        let socket = setup.server.socketPath

        let reply = try await offPool {
            let fd = try ControlClient.connect(to: socket)
            defer { close(fd) }
            try SocketStream(fd: fd, deadline: .now + .seconds(60)).write(Data("not json\n".utf8))
            return try Self.reply(on: fd)
        }

        #expect(reply.status == 1)
        #expect(reply.code == "bad_request")
        await setup.stop()
    }

    @Test func aRelayThatHangsUpStopsItsRunAndEverythingItStarted() async throws {
        let setup = try await Setup()
        let started = setup.dir.sub("started")
        let cli = try setup.script("cli", #"sleep 120 & echo $$ > "$1.new" && mv "$1.new" "$1"; wait"#)
        let socket = setup.server.socketPath
        let request = setup.request([cli, started])

        let fd = try await offPool { try Self.connect(socket, sending: request) }
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        let text = try String(contentsOfFile: started, encoding: .utf8)
        let group = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(-group, 0) == 0)
        close(fd)

        #expect(await eventually { kill(-group, 0) == -1 && errno == ESRCH })
        await setup.stop()
    }

    /// Claude's hook hangs up 4 seconds after it starts, but once the app acknowledged its report the report is the
    /// app's, so the run goes on. Another command whose relay hangs up stops.
    @Test func anAcknowledgedHookRunsOnAfterItsRelayHangsUpAndAnotherCallStops() async throws {
        let dir = try TempDir()
        let calls = Calls()
        let server = HostRelayServer(socketPath: dir.sub("hosts/box.sock"), host: "box", handler: calls.handle)
        try server.start()
        let socket = server.socketPath
        let requests = [["agent-hook", "stop"], ["row", "list"]].map {
            RelayRequest(version: HostFiles.version, args: $0, cwd: "/", env: [:], stdin: nil, age: nil)
        }

        let connected = try await offPool {
            try requests.map { request in
                let fd = try Self.connect(socket, sending: request)
                return (fd, try SocketStream(fd: fd, deadline: .now + .seconds(60)).read())
            }
        }
        let fds = connected.map(\.0)
        #expect(connected.allSatisfy { $0.1 == HostRelayServer.acknowledgement })
        #expect(await eventually { calls.started == ["agent-hook", "row"] })
        for fd in fds { close(fd) }

        #expect(await eventually { calls.ended["row"] == .cancelled })
        calls.release()
        #expect(await eventually { calls.ended["agent-hook"] == .finished })
        server.stop()
    }

    /// A call the server cancels as it stops did not finish, so its relay hears nothing and says Canopy is not
    /// reachable, rather than printing what a killed CLI printed.
    @Test func stoppingTheServerAnswersNothingToTheCallsItCancels() async throws {
        let dir = try TempDir()
        let calls = Calls()
        let server = HostRelayServer(socketPath: dir.sub("hosts/box.sock"), host: "box", handler: calls.handle)
        try server.start()
        let socket = server.socketPath
        let request = RelayRequest(
            version: HostFiles.version, args: ["term", "wait", "p1"], cwd: "/", env: [:], stdin: nil, age: nil)

        let fd = try await offPool { try Self.connect(socket, sending: request) }
        defer { close(fd) }
        #expect(await eventually { calls.started == ["term"] })
        server.stop()
        let lines = try await offPool { try Self.lines(on: fd) }

        #expect(calls.ended["term"] == .cancelled)
        #expect(lines == [HostRelayServer.acknowledgement])
    }

    @Test func twoCallsAtOnceBothAnswer() async throws {
        let setup = try await Setup()
        // Each waits for the other to have started, so calls served one at a time would each print "alone".
        let cli = try setup.script(
            "cli",
            #"""
            touch "$1"
            i=0
            while [ ! -e "$2" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
            if [ -e "$2" ]; then echo together; else echo alone; fi
            """#)
        let first = setup.dir.sub("first")
        let second = setup.dir.sub("second")

        async let one = setup.call(setup.request([cli, first, second]))
        async let two = setup.call(setup.request([cli, second, first]))
        let replies = try await [one, two]

        #expect(replies.map(\.output) == ["together\n", "together\n"])
        await setup.stop()
    }

    @Test func theSocketIsItsUsersAloneAndAStaleFileDoesNotBlockIt() async throws {
        let dir = try TempDir()
        let path = dir.sub("hosts/box.sock")
        try FileManager.default.createDirectory(atPath: dir.sub("hosts"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        let server = HostRelayServer(socketPath: path, host: "box") { _, host in .failure("from \(host)") }

        try server.start()

        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        let request = RelayRequest(version: "x", args: [], cwd: "/", env: [:], stdin: nil, age: nil)
        let reply = try await offPool { try Self.call(path, request) }
        #expect(reply.errors == "from box\n")
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aFolderAnotherUserCouldReachIsMadePrivate() throws {
        let dir = try TempDir()
        let folder = dir.sub("hosts")
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let server = HostRelayServer(socketPath: folder + "/box.sock", host: "box") { _, _ in .failure("x") }

        try server.start()

        var info = stat()
        #expect(lstat(folder, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        server.stop()
    }

    @Test func aPathTooLongForASocketIsRefused() throws {
        let server = HostRelayServer(socketPath: "/tmp/" + String(repeating: "x", count: 120), host: "box") { _, _ in
            .failure("x")
        }

        #expect(throws: HostRelayServerError.self) { try server.start() }
    }
}

/// A handler that runs until it is released or cancelled, and records which.
final class Calls: Sendable {
    enum End: Equatable { case finished, cancelled }

    private struct State {
        var started: Set<String> = []
        var ended: [String: End] = [:]
        var released = false
    }

    private let state = Mutex(State())

    var started: Set<String> { state.withLock { $0.started } }
    var ended: [String: End] { state.withLock { $0.ended } }

    func release() {
        state.withLock { $0.released = true }
    }

    var handle: HostRelayServer.Handler {
        { [self] request, _ in
            let name = request.args.first ?? ""
            state.withLock { _ = $0.started.insert(name) }
            while !state.withLock({ $0.released }) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let end: End = Task.isCancelled ? .cancelled : .finished
            state.withLock { $0.ended[name] = end }
            return .failure("ended")
        }
    }
}

extension RelayReply {
    var output: String { String(decoding: Data(base64Encoded: stdout) ?? Data(), as: UTF8.self) }
    var errors: String { String(decoding: Data(base64Encoded: stderr) ?? Data(), as: UTF8.self) }
}
