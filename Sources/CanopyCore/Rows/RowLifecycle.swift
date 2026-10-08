import Foundation

/// How setup went for a new row.
public struct SetupReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The row's checkout has no setup commands.
        case none
        /// Setup was turned off, as with `--no-setup`.
        case skipped
        case succeeded
        case failed
    }

    public var status: Status
    public var exitCode: Int32?
    public var message: String?

    public init(status: Status, exitCode: Int32? = nil, message: String? = nil) {
        self.status = status
        self.exitCode = exitCode
        self.message = message
    }
}

/// A new row, ready: its setup outcome and the pane started for `--run`.
public struct RowPreparation: Sendable, Equatable {
    public var setup: SetupReport
    public var pane: PaneID?

    public init(setup: SetupReport, pane: PaneID? = nil) {
        self.setup = setup
        self.pane = pane
    }
}

/// The parts of creating and removing a row that involve its terminals: setup runs in a visible tab before the
/// row is used, and teardown runs in one before it goes. The UI and the control API both come through here.
@MainActor
public final class RowLifecycle {
    public nonisolated let workspace: Workspace
    public let terminals: TerminalStore

    public init(workspace: Workspace, terminals: TerminalStore) {
        self.workspace = workspace
        self.terminals = terminals
        terminals.remoteHooks = self
    }

    /// Opens the new row's first tab before returning, either Setup or the `run` command, so a caller that selects
    /// the row next does not also get a blank terminal. The task ends when setup has and `run` has been typed.
    /// A successful Setup tab closes, leaving the `run` pane or a plain terminal. A failed one stays open.
    public func prepare(_ row: Row, repoName: String, setup: Bool, run: String?) -> Task<RowPreparation, Never> {
        let context = PaneContext(row: row, repoName: repoName)
        let commands: [String]
        do {
            commands = setup ? try RepoConfig.load(from: row.path).setup : []
        } catch {
            let report = SetupReport(status: .failed, message: (error as? WorkspaceError)?.message ?? "\(error)")
            return Task { RowPreparation(setup: report) }
        }

        guard !commands.isEmpty else {
            let pane = run.map { _ in terminals.openTab(for: context).pane }
            let report = SetupReport(status: setup ? .none : .skipped)
            return Task {
                if let pane, let run { await pane.run(run) }
                return RowPreparation(setup: report, pane: pane?.id)
            }
        }

        let script = SetupScript.render(commands, label: "Setup")
        // The setup pane, not its tab: the user may split the Setup tab while setup runs.
        let setupPane = terminals.openTab(for: context, name: "Setup", command: .script(script)).pane
        return Task {
            let code = await setupPane.waitForExit()
            guard code == 0 else {
                let closed = terminals.tab(containing: setupPane.id) == nil
                let message =
                    closed
                    ? "Setup stopped because its tab was closed."
                    : "Setup failed with exit code \(code). The Setup tab in \(context.rowName) shows why."
                return RowPreparation(setup: SetupReport(status: .failed, exitCode: code, message: message))
            }
            var pane: Pane?
            if run != nil {
                pane = terminals.openTab(for: context).pane
            } else if terminals.tabs(inRow: row.path).count == 1,
                terminals.tab(containing: setupPane.id)?.1.paneList.count == 1
            {
                terminals.openTab(for: context)
            }
            // Closes the tab only if setup's pane was all it held.
            terminals.closePane(setupPane.id)
            if let pane, let run { await pane.run(run) }
            return RowPreparation(setup: SetupReport(status: .succeeded, exitCode: 0), pane: pane?.id)
        }
    }

    /// Removes a Canopy row once its teardown commands succeed, or un-adopts an adopted row. The row's terminals
    /// close first. With `force`, neither uncommitted changes nor a failing teardown stop the removal.
    /// `skipTeardown` is for removing anyway after teardown already failed, without discarding changes.
    /// Returns warnings about what failed after the row was gone.
    @discardableResult
    public func remove(
        _ row: Row, repoName: String, force: Bool, deleteBranch: Bool, skipTeardown: Bool = false
    ) async throws -> [String] {
        switch row.rowClass {
        case .main:
            throw WorkspaceError.cannotRemoveMain
        case .external:
            throw WorkspaceError.notManaged(row.path)
        case .remote:
            if !force, try await workspace.remoteHasUncommittedChanges(standIn: row.path) {
                throw WorkspaceError.worktreeDirty(row.path)
            }
            // The host removes a worktree its sessions are in, so they end only once the row is gone, and a removal
            // that fails leaves them running.
            let warnings = try await workspace.removeRemoteRow(
                standIn: row.path, force: force, deleteBranch: deleteBranch)
            terminals.closeRow(path: row.path)
            return warnings
        case .adopted:
            break
        case .canopy:
            // A row whose folder is gone has no checkout to tear down.
            if !row.isMissing {
                // Checked first, so a removal that would be refused anyway does not run teardown.
                if !force, try await workspace.hasUncommittedChanges(path: row.path) {
                    throw WorkspaceError.worktreeDirty(row.path)
                }
                if !skipTeardown {
                    try await tearDown(row, repoName: repoName, force: force)
                }
            }
        }
        terminals.closeRow(path: row.path)
        return try await workspace.removeRow(path: row.path, force: force, deleteBranch: deleteBranch)
    }

    /// Unregisters a repo and closes the terminals in its rows. Its files stay where they are.
    public func removeRepo(path: String) async throws {
        try await workspace.removeRepo(path: path)
        terminals.closeRows(ofRepo: path)
    }

    /// Points a missing repo at its new folder. Its terminals follow it.
    public func relocateRepo(path: String, to newPath: String) async throws {
        let mainPath = try await workspace.relocateRepo(path: path, to: newPath)
        terminals.moveRows(ofRepo: path, to: mainPath)
    }

    private func tearDown(_ row: Row, repoName: String, force: Bool) async throws {
        let commands: [String]
        do {
            commands = try RepoConfig.load(from: row.path).teardown
        } catch  where force {
            return
        }
        guard !commands.isEmpty else { return }
        let script = SetupScript.render(commands, label: "Teardown")
        let teardownPane = terminals.openTab(
            for: PaneContext(row: row, repoName: repoName), name: "Teardown", command: .script(script)
        ).pane
        let code = await teardownPane.waitForExit()
        guard code != 0, !force else { return }
        let closed = terminals.tab(containing: teardownPane.id) == nil
        throw closed ? WorkspaceError.teardownStopped : WorkspaceError.teardownFailed(code)
    }
}

/// A remote pane, as its attach command needs it.
public struct RemotePaneInfo: Sendable, Equatable {
    public var pane: String
    public var host: String
    public var session: String
    /// Where the session starts when the host has none.
    public var folder: String
    public var repoPath: String
    public var rowName: String
}

extension RowLifecycle: RemotePaneHooks {
    public func run(_ text: String, in pane: Pane) async {
        guard let remote = pane.context.remote, let session = pane.remoteSession else { return }
        await workspace.sendKeys(text, to: session, on: remote.host)
    }

    public func closed(_ panes: [Pane]) {
        var sessions: [String: [String]] = [:]
        for pane in panes {
            guard let remote = pane.context.remote, let session = pane.remoteSession else { continue }
            sessions[remote.host, default: []].append(session)
        }
        for (host, names) in sessions {
            Task { await workspace.killSessions(names, on: host) }
        }
    }

    public func remotePaneInfo(_ id: String) -> RemotePaneInfo? {
        guard let paneID = PaneID(id), let pane = terminals.pane(paneID), let remote = pane.context.remote,
            let session = pane.remoteSession, let repoPath = pane.context.repoPath
        else { return nil }
        return RemotePaneInfo(
            pane: id, host: remote.host, session: session,
            folder: pane.remoteActivity?.folder ?? pane.remoteFolder ?? remote.path, repoPath: repoPath,
            rowName: pane.context.rowName)
    }
}
