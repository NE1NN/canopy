import Foundation

/// UI actions the control API can trigger. The app implements it on the main actor.
public protocol ControlUIBridge: Sendable {
    func selectRow(path: String) async
}

public struct WorkspaceControlHandler: Sendable {
    let rows: RowLifecycle
    let ui: any ControlUIBridge

    public init(rows: RowLifecycle, ui: any ControlUIBridge) {
        self.rows = rows
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
        record(request, response)
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
    /// out of history under hist_ignore_space.
    private func record(_ request: ControlRequest, _ response: ControlResponse) {
        guard !ControlMethod.readOnly.contains(request.method) else { return }
        var params = request.params ?? .object([:])
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

        case ControlMethod.repoList:
            return try .from(await workspace.snapshot.repos.map(RepoInfo.init))

        case ControlMethod.repoRemove:
            let params = try request.decodeParams(RepoRemoveParams.self)
            let repo = try TargetResolver.repo(for: TargetHint(repo: params.repo), in: await workspace.snapshot)
            try await rows.removeRepo(path: repo.path)
            return try .from(RepoInfo(repo))

        case ControlMethod.rowList:
            let params = try request.decodeParams(RowListParams.self)
            let snapshot = await workspace.snapshot
            let repos =
                try params.repo.map { [try TargetResolver.repo(for: TargetHint(repo: $0), in: snapshot)] }
                ?? snapshot.repos
            return try .from(repos.flatMap { params.all ? $0.allRows : $0.rows })

        case ControlMethod.rowNew:
            let params = try request.decodeParams(RowNewParams.self)
            let start = try RowStart(params)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            let created =
                switch start {
                case .branch(let branch):
                    try await workspace.createRow(
                        repoPath: repo.path, branch: branch, base: params.base, existing: params.existing)
                case .pullRequest(let reference):
                    try await workspace.createRow(repoPath: repo.path, pullRequest: reference, branch: params.branch)
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
            let row = try TargetResolver.row(for: params.target, in: snapshot)
            let warnings = try await rows.remove(
                row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "", force: params.force,
                deleteBranch: params.deleteBranch)
            return try .from(RowRemoveResult(row: row, warnings: warnings))

        case ControlMethod.rowSelect:
            let params = try request.decodeParams(RowRefParams.self)
            let row = try TargetResolver.row(for: params.target, in: await workspace.snapshot)
            await select(row.path)
            return try .from(row)

        case ControlMethod.rowAdopt:
            let params = try request.decodeParams(RowAdoptParams.self)
            return try .from(try await workspace.adopt(path: params.path))

        case ControlMethod.prShow:
            let params = try request.decodeParams(PRShowParams.self)
            let snapshot = await workspace.snapshot
            let row = try TargetResolver.row(for: params.target, in: snapshot)
            let pr = try await workspace.pullRequest(for: row, refresh: params.refresh)
            return try .from(
                PRShowResult(
                    repo: snapshot.repo(path: row.repoPath)?.name ?? "", branch: row.displayName, path: row.path,
                    pr: pr))

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
            var row: Row?
            if !params.all {
                do {
                    row = try TargetResolver.row(for: params.target, in: snapshot)
                } catch WorkspaceError.missingTarget {
                    row = nil
                }
            }
            let names = Dictionary(snapshot.repos.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
            return try .from(await rows.terminalInfo(rowPath: row?.path, repoNames: names))

        case TermMethod.new:
            let params = try request.decodeParams(TermNewParams.self)
            let snapshot = await workspace.snapshot
            let row = try TargetResolver.row(for: params.target, in: snapshot)
            guard !row.isMissing else { throw WorkspaceError.pathNotFound(row.path) }
            let repoName = snapshot.repo(path: row.repoPath)?.name ?? ""
            return try .from(await rows.newTerminal(row, repoName: repoName, params))

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

        default:
            throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
        }
    }

    /// The resolved row, or nil for every row with `all` or when no row resolves.
    private func rowUnlessAll(_ target: TargetHint, all: Bool) async throws -> Row? {
        guard !all else { return nil }
        do {
            return try TargetResolver.row(for: target, in: await workspace.snapshot)
        } catch WorkspaceError.missingTarget {
            return nil
        }
    }

    private func select(_ path: String) async {
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
