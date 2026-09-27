import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let home: CanopyHome
    let workspace: Workspace
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
        self.workspace = Workspace(home: home)
    }

    var selectedRow: Row? {
        selectedRowPath.flatMap { snapshot.row(path: $0) }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await workspace.start()
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
    }

    private func startControlServer() async {
        let bridge = AppUIBridge { [weak self] path in self?.selectedRowPath = path }
        let handler = WorkspaceControlHandler(workspace: workspace, ui: bridge)
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

    /// Creates a row and selects it. Returns an error message for the sheet to show, or nil.
    func createRow(in repo: RepoSnapshot, branch: String, base: String?) async -> String? {
        do {
            let created = try await workspace.createRow(repoPath: repo.path, branch: branch, base: base)
            selectedRowPath = created.row.path
            if let warning = created.warnings.first {
                show(warning)
            }
            return nil
        } catch {
            return (error as? WorkspaceError)?.message ?? "\(error)"
        }
    }

    enum RemoveOutcome {
        case removed
        case dirty
        case failed(String)
    }

    func removeRow(_ row: Row, force: Bool, deleteBranch: Bool) async -> RemoveOutcome {
        do {
            try await workspace.removeRow(path: row.path, force: force, deleteBranch: deleteBranch)
            return .removed
        } catch WorkspaceError.worktreeDirty {
            return .dirty
        } catch {
            return .failed((error as? WorkspaceError)?.message ?? "\(error)")
        }
    }

    // MARK: Repos

    func addRepo(_ url: URL) {
        perform { try await $0.addRepo(path: url.path) }
    }

    func removeRepo(_ repo: RepoSnapshot) {
        perform { try await $0.removeRepo(path: repo.path) }
    }

    func relocateRepo(_ repo: RepoSnapshot, to url: URL) {
        perform { try await $0.relocateRepo(path: repo.path, to: url.path) }
    }

    func prune(_ repo: RepoSnapshot) {
        perform { try await $0.prune(repoPath: repo.path) }
    }

    // MARK: Internals

    private func apply(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
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
    let select: @MainActor @Sendable (String) -> Void

    func selectRow(path: String) async {
        await select(path)
    }
}
