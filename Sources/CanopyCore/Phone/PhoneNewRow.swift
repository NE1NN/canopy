import Foundation

extension RowLifecycle {
    /// A task from the phone: a row in one of this Mac's repos by `row new`'s branch rules, its setup, then a tab typing
    /// `line`, whose shell has the brief in `PhoneAgentCommand.briefVariable`. The row is not selected, so the Mac's
    /// window stays where the author left it.
    public func phoneNewRow(_ params: PhoneNewRowParams, line: String) async throws -> PhoneNewRowResult {
        let snapshot = await workspace.snapshot
        guard let repo = TargetResolver.match(repo: params.repo, in: snapshot) else {
            throw WorkspaceError.repoNotFound(params.repo)
        }
        let created = try await workspace.createRow(repoPath: repo.path, branch: params.branch, base: params.base)
        let row = created.row
        let brief = params.brief.isEmpty ? [:] : [PhoneAgentCommand.briefVariable: params.brief]
        let ready = await prepare(row, repoName: repo.name, setup: true, run: line, environment: brief).value
        guard let pane = ready.pane else {
            let name = row.branch ?? (row.path as NSString).lastPathComponent
            throw ControlError(
                code: "setup_failed",
                message: "Made the row \(name), but its setup failed, so the agent did not start. "
                    + (ready.setup.message ?? ""))
        }
        let warnings = created.warnings
        return PhoneNewRowResult(
            path: row.path, branch: row.branch ?? params.branch, pane: pane.description,
            warnings: warnings.isEmpty ? nil : warnings)
    }
}
