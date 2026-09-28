import Foundation
import Testing

@testable import CanopyCore

struct WorkspaceTests {
    func makeWorkspace(_ dir: TempDir) async throws -> Workspace {
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        return workspace
    }

    @Test func thePortsPanelRemembersBeingCollapsed() async throws {
        let dir = try TempDir()
        let first = try await makeWorkspace(dir)
        #expect(await first.portsCollapsed == false)

        try await first.setPortsCollapsed(true)
        await first.stop()

        #expect(try await makeWorkspace(dir).portsCollapsed)
    }

    @Test func addRepoShowsMainRow() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)

        let added = try await workspace.addRepo(path: repo)

        #expect(added.name == "demo")
        #expect(added.rows.map(\.branch) == ["main"])
        #expect(added.rows.first?.rowClass == .main)
    }

    @Test func addRepoFromLinkedWorktreeRegistersMainCheckout() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: dir.sub("linked"))
        let workspace = try await makeWorkspace(dir)

        let added = try await workspace.addRepo(path: dir.sub("linked"))

        #expect(added.path == repo)
    }

    @Test func addRepoIsIdempotent() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)

        try await workspace.addRepo(path: repo)
        try await workspace.addRepo(path: repo)

        #expect(await workspace.snapshot.repos.count == 1)
    }

    @Test func addRepoRejectsNonRepos() async throws {
        let dir = try TempDir()
        let workspace = try await makeWorkspace(dir)

        await #expect(throws: WorkspaceError.pathNotFound(dir.sub("nope"))) {
            try await workspace.addRepo(path: dir.sub("nope"))
        }
        await #expect(throws: WorkspaceError.notAGitRepo(dir.path)) {
            try await workspace.addRepo(path: dir.path)
        }
    }

    @Test func pathsWithSpacesWork() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, name: "my repo")
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: dir.sub("home/worktrees/my repo/feat x"))
        let workspace = try await makeWorkspace(dir)

        let added = try await workspace.addRepo(path: repo)

        #expect(added.name == "my repo")
        #expect(added.rows.map(\.branch) == ["main", "feat/x"])
        #expect(added.rows.last?.path == dir.sub("home/worktrees/my repo/feat x"))
    }

    @Test func worktreeCreatedWithPlainGitAppears() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try await Fixture.worktree(repo: repo, branch: "feat/agent", at: dir.sub("home/worktrees/demo/feat-agent"))

        let appeared = await eventually {
            await workspace.snapshot.repos.first?.rows.contains { $0.branch == "feat/agent" && $0.rowClass == .canopy }
                == true
        }
        #expect(appeared)
    }

    @Test func worktreesElsewhereAreExternalUntilAdopted() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: dir.sub("elsewhere"))
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        var repoSnapshot = try #require(await workspace.snapshot.repos.first)
        #expect(repoSnapshot.rows.map(\.branch) == ["main"])
        #expect(repoSnapshot.external.map(\.externalTag) == [.other])

        let adopted = try await workspace.adopt(path: dir.sub("elsewhere"))

        #expect(adopted.rowClass == .adopted)
        repoSnapshot = try #require(await workspace.snapshot.repos.first)
        #expect(repoSnapshot.rows.map(\.branch) == ["main", "feat/other"])
        #expect(repoSnapshot.external.isEmpty)
    }

    @Test func stateSurvivesRestart() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: dir.sub("elsewhere"))
        let first = try await makeWorkspace(dir)
        try await first.addRepo(path: repo)
        _ = try await first.adopt(path: dir.sub("elsewhere"))
        try await first.setSelectedRow(path: dir.sub("elsewhere"))

        await first.stop()
        let second = try await makeWorkspace(dir)

        let snapshot = await second.snapshot
        #expect(snapshot.repos.first?.rows.map(\.branch) == ["main", "feat/other"])
        #expect(snapshot.selectedRowPath == dir.sub("elsewhere"))
    }

    @Test func secondWorkspaceOnTheSameHomeIsRefused() async throws {
        let dir = try TempDir()
        let first = try await makeWorkspace(dir)
        let second = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)

        await #expect(throws: WorkspaceError.homeInUse(dir.sub("home"))) {
            try await second.start()
        }
        _ = first
    }

    @Test func stoppedWorkspaceFreesItsHome() async throws {
        let dir = try TempDir()
        let first = try await makeWorkspace(dir)

        await first.stop()

        _ = try await makeWorkspace(dir)
    }

    @Test func newRowsAppendToTheEnd() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        for branch in ["b", "a", "c"] {
            try await Fixture.worktree(repo: repo, branch: branch, at: dir.sub("home/worktrees/demo/\(branch)"))
            await workspace.refresh(repoPath: repo)
        }

        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main", "b", "a", "c"])
    }

    @Test func deletedWorktreeFolderShowsMissingAndPrunes() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "gone", at: dir.sub("home/worktrees/demo/gone"))
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try FileManager.default.removeItem(atPath: dir.sub("home/worktrees/demo/gone"))
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.rows.last?.isMissing == true)

        try await workspace.prune(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main"])
    }

    @Test func relocateSurvivesARepoRemovedMeanwhile() async throws {
        let dir = try TempDir()
        let a = try await Fixture.repo(in: dir, name: "a")
        let b = try await Fixture.repo(in: dir, name: "b")
        let c = try await Fixture.repo(in: dir, name: "c")
        let git = try Fixture.git(in: dir, before: #"[[ "$*" == "worktree repair" ]] && sleep 1"#)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        for repo in [a, b, c] {
            try await workspace.addRepo(path: repo)
        }
        try FileManager.default.moveItem(atPath: b, toPath: dir.sub("b-moved"))

        async let relocation = workspace.relocateRepo(path: b, to: dir.sub("b-moved"))
        try await Task.sleep(for: .milliseconds(300))
        try await workspace.removeRepo(path: a)
        _ = try await relocation

        #expect(await workspace.snapshot.repos.map(\.path) == [dir.sub("b-moved"), c])
    }

    @Test func relocateRefusesARepoThatIsAlreadyRegistered() async throws {
        let dir = try TempDir()
        let a = try await Fixture.repo(in: dir, name: "a")
        let b = try await Fixture.repo(in: dir, name: "b")
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: a)
        try await workspace.addRepo(path: b)

        await #expect(throws: WorkspaceError.alreadyRegistered(b)) {
            try await workspace.relocateRepo(path: a, to: b)
        }
        #expect(await workspace.snapshot.repos.map(\.path) == [a, b])
    }

    @Test func missingRepoFolderIsFlagged() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.isMissing == true)

        try await workspace.relocateRepo(path: repo, to: dir.sub("moved"))
        let relocated = try #require(await workspace.snapshot.repos.first)
        #expect(relocated.path == dir.sub("moved"))
        #expect(!relocated.isMissing)
    }

    @Test func staleRefreshDoesNotReplaceNewerRows() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let marker = dir.sub("slow-once")
        // With the marker present, the next worktree list is read at once, then the marker is removed,
        // and the list is returned a second later.
        let script = dir.sub("slow-git")
        try """
        #!/bin/bash
        if [[ "$1 $2" == "worktree list" && -f "\(marker)" ]]; then
            out=$(mktemp)
            '\(Fixture.gitPath)' "$@" > "$out"
            status=$?
            rm "\(marker)"
            sleep 1
            cat "$out"
            rm "$out"
            exit $status
        fi
        exec '\(Fixture.gitPath)' "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let git = GitRunner(executable: script, environment: Fixture.environment)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        FileManager.default.createFile(atPath: marker, contents: nil)
        async let stale: Void = workspace.refresh(repoPath: repo)
        #expect(await eventually { !FileManager.default.fileExists(atPath: marker) })
        try await Fixture.worktree(repo: repo, branch: "feat/new", at: dir.sub("new"))
        await workspace.refresh(repoPath: repo)
        await stale

        #expect(await workspace.snapshot.repos.first?.external.map(\.branch) == ["feat/new"])
    }

    @Test func failedRefreshKeepsRowsAndShowsTheError() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/kept", at: dir.sub("kept"))
        let marker = dir.sub("fail")
        let git = try Fixture.git(
            in: dir,
            before:
                #"[[ "$1 $2" == "worktree list" && -f "\#(marker)" ]] && { echo "fatal: simulated" >&2; exit 128; }"#
        )
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        FileManager.default.createFile(atPath: marker, contents: nil)
        await workspace.refresh(repoPath: repo)

        let failed = try #require(await workspace.snapshot.repos.first)
        #expect(failed.rows.map(\.branch) == ["main"])
        #expect(failed.external.map(\.branch) == ["feat/kept"])
        #expect(failed.error?.contains("simulated") == true)
        try FileManager.default.removeItem(atPath: marker)
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.error == nil)
    }

    @Test func updatesStreamYieldsChanges() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        var iterator = await workspace.updates().makeAsyncIterator()

        #expect(await iterator.next()?.repos.isEmpty == true)
        try await workspace.addRepo(path: repo)
        var sawRepo = false
        while let snapshot = await iterator.next() {
            if snapshot.repos.first?.rows.isEmpty == false {
                sawRepo = true
                break
            }
        }
        #expect(sawRepo)
    }
}
