import Foundation
import Testing

@testable import CanopyCore

/// Everything the workspace logged so far, of the given kinds, such as "row".
func logged(_ workspace: Workspace, _ prefixes: String...) async -> [ActivityEvent] {
    await workspace.activity.flush()
    return activityEvents(workspace.activity.folder).filter { event in
        prefixes.contains { event.type.hasPrefix($0 + ".") }
    }
}

struct RowActivityTests {
    func setUp(_ dir: TempDir) async throws -> (Workspace, String) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (workspace, repo)
    }

    @Test func addingAndRemovingAReposAreLogged() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        try await workspace.addRepo(path: repo)
        try await workspace.removeRepo(path: repo)

        let events = await logged(workspace, "repo", "row")
        #expect(events.map(\.type) == ["repo.added", "repo.removed"])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.path == repo && $0.source == .ui })
    }

    @Test func rowsCanopyChangesAreLoggedOnceWithWhoAskedForThem() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)

        let first = try await workspace.createRow(repoPath: repo, branch: "feat/a").row
        let second = try await ActivitySource.$current.withValue(.cli) {
            try await workspace.createRow(repoPath: repo, branch: "feat/b").row
        }
        try await ActivitySource.$current.withValue(.cli) { _ = try await workspace.removeRow(path: first.path) }
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created", "row.created", "row.removed"])
        #expect(events.map(\.source) == [.ui, .cli, .cli])
        #expect(events.map(\.path) == [first.path, second.path, first.path])
        #expect(events.map(\.row) == ["feat/a", "feat/b", "feat/a"])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.data["class"] == "canopy" })
    }

    @Test func changesMadeWithPlainGitAreLoggedAsGit() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let path = dir.sub("elsewhere")

        try await Fixture.worktree(repo: repo, branch: "feat/x", at: path)
        await workspace.refresh(repoPath: repo)
        try await Fixture.git.run(["switch", "--quiet", "-c", "feat/y"], in: path)
        await workspace.refresh(repoPath: repo)
        try await Fixture.git.run(["switch", "--quiet", "--detach"], in: path)
        await workspace.refresh(repoPath: repo)
        try await Fixture.git.run(["worktree", "remove", path], in: repo)
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        try #require(events.map(\.type) == ["row.created", "row.branch_changed", "row.branch_changed", "row.removed"])
        #expect(events.allSatisfy { $0.source == .git && $0.path == path })
        #expect(events[0].data["class"] == "external")
        #expect(events[1].data == ["from": "feat/x", "to": "feat/y"])
        #expect(events[2].data == ["from": "feat/y", "to": .null])
    }

    @Test func rowsThatWereThereAtLaunchAreNotLogged() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/a", at: dir.sub("home/worktrees/demo/feat-a"))
        let first = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await first.start()
        try await first.addRepo(path: repo)
        await first.stop()

        let second = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await second.start()
        await second.refreshAll()

        #expect(await logged(second, "row").isEmpty)
    }

    @Test func aRepoThatComesBackLogsOnlyWhatChangedWhileItWasGone() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        _ = try await workspace.createRow(repoPath: repo, branch: "feat/a")

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.isMissing == true)
        try FileManager.default.moveItem(atPath: dir.sub("moved"), toPath: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await logged(workspace, "row").map(\.type) == ["row.created"])
    }

    @Test func aRowCanopyIsStillCreatingIsLoggedOnceItIsDone() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let path = dir.sub("home/worktrees/demo/feat-a")
        let (paused, resume) = (dir.sub("paused"), dir.sub("resume"))
        // After adding the worktree, git leaves it detached until the test lets go, as if still setting it up.
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ $1 == worktree && $2 == add ]]; then
                    '\(Fixture.gitPath)' "$@" || exit
                    '\(Fixture.gitPath)' -C '\(path)' switch --quiet --detach
                    touch '\(paused)'
                    \(Fixture.waitForFile(resume))
                    exec '\(Fixture.gitPath)' -C '\(path)' switch --quiet feat/a
                fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        async let created = ActivitySource.$current.withValue(.cli) {
            try await workspace.createRow(repoPath: repo, branch: "feat/a")
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: paused) })
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.row(path: path)?.branch == nil)
        FileManager.default.createFile(atPath: resume, contents: nil)
        _ = try await created
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created"])
        #expect(events.first?.row == "feat/a" && events.first?.source == .cli)
    }

    @Test func aWorktreeGitIsStillCreatingIsLoggedOnceItIsDone() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        try await Fixture.git.run(["branch", "feat/x"], in: repo)
        let path = dir.sub("elsewhere")
        let admin = repo + "/.git/worktrees/elsewhere"
        // How `git worktree add` leaves a worktree until it has checked the branch out: an all-zero HEAD. Written
        // HEAD first, so a refresh the watcher starts meanwhile never sees the worktree any other way.
        try FileManager.default.createDirectory(atPath: admin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try (String(repeating: "0", count: 40) + "\n").write(toFile: admin + "/HEAD", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: admin + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(admin)\n".write(toFile: path + "/.git", atomically: true, encoding: .utf8)
        try "\(path)/.git\n".write(toFile: admin + "/gitdir", atomically: true, encoding: .utf8)

        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.row(path: path) != nil)
        #expect(await logged(workspace, "row").isEmpty)
        try "ref: refs/heads/feat/x\n".write(toFile: admin + "/HEAD", atomically: true, encoding: .utf8)
        await workspace.refresh(repoPath: repo)

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created"])
        #expect(events.first?.row == "feat/x" && events.first?.source == .git)
    }

    @Test func aRepoMovedWhileGitListsItShowsAsMissing() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let moveNow = dir.sub("move-now")
        // git follows its folder if it moves after git started in it, and reports the new place.
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ $1 == worktree && $2 == list && -f '\(moveNow)' ]]; then
                    rm '\(moveNow)'
                    mv "$PWD" '\(dir.sub("moved"))'
                fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        FileManager.default.createFile(atPath: moveNow, contents: Data())
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.isMissing == true)
        try FileManager.default.moveItem(atPath: dir.sub("moved"), toPath: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await workspace.snapshot.repos.first?.rows.map(\.path) == [repo])
        #expect(await logged(workspace, "row").isEmpty)
    }

    @Test func adoptingAndUnadoptingAreLogged() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let path = dir.sub("elsewhere")
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: path)
        await workspace.refresh(repoPath: repo)

        _ = try await ActivitySource.$current.withValue(.cli) { try await workspace.adopt(path: path) }
        try await workspace.removeRow(path: path)

        let events = await logged(workspace, "row").dropFirst()
        #expect(events.map(\.type) == ["row.adopted", "row.removed"])
        #expect(events.map(\.source) == [.cli, .ui])
        #expect(events.allSatisfy { $0.path == path && $0.row == "feat/x" && $0.data["class"] == "adopted" })
    }

    @Test func pruningIsLoggedAsTheCallersChange() async throws {
        let dir = try TempDir()
        let (workspace, repo) = try await setUp(dir)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/a").row
        try FileManager.default.removeItem(atPath: row.path)
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.row(path: row.path)?.isMissing == true)

        try await ActivitySource.$current.withValue(.cli) { try await workspace.prune(repoPath: repo) }

        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created", "row.removed"])
        #expect(events.map(\.source) == [.ui, .cli])
    }

    @Test func aPruneThatFailsLogsWhatItRemovedAsTheCallers() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        // git prunes, then reports an error, as when it could not remove every stale entry.
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ $1 == worktree && $2 == prune ]]; then '\(Fixture.gitPath)' "$@"; exit 1; fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/a").row
        try FileManager.default.removeItem(atPath: row.path)
        await workspace.refresh(repoPath: repo)

        await #expect(throws: WorkspaceError.self) {
            try await ActivitySource.$current.withValue(.cli) { try await workspace.prune(repoPath: repo) }
        }
        await workspace.refresh(repoPath: repo)

        #expect(await logged(workspace, "row").map(\.source) == [.ui, .cli])
    }

    @Test func aRepoWithNoCommitsYetIsNotLoggedAsNewOnceItHasOne() async throws {
        let dir = try TempDir()
        let repo = dir.sub("empty")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await Fixture.git.run(["init", "--quiet", "-b", "main"], in: repo)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        try await Fixture.git.run(
            [
                "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--quiet", "--allow-empty", "-m",
                "first",
            ],
            in: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await logged(workspace, "row").isEmpty)
    }
}
