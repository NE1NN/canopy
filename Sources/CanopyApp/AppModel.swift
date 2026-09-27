import AppKit
import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let home: CanopyHome
    let workspace: Workspace
    let terminals: TerminalStore
    let rows: RowLifecycle
    private(set) var snapshot = WorkspaceSnapshot()
    private(set) var toast: String?
    var selectedRowPath: String? {
        didSet {
            if selectedRowPath != oldValue { selectionChanged() }
        }
    }
    private var started = false
    private var toastTask: Task<Void, Never>?
    private var server: ControlServer?

    init(home: CanopyHome) {
        self.home = home
        let workspace = Workspace(home: home)
        let terminals = TerminalStore(
            engine: SwiftTermEngine(), settings: .current(home: home, cliDirectory: Self.bundledCLIDirectory()))
        self.workspace = workspace
        self.terminals = terminals
        self.rows = RowLifecycle(workspace: workspace, terminals: terminals)
    }

    /// The bundle's folder holding `canopy`, which terminals get on their PATH.
    private static func bundledCLIDirectory() -> String? {
        guard let bin = Bundle.main.resourceURL?.appending(path: "bin"),
            FileManager.default.isExecutableFile(atPath: bin.appending(path: "canopy").path)
        else { return nil }
        return bin.path
    }

    var selectedRow: Row? {
        selectedRowPath.flatMap { snapshot.row(path: $0) }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await workspace.start()
        } catch WorkspaceError.homeInUse {
            // Launched with `open -n` while another instance already owns this home; that one serves the CLI.
            NSApplication.shared.terminate(nil)
            return
        } catch {
            show(error)
            return
        }
        if let notice = await workspace.loadNotice {
            show(notice)
        }
        let updates = await workspace.updates()
        Task { [weak self] in
            for await snapshot in updates {
                self?.apply(snapshot)
            }
        }
        await startControlServer()
    }

    func shutdown() {
        server?.stop()
        server = nil
        terminals.closeAll()
    }

    private func startControlServer() async {
        let bridge = AppUIBridge { [weak self] path in await self?.select(path) }
        let handler = WorkspaceControlHandler(rows: rows, ui: bridge)
        let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
        do {
            try await server.start()
            self.server = server
        } catch {
            show("The canopy CLI is unavailable: \(error)")
        }
    }

    // MARK: Rows

    /// ⌘1 to ⌘9, in sidebar order across repos.
    func shortcut(for row: Row) -> Int? {
        guard let index = snapshot.visibleRows.firstIndex(where: { $0.path == row.path }), index < 9 else {
            return nil
        }
        return index + 1
    }

    func selectRow(number: Int) {
        let rows = snapshot.visibleRows
        guard number >= 1, number <= rows.count else { return }
        selectedRowPath = rows[number - 1].path
    }

    func menuTitle(forRow number: Int) -> String {
        let rows = snapshot.visibleRows
        return number <= rows.count ? rows[number - 1].displayName : "Row \(number)"
    }

    func refresh() {
        Task { await workspace.refreshAll() }
    }

    /// Selects a row once the snapshot has it, so a row created a moment ago gets its terminal.
    func select(_ path: String) async {
        apply(await workspace.snapshot)
        selectedRowPath = path
    }

    /// Creates a row, starts its setup, and selects it. Returns an error message for the sheet to show, or nil.
    func createRow(in repo: RepoSnapshot, branch: String, base: String?) async -> String? {
        do {
            let created = try await workspace.createRow(repoPath: repo.path, branch: branch, base: base)
            let preparing = rows.prepare(created.row, repoName: repo.name, setup: true, run: nil)
            await select(created.row.path)
            if let warning = created.warnings.first {
                show(warning)
            }
            Task {
                let ready = await preparing.value
                if ready.setup.status == .failed, let message = ready.setup.message {
                    show(message)
                }
            }
            return nil
        } catch {
            return (error as? WorkspaceError)?.message ?? "\(error)"
        }
    }

    enum RemoveOutcome {
        case removed
        case dirty
        case teardownFailed(Int32)
        case failed(String)
    }

    /// `force` discards uncommitted changes. `skipTeardown` removes anyway after teardown already failed.
    func removeRow(_ row: Row, force: Bool, skipTeardown: Bool, deleteBranch: Bool) async -> RemoveOutcome {
        do {
            let repoName = snapshot.repo(path: row.repoPath)?.name ?? ""
            let warnings = try await rows.remove(
                row, repoName: repoName, force: force, deleteBranch: deleteBranch, skipTeardown: skipTeardown)
            if let warning = warnings.first {
                show(warning)
            }
            return .removed
        } catch WorkspaceError.worktreeDirty {
            return .dirty
        } catch WorkspaceError.teardownFailed(let code) {
            return .teardownFailed(code)
        } catch {
            return .failed((error as? WorkspaceError)?.message ?? "\(error)")
        }
    }

    // MARK: Terminals

    func context(for row: Row) -> PaneContext {
        PaneContext(row: row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "")
    }

    /// A close waiting for the user to confirm, because a program still runs in the terminal.
    struct PendingClose {
        let pane: PaneID
        let program: String
    }

    var pendingClose: PendingClose?

    var selectedTab: TerminalTab? {
        selectedRow.flatMap { terminals.selectedTab(inRow: $0.path) }
    }

    var canOpenTerminal: Bool {
        selectedRow.map { !$0.isMissing } ?? false
    }

    func newTab() {
        guard let row = selectedRow, !row.isMissing else { return }
        terminals.openTab(for: context(for: row))
    }

    /// Closes a terminal, first asking if a program other than the shell still runs in it.
    func requestClose(_ pane: Pane) {
        if pane.isBusy, let program = pane.foreground?.name {
            pendingClose = PendingClose(pane: pane.id, program: program)
        } else {
            terminals.closePane(pane.id)
        }
    }

    func confirmClose() {
        if let pending = pendingClose {
            terminals.closePane(pending.pane)
        }
        pendingClose = nil
    }

    /// ⌘W. Only for the main window itself, so it never closes a terminal behind a sheet or a closed window.
    func closeFocusedPane() {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
            let pane = selectedTab?.pane
        else { return }
        requestClose(pane)
    }

    /// Hands the keyboard back to the terminal on screen, as after renaming a tab.
    func focusSelectedTerminal() {
        (selectedTab?.pane.emulator as? SwiftTermEmulator)?.focus()
    }

    func selectTab(offset: Int) {
        guard let row = selectedRow else { return }
        terminals.selectTab(offset: offset, inRow: row.path)
    }

    // MARK: Repos

    func addRepo(_ url: URL) {
        perform { try await $0.addRepo(path: url.path) }
    }

    /// A repo removal waiting for the user to confirm, because programs still run in its terminals.
    struct PendingRepoRemoval {
        let repo: RepoSnapshot
        let busyTerminals: Int
    }

    var pendingRepoRemoval: PendingRepoRemoval?

    /// Unregisters a repo and closes its terminals, first asking if any of them are running programs.
    func removeRepo(_ repo: RepoSnapshot) {
        let busy = repo.allRows.reduce(0) { $0 + terminals.busyPanes(inRow: $1.path).count }
        if busy > 0 {
            pendingRepoRemoval = PendingRepoRemoval(repo: repo, busyTerminals: busy)
        } else {
            confirmRepoRemoval(repo)
        }
    }

    func confirmRepoRemoval(_ repo: RepoSnapshot) {
        pendingRepoRemoval = nil
        Task {
            do {
                try await rows.removeRepo(path: repo.path)
            } catch {
                show(error)
            }
        }
    }

    func relocateRepo(_ repo: RepoSnapshot, to url: URL) {
        Task {
            do {
                try await rows.relocateRepo(path: repo.path, to: url.path)
            } catch {
                show(error)
            }
        }
    }

    func prune(_ repo: RepoSnapshot) {
        perform { try await $0.prune(repoPath: repo.path) }
    }

    // MARK: Internals

    private func apply(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        terminals.closeRowsGone(from: snapshot)
        if selectedRowPath == nil, let saved = snapshot.selectedRowPath, snapshot.row(path: saved) != nil {
            selectedRowPath = saved
        } else if let path = selectedRowPath, snapshot.row(path: path) == nil {
            selectedRowPath = nil
        }
    }

    private func selectionChanged() {
        let path = selectedRowPath
        if let path, snapshot.row(path: path)?.rowClass == .external {
            perform { _ = try await $0.adopt(path: path) }
        }
        perform { try await $0.setSelectedRow(path: path) }
        // Selecting a row with no tabs opens one. A row whose tabs were all closed stays empty until then.
        if let row = selectedRow {
            terminals.ensureTab(for: context(for: row))
        }
    }

    func perform(_ action: @escaping @Sendable (Workspace) async throws -> Void) {
        Task {
            do {
                try await action(workspace)
            } catch {
                show(error)
            }
        }
    }

    func show(_ error: any Error) {
        show((error as? WorkspaceError)?.message ?? "\(error)")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

struct AppUIBridge: ControlUIBridge {
    let select: @MainActor @Sendable (String) async -> Void

    func selectRow(path: String) async {
        await select(path)
    }
}
