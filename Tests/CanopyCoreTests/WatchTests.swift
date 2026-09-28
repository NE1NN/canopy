import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct GitEventFilterTests {
    let gitDir = "/r/.git"

    @Test func headAndWorktreeChangesAreRelevant() {
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/HEAD", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/HEAD", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/gitdir", gitDir: gitDir))
    }

    @Test func routineGitWritesAreNoise() {
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/index", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/objects/ab/cdef", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/index", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/logs/HEAD", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.gitignore", gitDir: gitDir))
    }

    @Test func remoteTrackingReflogsArePickedOut() {
        #expect(GitEventFilter.isRemoteRefLog(eventPath: "/r/.git/logs/refs/remotes/origin/feat/x", gitDir: gitDir))
        #expect(!GitEventFilter.isRemoteRefLog(eventPath: "/r/.git/logs/refs/remotes/origin/x.lock", gitDir: gitDir))
        #expect(!GitEventFilter.isRemoteRefLog(eventPath: "/r/.git/logs/refs/remotes/origin", gitDir: gitDir))
        #expect(!GitEventFilter.isRemoteRefLog(eventPath: "/r/.git/refs/remotes/origin/feat/x", gitDir: gitDir))
        #expect(!GitEventFilter.isRemoteRefLog(eventPath: "/r/.git/logs/refs/heads/feat/x", gitDir: gitDir))
        #expect(!GitEventFilter.isRemoteRefLog(eventPath: "/r/.git/packed-refs", gitDir: gitDir))
    }
}

struct GitReflogTests {
    @Test func tellsAPushFromAFetch() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let other = dir.sub("other")
        try await Fixture.git.run(["clone", "--quiet", dir.sub("demo-origin.git"), other])
        let log = repo + "/.git/logs/refs/remotes/origin/main"

        #expect(GitReflog.lastEntryIsPush(atPath: log))

        try await Fixture.git.run(
            ["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--quiet", "--allow-empty", "-m", "2"],
            in: other)
        try await Fixture.git.run(["push", "--quiet", "origin", "main"], in: other)
        try await Fixture.git.run(["fetch", "--quiet"], in: repo)

        #expect(!GitReflog.lastEntryIsPush(atPath: log))
        #expect(!GitReflog.lastEntryIsPush(atPath: dir.sub("missing")))
    }
}

final class EventLog: Sendable {
    let paths = Mutex<[String]>([])
}

struct DirectoryWatcherTests {
    @Test func reportsNewFiles() async throws {
        let dir = try TempDir()
        let log = EventLog()
        let watcher = DirectoryWatcher(paths: [dir.path]) { paths in
            log.paths.withLock { $0 += paths }
        }
        try await Task.sleep(for: .milliseconds(300))

        try "x".write(toFile: dir.sub("a.txt"), atomically: false, encoding: .utf8)

        let seen = await eventually { log.paths.withLock { $0 }.contains(dir.sub("a.txt")) }
        #expect(seen)
        _ = watcher
    }
}

final class StopFlag: Sendable {
    let value = Atomic(false)
}

struct WatcherLifetimeTests {
    @Test func removingARepoWhileItIsBeingAddedLeavesNoWatcher() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let started = dir.sub("rev-parse-started")
        let release = dir.sub("rev-parse-release")
        let git = try Fixture.git(
            in: dir,
            before: """
                if [[ "$1" == "rev-parse" ]]; then touch "\(started)"; while [[ ! -f "\(release)" ]]; do sleep 0.05; done; fi
                """)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
        try await workspace.start()

        let adding = Task { try await workspace.addRepo(path: repo) }
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        try await workspace.removeRepo(path: repo)
        FileManager.default.createFile(atPath: release, contents: nil)
        _ = try? await adding.value

        #expect(await workspace.watchers.isEmpty)
    }

    @Test func releasingAWatcherWhileEventsArriveIsSafe() async throws {
        let dir = try TempDir()
        let stop = StopFlag()
        defer { stop.value.store(true, ordering: .relaxed) }
        // A thread of its own: a busy loop on a Swift concurrency thread would starve the test. Even a 50 microsecond
        // pause between writes let the old watcher survive a third of runs, so the loop does not pause.
        Thread {
            var count = 0
            while !stop.value.load(ordering: .relaxed) {
                FileManager.default.createFile(atPath: dir.sub("f\(count % 50)"), contents: Data([1]))
                count += 1
            }
        }.start()
        for _ in 0..<200 {
            let watcher = DirectoryWatcher(paths: [dir.path], latency: 0) { _ in usleep(200) }
            try await Task.sleep(for: .milliseconds(Int.random(in: 1...8)))
            _ = watcher
        }
    }
}
