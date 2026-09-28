import Foundation

/// When PR badges refresh, besides `canopy pr --refresh` and rows appearing.
public struct PRTiming: Sendable {
    public var interval: Duration
    /// The least time between refreshes caused by the app coming to the front.
    public var focusGap: Duration
    public var afterPushInterval: Duration
    public var afterPushDuration: Duration

    public init(interval: Duration, focusGap: Duration, afterPushInterval: Duration, afterPushDuration: Duration) {
        self.interval = interval
        self.focusGap = focusGap
        self.afterPushInterval = afterPushInterval
        self.afterPushDuration = afterPushDuration
    }

    /// Every minute, on focus at most every 15 seconds, and every 10 seconds for two minutes after a push,
    /// when a PR is most likely to be opened.
    public static let standard = PRTiming(
        interval: .seconds(60), focusGap: .seconds(15), afterPushInterval: .seconds(10),
        afterPushDuration: .seconds(120))
}

/// What Canopy last learned about one repo's pull requests.
struct RepoPullRequests: Equatable {
    enum Source: Equatable {
        case github
        case notGitHub
        case ghMissing
        case notLoggedIn
        case failed(String)
    }

    var source: Source
    /// The branches the last finished lookup asked about.
    var branches: [String] = []
    var found: [String: PullRequest] = [:]

    var warning: String? {
        switch source {
        case .github, .notGitHub: nil
        case .ghMissing: "Install gh to see pull requests: `brew install gh`, then `gh auth login`."
        case .notLoggedIn: "Run `gh auth login` to see pull requests."
        case .failed(let message): "Pull requests did not load: \(message)"
        }
    }

    /// A failed lookup keeps the last badges. They only go when gh cannot be used at all. A missing repo has no rows
    /// to badge, and "missing" says all there is to say.
    func apply(to repo: inout RepoSnapshot) {
        guard !repo.isMissing else { return }
        repo.pullRequestWarning = warning
        for index in repo.rows.indices where Workspace.looksUpPullRequest(repo.rows[index]) {
            repo.rows[index].pullRequest = repo.rows[index].branch.flatMap { found[$0] }
        }
    }
}

/// A git remote on GitHub.
struct GitHubRemote: Sendable, Equatable {
    /// The URL git uses for the remote.
    var url: String
    var repo: GitHubRepo
}

extension Workspace {
    /// The GitHub repo behind a remote, or nil when it is not on GitHub. `git remote get-url` applies `insteadOf`
    /// rewrites, so a mirror can hide GitHub, and then the remote's configured URL still names the repo.
    func gitHubRemote(_ remote: String, repoPath: String) async -> GitHubRemote? {
        for arguments in [["remote", "get-url", remote], ["config", "--get", "remote.\(remote).url"]] {
            guard let url = try? await git.run(arguments, in: repoPath).trimmingCharacters(in: .whitespacesAndNewlines),
                let repo = await github.repo(forRemote: url)
            else { continue }
            return GitHubRemote(url: url, repo: repo)
        }
        return nil
    }

    /// Main and external rows are never looked up, and neither is a detached HEAD.
    static func looksUpPullRequest(_ row: Row) -> Bool {
        (row.rowClass == .canopy || row.rowClass == .adopted) && row.branch != nil
    }

    /// The PRs bound to `branches`, while origin is still the repo they were bound in.
    func boundPullRequests(repoPath: String, branches: [String], repo: GitHubRepo) -> [String: Int] {
        let bindings = state.repos.first { $0.path == repoPath }?.prBindings ?? [:]
        var numbers: [String: Int] = [:]
        for branch in branches {
            guard let binding = bindings[branch], binding.repo.lowercased() == repo.nameWithOwner.lowercased() else {
                continue
            }
            numbers[branch] = binding.number
        }
        return numbers
    }

    /// Forgets the PR bound to `branch`, which is gone, or is about to be a new branch with the same name.
    func forgetPullRequest(of branch: String, repoPath: String) throws {
        guard let index = try? entryIndex(repoPath: repoPath), state.repos[index].prBindings[branch] != nil else {
            return
        }
        state.repos[index].prBindings[branch] = nil
        try save()
    }

    func pullRequestBranches(repoPath: String) -> [String] {
        let rows = repoSnapshots[repoPath]?.rows ?? []
        return Set(rows.filter(Self.looksUpPullRequest).compactMap(\.branch)).sorted()
    }

    /// Returns once the snapshot reflects GitHub as of this call.
    public func refreshPullRequests(repoPath: String) async {
        await queuePullRequestRefresh(repoPath: repoPath).value
    }

    /// Repos are looked up in parallel.
    public func refreshAllPullRequests() async {
        let lookups = state.repos.map { queuePullRequestRefresh(repoPath: $0.path) }
        for lookup in lookups {
            await lookup.value
        }
    }

    /// The row's PR, looked up first when asked to or when its branch has not been looked up yet.
    public func pullRequest(for row: Row, refresh: Bool) async throws -> PullRequest? {
        guard Self.looksUpPullRequest(row), let branch = row.branch else {
            throw WorkspaceError.noPullRequestLookup(row.displayName)
        }
        if refresh || pullRequests[row.repoPath]?.branches.contains(branch) != true {
            await refreshPullRequests(repoPath: row.repoPath)
        }
        guard let entry = pullRequests[row.repoPath] else { throw WorkspaceError.rowNotFound(row.path) }
        switch entry.source {
        case .notGitHub:
            throw WorkspaceError.notOnGitHub(snapshot.repo(path: row.repoPath)?.name ?? row.repoPath)
        case .ghMissing, .notLoggedIn:
            throw WorkspaceError.ghUnavailable(entry.warning ?? "")
        case .failed(let message) where refresh || !entry.branches.contains(branch):
            throw WorkspaceError.ghFailed(message)
        case .github, .failed:
            return entry.found[branch]
        }
    }

    public func applicationBecameActive() async {
        let now = ContinuousClock.now
        if let last = lastFocusRefresh, now - last < prTiming.focusGap { return }
        lastFocusRefresh = now
        await refreshAllPullRequests()
    }

    /// Lookups of one repo run one after another, so an older answer never replaces a newer one.
    /// A lookup that is queued but not started yet already covers anyone asking now, so they share it.
    func queuePullRequestRefresh(repoPath: String) -> Task<Void, Never> {
        guard !prStopped else { return Task {} }
        prBranchesRequested[repoPath] = pullRequestBranches(repoPath: repoPath)
        if let pending = prPending[repoPath] { return pending }
        let previous = prQueues[repoPath]
        let task = Task {
            await previous?.value
            await self.lookUpPullRequests(repoPath: repoPath)
        }
        prPending[repoPath] = task
        prQueues[repoPath] = task
        return task
    }

    private func lookUpPullRequests(repoPath: String) async {
        prPending[repoPath] = nil
        guard state.repos.contains(where: { $0.path == repoPath }), let repo = repoSnapshots[repoPath], !repo.isMissing
        else { return }
        let branches = pullRequestBranches(repoPath: repoPath)
        var lookup: PRLookup?
        if let origin = await gitHubRemote("origin", repoPath: repoPath) {
            let numbers = boundPullRequests(repoPath: repoPath, branches: branches, repo: origin.repo)
            lookup =
                branches.isEmpty
                ? .found([:]) : await github.pullRequests(repo: origin.repo, branches: branches, numbers: numbers)
        }
        // The repo may have been removed while gh answered.
        guard state.repos.contains(where: { $0.path == repoPath }) else { return }
        var entry = pullRequests[repoPath] ?? RepoPullRequests(source: .github)
        switch lookup {
        case nil: entry = RepoPullRequests(source: .notGitHub, branches: branches)
        case .found(let found): entry = RepoPullRequests(source: .github, branches: branches, found: found)
        case .ghMissing: entry = RepoPullRequests(source: .ghMissing, branches: branches)
        case .notLoggedIn: entry = RepoPullRequests(source: .notLoggedIn, branches: branches)
        case .failed(let message): entry.source = .failed(message)
        }
        recordPullRequestChanges(repoPath: repoPath, entry: entry)
        guard entry != pullRequests[repoPath] else { return }
        pullRequests[repoPath] = entry
        publish()
    }

    /// Logs PRs that opened or changed state since the last lookup GitHub answered. A branch that lookup did not ask
    /// about, such as a row made a moment ago, has nothing to compare with. A lookup gh could not make changes nothing,
    /// so PRs coming back after `gh auth login` are not logged as new.
    private func recordPullRequestChanges(repoPath: String, entry: RepoPullRequests) {
        guard entry.source == .github else { return }
        defer { prBaselines[repoPath] = entry }
        guard let before = prBaselines[repoPath] else { return }
        let rows = repoSnapshots[repoPath]?.rows.filter(Self.looksUpPullRequest) ?? []
        for branch in entry.branches where before.branches.contains(branch) {
            guard let pr = entry.found[branch], let row = rows.first(where: { $0.branch == branch }) else { continue }
            let number = JSONValue.number(Double(pr.number))
            if let old = before.found[branch], old.number == pr.number {
                guard old.state != pr.state else { continue }
                record(
                    ActivityType.prStateChanged, row, source: .git,
                    data: [
                        "number": number, "from": .string(old.state.rawValue), "to": .string(pr.state.rawValue),
                        "url": .string(pr.url),
                    ])
            } else if before.found[branch] == nil || [.open, .draft].contains(pr.state) {
                // Among closed PRs the branch shows the most recently updated, so one can take over from another
                // without anything being opened.
                record(
                    ActivityType.prOpened, row, source: .git,
                    data: [
                        "number": number, "title": .string(pr.title), "state": .string(pr.state.rawValue),
                        "url": .string(pr.url),
                    ])
            }
        }
    }

    func startPullRequests() {
        prStopped = false
        prTimer?.cancel()
        prTimer = Task { [weak self, interval = prTiming.interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.refreshOnTimer()
            }
        }
    }

    /// Checks for cancellation on the actor, so a tick already on its way in when `stop()` ran looks nothing up.
    private func refreshOnTimer() async {
        guard !Task.isCancelled else { return }
        await refreshAllPullRequests()
    }

    /// A push moved a remote-tracking branch. Another push in the window extends it.
    func refreshOftenAfterPush(repoPath: String) {
        guard !prStopped, state.repos.contains(where: { $0.path == repoPath }) else { return }
        let until = ContinuousClock.now + prTiming.afterPushDuration
        if let running = afterPush[repoPath] {
            afterPush[repoPath] = (until, running.task)
            return
        }
        let task = Task { [weak self, every = prTiming.afterPushInterval] in
            while true {
                try? await Task.sleep(for: every)
                guard let self, await self.isAfterPush(repoPath: repoPath) else { return }
                await self.refreshPullRequests(repoPath: repoPath)
            }
        }
        afterPush[repoPath] = (until, task)
    }

    /// Called from the repo's after-push task, so a cancelled one never touches its successor's entry.
    private func isAfterPush(repoPath: String) -> Bool {
        guard !Task.isCancelled, let entry = afterPush[repoPath] else { return false }
        if ContinuousClock.now < entry.until { return true }
        afterPush[repoPath] = nil
        return false
    }

    func forgetPullRequests(repoPath: String) {
        pullRequests[repoPath] = nil
        prBaselines[repoPath] = nil
        prBranchesRequested[repoPath] = nil
        afterPush.removeValue(forKey: repoPath)?.task.cancel()
    }

    func stopPullRequestRefreshes() {
        prStopped = true
        prTimer?.cancel()
        prTimer = nil
        for entry in afterPush.values {
            entry.task.cancel()
        }
        afterPush.removeAll()
    }
}
