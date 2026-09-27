import Testing

@testable import CanopyCore

struct TargetResolverTests {
    static func row(_ repo: String, _ path: String, _ branch: String, _ rowClass: RowClass = .canopy) -> Row {
        Row(repoPath: repo, path: path, branch: branch, head: nil, rowClass: rowClass)
    }

    let snapshot = WorkspaceSnapshot(repos: [
        RepoSnapshot(
            path: "/src/web",
            name: "web",
            rows: [row("/src/web", "/src/web", "main", .main), row("/src/web", "/c/web/fix-a", "fix/a")],
            external: [row("/src/web", "/x/web-other", "other", .external)]
        ),
        RepoSnapshot(
            path: "/src/api",
            name: "api",
            rows: [row("/src/api", "/src/api", "main", .main), row("/src/api", "/c/api/fix-a", "fix/a")]
        ),
    ])

    @Test func explicitRepoByNameOrPath() throws {
        #expect(try TargetResolver.repo(for: TargetHint(repo: "api"), in: snapshot).path == "/src/api")
        #expect(try TargetResolver.repo(for: TargetHint(repo: "/src/web"), in: snapshot).path == "/src/web")
    }

    @Test func unknownExplicitRepoFails() {
        #expect(throws: WorkspaceError.repoNotFound("nope")) {
            try TargetResolver.repo(for: TargetHint(repo: "nope", envRepo: "web"), in: snapshot)
        }
    }

    @Test func repoFallsBackToEnvironmentThenCwd() throws {
        #expect(
            try TargetResolver.repo(for: TargetHint(envRepo: "api", cwd: "/c/web/fix-a"), in: snapshot).path
                == "/src/api")
        #expect(try TargetResolver.repo(for: TargetHint(cwd: "/c/web/fix-a/src/deep"), in: snapshot).path == "/src/web")
    }

    @Test func repoWithNoClueFails() {
        #expect(throws: WorkspaceError.missingTarget(flag: "--repo")) {
            try TargetResolver.repo(for: TargetHint(cwd: "/unrelated"), in: snapshot)
        }
    }

    @Test func branchIsScopedByResolvableRepo() throws {
        let row = try TargetResolver.row(for: TargetHint(row: "fix/a", envRepo: "api"), in: snapshot)
        #expect(row.path == "/c/api/fix-a")
    }

    @Test func branchInSeveralReposIsAmbiguous() {
        #expect(throws: WorkspaceError.ambiguousRow("fix/a", repos: ["web", "api"])) {
            try TargetResolver.row(for: TargetHint(row: "fix/a"), in: snapshot)
        }
    }

    @Test func rowByPathAndExternalRows() throws {
        #expect(try TargetResolver.row(for: TargetHint(row: "/c/web/fix-a"), in: snapshot).branch == "fix/a")
        #expect(try TargetResolver.row(for: TargetHint(repo: "web", row: "other"), in: snapshot).rowClass == .external)
    }

    @Test func rowFallsBackToEnvironmentThenCwd() throws {
        #expect(
            try TargetResolver.row(for: TargetHint(envRowPath: "/c/api/fix-a"), in: snapshot).repoPath == "/src/api")
        #expect(try TargetResolver.row(for: TargetHint(cwd: "/c/web/fix-a/lib"), in: snapshot).path == "/c/web/fix-a")
    }
}
