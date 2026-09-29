import Foundation

/// UI actions the control API can trigger. The app implements it on the main actor.
public protocol ControlUIBridge: Sendable {
    func selectRow(path: String) async
}

public struct WorkspaceControlHandler: Sendable {
    let rows: RowLifecycle
    let plugins: PluginHost
    let ui: any ControlUIBridge

    public init(rows: RowLifecycle, plugins: PluginHost, ui: any ControlUIBridge) {
        self.rows = rows
        self.plugins = plugins
        self.ui = ui
    }

    var workspace: Workspace { rows.workspace }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        guard request.v == ControlCodec.version else {
            return .failure(
                id: request.id,
                error: ControlError(
                    code: "version_mismatch",
                    message:
                        "The app speaks protocol v\(ControlCodec.version) but the CLI sent v\(request.v). Update the linked CLI."
                )
            )
        }
        let response = await ActivitySource.$current.withValue(.cli) { await respond(to: request) }
        if !ControlMethod.notLogged.contains(request.method), await !plugins.readOnlyMethods.contains(request.method) {
            record(request, response)
        }
        return response
    }

    private func respond(to request: ControlRequest) async -> ControlResponse {
        do {
            return .success(id: request.id, result: try await result(for: request))
        } catch let error as WorkspaceError {
            return .failure(id: request.id, error: ControlError(error))
        } catch let error as ControlError {
            return .failure(id: request.id, error: error)
        } catch {
            return .failure(id: request.id, error: ControlError(code: "internal", message: "\(error)"))
        }
    }

    /// Logs calls that change something, with their params as sent and the error code if they failed. Commands typed
    /// into terminals are left out while command logging is off, and so is text starting with a space, which zsh keeps
    /// out of history under hist_ignore_space. A `token` is never logged, wherever it is in the params.
    private func record(_ request: ControlRequest, _ response: ControlResponse) {
        var params = Self.withoutTokens(request.params ?? .object([:]))
        if case .object(var fields) = params {
            for key in ["run", "text"] {
                guard case .string(let typed) = fields[key] else { continue }
                if !workspace.activity.logsCommands || typed.hasPrefix(" ") { fields[key] = nil }
            }
            params = .object(fields)
        }
        var data: [String: JSONValue] = ["method": .string(request.method), "params": params]
        if let error = response.error {
            data["error"] = .string(error.code)
        }
        workspace.activity.record(ActivityType.cliCall, source: .cli, data: data)
    }

    private func result(for request: ControlRequest) async throws -> JSONValue {
        switch request.method {
        case ControlMethod.status:
            return try .from(
                StatusResult(
                    version: CanopyVersion.current,
                    home: workspace.home.root.path,
                    pid: ProcessInfo.processInfo.processIdentifier
                )
            )

        case ControlMethod.repoAdd:
            let params = try request.decodeParams(RepoAddParams.self)
            return try .from(RepoInfo(try await workspace.addRepo(path: params.path)))

        case ControlMethod.repoClone:
            let params = try request.decodeParams(RepoCloneParams.self)
            // The app runs in another folder than the caller, so a relative path would land somewhere unexpected.
            if let into = params.into, !(into as NSString).expandingTildeInPath.hasPrefix("/") {
                throw ControlError(code: "bad_params", message: "into must be an absolute path, not \(into).")
            }
            return try .from(RepoInfo(try await workspace.cloneRepo(params.source, into: params.into)))

        case ControlMethod.repoList:
            return try .from(await workspace.snapshot.repos.map(RepoInfo.init))

        case ControlMethod.repoRemove:
            let params = try request.decodeParams(RepoRemoveParams.self)
            let repo = try TargetResolver.repo(for: TargetHint(repo: params.repo), in: await workspace.snapshot)
            try await rows.removeRepo(path: repo.path)
            return try .from(RepoInfo(repo))

        case ControlMethod.repoCollapse, ControlMethod.repoExpand:
            let params = try request.decodeParams(RepoFoldParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            try await workspace.setRepoCollapsed(
                repoPath: repo.path, collapsed: request.method == ControlMethod.repoCollapse)
            return try .from(RepoInfo(await workspace.snapshot.repo(path: repo.path) ?? repo))

        case ControlMethod.rowList:
            let params = try request.decodeParams(RowListParams.self)
            let snapshot = await workspace.snapshot
            if let repo = params.repo {
                let repo = try TargetResolver.repo(for: TargetHint(repo: repo), in: snapshot)
                return try .from((params.all ? repo.allRows : repo.rows).map(SidebarRow.worktree))
            }
            // Plugin rows come after every repo's, under their plugin's name.
            let worktrees = snapshot.repos.flatMap { params.all ? $0.allRows : $0.rows }.map(SidebarRow.worktree)
            return try .from(worktrees + snapshot.activePlugins.flatMap(\.rows).map(SidebarRow.plugin))

        case ControlMethod.rowNew:
            let params = try request.decodeParams(RowNewParams.self)
            let start = try RowStart(params)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            // Resolved before any git work, so a reference the plugin does not know makes nothing.
            var link: PluginLink?
            if let requested = params.link {
                do {
                    link = try await plugins.resolveLink(plugin: requested.plugin, reference: requested.reference)
                } catch  where requested.fromEnvironment {
                    let error =
                        (error as? ControlError)
                        ?? ControlError(code: Self.code(of: error), message: PluginHost.message(error))
                    throw ControlError(
                        code: error.code,
                        message: error.message
                            + " The link came from the plugin row this ran in. Pass --no-link to make the row without it."
                    )
                }
            }
            let created =
                switch start {
                case .branch(let branch):
                    try await workspace.createRow(
                        repoPath: repo.path, branch: branch, base: params.base, existing: params.existing,
                        group: params.group, link: link)
                case .pullRequest(let reference):
                    try await workspace.createRow(
                        repoPath: repo.path, pullRequest: reference, branch: params.branch, group: params.group,
                        link: link)
                }
            let preparing = await rows.prepare(created.row, repoName: repo.name, setup: params.setup, run: params.run)
            if params.select {
                await select(created.row.path)
            }
            let ready = await preparing.value
            return try .from(
                RowNewResult(
                    row: created.row, source: created.source, base: created.base, pr: created.pullRequest,
                    notes: created.notes, warnings: created.warnings, setup: ready.setup,
                    pane: ready.pane?.description))

        case ControlMethod.rowRemove:
            let params = try request.decodeParams(RowRemoveParams.self)
            let snapshot = await workspace.snapshot
            switch try TargetResolver.sidebarRow(for: params.target, in: snapshot) {
            case .worktree(let row):
                let warnings = try await rows.remove(
                    row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "", force: params.force,
                    deleteBranch: params.deleteBranch)
                return try .from(RowRemoveResult(row: .worktree(row), warnings: warnings))
            case .plugin(let row):
                guard !params.deleteBranch else {
                    throw ControlError(code: "bad_params", message: "A plugin row has no branch to delete.")
                }
                let removed = try await plugins.removeRow(row, force: params.force)
                return try .from(RowRemoveResult(row: .plugin(removed.row), trashedTo: removed.trashedTo))
            }

        case ControlMethod.rowSelect:
            let params = try request.decodeParams(RowRefParams.self)
            let row = try TargetResolver.sidebarRow(for: params.target, in: await workspace.snapshot)
            await select(row.path)
            return try .from(row)

        case ControlMethod.rowAdopt:
            let params = try request.decodeParams(RowAdoptParams.self)
            return try .from(try await workspace.adopt(path: params.path))

        case ControlMethod.rowMove:
            let params = try request.decodeParams(RowMoveParams.self)
            guard params.destinationCount == 1 else {
                throw ControlError(
                    code: "bad_params", message: "row.move takes exactly one of group, noGroup, before, and after.")
            }
            let snapshot = await workspace.snapshot
            let row: Row
            switch try TargetResolver.sidebarRow(for: params.target, in: snapshot) {
            case .worktree(let found): row = found
            case .plugin(let found): return try .from(try await movePluginRow(found, params, in: snapshot))
            }
            let placement: RowPlacement =
                if let group = params.group {
                    .group(group)
                } else if let before = params.before {
                    .before(try anchor(before, besides: row, in: snapshot))
                } else if let after = params.after {
                    .after(try anchor(after, besides: row, in: snapshot))
                } else {
                    .ungrouped
                }
            let moved = try await workspace.moveRow(path: row.path, to: placement)
            return try .from(RowMoveResult(row: .worktree(moved.row), moved: moved.moved, from: moved.from))

        case GroupMethod.list:
            let params = try request.decodeParams(GroupListParams.self)
            let snapshot = await workspace.snapshot
            let repos =
                try params.repo.map { [try TargetResolver.repo(for: TargetHint(repo: $0), in: snapshot)] }
                ?? snapshot.repos
            return try .from(repos.flatMap { repo in repo.groups.map { GroupInfo(repo: repo, group: $0) } })

        case GroupMethod.new:
            let params = try request.decodeParams(GroupParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            return try .from(try await workspace.createGroup(repoPath: repo.path, name: params.name))

        case GroupMethod.rename:
            let params = try request.decodeParams(GroupRenameParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            return try .from(
                try await workspace.renameGroup(repoPath: repo.path, name: params.name, to: params.newName))

        case GroupMethod.remove:
            let params = try request.decodeParams(GroupParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            return try .from(try await workspace.removeGroup(repoPath: repo.path, name: params.name))

        case GroupMethod.collapse, GroupMethod.expand:
            let params = try request.decodeParams(GroupParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            return try .from(
                try await workspace.setGroupCollapsed(
                    repoPath: repo.path, name: params.name, collapsed: request.method == GroupMethod.collapse))

        case ControlMethod.prShow:
            let params = try request.decodeParams(PRShowParams.self)
            let snapshot = await workspace.snapshot
            let row: Row
            switch try TargetResolver.sidebarRow(for: params.target, in: snapshot) {
            case .worktree(let found): row = found
            case .plugin(let found): throw WorkspaceError.noPullRequestLookup(found.displayName)
            }
            let pr = try await workspace.pullRequest(for: row, refresh: params.refresh)
            return try .from(
                PRShowResult(
                    repo: snapshot.repo(path: row.repoPath)?.name ?? "", branch: row.displayName, path: row.path,
                    pr: pr))

        case ControlMethod.prList:
            let params = try request.decodeParams(PRListParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            return try .from(
                try await workspace.listPullRequests(
                    repoPath: repo.path, query: params.query, includeClosed: params.closed))

        case ControlMethod.branchList:
            let params = try request.decodeParams(BranchListParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            return try .from(
                try await workspace.listBranches(repoPath: repo.path, query: params.query, fetch: params.fetch))

        case PortMethod.list:
            let params = try request.decodeParams(PortsListParams.self)
            let row = try await rowUnlessAll(params.target, all: params.all)
            return try .from(await rows.portInfo(rowPath: row?.path))

        case PortMethod.stop:
            let params = try request.decodeParams(PortsStopParams.self)
            let row = try await rowUnlessAll(params.target, all: params.all)
            return try .from(try await rows.stopPort(params.port, rowPath: row?.path))

        case TermMethod.list:
            let params = try request.decodeParams(TermListParams.self)
            let snapshot = await workspace.snapshot
            // Every row's terminals with --all, or when no row resolves.
            var row: SidebarRow?
            if !params.all {
                do {
                    row = try TargetResolver.sidebarRow(for: params.target, in: snapshot)
                } catch WorkspaceError.missingTarget {
                    row = nil
                }
            }
            let names = Dictionary(snapshot.repos.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
            return try .from(await rows.terminalInfo(rowPath: row?.path, repoNames: names))

        case TermMethod.new:
            let params = try request.decodeParams(TermNewParams.self)
            let snapshot = await workspace.snapshot
            switch try TargetResolver.sidebarRow(for: params.target, in: snapshot) {
            case .worktree(let row):
                guard !row.isMissing else { throw WorkspaceError.pathNotFound(row.path) }
                let repoName = snapshot.repo(path: row.repoPath)?.name ?? ""
                return try .from(await rows.newTerminal(PaneContext(row: row, repoName: repoName), params))
            case .plugin(let row):
                await plugins.ensureFolder(row)
                return try .from(await rows.newTerminal(PaneContext(pluginRow: row), params))
            }

        case TermMethod.send:
            let params = try request.decodeParams(TermSendParams.self)
            try await rows.sendToTerminal(params)
            return .object(["pane": .string(params.pane)])

        case TermMethod.read:
            return try .from(try await rows.readTerminal(request.decodeParams(TermReadParams.self)))

        case TermMethod.close:
            let params = try request.decodeParams(TermCloseParams.self)
            try await rows.closeTerminal(params)
            return .object(["pane": .string(params.pane)])

        case TermMethod.state:
            return try .from(try await rows.reportAgent(request.decodeParams(TermStateParams.self)))

        case TermMethod.wait:
            return try .from(try await rows.waitForAgents(request.decodeParams(TermWaitParams.self)))

        case PluginMethod.list:
            return try .from(await plugins.list())

        case PluginMethod.enable:
            let params = try request.decodeParams(PluginEnableParams.self)
            return try .from(try await plugins.enable(params.plugin, with: params.fields))

        case PluginMethod.disable:
            let params = try request.decodeParams(PluginDisableParams.self)
            return try .from(try await plugins.disable(params.plugin, force: params.force))

        case PluginMethod.items:
            let params = try request.decodeParams(PluginItemsParams.self)
            guard let plugin = plugins.plugins.first(where: { $0.info.id == params.plugin }) else {
                throw WorkspaceError.pluginNotFound(params.plugin)
            }
            let query = try plugin.filters.query(text: params.query, filters: params.filters, plugin: plugin.info.name)
            return try .from(try await plugins.items(params.plugin, matching: query))

        case PluginMethod.collapse, PluginMethod.expand:
            let params = try request.decodeParams(PluginFoldParams.self)
            return try .from(try await plugins.setCollapsed(params.plugin, request.method == PluginMethod.collapse))

        case PluginMethod.new:
            let params = try request.decodeParams(PluginNewParams.self)
            return try .from(
                try await plugins.createRow(
                    params.plugin, reference: params.reference, run: params.run, select: params.select))

        default:
            guard await plugins.handles(request.method) else {
                throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
            }
            return try await pluginCall(request)
        }
    }

    /// A plugin's own method, with the plugin row its target points at, if any.
    private func pluginCall(_ request: ControlRequest) async throws -> JSONValue {
        var target = TargetHint()
        if case .object(let fields)? = request.params, let hint = fields["target"] {
            target = (try? hint.decode(TargetHint.self)) ?? TargetHint()
        }
        let row = try? TargetResolver.sidebarRow(for: target, in: await workspace.snapshot).pluginRow
        return try await plugins.call(request.method, params: request.params ?? .object([:]), target: target, row: row)
    }

    /// `row move` for a plugin row: just before or after another row of the same plugin, by path.
    private func movePluginRow(_ row: PluginRow, _ params: RowMoveParams, in snapshot: WorkspaceSnapshot) async throws
        -> RowMoveResult
    {
        guard params.group == nil, !params.noGroup, let name = params.before ?? params.after else {
            throw WorkspaceError.pluginRowsHaveNoGroups
        }
        guard let anchor = try? TargetResolver.sidebarRow(for: TargetHint(row: name), in: snapshot).pluginRow,
            anchor.plugin == row.plugin, anchor.path != row.path
        else { throw WorkspaceError.invalidPluginAnchor(name) }
        let placement: RowPlacement = params.before != nil ? .before(anchor.path) : .after(anchor.path)
        let moved = try await workspace.movePluginRow(path: row.path, to: placement)
        let current = await workspace.snapshot.pluginRow(path: row.path) ?? row
        return RowMoveResult(row: .plugin(current), moved: moved, from: nil)
    }

    static func code(of error: any Error) -> String {
        (error as? WorkspaceError)?.code ?? "internal"
    }

    /// The params with every `token` key taken out, at any depth.
    static func withoutTokens(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            .object(fields.filter { $0.key != "token" }.mapValues(withoutTokens))
        case .array(let items):
            .array(items.map(withoutTokens))
        default:
            value
        }
    }

    /// The resolved row, or nil for every row with `all` or when no row resolves.
    private func rowUnlessAll(_ target: TargetHint, all: Bool) async throws -> SidebarRow? {
        guard !all else { return nil }
        do {
            return try TargetResolver.sidebarRow(for: target, in: await workspace.snapshot)
        } catch WorkspaceError.missingTarget {
            return nil
        }
    }

    /// The row `--before` or `--after` names, looked up among the moved row's repo, so a branch that also exists
    /// in another repo is not ambiguous. It must be another Canopy or adopted row of that repo.
    private func anchor(_ name: String, besides row: Row, in snapshot: WorkspaceSnapshot) throws -> String {
        let found: Row
        do {
            found = try TargetResolver.row(for: TargetHint(repo: row.repoPath, row: name), in: snapshot)
        } catch WorkspaceError.rowNotFound {
            let elsewhere =
                snapshot.repos.contains { $0.allRows.contains { $0.branch == name } }
                || snapshot.pluginRow(path: Paths.canonical(name)) != nil
            throw elsewhere ? WorkspaceError.invalidAnchor(name) : WorkspaceError.rowNotFound(name)
        }
        guard found.repoPath == row.repoPath, found.path != row.path,
            found.rowClass == .canopy || found.rowClass == .adopted
        else { throw WorkspaceError.invalidAnchor(name) }
        return found.path
    }

    /// A row hidden in a folded repo, group, or plugin section unfolds first, so the sidebar shows what is selected.
    private func select(_ path: String) async {
        try? await workspace.revealRow(path: path)
        try? await workspace.setSelectedRow(path: path)
        await ui.selectRow(path: path)
    }
}

/// What `row.new` starts from, once the options the CLI never sends together are refused.
private enum RowStart {
    case branch(String)
    case pullRequest(PRReference)

    init(_ params: RowNewParams) throws {
        func refuse(_ message: String) -> ControlError { ControlError(code: "bad_params", message: message) }
        guard let text = params.pr else {
            guard let branch = params.branch else { throw refuse("Pass a branch name, or a PR with --pr.") }
            if params.existing, params.base != nil {
                throw refuse("--from only applies to new branches, and --existing never creates one.")
            }
            self = .branch(branch)
            return
        }
        if params.base != nil { throw refuse("--from only applies to new branches, and --pr uses the PR's.") }
        if params.existing { throw refuse("--existing is for a branch name. --pr always uses the PR's branch.") }
        guard let reference = PRReference(text) else { throw WorkspaceError.invalidPullRequest(text) }
        self = .pullRequest(reference)
    }
}
