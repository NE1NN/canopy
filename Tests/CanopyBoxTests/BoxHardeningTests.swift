import CanopyAgents
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

/// What 3a's review deferred, fixed in 3b.
struct BoxHardeningTests {
    @Test func hangingUpWaitsOutWhatThePeerSends() async throws {
        let folder = try TempDir(in: "/tmp")
        let path = folder.sub("h.sock")
        let accepted = Shared<UnixConnection?>(nil)
        let listener = try UnixListener(path: path) { connection in accepted.withLock { $0 = connection } }
        defer { listener.close() }
        let client = try UnixConnection.connect(path: path)
        defer { client.close() }
        #expect(await eventually { accepted.withLock { $0 } != nil })
        let server = try #require(accepted.withLock { $0 })
        try client.write(Data("extra bytes".utf8), deadline: .now + .seconds(5))
        let started = ContinuousClock.now
        let hungUp = try await offPool { server.hungUp(within: .milliseconds(300)) }
        #expect(!hungUp)
        #expect(ContinuousClock.now - started >= .milliseconds(250))
    }

    @Test func aFullDisconnectCancelsItsCalls() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let server = try BoxServer(daemon: daemon, socketPath: home.paths.socket)
        defer { server.close() }
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        // Let go of once the call runs, which closes its descriptor, as a process that exits does.
        let held = Shared<UnixConnection?>(try UnixConnection.connect(path: home.paths.socket))
        let line = try ControlCodec.encodeLine(
            ControlRequest(method: BoxMethod.wait, params: try .from(TermWaitParams(panes: [pane], timeout: 600))))
        try held.withLock { $0 }?.write(line, deadline: .now + .seconds(5))
        #expect(await eventually { await daemon.waiters.count == 1 })
        held.withLock { $0 = nil }
        #expect(await eventually(timeout: .seconds(5)) { await daemon.waiters.isEmpty })
    }

    /// A relayed call the host's relay script waits on: an acknowledgement, a heartbeat while it runs, then the reply.
    @Test func aLongRelayedCallSendsHeartbeatsThenItsReply() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let server = try BoxServer(daemon: daemon, socketPath: home.paths.socket, heartbeat: .milliseconds(100))
        defer { server.close() }
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let request = RelayRequest(
            version: "v", args: ["term", "wait", pane, "--timeout", "1"], cwd: "/", env: [:], stdin: nil, age: 0)
        let relay = try BoxClient(path: home.paths.socket)

        let ack = try await relay.exchange(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        var beats = 0
        var reply: String?
        while let line = try await relay.readLine() {
            if line == #"{"alive": true}"# {
                beats += 1
            } else {
                reply = line
                break
            }
        }

        #expect(ack == #"{"ack": true}"#)
        #expect(beats >= 2)
        let data = Data(try #require(reply).utf8)
        #expect((try? JSONDecoder().decode(RelayReply.self, from: data)) != nil)
    }

    /// A relayed call whose host process went away stops, rather than holding its thread until its timeout.
    @Test func aRelayedCallStopsWhenItsCallerHangsUp() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let server = try BoxServer(daemon: daemon, socketPath: home.paths.socket)
        defer { server.close() }
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let request = RelayRequest(
            version: "v", args: ["term", "wait", pane, "--timeout", "600"], cwd: "/", env: [:], stdin: nil, age: 0)
        let held = Shared<UnixConnection?>(try UnixConnection.connect(path: home.paths.socket))
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try held.withLock { $0 }?.write(line, deadline: .now + .seconds(5))
        #expect(await eventually { await daemon.waiters.count == 1 })

        held.withLock { $0 = nil }

        #expect(await eventually(timeout: .seconds(5)) { await daemon.waiters.isEmpty })
    }

    /// A hook's report lands even when the hook's process is gone before the reply, as Claude Code does not wait.
    @Test func aHookLandsAfterItsCallerHangsUp() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let server = try BoxServer(daemon: daemon, socketPath: home.paths.socket)
        defer { server.close() }
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let input = Data(#"{"hook_event_name": "UserPromptSubmit", "session_id": "s"}"#.utf8)
        let request = RelayRequest(
            version: "v", args: ["agent-hook"], cwd: "/", env: ["CANOPY_PANE": pane],
            stdin: input.base64EncodedString(), age: 0)
        let held = Shared<UnixConnection?>(try UnixConnection.connect(path: home.paths.socket))
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try held.withLock { $0 }?.write(line, deadline: .now + .seconds(5))

        held.withLock { $0 = nil }

        #expect(await eventually { await daemon.snapshot().panes.first?.agent == .working })
    }

    @Test func typedKeysMoveTheAgentWithoutReachingThePane() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await daemon.report(pane: pane, AgentReport(state: .working, session: "s"))
        let response = await BoxServer.handle(
            ControlRequest(method: BoxMethod.typed, params: try .from(BoxKeysParams(pane: pane, keys: ["\u{1b}"]))),
            daemon: daemon)
        #expect(response.error == nil)
        #expect(await daemon.snapshot().panes.first?.agent == AgentState.none)
    }

    @Test func readSaysWhyTmuxFailed() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        await home.server.tmux.killSession(pane)
        await #expect(throws: BoxErrors.paneNotFound(pane)) { try await daemon.read(pane: pane, lines: nil) }
    }
}
