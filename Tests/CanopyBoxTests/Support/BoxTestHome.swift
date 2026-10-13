import CanopyAgents
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation

@testable import CanopyBoxKit

/// A host for one test: a root folder standing in for the user's home, a repo `demo` cloned at `<root>/demo` from an
/// origin, a tmux server of its own, and a daemon on all of it.
final class BoxTestHome: Sendable {
    static let homeID = "0a1b2c3d"
    let dir: TempDir
    let server: TmuxServer
    let clone: String
    let paths: BoxPaths

    init() async throws {
        dir = try TempDir(in: "/tmp")
        server = try TmuxServer()
        clone = try await GitFixture.repo(in: dir, origin: true)
        paths = BoxPaths(root: dir.path, homeID: Self.homeID)
    }

    var config: BoxConfig { BoxConfig(host: "box", repos: ["demo": clone]) }

    /// A daemon on this home, configured unless `configured` is false, and started.
    func daemon(configured: Bool = true) async throws -> BoxDaemon {
        let daemon = BoxDaemon(paths: paths, tmux: server.tmux, git: { GitFixture.clone($0) })
        if configured, !FileManager.default.fileExists(atPath: paths.configFile) {
            try BoxFiles.write(try JSONEncoder().encode(config), to: paths.configFile)
        }
        await daemon.start()
        return daemon
    }

    /// A worktree of `demo` made outside the daemon, as the Mac or a person would.
    @discardableResult
    func worktree(_ branch: String, under folder: String? = nil) async throws -> String {
        let parent = folder ?? paths.worktrees(repo: "demo")
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let path = parent + "/" + branch.replacingOccurrences(of: "/", with: "-")
        try await GitFixture.git(["worktree", "add", "--quiet", "-b", branch, path], in: clone)
        return Paths.canonical(path)
    }

    /// A session made outside the daemon, as the Mac's attach makes one.
    func session(_ name: String, in folder: String) async throws {
        try await server.tmux.newSession(name, folder: folder, environment: [:], command: "exec sleep 600")
    }
}
