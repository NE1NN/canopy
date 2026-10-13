import CanopyGit
import CanopySystem
import Foundation

/// Real git repos for tests, on macOS and Linux.
public enum GitFixture {
    /// This process's environment without the SDKROOT that `swift test` adds and the app never has.
    public static let environment = ProcessInfo.processInfo.environment.filter { $0.key != "SDKROOT" }

    /// The git that /usr/bin/git hands off to on macOS, from xcode-select, since the shim asks xcrun on every run.
    public static let gitPath: String = {
        #if os(macOS)
            let folder = try? Subprocess.run(
                "/usr/bin/xcode-select", ["--print-path"], environment: environment, directory: nil,
                timeout: .seconds(10))
            let path = folder.map {
                String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) + "/usr/bin/git"
            }
            return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/usr/bin/git"
        #else
            return "/usr/bin/git"
        #endif
    }()

    public static func clone(_ path: String) -> GitClone {
        .local(path: path, executable: gitPath, environment: environment)
    }

    /// Runs git in `folder`, or with no folder for commands that name their own.
    @discardableResult
    public static func git(_ arguments: [String], in folder: String? = nil) async throws -> String {
        try await clone(folder ?? FileManager.default.currentDirectoryPath).run(arguments)
    }

    /// Creates `<dir>/<name>` with one commit on `main`. With `origin`, also a bare `<dir>/<name>-origin.git` it
    /// pushes to, with origin/HEAD set.
    @discardableResult
    public static func repo(in dir: TempDir, name: String = "demo", origin: Bool = false) async throws -> String {
        let path = dir.sub(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(["init", "--quiet", "-b", "main"], in: path)
        try await git(["config", "user.email", "test@example.com"], in: path)
        try await git(["config", "user.name", "Test"], in: path)
        try await git(["commit", "--quiet", "--allow-empty", "-m", "init"], in: path)
        if origin {
            let bare = dir.sub("\(name)-origin.git")
            try await git(["init", "--quiet", "--bare", "-b", "main", bare], in: dir.path)
            try await git(["remote", "add", "origin", bare], in: path)
            try await git(["push", "--quiet", "-u", "origin", "main"], in: path)
            try await git(["remote", "set-head", "origin", "main"], in: path)
        }
        return Paths.canonical(path)
    }

    /// Commits nothing in `folder`, with `message`, and returns the new commit.
    @discardableResult
    public static func commit(in folder: String, _ message: String) async throws -> String {
        try await git(["commit", "--quiet", "--allow-empty", "-m", message], in: folder)
        return try await git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
