import Foundation
import Testing

@testable import CanopyCore

struct HostFilesTests {
    static let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// Writes the host's files into a fake host's home with the install command, as `host add` does.
    func install(_ host: FakeHost) throws {
        let argv = host.ssh.exec(HostFiles.installCommand(server: "canopy-test"))
        let result = try Subprocess.run(
            argv[0], Array(argv.dropFirst()), environment: host.environment, directory: nil, timeout: .seconds(30))
        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    @Test func installingWritesTheScriptTheConfigAndTheVersion() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)

        try install(host)

        let script = host.home + "/.canopy/bin/canopy-host"
        #expect(try String(contentsOfFile: script, encoding: .utf8) == HostFiles.script)
        #expect(FileManager.default.isExecutableFile(atPath: script))
        #expect(try String(contentsOfFile: host.home + "/.canopy/tmux.conf", encoding: .utf8) == HostFiles.tmuxConf)
        #expect(try String(contentsOfFile: host.home + "/.canopy/files-version", encoding: .utf8) == HostFiles.version)
    }

    /// tmux may be missing for a moment, as while the host's packages update, and the probe runs every 2 seconds.
    @Test func withoutTmuxInstallingWorksAndTheProbeFindsNoSessions() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir, path: "/usr/bin:/bin")
        try install(host)
        let argv = host.ssh.exec(HostProbe.command(server: "canopy-test"))

        let result = try Subprocess.run(
            argv[0], Array(argv.dropFirst()), environment: host.environment, directory: nil, timeout: .seconds(30))

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(try HostProbe.decode(result.stdout).isEmpty)
    }

    @Test func theScriptIsValidPython() throws {
        let dir = try TempDir()
        let file = dir.sub("canopy-host")
        try HostFiles.script.write(toFile: file, atomically: true, encoding: .utf8)

        let result = try Subprocess.run(
            "/usr/bin/python3", ["-m", "py_compile", file], environment: Fixture.environment, directory: nil,
            timeout: .seconds(30))

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    @Test(.enabled(if: tmux != nil, "needs tmux: brew install tmux"))
    func probeListsSessionsWithTheirFolderAndWhetherAProgramRuns() async throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        try install(host)
        let server = "canopy-test-\(UUID().uuidString.prefix(6))"
        let tmux = try #require(Self.tmux)
        let folder = dir.sub("work dir")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        _ = try Subprocess.run(
            // A login shell, as tmux starts one, whose name starts with a dash.
            tmux,
            [
                "-L", server, "-f", "/dev/null", "new-session", "-d", "-s", "p1", "-c", folder,
                "exec -a -bash /bin/bash",
            ],
            environment: Fixture.environment, directory: nil, timeout: .seconds(10))
        defer {
            _ = try? Subprocess.run(
                tmux, ["-L", server, "kill-server"], environment: Fixture.environment, directory: nil,
                timeout: .seconds(10))
        }
        func probe() throws -> [String: SessionActivity] {
            let argv = host.ssh.exec(HostProbe.command(server: server))
            var environment = host.environment
            environment["FAKE_SSH_PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
            // As the app runs it: git's environment says LC_ALL=C, and ssh passes LC_* on to the host.
            environment["LC_ALL"] = "C"
            let result = try Subprocess.run(
                argv[0], Array(argv.dropFirst()), environment: environment, directory: nil, timeout: .seconds(30))
            return try HostProbe.decode(result.stdout)
        }

        let idle = await eventually { (try? probe())?["p1"]?.busy == false }
        #expect(idle)
        #expect(try probe()["p1"]?.folder == folder)
        // tmux's title for a pane nothing titled is the machine's name, which says nothing.
        #expect(try probe()["p1"]?.title == "")
        #expect(try probe()["p1"]?.foreground == "bash")
        _ = try Subprocess.run(
            tmux, ["-L", server, "send-keys", "-t", "p1", "sleep 30", "Enter"], environment: Fixture.environment,
            directory: nil, timeout: .seconds(10))
        let busy = await eventually { (try? probe())?["p1"]?.busy == true }

        #expect(busy)
        #expect(try probe()["p1"]?.foreground == "sleep")
    }

    /// Security scanners can hold the first run of a new file for seconds, longer than a probe may take, and every
    /// new version of the helper is a new file. Run through python3, the helper is only read.
    @Test func theProbeReadsTheHelperInsteadOfRunningIt() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        try install(host)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: host.home + "/.canopy/bin/canopy-host")
        let argv = host.ssh.exec(HostProbe.command(server: "canopy-test-\(UUID().uuidString.prefix(6))"))

        let result = try Subprocess.run(
            argv[0], Array(argv.dropFirst()), environment: host.environment, directory: nil, timeout: .seconds(30))

        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        #expect(try HostProbe.decode(result.stdout).isEmpty)
    }

    @Test func probeOutputDecodesAndAServerWithNoSessionsHasNone() throws {
        let output = Data(
            #"{"sessions": [{"name": "p3", "pid": 41, "busy": true, "foreground": "claude", "folder": "/w", "title": "✳ Fix"}]}"#
                .utf8)

        let sessions = try HostProbe.decode(output)

        #expect(sessions == ["p3": SessionActivity(busy: true, foreground: "claude", folder: "/w", title: "✳ Fix")])
        #expect(try HostProbe.decode(Data(#"{"sessions": []}"#.utf8)).isEmpty)
    }
}
