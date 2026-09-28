import Foundation

/// What `canopy term state` and `canopy term wait` do, on the main actor where terminals live.
extension RowLifecycle {
    public func reportAgent(_ params: TermStateParams) throws -> TermStateResult {
        guard params.state != nil || params.session != nil else {
            throw ControlError(code: "bad_params", message: "Pass a state: working, waiting, done, or none.")
        }
        let pane = try terminal(params.pane)
        pane.report(params.report)
        return TermStateResult(pane: params.pane, state: pane.agent.state)
    }

    public func waitForAgents(_ params: TermWaitParams) async throws -> TermWaitResult {
        guard !params.panes.isEmpty else {
            throw ControlError(code: "bad_params", message: "Name at least one terminal to wait for.")
        }
        guard params.timeout.isFinite, params.timeout >= 0 else {
            throw ControlError(code: "bad_params", message: "The timeout must be zero or more seconds.")
        }
        let ids = try params.panes.map { text in
            guard let id = PaneID(text) else { throw WorkspaceError.paneNotFound(text) }
            return id
        }
        // A year is as long as anyone waits, and keeps the milliseconds in range.
        let milliseconds = Int64(min(params.timeout, 366 * 86_400) * 1000)
        let (pane, state) = try await terminals.waitForAgents(
            ids, for: params.target, timeout: .milliseconds(milliseconds))
        return TermWaitResult(pane: pane.id.description, state: state)
    }
}
