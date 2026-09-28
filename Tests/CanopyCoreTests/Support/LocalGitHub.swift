import Foundation

@testable import CanopyCore

/// A GitHub on this machine, so PR tests never reach the network. Repos are bare repos at
/// `<dir>/remotes/<owner>/<name>.git`, and `git` reaches them at https://github.com/<owner>/<name>.git through a URL
/// rewrite. `gh` answers a PR's lookup and the list of PRs from what `openPR` wrote, and records every other query and
/// answers it from `reply`.
struct LocalGitHub {
    let dir: TempDir
    let git: GitRunner
    let gh: GitHubCLI
    private var remotes: String { dir.sub("remotes") }
    private var prs: String { dir.sub("gh-prs") }
    private var callsFile: String { dir.sub("gh-calls") }
    private var replyFile: String { dir.sub("gh-reply") }
    private var failureFile: String { dir.sub("gh-failure") }

    init(_ dir: TempDir) throws {
        self.dir = dir
        git = GitRunner(executable: Fixture.gitPath, environment: Self.rewriting(to: dir.sub("remotes")))
        try FileManager.default.createDirectory(atPath: dir.sub("gh-prs"), withIntermediateDirectories: true)
        gh = try Fixture.gh(
            in: dir,
            """
            if [[ -f "\(dir.sub("gh-failure"))" ]]; then { read -r code; cat >&2; } < "\(dir.sub("gh-failure"))"; exit "$code"; fi
            query="${4#query=}"
            if [[ "$query" == *maintainerCanModify* ]]; then
                number=$(sed -E 's/.*pullRequest\\(number: ([0-9]+)\\).*/\\1/' <<< "$query")
                pr="\(dir.sub("gh-prs"))/$number.json"
                if [[ -f "$pr" ]]; then
                    printf '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": %s}}}\\n' "$(cat "$pr")"
                    exit 0
                fi
                echo '{"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": null}}}'
                echo "gh: Could not resolve to a PullRequest with the number of $number." >&2
                exit 1
            fi
            if [[ "$query" == *"pullRequests(states: [OPEN],"* ]]; then cat "\(dir.sub("gh-list-open"))"; exit 0; fi
            if [[ "$query" == *"pullRequests(states:"* ]]; then cat "\(dir.sub("gh-list-all"))"; exit 0; fi
            printf '%s\\n' "$query" >> "\(dir.sub("gh-calls"))"
            for number in $(grep -oE 'pullRequest\\(number: [0-9]+\\)' <<< "$query" | grep -oE '[0-9]+'); do
                if [[ ! -f "\(dir.sub("gh-prs"))/$number.json" ]]; then
                    echo '{"data": {"repository": {}}}'
                    echo "gh: Could not resolve to a PullRequest with the number of $number." >&2
                    exit 1
                fi
            done
            cat "\(dir.sub("gh-reply"))" 2>/dev/null || echo '{"data": {"repository": {}}}'
            """)
        try writeLists()
    }

    /// The tests' environment, with https://github.com/ rewritten to `remotes`.
    static func rewriting(to remotes: String) -> [String: String] {
        var environment = Fixture.environment
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "url.\(remotes)/.insteadOf"
        environment["GIT_CONFIG_VALUE_0"] = "https://github.com/"
        return environment
    }

    /// Creates `nameWithOwner` with one commit on main.
    func createRepo(_ nameWithOwner: String) async throws {
        let seed = try await Fixture.repo(in: dir, name: "seed-\(UUID().uuidString.prefix(6))")
        try await Fixture.git.run(["clone", "--quiet", "--bare", seed, bare(nameWithOwner)])
    }

    /// Makes `fork` a copy of `base`, as forking on GitHub does.
    func fork(_ base: String, as fork: String) async throws {
        try await Fixture.git.run(["clone", "--quiet", "--bare", bare(base), bare(fork)])
    }

    /// Clones `nameWithOwner` into `<dir>/<name>` with origin at its GitHub URL, as `gh repo clone` does.
    func clone(_ nameWithOwner: String, name: String = "demo", singleBranch: Bool = false) async throws -> String {
        let path = dir.sub(name)
        try await git.run(
            ["clone", "--quiet"] + (singleBranch ? ["--single-branch"] : [])
                + ["https://github.com/\(nameWithOwner).git", path])
        try await git.run(["config", "user.email", "test@example.com"], in: path)
        try await git.run(["config", "user.name", "Test"], in: path)
        return Paths.canonical(path)
    }

    /// Pushes `count` new commits on `branch` of `nameWithOwner`, starting it from main if it is new, made at `date`
    /// (default: now). Returns its tip.
    @discardableResult
    func push(
        _ count: Int = 1, to branch: String, of nameWithOwner: String, date: String? = nil
    ) async throws -> String {
        let work = dir.sub("work/\(nameWithOwner)")
        if !FileManager.default.fileExists(atPath: work) {
            try await Fixture.git.run(["clone", "--quiet", bare(nameWithOwner), work])
            try await Fixture.git.run(["config", "user.email", "author@example.com"], in: work)
            try await Fixture.git.run(["config", "user.name", "Author"], in: work)
        }
        try await Fixture.git.run(["fetch", "--quiet", "origin"], in: work)
        let start = await Fixture.git.succeeds(["rev-parse", "--verify", "--quiet", "origin/\(branch)"], in: work)
        try await Fixture.git.run(
            ["switch", "--quiet", "--force-create", branch, start ? "origin/\(branch)" : "origin/main"], in: work)
        for index in 1...count {
            try await Fixture.git(committingAt: date).run(
                ["commit", "--quiet", "--allow-empty", "-m", "\(branch) \(index)"], in: work)
        }
        try await Fixture.git.run(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], in: work)
        return try await Fixture.git.run(["rev-parse", "HEAD"], in: work).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// Opens PR `number` on `base` from `branch` of `head` (default: `base` itself). GitHub keeps every PR's head at
    /// `refs/pull/<number>/head` of the base repo, so that ref is pointed at the branch's tip.
    func openPR(
        _ number: Int, on base: String, from branch: String, of head: String? = nil, state: String = "OPEN",
        maintainerCanModify: Bool = false, deleteBranch: Bool = false, forkGone: Bool = false, title: String? = nil,
        author: String? = "author", isDraft: Bool = false, updatedAt: String = "2026-09-28T00:00:00Z"
    ) async throws {
        let headRepo = head ?? base
        let tip = try await Fixture.git.run(["rev-parse", "refs/heads/\(branch)"], in: bare(headRepo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await Fixture.git.run(
            ["push", "--quiet", bare(base), "\(tip):refs/pull/\(number)/head"], in: bare(headRepo))
        if deleteBranch {
            try await Fixture.git.run(["branch", "--quiet", "-D", branch], in: bare(headRepo))
        }
        let parts = headRepo.split(separator: "/")
        let json: [String: Any] = [
            "number": number, "title": title ?? "PR \(number)", "url": "https://github.com/\(base)/pull/\(number)",
            "state": state, "isDraft": isDraft, "updatedAt": updatedAt, "headRefName": branch,
            "headRefOid": tip, "headRef": deleteBranch ? NSNull() : ["name": branch], "baseRefName": "main",
            "isCrossRepository": headRepo != base, "maintainerCanModify": maintainerCanModify,
            "headRepository": forkGone ? NSNull() : ["name": String(parts[1])],
            "headRepositoryOwner": forkGone ? NSNull() : ["login": String(parts[0])],
            "author": author.map { ["login": $0] } ?? NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: "\(prs)/\(number).json"))
        try writeLists()
    }

    /// Makes GitHub forget PR `number`, as when it removes a spam PR.
    func deletePR(_ number: Int) {
        try? FileManager.default.removeItem(atPath: "\(prs)/\(number).json")
        try? writeLists()
    }

    /// What gh answers for the list of open PRs and of all PRs, most recently updated first.
    private func writeLists() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: prs).filter { $0.hasSuffix(".json") }
        let all = try names.compactMap {
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(prs)/\($0)")))
                as? [String: Any]
        }
        .sorted { ($0["updatedAt"] as? String ?? "") > ($1["updatedAt"] as? String ?? "") }
        let fields = [
            "number", "title", "url", "state", "isDraft", "updatedAt", "headRefName", "isCrossRepository", "author",
        ]
        for (file, states) in [("gh-list-open", ["OPEN"]), ("gh-list-all", ["OPEN", "CLOSED", "MERGED"])] {
            let nodes = all.filter { states.contains($0["state"] as? String ?? "") }.map {
                $0.filter { fields.contains($0.key) }
            }
            let reply = ["data": ["repository": ["pullRequests": ["nodes": nodes]]]]
            try JSONSerialization.data(withJSONObject: reply).write(to: URL(fileURLWithPath: dir.sub(file)))
        }
    }

    /// What gh answers every query that is not a PR's lookup.
    func reply(_ json: String) {
        try? json.write(toFile: replyFile, atomically: true, encoding: .utf8)
    }

    func fail(exitCode: Int, _ message: String) {
        try? "\(exitCode)\n\(message)\n".write(toFile: failureFile, atomically: true, encoding: .utf8)
    }

    /// Every query gh was asked that was not a PR's lookup.
    var calls: [String] {
        ((try? String(contentsOfFile: callsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func bare(_ nameWithOwner: String) -> String {
        "\(remotes)/\(nameWithOwner).git"
    }

    /// A GitRunner like `git` whose git first runs `before` (bash, with the arguments in "$@").
    func git(before: String) throws -> GitRunner {
        let script = dir.sub("git-wrapper-\(UUID().uuidString.prefix(6))")
        try "#!/bin/bash\n\(before)\nexec '\(Fixture.gitPath)' \"$@\"\n".write(
            toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return GitRunner(executable: script, environment: Self.rewriting(to: remotes))
    }
}
