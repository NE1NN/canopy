import Foundation
import Testing

@testable import CanopyCore

struct CloneSourceTests {
    @Test func readsOwnerSlashRepoAsAGitHubRepo() throws {
        let source = try CloneSource("  acme/app \n")

        #expect(source.text == "acme/app")
        #expect(source.github == GitHubRepo(remoteURL: "https://github.com/acme/app"))
        #expect(source.url == nil)
        #expect(source.ghArgument == "acme/app")
        #expect(source.owner == "acme")
        #expect(source.name == "app")
    }

    @Test func keepsRepoNamesThatStartWithADot() throws {
        let source = try CloneSource("acme/.github")

        #expect(source.name == ".github")
    }

    @Test(arguments: [
        "https://github.com/acme/app.git", "https://github.com/acme/app", "git@github.com:acme/app.git",
        "ssh://git@github.com/acme/app.git",
    ])
    func readsGitHubURLs(url: String) throws {
        let source = try CloneSource(url)

        #expect(source.github?.nameWithOwner == "acme/app")
        #expect(source.url == url)
        #expect(source.ghArgument == url)
        #expect(source.owner == "acme")
        #expect(source.name == "app")
    }

    @Test(arguments: [
        ("https://gitlab.com/group/team/tool.git", "team", "tool"),
        ("git@example.com:team/tool.git", "team", "tool"),
        ("file:///srv/git/acme/lib.git", "acme", "lib"),
        ("/srv/git/acme/lib.git", "acme", "lib"),
        ("https://example.com/tool.git/", "example.com", "tool"),
    ])
    func takesTheFolderAboveTheRepoAsTheOwnerOfOtherURLs(url: String, owner: String, name: String) throws {
        let source = try CloneSource(url)

        #expect(source.github == nil)
        #expect(source.url == url)
        #expect(source.ghArgument == nil)
        #expect(source.owner == owner)
        #expect(source.name == name)
    }

    @Test(arguments: [
        "", "   ", "canopy", "acme/app/extra", "acme/..", "../app", "acme/.", "https://example.com/acme/..",
        "https://example.com/../app.git", "https://example.com/", "file:///srv/acme/.git", "-acme/app",
        "--upload-pack=touch:pwned",
    ])
    func refusesAnythingElse(text: String) {
        #expect(throws: WorkspaceError.invalidCloneSource(text.trimmingCharacters(in: .whitespacesAndNewlines))) {
            try CloneSource(text)
        }
    }

    @Test func picksAFolderUnderReposByOwnerAndName() throws {
        let home = CanopyHome(path: "/tmp/canopy-home")

        #expect(try CloneSource("acme/app").defaultFolder(in: home) == "/tmp/canopy-home/repos/acme/app")
    }

    @Test func needsAFolderForAURLWithNoOwner() throws {
        let source = try CloneSource("file:///app.git")

        #expect(source.owner == nil)
        #expect(throws: WorkspaceError.cloneNeedsFolder("file:///app.git")) {
            try source.defaultFolder(in: CanopyHome(path: "/tmp/canopy-home"))
        }
    }

    @Test func matchesAGitHubOriginOverAnyProtocolAndInAnyCase() throws {
        let source = try CloneSource("acme/app")
        let origin = "git@github.com:ACME/App.git"

        #expect(source.isSameRepo(asOrigin: origin, gitHubRepo: GitHubRepo(remoteURL: origin)))
        #expect(
            !source.isSameRepo(
                asOrigin: "https://github.com/acme/other",
                gitHubRepo: GitHubRepo(remoteURL: "https://github.com/acme/other")))
        #expect(!source.isSameRepo(asOrigin: "https://example.com/acme/app", gitHubRepo: nil))
    }

    @Test func matchesOtherOriginsWithoutTheirGitSuffixOrTrailingSlash() throws {
        let source = try CloneSource("https://gitlab.com/team/tool")

        #expect(source.isSameRepo(asOrigin: "https://gitlab.com/team/tool.git/", gitHubRepo: nil))
        #expect(!source.isSameRepo(asOrigin: "https://gitlab.com/team/other.git", gitHubRepo: nil))
    }

    @Test func matchesLocalOriginsByTheirResolvedPath() throws {
        let dir = try TempDir()
        let bare = dir.sub("lib.git")
        try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir.sub("link.git"), withDestinationPath: bare)
        let source = try CloneSource("file://" + dir.sub("link.git"))

        #expect(source.isSameRepo(asOrigin: bare, gitHubRepo: nil))
        #expect(source.isSameRepo(asOrigin: "file://" + bare + "/", gitHubRepo: nil))
        #expect(!source.isSameRepo(asOrigin: dir.sub("other.git"), gitHubRepo: nil))
    }
}
