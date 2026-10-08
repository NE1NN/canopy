import Foundation
import Testing

@testable import CanopyCore

struct HostFilesTests {
    static let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// Writes a home's files into a fake host's home with the install command, as `host add` does.
    func install(_ host: FakeHost, homeID: String = "test") throws {
        let argv = host.ssh.exec(HostFiles.installCommand(homeID: homeID))
        let result = try Subprocess.run(
            argv[0], Array(argv.dropFirst()), environment: host.environment, directory: nil, timeout: .seconds(30))
        #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    func installedVersion(_ host: FakeHost, homeID: String) throws -> String {
        let argv = host.ssh.exec(HostFiles.versionCommand(homeID: homeID))
        let result = try Subprocess.run(
            argv[0], Array(argv.dropFirst()), environment: host.environment, directory: nil, timeout: .seconds(30))
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// The shared `canopy`, read by sh rather than run, since a new file's first run can wait on this Mac's security
    /// scanner.
    func runShared(_ host: FakeHost, homeID: String?, _ arguments: [String]) throws -> SubprocessResult {
        let assignment = homeID.map { ["env", "CANOPY_HOME_ID=\($0)"] } ?? ["env", "-u", "CANOPY_HOME_ID"]
        let argv = host.ssh.exec(assignment + ["sh", ".local/bin/canopy"] + arguments)
        return try Subprocess.run(
            argv[0], Array(argv.dropFirst()), environment: host.environment, directory: nil, timeout: .seconds(30))
    }

    @Test func installingWritesTheScriptTheConfigAndTheVersionInTheHomesOwnFolder() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)

        try install(host)

        let own = host.home + "/.canopy/test/"
        let script = own + "bin/canopy-host"
        #expect(try String(contentsOfFile: script, encoding: .utf8) == HostFiles.script)
        #expect(FileManager.default.isExecutableFile(atPath: script))
        #expect(try String(contentsOfFile: own + "tmux.conf", encoding: .utf8) == HostFiles.tmuxConf)
        #expect(try String(contentsOfFile: own + "files-version", encoding: .utf8) == HostFiles.version)
        #expect(try installedVersion(host, homeID: "test") == HostFiles.version)
        #expect(try installedVersion(host, homeID: "other") == "")
    }

    @Test func installingWritesCanopyAndXdgOpenAndLinksCanopyWhereLoginShellsLook() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)

        try install(host)
        try install(host)

        let bin = host.home + "/.canopy/test/bin/"
        #expect(try String(contentsOfFile: bin + "canopy", encoding: .utf8) == HostFiles.canopyLauncher(homeID: "test"))
        #expect(
            try String(contentsOfFile: bin + "xdg-open", encoding: .utf8) == HostFiles.xdgOpenLauncher(homeID: "test"))
        #expect(HostFiles.canopyLauncher(homeID: "test").contains(#""$HOME/.canopy/test/bin/canopy-host" relay"#))
        #expect(HostFiles.xdgOpenLauncher(homeID: "test").contains(#""$HOME/.canopy/test/bin/canopy-host" open"#))
        #expect(FileManager.default.isExecutableFile(atPath: bin + "canopy"))
        #expect(FileManager.default.isExecutableFile(atPath: bin + "xdg-open"))
        let shared = host.home + "/.canopy/bin/canopy"
        #expect(try String(contentsOfFile: shared, encoding: .utf8) == HostFiles.sharedCanopy)
        #expect(FileManager.default.isExecutableFile(atPath: shared))
        let link = host.home + "/.local/bin/canopy"
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == shared)
        let result = try runShared(host, homeID: nil, ["row", "list"])
        #expect(result.status == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "Run canopy in a Canopy terminal on this host.\n")
    }

    /// The release app and a dev build on one host, each with its own version, as when the author tests a build.
    @Test func twoHomesOnOneHostKeepTheirOwnFilesAndVersions() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        try install(host, homeID: "aaaa1111")
        let other = host.home + "/.canopy/aaaa1111/"
        try Data("0.0.1+old\n".utf8).write(to: URL(fileURLWithPath: other + "files-version"))
        try Data("old helper\n".utf8).write(to: URL(fileURLWithPath: other + "bin/canopy-host"))

        try install(host, homeID: "bbbb2222")

        #expect(try installedVersion(host, homeID: "aaaa1111") == "0.0.1+old\n")
        #expect(try String(contentsOfFile: other + "bin/canopy-host", encoding: .utf8) == "old helper\n")
        #expect(try installedVersion(host, homeID: "bbbb2222") == HostFiles.version)
        let own = host.home + "/.canopy/bbbb2222/"
        #expect(try String(contentsOfFile: own + "bin/canopy-host", encoding: .utf8) == HostFiles.script)

        try install(host, homeID: "aaaa1111")

        #expect(try installedVersion(host, homeID: "aaaa1111") == HostFiles.version)
        #expect(try installedVersion(host, homeID: "bbbb2222") == HostFiles.version)
        #expect(
            try String(contentsOfFile: own + "bin/canopy", encoding: .utf8)
                == HostFiles.canopyLauncher(homeID: "bbbb2222"))
    }

    /// Login shells, and pane shells whose startup files put other folders first, reach the pane's own home.
    @Test func theSharedCanopyRunsTheCanopyOfThePanesHome() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        try install(host, homeID: "aaaa1111")
        let launcher = host.home + "/.canopy/aaaa1111/bin/canopy"
        try FileManager.default.removeItem(atPath: launcher)
        // A program that was already there, so nothing new runs.
        try FileManager.default.createSymbolicLink(atPath: launcher, withDestinationPath: "/bin/echo")

        let inAPane = try runShared(host, homeID: "aaaa1111", ["row", "list"])
        let outsideAPane = try runShared(host, homeID: nil, ["row", "list"])
        let unknownHome = try runShared(host, homeID: "cccc3333", ["row", "list"])
        let emptyHome = try runShared(host, homeID: "", ["row", "list"])

        #expect(inAPane.status == 0, "\(String(decoding: inAPane.stderr, as: UTF8.self))")
        #expect(String(decoding: inAPane.stdout, as: UTF8.self) == "row list\n")
        for result in [outsideAPane, unknownHome, emptyHome] {
            #expect(result.status == 1)
            #expect(String(decoding: result.stderr, as: UTF8.self) == "Run canopy in a Canopy terminal on this host.\n")
        }
    }

    /// Every home and every build writes the same shared `canopy`, so none of them replaces it with something else, and
    /// it never makes a home install again.
    @Test func theSharedCanopyIsTheSameForEveryHomeAndVersionAndIsWrittenOnlyWhenItDiffers() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        let shared = host.home + "/.canopy/bin/canopy"

        try install(host, homeID: "aaaa1111")
        let first = try FileManager.default.attributesOfItem(atPath: shared)[.systemFileNumber] as? Int
        try install(host, homeID: "bbbb2222")
        let second = try FileManager.default.attributesOfItem(atPath: shared)[.systemFileNumber] as? Int

        #expect(first != nil && first == second)
        #expect(try String(contentsOfFile: shared, encoding: .utf8) == HostFiles.sharedCanopy)
        for text in ["aaaa1111", "bbbb2222", HostFiles.version, CanopyVersion.current, "@CANOPY"] {
            #expect(!HostFiles.sharedCanopy.contains(text), "\(text)")
        }
        try Data("#!/bin/sh\nexec python3 \"$HOME/.canopy/bin/canopy-host\" relay \"$@\"\n".utf8)
            .write(to: URL(fileURLWithPath: shared))
        try install(host, homeID: "aaaa1111")
        #expect(try String(contentsOfFile: shared, encoding: .utf8) == HostFiles.sharedCanopy)
    }

    @Test func installingLeavesAnotherCanopyOnThePathAlone() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir)
        let bin = host.home + "/.local/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "mine".write(toFile: bin + "/canopy", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: bin + "/elsewhere", withDestinationPath: "/nowhere")

        try install(host)

        #expect(try String(contentsOfFile: bin + "/canopy", encoding: .utf8) == "mine")
        try FileManager.default.removeItem(atPath: bin + "/canopy")
        try FileManager.default.moveItem(atPath: bin + "/elsewhere", toPath: bin + "/canopy")
        try install(host)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/canopy") == "/nowhere")
    }

    /// tmux may be missing for a moment, as while the host's packages update, and the probe runs every 2 seconds.
    @Test func withoutTmuxInstallingWorksAndTheProbeFindsNoSessions() throws {
        let dir = try TempDir()
        let host = try FakeHost(in: dir, path: "/usr/bin:/bin")
        try install(host)
        let argv = host.ssh.exec(HostProbe.command(homeID: "test"))

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
        let homeID = "test-\(UUID().uuidString.prefix(6))"
        try install(host, homeID: homeID)
        let server = HostPaths.tmuxServer(homeID: homeID)
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
            let argv = host.ssh.exec(HostProbe.command(homeID: homeID))
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
        let homeID = "test-\(UUID().uuidString.prefix(6))"
        try install(host, homeID: homeID)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: host.home + "/.canopy/\(homeID)/bin/canopy-host")
        let argv = host.ssh.exec(HostProbe.command(homeID: homeID))

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
