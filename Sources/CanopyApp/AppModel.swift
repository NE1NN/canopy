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
