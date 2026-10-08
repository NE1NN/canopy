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
                    sshExecutable: "/usr/bin/false", clock: TestHostClock(),
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
}
