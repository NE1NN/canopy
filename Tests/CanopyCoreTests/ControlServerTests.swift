import Foundation
import Synchronization
import Testing

@testable import CanopyCore

final class RecordingUI: ControlUIBridge {
    let selected = Mutex<[String]>([])

    func selectRow(path: String) async {
        selected.withLock { $0.append(path) }
    }
}

struct ControlServerTests {
    func startServer(_ dir: TempDir, github: GitHubCLI = GitHubCLI()) async throws
        -> (Workspace, ControlServer, ControlClient, RecordingUI)
    {
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home, git: Fixture.git, github: github)
        try await workspace.start()
        let ui = RecordingUI()
        let rows = await MainActor.run { RowLifecycle(workspace: workspace, terminals: Fixture.terminals(dir)) }
        let handler = WorkspaceControlHandler(rows: rows, ui: ui)
        let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
        try await server.start()
        // Creating rows runs git and setup, which a loaded CI runner can take well over 10 seconds to finish.
        return (workspace, server, ControlClient(socketPath: home.socketPath, timeout: 60), ui)
    }

    func call<T: Decodable & Sendable>(
        _ client: ControlClient, _ method: String, _ params: some Encodable, as: T.Type
    ) async throws -> T {
        let request = ControlRequest(method: method, params: try .from(params))
        let response = try await offPool { try client.send(request) }
        if let error = response.error { throw error }
        return try #require(response.result).decode(T.self)
    }

    @Test func socketIsPrivateAndRejectsSecondServer() async throws {
        let dir = try TempDir()
        let (_, server, _, _) = try await startServer(dir)
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: dir.sub("home/canopy.sock"))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let second = ControlServer(socketPath: dir.sub("home/canopy.sock")) { _ in .success(id: "", result: .null) }
        await #expect(throws: ControlServerError.alreadyRunning(dir.sub("home/canopy.sock"))) {
            try await second.start()
        }
    }

    @Test func replacesStaleSocketFile() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        FileManager.default.createFile(atPath: home.socketPath, contents: Data())

        let server = ControlServer(socketPath: home.socketPath) { .success(id: $0.id, result: .bool(true)) }
        try await server.start()
        defer { server.stop() }

        let socketPath = home.socketPath
        let response = try await offPool {
            try ControlClient(socketPath: socketPath).send(ControlRequest(method: "ping"))
        }
        #expect(response.result == .bool(true))
    }

    @Test func repoAndRowFlowOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let (_, server, client, ui) = try await startServer(dir)
        defer { server.stop() }

        let status = try await call(client, ControlMethod.status, JSONValue.null, as: StatusResult.self)
        #expect(status.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(status.running)

        let added = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        #expect(added.name == "demo")

        let created = try await call(
            client,
            ControlMethod.rowNew,
            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", select: true),
            as: RowNewResult.self
        )
        #expect(created.row.branch == "feat/cli")
        #expect(created.setup.status == .none)
        #expect(created.pane == nil)
        #expect(ui.selected.withLock { $0 } == [created.row.path])

        let rows = try await call(client, ControlMethod.rowList, RowListParams(), as: [Row].self)
        #expect(rows.map(\.branch) == ["main", "feat/cli"])

        let removed = try await call(
            client,
            ControlMethod.rowRemove,
            RowRemoveParams(target: TargetHint(envRepo: "demo", cwd: created.row.path), deleteBranch: true),
            as: RowRemoveResult.self
        )
        #expect(removed.row.path == created.row.path)
        #expect(removed.warnings.isEmpty)
    }

    @Test func shortRequestsLikeTheSpecsExampleAreAccepted() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)

        // Without a target the app cannot tell which repo is meant, but the params themselves are fine.
        let untargeted = try await offPool {
            try client.send(
                ControlRequest(
                    method: ControlMethod.rowNew,
                    params: .object(["branch": .string("fix/x"), "run": .string("echo hi")])))
        }
        #expect(untargeted.error?.code == "missing_target")

        let created = try await call(
            client, ControlMethod.rowNew,
            JSONValue.object([
                "branch": .string("fix/x"), "run": .string(#"echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran""#),
                "target": .object(["repo": .string("demo")]),
            ]),
            as: RowNewResult.self
        )
        let pane = try #require(created.pane)
        #expect(
            await eventually { (try? String(contentsOfFile: dir.sub("ran"), encoding: .utf8)) == "\(pane)\n" })

        let rows = try await call(client, ControlMethod.rowList, JSONValue.object([:]), as: [Row].self)
        #expect(rows.map(\.branch) == ["main", "fix/x"])
        _ = try await call(
            client, ControlMethod.rowRemove,
            JSONValue.object([
                "target": .object(["repo": .string("demo"), "row": .string("fix/x")]), "force": .bool(true),
            ]), as: RowRemoveResult.self)
    }

    @Test func termCommandsDriveTerminals() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")
        func read(_ pane: String) async -> String {
            (try? await call(client, TermMethod.read, TermReadParams(pane: pane), as: TermReadResult.self))?.text ?? ""
        }

        let first = try await call(
            client, TermMethod.new, TermNewParams(target: target, title: "Server"), as: TermNewResult.self)
        let second = try await call(
            client, TermMethod.new, TermNewParams(target: target, run: "echo from-second"), as: TermNewResult.self)
        #expect(first.tab == second.tab)
        #expect(await eventually { await read(second.pane).contains("from-second") })

        _ = try await call(
            client, TermMethod.send, TermSendParams(pane: first.pane, text: "echo typed-in", enter: true),
            as: JSONValue.self)
        #expect(await eventually { await read(first.pane).contains("typed-in") })

        let listed = try await call(client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
        #expect(listed.map(\.pane) == [first.pane, second.pane])
        #expect(listed.first?.title == "Server")
        #expect(listed.first?.folder == repo)

        _ = try await call(
            client, TermMethod.send, TermSendParams(pane: second.pane, text: "sleep 30", enter: true),
            as: JSONValue.self)
        #expect(
            await eventually {
                let panes = try? await call(client, TermMethod.list, TermListParams(all: true), as: [TermInfo].self)
                return panes?.last?.foreground == "sleep"
            })
        await #expect(throws: ControlError.self) {
            try await call(client, TermMethod.close, TermCloseParams(pane: second.pane), as: JSONValue.self)
        }
        for pane in [first.pane, second.pane] {
            _ = try await call(client, TermMethod.close, TermCloseParams(pane: pane, force: true), as: JSONValue.self)
        }
        #expect(try await call(client, TermMethod.list, TermListParams(all: true), as: [TermInfo].self).isEmpty)

        let typo = try await offPool {
            try client.send(
                ControlRequest(
                    method: TermMethod.list,
                    params: try .from(TermListParams(target: TargetHint(repo: "demo", row: "fix/nope")))))
        }
        #expect(typo.error?.code == "row_not_found")

        let missing = try await offPool {
            try client.send(ControlRequest(method: TermMethod.read, params: try .from(TermReadParams(pane: "p999"))))
        }
        #expect(missing.error?.code == "pane_not_found")
    }

    @Test func prShowAnswersOverTheSocket() async throws {
        let dir = try TempDir()
        let gh = try FakeGH(dir)
        gh.answer([0: (5, "OPEN")])
        let (workspace, server, client, _) = try await startServer(dir, github: gh.cli)
        defer { server.stop() }
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.git.run(["remote", "add", "origin", "https://github.com/NE1NN/canopy.git"], in: repo)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        try await workspace.addRepo(path: repo)

        let shown = try await call(
            client, ControlMethod.prShow, PRShowParams(target: TargetHint(row: "feat/a")), as: PRShowResult.self)

        #expect(shown.pr?.number == 5)
        #expect(shown.branch == "feat/a")
        #expect(shown.repo == "demo")
        let request = ControlRequest(
            method: ControlMethod.prShow, params: .object(["target": .object(["row": .string("main")])]))
        let main = try await offPool { try client.send(request) }
        #expect(main.error?.code == "no_pr_lookup")
    }

    @Test func errorsCarryCodes() async throws {
        let dir = try TempDir()
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }

        let unknown = try await offPool { try client.send(ControlRequest(method: "nope")) }
        #expect(unknown.error?.code == "unknown_method")

        let badVersion = try await offPool { try client.send(ControlRequest(method: ControlMethod.status, v: 99)) }
        #expect(badVersion.error?.code == "version_mismatch")

        let missingRequest = ControlRequest(
            method: ControlMethod.repoAdd, params: try .from(RepoAddParams(path: dir.sub("nope"))))
        let missingRepo = try await offPool { try client.send(missingRequest) }
        #expect(missingRepo.error?.code == "path_not_found")

        let badParams = try await offPool {
            try client.send(ControlRequest(method: ControlMethod.repoAdd, params: .string("x")))
        }
        #expect(badParams.error?.code == "bad_params")
    }

    @Test func malformedLineGetsBadRequest() async throws {
        let dir = try TempDir()
        let (_, server, _, _) = try await startServer(dir)
        defer { server.stop() }

        let socketPath = dir.sub("home/canopy.sock")
        let reply = try await offPool { () throws -> Data in
            let fd = try ControlClient.connect(to: socketPath)
            defer { close(fd) }
            _ = "not json\n".withCString { write(fd, $0, strlen($0)) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            return Data(buffer[0..<max(count, 0)].prefix { $0 != 0x0A })
        }
        let response = try ControlCodec.decode(ControlResponse.self, from: reply)
        #expect(response.error?.code == "bad_request")
    }

    /// Sends `payload` on a raw connection, optionally closes the write side, and reads until `lines` replies arrive.
    func exchange(_ socketPath: String, _ payload: Data, halfClose: Bool = false, lines: Int = 1) async throws
        -> [String]
    {
        try await offPool {
            let fd = try ControlClient.connect(to: socketPath)
            defer { close(fd) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            if halfClose { shutdown(fd, SHUT_WR) }
            var received = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while received.filter({ $0 == 0x0A }).count < lines {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                received.append(contentsOf: chunk[0..<count])
            }
            return String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }

    @Test func halfClosedConnectionsStillGetTheirReply() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let server = ControlServer(socketPath: home.socketPath) { request in
            try? await Task.sleep(for: .milliseconds(200))
            return .success(id: request.id, result: .bool(true))
        }
        try await server.start()
        defer { server.stop() }

        let replies = try await exchange(
            home.socketPath, try ControlCodec.encodeLine(ControlRequest(method: "slow", id: "a")), halfClose: true)

        #expect(replies.count == 1)
        #expect(replies.first?.contains(#""id":"a""#) == true)
    }

    @Test func repliesComeInRequestOrder() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let server = ControlServer(socketPath: home.socketPath) { request in
            if request.id == "first" { try? await Task.sleep(for: .milliseconds(300)) }
            return .success(id: request.id, result: .null)
        }
        try await server.start()
        defer { server.stop() }
        var payload = try ControlCodec.encodeLine(ControlRequest(method: "x", id: "first"))
        payload.append(try ControlCodec.encodeLine(ControlRequest(method: "x", id: "second")))

        let replies = try await exchange(home.socketPath, payload, lines: 2)

        #expect(replies.map { $0.contains(#""id":"first""#) } == [true, false])
    }

    @Test func overLongLinesAreRejected() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let server = ControlServer(socketPath: home.socketPath) { .success(id: $0.id, result: .null) }
        try await server.start()
        defer { server.stop() }

        let replies = try await exchange(home.socketPath, Data(repeating: 0x61, count: (1 << 20) + 10))

        #expect(replies.first?.contains("bad_request") == true)
    }

    @Test func serverRejectsASocketPathOverTheLimit() async {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/canopy.sock"
        await #expect(throws: ControlServerError.socketPathTooLong(path)) {
            try await ControlServer(socketPath: path) { .success(id: $0.id, result: .null) }.start()
        }
    }

    @Test func socketPathOverTheLimitFailsClearly() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/canopy.sock"
        #expect(throws: ControlClientError.socketPathTooLong(path)) {
            try ControlClient(socketPath: path).send(ControlRequest(method: ControlMethod.status))
        }
    }

    @Test func clientReportsAppNotRunning() {
        do {
            _ = try ControlClient(socketPath: "/tmp/canopy-definitely-missing.sock").send(
                ControlRequest(method: "status"))
            Issue.record("expected failure")
        } catch let error as ControlClientError {
            #expect(error.isAppNotRunning)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
