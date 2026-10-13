import CanopyBoxKit
import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// The Mac's link against canopy-box's server, both in this process.
struct BoxLinkTests {
    final class Box: Sendable {
        let dir: TempDir
        let socket: String
        let tmuxFolder: String
        let server: Shared<BoxServer?> = Shared(nil)
        let daemon: Shared<BoxDaemon?> = Shared(nil)

        init() throws {
            dir = try TempDir(in: "/tmp")
            socket = dir.sub("box.sock")
            tmuxFolder = dir.sub("tmux")
            try FileManager.default.createDirectory(atPath: tmuxFolder, withIntermediateDirectories: true)
        }

        /// Starts a daemon and its server, or a new one in place of the last, as a restart does.
        func start() async throws -> BoxDaemon {
            server.withLock { $0?.close() }
            var environment = Fixture.environment
            environment["TMUX_TMPDIR"] = tmuxFolder
            let daemon = BoxDaemon(
                paths: BoxPaths(root: dir.path, homeID: "11112222"),
                tmux: Tmux(server: "link-\(UUID().uuidString.prefix(6))", config: nil, environment: environment),
                git: { GitFixture.clone($0) })
            // Never the real instance metadata service.
            try BoxFiles.write(Data("127.0.0.1 1".utf8), to: dir.sub("11112222/box/imds"))
            await daemon.start()
            let started = try BoxServer(daemon: daemon, socketPath: socket)
            server.withLock { $0 = started }
            self.daemon.withLock { $0 = daemon }
            return daemon
        }

        func link() -> BoxLink {
            BoxLink(alias: "box", socketPath: socket) { BoxConfig(host: "box", repos: [:]) }
        }

        deinit { server.withLock { $0?.close() } }
    }

    @Test func theLinkConfiguresSubscribesAndCalls() async throws {
        let box = try Box()
        let daemon = try await box.start()
        let link = box.link()
        await link.start()
        defer { Task { await link.stop() } }
        #expect(await link.waitUntilConnected(within: .seconds(30)))
        #expect(await daemon.isConfigured)
        var snapshots = await link.snapshots().makeAsyncIterator()
        #expect(await snapshots.next() == BoxSnapshot())
        let hello: BoxHelloResult = try await link.call(BoxMethod.hello, BoxHelloParams(version: "x"))
        #expect(hello.homeID == "11112222")
        await #expect(throws: ControlError.self) {
            let _: Bool = try await link.call(BoxMethod.paneClose, BoxPaneParams(pane: "b9"))
        }
    }

    /// A setting changed on the Mac, as a wake key, reaches the daemon without waiting for the next connect.
    @Test func reconfiguringSendsTheSettingsAgain() async throws {
        let box = try Box()
        let daemon = try await box.start()
        let wake = Shared<BoxWakeKey?>(nil)
        let link = BoxLink(alias: "box", socketPath: box.socket) {
            BoxConfig(host: "box", wake: wake.withLock { $0 })
        }
        await link.start()
        defer { Task { await link.stop() } }
        #expect(await link.waitUntilConnected(within: .seconds(30)))
        let key = BoxWakeKey(accessKeyID: "AKIA", secretAccessKey: "s")
        wake.withLock { $0 = key }

        try await link.reconfigure()

        #expect(await daemon.wakeKey == key)
    }

    @Test func aLinkComesBackAfterTheDaemonRestarts() async throws {
        let box = try Box()
        _ = try await box.start()
        let link = box.link()
        await link.start()
        defer { Task { await link.stop() } }
        #expect(await link.waitUntilConnected(within: .seconds(30)))
        box.server.withLock { $0?.close() }
        #expect(await eventually { !(await link.isConnected) })
        let restarted = try await box.start()
        #expect(await link.waitUntilConnected(within: .seconds(30)))
        #expect(await restarted.isConfigured)
    }

    @Test func aCallWithoutALinkFailsAsHostUnreachable() async throws {
        let box = try Box()
        let link = box.link()
        await #expect(throws: WorkspaceError.hostUnreachable("box", reason: "Canopy on box is not connected.")) {
            let _: BoxHelloResult = try await link.call(BoxMethod.hello, BoxHelloParams(version: "x"))
        }
    }

    @Test func aForwardWithNoDaemonBehindItIsTriedAgainEverySecond() async throws {
        // ssh's forward takes the connection and closes it while the host's box.sock is gone, as a restart leaves it.
        let box = try Box()
        let accepted = Shared(0)
        let listener = try UnixListener(path: box.socket) { connection in
            accepted.withLock { $0 += 1 }
            // ssh reads what the app sends before it learns the host's end is gone.
            _ = try? connection.readLine(deadline: .now + .seconds(5))
            connection.close()
        }
        defer { listener.close() }
        let link = box.link()
        await link.start()
        defer { Task { await link.stop() } }
        // Twice in 20 seconds even on a loaded machine; a link waiting out a call would try once in two minutes.
        #expect(await eventually(timeout: .seconds(20)) { accepted.withLock { $0 } >= 2 })
    }
}
