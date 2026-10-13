import CanopyAgents
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

struct BoxServerTests {
    struct Served {
        let home: BoxTestHome
        let daemon: BoxDaemon
        let server: BoxServer

        init(configured: Bool = true) async throws {
            home = try await BoxTestHome()
            daemon = try await home.daemon(configured: configured)
            server = try BoxServer(daemon: daemon, socketPath: home.paths.socket)
        }

        func client() throws -> BoxClient { try BoxClient(path: home.paths.socket) }
    }

    @Test func helloSaysItsVersionAndHome() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let response = try await served.client().call(BoxMethod.hello, BoxHelloParams(version: "1"))
        let hello = try #require(try response.result?.decode(BoxHelloResult.self))
        #expect(
            hello
                == BoxHelloResult(
                    version: CanopyVersion.current, protocolVersion: 1, homeID: BoxTestHome.homeID, configured: true))
    }

    @Test func configureIsSavedAndUsed() async throws {
        let served = try await Served(configured: false)
        defer { served.server.close() }
        let client = try served.client()
        let configured = try await client.call(BoxMethod.configure, served.home.config)
        #expect(configured.result == .bool(true))
        let hello = try await client.call(BoxMethod.hello, BoxHelloParams(version: "1"))
        #expect(try hello.result?.decode(BoxHelloResult.self).configured == true)
        #expect(await served.daemon.snapshot().rows.map(\.path) == [served.home.clone])
        let restarted = try await served.home.daemon(configured: false)
        #expect(await restarted.isConfigured)
    }

    @Test func subscribeSendsTheSnapshotThenChanges() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let watcher = try served.client()
        let subscribed = try await watcher.call(BoxMethod.subscribe)
        #expect(subscribed.result == .bool(true))
        #expect(try await watcher.nextSnapshot()?.rows.count == 1)
        let made = try await served.client().call(BoxMethod.paneNew, BoxPaneNewParams(rowPath: served.home.clone))
        #expect(try made.result?.decode(BoxPaneNewResult.self).pane == "b1")
        var panes: [String] = []
        while panes.isEmpty, let next = try await watcher.nextSnapshot() { panes = next.panes.map(\.id) }
        #expect(panes == ["b1"])
    }

    @Test func snapshotsComeAtMostEvery100ms() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let watcher = try served.client()
        _ = try await watcher.call(BoxMethod.subscribe)
        _ = try await watcher.nextSnapshot()
        let started = ContinuousClock.now
        for number in 1...20 { await served.daemon.setPRs([served.home.clone: number]) }
        var seen = 0
        var last: Int?
        while last != 20, let next = try await watcher.nextSnapshot(timeout: .seconds(5)) {
            seen += 1
            last = next.rows.first?.pr
        }
        #expect(last == 20)
        let elapsed = (ContinuousClock.now - started) / .milliseconds(100)
        #expect(Double(seen) <= elapsed + 2)
    }

    @Test func aHookThroughTheSocketReachesSubscribers() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let pane = try await served.daemon.paneNew(BoxPaneNewParams(rowPath: served.home.clone))
        let input = Data(#"{"hook_event_name": "UserPromptSubmit", "session_id": "s"}"#.utf8)
        let request = RelayRequest(
            version: "v", args: ["agent-hook"], cwd: "/", env: ["CANOPY_PANE": pane],
            stdin: input.base64EncodedString(),
            age: 0)
        let relay = try served.client()
        let ack = try await relay.exchange(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        #expect(ack == #"{"ack": true}"#)
        let line = try #require(try await relay.readLine())
        #expect(try JSONDecoder().decode(RelayReply.self, from: Data(line.utf8)).status == 0)
        #expect(await served.daemon.snapshot().panes.first?.agent == .working)
    }

    @Test func aBadLineGetsBadRequestAndAnUnknownMethodSaysSo() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let client = try served.client()
        let bad = try #require(try await client.exchange("{nope"))
        #expect(try JSONDecoder().decode(ControlResponse.self, from: Data(bad.utf8)).error?.code == "bad_request")
        let unknown = try await client.call("box.nothing")
        #expect(unknown.error?.code == "unknown_method")
    }

    @Test func adoptThenReleaseRoundTrips() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let path = try await served.home.worktree("feat/ad", under: served.home.dir.sub("mac"))
        try await served.home.session("p3", in: path)
        let client = try served.client()
        let adopted = try await client.call(
            BoxMethod.adopt,
            BoxAdoptParams(
                rows: [BoxAdoptedRow(repo: "demo", path: path, branch: "feat/ad")],
                panes: [BoxAdoptedPane(id: "p3", rowPath: path, folder: path, agent: PaneAgent())], nextPane: 4))
        #expect(
            try adopted.result?.decode(BoxAdoptResult.self) == BoxAdoptResult(rows: [path], panes: ["p3"], missing: []))
        let released = try await client.call(BoxMethod.release)
        let result = try #require(try released.result?.decode(BoxReleaseResult.self))
        #expect(result.rows.map(\.path) == [path])
        #expect(result.panes.map(\.id) == ["p3"])
        #expect(result.nextPane == 4)
    }

    @Test func answersWhatCameBeforeTheClientClosedItsSide() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let connection = try UnixConnection.connect(path: served.home.paths.socket)
        defer { connection.close() }
        let reply = try await offPool {
            try connection.write(
                try ControlCodec.encodeLine(ControlRequest(method: BoxMethod.hello, params: .object([:]), id: "h")),
                deadline: .now + .seconds(5))
            connection.finishSending()
            var line = try connection.readLine(deadline: .now + .seconds(10))
            while line?.isEmpty == true { line = try connection.readLine(deadline: .now + .seconds(10)) }
            return line
        }
        let response = try ControlCodec.decode(ControlResponse.self, from: try #require(reply))
        #expect(response.id == "h")
        #expect(response.error == nil)
    }

    @Test func failuresKeepTheirCodes() async throws {
        let served = try await Served()
        defer { served.server.close() }
        let response = try await served.client().call(BoxMethod.paneClose, BoxPaneParams(pane: "b42"))
        #expect(response.error == BoxErrors.paneNotFound("b42"))
    }
}
