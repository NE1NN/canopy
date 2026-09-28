import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct CloneTests {
    func makeWorkspace(_ dir: TempDir, github: GitHubCLI, git: GitRunner = Fixture.git) async throws -> Workspace {
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git, github: github)
        try await workspace.start()
        return workspace
    }

    func origin(of path: String) async throws -> String {
        try await Fixture.git.run(["remote", "get-url", "origin"], in: path).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// Everything in a folder, or nil when it does not exist.
    func contents(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }

    // MARK: Cloning

    @Test func clonesOwnerSlashRepoWithGHIntoReposOwnerName() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        let repo = try await workspace.cloneRepo("acme/app")

        #expect(repo.path == dir.sub("home/repos/acme/app"))
        #expect(repo.name == "app")
        #expect(repo.rows.map(\.branch) == ["main"])
        #expect(try await origin(of: repo.path) == "https://github.com/acme/app.git")
        #expect(await workspace.snapshot.repos.map(\.path) == [repo.path])
    }

    @Test func clonesURLsNotOnGitHubWithGit() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))

        let repo = try await workspace.cloneRepo("file://" + bare)

        #expect(repo.path == dir.sub("home/repos/team/lib"))
        #expect(repo.rows.map(\.branch) == ["main"])
    }

    @Test func clonesIntoTheFolderItIsGiven() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))

        let repo = try await workspace.cloneRepo(bare, into: dir.sub("elsewhere/my-lib"))

        #expect(repo.path == dir.sub("elsewhere/my-lib"))
        #expect(repo.name == "my-lib")
    }

    @Test func clonesIntoAnEmptyFolder() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        try FileManager.default.createDirectory(atPath: dir.sub("empty"), withIntermediateDirectories: true)
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))

        let repo = try await workspace.cloneRepo(bare, into: dir.sub("empty"))

        #expect(repo.path == dir.sub("empty"))
    }

    @Test func tellsHowTheCloneIsGoing() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let gh = try Fixture.cloningGH(in: dir, before: "echo 'Receiving objects:  50% (1/2)' >&2; sleep 1")
        let workspace = try await makeWorkspace(dir, github: gh)
        let heard = Mutex<[CloneProgress]>([])

        try await workspace.cloneRepo("acme/app") { progress in heard.withLock { $0.append(progress) } }

        #expect(heard.withLock { $0.first } == CloneProgress(phase: "Receiving objects", fraction: 0.5))
    }

    @Test func logsWhereTheRepoWasClonedFrom() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        let repo = try await ActivitySource.$current.withValue(.cli) { try await workspace.cloneRepo("acme/app") }

        let events = await logged(workspace, "repo")
        #expect(events.map(\.type) == ["repo.added"])
        #expect(events.first?.path == repo.path)
        #expect(events.first?.source == .cli)
        #expect(events.first?.data["clonedFrom"] == "acme/app")
    }

    // MARK: Without gh

    @Test func fallsBackToGitForAGitHubURLWhenGHIsMissing() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let workspace = try await makeWorkspace(
            dir, github: Fixture.noGH(in: dir), git: Fixture.gitRedirectingGitHub(to: dir))

        let repo = try await workspace.cloneRepo("https://github.com/acme/app.git")

        #expect(repo.path == dir.sub("home/repos/acme/app"))
        #expect(repo.rows.map(\.branch) == ["main"])
    }

    @Test func fallsBackToGitForAGitHubURLWhenGHIsLoggedOut() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let gh = try Fixture.gh(
            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
        let workspace = try await makeWorkspace(dir, github: gh, git: Fixture.gitRedirectingGitHub(to: dir))

        let repo = try await workspace.cloneRepo("https://github.com/acme/app")

        #expect(repo.rows.map(\.branch) == ["main"])
    }

    @Test func ownerSlashRepoNeedsGHAndSaysHowToGetIt() async throws {
        let dir = try TempDir()
        let missing = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))
        let other = try TempDir()
        let loggedOut = try await makeWorkspace(other, github: try Fixture.gh(in: other, "exit 4"))

        await #expect(
            throws: WorkspaceError.ghUnavailable(
                "Install gh to clone acme/app: `brew install gh`, then `gh auth login`. Or pass the repo's URL.")
        ) { try await missing.cloneRepo("acme/app") }
        await #expect(
            throws: WorkspaceError.ghUnavailable("Run `gh auth login` to clone acme/app, or pass the repo's URL.")
        ) { try await loggedOut.cloneRepo("acme/app") }
        #expect(contents(dir.sub("home/repos")) == nil)
    }

    // MARK: Folders that already exist

    @Test func registersAFolderThatAlreadyHoldsTheSameRepo() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let calls = dir.sub("calls")
        let workspace = try await makeWorkspace(
            dir, github: try Fixture.cloningGH(in: dir, before: "echo x >> '\(calls)'"))

        let first = try await workspace.cloneRepo("acme/app")
        try await workspace.removeRepo(path: first.path)
        let second = try await workspace.cloneRepo("ACME/App")

        #expect(second.path == first.path)
        #expect(try String(contentsOfFile: calls, encoding: .utf8) == "x\n")
        #expect(await workspace.snapshot.repos.map(\.path) == [first.path])
    }

    @Test(arguments: ["git@github.com:ACME/App.git", "git@github-work:acme/app.git", "ssh://git@github.com/acme/app"])
    func recognizesTheSameRepoClonedAnotherWay(origin: String) async throws {
        let dir = try TempDir()
        let sshConfig = dir.sub("ssh_config")
        try "Host github-work\n  HostName github.com\n".write(toFile: sshConfig, atomically: true, encoding: .utf8)
        let folder = dir.sub("home/repos/acme/app")
        try FileManager.default.createDirectory(atPath: dir.sub("home/repos/acme"), withIntermediateDirectories: true)
        try await Fixture.repo(in: dir, name: "home/repos/acme/app")
        try await Fixture.git.run(["remote", "add", "origin", origin], in: folder)
        let gh = try Fixture.gh(in: dir, sshConfigFile: sshConfig, "exit 1")
        let workspace = try await makeWorkspace(dir, github: gh)

        let repo = try await workspace.cloneRepo("acme/app")

        #expect(repo.path == folder)
    }

    @Test func refusesAFolderHoldingAnotherRepo() async throws {
        let dir = try TempDir()
        let folder = try await Fixture.repo(in: dir, name: "taken")
        try await Fixture.git.run(["remote", "add", "origin", "https://github.com/acme/other.git"], in: folder)
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(
            throws: WorkspaceError.folderTaken(folder, holding: "a clone of https://github.com/acme/other.git")
        ) {
            try await workspace.cloneRepo("acme/app", into: folder)
        }
        #expect(await workspace.snapshot.repos.isEmpty)
    }

    @Test func refusesAFolderHoldingARepoWithNoOrigin() async throws {
        let dir = try TempDir()
        let folder = try await Fixture.repo(in: dir, name: "local")
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(throws: WorkspaceError.folderTaken(folder, holding: "a repo with no origin")) {
            try await workspace.cloneRepo("acme/app", into: folder)
        }
    }

    @Test func refusesAFolderHoldingAnythingElseAndLeavesItAlone() async throws {
        let dir = try TempDir()
        let folder = dir.sub("home/repos/acme/app")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "notes".write(toFile: folder + "/notes.txt", atomically: true, encoding: .utf8)
        try "file".write(toFile: dir.sub("a-file"), atomically: true, encoding: .utf8)
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(throws: WorkspaceError.folderTaken(folder, holding: nil)) {
            try await workspace.cloneRepo("acme/app")
        }
        await #expect(throws: WorkspaceError.folderTaken(dir.sub("a-file"), holding: nil)) {
            try await workspace.cloneRepo("acme/app", into: dir.sub("a-file"))
        }
        #expect(contents(folder) == ["notes.txt"])
    }

    @Test func refusesASourceThatWouldLeaveTheReposFolder() async throws {
        let dir = try TempDir()
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(throws: WorkspaceError.invalidCloneSource("https://example.com/acme/..")) {
            try await workspace.cloneRepo("https://example.com/acme/..")
        }
        #expect(contents(dir.sub("home/repos")) == nil)
    }

    // MARK: Failing and stopping

    @Test func aFailedCloneLeavesNothingBehind() async throws {
        let dir = try TempDir()
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(
            throws: WorkspaceError.cloneFailed(
                "acme/nope",
                reason: "GraphQL: Could not resolve to a Repository with the name 'acme/nope'. (repository)")
        ) { try await workspace.cloneRepo("acme/nope") }

        #expect(contents(dir.sub("home/repos")) == nil)
    }

    @Test func aCloneThatFailsHalfwayLeavesNothingBehind() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        // git writes the whole clone, then fails the way a checkout can.
        let git = try Fixture.git(
            in: dir,
            before:
                #"[[ "$1" == clone ]] && { /usr/bin/git "$@"; echo 'fatal: unable to checkout working tree' >&2; exit 128; }"#
        )
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir), git: git)

        await #expect(throws: WorkspaceError.cloneFailed(bare, reason: "unable to checkout working tree")) {
            try await workspace.cloneRepo(bare, into: dir.sub("new/deeper/lib"))
        }

        #expect(contents(dir.sub("new")) == nil)
    }

    @Test func cancellingStopsTheCloneAndDeletesWhatItWrote() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let sleeper = dir.sub("sleeper.pid")
        let gh = try Fixture.cloningGH(
            in: dir, before: "mkdir -p \"$4\"; touch \"$4/half\"; sleep 30 & echo $! > '\(sleeper)'; wait")
        let workspace = try await makeWorkspace(dir, github: gh)

        let clone = Task { try await workspace.cloneRepo("acme/app") }
        #expect(await eventually { FileManager.default.fileExists(atPath: sleeper) })
        clone.cancel()

        await #expect(throws: WorkspaceError.cloneCancelled) { try await clone.value }
        #expect(contents(dir.sub("home/repos")) == nil)
        let pid = try #require(
            Int32(String(contentsOfFile: sleeper, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
    }

    @Test func stoppingClonesDeletesWhatTheyWroteAtOnce() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let started = dir.sub("started")
        let gh = try Fixture.cloningGH(in: dir, before: "mkdir -p \"$4\"; touch \"$4/half\" '\(started)'; sleep 30")
        let workspace = try await makeWorkspace(dir, github: gh)

        let clone = Task { try await workspace.cloneRepo("acme/app") }
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        workspace.stopClones()

        #expect(contents(dir.sub("home/repos")) == nil)
        await #expect(throws: WorkspaceError.cloneCancelled) { try await clone.value }
    }

    // MARK: Racing

    @Test func twoClonesOfOneRepoCloneItOnce() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let calls = dir.sub("calls")
        let gh = try Fixture.cloningGH(in: dir, before: "echo x >> '\(calls)'; sleep 0.5")
        let workspace = try await makeWorkspace(dir, github: gh)

        async let first = workspace.cloneRepo("acme/app")
        async let second = workspace.cloneRepo("https://github.com/acme/app")
        let paths = try await [first.path, second.path]

        #expect(paths == [dir.sub("home/repos/acme/app"), dir.sub("home/repos/acme/app")])
        #expect(try String(contentsOfFile: calls, encoding: .utf8) == "x\n")
        #expect(await workspace.snapshot.repos.count == 1)
    }

    @Test func aFolderFilledWithTheSameRepoDuringTheCloneIsRegistered() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "acme/app")
        let folder = dir.sub("home/repos/acme/app")
        // Another tool clones the same repo into the folder while Canopy's clone runs.
        let gh = try Fixture.cloningGH(
            in: dir,
            before: """
                git clone -q "file://\(bare)" '\(folder)'
                git -C '\(folder)' remote set-url origin https://github.com/acme/app.git
                """)
        let workspace = try await makeWorkspace(dir, github: gh)

        let repo = try await workspace.cloneRepo("acme/app")

        #expect(repo.path == folder)
        #expect(contents(dir.sub("home/repos/acme")) == ["app"])
    }
}
