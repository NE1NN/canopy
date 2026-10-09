import Foundation
import Testing

@testable import CanopyCore

struct HostChecksTests {
    @Test func factsReadFromTheHostsOutput() {
        let facts = HostChecks.parse(
            "os=Linux\nhome=/home/ubuntu\ngit=/usr/bin/git\ntmux=tmux 3.4\npython3=/usr/bin/python3\nuid=1000\n")

        #expect(
            facts == HostFacts(os: "Linux", home: "/home/ubuntu", git: true, tmux: "tmux 3.4", python3: true, uid: 1000)
        )
        #expect(HostChecks.problems(facts).isEmpty)
    }

    @Test func aHostThatAllowsFewSessionsPerConnectionIsWarnedAbout() {
        let facts = HostChecks.parse("os=Linux\nhome=/h\ngit=/g\ntmux=tmux 3.4\npython3=/p\nuid=1\nmaxsessions=\n")

        #expect(facts.maxSessions == 10)
        #expect(HostChecks.warnings(facts, alias: "box").first?.contains("MaxSessions 100") == true)
        #expect(HostChecks.parse("maxsessions=64\n").maxSessions == 64)
        #expect(HostChecks.warnings(HostChecks.parse("maxsessions=64\n"), alias: "box").isEmpty)
        // Some systems let only root read sshd's config.
        #expect(HostChecks.parse("maxsessions=unknown\n").maxSessions == nil)
        #expect(HostChecks.warnings(HostChecks.parse("maxsessions=unknown\n"), alias: "box").isEmpty)
    }

    @Test func eachMissingToolIsNamed() {
        let facts = HostFacts(os: "Darwin", home: "/Users/x", git: false, tmux: "tmux 2.9a", python3: false, uid: 501)

        #expect(
            HostChecks.problems(facts) == [
                "Linux (it runs Darwin)", "git", "tmux 3.0 or later (it has tmux 2.9a)", "python3",
            ])
        #expect(
            HostChecks.problems(HostFacts(os: "Linux", home: "/h", git: true, tmux: "", python3: true, uid: 1)) == [
                "tmux 3.0 or later"
            ])
    }

    @Test func tmuxVersionsCompareByTheirNumbers() {
        #expect(HostChecks.isRecentTmux("tmux 3.0"))
        #expect(HostChecks.isRecentTmux("tmux 3.7c"))
        #expect(HostChecks.isRecentTmux("tmux next-3.5"))
        #expect(HostChecks.isRecentTmux("tmux 10.1"))
        #expect(!HostChecks.isRecentTmux("tmux 2.9a"))
        #expect(!HostChecks.isRecentTmux("tmux master"))
    }

    @Test func aTildePathIsUnderTheHostsHome() {
        #expect(HostChecks.resolve("~/Projects/x", home: "/home/u") == "/home/u/Projects/x")
        #expect(HostChecks.resolve("~", home: "/home/u") == "/home/u")
        #expect(HostChecks.resolve("/srv/x/", home: "/home/u") == "/srv/x")
    }
}

struct HostControlTests {
    struct Setup {
        let dir: TempDir
        let host: FakeHost
        let workspace: Workspace
        let repo: String
        let clone: String

        init(path: String = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin") async throws {
            dir = try TempDir()
            let host = try FakeHost(in: dir, path: path)
            self.host = host
            repo = try await Fixture.repo(in: dir, name: "demo", origin: true)
            clone = dir.sub("host-box/Projects/demo")
            try await Fixture.git.run(["clone", "--quiet", dir.sub("demo-origin.git"), clone])
            workspace = Workspace(
                home: CanopyHome(path: dir.sub("home")), git: Fixture.git,
                hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { host.environment }))
            try await workspace.start()
            try await workspace.addRepo(path: repo)
        }
    }

    /// Restored panes attach together, and each prepares the host first.
    @Test func panesPreparingAHostAtOnceInstallItsFilesOnce() async throws {
        let setup = try await Setup()
        let installs = setup.dir.sub("installs")
        let script = setup.dir.sub("counting-ssh")
        try """
        #!/bin/bash
        [[ "$*" == *b64decode* ]] && echo x >> '\(installs)'
        exec '\(FakeHost.script)' "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let workspace = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: script, environment: { setup.host.environment }))
        try await workspace.start()
        try HostsConfigFile(url: workspace.home.configFile).save("box", HostEntry(repos: [:]))
        let connection = try await workspace.connection(for: "box")
        try await connection.connect()

        async let first: Void = workspace.prepareHost(connection)
        async let second: Void = workspace.prepareHost(connection)
        async let third: Void = workspace.prepareHost(connection)
        _ = try await (first, second, third)

        #expect(try String(contentsOfFile: installs, encoding: .utf8) == "x\n")
        await workspace.stop()
        await setup.workspace.stop()
    }

    @Test func anAliasSSHConfigDoesNotNameAndThatDoesNotResolveIsUnknownAtOnce() async throws {
        let setup = try await Setup()
        FileManager.default.createFile(atPath: setup.host.home + "/.fake-ssh-unknown", contents: nil)
        FileManager.default.createFile(atPath: setup.host.home + "/.fake-ssh-down", contents: nil)
        let workspace = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(
                sshExecutable: FakeHost.script, environment: { setup.host.environment }, clock: TestHostClock()))
        try await workspace.start()

        await #expect {
            try await workspace.addHost(alias: "no-such-host.invalid", repos: [:], wake: nil, idleDetachMinutes: nil)
        } throws: { ($0 as? WorkspaceError)?.code == "host_unknown" }
        // A name that only resolves while its host is awake is woken first, and reached once it is up, rather than
        // retried for five minutes with a master started each time.
        let woken = setup.dir.sub("woken")
        let wake = "touch '\(woken)' && rm '\(setup.host.home)/.fake-ssh-down'"
        do {
            _ = try await workspace.addHost(
                alias: "no-such-host.invalid", repos: [:], wake: wake, idleDetachMinutes: nil)
        } catch {
            #expect((error as? WorkspaceError)?.code != "host_unknown", "\(error)")
        }
        #expect(FileManager.default.fileExists(atPath: woken))

        await workspace.stop()
        await setup.workspace.stop()
    }

    @Test func aHostAddThatFailsChangesNothing() async throws {
        let setup = try await Setup()
        _ = try await setup.workspace.addHost(
            alias: "box", repos: ["demo": "~/Projects/demo"], wake: nil, idleDetachMinutes: 10)

        await #expect {
            try await setup.workspace.addHost(
                alias: "box", repos: ["demo": "~/nowhere"], wake: "start it", idleDetachMinutes: 1)
        } throws: { ($0 as? WorkspaceError)?.code == "repo_not_found" }
        await #expect {
            try await setup.workspace.addHost(
                alias: "other", repos: ["demo": "~/nowhere"], wake: nil, idleDetachMinutes: nil)
        } throws: { ($0 as? WorkspaceError)?.code == "repo_not_found" }

        let entry = await setup.workspace.hostConnections["box"]?.entry
        #expect(entry?.idleDetachMinutes == 10)
        #expect(entry?.wake == nil)
        #expect(await setup.workspace.hostConnections["other"] == nil)
        await setup.workspace.stop()
    }

    /// `row new --on local` means this Mac, so no host may take that name.
    @Test func aHostCannotBeNamedLocal() async throws {
        let setup = try await Setup()

        await #expect {
            try await setup.workspace.addHost(alias: "local", repos: [:], wake: nil, idleDetachMinutes: nil)
        } throws: { error in
            guard let error = error as? WorkspaceError else { return false }
            return error.code == "host_reserved" && error.message.contains("--on local")
        }
        #expect(await setup.workspace.hostConnections["local"] == nil)
        #expect(await setup.workspace.hostListing().hosts.isEmpty)
        _ = try await setup.workspace.addHost(alias: "Local", repos: [:], wake: nil, idleDetachMinutes: nil)
        await setup.workspace.stop()
    }

    /// A host added again gets a new connection, whose generations start over, so it must be prepared again.
    @Test func aRemovedHostIsPreparedAgainOnceAddedBack() async throws {
        let setup = try await Setup()
        _ = try await setup.workspace.addHost(alias: "box", repos: [:], wake: nil, idleDetachMinutes: nil)
        try await setup.workspace.prepareHost(try await setup.workspace.connection(for: "box"))

        try await setup.workspace.removeHost(alias: "box")

        #expect(await setup.workspace.preparedHosts["box"] == nil)
        await setup.workspace.stop()
    }

    @Test func listingSaysWhichHostsConfigJSONCouldNotRead() async throws {
        let setup = try await Setup()
        try #"{"hosts": {"bad": {"repos": "nope"}, "good": {"repos": {"demo": "/x"}}}}"#.write(
            toFile: setup.workspace.home.configFile.path, atomically: true, encoding: .utf8)

        let listing = await setup.workspace.hostListing()

        #expect(listing.hosts.map(\.alias) == ["good"])
        #expect(listing.warnings.count == 1)
        #expect(listing.warnings.first?.contains("bad") == true)
        await setup.workspace.stop()
    }

    @Test func addingAHostChecksItInstallsCanopysFilesAndSavesIt() async throws {
        let setup = try await Setup()

        let info = try await setup.workspace.addHost(
            alias: "box", repos: ["demo": "~/Projects/demo"], wake: "start it", idleDetachMinutes: 10)

        #expect(info.alias == "box")
        #expect(info.repos == ["demo": setup.clone])
        #expect(info.state == .connected)
        #expect(info.tmuxServer == HostPaths.tmuxServer(homeID: setup.workspace.homeID))
        let saved = HostsConfig.load(from: setup.workspace.home.configFile).hosts["box"]
        #expect(saved == HostEntry(repos: ["demo": setup.clone], wake: "start it", idleDetachMinutes: 10))
        #expect(
            FileManager.default.fileExists(
                atPath: setup.host.home + "/.canopy/\(setup.workspace.homeID)/bin/canopy-host"))
        setup.workspace.activity.flushNow()
        let events = ActivityReader.events(in: setup.workspace.home.activityFolder, since: .distantPast, until: nil)
        #expect(events.contains { $0.type == "host.added" && $0.data["host"] == .string("box") })
        await setup.workspace.stop()
    }

    @Test func aCloneReachedThroughALinkIsACheckout() async throws {
        let setup = try await Setup()
        try FileManager.default.createSymbolicLink(
            atPath: setup.host.home + "/linked", withDestinationPath: setup.clone)

        let info = try await setup.workspace.addHost(
            alias: "box", repos: ["demo": "~/linked"], wake: nil, idleDetachMinutes: nil)

        #expect(info.repos == ["demo": setup.host.home + "/linked"])
        await setup.workspace.stop()
    }

    @Test func aFolderInsideACheckoutIsNotOne() async throws {
        let setup = try await Setup()
        try FileManager.default.createDirectory(atPath: setup.clone + "/sub", withIntermediateDirectories: true)

        await #expect {
            try await setup.workspace.addHost(
                alias: "box", repos: ["demo": "~/Projects/demo/sub"], wake: nil, idleDetachMinutes: nil)
        } throws: { ($0 as? WorkspaceError)?.code == "repo_not_found" }
        await setup.workspace.stop()
    }

    @Test func addingAgainUpdatesTheHost() async throws {
        let setup = try await Setup()
        try await setup.workspace.addHost(
            alias: "box", repos: ["demo": "~/Projects/demo"], wake: nil, idleDetachMinutes: nil)

        try await setup.workspace.addHost(alias: "box", repos: [:], wake: "w", idleDetachMinutes: 5)

        let saved = HostsConfig.load(from: setup.workspace.home.configFile).hosts["box"]
        #expect(saved == HostEntry(repos: ["demo": setup.clone], wake: "w", idleDetachMinutes: 5))
        await setup.workspace.stop()
    }

    @Test func aHostWithoutTmuxIsUnfit() async throws {
        let setup = try await Setup(path: "/usr/bin:/bin")

        await #expect {
            try await setup.workspace.addHost(
                alias: "box", repos: ["demo": "~/Projects/demo"], wake: nil, idleDetachMinutes: nil)
        } throws: { error in
            let error = error as? WorkspaceError
            return error?.code == "host_unfit" && error?.message.contains("tmux") == true
        }
        #expect(HostsConfig.load(from: setup.workspace.home.configFile).hosts.isEmpty)
        await setup.workspace.stop()
    }

    @Test func aPathThatIsNotACheckoutAndARepoCanopyLacksAreNotFound() async throws {
        let setup = try await Setup()

        await #expect {
            try await setup.workspace.addHost(
                alias: "box", repos: ["demo": "~/nowhere"], wake: nil, idleDetachMinutes: nil)
        } throws: { ($0 as? WorkspaceError)?.code == "repo_not_found" && "\($0)".contains("nowhere") }
        await #expect {
            try await setup.workspace.addHost(
                alias: "box", repos: ["other": "~/Projects/demo"], wake: nil, idleDetachMinutes: nil)
        } throws: { ($0 as? WorkspaceError)?.code == "repo_not_found" }
        #expect(HostsConfig.load(from: setup.workspace.home.configFile).hosts.isEmpty)
        await setup.workspace.stop()
    }

    @Test func aHostWithRowsCannotBeRemoved() async throws {
        let setup = try await Setup()
        try await setup.workspace.addHost(
            alias: "box", repos: ["demo": "~/Projects/demo"], wake: nil, idleDetachMinutes: nil)
        let entry = RemoteRowEntry(
            host: "box", path: setup.clone + "-x", standIn: setup.workspace.home.remoteRoot.path + "/box/demo/x",
            branch: "x", head: nil)
        try await setup.workspace.addRemoteRow(entry, repoPath: setup.repo)

        await #expect {
            try await setup.workspace.removeHost(alias: "box")
        } throws: { ($0 as? WorkspaceError)?.code == "host_has_rows" && "\($0)".contains(entry.standIn) }
        await setup.workspace.stop()
    }

    @Test func removingAHostForgetsIt() async throws {
        let setup = try await Setup()
        try await setup.workspace.addHost(
            alias: "box", repos: ["demo": "~/Projects/demo"], wake: nil, idleDetachMinutes: nil)

        try await setup.workspace.removeHost(alias: "box")

        #expect(HostsConfig.load(from: setup.workspace.home.configFile).hosts.isEmpty)
        #expect(await setup.workspace.hostListing().hosts.isEmpty)
        await setup.workspace.stop()
    }

    @Test func aHostNothingUsedListsAsIdle() async throws {
        let setup = try await Setup()
        try HostsConfigFile(url: setup.workspace.home.configFile).save("box", HostEntry(repos: ["demo": setup.clone]))

        #expect(await setup.workspace.hostListing().hosts.map(\.state) == [.idle])
        await setup.workspace.stop()
    }
}

struct StaleMasterTests {
    @Test func aMasterLeftByACrashedCanopyStopsAtLaunch() async throws {
        let setup = try await HostControlTests.Setup()
        try HostsConfigFile(url: setup.workspace.home.configFile).save("box", HostEntry(repos: ["demo": setup.clone]))
        await setup.workspace.stop()
        let control = setup.workspace.ssh(for: "box").controlPath
        try FileManager.default.createDirectory(
            atPath: (control as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A crash leaves a master running with nobody to stop it.
        let stray = Process()
        stray.executableURL = URL(fileURLWithPath: FakeHost.script)
        stray.arguments = ["-M", "-N", "-S", control, "--", "box"]
        stray.environment = setup.host.environment
        stray.standardOutput = FileHandle.nullDevice
        stray.standardError = FileHandle.nullDevice
        try stray.run()
        defer { stray.terminate() }
        #expect(await eventually { FileManager.default.fileExists(atPath: control) })

        let relaunched = Workspace(
            home: setup.workspace.home, git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { setup.host.environment }))
        try await relaunched.start()

        #expect(await eventually { !stray.isRunning })
        await relaunched.stop()
    }
}

struct HostHooksTests {
    typealias Setup = HostControlTests.Setup

    static func settings(_ setup: Setup, _ path: String = ".claude/settings.json") -> String {
        setup.host.home + "/" + path
    }

    static func add(_ workspace: Workspace) async throws {
        try await workspace.addHost(alias: "box", repos: [:], wake: nil, idleDetachMinutes: nil)
    }

    static func inode(_ path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
    }

    static func mode(_ path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    /// What `canopy hooks install` makes of `text` on this Mac.
    static func installedLocally(_ text: String, in dir: TempDir) throws -> Data {
        let file = Fixture.claudeSettings(dir, "local/settings.json")
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
        try file.install()
        return try Data(contentsOf: file.url)
    }

    @Test func aHostGetsCanopysHooksAsHooksInstallWritesThem() async throws {
        let setup = try await Setup()

        try await Self.add(setup.workspace)

        let path = Self.settings(setup)
        let file = ClaudeSettingsFile(url: URL(fileURLWithPath: path))
        #expect(try file.status() == .installed)
        let local = Fixture.claudeSettings(setup.dir, "local/settings.json")
        try local.install()
        #expect(try Data(contentsOf: file.url) == Data(contentsOf: local.url))
        #expect(try Self.mode(path) == 0o644)
        await setup.workspace.stop()
    }

    @Test func aHostsOtherSettingsStayAsTheyWere() async throws {
        let setup = try await Setup()
        // A settings file kept with dotfiles, through a link that must stay one.
        let target = Self.settings(setup, "dotfiles/claude.json")
        try FileManager.default.createDirectory(
            atPath: Self.settings(setup, "dotfiles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: Self.settings(setup, ".claude"), withIntermediateDirectories: true)
        try Data(ClaudeSettingsTests.written.utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        try FileManager.default.createSymbolicLink(atPath: Self.settings(setup), withDestinationPath: target)

        try await Self.add(setup.workspace)

        #expect(
            try Data(contentsOf: URL(fileURLWithPath: target))
                == Self.installedLocally(ClaudeSettingsTests.written, in: setup.dir))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: Self.settings(setup)) == target)
        #expect(try Self.mode(target) == 0o600)
        await setup.workspace.stop()
    }

    /// The hooks run `$CANOPY_CLI`, which each home's panes point at their own relay, so every home on a host shares
    /// them.
    @Test func addingAgainOrFromAnotherHomeChangesNothing() async throws {
        let setup = try await Setup()
        try await Self.add(setup.workspace)
        let path = Self.settings(setup)
        let installed = try Data(contentsOf: URL(fileURLWithPath: path))
        let inode = try Self.inode(path)

        try await Self.add(setup.workspace)
        let other = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { setup.host.environment }))
        try await other.start()
        try await Self.add(other)

        #expect(other.homeID != setup.workspace.homeID)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == installed)
        #expect(try Self.inode(path) == inode)
        await other.stop()
        await setup.workspace.stop()
    }

    @Test func settingsClaudeCodeCannotReadStopTheHostBeingAdded() async throws {
        let setup = try await Setup()
        let path = Self.settings(setup)
        try FileManager.default.createDirectory(
            atPath: Self.settings(setup, ".claude"), withIntermediateDirectories: true)
        try "{ \"model\": ".write(toFile: path, atomically: true, encoding: .utf8)

        await #expect {
            try await Self.add(setup.workspace)
        } throws: { error in
            guard let error = error as? WorkspaceError else { return false }
            return error.code == "host_command_failed" && error.message.contains(path)
        }

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{ \"model\": ")
        #expect(HostsConfig.load(from: setup.workspace.home.configFile).hosts.isEmpty)
        await setup.workspace.stop()
    }

    @Test func theHooksGoWhereTheHostsClaudeConfigDirSays() async throws {
        let setup = try await Setup()
        var environment = setup.host.environment
        environment["FAKE_SSH_CLAUDE_CONFIG_DIR"] = "~/claude-config"
        let workspace = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { [environment] in environment }))
        try await workspace.start()

        try await Self.add(workspace)

        let file = ClaudeSettingsFile(url: URL(fileURLWithPath: Self.settings(setup, "claude-config/settings.json")))
        #expect(try file.status() == .installed)
        #expect(!FileManager.default.fileExists(atPath: Self.settings(setup)))
        await workspace.stop()
        await setup.workspace.stop()
    }

    /// Outside a Canopy pane on the host, and in one whose app is away, a hook stays silent and lets Claude go on.
    @Test func theInstalledHookIsQuietWithoutCanopy() async throws {
        let setup = try await Setup()
        try await Self.add(setup.workspace)
        let settings = try OrderedJSON.parse(try Data(contentsOf: URL(fileURLWithPath: Self.settings(setup))))
        guard case .array(let groups) = settings["hooks"]?["Stop"], case .array(let handlers) = groups.first?["hooks"],
            case .string(let command) = handlers.first?["command"]
        else {
            Issue.record("No Stop hook")
            return
        }
        let connection = try await setup.workspace.connection(for: "box")
        let files = setup.host.home + "/.canopy/\(setup.workspace.homeID)"
        let outside = [
            "env", "-u", "CANOPY_CLI", "-u", "CANOPY_SOCKET", "-u", "CANOPY_PANE", "-u", "CANOPY_HOME_ID", "sh", "-c",
            command,
        ]
        let appAway = [
            "env", "CANOPY_CLI=\(files)/bin/canopy", "CANOPY_SOCKET=\(files)/app.sock", "CANOPY_PANE=p1",
            "CANOPY_HOME_ID=\(setup.workspace.homeID)", "sh", "-c", command,
        ]

        for remote in [outside, appAway] {
            let result = try await connection.run(remote, timeout: .seconds(60))
            #expect(result.status == 0, "\(remote)")
            #expect(String(decoding: result.stdout, as: UTF8.self) == "", "\(remote)")
            #expect(String(decoding: result.stderr, as: UTF8.self) == "", "\(remote)")
        }
        // The hook did run the relay, which kept the report for the app.
        #expect(FileManager.default.fileExists(atPath: files + "/pending/p1.json"))
        await setup.workspace.stop()
    }

    @Test func settingsChangedSinceTheyWereReadAreNotWrittenOver() async throws {
        let setup = try await Setup()
        let path = Self.settings(setup)
        try FileManager.default.createDirectory(
            atPath: Self.settings(setup, ".claude"), withIntermediateDirectories: true)
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
        try HostsConfigFile(url: setup.workspace.home.configFile).save("box", HostEntry(repos: [:]))
        let connection = try await setup.workspace.connection(for: "box")

        let stale = HostClaudeSettings.writeCommand(
            replacing: Data("{\"a\": 1}\n".utf8), with: Data("{\"b\": 2}\n".utf8))
        let result = try await connection.run(stale, timeout: .seconds(60))

        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "changed\n")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{}\n")
        await setup.workspace.stop()
    }
}
