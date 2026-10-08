import Foundation

extension Workspace {
    /// Records a remote row the host now has: makes its stand-in folder, saves it with its repo, and places it at the
    /// end of `group` or of the ungrouped rows.
    func addRemoteRow(_ entry: RemoteRowEntry, repoPath: String, joining group: String? = nil) async throws {
        let index = try entryIndex(repoPath: repoPath)
        try entry.makeStandIn()
        state.repos[index].remote.removeAll { $0.standIn == entry.standIn }
        state.repos[index].remote.append(entry)
        state.repos[index].place(entry.standIn, joining: group)
        try save()
        await refresh(repoPath: repoPath)
    }

    public func remoteRow(standIn: String) -> RemoteRowEntry? {
        state.repos.lazy.flatMap(\.remote).first { $0.standIn == standIn }
    }

    public func remoteRow(host: String, path: String) -> RemoteRowEntry? {
        state.repos.lazy.flatMap(\.remote).first { $0.host == host && $0.path == path }
    }

    /// The repo's remote rows as the sidebar shows them.
    func remoteRows(of entry: RepoEntry) -> [Row] {
        entry.remote.map { Row(remote: $0, repoPath: entry.path) }
    }
}

extension Workspace {
    /// Makes a worktree for `branch` in the repo's clone on the host, with the rules a local row uses: a branch the
    /// host's clone has, fast-forwarded when it is only behind origin, then origin's, then a new one from `base` or
    /// origin's default branch. It goes in ~/.canopy/worktrees/<repo>/ on the host, and its stand-in here.
    public func createRemoteRow(
        repoPath: String, host alias: String, branch requested: String, base: String? = nil, existing: Bool = false,
        group: String? = nil, link: PluginLink? = nil
    ) async throws -> CreatedRow {
        let requestedAt = ContinuousClock.now
        let target = try await remoteTarget(repoPath: repoPath, host: alias)
        if let group { _ = try joiningGroup(group, repoPath: repoPath) }
        var created = try await gitQueues.enqueue("\(alias):\(target.clone)") {
            try await self.createRemoteRowNow(
                repoPath: repoPath, target: target, branch: requested, base: base, existing: existing, group: group,
                link: link, requestedAt: requestedAt)
        }.value
        created.row = snapshot.row(path: created.row.path) ?? created.row
        return created
    }

    struct RemoteTarget {
        var alias: String
        var connection: HostConnection
        var clone: String
        var repoName: String
        var dirName: String
    }

    func remoteTarget(repoPath: String, host alias: String) async throws -> RemoteTarget {
        let index = try entryIndex(repoPath: repoPath)
        let name = snapshot.repo(path: repoPath)?.name ?? state.repos[index].dirName
        let hosts = self.hosts.hosts
        guard let entry = hosts[alias] else { throw WorkspaceError.hostNotFound(alias, known: hosts.keys.sorted()) }
        guard let clone = entry.clonePath(repoName: name, repoPath: repoPath) else {
            let others = hosts.filter { $0.value.clonePath(repoName: name, repoPath: repoPath) != nil }.keys.sorted()
            throw WorkspaceError.hostHasNoRepo(alias, repo: name, hosts: others)
        }
        return RemoteTarget(
            alias: alias, connection: await connection(alias, entry), clone: clone, repoName: name,
            dirName: state.repos[index].dirName)
    }

    private func createRemoteRowNow(
        repoPath: String, target: RemoteTarget, branch requested: String, base: String?, existing: Bool,
        group: String?, link: PluginLink?, requestedAt: ContinuousClock.Instant
    ) async throws -> CreatedRow {
        let joining = try group.map { try joiningGroup($0, repoPath: repoPath) }
        let alias = target.alias
        try await target.connection.connect()
        let clone = RepoGit(git: remoteGit(alias), path: target.clone)
        return try await hostErrors(alias) {
            try await requireValidBranchName(requested, in: clone)
            if holder(of: requested, repoPath: repoPath, host: alias) != nil {
                await refreshRemote(repoPath: repoPath, host: alias)
                if let holder = holder(of: requested, repoPath: repoPath, host: alias), !holder.isMissing {
                    throw WorkspaceError.branchCheckedOut(requested, row: holder)
                }
            }
            var notes: [String] = []
            var warnings: [String] = []
            let hasOrigin = try await clone.succeedsOnHost(["remote", "get-url", "origin"])
            var fetchFailure: String?
            if hasOrigin {
                fetchFailure = await fetchUnlessFresh(clone, key: "\(alias):\(target.clone)", since: requestedAt)
                if let fetchFailure { warnings.append("\(fetchFailure), so the row starts from the host's refs.") }
            }

            let branch: String
            let source: BranchSource
            var start: String?
            if let local = await existingBranch(requested, under: "refs/heads/", in: clone) {
                (branch, source) = (local, .local)
            } else if hasOrigin, let remote = await existingBranch(requested, under: "refs/remotes/origin/", in: clone)
            {
                (branch, source) = (remote, .origin)
            } else {
                guard !existing else { throw WorkspaceError.branchNotFound(requested, fetchFailure: fetchFailure) }
                (branch, source) = (requested, .new)
                start = try await startPoint(base, in: clone, hasOrigin: hasOrigin)
            }
            if branch != requested { notes.append("Using \(branch), the branch's own spelling.") }

            var fastForward: FastForward?
            if source == .local, hasOrigin {
                let report = await compare(
                    branch, with: "refs/remotes/origin/\(branch)", named: "origin/\(branch)",
                    resetTo: "origin/\(branch)", in: clone)
                notes += report.notes
                warnings += report.warnings
                fastForward = report.fastForward
            }

            let home = try await target.connection.home()
            // git lists worktrees by their real path, which differs from one made under a home reached through a link.
            let listed = try await output(
                of: [
                    "sh", "-c", #"mkdir -p "$0" && cd "$0" && pwd -P && ls -1A"#,
                    "\(home)/.canopy/worktrees/\(target.dirName)",
                ],
                on: target.connection
            ).split(separator: "\n").map(String.init)
            guard let parent = listed.first, parent.hasPrefix("/") else {
                throw WorkspaceError.hostUnreachable(alias, reason: "The host did not say where its worktrees go.")
            }
            let taken = Set(listed.dropFirst())
            let registered = Set(state.repos.flatMap(\.remote).filter { $0.host == alias }.map(\.path))
            let folder = BranchSlug.folder(for: branch, in: URL(fileURLWithPath: parent)) {
                taken.contains($0.lastPathComponent) || registered.contains($0.path)
            }.path
            let arguments: [String] =
                switch source {
                case .local: [folder, branch]
                case .origin: ["--track", "-b", branch, folder, "origin/\(branch)"]
                case .new: ["--no-track", "-b", branch, folder, start ?? "HEAD"]
                }
            do {
                try await clone.run(["worktree", "add", "--quiet"] + arguments)
            } catch let error as GitError
                where error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree")
            {
                throw WorkspaceError.branchCheckedOut(branch, row: nil)
            }
            // The worktree is there from now on, so the row is saved even when the host drops before it is filled in.
            let worktree = RepoGit(git: clone.git, path: folder)
            var head: String?
            do {
                if let fastForward {
                    do {
                        try await worktree.run(["merge", "--ff-only", "--quiet", fastForward.commit])
                        notes.append(
                            "Fast-forwarded \(branch) by \(Self.commits(fastForward.count)) to match \(fastForward.name)."
                        )
                    } catch let error as GitError where !error.hostUnreachable {
                        warnings.append(
                            "Could not fast-forward \(branch) to \(fastForward.name), so it starts as it was: \(error)")
                    }
                }
                if try await output(
                    of: ["sh", "-c", #"test -f "$0/.canopy/config.json" && echo yes; true"#, folder],
                    on: target.connection
                ).contains("yes") {
                    notes.append(
                        "Remote rows do not run the branch's setup commands, so run them in the row if it needs them.")
                }
                head = try await worktree.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                warnings.append(
                    "Lost \(alias) after making the worktree, so the row fills in once the host is back: \(error)")
            }
            let leaf = (folder as NSString).lastPathComponent
            let entry = RemoteRowEntry(
                host: alias, path: worktree.path,
                standIn: standInPath(alias: alias, dirName: target.dirName, leaf: leaf), branch: branch, head: head)
            if source != .local { try? forgetPullRequest(of: branch, repoPath: repoPath) }
            if let link {
                state.plugins[link.plugin, default: PluginEntry()].links[entry.standIn] = link.item
            }
            try await addRemoteRow(entry, repoPath: repoPath, joining: joining)
            let row = snapshot.row(path: entry.standIn) ?? Row(remote: entry, repoPath: repoPath)
            var data = remoteData(row, ["class": .string(RowClass.remote.rawValue)])
            if let link { data["link"] = .object(["plugin": .string(link.plugin), "item": .string(link.item)]) }
            record(ActivityType.rowCreated, row, data: data)
            if let joined = row.group {
                record(ActivityType.rowMoved, row, data: remoteData(row, ["from": .null, "to": .string(joined)]))
            }
            return CreatedRow(
                row: row, source: source, base: start, pullRequest: nil, notes: notes, warnings: warnings)
        }
    }

    /// A stand-in's path, at remote/<host>/<repo>/<leaf>.
    /// Canonical, like every row path, so a home reached through a link still finds its rows.
    private nonisolated func standInPath(alias: String, dirName: String, leaf: String) -> String {
        Paths.canonical(home.remoteRoot.appending(path: alias).appending(path: dirName).appending(path: leaf).path)
    }

    /// Activity data for a remote row: its host and remote path, besides `data`.
    func remoteData(_ row: Row, _ data: [String: JSONValue]) -> [String: JSONValue] {
        var data = data
        if let host = row.host { data["host"] = .string(host) }
        if let remotePath = row.remotePath { data["remotePath"] = .string(remotePath) }
        return data
    }

    /// Runs `body`, turning git failing to reach the host into `host_unreachable`.
    func hostErrors<T>(_ alias: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as GitError where error.hostUnreachable {
            throw WorkspaceError.hostUnreachable(alias, reason: error.description)
        } catch WorkspaceError.git(let error) where error.hostUnreachable {
            throw WorkspaceError.hostUnreachable(alias, reason: error.description)
        }
    }

    /// Reads the host's worktrees of the repo and brings its remote rows up to date: each row's branch and head, and
    /// whether the host still has it. Does nothing while the host is not connected, so listing never wakes a host.
    public func refreshRemote(repoPath: String, host alias: String) async {
        guard let entry = hosts.hosts[alias], let index = try? entryIndex(repoPath: repoPath),
            state.repos[index].remote.contains(where: { $0.host == alias }),
            let clone = entry.clonePath(repoName: snapshot.repo(path: repoPath)?.name ?? "", repoPath: repoPath),
            let connection = hostConnections[alias], await connection.state == .connected,
            let output = try? await remoteGit(alias).run(["worktree", "list", "--porcelain", "-z"], in: clone)
        else { return }
        let worktrees = Dictionary(
            WorktreeListParser.parse(output).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // The awaits above let other calls run, so read the entry again.
        guard let index = try? entryIndex(repoPath: repoPath) else { return }
        var changed = false
        var headsMoved = false
        for (position, remote) in state.repos[index].remote.enumerated() where remote.host == alias {
            var updated = remote
            if let worktree = worktrees[remote.path] {
                updated.branch = worktree.branch
                updated.head = worktree.head
                updated.missing = worktree.isPrunable
            } else {
                updated.missing = true
            }
            guard updated != remote else { continue }
            changed = true
            headsMoved = headsMoved || updated.head != remote.head || updated.branch != remote.branch
            state.repos[index].remote[position] = updated
            if updated.branch != remote.branch {
                let row = Row(remote: updated, repoPath: repoPath)
                record(
                    ActivityType.rowBranchChanged, row, source: .git,
                    data: remoteData(
                        row,
                        [
                            "from": remote.branch.map(JSONValue.string) ?? .null,
                            "to": updated.branch.map(JSONValue.string) ?? .null,
                        ]))
            }
        }
        guard changed else { return }
        try? save()
        await refresh(repoPath: repoPath)
        if headsMoved { _ = queuePullRequestRefresh(repoPath: repoPath) }
    }

    /// Whether the remote row's worktree has changes `git worktree remove` would refuse to drop.
    public func remoteHasUncommittedChanges(standIn: String) async throws -> Bool {
        guard let entry = remoteRow(standIn: standIn), !entry.missing else { return false }
        let connection = try await connection(for: entry.host)
        try await connection.connect()
        return try await hostErrors(entry.host) {
            !(try await remoteGit(entry.host).run(["status", "--porcelain", "-z"], in: entry.path)).isEmpty
        }
    }

    /// Removes a remote row's worktree on its host, forgets the row, and deletes its stand-in. With `force`, changes
    /// in the worktree are dropped, and a host that cannot be reached only loses the row here, leaving the worktree.
    /// Returns warnings about what failed after the row was gone.
    @discardableResult
    public func removeRemoteRow(standIn: String, force: Bool, deleteBranch: Bool) async throws -> [String] {
        guard let entry = remoteRow(standIn: standIn),
            let repoPath = state.repos.first(where: { $0.remote.contains { $0.standIn == standIn } })?.path
        else { throw WorkspaceError.rowNotFound(standIn) }
        let row = Row(remote: entry, repoPath: repoPath)
        var warnings: [String] = []
        do {
            let target = try await remoteTarget(repoPath: repoPath, host: entry.host)
            try await gitQueues.enqueue("\(entry.host):\(target.clone)") {
                try await self.removeRemoteWorktree(entry, target: target, force: force, deleteBranch: deleteBranch)
            }.value
        } catch let error as WorkspaceError where force && error.code == "host_unreachable" {
            warnings.append(
                "\(entry.host) could not be reached, so its worktree at \(entry.path) stays there. "
                    + "Remove it on the host with `git worktree remove`.")
        }
        if let index = state.repos.firstIndex(where: { $0.path == repoPath }) {
            state.repos[index].remote.removeAll { $0.standIn == standIn }
            state.repos[index].forget(standIn)
        }
        if state.selectedRowPath == standIn { state.selectedRowPath = nil }
        dropLinks { $0 == standIn }
        try save()
        try? FileManager.default.removeItem(atPath: standIn)
        record(ActivityType.rowRemoved, row, data: remoteData(row, ["class": .string(RowClass.remote.rawValue)]))
        await refresh(repoPath: repoPath)
        return warnings
    }

    private func removeRemoteWorktree(
        _ entry: RemoteRowEntry, target: RemoteTarget, force: Bool, deleteBranch: Bool
    ) async throws {
        try await target.connection.connect()
        let clone = RepoGit(git: remoteGit(entry.host), path: target.clone)
        try await hostErrors(entry.host) {
            if entry.missing {
                try await clone.run(["worktree", "prune"])
            } else {
                do {
                    try await clone.run(["worktree", "remove"] + (force ? ["--force"] : []) + [entry.path])
                } catch let error as GitError where error.stderr.contains("modified or untracked files") {
                    throw WorkspaceError.worktreeDirty(entry.standIn)
                }
            }
            if deleteBranch, let branch = entry.branch {
                _ = try? await clone.run(["branch", "-D", branch])
            }
        }
    }
}

extension RepoGit {
    /// Like `succeeds`, but a host that cannot be reached fails rather than reading as "no".
    func succeedsOnHost(_ arguments: [String]) async throws -> Bool {
        do {
            try await run(arguments)
            return true
        } catch let error as GitError where error.hostUnreachable {
            throw error
        } catch {
            return false
        }
    }
}
