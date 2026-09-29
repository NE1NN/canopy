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
    func startServer(
        _ dir: TempDir, git: GitRunner = Fixture.git, github: GitHubCLI = GitHubCLI(), logsCommands: Bool = true
    ) async throws -> (Workspace, ControlServer, ControlClient, RecordingUI) {
        let home = CanopyHome(path: dir.sub("home"))
        let activity = ActivityLog(folder: home.activityFolder, logsCommands: logsCommands)
        let workspace = Workspace(home: home, git: git, github: github, activity: activity)
        try await workspace.start()
        let ui = RecordingUI()
        let (rows, plugins) = await MainActor.run {
            let terminals = Fixture.terminals(dir)
            return (
                RowLifecycle(workspace: workspace, terminals: terminals),
                PluginHost(
                    workspace: workspace, terminals: terminals, plugins: [], secrets: MemorySecretStore(),
                    bundleID: "test", trash: MovingTrash(into: dir.sub("trash")))
            )
        }
        let handler = WorkspaceControlHandler(rows: rows, plugins: plugins, ui: ui)
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

    @Test func portsAnswerOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let feature = dir.sub("home/worktrees/demo/feat-web")
        try await Fixture.worktree(repo: repo, branch: "feat/web", at: feature)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        // Started in the main row's terminal but working in /, so only the terminal ties it to the row.
        let listener = "cd / && perl -MIO::Socket::INET -e '\(ListeningChild.bindSparePort) sleep 120'"
        let pane = try await call(
            client, TermMethod.new, TermNewParams(target: TargetHint(repo: "demo", row: "main"), run: listener),
            as: TermNewResult.self)
        // Started outside Canopy, in the feature row's folder.
        let outside = try await ListeningChild.start(in: feature)
        defer { outside.process.terminate() }
        // A port from the system's random range, like an agent's MCP server, is not something to open or stop.
        let tool = try await ListeningChild.start(in: feature, anyPort: true)
        defer { tool.process.terminate() }

        var all: [PortInfo] = []
        #expect(
            await eventually {
                all = (try? await call(client, PortMethod.list, PortsListParams(all: true), as: [PortInfo].self)) ?? []
                return all.count == 2
            })
        #expect(all.map(\.row) == ["main", "feat/web"])
        #expect(all.first?.process == "perl")
        #expect(all.last?.port == Int(outside.port.port))
        let featureOnly = try await call(
            client, PortMethod.list, PortsListParams(target: TargetHint(repo: "demo", row: "feat/web")),
            as: [PortInfo].self)
        #expect(featureOnly.map(\.pid) == [outside.port.pid])
        #expect(!all.contains { $0.pid == tool.port.pid })
        // An agent in the main row stopping the feature row's port is refused, unless it asks for any row.
        let fromMain = try await offPool {
            try client.send(
                ControlRequest(
                    method: PortMethod.stop,
                    params: try .from(
                        PortsStopParams(port: Int(outside.port.port), target: TargetHint(repo: "demo", row: "main")))))
        }
        #expect(fromMain.error?.code == "port_in_other_row")
        #expect(fromMain.error?.message.contains("feat/web") == true)

        let stopped = try await call(
            client, PortMethod.stop,
            PortsStopParams(port: Int(outside.port.port), target: TargetHint(repo: "demo", row: "main"), all: true),
            as: PortsStopResult.self)

        #expect(stopped.stopped.map(\.pid) == [outside.port.pid])
        #expect(stopped.killed.isEmpty)
        #expect(await eventually { !outside.process.isRunning })
        // This test process listens too, but its folder is no row's, so the port is not Canopy's to stop.
        let stranger = try Listener()
        let strangerPort = Int(stranger.port)
        let refused = try await offPool {
            try client.send(
                ControlRequest(method: PortMethod.stop, params: try .from(PortsStopParams(port: strangerPort))))
        }
        #expect(refused.error?.code == "port_not_found")
        _ = stranger
        _ = try await call(client, TermMethod.close, TermCloseParams(pane: pane.pane, force: true), as: JSONValue.self)
    }

    @Test func callsThatChangeSomethingAreLoggedAsTheCLIs() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }

        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let params = RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", setup: false, run: "echo hi")
        let created = try await call(client, ControlMethod.rowNew, params, as: RowNewResult.self)
        _ = try await call(client, ControlMethod.rowList, RowListParams(), as: [Row].self)
        _ = try await call(
            client, TermMethod.read, TermReadParams(pane: try #require(created.pane)), as: JSONValue.self)
        await #expect(throws: ControlError.self) {
            _ = try await call(
                client, ControlMethod.rowNew, RowNewParams(target: TargetHint(repo: "demo"), branch: "bad name"),
                as: JSONValue.self)
        }

        let events = await logged(workspace, "repo", "row", "cli")
        #expect(events.map(\.type) == ["repo.added", "cli.call", "row.created", "cli.call", "cli.call"])
        #expect(events.allSatisfy { $0.source == .cli })
        let calls = events.filter { $0.type == ActivityType.cliCall }
        try #require(calls.map(\.data["method"]) == ["repo.add", "row.new", "row.new"])
        #expect(calls[1].data["params"] == (try JSONValue.from(params)))
        #expect(calls.map(\.data["error"]) == [nil, nil, "invalid_branch"])
    }

    @Test func repoCloneAnswersLikeRepoAddAndIsLogged() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let (workspace, server, client, _) = try await startServer(dir, github: try Fixture.cloningGH(in: dir))
        defer { server.stop() }

        let cloned = try await call(
            client, ControlMethod.repoClone, RepoCloneParams(source: "acme/app"), as: RepoInfo.self)
        let again = try await call(client, ControlMethod.repoClone, ["source": "acme/app"], as: RepoInfo.self)

        #expect(cloned.name == "app")
        #expect(cloned.path == dir.sub("home/repos/acme/app"))
        #expect(cloned.rows == 1)
        #expect(again == cloned)
        let events = await logged(workspace, "repo", "cli")
        #expect(events.map(\.type) == ["repo.added", "cli.call", "cli.call"])
        #expect(events.allSatisfy { $0.source == .cli })
        #expect(events[0].data["clonedFrom"] == "acme/app")
        #expect(events[1].data["method"] == "repo.clone")
        #expect(events[1].data["params"] == .object(["source": .string("acme/app")]))
    }

    @Test func aCloneKeepsGoingWhenTheCLIGoesAway() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let started = dir.sub("started")
        let gh = try Fixture.cloningGH(in: dir, before: "touch '\(started)'; sleep 1")
        let (workspace, server, _, _) = try await startServer(dir, github: gh)
        defer { server.stop() }

        // Like Ctrl-C on `canopy repo clone`: the request goes out, and the connection closes before the reply.
        let request = ControlRequest(
            method: ControlMethod.repoClone, params: try .from(RepoCloneParams(source: "acme/app")))
        let socketPath = CanopyHome(path: dir.sub("home")).socketPath
        try await offPool {
            let fd = try ControlClient.connect(to: socketPath)
            _ = try ControlCodec.encodeLine(request).withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: started), Date() < deadline { usleep(20_000) }
            close(fd)
        }

        #expect(await eventually { await workspace.snapshot.repos.map(\.name) == ["app"] })
    }

    @Test func repoCloneErrorsCarryCodes() async throws {
        let dir = try TempDir()
        let taken = try await Fixture.repo(in: dir, name: "taken")
        let (_, server, client, _) = try await startServer(dir, github: try Fixture.cloningGH(in: dir))
        defer { server.stop() }

        func code(_ params: RepoCloneParams) async throws -> String? {
            let request = ControlRequest(method: ControlMethod.repoClone, params: try .from(params))
            return try await offPool { try client.send(request) }.error?.code
        }

        #expect(try await code(RepoCloneParams(source: "acme/app", into: taken)) == "folder_taken")
        #expect(try await code(RepoCloneParams(source: "acme/nope")) == "clone_failed")
        #expect(try await code(RepoCloneParams(source: "nope")) == "invalid_clone_source")
        #expect(try await code(RepoCloneParams(source: "acme/app", into: "relative/app")) == "bad_params")
    }

    @Test func commandTextIsLeftOutOfCallsWhenCommandLoggingIsOff() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir, logsCommands: false)
        defer { server.stop() }

        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let created = try await call(
            client, ControlMethod.rowNew,
            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", setup: false, run: "echo secret-run"),
            as: RowNewResult.self)
        _ = try await call(
            client, TermMethod.send, TermSendParams(pane: try #require(created.pane), text: "echo secret-text"),
            as: JSONValue.self)

        let calls = await logged(workspace, "cli")
        try #require(calls.count == 3)
        guard case .object(let rowNew) = calls[1].data["params"], case .object(let send) = calls[2].data["params"]
        else {
            Issue.record("params are not objects")
            return
        }
        #expect(rowNew["branch"] == "feat/cli" && rowNew["run"] == nil)
        #expect(send["pane"] == .string(created.pane!) && send["text"] == nil)
    }

    @Test func textStartingWithASpaceIsLeftOutOfCalls() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }

        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let created = try await call(
            client, ControlMethod.rowNew,
            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", setup: false, run: "true"),
            as: RowNewResult.self)
        let pane = try #require(created.pane)
        _ = try await call(client, TermMethod.send, TermSendParams(pane: pane, text: " hunter2"), as: JSONValue.self)
        _ = try await call(client, TermMethod.send, TermSendParams(pane: pane, text: "ls"), as: JSONValue.self)

        let sends = await logged(workspace, "cli").filter { $0.data["method"] == "term.send" }
        let texts = sends.map { event -> JSONValue? in
            guard case .object(let params) = event.data["params"] else { return nil }
            return params["text"]
        }
        #expect(texts == [nil, "ls"])
    }

    @Test func rowNewStartsFromAPullRequest() async throws {
        let dir = try TempDir()
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split")
        let repo = try await github.clone("acme/app")
        let (_, server, client, _) = try await startServer(dir, git: github.git, github: github.gh)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)

        let created = try await call(
            client, ControlMethod.rowNew,
            JSONValue.object([
                "pr": .string("https://github.com/acme/app/pull/7/files"), "target": .object(["repo": .string("demo")]),
            ]),
            as: RowNewResult.self)

        #expect(created.row.branch == "feat/split")
        #expect(created.source == .origin)
        #expect(created.pr?.number == 7)
    }

    @Test func pullRequestAndBranchListsAnswerOverTheSocket() async throws {
        let dir = try TempDir()
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.push(to: "feat/other", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split", title: "Split checkout")
        try await github.openPR(8, on: "acme/app", from: "feat/other", state: "MERGED")
        let repo = try await github.clone("acme/app")
        let (workspace, server, client, _) = try await startServer(dir, git: github.git, github: github.gh)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/split", existing: true).row
        let target = TargetHint(repo: "demo")

        let open = try await call(
            client, ControlMethod.prList, PRListParams(target: target), as: [ListedPullRequest].self)
        let all = try await call(
            client, ControlMethod.prList, PRListParams(target: target, closed: true), as: [ListedPullRequest].self)
        let merged = try await call(
            client, ControlMethod.prList, PRListParams(target: target, query: "#8"), as: [ListedPullRequest].self)
        let branches = try await call(
            client, ControlMethod.branchList, BranchListParams(target: target, query: "feat"), as: BranchListing.self)

        #expect(open.map(\.number) == [7])
        #expect(open.first?.row == BranchHolder(row))
        #expect(Set(all.map(\.number)) == [7, 8])
        #expect(merged.map(\.state) == [.merged])
        #expect(Set(branches.branches.map(\.name)) == ["feat/split", "feat/other"])
        #expect(branches.branches.first { $0.name == "feat/split" }?.row == BranchHolder(row))
        #expect(branches.defaultBase == "origin/main")
    }

    @Test func rowNewRefusesOptionsThatDoNotGoTogether() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)

        func code(_ params: [String: JSONValue]) async throws -> String? {
            var params = params
            params["target"] = .object(["repo": .string("demo")])
            let request = ControlRequest(method: ControlMethod.rowNew, params: .object(params))
            return try await offPool { try client.send(request) }.error?.code
        }
        #expect(try await code([:]) == "bad_params")
        #expect(try await code(["pr": .number(7), "base": .string("main")]) == "bad_params")
        #expect(try await code(["pr": .number(7), "existing": .bool(true)]) == "bad_params")
        #expect(
            try await code(["branch": .string("feat/x"), "base": .string("main"), "existing": .bool(true)])
                == "bad_params")
        #expect(try await code(["pr": .string("feat/x")]) == "invalid_pr")
        #expect(try await code(["branch": .string("feat/typo"), "existing": .bool(true)]) == "branch_not_found")
        #expect(
            await Fixture.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/x"], in: repo) == false)
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

        let replies = try await exchange(dir.sub("home/canopy.sock"), Data("not json\n".utf8))

        let response = try ControlCodec.decode(ControlResponse.self, from: Data(try #require(replies.first).utf8))
        #expect(response.error?.code == "bad_request")
    }

    /// Sends `payload` on a raw connection, optionally closes the write side, and reads until `lines` replies arrive.
    /// The server may hang up before taking all of `payload`, so write errors are left to show as missing replies.
    func exchange(_ socketPath: String, _ payload: Data, halfClose: Bool = false, lines: Int = 1) async throws
        -> [String]
    {
        try await offPool {
            let fd = try ControlClient.connect(to: socketPath)
            defer { close(fd) }
            let stream = SocketStream(fd: fd, deadline: .now + .seconds(60))
            try? stream.write(payload)
            if halfClose { shutdown(fd, SHUT_WR) }
            var received = Data()
            while received.filter({ $0 == 0x0A }).count < lines {
                let chunk = try stream.read()
                guard !chunk.isEmpty else { break }
                received.append(chunk)
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

    /// Every child a test starts gets a copy of the client's socket and closes it as it starts. A port scan reading
    /// that copy at that moment drains the socket, and a read that sleeps on a drained socket fails with EBADF even
    /// once the reply is there, which failed a different test in about one loaded full run in six.
    @Test func aReplyArrivesOnADrainedSocket() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let server = ControlServer(socketPath: home.socketPath) { request in
            try? await Task.sleep(for: .milliseconds(300))
            return .success(id: request.id, result: .bool(true))
        }
        try await server.start()
        defer { server.stop() }
        let socketPath = home.socketPath

        let (drained, response) = try await offPool {
            let fd = try ControlClient.connect(to: socketPath)
            defer { close(fd) }
            let drained = drainSocket(fd)
            return (drained, try ControlClient(socketPath: socketPath).send(ControlRequest(method: "slow"), over: fd))
        }

        try #require(drained)
        #expect(response.result == .bool(true))
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

        #expect(replies.map { $0.contains(#""id":"first""#) } == [true, false], "\(replies)")
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
