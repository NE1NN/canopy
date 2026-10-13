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
        #expect(await link.waitUntilConnected(within: .seconds(10)))
        #expect(await daemon.isConfigured)
        var snapshots = await link.snapshots().makeAsyncIterator()
        #expect(await snapshots.next() == BoxSnapshot())
        let hello: BoxHelloResult = try await link.call(BoxMethod.hello, BoxHelloParams(version: "x"))
        #expect(hello.homeID == "11112222")
        await #expect(throws: ControlError.self) {
            let _: Bool = try await link.call(BoxMethod.paneClose, BoxPaneParams(pane: "b9"))
        }
    }

    @Test func aLinkComesBackAfterTheDaemonRestarts() async throws {
        let box = try Box()
        _ = try await box.start()
        let link = box.link()
        await link.start()
        defer { Task { await link.stop() } }
        #expect(await link.waitUntilConnected(within: .seconds(10)))
        box.server.withLock { $0?.close() }
        #expect(await eventually { !(await link.isConnected) })
        let restarted = try await box.start()
        #expect(await link.waitUntilConnected(within: .seconds(10)))
        #expect(await restarted.isConfigured)
    }

    @Test func aCallWithoutALinkFailsAsHostUnreachable() async throws {
        let box = try Box()
        let link = box.link()
        await #expect(throws: WorkspaceError.hostUnreachable("box", reason: "Canopy on box is not connected.")) {
            let _: BoxHelloResult = try await link.call(BoxMethod.hello, BoxHelloParams(version: "x"))
        }
    }
}
