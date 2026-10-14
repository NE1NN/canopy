import CanopyTestSupport
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// Trust as Claude Code 2.1.296 reads and writes it, checked against its TUI on 2026-10-13: inside a git repo only the
/// repo's main checkout or the row's own folder count, and accepting writes the main checkout; outside git, the folder
/// or any folder above it counts.
struct ClaudeTrustTests {
    let dir: TempDir
    let config: URL

    init() throws {
        dir = try TempDir()
        config = URL(fileURLWithPath: dir.sub(".claude.json"))
    }

    func write(_ projects: [String: Bool], extra: [String: JSONValue] = [:]) throws {
        var object = extra
        object["projects"] = .object(projects.mapValues { .object(["hasTrustDialogAccepted": .bool($0)]) })
        try JSONEncoder().encode(JSONValue.object(object)).write(to: config)
    }

    func read() throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: config))
    }

    @Test func aRowIsTrustedThroughItsRepo() throws {
        try write(["/r/demo": true])
        let place = ClaudeTrust.Place.row(path: "/w/feat-x", repo: "/r/demo")

        #expect(ClaudeTrust.isTrusted(place, config: config))
        #expect(!ClaudeTrust.isTrusted(.row(path: "/w/feat-x", repo: "/r/other"), config: config))
    }

    @Test func aRowIsTrustedThroughItsOwnFolder() throws {
        try write(["/w/feat-x": true])

        #expect(ClaudeTrust.isTrusted(.row(path: "/w/feat-x", repo: "/r/demo"), config: config))
    }

    @Test func aFolderAboveARepoDoesNotCount() throws {
        try write(["/w": true, "/r": true])

        #expect(!ClaudeTrust.isTrusted(.row(path: "/w/feat-x", repo: "/r/demo"), config: config))
    }

    @Test func outsideGitAFolderAboveCounts() throws {
        try write(["/h/.canopy/plugins/tickets": true])

        #expect(ClaudeTrust.isTrusted(.folder("/h/.canopy/plugins/tickets/0811-paul"), config: config))
        #expect(!ClaudeTrust.isTrusted(.folder("/h/.canopy/plugins/other"), config: config))
    }

    @Test func aFalseEntryOrNoFileIsNotTrusted() throws {
        #expect(!ClaudeTrust.isTrusted(.folder("/x"), config: config))
        try write(["/x": false])
        #expect(!ClaudeTrust.isTrusted(.folder("/x"), config: config))
    }

    @Test func trustingWritesTheRepoAndKeepsEverythingElse() throws {
        try write(["/other": false], extra: ["theme": "dark", "numStartups": 42])

        try ClaudeTrust.trust(.row(path: "/w/feat-x", repo: "/r/demo"), config: config)

        let saved = try read()
        #expect(saved["theme"] == "dark")
        #expect(saved["numStartups"] == 42)
        guard case .object(let projects)? = saved["projects"] else {
            Issue.record("no projects")
            return
        }
        #expect(projects["/r/demo"]?.fields?["hasTrustDialogAccepted"] == .bool(true))
        #expect(projects["/other"]?.fields?["hasTrustDialogAccepted"] == .bool(false))
        #expect(projects["/w/feat-x"] == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func trustingKeepsTheFoldersOtherSettings() throws {
        try JSONEncoder().encode(
            JSONValue.object([
                "projects": .object(["/x": .object(["allowedTools": .array([]), "hasTrustDialogAccepted": false])])
            ])
        ).write(to: config)

        try ClaudeTrust.trust(.folder("/x"), config: config)

        #expect(
            try read()["projects"]?.fields?["/x"]
                == .object(["allowedTools": .array([]), "hasTrustDialogAccepted": true]))
    }

    @Test func aSymlinkedFileIsWrittenWhereItLives() throws {
        let real = URL(fileURLWithPath: dir.sub("dotfiles.json"))
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(atPath: config.path, withDestinationPath: real.path)

        try ClaudeTrust.trust(.folder("/x"), config: config)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == real.path)
        #expect(ClaudeTrust.isTrusted(.folder("/x"), config: real))
    }

    @Test func trustingWithNoFileMakesOne() throws {
        try ClaudeTrust.trust(.folder("/x"), config: config)

        #expect(ClaudeTrust.isTrusted(.folder("/x"), config: config))
    }

    /// Every Claude Code process rewrites the file from its own copy, which can drop the new key.
    @Test func trustingWritesAgainIfAnotherWriterDropsIt() throws {
        try write([:])
        let clobbers = Mutex(1)

        try ClaudeTrust.trust(.folder("/x"), config: config, settle: .milliseconds(20)) {
            let clobber = clobbers.withLock { count -> Bool in
                defer { count -= 1 }
                return count > 0
            }
            if clobber { try? self.write([:]) }
        }

        #expect(ClaudeTrust.isTrusted(.folder("/x"), config: config))
    }

    @Test func givesUpWhenTheKeyKeepsGoingMissing() throws {
        try write([:])

        #expect(throws: ClaudeTrust.Failure.notKept) {
            try ClaudeTrust.trust(.folder("/x"), config: config, settle: .milliseconds(5)) { try? self.write([:]) }
        }
    }

    @Test func refusesToRewriteAFileItCannotRead() throws {
        try Data("{ not json".utf8).write(to: config)

        #expect(throws: ClaudeTrust.Failure.unreadable) {
            try ClaudeTrust.trust(.folder("/x"), config: config)
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == "{ not json")
    }
}
