import Foundation

/// Owns registered repos and their rows. Git is the source of truth for which worktrees exist;
/// the workspace only persists which repos are registered, adopted paths, and row order.
public actor Workspace {
    public nonisolated let home: CanopyHome
    public nonisolated let activity: ActivityLog
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
    var gitQueues = KeyedQueue()
    /// Clones of each destination folder, apart from the git work of the repo that folder may already hold.
    var cloneQueues = KeyedQueue()
    var instanceLock: InstanceLock?
    var subscribers: [UUID: AsyncStream<WorkspaceSnapshot>.Continuation] = [:]
    public private(set) var loadNotice: String?
    /// Each repo's rows as of the last worktree list git gave, which the next one is compared with to log changes.
    var rowBaselines: [String: [Row]] = [:]
    /// Rows Canopy is creating, removing, or pruning, with who asked. git can list a row halfway through a change, so
    /// refreshes leave these out of the comparison, and the operation logs how each one ended up.
    var changingRows: [String: ActivitySource] = [:]
    /// Rows being created into a group, by path, so a refresh that lists one before its creation finishes puts it
    /// straight into the group. Renaming the group renames it here too.
    var rowsJoiningGroups: [String: JoiningGroup] = [:]
    /// Rows being created with a link to a plugin's item, by path, so their `row.created` says so.
    var rowsBeingLinked: [String: PluginLink] = [:]

    /// The built-in plugins, in the order their sections show. Their rows are in `state.plugins`.
    var pluginInfos: [PluginInfo] = []
    var pluginsOn: Set<String> = []
    var pluginWarnings: [String: String] = [:]
    /// How each plugin row looks, keyed by path, as its plugin last set it while running.
    var pluginLooks: [String: PluginRowLook] = [:]

    let github: GitHubCLI
    let prTiming: PRTiming
    var pullRequests: [String: RepoPullRequests] = [:]
    /// Each repo's last lookup GitHub answered, which the next one is compared with to log PRs opening and changing.
    var prBaselines: [String: RepoPullRequests] = [:]
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

    nonisolated let hostTooling: HostTooling
    /// Names this home on hosts.
    public nonisolated let homeID: String
    var hostConnections: [String: HostConnection] = [:]
    /// Each host's preparation, by the connection generation it was for. Callers at the same time share one.
    var preparedHosts: [String: (generation: Int, task: Task<Void, any Error>)] = [:]
    /// Each host's socket for its relayed `canopy` calls, which its connections forward here.
    var relayServers: [String: HostRelayServer] = [:]
    /// The Mac ports every host's forwards hold, so one host's never take another's.
    nonisolated let macPorts = MacPortReservations()

    /// Clones under way, which quitting stops without waiting for the actor.
    nonisolated let runningClones = RunningClones()

    public init(
        home: CanopyHome, git: GitRunner = GitRunner(), fetchTimeout: Duration = .seconds(60),
        github: GitHubCLI = GitHubCLI(), prTiming: PRTiming = .standard, activity: ActivityLog? = nil,
        hostTooling: HostTooling = HostTooling()
    ) {
        self.home = home
        self.activity = activity ?? ActivityLog(folder: home.activityFolder)
        self.git = git
        self.fetchTimeout = fetchTimeout
        self.github = github
        self.prTiming = prTiming
        self.hostTooling = hostTooling
        self.homeID = HomeID.load(home: home)
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
        await stopStaleMasters()
        // A stand-in deleted outside Canopy comes back, so the row's terminals have a folder to start in.
        for remote in state.repos.flatMap(\.remote) {
            try? remote.makeStandIn()
        }
        startPullRequests()
        for entry in state.repos {
            await watch(repoPath: entry.path)
        }
        await refreshAll()
    }

    /// Stops watching, lets every host go, and releases the home for another instance.
    public func stop() async {
        stopClones()
        await stopHosts()
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
        let links = rowLinks
        let repos = state.repos.map { entry in
            var repo = repoSnapshots[entry.path] ?? RepoSnapshot(path: entry.path, name: "")
            repo.name = names[entry.path] ?? entry.dirName
            repo.collapsed = entry.collapsed
            pullRequests[entry.path]?.apply(to: &repo)
            if !links.isEmpty {
                for index in repo.rows.indices {
                    repo.rows[index].link = links[repo.rows[index].path]
                }
            }
            return repo
        }
        return WorkspaceSnapshot(repos: repos, plugins: pluginSections, selectedRowPath: state.selectedRowPath)
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

    /// `clonedFrom` is what a clone was made from, for the activity log.
    @discardableResult
    public func addRepo(path: String, clonedFrom: String? = nil) async throws -> RepoSnapshot {
        let mainPath = try await mainCheckout(for: path)
        if state.repos.contains(where: { $0.path == mainPath }) {
            return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
        }
        let dirName = RepoNaming.dirName(for: mainPath, taken: Set(state.repos.map(\.dirName)))
        state.repos.append(RepoEntry(path: mainPath, dirName: dirName))
        try save()
        activity.record(
            ActivityType.repoAdded, repo: snapshot.repo(path: mainPath)?.name, path: mainPath,
            data: clonedFrom.map { ["clonedFrom": .string($0)] } ?? [:])
        await watch(repoPath: mainPath)
        await refresh(repoPath: mainPath)
        return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
    }

    public func removeRepo(path: String) throws {
        guard let index = state.repos.firstIndex(where: { $0.path == path }) else {
            throw WorkspaceError.repoNotFound(path)
        }
        let name = snapshot.repo(path: path)?.name
        let removed = state.repos.remove(at: index)
        dropLinks { owns(removed, $0) }
        watchers[path] = nil
        pendingRefreshes.removeValue(forKey: path)?.cancel()
        refreshQueues[path] = nil
        repoSnapshots[path] = nil
        rowBaselines[path] = nil
        forgetPullRequests(repoPath: path)
        try save()
        activity.record(ActivityType.repoRemoved, repo: name, path: path)
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
        rowBaselines[path] = nil
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
        let adopted = snapshot.row(path: canonical) ?? row
        record(ActivityType.rowAdopted, adopted, data: ["class": .string(RowClass.adopted.rawValue)])
        return adopted
    }

    public func unadopt(path: String) async throws {
        guard let index = state.repos.firstIndex(where: { $0.adopted.contains(path) }) else {
            throw WorkspaceError.rowNotFound(path)
        }
        let row = snapshot.row(path: path)
        state.repos[index].adopted.removeAll { $0 == path }
        state.repos[index].forget(path)
        dropLinks { $0 == path }
        if state.selectedRowPath == path {
            state.selectedRowPath = nil
        }
        try save()
        if let row {
            record(ActivityType.rowRemoved, row, data: ["class": .string(RowClass.adopted.rawValue)])
        }
        await refresh(repoPath: state.repos[index].path)
    }

    /// Each row's saved tabs and layouts, from state.json.
    public var savedTerminals: [String: SavedRowTerminals] {
        state.terminals
    }

    public var savedNextPane: Int {
        state.nextPane
    }

    public var savedNextWebPage: Int {
        state.nextWebPage
    }

    public var savedWebPlacement: WebPlacement {
        state.webPlacement
    }

    public func setSavedTerminals(
        _ terminals: [String: SavedRowTerminals], nextPane: Int? = nil, nextWebPage: Int? = nil,
        webPlacement: WebPlacement? = nil
    ) throws {
        let nextPane = max(nextPane ?? state.nextPane, state.nextPane)
        let nextWebPage = max(nextWebPage ?? state.nextWebPage, state.nextWebPage)
        let webPlacement = webPlacement ?? state.webPlacement
        guard
            state.terminals != terminals || state.nextPane != nextPane || state.nextWebPage != nextWebPage
                || state.webPlacement != webPlacement
        else { return }
        state.terminals = terminals
        state.nextPane = nextPane
        state.nextWebPage = nextWebPage
        state.webPlacement = webPlacement
        try save()
    }

    public var webPanelWidth: Double? {
        state.webPanelWidth
    }

    public func setWebPanelWidth(_ width: Double) throws {
        guard state.webPanelWidth != width else { return }
        state.webPanelWidth = width
        try save()
    }

    public var portsCollapsed: Bool {
        state.portsCollapsed
    }

    public func setPortsCollapsed(_ collapsed: Bool) throws {
        guard state.portsCollapsed != collapsed else { return }
        state.portsCollapsed = collapsed
        try save()
    }

    public var agentHooksOffered: Bool {
        state.agentHooksOffered
    }

    public func setAgentHooksOffered() throws {
        guard !state.agentHooksOffered else { return }
        state.agentHooksOffered = true
        try save()
    }

    public func setSelectedRow(path: String?) throws {
        guard state.selectedRowPath != path else { return }
        state.selectedRowPath = path
        try save()
        publish()
    }

    public func prune(repoPath: String) async throws {
        let missing = snapshot.repo(path: repoPath)?.allRows.filter(\.isMissing).map(\.path) ?? []
        for path in missing {
            changingRows[path] = .current
        }
        defer { finishChanging(missing, repoPath: repoPath) }
        do {
            try await serialized(repoPath: repoPath) {
                do {
                    try await self.git.run(["worktree", "prune"], in: repoPath)
                } catch let error as GitError {
                    throw WorkspaceError.git(error)
                }
            }
        } catch {
            // git may have pruned some rows before it failed, and they are the caller's doing too.
            await refresh(repoPath: repoPath)
            throw error
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
            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", isMissing: true).arranged(by: entry)
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
        let worktrees = WorktreeListParser.parse(output)
        // git follows a folder that moves after it started in it, and reports where the folder went.
        guard worktrees.first.map({ Paths.canonical($0.path) }) == current.path else {
            repoSnapshots[current.path] = RepoSnapshot(path: current.path, name: "", isMissing: true).arranged(
                by: current)
            publish()
            return
        }
        let local = classifier.rows(
            for: worktrees,
            repoPath: current.path,
            adopted: Set(current.adopted),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        recordRowChanges(repoPath: current.path, rows: local)
        let rows = local + remoteRows(of: current)
        let managed = rows.filter { $0.rowClass == .canopy || $0.rowClass == .adopted || $0.rowClass == .remote }
        var reconciled = current
        let joining = rowsJoiningGroups.filter { $0.value.repoPath == current.path }.mapValues(\.group)
        var changed = reconciled.reconcile(present: managed.map(\.path), joining: joining)
        if changed {
            state.repos[index] = reconciled
        }
        let present = Set(managed.map(\.path))
        // A row being made may be missing from a list git gave before it was, while its link is already saved.
        changed = dropLinks { owns(reconciled, $0) && !present.contains($0) && changingRows[$0] == nil } || changed
        if changed {
            try? save()
        }
        repoSnapshots[current.path] = RepoSnapshot(
            path: current.path,
            name: "",
            rows: rows.filter { $0.rowClass != .external },
            external: rows.filter { $0.rowClass == .external }
        ).arranged(by: reconciled)
        publish()
        if prBranchesRequested[current.path] != pullRequestBranches(repoPath: current.path) {
            _ = queuePullRequestRefresh(repoPath: current.path)
        }
    }

    // MARK: Activity

    /// Logs rows that appeared, went away, or moved to another branch since git last listed the repo's worktrees.
    /// Rows Canopy is changing, and rows git is still creating, wait until they are done. The first list after launch,
    /// adding the repo, or relocating it has nothing to compare with, so it logs nothing.
    private func recordRowChanges(repoPath: String, rows: [Row]) {
        let unsettled = Set(changingRows.keys).union(rows.filter(Self.isBeingCreated).map(\.path))
        let settled = rows.filter { !unsettled.contains($0.path) }
        guard let before = rowBaselines[repoPath] else {
            rowBaselines[repoPath] = settled
            return
        }
        rowBaselines[repoPath] = settled + before.filter { unsettled.contains($0.path) }
        let previous = Dictionary(before.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for row in settled {
            if let old = previous[row.path] {
                recordBranchChange(from: old, to: row, source: .git)
            } else {
                record(ActivityType.rowCreated, row, source: .git, data: ["class": .string(row.rowClass.rawValue)])
            }
        }
        let present = Set(rows.map(\.path))
        for row in before where !unsettled.contains(row.path) && !present.contains(row.path) {
            record(ActivityType.rowRemoved, row, source: .git, data: ["class": .string(row.rowClass.rawValue)])
        }
    }

    /// Logs how rows Canopy changed ended up, as of the last refresh, and compares them from there on.
    func finishChanging(_ paths: [String], repoPath: String) {
        for path in paths {
            let link = rowsBeingLinked.removeValue(forKey: path)
            guard let source = changingRows.removeValue(forKey: path), var baseline = rowBaselines[repoPath],
                let repo = repoSnapshots[repoPath], !repo.isMissing
            else { continue }
            let old = baseline.first { $0.path == path }
            let new = repo.allRows.first { $0.path == path && !Self.isBeingCreated($0) }
            switch (old, new) {
            case (nil, let row?):
                var data: [String: JSONValue] = ["class": .string(row.rowClass.rawValue)]
                if let link {
                    data["link"] = .object(["plugin": .string(link.plugin), "item": .string(link.item)])
                }
                record(ActivityType.rowCreated, row, source: source, data: data)
            case (let row?, nil):
                record(ActivityType.rowRemoved, row, source: source, data: ["class": .string(row.rowClass.rawValue)])
            case (let old?, let row?):
                recordBranchChange(from: old, to: row, source: source)
            case (nil, nil):
                break
            }
            baseline.removeAll { $0.path == path }
            baseline += new.map { [$0] } ?? []
            rowBaselines[repoPath] = baseline
        }
    }

    private func recordBranchChange(from old: Row, to row: Row, source: ActivitySource) {
        guard old.branch != row.branch else { return }
        record(
            ActivityType.rowBranchChanged, row, source: source,
            data: ["from": old.branch.map(JSONValue.string) ?? .null, "to": row.branch.map(JSONValue.string) ?? .null])
    }

    /// `git worktree add` lists a new worktree with a detached, all-zero HEAD until it has checked the branch out.
    /// A branch with no commits yet also has an all-zero HEAD, but it is named.
    static func isBeingCreated(_ row: Row) -> Bool {
        row.branch == nil && row.head.map { !$0.isEmpty && $0.allSatisfy { $0 == "0" } } ?? false
    }

    func record(
        _ type: String, _ row: Row, source: ActivitySource = .current, data: [String: JSONValue] = [:]
    ) {
        activity.record(
            type, repo: snapshot.repo(path: row.repoPath)?.name, row: row.displayName, path: row.path, source: source,
            data: data)
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
        try await gitQueues.enqueue(repoPath, operation).value
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

/// Work that runs one at a time per key, in the order it was queued.
struct KeyedQueue {
    private var last: [String: Task<Void, Never>] = [:]

    /// Starts `operation` once everything queued before it under `key` has finished.
    mutating func enqueue<T: Sendable>(
        _ key: String, _ operation: @escaping @Sendable () async throws -> T
    ) -> Task<T, any Error> {
        let previous = last[key]
        let task = Task {
            await previous?.value
            return try await operation()
        }
        last[key] = Task { _ = try? await task.value }
        return task
    }
}
