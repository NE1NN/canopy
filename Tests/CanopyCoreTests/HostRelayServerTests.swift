import Foundation
import Testing

@testable import CanopyCore

struct HostRelayServerTests {
    /// A workspace with the fake host `box`, whose relayed calls run stand-in CLI scripts through /bin/sh, so no
    /// freshly written file is ever exec'd.
    struct Setup {
        let remote: RemoteRowTests.Setup
        let server: HostRelayServer

        init(relayCLI: String? = "/bin/sh") async throws {
            remote = try await RemoteRowTests.Setup(relayCLI: relayCLI)
            let workspace = remote.workspace
            server = HostRelayServer(
                socketPath: HostPaths.hostSocket(home: workspace.home, homeID: workspace.homeID, alias: "box"),
                host: "box", handler: { await workspace.relay($0, host: $1) })
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

    static func reply(on fd: Int32) throws -> RelayReply {
        let stream = SocketStream(fd: fd, deadline: .now + .seconds(60))
        var received = Data()
        while !received.contains(0x0A) {
            let chunk = try stream.read()
            if chunk.isEmpty { break }
            received.append(chunk)
        }
        return try JSONDecoder().decode(RelayReply.self, from: Data(received.prefix { $0 != 0x0A }))
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
        let versionFile = setup.remote.host.home + "/.canopy/files-version"
        try FileManager.default.createDirectory(
            atPath: setup.remote.host.home + "/.canopy", withIntermediateDirectories: true)
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

extension RelayReply {
    var output: String { String(decoding: Data(base64Encoded: stdout) ?? Data(), as: UTF8.self) }
    var errors: String { String(decoding: Data(base64Encoded: stderr) ?? Data(), as: UTF8.self) }
}
