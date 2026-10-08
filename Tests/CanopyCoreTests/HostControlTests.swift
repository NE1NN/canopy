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
        #expect(FileManager.default.fileExists(atPath: setup.host.home + "/.canopy/bin/canopy-host"))
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
