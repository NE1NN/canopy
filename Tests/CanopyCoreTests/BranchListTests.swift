import Foundation
import Testing

@testable import CanopyCore

/// `branch list`: a repo's local and origin branches, each with the row or worktree that has it.
struct BranchListTests {
    /// acme/app, whose main was committed on 2026-09-01, with a clone at <dir>/demo registered in a workspace.
    /// `before` runs ahead of each git command the workspace runs, as `LocalGitHub.git(before:)` describes.
    func setUp(_ dir: TempDir, before: String? = nil) async throws -> (LocalGitHub, String, Workspace) {
        let github = try LocalGitHub(dir)
        let git = try before.map { try github.git(before: $0) }
        try await github.createRepo("acme/app")
        try await github.push(to: "main", of: "acme/app", date: "2026-09-01T00:00:00Z")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git ?? github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (github, repo, workspace)
    }

    /// Commits on the checked-out branch of `path`, made at `date`.
    func commit(_ path: String, date: String, count: Int = 1) async throws {
        for index in 1...count {
            try await Fixture.git(committingAt: date).run(
                ["commit", "--quiet", "--allow-empty", "-m", "local \(index)"], in: path)
        }
    }

    @Test func listsLocalAndOriginBranchesNewestFirst() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/old", of: "acme/app", date: "2026-09-10T00:00:00Z")
        try await github.push(to: "feat/new", of: "acme/app", date: "2026-09-20T00:00:00Z")
        try await github.git.run(["switch", "--quiet", "-c", "local/only"], in: repo)
        try await commit(repo, date: "2026-09-15T00:00:00Z")
        try await github.git.run(["switch", "--quiet", "main"], in: repo)

        let listing = try await workspace.listBranches(repoPath: repo)

        #expect(listing.branches.map(\.name) == ["feat/new", "local/only", "feat/old", "main"])
        #expect(listing.branches.map(\.location) == [.origin, .local, .origin, .both])
        #expect(listing.branches.map(\.committedAt).first == "2026-09-20T00:00:00Z")
        #expect(listing.warnings.isEmpty)
    }

    @Test func comparesALocalBranchWithOriginsByName() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        for branch in ["feat/behind", "feat/ahead", "feat/diverged", "feat/same"] {
            try await github.push(2, to: branch, of: "acme/app", date: "2026-09-02T00:00:00Z")
        }
        try await github.git.run(["fetch", "--quiet", "origin"], in: repo)
        try await github.git.run(["branch", "feat/behind", "origin/feat/behind~2"], in: repo)
        try await github.git.run(["branch", "feat/same", "origin/feat/same"], in: repo)
        for (branch, start) in [("feat/ahead", "origin/feat/ahead"), ("feat/diverged", "origin/feat/diverged~1")] {
            try await github.git.run(["switch", "--quiet", "-c", branch, start], in: repo)
            try await commit(repo, date: "2026-09-03T00:00:00Z")
        }
        // Tracking origin/main does not make it origin's feat/tracks-main.
        try await github.git.run(["switch", "--quiet", "--track", "-c", "feat/tracks-main", "origin/main"], in: repo)
        try await github.git.run(["switch", "--quiet", "main"], in: repo)

        let branches = Dictionary(
            uniqueKeysWithValues: try await workspace.listBranches(repoPath: repo, fetch: false).branches.map {
                ($0.name, $0)
            })

        #expect(branches["feat/behind"]?.behind == 2 && branches["feat/behind"]?.ahead == 0)
        #expect(branches["feat/ahead"]?.ahead == 1 && branches["feat/ahead"]?.behind == 0)
        #expect(branches["feat/diverged"]?.ahead == 1 && branches["feat/diverged"]?.behind == 1)
        #expect(branches["feat/same"]?.ahead == 0 && branches["feat/same"]?.behind == 0)
        #expect(branches["feat/tracks-main"]?.location == .local)
        #expect(branches["feat/tracks-main"]?.ahead == nil)
        #expect(branches["feat/behind"]?.label == "local, 2 behind")
        #expect(branches["feat/ahead"]?.label == "local, 1 ahead")
        #expect(branches["feat/diverged"]?.label == "local ≠ origin")
        #expect(branches["feat/same"]?.label == "local")
        #expect(branches["feat/tracks-main"]?.label == "local")
        // The newer of the two commits dates it.
        #expect(branches["feat/diverged"]?.committedAt == "2026-09-03T00:00:00Z")
        #expect(branches["feat/behind"]?.committedAt == "2026-09-02T00:00:00Z")
    }

    @Test func labelsSayWhereABranchIs() {
        func label(_ location: BranchLocation, _ ahead: Int? = nil, _ behind: Int? = nil) -> String {
            ListedBranch(name: "x", location: location, ahead: ahead, behind: behind, committedAt: "").label
        }

        #expect(label(.origin) == "origin")
        #expect(label(.local) == "local")
        #expect(label(.both, 0, 0) == "local")
        #expect(label(.both, 0, 3) == "local, 3 behind")
        #expect(label(.both, 2, 0) == "local, 2 ahead")
        #expect(label(.both, 1, 1) == "local ≠ origin")
    }

    @Test func aListedBranchReadsPlainlyForAgents() throws {
        let branch = ListedBranch(
            name: "feat/x", location: .origin, ahead: nil, behind: nil, committedAt: "2026-09-02T00:00:00Z")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let json = String(decoding: try encoder.encode(branch), as: UTF8.self)

        #expect(
            json
                == #"{"ahead":null,"behind":null,"committedAt":"2026-09-02T00:00:00Z","name":"feat/x","row":null,"#
                + #""where":"origin"}"#)
        #expect(try JSONDecoder().decode(ListedBranch.self, from: Data(json.utf8)) == branch)
    }

    @Test func saysWhichRowOrWorktreeHasEachBranch() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        for branch in ["feat/row", "feat/elsewhere", "feat/gone", "feat/free"] {
            try await github.push(to: branch, of: "acme/app")
        }
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/row", existing: true).row
        try await github.git.run(
            [
                "worktree", "add", "--quiet", "--track", "-b", "feat/elsewhere", dir.sub("elsewhere"),
                "origin/feat/elsewhere",
            ],
            in: repo)
        let gone = try await workspace.createRow(repoPath: repo, branch: "feat/gone", existing: true).row
        try FileManager.default.removeItem(atPath: gone.path)
        await workspace.refresh(repoPath: repo)

        let holders = Dictionary(
            uniqueKeysWithValues: try await workspace.listBranches(repoPath: repo).branches.map { ($0.name, $0.row) })

        #expect(holders["feat/row"] == BranchHolder(row))
        #expect(holders["main"] == BranchHolder(path: repo, branch: "main", rowClass: .main))
        #expect(
            holders["feat/elsewhere"]
                == BranchHolder(
                    path: Paths.canonical(dir.sub("elsewhere")), branch: "feat/elsewhere", rowClass: .external))
        #expect(holders["feat/gone"] == .some(nil))
        #expect(holders["feat/free"] == .some(nil))
    }

    @Test func fetchesFirstUnlessAFetchCoversIt() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(
            dir, before: #"[[ "$1" == fetch ]] && echo fetch >> "\#(dir.sub("fetches"))""#)
        func fetches() -> Int {
            ((try? String(contentsOfFile: dir.sub("fetches"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        try await github.push(to: "feat/pushed", of: "acme/app")

        let local = try await workspace.listBranches(repoPath: repo, fetch: false)
        #expect(!local.branches.map(\.name).contains("feat/pushed"))
        #expect(fetches() == 0)

        async let first = workspace.listBranches(repoPath: repo)
        async let second = workspace.listBranches(repoPath: repo)
        let both = try await [first, second]

        #expect(both.allSatisfy { $0.branches.map(\.name).contains("feat/pushed") })
        #expect(fetches() == 1)
        _ = try await workspace.listBranches(repoPath: repo)
        #expect(fetches() == 2)
    }

    @Test func aFailedFetchStillListsLocalBranches() async throws {
        let dir = try TempDir()
        let (_, repo, workspace) = try await setUp(
            dir,
            before: #"""
                [[ "$1" == fetch ]] && { echo "fatal: unable to access 'https://github.com/acme/app.git/'" >&2; exit 128; }
                """#)

        let listing = try await workspace.listBranches(repoPath: repo)

        #expect(listing.branches.map(\.name) == ["main"])
        #expect(
            listing.warnings == [
                "git fetch failed: fatal: unable to access 'https://github.com/acme/app.git/', so the list shows "
                    + "what Canopy last saw of origin."
            ])
    }

    @Test func aRepoWithoutOriginListsLocalBranches() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let git = try Fixture.git(in: dir, before: #"[[ "$1" == fetch ]] && exit 1"#)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git, github: Fixture.noGH(in: dir))
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        let listing = try await workspace.listBranches(repoPath: repo)

        #expect(listing.branches.map(\.name) == ["main"])
        #expect(listing.branches.first?.location == .local)
        #expect(listing.defaultBase == "HEAD")
        #expect(listing.warnings.isEmpty)
    }

    @Test func filtersByQueryWithAnExactNameFirst() async throws {
        let dir = try TempDir()
        let (github, repo, workspace) = try await setUp(dir)
        try await github.push(to: "feat/login", of: "acme/app", date: "2026-09-02T00:00:00Z")
        try await github.push(to: "feat/login-page", of: "acme/app", date: "2026-09-05T00:00:00Z")
        try await github.push(to: "fix/logout", of: "acme/app", date: "2026-09-04T00:00:00Z")

        func names(_ query: String) async throws -> [String] {
            try await workspace.listBranches(repoPath: repo, query: query).branches.map(\.name)
        }

        #expect(try await names("LOGIN") == ["feat/login-page", "feat/login"])
        #expect(try await names("Feat/Login") == ["feat/login", "feat/login-page"])
        #expect(try await names("log fix") == ["fix/logout"])
        #expect(try await names("nothing") == [])
    }

    @Test func theDefaultBaseIsOriginsDefaultBranch() async throws {
        let dir = try TempDir()
        let (_, repo, workspace) = try await setUp(dir)

        #expect(try await workspace.listBranches(repoPath: repo, fetch: false).defaultBase == "origin/main")
    }
}
