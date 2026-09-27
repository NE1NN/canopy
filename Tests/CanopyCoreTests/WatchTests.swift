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
