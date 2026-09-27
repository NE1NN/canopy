import Foundation

@testable import CanopyCore

enum Fixture {
    static let git = GitRunner()

    /// Creates `<dir>/<name>` with one commit on `main`. With `origin`, also creates a bare
    /// `<dir>/<name>-origin.git`, pushes to it, and sets origin/HEAD.
    @discardableResult
    static func repo(in dir: TempDir, name: String = "demo", origin: Bool = false) async throws -> String {
        let path = dir.sub(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "-b", "main"], in: path)
        try await git.run(["config", "user.email", "test@example.com"], in: path)
        try await git.run(["config", "user.name", "Test"], in: path)
        try await git.run(["commit", "--quiet", "--allow-empty", "-m", "init"], in: path)
        if origin {
            let bare = dir.sub("\(name)-origin.git")
            try await git.run(["init", "--quiet", "--bare", "-b", "main", bare])
            try await git.run(["remote", "add", "origin", bare], in: path)
            try await git.run(["push", "--quiet", "-u", "origin", "main"], in: path)
            try await git.run(["remote", "set-head", "origin", "main"], in: path)
        }
        return Paths.canonical(path)
    }

    static func worktree(repo: String, branch: String, at path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try await git.run(["worktree", "add", "--quiet", "-b", branch, path], in: repo)
    }
}

/// Polls until `condition` holds or the timeout passes. Returns whether it held.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
