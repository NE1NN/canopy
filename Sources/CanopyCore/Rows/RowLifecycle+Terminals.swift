import Foundation

/// What `canopy term` does, on the main actor where terminals live.
extension RowLifecycle {
    /// Terminals in one row, or in every row when `rowPath` is nil.
    public func terminalInfo(rowPath: String?, repoNames: [String: String]) -> [TermInfo] {
        let paths = rowPath.map { [$0] } ?? terminals.tabsByRow.keys.sorted()
        return paths.flatMap { path in
            terminals.tabs(inRow: path).flatMap { tab in
                tab.paneList.map { pane in
                    pane.refreshTitle()
                    var exited: Int32?
                    if case .exited(let code) = pane.status { exited = code }
                    return TermInfo(
                        pane: pane.id.description, repo: repoNames[pane.context.repoPath] ?? pane.context.repoName,
                        row: pane.context.rowName, rowPath: path, tab: tab.name, title: pane.title,
                        folder: pane.currentDirectory ?? pane.startDirectory ?? path,
                        foreground: pane.foreground?.name, exited: exited,
                        agent: pane.agent.state == .none ? nil : pane.agent.state)
                }
            }
        }
    }

    public func newTerminal(_ row: Row, repoName: String, _ params: TermNewParams) async -> TermNewResult {
        let context = PaneContext(row: row, repoName: repoName)
        let name = params.tab.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let (tab, pane) = terminals.openTerminal(for: context, tabNamed: name, newTab: params.newTab)
        if let title = params.title { pane.fixedTitle = title }
        if let run = params.run { await pane.run(run) }
        return TermNewResult(pane: pane.id.description, tab: tab.name)
    }

    public func sendToTerminal(_ params: TermSendParams) async throws {
        let pane = try terminal(params.pane)
        guard case .running = pane.status else { throw WorkspaceError.paneExited(params.pane) }
        await pane.type(params.text, enter: params.enter)
    }

    public func readTerminal(_ params: TermReadParams) throws -> TermReadResult {
        let pane = try terminal(params.pane)
        if let lines = params.lines, lines < 1 {
            throw ControlError(code: "bad_params", message: "--lines must be at least 1.")
        }
        let text = params.lines.map { pane.emulator.recentText(lines: $0) } ?? pane.emulator.screenText()
        return TermReadResult(text: text)
    }

    public func closeTerminal(_ params: TermCloseParams) throws {
        let pane = try terminal(params.pane)
        if pane.isBusy, !params.force {
            throw WorkspaceError.paneBusy(params.pane, program: pane.foreground?.name ?? "A program")
        }
        terminals.closePane(pane.id)
    }

    func terminal(_ id: String) throws -> Pane {
        guard let paneID = PaneID(id), let pane = terminals.pane(paneID) else { throw WorkspaceError.paneNotFound(id) }
        return pane
    }
}
