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

    /// A failed lookup keeps the last badges. They only go when gh cannot be used at all.
    func apply(to repo: inout RepoSnapshot) {
        repo.pullRequestWarning = warning
        for index in repo.rows.indices where Workspace.looksUpPullRequest(repo.rows[index]) {
            repo.rows[index].pullRequest = repo.rows[index].branch.flatMap { found[$0] }
        }
    }
}

extension Workspace {
    /// Main and external rows are never looked up, and neither is a detached HEAD.
    static func looksUpPullRequest(_ row: Row) -> Bool {
        (row.rowClass == .canopy || row.rowClass == .adopted) && row.branch != nil
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
        let origin = try? await git.run(["remote", "get-url", "origin"], in: repoPath)
        var lookup: PRLookup?
        if let github = origin.flatMap(GitHubRepo.init(remoteURL:)) {
            lookup = branches.isEmpty ? .found([:]) : await self.github.pullRequests(repo: github, branches: branches)
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
        guard entry != pullRequests[repoPath] else { return }
        pullRequests[repoPath] = entry
        publish()
    }

    func startPullRequestTimer() {
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
        guard state.repos.contains(where: { $0.path == repoPath }) else { return }
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
        prBranchesRequested[repoPath] = nil
        afterPush.removeValue(forKey: repoPath)?.task.cancel()
    }

    func stopPullRequestRefreshes() {
        prTimer?.cancel()
        prTimer = nil
        for entry in afterPush.values {
            entry.task.cancel()
        }
        afterPush.removeAll()
    }
}
