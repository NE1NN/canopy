import Foundation

/// Owns registered repos and their rows. Git is the source of truth for which worktrees exist;
/// the workspace only persists which repos are registered, adopted paths, and row order.
public actor Workspace {
    public nonisolated let home: CanopyHome
    let git: GitRunner
    let fetchTimeout: Duration
    var lastFetch: [String: FetchAttempt] = [:]
    let store: StateStore
    let classifier: RowClassifier
    var state = AppState()
    var repoSnapshots: [String: RepoSnapshot] = [:]
    var watchers: [String: DirectoryWatcher] = [:]
    var pendingRefreshes: [String: Task<Void, Never>] = [:]
    var refreshQueues: [String: Task<Void, Never>] = [:]
    var gitQueues: [String: Task<Void, Never>] = [:]
    var instanceLock: InstanceLock?
    var subscribers: [UUID: AsyncStream<WorkspaceSnapshot>.Continuation] = [:]
    public private(set) var loadNotice: String?

    let github: GitHubCLI
    let prTiming: PRTiming
    var pullRequests: [String: RepoPullRequests] = [:]
    /// The branches each repo's latest lookup asked about, set when it is queued.
    var prBranchesRequested: [String: [String]] = [:]
    var prQueues: [String: Task<Void, Never>] = [:]
    /// A queued lookup that has not started yet, which later callers share instead of queueing another.
    var prPending: [String: Task<Void, Never>] = [:]
    var prTimer: Task<Void, Never>?
    var afterPush: [String: (until: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]
    var lastFocusRefresh: ContinuousClock.Instant?
    /// Set by `stop()`, so watcher events and refreshes already under way start no more lookups.
    var prStopped = false

    public init(
        home: CanopyHome, git: GitRunner = GitRunner(), fetchTimeout: Duration = .seconds(60),
        github: GitHubCLI = GitHubCLI(), prTiming: PRTiming = .standard
    ) {
        self.home = home
        self.git = git
        self.fetchTimeout = fetchTimeout
        self.github = github
        self.prTiming = prTiming
        self.store = StateStore(url: home.stateFile)
        self.classifier = RowClassifier(
            canopyWorktreesRoot: Paths.canonical(home.worktreesRoot.path),
            homeDirectory: Paths.homeDirectory
        )
    }

    /// Takes the home's app lock first: two instances would each save their own state.json over the other's.
    public func start() async throws {
        try home.ensureExists()
        do {
            instanceLock = try InstanceLock(path: home.appLockPath)
        } catch InstanceLockError.heldElsewhere {
            throw WorkspaceError.homeInUse(home.root.path)
        }
        let result = store.load()
        state = result.state
        if case .recovered(_, let backup) = result {
            loadNotice =
                "state.json could not be read. It was moved to \(backup.lastPathComponent) and Canopy started fresh."
        }
        startPullRequests()
        for entry in state.repos {
            await watch(repoPath: entry.path)
        }
        await refreshAll()
    }

    /// Stops watching and releases the home for another instance.
    public func stop() {
        watchers.removeAll()
        for task in pendingRefreshes.values {
            task.cancel()
        }
        pendingRefreshes.removeAll()
        stopPullRequestRefreshes()
        for subscriber in subscribers.values {
            subscriber.finish()
        }
        subscribers.removeAll()
        instanceLock = nil
    }

    public var snapshot: WorkspaceSnapshot {
        let names = RepoNaming.displayNames(for: state.repos.map(\.path))
        let repos = state.repos.map { entry in
            var repo = repoSnapshots[entry.path] ?? RepoSnapshot(path: entry.path, name: "")
            repo.name = names[entry.path] ?? entry.dirName
            pullRequests[entry.path]?.apply(to: &repo)
            return repo
        }
        return WorkspaceSnapshot(repos: repos, selectedRowPath: state.selectedRowPath)
    }

    /// Yields the current snapshot immediately, then every change.
    public func updates() -> AsyncStream<WorkspaceSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: WorkspaceSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    // MARK: Repos

    @discardableResult
    public func addRepo(path: String) async throws -> RepoSnapshot {
        let mainPath = try await mainCheckout(for: path)
        if state.repos.contains(where: { $0.path == mainPath }) {
            return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
        }
        let dirName = RepoNaming.dirName(for: mainPath, taken: Set(state.repos.map(\.dirName)))
        state.repos.append(RepoEntry(path: mainPath, dirName: dirName))
        try save()
        await watch(repoPath: mainPath)
        await refresh(repoPath: mainPath)
        return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
    }

    public func removeRepo(path: String) throws {
        guard let index = state.repos.firstIndex(where: { $0.path == path }) else {
            throw WorkspaceError.repoNotFound(path)
        }
        state.repos.remove(at: index)
        watchers[path] = nil
        pendingRefreshes.removeValue(forKey: path)?.cancel()
        refreshQueues[path] = nil
        repoSnapshots[path] = nil
        forgetPullRequests(repoPath: path)
        try save()
        publish()
    }

    /// Points a missing repo at its new location, keeping its adopted rows and order. Returns the new main path.
    @discardableResult
    public func relocateRepo(path: String, to newPath: String) async throws -> String {
        guard state.repos.contains(where: { $0.path == path }) else {
            throw WorkspaceError.repoNotFound(path)
        }
        let mainPath = try await mainCheckout(for: newPath)
        try requireUnregistered(mainPath, except: path)
        _ = try? await git.run(["worktree", "repair"], in: mainPath)
        // The awaits above let other calls add or remove repos, so look everything up again.
        guard let index = state.repos.firstIndex(where: { $0.path == path }) else {
            throw WorkspaceError.repoNotFound(path)
        }
        try requireUnregistered(mainPath, except: path)
        state.repos[index].path = mainPath
        watchers[path] = nil
        pendingRefreshes.removeValue(forKey: path)?.cancel()
        refreshQueues[path] = nil
        repoSnapshots[path] = nil
        forgetPullRequests(repoPath: path)
        try save()
        await watch(repoPath: mainPath)
        await refresh(repoPath: mainPath)
        return mainPath
    }

    // MARK: Rows

    public func adopt(path: String) async throws -> Row {
        let canonical = Paths.canonical(path)
        if snapshot.row(path: canonical) == nil {
            await refreshAll()
        }
        guard let row = snapshot.row(path: canonical),
            let index = state.repos.firstIndex(where: { $0.path == row.repoPath })
        else {
            throw WorkspaceError.rowNotFound(path)
        }
        guard row.rowClass == .external else { return row }
        state.repos[index].adopted.append(canonical)
        try save()
        await refresh(repoPath: row.repoPath)
        return snapshot.row(path: canonical) ?? row
    }

    public func unadopt(path: String) async throws {
        guard let index = state.repos.firstIndex(where: { $0.adopted.contains(path) }) else {
            throw WorkspaceError.rowNotFound(path)
        }
        state.repos[index].adopted.removeAll { $0 == path }
        state.repos[index].rowOrder.removeAll { $0 == path }
        if state.selectedRowPath == path {
            state.selectedRowPath = nil
        }
        try save()
        await refresh(repoPath: state.repos[index].path)
    }

    /// Each row's saved tabs and layouts, from state.json.
    public var savedTerminals: [String: SavedRowTerminals] {
        state.terminals
    }

    public var savedNextPane: Int {
        state.nextPane
    }

    public func setSavedTerminals(_ terminals: [String: SavedRowTerminals], nextPane: Int? = nil) throws {
        let nextPane = max(nextPane ?? state.nextPane, state.nextPane)
        guard state.terminals != terminals || state.nextPane != nextPane else { return }
        state.terminals = terminals
        state.nextPane = nextPane
        try save()
    }

    public func setSelectedRow(path: String?) throws {
        guard state.selectedRowPath != path else { return }
        state.selectedRowPath = path
        try save()
        publish()
    }

    public func prune(repoPath: String) async throws {
        try await serialized(repoPath: repoPath) {
            do {
                try await self.git.run(["worktree", "prune"], in: repoPath)
            } catch let error as GitError {
                throw WorkspaceError.git(error)
            }
        }
        await refresh(repoPath: repoPath)
    }

    // MARK: Refreshing

    public func refreshAll() async {
        for path in state.repos.map(\.path) {
            await refresh(repoPath: path)
        }
    }

    /// Refreshes of one repo run one after another, so a slow worktree list can never land after a newer one,
    /// and the snapshot reflects git as of this call once it returns.
    public func refresh(repoPath: String) async {
        let previous = refreshQueues[repoPath]
        let task = Task {
            await previous?.value
            await self.refreshNow(repoPath: repoPath)
        }
        refreshQueues[repoPath] = task
        await task.value
    }

    private func refreshNow(repoPath: String) async {
        guard let entry = state.repos.first(where: { $0.path == repoPath }) else { return }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", isMissing: true)
            publish()
            return
        }
        let output: String
        do {
            output = try await git.run(["worktree", "list", "--porcelain", "-z"], in: entry.path)
        } catch {
            // Keep the last known rows, so a passing git failure does not close the view onto them.
            var failed = repoSnapshots[entry.path] ?? RepoSnapshot(path: entry.path, name: "")
            failed.isMissing = false
            failed.error = "\(error)"
            repoSnapshots[entry.path] = failed
            publish()
            return
        }
        // The await above let other calls run, so read the entry again before using it.
        guard let index = state.repos.firstIndex(where: { $0.path == repoPath }) else { return }
        let current = state.repos[index]
        let rows = classifier.rows(
            for: WorktreeListParser.parse(output),
            repoPath: current.path,
            adopted: Set(current.adopted),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        let managed = rows.filter { $0.rowClass == .canopy || $0.rowClass == .adopted }
        let order = RowOrdering.reconcile(order: current.rowOrder, present: managed.map(\.path))
        if order != current.rowOrder {
            state.repos[index].rowOrder = order
            try? save()
        }
        let managedByPath = Dictionary(managed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        repoSnapshots[current.path] = RepoSnapshot(
            path: current.path,
            name: "",
            rows: rows.filter { $0.rowClass == .main } + order.compactMap { managedByPath[$0] },
            external: rows.filter { $0.rowClass == .external }
        )
        publish()
        if prBranchesRequested[current.path] != pullRequestBranches(repoPath: current.path) {
            _ = queuePullRequestRefresh(repoPath: current.path)
        }
    }

    // MARK: Internals

    func mainCheckout(for path: String) async throws -> String {
        let canonical = Paths.canonical(path)
        guard FileManager.default.fileExists(atPath: canonical) else {
            throw WorkspaceError.pathNotFound(path)
        }
        let output: String
        do {
            output = try await git.run(["worktree", "list", "--porcelain", "-z"], in: canonical)
        } catch {
            throw WorkspaceError.notAGitRepo(path)
        }
        guard let main = WorktreeListParser.parse(output).first else {
            throw WorkspaceError.notAGitRepo(path)
        }
        guard !main.isBare else { throw WorkspaceError.bareRepo(path) }
        return Paths.canonical(main.path)
    }

    /// Runs git changes to one repo one at a time. Git takes lock files on config and refs, so parallel
    /// agents adding worktrees to the same repo would otherwise fail on each other. Repos stay parallel.
    func serialized<T: Sendable>(
        repoPath: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = gitQueues[repoPath]
        let task = Task {
            await previous?.value
            return try await operation()
        }
        gitQueues[repoPath] = Task { _ = try? await task.value }
        return try await task.value
    }

    private func requireUnregistered(_ path: String, except current: String) throws {
        if path != current, state.repos.contains(where: { $0.path == path }) {
            throw WorkspaceError.alreadyRegistered(path)
        }
    }

    func save() throws {
        try store.save(state)
    }

    func publish() {
        let current = snapshot
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func watch(repoPath: String) async {
        guard
            let gitDir = try? await git.run(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                in: repoPath
            )
        else { return }
        // The repo may have been removed while git answered.
        guard state.repos.contains(where: { $0.path == repoPath }) else { return }
        let canonicalGitDir = Paths.canonical(gitDir.trimmingCharacters(in: .whitespacesAndNewlines))
        watchers[repoPath] = DirectoryWatcher(paths: [canonicalGitDir]) { [weak self] paths in
            let worktrees = paths.contains { GitEventFilter.isRelevant(eventPath: $0, gitDir: canonicalGitDir) }
            let pushed = paths.contains {
                GitEventFilter.isRemoteRefLog(eventPath: $0, gitDir: canonicalGitDir)
                    && GitReflog.lastEntryIsPush(atPath: $0)
            }
            guard worktrees || pushed else { return }
            Task {
                if worktrees { await self?.scheduleRefresh(repoPath: repoPath) }
                if pushed { await self?.refreshOftenAfterPush(repoPath: repoPath) }
            }
        }
    }

    private func scheduleRefresh(repoPath: String) {
        pendingRefreshes[repoPath]?.cancel()
        pendingRefreshes[repoPath] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.refresh(repoPath: repoPath)
        }
    }
}
