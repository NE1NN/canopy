import Foundation
import Testing

@testable import CanopyCore

struct CanopyHomeTests {
    @Test func environmentWins() {
        let home = CanopyHome.resolve(environment: ["CANOPY_HOME": "/tmp/x"], bundleHome: "~/.canopy-dev")
        #expect(home.root.path == "/tmp/x")
    }

    @Test func bundleKeyIsSecond() {
        let home = CanopyHome.resolve(environment: [:], bundleHome: "~/.canopy-dev")
        #expect(home.root.path == NSHomeDirectory() + "/.canopy-dev")
    }

    @Test func defaultsToDotCanopy() {
        let home = CanopyHome.resolve(environment: [:], bundleHome: nil)
        #expect(home.root.path == NSHomeDirectory() + "/.canopy")
        #expect(home.socketPath == NSHomeDirectory() + "/.canopy/canopy.sock")
        #expect(home.worktreesRoot.path == NSHomeDirectory() + "/.canopy/worktrees")
    }

    @Test func ensureExistsCreatesPrivateFolder() throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let attributes = try FileManager.default.attributesOfItem(atPath: home.root.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect(FileManager.default.fileExists(atPath: home.worktreesRoot.path))
    }
}

struct PathsTests {
    @Test func canonicalResolvesPrivateSymlink() {
        #expect(Paths.canonical("/tmp") == "/private/tmp")
    }

    @Test func canonicalKeepsMissingPaths() {
        #expect(Paths.canonical("/nope/../nope/x") == "/nope/x")
    }

    @Test func canonicalResolvesExistingPrefixOfMissingPath() {
        #expect(Paths.canonical("/tmp/canopy-not-created-yet/a") == "/private/tmp/canopy-not-created-yet/a")
    }

    @Test func isInsideRespectsFolderBoundaries() {
        #expect(Paths.isInside("/a/b/c", "/a/b"))
        #expect(Paths.isInside("/a/b", "/a/b"))
        #expect(!Paths.isInside("/a/bc", "/a/b"))
    }
}
