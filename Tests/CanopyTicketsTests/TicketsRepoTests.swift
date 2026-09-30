import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

/// The `repo` setting, and the AGENTS.md and CLAUDE.md it puts in ticket rows' folders.
@MainActor
struct TicketsRepoTests {
    let id853 = "0000000000000000000010001tickets"

    func connected(_ dir: TempDir) async throws -> TicketsHarness {
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await harness.connect(token: "t")
        return harness
    }

    /// A repo at `dir/<folder>/<name>` cloned from a bare origin, so `origin/HEAD` points at main, registered in the
    /// harness's workspace.
    @discardableResult
    func addRepo(_ harness: TicketsHarness, _ dir: TempDir, name: String = "app", folder: String = "a") async throws
        -> String
    {
        let git = GitRunner(environment: ["PATH": "/usr/bin:/bin"])
        let origin = dir.sub("\(folder)-\(name)-origin.git")
        let seed = dir.sub("\(folder)-\(name)-seed")
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "--bare", "-b", "main", origin])
        try await git.run(["init", "--quiet", "-b", "main"], in: seed)
        try await git.run(
            [
                "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--quiet", "--allow-empty", "-m",
                "init",
            ],
            in: seed)
        try await git.run(["push", "--quiet", origin, "main"], in: seed)
        try FileManager.default.createDirectory(atPath: dir.sub(folder), withIntermediateDirectories: true)
        let path = dir.sub(folder) + "/" + name
        try await git.run(["clone", "--quiet", origin, path])
        _ = try await harness.workspace.addRepo(path: path)
        return Paths.canonical(path)
    }

    func agents(_ row: PluginRow) -> String? {
        try? String(contentsOfFile: row.path + "/AGENTS.md", encoding: .utf8)
    }

    func claude(_ row: PluginRow) -> String? {
        try? String(contentsOfFile: row.path + "/CLAUDE.md", encoding: .utf8)
    }

    // MARK: Writing the files

    @Test func aNewRowGetsAgentFilesNamingTheRepo() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let path = try await addRepo(harness, dir)
        try await harness.setConfig(["repo": "app"])

        let row = try await harness.newRow("853")

        #expect(agents(row) == TicketAgentFiles.agents(.repo(name: "app", path: path, defaultBranch: "main")))
        #expect(claude(row) == "@AGENTS.md\n")
    }

    @Test func aNewRowWithoutASettingSaysCanopyDoesNotKnow() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        try await addRepo(harness, dir)

        let row = try await harness.newRow("853")

        #expect(agents(row) == TicketAgentFiles.agents(.notSet))
        #expect(claude(row) == "@AGENTS.md\n")
    }

    @Test func aNameCanopyHasNoRepoForSaysSo() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        try await harness.setConfig(["repo": "gone"])

        let row = try await harness.newRow("853")

        #expect(agents(row) == TicketAgentFiles.agents(.notRegistered(name: "gone")))
    }

    @Test func aRowWhoseTicketCannotBeFetchedStillGetsThem() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        _ = try await harness.call(TicketMethod.list, TicketListParams())
        await harness.transport.fail("/api/v1/tickets/\(id853)", URLError(.cannotConnectToHost))

        let created = try await harness.call(TicketMethod.new, TicketNewParams(reference: id853))
            .decode(PluginRowCreated.self)

        #expect(created.fillError != nil)
        #expect(agents(created.row) == TicketAgentFiles.agents(.notSet))
    }

    @Test func rowsGetAgentFilesWhenThePluginStarts() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let path = try await addRepo(harness, dir)
        try await harness.setConfig(["repo": "app"])
        let row = try await harness.newRow("853")
        // A row made before Canopy wrote these files, and a ticket-manager that answers nothing.
        for name in ["AGENTS.md", "CLAUDE.md"] {
            try FileManager.default.removeItem(atPath: row.path + "/" + name)
        }
        await harness.transport.failEverything(URLError(.cannotConnectToHost))

        let relaunched = try await harness.restart()
        defer { relaunched.close() }

        #expect(await eventually { self.claude(row) == "@AGENTS.md\n" })
        #expect(agents(row) == TicketAgentFiles.agents(.repo(name: "app", path: path, defaultBranch: "main")))
    }

    @Test func aMovedRepoIsFoundAtItsNewPathOnTheNextWrite() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let old = try await addRepo(harness, dir, folder: "a")
        try await harness.setConfig(["repo": "app"])
        let row = try await harness.newRow("853")
        #expect(agents(row)?.contains(old) == true)

        try await harness.workspace.removeRepo(path: old)
        let new = try await addRepo(harness, dir, folder: "b")
        _ = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853", refresh: true))

        #expect(agents(row) == TicketAgentFiles.agents(.repo(name: "app", path: new, defaultBranch: "main")))
    }

    @Test func aFetchThatChangesNothingLeavesTheFilesAlone() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        try await addRepo(harness, dir)
        try await harness.setConfig(["repo": "app"])
        let row = try await harness.newRow("853")
        let inode = { (name: String) in
            try FileManager.default.attributesOfItem(atPath: row.path + "/" + name)[.systemFileNumber] as? Int
        }
        let (agentsFile, claudeFile) = (try inode("AGENTS.md"), try inode("CLAUDE.md"))

        _ = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853", refresh: true))

        #expect(try inode("AGENTS.md") == agentsFile && inode("CLAUDE.md") == claudeFile)
    }

    // MARK: Setting it

    func setRepo(_ harness: TicketsHarness, _ repo: String?) async throws -> TicketRepoResult {
        try await harness.call(TicketMethod.setRepo, TicketSetRepoParams(repo: repo)).decode(TicketRepoResult.self)
    }

    func savedRepo(_ harness: TicketsHarness) throws -> JSONValue? {
        guard case .object(let fields)? = try PluginConfig.sections(in: harness.home.configFile)["tickets"] else {
            return nil
        }
        return fields["repo"]
    }

    @Test func connectWithRepoSavesItsNameEvenFromAPath() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        let path = try await addRepo(harness, dir)

        _ = try await harness.call(
            TicketMethod.connect, TicketConnectParams(url: harness.url, token: "t", repo: path))

        #expect(try savedRepo(harness) == "app")
        let row = try await harness.newRow("853")
        #expect(agents(row)?.contains("at `\(path)`") == true)
    }

    @Test func connectWithAnUnknownRepoSavesNothing() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")

        await #expect {
            try await harness.call(
                TicketMethod.connect, TicketConnectParams(url: harness.url, token: "t", repo: "nope"))
        } throws: {
            let error = $0 as? ControlError
            return error?.code == "repo_not_found"
                && error?.message
                    == #"Canopy has no repo named "nope", and none are registered. Add one with `canopy repo add <path>`."#
        }
        try await addRepo(harness, dir, name: "app")
        try await addRepo(harness, dir, name: "web")
        await #expect {
            try await harness.call(
                TicketMethod.connect, TicketConnectParams(url: harness.url, token: "t", repo: "nope"))
        } throws: {
            ($0 as? ControlError)?.message == #"Canopy has no repo named "nope". Registered repos: app, web."#
        }

        #expect(await harness.transport.requests.isEmpty)
        #expect(try harness.secrets.read("token") == nil)
        #expect(try PluginConfig.sections(in: harness.home.configFile)["tickets"] == nil)
    }

    @Test func connectWithoutRepoKeepsTheSetting() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await addRepo(harness, dir)
        _ = try await harness.call(TicketMethod.connect, TicketConnectParams(url: harness.url, token: "t", repo: "app"))

        try await harness.connect(token: "t")

        #expect(try savedRepo(harness) == "app")
    }

    @Test func settingTheRepoRewritesEveryRowWithoutRestarting() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let path = try await addRepo(harness, dir)
        let rows = [try await harness.newRow("853"), try await harness.newRow("849")]
        let generation = await harness.plugin.generation

        let result = try await setRepo(harness, "app")

        #expect(result == TicketRepoResult(repo: "app", path: path, defaultBranch: "main", registered: ["app"]))
        #expect(try savedRepo(harness) == "app")
        for row in rows {
            #expect(agents(row) == TicketAgentFiles.agents(.repo(name: "app", path: path, defaultBranch: "main")))
        }
        #expect(await harness.plugin.generation == generation)
        #expect(harness.store.ticket(id853).detail != nil)
    }

    @Test func clearingTheRepoPutsTheFirstTextBack() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        try await addRepo(harness, dir)
        let row = try await harness.newRow("853")
        _ = try await setRepo(harness, "app")

        let result = try await setRepo(harness, nil)

        #expect(result == TicketRepoResult(repo: nil, path: nil, defaultBranch: nil, registered: ["app"]))
        #expect(try savedRepo(harness) == nil)
        #expect(agents(row) == TicketAgentFiles.agents(.notSet))
    }

    @Test func settingAnUnknownRepoChangesNothing() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        try await addRepo(harness, dir)
        _ = try await setRepo(harness, "app")

        await #expect { try await setRepo(harness, "nope") } throws: {
            ($0 as? ControlError)?.message == #"Canopy has no repo named "nope". Registered repos: app."#
        }
        #expect(try savedRepo(harness) == "app")
    }

    @Test func readingTheRepoSaysWhereItIs() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        func read() async throws -> TicketRepoResult {
            try await harness.call(TicketMethod.repo, JSONValue.object([:])).decode(TicketRepoResult.self)
        }
        #expect(try await read() == TicketRepoResult(repo: nil, path: nil, defaultBranch: nil, registered: []))

        try await harness.setConfig(["repo": "app"])
        #expect(try await read() == TicketRepoResult(repo: "app", path: nil, defaultBranch: nil, registered: []))

        let path = try await addRepo(harness, dir)
        #expect(
            try await read() == TicketRepoResult(repo: "app", path: path, defaultBranch: "main", registered: ["app"]))
        #expect(TicketMethod.readOnly.contains(TicketMethod.repo))
        #expect(!TicketMethod.readOnly.contains(TicketMethod.setRepo))
    }

    @Test func settingTheRepoWhileOffFailsWithPluginOff() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await addRepo(harness, dir)

        await #expect { try await setRepo(harness, "app") } throws: { errorCode($0) == "plugin_off" }
        #expect(try PluginConfig.sections(in: harness.home.configFile)["tickets"] == nil)
    }

    @Test func theResultEncodesEveryFieldForAgents() throws {
        let json = try JSONValue.from(TicketRepoResult(repo: nil, path: nil, defaultBranch: nil, registered: []))
        #expect(
            json
                == .object([
                    "repo": .null, "path": .null, "defaultBranch": .null, "missing": false, "registered": .array([]),
                ]))
    }
}
