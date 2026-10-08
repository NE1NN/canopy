import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// `canopy-host` run directly with python3, as the host's `canopy` and `xdg-open` run it, against a stand-in for the
/// app's end of the relay socket.
struct HostRelayScriptTests {
    struct Setup {
        let dir: TempDir
        let home: String

        init() throws {
            dir = try TempDir()
            home = dir.sub("home")
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try HostFiles.script.write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        }

        let homeID = "abcd1234"
        /// This home's own folder of programs on the host.
        var bin: String { home + "/.canopy/\(homeID)/bin" }
        var script: String { bin + "/canopy-host" }
        var socket: String { dir.sub("app.sock") }

        /// Only what the test gives, so a test run inside a Canopy pane passes none of that pane's variables on.
        func environment(_ variables: [String: String] = [:], path: String = "/usr/bin:/bin") -> [String: String] {
            var environment = Fixture.environment.filter { !$0.key.hasPrefix("CANOPY_") }
            environment["HOME"] = home
            environment["PATH"] = path
            return environment.merging(variables) { $1 }
        }

        func run(
            _ arguments: [String], environment: [String: String], stdin: Data? = nil, directory: String? = nil
        ) async throws -> SubprocessResult {
            let script = script
            return try await offPool {
                try Subprocess.run(
                    "/usr/bin/python3", [script] + arguments, environment: environment, directory: directory,
                    timeout: .seconds(30), stdin: stdin)
            }
        }

        func pending(homeID: String, pane: String) -> String {
            home + "/.canopy/\(homeID)/pending/\(pane).json"
        }
    }

    static let unreachable = "Canopy is not reachable from this host right now.\n"

    @Test func theRelaySendsItsArgumentsFolderCanopyVariablesInputAndAge() async throws {
        let setup = try Setup()
        let app = try RelayStub(
            path: setup.socket,
            reply: RelayReply(stdout: Data([0x6F, 0xFF, 0x0A]), stderr: Data("e\n".utf8), status: 3))
        let folder = setup.dir.sub("work")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let variables = ["CANOPY_SOCKET": setup.socket, "CANOPY_PANE": "p4", "CANOPY_ROW_PATH": "/w/x", "OTHER": "1"]

        let result = try await setup.run(
            ["relay", "row", "list", "--json"], environment: setup.environment(variables),
            stdin: Data("piped\n".utf8), directory: folder)

        #expect(result.status == 3)
        #expect(result.stdout == Data([0x6F, 0xFF, 0x0A]))
        #expect(result.stderr == Data("e\n".utf8))
        let request = try #require(app.request)
        #expect(request.version == HostFiles.version)
        #expect(request.args == ["row", "list", "--json"])
        #expect(request.cwd == folder)
        #expect(request.env == ["CANOPY_SOCKET": setup.socket, "CANOPY_PANE": "p4", "CANOPY_ROW_PATH": "/w/x"])
        #expect(request.input == Data("piped\n".utf8))
        let age = try #require(request.age)
        #expect(age >= 0)
    }

    @Test func outsideACanopyPaneTheRelaySaysSo() async throws {
        let setup = try Setup()

        let result = try await setup.run(["relay", "row", "list"], environment: setup.environment())

        #expect(result.status == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "Run canopy in a Canopy terminal on this host.\n")
        #expect(result.stdout.isEmpty)
    }

    @Test func withNoAppTheRelaySaysItIsNotReachable() async throws {
        let setup = try Setup()
        let refusing = setup.dir.sub("refusing.sock")
        try RelayStub.bindWithoutListening(refusing)

        for socket in [setup.socket, refusing] {
            let result = try await setup.run(
                ["relay", "row", "list"], environment: setup.environment(["CANOPY_SOCKET": socket]))

            #expect(result.status == 1)
            #expect(String(decoding: result.stderr, as: UTF8.self) == Self.unreachable)
        }
    }

    @Test func anAppThatHangsUpWithoutAnsweringIsNotReachable() async throws {
        let setup = try Setup()
        let app = try RelayStub(path: setup.socket, reply: nil)

        let result = try await setup.run(
            ["relay", "row", "list"], environment: setup.environment(["CANOPY_SOCKET": setup.socket]))

        #expect(result.status == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == Self.unreachable)
        #expect(app.request?.args == ["row", "list"])
    }

    @Test func aHookWithNoAppKeepsItsReportAndALaterOneReplacesIt() async throws {
        let setup = try Setup()
        let variables = ["CANOPY_SOCKET": setup.socket, "CANOPY_HOME_ID": "ab12cd34", "CANOPY_PANE": "p7"]
        let pending = setup.pending(homeID: "ab12cd34", pane: "p7")

        for input in ["first", "second"] {
            let result = try await setup.run(
                ["relay", "agent-hook", "stop"], environment: setup.environment(variables), stdin: Data(input.utf8))

            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.isEmpty)
            let saved = try JSONDecoder().decode(
                RelayRequest.self, from: Data(contentsOf: URL(fileURLWithPath: pending)))
            #expect(saved.args == ["agent-hook", "stop"])
            #expect(saved.input == Data(input.utf8))
            #expect(saved.env["CANOPY_PANE"] == "p7")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: pending)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = (pending as NSString).deletingLastPathComponent
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["p7.json"])
    }

    @Test func aHookKeepsNothingWithoutAPlainPaneAndHomeID() async throws {
        let setup = try Setup()
        let cases: [[String: String]] = [
            ["CANOPY_HOME_ID": "ab12cd34"],
            ["CANOPY_PANE": "p7"],
            ["CANOPY_HOME_ID": "ab12cd34", "CANOPY_PANE": "../p7"],
            ["CANOPY_HOME_ID": "..", "CANOPY_PANE": "p7"],
            ["CANOPY_HOME_ID": "", "CANOPY_PANE": "p7"],
        ]

        for variables in cases {
            let result = try await setup.run(
                ["relay", "agent-hook", "stop"],
                environment: setup.environment(variables.merging(["CANOPY_SOCKET": setup.socket]) { $1 }),
                stdin: Data("{}".utf8))

            #expect(result.status == 0)
            #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.home + "/.canopy") == [setup.homeID])
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.home + "/.canopy/\(setup.homeID)") == ["bin"])
    }

    /// A hook must never disturb Claude, whatever the app answers.
    @Test func aHookPrintsNothingAndSucceedsWhateverTheAppAnswers() async throws {
        let setup = try Setup()
        let app = try RelayStub(
            path: setup.socket, reply: RelayReply(stdout: Data("o".utf8), stderr: Data("e".utf8), status: 1))
        let variables = ["CANOPY_SOCKET": setup.socket, "CANOPY_HOME_ID": "ab12cd34", "CANOPY_PANE": "p7"]

        let result = try await setup.run(
            ["relay", "agent-hook", "stop"], environment: setup.environment(variables), stdin: Data("{}".utf8))

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(app.request?.args == ["agent-hook", "stop"])
        #expect(!FileManager.default.fileExists(atPath: setup.pending(homeID: "ab12cd34", pane: "p7")))
        let outside = try await setup.run(["relay", "agent-hook", "stop"], environment: setup.environment())
        #expect(outside.status == 0)
        #expect(outside.stdout.isEmpty && outside.stderr.isEmpty)
    }

    @Test func replayPrintsAKeptReportOnceAndRemovesIt() async throws {
        let setup = try Setup()
        let variables = ["CANOPY_SOCKET": setup.socket, "CANOPY_HOME_ID": "ab12cd34", "CANOPY_PANE": "p7"]
        _ = try await setup.run(
            ["relay", "agent-hook", "stop"], environment: setup.environment(variables), stdin: Data("{}".utf8))
        let replay = ["replay", "--pane", "p7", "--home-id", "ab12cd34"]
        // A report waits in its file while the app is away, and keeps the time its hook ran.
        let kept = setup.pending(homeID: "ab12cd34", pane: "p7")
        var saved =
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: kept))) as! [String: Any]
        saved["kept"] = (saved["kept"] as! Double) - 600
        try JSONSerialization.data(withJSONObject: saved).write(to: URL(fileURLWithPath: kept))

        let first = try await setup.run(replay, environment: setup.environment())
        let second = try await setup.run(replay, environment: setup.environment())

        #expect(first.status == 0)
        let lines = String(decoding: first.stdout, as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2 && lines[1].isEmpty)
        let request = try JSONDecoder().decode(RelayRequest.self, from: Data(lines[0].utf8))
        #expect(request.args == ["agent-hook", "stop"])
        #expect(request.input == Data("{}".utf8))
        #expect((request.age ?? 0) >= 600)
        #expect(!FileManager.default.fileExists(atPath: setup.pending(homeID: "ab12cd34", pane: "p7")))
        #expect(second.status == 0)
        #expect(second.stdout.isEmpty)
    }

    @Test func openSendsAnArtifactLinkToCanopy() async throws {
        let setup = try Setup()
        let app = try RelayStub(path: setup.socket, reply: RelayReply(stdout: Data(), stderr: Data(), status: 0))
        let link = "https://claude.ai/artifact/abc_12"

        let result = try await setup.run(
            ["open", link], environment: setup.environment(["CANOPY_SOCKET": setup.socket]))

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(app.request?.args == ["web", "open", link])
    }

    /// Links that are not artifacts go to the host's own xdg-open, never back to Canopy's or another home's, however
    /// it is reached.
    @Test func openHandsOtherLinksToTheNextXdgOpen() async throws {
        let setup = try Setup()
        let standIn = setup.bin + "/xdg-open"
        try HostFiles.xdgOpenLauncher(homeID: setup.homeID).write(toFile: standIn, atomically: true, encoding: .utf8)
        let shared = setup.home + "/.canopy/bin"
        let otherHome = setup.home + "/.canopy/ffff0000/bin"
        let shadow = setup.dir.sub("shadow")
        let real = setup.dir.sub("real")
        for folder in [shared, otherHome, shadow, real] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        // Programs that were already there, so nothing new runs. Reaching any of Canopy's would fail the open.
        for folder in [shared, otherHome] {
            try FileManager.default.createSymbolicLink(
                atPath: folder + "/xdg-open", withDestinationPath: "/usr/bin/false")
        }
        try FileManager.default.createSymbolicLink(atPath: shadow + "/other-home", withDestinationPath: otherHome)
        try FileManager.default.createSymbolicLink(atPath: shadow + "/xdg-open", withDestinationPath: standIn)
        try FileManager.default.createSymbolicLink(atPath: real + "/xdg-open", withDestinationPath: "/bin/echo")
        let path = [setup.bin, shared, otherHome, shadow + "/other-home", shadow, real, "/usr/bin", "/bin"]
            .joined(separator: ":")

        let other = try await setup.run(
            ["open", "https://example.com/a"], environment: setup.environment(path: path))
        let outsideAPane = try await setup.run(
            ["open", "https://claude.ai/artifact/abc"], environment: setup.environment(path: path))

        #expect(other.status == 0, "\(String(decoding: other.stderr, as: UTF8.self))")
        #expect(String(decoding: other.stdout, as: UTF8.self) == "https://example.com/a\n")
        #expect(String(decoding: outsideAPane.stdout, as: UTF8.self) == "https://claude.ai/artifact/abc\n")
    }

    @Test func withoutAnotherXdgOpenOpenFailsAsAMissingOneWould() async throws {
        let setup = try Setup()
        let path = setup.bin + ":/usr/bin:/bin"

        let result = try await setup.run(["open", "https://example.com"], environment: setup.environment(path: path))

        #expect(result.status == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "xdg-open: no handler for https://example.com\n")
    }

    /// The host decides which links open in Canopy by the same rule the app uses for ⌘-clicks.
    @Test func theArtifactRuleAgreesWithTheApps() async throws {
        let setup = try Setup()
        let module = setup.dir.sub("canopy_host.py")
        try HostFiles.script.write(toFile: module, atomically: true, encoding: .utf8)
        let links = [
            "https://claude.ai/artifact/abc123",
            "https://claude.ai/artifact/abc_DEF-9/",
            "https://www.claude.ai/artifact/x?utm=1#top",
            "HTTPS://Claude.AI/artifact/x",
            " https://claude.ai/artifact/abc ",
            "https://claude.ai/code/artifact/1b4e28ba-2fa1-11d2-883f-0016d3cca427",
            "https://claude.ai/code/artifact/1B4E28BA-2FA1-11D2-883F-0016D3CCA427/",
            "https://claude.ai/code/artifact/not-a-uuid",
            "http://claude.ai/artifact/abc",
            "https://claude.ai:443/artifact/abc",
            "https://user@claude.ai/artifact/abc",
            "https://user:pw@claude.ai/artifact/abc",
            "https://claude.ai.example.com/artifact/abc",
            "https://example.com/artifact/abc",
            "https://claude.ai/artifact/",
            "https://claude.ai/artifact/a.b",
            "https://claude.ai/artifact/%41bc",
            "https://claude.ai/artifact/abc/more",
            "https://claude.ai/artifacts/abc",
            "https://claude.ai//artifact/abc",
            "claude.ai/artifact/abc",
        ]
        let program = """
            import sys
            sys.path.insert(0, sys.argv[1])
            import canopy_host
            for link in sys.argv[2:]:
                print("yes" if canopy_host.is_artifact(link) else "no")
            """

        let result = try await offPool {
            try Subprocess.run(
                "/usr/bin/python3", ["-I", "-c", program, setup.dir.path] + links, environment: setup.environment(),
                directory: nil, timeout: .seconds(30))
        }

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        let answers = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map { $0 == "yes" }
        #expect(answers.count == links.count)
        for (link, answer) in zip(links, answers) {
            #expect(answer == (ArtifactLink(link) != nil), "\(link)")
        }
        #expect(answers.contains(true) && answers.contains(false))
    }
}

/// The app's end of a relay socket: takes one connection, keeps its request, and answers it with `reply`, or hangs up
/// without answering when that is nil.
final class RelayStub: Sendable {
    private let received = Received()
    private let path: String
    private let fd: Int32

    init(path: String, reply: RelayReply?) throws {
        self.path = path
        fd = try Self.bound(path)
        guard listen(fd, 4) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let (fd, received) = (fd, received)
        Thread {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 30_000) == 1 else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let stream = SocketStream(fd: client, deadline: .now + .seconds(30))
            var data = Data()
            while !data.contains(0x0A), let chunk = try? stream.read(), !chunk.isEmpty {
                data.append(chunk)
            }
            received.request.withLock {
                $0 = try? JSONDecoder().decode(RelayRequest.self, from: data.prefix { $0 != 0x0A })
            }
            guard let reply, let line = try? JSONEncoder().encode(reply) else { return }
            try? stream.write(line + Data("\n".utf8))
        }.start()
    }

    /// The request, once the relay has sent it. Read after the relay exits, which it does only after this answers.
    var request: RelayRequest? {
        received.request.withLock { $0 }
    }

    /// A socket file nothing listens on, as one left by an app that quit.
    static func bindWithoutListening(_ path: String) throws {
        close(try bound(path))
    }

    private static func bound(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path), "socket path too long: \(path)")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return fd
    }

    deinit {
        close(fd)
        unlink(path)
    }

    private final class Received: Sendable {
        let request = Mutex<RelayRequest?>(nil)
    }
}
