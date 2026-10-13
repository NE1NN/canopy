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
                    var plugin: String?
                    if case .plugin(let id, _) = pane.context.owner { plugin = id }
                    return TermInfo(
                        pane: pane.id.description,
                        repo: pane.context.repoPath.flatMap { repoNames[$0] } ?? pane.context.repoName, plugin: plugin,
                        row: pane.context.rowName, rowPath: path, tab: tab.name, title: pane.title,
                        folder: pane.currentDirectory ?? pane.terminal?.startDirectory ?? path,
                        foreground: pane.chat.map { $0.isRunning ? "claude" : nil } ?? pane.foreground?.name,
                        exited: exited, kind: pane.chat == nil ? "terminal" : "chat",
                        agent: pane.agent.state == .none ? nil : pane.agent.state,
                        backgroundTasks: pane.agent.backgroundTasks.isEmpty ? nil : pane.agent.backgroundTasks)
                }
            }
        }
    }

    /// The panes open in these rows, in order.
    public func paneIDs(inRows paths: [String]) -> [String] {
        paths.flatMap { terminals.tabs(inRow: $0).flatMap(\.paneList).map(\.id.description) }
    }

    public func newTerminal(_ context: PaneContext, _ params: TermNewParams) async -> TermNewResult {
        let name = params.tab.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let (tab, pane) = terminals.openTerminal(for: context, tabNamed: name, newTab: params.newTab)
        if let title = params.title { pane.fixedTitle = title }
        if let run = params.run { await pane.terminal?.run(run) }
        return TermNewResult(pane: pane.id.description, tab: tab.name)
    }

    /// Opens a chat tab in the row, as New Chat does, and sends `prompt` as its first message.
    public func newChat(_ context: PaneContext, _ params: ChatNewParams) throws -> ChatNewResult {
        if context.remote != nil {
            throw ControlError(code: "remote_row", message: "Chats run in this Mac's rows for now.")
        }
        if let mode = params.mode, !ChatNewParams.modes.contains(mode) {
            throw ControlError(
                code: "bad_params",
                message: "--mode must be one of \(ChatNewParams.modes.joined(separator: ", ")), not \(mode).")
        }
        if let session = params.resume, let holder = terminals.pane(holdingSession: session) {
            throw ControlError(
                code: "session_open", message: "Session \(session) is open in \(holder.id.description) already.")
        }
        let (tab, pane) = terminals.openChat(
            for: context, session: params.resume, model: params.model, mode: params.mode)
        if let prompt = params.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pane.chat?.send(prompt)
        }
        return ChatNewResult(pane: pane.id.description, tab: tab.name)
    }

    public func sendToTerminal(_ params: TermSendParams) async throws {
        let pane = try terminal(params.pane)
        // A chat takes it as the composer would: Enter sends it, otherwise it waits in the draft.
        if let chat = pane.chat {
            if params.enter {
                chat.send(chat.draft + params.text)
                chat.draft = ""
            } else {
                chat.draft += params.text
            }
            return
        }
        guard case .running = pane.status else { throw WorkspaceError.paneExited(params.pane) }
        guard let terminal = pane.terminal else { throw WorkspaceError.notATerminal(params.pane) }
        await terminal.type(params.text, enter: params.enter)
    }

    public func readTerminal(_ params: TermReadParams) throws -> TermReadResult {
        let pane = try terminal(params.pane)
        if let lines = params.lines, lines < 1 {
            throw ControlError(code: "bad_params", message: "--lines must be at least 1.")
        }
        if let chat = pane.chat {
            chat.open()
            let text = chat.readableText
            guard let count = params.lines else { return TermReadResult(text: text) }
            return TermReadResult(
                text: text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count)
                    .joined(separator: "\n"))
        }
        guard let emulator = pane.terminal?.emulator else { throw WorkspaceError.notATerminal(params.pane) }
        let text = params.lines.map { emulator.recentText(lines: $0) } ?? emulator.screenText()
        return TermReadResult(text: text)
    }

    public func closeTerminal(_ params: TermCloseParams) throws {
        let pane = try terminal(params.pane)
        if pane.hasRunningWork, !params.force {
            throw WorkspaceError.paneBusy(
                params.pane, program: pane.chat == nil ? pane.foreground?.name ?? "A program" : "Claude")
        }
        terminals.closePane(pane.id)
    }

    func terminal(_ id: String) throws -> Pane {
        guard let paneID = PaneID(id), let pane = terminals.pane(paneID) else { throw WorkspaceError.paneNotFound(id) }
        return pane
    }
}
