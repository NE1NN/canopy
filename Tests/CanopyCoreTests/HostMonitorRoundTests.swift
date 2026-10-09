import Foundation
import Testing

@testable import CanopyCore

/// The monitor over hosts whose ssh is a stand-in that answers probes, and can hold them, as a slow host would.
@MainActor
struct HostMonitorRoundTests {
    static let empty = #"{"sessions": [], "pending": [], "ports": []}"#

    @MainActor
    final class Hosts {
        let dir: TempDir
        let launchers: [String: FakeHostLauncher]
        let workspace: Workspace
        let terminals: TerminalStore
        let clock = TestHostClock()

        /// With `rows`, each host has a remote row of the repo `demo`, at `/h/<alias>/feat` there.
        init(_ aliases: [String], rows: Bool = false) async throws {
            dir = try TempDir()
            let launchers = Dictionary(uniqueKeysWithValues: aliases.map { ($0, FakeHostLauncher()) })
            for launcher in launchers.values {
                launcher.answer(.sessions, with: HostMonitorRoundTests.empty)
                launcher.answer(.ports, with: HostMonitorRoundTests.empty)
            }
            self.launchers = launchers
            workspace = Workspace(
                home: CanopyHome(path: dir.sub("home")), git: Fixture.git,
                hostTooling: HostTooling(
                    sshExecutable: "/usr/bin/false", clock: clock,
                    launcher: { launchers[$0] ?? FakeHostLauncher() }))
            try await workspace.start()
            let repo = rows ? try await Fixture.repo(in: dir) : nil
            if let repo { try await workspace.addRepo(path: repo) }
            for alias in aliases {
                try HostsConfigFile(url: workspace.home.configFile).save(alias, HostEntry(repos: [:]))
                try await workspace.connection(for: alias).connect()
                if let repo {
                    let entry = RemoteRowEntry(
                        host: alias, path: Self.rowPath(alias),
                        standIn: workspace.home.remoteRoot.path + "/\(alias)/demo/feat", branch: "feat", head: nil)
                    try await workspace.addRemoteRow(entry, repoPath: repo)
                }
            }
            terminals = Fixture.terminals(dir)
        }

        static func rowPath(_ alias: String) -> String { "/h/\(alias)/feat" }

        /// The host's ports probe finds servers on `ports`, working in its remote row.
        func serve(on alias: String, _ ports: [UInt16]) {
            let listed = ports.map { port in
                #"{"port": \#(port), "address": "127.0.0.1", "processes": [{"pid": \#(port), "name": "node", "ancestors": [1], "folder": "\#(Self.rowPath(alias))"}]}"#
            }
            self[alias].answer(
                .ports, with: #"{"sessions": [], "pending": [], "ports": [\#(listed.joined(separator: ", "))]}"#)
        }

        subscript(alias: String) -> FakeHostLauncher { launchers[alias]! }

        func stop() async {
            for launcher in launchers.values {
                launcher.release(.sessions)
                launcher.release(.ports)
                launcher.releaseForwards()
            }
            terminals.closeAll()
            await workspace.stop()
        }
    }

    /// Rounds one after another, as the app runs them, until cancelled.
    static func rounds(_ monitor: HostMonitor) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await monitor.probe()
                try? await Task.sleep(for: .milliseconds(10))
            }
            await monitor.settle()
        }
    }

    /// A host's own probes go one after another, so they hold one ssh session at most, but another host's never
    /// wait for them.
    @Test func aStuckPortsProbeHoldsUpNoOtherHost() async throws {
        let hosts = try await Hosts(["slow", "quick"])
        let monitor = HostMonitor(workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero)
        hosts["slow"].hold(.ports)

        let rounds = Self.rounds(monitor)

        #expect(await eventually { hosts["quick"].probes(.sessions) >= 3 && hosts["quick"].probes(.ports) >= 3 })
        #expect(hosts["slow"].probes(.sessions) == 1)
        #expect(hosts["slow"].probes(.ports) == 1)
        hosts["slow"].release(.ports)
        #expect(await eventually { hosts["slow"].probes(.sessions) >= 2 })
        rounds.cancel()
        await rounds.value
        await hosts.stop()
    }

    /// The app starts a round every few seconds without waiting for the last, so a host whose session probe hangs
    /// is skipped until it answers, while the others go on.
    @Test func aStuckSessionProbeHoldsUpNoOtherHost() async throws {
        let hosts = try await Hosts(["slow", "quick"])
        let monitor = HostMonitor(workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero)
        hosts["slow"].hold(.sessions)

        let watching = Task { await monitor.watch(every: .milliseconds(10)) }

        #expect(await eventually { hosts["quick"].probes(.sessions) >= 3 })
        #expect(hosts["slow"].probes(.sessions) == 1)
        #expect(hosts["slow"].probes(.ports) == 0)
        hosts["slow"].release(.sessions)
        #expect(await eventually { hosts["slow"].probes(.sessions) >= 2 })
        watching.cancel()
        await watching.value
        await hosts.stop()
    }

    /// Ending the watch ends the rounds it started and waits for them, so none outlives the hosts they probe.
    @Test func endingTheWatchEndsTheRoundsItStarted() async throws {
        let hosts = try await Hosts(["slow", "quick"])
        let monitor = HostMonitor(workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero)
        hosts["slow"].hold(.sessions)
        let watching = Task { await monitor.watch(every: .milliseconds(10)) }
        #expect(await eventually { hosts["slow"].heldProbeCount(.sessions) == 1 })

        watching.cancel()
        await watching.value

        #expect(hosts["slow"].heldProbeCount(.sessions) == 0)
        #expect(monitor.isSettled)
        await hosts.stop()
    }

    /// A round the master stopped under says nothing of the forwards, so the ports keep what they showed rather than
    /// showing as not forwarded with no reason.
    @Test func aRoundTheMasterStoppedUnderShowsNoFalseError() async throws {
        let hosts = try await Hosts(["box"], rows: true)
        let box = hosts["box"]
        let monitor = HostMonitor(workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero)
        let port = FakeSSHForwardTests.freePort(count: 2)
        hosts.serve(on: "box", [port])
        let ports = { monitor.remotePorts["box"]?.flatMap(\.ports) ?? [] }
        #expect(
            await eventually {
                await monitor.probe()
                return ports().first?.remote?.local == port
            })
        box.holdForwards = true
        hosts.serve(on: "box", [port, port + 1])
        #expect(
            await eventually {
                await monitor.probe()
                return box.heldForwardCount() == 1
            })
        let connection = try await hosts.workspace.connection(for: "box")
        await connection.detach()
        try await connection.connect()

        box.releaseFirstForward()

        // The next round waits for this one, so once it holds its first forward, this one has shown what it found.
        #expect(
            await eventually {
                await monitor.probe()
                return box.heldForwardCount() == 1
            })
        #expect(!ports().isEmpty)
        #expect(ports().allSatisfy { $0.remote?.local != nil || $0.remote?.error != nil })
        await hosts.stop()
    }

    /// A host whose remote row serves a port keeps its master with no pane attached, as someone may be browsing it.
    @Test func aHostServingARemoteRowsPortStaysConnected() async throws {
        let hosts = try await Hosts(["serving", "quiet"], rows: true)
        let monitor = HostMonitor(workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero)
        let port = FakeSSHForwardTests.freePort()
        hosts.serve(on: "serving", [port])
        #expect(
            await eventually {
                await monitor.probe()
                return monitor.remotePorts["serving"]?.isEmpty == false
            })

        let serving = try await hosts.workspace.connection(for: "serving")
        let quiet = try await hosts.workspace.connection(for: "quiet")
        let probed = hosts["serving"].probes(.sessions)

        hosts.clock.advance(by: .seconds(11 * 60))

        // A round skips a host whose ports probe still runs, so rounds go on until each host had one.
        #expect(
            await eventually {
                await monitor.probe()
                return await quiet.state == .idle && hosts["serving"].probes(.sessions) > probed
            })
        #expect(await serving.state == .connected)
        await hosts.stop()
    }

    /// A server that died while the host's `ss` kept failing would otherwise count as use for good, so ports count
    /// only while the listing they came from is recent.
    @Test func portsFromAStaleListingAreNoUse() async throws {
        let hosts = try await Hosts(["box"], rows: true)
        let clock = TestHostClock()
        let monitor = HostMonitor(
            workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero, clock: clock)
        let port = FakeSSHForwardTests.freePort()
        hosts.serve(on: "box", [port])
        #expect(
            await eventually {
                await monitor.probe()
                return monitor.remotePorts["box"]?.first?.ports.first?.remote?.local == port
            })
        hosts["box"].answer(.ports, with: #"{"sessions": [], "pending": [], "ports": null}"#)
        let listed = hosts["box"].probes(.ports)
        // A host's ports probes go one after another, so by the second since, none that found the port is under way.
        #expect(
            await eventually {
                await monitor.probe()
                return hosts["box"].probes(.ports) >= listed + 2
            })
        #expect(monitor.remotePorts["box"]?.isEmpty == false)
        let box = try await hosts.workspace.connection(for: "box")

        clock.advance(by: .seconds(61))
        hosts.clock.advance(by: .seconds(11 * 60))

        #expect(
            await eventually {
                await monitor.probe()
                return await box.state == .idle
            })
        await hosts.stop()
    }

    /// A port ssh could not forward cannot be browsed from the Mac, so it keeps nothing up.
    @Test func aPortWithoutAForwardIsNoUse() async throws {
        let hosts = try await Hosts(["box"], rows: true)
        let monitor = HostMonitor(workspace: hosts.workspace, terminals: hosts.terminals, portsEvery: .zero)
        hosts["box"].refuseEveryPort(true)
        hosts.serve(on: "box", [FakeSSHForwardTests.freePort()])
        #expect(
            await eventually {
                await monitor.probe()
                return monitor.remotePorts["box"]?.first?.ports.first?.remote?.error != nil
            })
        let box = try await hosts.workspace.connection(for: "box")

        hosts.clock.advance(by: .seconds(11 * 60))

        #expect(
            await eventually {
                await monitor.probe()
                return await box.state == .idle
            })
        await hosts.stop()
    }
}
