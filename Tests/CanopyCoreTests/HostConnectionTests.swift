import Foundation
import Testing

@testable import CanopyCore

struct HostConnectionTests {
    struct Setup {
        let dir: TempDir
        let launcher = FakeHostLauncher()
        let clock = TestHostClock()
        let activity: ActivityLog
        let connection: HostConnection

        init(wake: String? = "start-box", idleMinutes: Int = 30) throws {
            dir = try TempDir()
            activity = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))
            connection = HostConnection(
                alias: "box", entry: HostEntry(repos: [:], wake: wake, idleDetachMinutes: idleMinutes),
                ssh: SSHCommand(executable: "/usr/bin/ssh", controlPath: dir.sub("cm"), alias: "box"),
                launcher: launcher,
                clock: clock, activity: activity)
        }

        func events() -> [String] {
            activity.flushNow()
            return ActivityReader.events(
                in: URL(fileURLWithPath: dir.sub("activity")), since: .distantPast, until: nil
            ).map(\.type)
        }
    }

    @Test func twoCallersShareOneMaster() async throws {
        let setup = try Setup()

        async let first: Void = setup.connection.connect()
        async let second: Void = setup.connection.connect()
        _ = try await (first, second)

        #expect(setup.launcher.masters.count == 1)
        #expect(await setup.connection.state == .connected)
        #expect(setup.events() == ["host.connected"])
    }

    /// A pane asks every few seconds, so it can say what the host is doing while it comes up.
    @Test func waitingAtMostAWhileLeavesTheAttemptForTheNextCaller() async throws {
        let setup = try Setup()
        setup.launcher.masterUp = false
        setup.launcher.holdWakes = true
        // Only this lets a connect that waits for the attempt to end come back, and then with the host up.
        let safety = Task {
            try await Task.sleep(for: .seconds(30))
            setup.launcher.masterUp = true
            setup.launcher.releaseWakes()
        }
        defer { safety.cancel() }

        let first = try await setup.connection.connect(waitingAtMost: .milliseconds(300))

        #expect(!first)
        #expect(await setup.connection.state == .waking)
        setup.launcher.masterUp = true
        setup.launcher.releaseWakes()
        #expect(try await setup.connection.connect(waitingAtMost: .seconds(20)))
        #expect(setup.launcher.wakes == ["start-box"])
        #expect(setup.events() == ["host.woken", "host.connected"])
    }

    @Test(arguments: [
        "ubuntu@10.0.0.1: Permission denied (publickey).",
        "Host key verification failed.",
        "/Users/me/.ssh/config: line 3: Bad configuration option: hostnme",
    ])
    func anErrorNoRetryCanFixFailsAtOnceWithoutWaking(_ error: String) async throws {
        let setup = try Setup()
        setup.launcher.masterUp = false
        setup.launcher.masterError = error

        await #expect {
            try await setup.connection.connect()
        } throws: { ($0 as? WorkspaceError)?.code == "host_unreachable" }

        #expect(setup.launcher.masters.count == 1)
        #expect(setup.launcher.wakes.isEmpty)
        #expect(await setup.connection.state == .unreachable)
        #expect(await setup.connection.lastError == error)
    }

    /// A name that does not resolve may be a Mac that is offline for now, or a host whose name only resolves while it
    /// is awake, so it is retried and woken. `host add` catches typos.
    @Test func aNameThatDoesNotResolveIsRetriedAndWoken() async throws {
        let setup = try Setup()
        setup.launcher.masterUp = false
        setup.launcher.masterError = "ssh: Could not resolve hostname box: nodename nor servname provided, or not known"

        await #expect {
            try await setup.connection.connect()
        } throws: { ($0 as? WorkspaceError)?.code == "host_unreachable" }

        #expect(setup.launcher.wakes.isEmpty == false)
        #expect(setup.launcher.masters.count > 1)
    }

    /// ssh also ends with 255 when the session's program dies by a signal, which a new attach fixes.
    @Test func aMasterThatAnswersButTakesNoCommandsRefusesSessions() async throws {
        let setup = try Setup()
        #expect(await !setup.connection.refusesSessions())
        try await setup.connection.connect()

        #expect(await !setup.connection.refusesSessions())
        setup.launcher.execStatus = 255
        #expect(await setup.connection.refusesSessions())
    }

    /// Two callers find the master gone at once. The first to learn it starts a new one, which the second must not
    /// stop, as the panes attaching through it would drop.
    @Test func callersThatFindTheMasterGoneTogetherKeepTheNewOne() async throws {
        let setup = try Setup()
        try await setup.connection.connect()
        let first = try #require(setup.launcher.masters.first)
        setup.launcher.state.withLock { _ = $0.deadSockets.insert(ObjectIdentifier(first)) }
        setup.launcher.holdChecks = true

        async let a: Void = setup.connection.connect()
        async let b: Void = setup.connection.connect()
        #expect(await eventually { setup.launcher.heldCheckCount() == 2 })
        // One learns first and starts a master, whose own check waits beside the other's.
        setup.launcher.releaseFirstCheck()
        #expect(await eventually { setup.launcher.masters.count == 2 && setup.launcher.heldCheckCount() == 2 })
        setup.launcher.releaseChecks()
        _ = try await (a, b)

        #expect(setup.launcher.masters.count == 2)
        #expect(setup.launcher.masters.last?.isRunning == true)
        #expect(await setup.connection.state == .connected)
    }

    @Test func aHostThatIsOffIsWokenOnceAndConnectsWhenItComesUp() async throws {
        let setup = try Setup()
        setup.launcher.masterUp = false
        let states = await setup.connection.states()
        Task {
            for await state in states where state == .waking {
                setup.launcher.masterUp = true
            }
        }

        try await setup.connection.connect()

        #expect(setup.launcher.wakes == ["start-box"])
        #expect(await setup.connection.state == .connected)
        #expect(setup.events() == ["host.woken", "host.connected"])
    }

    @Test func wakeRunsAtMostEveryTwoMinutesAndGivesUpAfterFive() async throws {
        let setup = try Setup()
        setup.launcher.masterUp = false

        await #expect { try await setup.connection.connect() } throws: {
            ($0 as? WorkspaceError)?.code == "host_unreachable"
        }

        #expect(setup.launcher.wakes.count == 3)
        #expect(setup.launcher.masters.count >= 30)
        #expect(await setup.connection.state == .unreachable)
        #expect(await setup.connection.lastError?.contains("Connection closed") == true)
        #expect(setup.events().filter { $0 != "host.woken" } == ["host.unreachable"])
    }

    @Test func withoutWakeItOnlyRetries() async throws {
        let setup = try Setup(wake: nil)
        setup.launcher.masterUp = false

        await #expect(throws: WorkspaceError.self) { try await setup.connection.connect() }

        #expect(setup.launcher.wakes.isEmpty)
        #expect(setup.launcher.masters.count > 1)
    }

    @Test func aMasterNothingUsesStopsAfterTenMinutes() async throws {
        let setup = try Setup()
        try await setup.connection.connect()

        setup.clock.advance(by: .seconds(9 * 60))
        await setup.connection.panesActive(attached: 0, busy: false, serving: false, quietFor: .seconds(9 * 60))
        #expect(await setup.connection.state == .connected)
        setup.clock.advance(by: .seconds(61))
        await setup.connection.panesActive(attached: 0, busy: false, serving: false, quietFor: .seconds(10 * 60))

        #expect(await setup.connection.state == .idle)
        #expect(setup.launcher.masters.last?.isRunning == false)
    }

    @Test func quietPanesDetachAfterTheHostsIdleMinutes() async throws {
        let setup = try Setup(idleMinutes: 30)
        try await setup.connection.connect()

        setup.clock.advance(by: .seconds(20 * 60))
        await setup.connection.panesActive(attached: 2, busy: true, serving: false, quietFor: .seconds(20 * 60))
        setup.clock.advance(by: .seconds(20 * 60))
        await setup.connection.panesActive(attached: 2, busy: false, serving: false, quietFor: .seconds(40 * 60))
        #expect(await setup.connection.state == .connected)
        setup.clock.advance(by: .seconds(11 * 60))
        await setup.connection.panesActive(attached: 2, busy: false, serving: false, quietFor: .seconds(29 * 60))
        #expect(await setup.connection.state == .connected)
        await setup.connection.panesActive(attached: 2, busy: false, serving: false, quietFor: .seconds(30 * 60))

        #expect(await setup.connection.state == .detached)
        #expect(setup.launcher.masters.last?.isRunning == false)
        #expect(setup.events() == ["host.connected", "host.detached"])
    }

    /// A remote row's server counts as use, so the master stays while someone may be browsing it through its forward,
    /// and the idle wait starts again once it stops.
    @Test func aHostServingARemoteRowsPortNeitherStopsNorDetaches() async throws {
        let setup = try Setup(idleMinutes: 30)
        try await setup.connection.connect()

        setup.clock.advance(by: .seconds(11 * 60))
        await setup.connection.panesActive(attached: 0, busy: false, serving: true, quietFor: .seconds(11 * 60))
        #expect(await setup.connection.state == .connected)
        setup.clock.advance(by: .seconds(40 * 60))
        await setup.connection.panesActive(attached: 2, busy: false, serving: true, quietFor: .seconds(51 * 60))
        #expect(await setup.connection.state == .connected)
        setup.clock.advance(by: .seconds(29 * 60))
        await setup.connection.panesActive(attached: 2, busy: false, serving: false, quietFor: .seconds(80 * 60))
        #expect(await setup.connection.state == .connected)
        setup.clock.advance(by: .seconds(60))
        await setup.connection.panesActive(attached: 2, busy: false, serving: false, quietFor: .seconds(81 * 60))

        #expect(await setup.connection.state == .detached)
    }

    @Test func zeroIdleMinutesNeverDetaches() async throws {
        let setup = try Setup(idleMinutes: 0)
        try await setup.connection.connect()

        setup.clock.advance(by: .seconds(24 * 3600))
        await setup.connection.panesActive(attached: 1, busy: false, serving: false, quietFor: .seconds(24 * 3600))

        #expect(await setup.connection.state == .connected)
    }

    @Test func aMasterThatDiesGoesIdleAndTheNextConnectStartsAnother() async throws {
        let setup = try Setup()
        try await setup.connection.connect()

        setup.launcher.masters.last?.end()
        let idle = await eventually { await setup.connection.state == .idle }
        #expect(idle)
        try await setup.connection.connect()

        #expect(setup.launcher.masters.count == 2)
        #expect(await setup.connection.state == .connected)
    }

    /// A host removed, or a Canopy quitting, stops its connection for good: work still on its way, such as a kept
    /// report being replayed, must not start a master nothing would stop.
    @Test func aStoppedConnectionRefusesToConnect() async throws {
        let setup = try Setup()
        try await setup.connection.connect()

        await setup.connection.stop()

        await #expect {
            try await setup.connection.run(["true"], timeout: .seconds(5))
        } throws: {
            ($0 as? WorkspaceError)?.code == "host_unreachable"
                && ($0 as? WorkspaceError)?.message.contains("Canopy stopped using box") == true
        }
        #expect(setup.launcher.masters.count == 1)
        #expect(await setup.connection.state == .idle)
    }

    /// A master coming up as the connection stops is stopped too, rather than left running.
    @Test func aMasterComingUpAsTheConnectionStopsIsStopped() async throws {
        let setup = try Setup()
        setup.launcher.holdChecks = true
        let connecting = Task { try await setup.connection.connect() }
        #expect(await eventually { setup.launcher.heldCheckCount() == 1 })

        await setup.connection.stop()
        setup.launcher.releaseChecks()

        await #expect(throws: (any Error).self) { try await connecting.value }
        #expect(await setup.connection.state == .idle)
        #expect(setup.launcher.masters.allSatisfy { !$0.isRunning })
    }

    @Test func commandsConnectFirstAndGoThroughTheMaster() async throws {
        let setup = try Setup()

        let result = try await setup.connection.run(["echo", "hi"], timeout: .seconds(5))

        #expect(result.status == 0)
        #expect(setup.launcher.commands.last == setup.connection.ssh.exec(["echo", "hi"]))
        #expect(await setup.connection.state == .connected)
    }

    @Test func aMasterThatNoLongerAnswersIsReplacedRatherThanReused() async throws {
        let setup = try Setup()
        try await setup.connection.connect()
        // The connection dropped: ssh's socket is gone, and the process is on its way out.
        let first = try #require(setup.launcher.masters.first)
        setup.launcher.state.withLock { _ = $0.deadSockets.insert(ObjectIdentifier(first)) }

        try await setup.connection.connect()

        #expect(setup.launcher.masters.count == 2)
        #expect(!first.isRunning)
        #expect(await setup.connection.state == .connected)
    }

    @Test func aSocketNoMasterAnswersOnIsClearedBeforeANewMaster() async throws {
        let setup = try Setup()
        // A master killed outright leaves its socket, and a new one would then run without multiplexing.
        try Data().write(to: URL(fileURLWithPath: setup.dir.sub("cm")))

        try await setup.connection.connect()

        #expect(setup.launcher.state.withLock { $0.socketThereAtStart } == [false])
    }
}

struct MasterWatchdogTests {
    @Test func aMasterStopsOnceWhoeverStartedItIsGone() async throws {
        let wrapped = SubprocessHostLauncher.watched(["/bin/sleep", "300"])
        // The shell starts the master and exits at once, as a Canopy that crashed would.
        let started = try Subprocess.run(
            "/bin/sh", ["-c", SSHCommand.shellQuoted(wrapped) + " >/dev/null 2>&1 & echo $!"],
            environment: ["PATH": "/usr/bin:/bin"], directory: nil, timeout: .seconds(10))
        let watchdog = try #require(
            Int32(String(decoding: started.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))

        let ended = await eventually { kill(watchdog, 0) == -1 }

        #expect(ended)
    }

    @Test func aWatchedMasterReportsItsOwnExit() throws {
        let result = try Subprocess.run(
            "/bin/sh",
            [
                "-c",
                SSHCommand.shellQuoted(SubprocessHostLauncher.watched(["/bin/sh", "-c", "echo oops >&2; exit 255"])),
            ],
            environment: ["PATH": "/usr/bin:/bin"], directory: nil, timeout: .seconds(10))

        #expect(result.status == 255)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
    }
}
