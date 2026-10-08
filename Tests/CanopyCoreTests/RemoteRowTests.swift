import Foundation
import Testing

@testable import CanopyCore

struct RemoteRowTests {
    /// A local repo with an origin, the host's clone of that origin, and the host added with it.
    struct Setup {
        let dir: TempDir
        let host: FakeHost
        let workspace: Workspace
        let repo: String
        let origin: String
        let clone: String

        init(host make: @Sendable (TempDir) throws -> FakeHost = { try FakeHost(in: $0) }) async throws {
            dir = try TempDir()
            let host = try make(dir)
            self.host = host
            repo = try await Fixture.repo(in: dir, name: "demo", origin: true)
            origin = dir.sub("demo-origin.git")
            clone = dir.sub("host-box/Projects/demo")
            try await Fixture.git.run(["clone", "--quiet", origin, clone])
            try await Fixture.git.run(["config", "user.email", "t@example.com"], in: clone)
            try await Fixture.git.run(["config", "user.name", "T"], in: clone)
            workspace = Workspace(
                home: CanopyHome(path: dir.sub("home")), git: Fixture.git,
                hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { host.environment }))
            try await workspace.start()
            try await workspace.addRepo(path: repo)
            try HostsConfigFile(url: workspace.home.configFile).save("box", HostEntry(repos: ["demo": clone]))
        }

        var worktrees: String { dir.sub("host-box/.canopy/worktrees/demo") }

        func git(_ arguments: [String], in folder: String) async throws -> String {
            try await Fixture.git.run(arguments, in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Pushes a commit to origin's `branch` from a scratch clone.
        func pushToOrigin(_ branch: String, from base: String = "main") async throws {
            let scratch = dir.sub("scratch-\(UUID().uuidString.prefix(6))")
            try await Fixture.git.run(["clone", "--quiet", origin, scratch])
            try await Fixture.git.run(["checkout", "--quiet", "-B", branch, "origin/\(base)"], in: scratch)
            try await Fixture.git.run(
                [
                    "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--quiet", "--allow-empty", "-m",
                    "up",
                ],
                in: scratch)
            try await Fixture.git.run(["push", "--quiet", "origin", "HEAD:\(branch)"], in: scratch)
        }
    }

    @Test func aNewBranchStartsFromOriginsDefaultBranchOnTheHost() async throws {
        let setup = try await Setup()

        let created = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/x")

        let folder = setup.worktrees + "/feat-x"
        #expect(created.source == .new)
        #expect(created.base == "origin/main")
        #expect(created.row.rowClass == .remote)
        #expect(created.row.host == "box")
        #expect(created.row.remotePath == folder)
        #expect(created.row.branch == "feat/x")
        #expect(created.row.path == setup.workspace.home.remoteRoot.path + "/box/demo/feat-x")
        #expect(try await setup.git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder) == "feat/x")
        #expect(FileManager.default.fileExists(atPath: created.row.path + "/remote.json"))
        #expect(
            await setup.workspace.snapshot.repo(path: setup.repo)?.rows.map(\.path).contains(created.row.path) == true)
        await setup.workspace.stop()
    }

    @Test func aBranchOnOriginIsTrackedAndAHostBranchOnlyBehindIsFastForwarded() async throws {
        let setup = try await Setup()
        try await setup.pushToOrigin("feat/remote")
        try await Fixture.git.run(["branch", "feat/behind", "main"], in: setup.clone)
        try await setup.pushToOrigin("feat/behind")

        let tracked = try await setup.workspace.createRemoteRow(
            repoPath: setup.repo, host: "box", branch: "feat/remote")
        let behind = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/behind")

        #expect(tracked.source == .origin)
        #expect(behind.source == .local)
        #expect(behind.notes.contains { $0.contains("Fast-forwarded feat/behind by 1 commit") })
        let head = try await setup.git(["rev-parse", "HEAD"], in: try #require(behind.row.remotePath))
        #expect(head == (try await setup.git(["rev-parse", "origin/feat/behind"], in: setup.clone)))
        await setup.workspace.stop()
    }

    @Test func aBranchAnotherRowOnTheHostHoldsFailsButALocalRowsDoesNot() async throws {
        let setup = try await Setup()
        _ = try await setup.workspace.createRow(repoPath: setup.repo, branch: "feat/both")
        _ = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/both")

        await #expect {
            try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/both")
        } throws: { ($0 as? WorkspaceError)?.code == "branch_checked_out" }
        await setup.workspace.stop()
    }

    @Test func aGroupTakesTheNewRow() async throws {
        let setup = try await Setup()
        try await setup.workspace.createGroup(repoPath: setup.repo, name: "Box")

        let created = try await setup.workspace.createRemoteRow(
            repoPath: setup.repo, host: "box", branch: "feat/g", group: "box")

        #expect(await setup.workspace.snapshot.row(path: created.row.path)?.group == "Box")
        await setup.workspace.stop()
    }

    @Test func listingFollowsABranchSwitchedOnTheHostAndAWorktreeRemovedThere() async throws {
        let setup = try await Setup()
        let first = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/a")
        let second = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/b")
        let firstFolder = try #require(first.row.remotePath)
        let secondFolder = try #require(second.row.remotePath)
        try await Fixture.git.run(["switch", "--quiet", "-c", "feat/renamed"], in: firstFolder)
        try await Fixture.git.run(["worktree", "remove", secondFolder], in: setup.clone)

        await setup.workspace.refreshRemote(repoPath: setup.repo, host: "box")

        let snapshot = await setup.workspace.snapshot
        #expect(snapshot.row(path: first.row.path)?.branch == "feat/renamed")
        #expect(snapshot.row(path: second.row.path)?.isMissing == true)
        setup.workspace.activity.flushNow()
        let events = ActivityReader.events(in: setup.workspace.home.activityFolder, since: .distantPast, until: nil)
        #expect(events.contains { $0.type == "row.branch_changed" && $0.data["host"] == .string("box") })
        await setup.workspace.stop()
    }

    @Test func aHostThatDropsHalfwaySavesNothing() async throws {
        let setup = try await Setup()
        try await setup.workspace.connection(for: "box").connect()
        let marker = setup.dir.sub("calls")
        // The fake ssh counts its calls other than master checks, and fails from the fourth on, partway through
        // making the row: after the master and two commands.
        let script = setup.dir.sub("dropping-ssh")
        try """
        #!/bin/bash
        [[ "$*" == *"-O"* ]] && exec '\(FakeHost.script)' "$@"
        count=$(( $(cat '\(marker)' 2>/dev/null || echo 0) + 1 ))
        echo $count > '\(marker)'
        (( count > 3 )) && { echo "Connection closed" >&2; exit 255; }
        exec '\(FakeHost.script)' "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let dropping = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: script, environment: { setup.host.environment }))
        try await dropping.start()
        try await dropping.addRepo(path: setup.repo)
        try HostsConfigFile(url: dropping.home.configFile).save("box", HostEntry(repos: ["demo": setup.clone]))

        await #expect {
            try await dropping.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/drop")
        } throws: { ($0 as? WorkspaceError)?.code == "host_unreachable" }

        #expect(await dropping.snapshot.repo(path: setup.repo)?.rows.map(\.rowClass) == [.main])
        await dropping.stop()
        await setup.workspace.stop()
    }

    /// A host that drops while its branches are listed must not look like one without the branch, which would make
    /// a new branch on the wrong base.
    /// Each machine's git only knows its own worktrees, so a branch a remote row holds is still free on this Mac.
    @Test func aBranchARemoteRowHoldsIsFreeOnThisMac() async throws {
        let setup = try await Setup()
        _ = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/both")
        try await Fixture.git.run(["branch", "feat/both"], in: setup.repo)

        let listed = try await setup.workspace.listBranches(repoPath: setup.repo, fetch: false).branches

        #expect(listed.first { $0.name == "feat/both" }?.row == nil)
        await setup.workspace.stop()
    }

    @Test func aHostThatDropsWhileListingBranchesMakesNoBranch() async throws {
        let setup = try await Setup()
        let script = setup.dir.sub("dropping-ssh")
        try """
        #!/bin/bash
        [[ "$*" == *for-each-ref* ]] && { echo "Connection closed" >&2; exit 255; }
        exec '\(FakeHost.script)' "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let dropping = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: script, environment: { setup.host.environment }))
        try await dropping.start()
        try await dropping.addRepo(path: setup.repo)
        try HostsConfigFile(url: dropping.home.configFile).save("box", HostEntry(repos: ["demo": setup.clone]))

        await #expect {
            try await dropping.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/listed")
        } throws: { ($0 as? WorkspaceError)?.code == "host_unreachable" }

        let branches = try await Fixture.git.run(["branch", "--list", "feat/listed"], in: setup.clone)
        #expect(branches.isEmpty)
        await dropping.stop()
        await setup.workspace.stop()
    }

    @Test func aHostThatDropsOnceTheWorktreeIsMadeStillGetsItsRow() async throws {
        let setup = try await Setup()
        try await setup.workspace.connection(for: "box").connect()
        let dropped = setup.dir.sub("dropped")
        let script = setup.dir.sub("dropping-ssh")
        try """
        #!/bin/bash
        [[ "$*" == *"-O"* ]] && exec '\(FakeHost.script)' "$@"
        [[ -e '\(dropped)' ]] && { echo "Connection closed" >&2; exit 255; }
        '\(FakeHost.script)' "$@"
        status=$?
        [[ "$*" == *"worktree add"* || "$*" == *"'worktree' 'add'"* ]] && touch '\(dropped)'
        exit $status
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let dropping = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: script, environment: { setup.host.environment }))
        try await dropping.start()
        try await dropping.addRepo(path: setup.repo)
        try HostsConfigFile(url: dropping.home.configFile).save("box", HostEntry(repos: ["demo": setup.clone]))

        let created = try await dropping.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/drop")

        #expect(FileManager.default.fileExists(atPath: dropped))
        let folder = try #require(created.row.remotePath)
        #expect(FileManager.default.fileExists(atPath: folder + "/.git"))
        #expect(created.row.branch == "feat/drop")
        #expect(created.warnings.contains { $0.contains("box") })
        #expect(await dropping.snapshot.row(path: created.row.path)?.remotePath == folder)
        await dropping.stop()
        await setup.workspace.stop()
    }

    @Test func removingADirtyRowNeedsForceAndThenGoesWithItsStandIn() async throws {
        let setup = try await Setup()
        let created = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/d")
        let folder = try #require(created.row.remotePath)
        try "x".write(toFile: folder + "/new-file", atomically: true, encoding: .utf8)

        await #expect {
            try await setup.workspace.removeRemoteRow(standIn: created.row.path, force: false, deleteBranch: false)
        } throws: { ($0 as? WorkspaceError)?.code == "worktree_dirty" }
        let warnings = try await setup.workspace.removeRemoteRow(
            standIn: created.row.path, force: true, deleteBranch: true)

        #expect(warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(!FileManager.default.fileExists(atPath: created.row.path))
        #expect(await setup.workspace.snapshot.row(path: created.row.path) == nil)
        #expect(await setup.workspace.remoteRow(standIn: created.row.path) == nil)
        #expect((try? await setup.git(["rev-parse", "--verify", "feat/d"], in: setup.clone)) == nil)
        await setup.workspace.stop()
    }

    @Test func removingWhileTheHostIsDownNeedsForceAndLeavesTheWorktree() async throws {
        let setup = try await Setup()
        let created = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/off")
        await setup.workspace.stop()
        let down = Workspace(
            home: setup.workspace.home, git: Fixture.git,
            hostTooling: HostTooling(
                sshExecutable: FakeHost.script,
                environment: { setup.host.environment.merging(["FAKE_SSH_DOWN": "1"]) { $1 } },
                clock: TestHostClock()))
        try await down.start()

        await #expect {
            try await down.removeRemoteRow(standIn: created.row.path, force: false, deleteBranch: false)
        } throws: { ($0 as? WorkspaceError)?.code == "host_unreachable" }
        let warnings = try await down.removeRemoteRow(standIn: created.row.path, force: true, deleteBranch: false)

        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("box") == true)
        #expect(await down.snapshot.row(path: created.row.path) == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(created.row.remotePath)))
        await down.stop()
    }

    @Test func aRepoTheHostLacksAndAnUnknownHostAreNamed() async throws {
        let setup = try await Setup()
        try HostsConfigFile(url: setup.workspace.home.configFile).save("empty", HostEntry())

        await #expect {
            try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "empty", branch: "x")
        } throws: { ($0 as? WorkspaceError)?.code == "host_has_no_repo" && "\($0)".contains("box") }
        await #expect {
            try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "nope", branch: "x")
        } throws: { ($0 as? WorkspaceError)?.code == "host_not_found" }
        await setup.workspace.stop()
    }

    @Test func remoteBranchesJoinPullRequestLookups() async throws {
        let setup = try await Setup()
        _ = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/pr")

        #expect(await setup.workspace.pullRequestBranches(repoPath: setup.repo).contains("feat/pr"))
        await setup.workspace.stop()
    }
}

struct RemoteSessionTests {
    static let tmux = HostFilesTests.tmux

    /// A session on the fake host's Canopy tmux server, running bash in `folder`.
    func startSession(_ name: String, server: String, in folder: String) throws {
        _ = try Subprocess.run(
            try #require(Self.tmux),
            ["-L", server, "-f", "/dev/null", "new-session", "-d", "-s", name, "-c", folder, "/bin/bash"],
            environment: Fixture.environment, directory: nil, timeout: .seconds(10))
    }

    func sessions(server: String) throws -> [String] {
        let result = try Subprocess.run(
            try #require(Self.tmux), ["-L", server, "list-sessions", "-F", "#{session_name}"],
            environment: Fixture.environment, directory: nil, timeout: .seconds(10))
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func killServer(_ server: String) {
        _ = try? Subprocess.run(
            Self.tmux ?? "/usr/bin/false", ["-L", server, "kill-server"], environment: Fixture.environment,
            directory: nil, timeout: .seconds(10))
    }

    @Test(.enabled(if: tmux != nil, "needs tmux: brew install tmux"))
    func aSessionClosedWhileTheHostIsDownEndsWhenItConnectsAgain() async throws {
        let setup = try await RemoteRowTests.Setup(host: {
            try FakeHost(in: $0, path: "/opt/homebrew/bin:/usr/bin:/bin")
        })
        let server = HostPaths.tmuxServer(homeID: setup.workspace.homeID)
        defer { killServer(server) }
        try startSession("p4", server: server, in: setup.dir.path)
        try startSession("p5", server: server, in: setup.dir.path)

        try await setup.workspace.connection(for: "box").connect()
        await setup.workspace.killSessions(["p4"], on: "box")
        #expect(try sessions(server: server) == ["p5"])
        #expect(await setup.workspace.pendingSessionKills.isEmpty)
        await setup.workspace.stop()

        let down = Workspace(
            home: setup.workspace.home, git: Fixture.git,
            hostTooling: HostTooling(
                sshExecutable: FakeHost.script,
                environment: { setup.host.environment.merging(["FAKE_SSH_DOWN": "1"]) { $1 } }, clock: TestHostClock()))
        try await down.start()
        await down.killSessions(["p5"], on: "box")
        #expect(await down.pendingSessionKills == ["box": ["p5"]])
        #expect(try sessions(server: server) == ["p5"])
        await down.stop()

        let up = Workspace(
            home: setup.workspace.home, git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { setup.host.environment }))
        try await up.start()
        try await up.prepareHost(try await up.connection(for: "box"))

        #expect(try sessions(server: server).isEmpty)
        #expect(await up.pendingSessionKills.isEmpty)
        await up.stop()
    }

    /// The host drops after the changes check, so the row stays, and with it the agent running in it.
    @Test(.enabled(if: tmux != nil, "needs tmux: brew install tmux"))
    func aRemovalTheHostRefusesLeavesTheRowsSessionsRunning() async throws {
        let setup = try await RemoteRowTests.Setup(host: {
            try FakeHost(in: $0, path: "/opt/homebrew/bin:/usr/bin:/bin")
        })
        let script = setup.dir.sub("dropping-ssh")
        try """
        #!/bin/bash
        [[ "$*" == *"'worktree' 'remove'"* ]] && { echo "Connection closed" >&2; exit 255; }
        exec '\(FakeHost.script)' "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let workspace = Workspace(
            home: CanopyHome(path: setup.dir.sub("home2")), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: script, environment: { setup.host.environment }))
        try await workspace.start()
        try await workspace.addRepo(path: setup.repo)
        try HostsConfigFile(url: workspace.home.configFile).save("box", HostEntry(repos: ["demo": setup.clone]))
        let server = HostPaths.tmuxServer(homeID: workspace.homeID)
        defer { killServer(server) }
        let created = try await workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/kept")
        let (terminals, rows) = await MainActor.run {
            let terminals = Fixture.terminals(setup.dir)
            return (terminals, RowLifecycle(workspace: workspace, terminals: terminals))
        }
        let session = try await MainActor.run {
            try #require(terminals.openTab(for: PaneContext(row: created.row, repoName: "demo")).pane.remoteSession)
        }
        try startSession(session, server: server, in: try #require(created.row.remotePath))

        await #expect {
            try await rows.remove(created.row, repoName: "demo", force: false, deleteBranch: false)
        } throws: { ($0 as? WorkspaceError)?.code == "host_unreachable" }

        #expect(try sessions(server: server) == [session])
        #expect(await workspace.pendingSessionKills.isEmpty)
        #expect(await MainActor.run { terminals.tabs(inRow: created.row.path).count } == 1)
        await MainActor.run { terminals.closeAll() }
        await workspace.stop()
        await setup.workspace.stop()
    }

    @Test func aRowWhoseHostIsGoneFromConfigCanBeForcedOut() async throws {
        let setup = try await RemoteRowTests.Setup()
        let created = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/gone")
        try HostsConfigFile(url: setup.workspace.home.configFile).remove("box")

        await #expect {
            try await setup.workspace.removeRemoteRow(standIn: created.row.path, force: false, deleteBranch: false)
        } throws: { ($0 as? WorkspaceError)?.code == "host_not_found" }
        let warnings = try await setup.workspace.removeRemoteRow(
            standIn: created.row.path, force: true, deleteBranch: false)

        #expect(warnings.first?.contains("box") == true)
        #expect(await setup.workspace.snapshot.row(path: created.row.path) == nil)
        await setup.workspace.stop()
    }

    @Test(.enabled(if: tmux != nil, "needs tmux: brew install tmux"))
    func keysReachTheSessionOnceItExists() async throws {
        let setup = try await RemoteRowTests.Setup(host: {
            try FakeHost(in: $0, path: "/opt/homebrew/bin:/usr/bin:/bin")
        })
        let server = HostPaths.tmuxServer(homeID: setup.workspace.homeID)
        defer { killServer(server) }
        let marker = setup.dir.sub("typed")
        try startSession("p9", server: server, in: setup.dir.path)

        await setup.workspace.sendKeys("echo hi > '\(marker)'", to: "p9", on: "box")

        let typed = await eventually { FileManager.default.fileExists(atPath: marker) }
        #expect(typed)
        await setup.workspace.stop()
    }
}

struct RemoteStandInPathTests {
    @Test func aStandInIsCanonicalWhenTheHomeIsReachedThroughALink() async throws {
        let setup = try await RemoteRowTests.Setup()
        let link = setup.dir.sub("linked-home")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: setup.workspace.home.root.path)
        await setup.workspace.stop()
        let linked = Workspace(
            home: CanopyHome(path: link), git: Fixture.git,
            hostTooling: HostTooling(sshExecutable: FakeHost.script, environment: { setup.host.environment }))
        try await linked.start()

        let created = try await linked.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/linked")

        #expect(created.row.path == Paths.canonical(created.row.path))
        #expect(created.row.path.hasPrefix(setup.workspace.home.root.path))
        let found = try TargetResolver.row(
            for: TargetHint(row: link + "/remote/box/demo/feat-linked"), in: await linked.snapshot)
        #expect(found.path == created.row.path)
        await linked.stop()
    }
}

@MainActor
struct HostMonitorTests {
    @Test(.enabled(if: RemoteSessionTests.tmux != nil, "needs tmux: brew install tmux"))
    func aProbeTellsEachRemotePaneWhatItsSessionDoes() async throws {
        let setup = try await RemoteRowTests.Setup(host: {
            try FakeHost(in: $0, path: "/opt/homebrew/bin:/usr/bin:/bin")
        })
        let server = HostPaths.tmuxServer(homeID: setup.workspace.homeID)
        defer { RemoteSessionTests().killServer(server) }
        let created = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/m")
        try await setup.workspace.prepareHost(try await setup.workspace.connection(for: "box"))
        let terminals = Fixture.terminals(setup.dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: PaneContext(row: created.row, repoName: "demo")).pane
        let folder = try #require(created.row.remotePath)
        try RemoteSessionTests().startSession(try #require(pane.remoteSession), server: server, in: folder)
        let monitor = HostMonitor(workspace: setup.workspace, terminals: terminals)

        await monitor.probe()

        #expect(pane.remoteActivity?.folder == folder)
        #expect(pane.remoteActivity?.busy == false)
        await setup.workspace.stop()
    }
}

struct RemoteLinkedHomeTests {
    @Test func aHostWhoseHomeIsALinkStillListsItsRows() async throws {
        let setup = try await RemoteRowTests.Setup(host: { try FakeHost(in: $0, linkedHome: true) })
        let created = try await setup.workspace.createRemoteRow(repoPath: setup.repo, host: "box", branch: "feat/l")

        await setup.workspace.refreshRemote(repoPath: setup.repo, host: "box")

        #expect(await setup.workspace.snapshot.row(path: created.row.path)?.isMissing == false)
        #expect(await setup.workspace.snapshot.row(path: created.row.path)?.branch == "feat/l")
        await setup.workspace.stop()
    }
}
