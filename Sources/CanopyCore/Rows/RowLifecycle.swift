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
        let tab = terminals.openTab(for: context, name: "Setup", command: .script(script))
        return Task {
            let code = await tab.pane.waitForExit()
            guard code == 0 else {
                let closed = !terminals.tabs(inRow: row.path).contains { $0.id == tab.id }
                let message =
                    closed
                    ? "Setup stopped because its tab was closed."
                    : "Setup failed with exit code \(code). The Setup tab in \(context.rowName) shows why."
                return RowPreparation(setup: SetupReport(status: .failed, exitCode: code, message: message))
            }
            var pane: Pane?
            if run != nil {
                pane = terminals.openTab(for: context).pane
            } else if terminals.tabs(inRow: row.path).count == 1 {
                terminals.openTab(for: context)
            }
            terminals.closeTab(tab.id, inRow: row.path)
            if let pane, let run { await pane.run(run) }
            return RowPreparation(setup: SetupReport(status: .succeeded, exitCode: 0), pane: pane?.id)
        }
    }

    /// Removes a Canopy row once its teardown commands succeed, or un-adopts an adopted row. The row's terminals
    /// close first. With `force`, neither uncommitted changes nor a failing teardown stop the removal.
    public func remove(_ row: Row, repoName: String, force: Bool, deleteBranch: Bool) async throws {
        switch row.rowClass {
        case .main:
            throw WorkspaceError.cannotRemoveMain
        case .external:
            throw WorkspaceError.notManaged(row.path)
        case .adopted:
            break
        case .canopy:
            // A row whose folder is gone has no checkout to tear down.
            if !row.isMissing {
                // Checked first, so a removal that would be refused anyway does not run teardown.
                if !force, try await workspace.hasUncommittedChanges(path: row.path) {
                    throw WorkspaceError.worktreeDirty(row.path)
                }
                try await tearDown(row, repoName: repoName, force: force)
            }
        }
        terminals.closeRow(path: row.path)
        try await workspace.removeRow(path: row.path, force: force, deleteBranch: deleteBranch)
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
        let tab = terminals.openTab(
            for: PaneContext(row: row, repoName: repoName), name: "Teardown", command: .script(script))
        let code = await tab.pane.waitForExit()
        if code != 0 && !force {
            throw WorkspaceError.teardownFailed(code)
        }
    }
}
