import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class TerminalTab: Identifiable {
    public let id: TabID
    public internal(set) var name: String
    public internal(set) var layout: Layout<PaneID>
    public internal(set) var panes: [PaneID: Pane]
    public internal(set) var focusedPaneID: PaneID

    init(id: TabID, name: String, pane: Pane) {
        self.id = id
        self.name = name
        self.layout = .leaf(pane.id)
        self.panes = [pane.id: pane]
        self.focusedPaneID = pane.id
    }

    /// Panes in layout order: left to right, then top to bottom.
    public var paneList: [Pane] {
        layout.leaves.compactMap { panes[$0] }
    }

    /// The pane `⌘W` closes and typing goes to.
    public var focused: Pane {
        panes[focusedPaneID] ?? paneList[0]
    }

    var repoPath: String? {
        paneList.first?.context.repoPath
    }
}

/// Every row's tabs and terminals. Terminals keep running while their row or tab is out of view.
@MainActor
@Observable
public final class TerminalStore {
    /// Each row's tabs in tab bar order, keyed by row path.
    public private(set) var tabsByRow: [String: [TerminalTab]] = [:]
    private var selectedTabByRow: [String: TabID] = [:]
    /// The size new terminals start at, so one opened in the background already fits the window.
    public var preferredSize = TerminalSize.standard
    /// Called after any change worth saving: tabs, names, layouts, focus, or selection.
    @ObservationIgnored public var onChange: () -> Void = {}
    @ObservationIgnored public let settings: ShellSettings
    @ObservationIgnored private let engine: any TerminalEngine
    @ObservationIgnored private var nextPane = 1
    @ObservationIgnored private var nextTab = 1
    /// Rows seen in a snapshot while they had terminals, so a row created a moment ago is not mistaken for one
    /// that went away.
    @ObservationIgnored private var seenRows: Set<String> = []

    public init(engine: any TerminalEngine, settings: ShellSettings) {
        self.engine = engine
        self.settings = settings
    }

    public func tabs(inRow path: String) -> [TerminalTab] {
        tabsByRow[path] ?? []
    }

    public func selectedTab(inRow path: String) -> TerminalTab? {
        let tabs = tabs(inRow: path)
        return tabs.first { $0.id == selectedTabByRow[path] } ?? tabs.first
    }

    public var panes: [Pane] {
        tabsByRow.values.flatMap { $0.flatMap(\.paneList) }
    }

    public func pane(_ id: PaneID) -> Pane? {
        panes.first { $0.id == id }
    }

    public var busyPanes: [Pane] {
        panes.filter(\.isBusy)
    }

    public func busyPanes(inRow path: String) -> [Pane] {
        tabs(inRow: path).flatMap(\.paneList).filter(\.isBusy)
    }

    // MARK: Tabs

    /// Opens a tab with one pane at the end of the row's tab bar and selects it.
    @discardableResult
    public func openTab(
        for context: PaneContext, name: String? = nil, command: PaneCommand = .shell, directory: String? = nil
    ) -> TerminalTab {
        let tabs = tabs(inRow: context.rowPath)
        let tab = TerminalTab(
            id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.map(\.name)),
            pane: makePane(context, command: command, directory: directory))
        nextTab += 1
        tabsByRow[context.rowPath] = tabs + [tab]
        selectedTabByRow[context.rowPath] = tab.id
        onChange()
        return tab
    }

    /// A row on screen with no tabs gets one. A row whose folder is gone gets none, not a shell somewhere else.
    public func ensureTab(for context: PaneContext) {
        guard tabs(inRow: context.rowPath).isEmpty, FileManager.default.fileExists(atPath: context.rowPath) else {
            return
        }
        openTab(for: context)
    }

    public func selectTab(_ id: TabID, inRow path: String) {
        guard tabs(inRow: path).contains(where: { $0.id == id }) else { return }
        selectedTabByRow[path] = id
        onChange()
    }

    /// Moves the selection by `offset` tabs, wrapping around at the ends.
    public func selectTab(offset: Int, inRow path: String) {
        let tabs = tabs(inRow: path)
        guard let current = selectedTab(inRow: path), let index = tabs.firstIndex(where: { $0.id == current.id })
        else { return }
        let count = tabs.count
        selectTab(tabs[((index + offset) % count + count) % count].id, inRow: path)
    }

    public func renameTab(_ id: TabID, inRow path: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }) else { return }
        tab.name = trimmed
        onChange()
    }

    /// Closes a tab and its terminals. If it was selected, the tab to its right takes over, or else the new last tab.
    public func closeTab(_ id: TabID, inRow path: String) {
        var tabs = tabs(inRow: path)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab(inRow: path)?.id == id
        for pane in tabs.remove(at: index).paneList {
            pane.close()
        }
        tabsByRow[path] = tabs.isEmpty ? nil : tabs
        if tabs.isEmpty {
            selectedTabByRow[path] = nil
        } else if wasSelected {
            selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
        }
        onChange()
    }

    // MARK: Panes

    /// Adds a pane to the row's selected tab by the add rule, where `fits` says whether a line of that many panes
    /// keeps each one wide enough, and focuses it. Opens a tab if the row has none.
    @discardableResult
    public func addPane(for context: PaneContext, fits: (Int) -> Bool) -> Pane {
        guard let tab = selectedTab(inRow: context.rowPath) else {
            return openTab(for: context).focused
        }
        let pane = makePane(context, command: .shell, directory: nil)
        tab.panes[pane.id] = pane
        tab.layout = tab.layout.adding(pane.id, fits: fits)
        tab.focusedPaneID = pane.id
        onChange()
        return pane
    }

    /// Closes a pane and hands its space to its neighbors. Closing a tab's last pane closes the tab.
    public func closePane(_ id: PaneID) {
        guard let found = tab(containing: id) else { return }
        let (path, tab) = found
        guard let layout = tab.layout.removing(id) else {
            closeTab(tab.id, inRow: path)
            return
        }
        if tab.focusedPaneID == id {
            // Focus moves to the pane that came before it in layout order, or else the one after.
            let order = tab.layout.leaves
            let index = order.firstIndex(of: id) ?? 0
            tab.focusedPaneID = index > 0 ? order[index - 1] : order[index + 1]
        }
        tab.panes.removeValue(forKey: id)?.close()
        tab.layout = layout
        onChange()
    }

    public func focus(_ id: PaneID) {
        guard let tab = tab(containing: id)?.1, tab.focusedPaneID != id else { return }
        tab.focusedPaneID = id
        onChange()
    }

    /// Focuses the pane next to the focused one in `direction`, laid out in `rect`. Returns it, if there is one.
    @discardableResult
    public func focusNeighbor(inRow path: String, toward direction: Direction, in rect: CGRect) -> Pane? {
        guard let tab = selectedTab(inRow: path),
            let neighbor = tab.layout.neighbor(of: tab.focusedPaneID, toward: direction, in: rect)
        else { return nil }
        focus(neighbor)
        return tab.panes[neighbor]
    }

    /// Drops `moved` on `target`: on an edge it splits the target 50/50, and in the middle the two swap.
    /// Both must be in the same tab.
    public func movePane(_ moved: PaneID, to zone: DropZone, of target: PaneID) {
        guard moved != target, let tab = tab(containing: moved)?.1, tab.panes[target] != nil else { return }
        switch zone {
        case .center: tab.layout = tab.layout.swapping(moved, target)
        case .edge(let edge): tab.layout = tab.layout.moving(moved, to: edge, of: target)
        }
        onChange()
    }

    public func resize(
        _ tab: TerminalTab, divider: DividerID, to position: Double, in rect: CGRect, minimum: CGSize
    ) {
        let layout = tab.layout.resizing(divider, to: position, in: rect, minimum: minimum)
        guard layout != tab.layout else { return }
        tab.layout = layout
        onChange()
    }

    public func tab(containing id: PaneID) -> (String, TerminalTab)? {
        for (path, tabs) in tabsByRow {
            if let tab = tabs.first(where: { $0.panes[id] != nil }) {
                return (path, tab)
            }
        }
        return nil
    }

    // MARK: Rows

    public func closeRow(path: String) {
        for pane in tabs(inRow: path).flatMap(\.paneList) {
            pane.close()
        }
        tabsByRow[path] = nil
        selectedTabByRow[path] = nil
        seenRows.remove(path)
        onChange()
    }

    /// Closes the terminals of rows that are gone from a repo git could list, such as a worktree removed with
    /// plain git, so they neither keep running out of reach nor come back when a new row reuses the folder.
    /// Repos that are missing or failed to refresh keep their terminals.
    public func closeRowsGone(from snapshot: WorkspaceSnapshot) {
        for (path, tabs) in tabsByRow {
            guard let repoPath = tabs.first?.repoPath,
                let repo = snapshot.repo(path: repoPath), !repo.isMissing, repo.error == nil
            else { continue }
            if repo.allRows.contains(where: { $0.path == path }) {
                seenRows.insert(path)
            } else if seenRows.contains(path) {
                closeRow(path: path)
            }
        }
    }

    /// Closes every terminal in a repo's rows, for when the repo is unregistered.
    public func closeRows(ofRepo repoPath: String) {
        for (path, tabs) in tabsByRow where tabs.first?.repoPath == repoPath {
            closeRow(path: path)
        }
    }

    /// Follows a repo that moved: rows inside its old folder move with it, and every pane learns its new paths.
    public func moveRows(ofRepo oldRepoPath: String, to newRepoPath: String) {
        for (path, tabs) in tabsByRow where tabs.first?.repoPath == oldRepoPath {
            let newPath = Paths.isInside(path, oldRepoPath) ? newRepoPath + path.dropFirst(oldRepoPath.count) : path
            for pane in tabs.flatMap(\.paneList) {
                pane.context.repoPath = newRepoPath
                pane.context.rowPath = newPath
            }
            tabsByRow[path] = nil
            tabsByRow[newPath] = tabs
            if let selected = selectedTabByRow.removeValue(forKey: path) {
                selectedTabByRow[newPath] = selected
            }
            if seenRows.remove(path) != nil {
                seenRows.insert(newPath)
            }
        }
        onChange()
    }

    public func closeAll() {
        for path in Array(tabsByRow.keys) {
            closeRow(path: path)
        }
    }

    // MARK: Saving and restoring

    /// Every row's tabs as they would be restored: names, layouts, and each pane's current folder.
    public func saved() -> [String: SavedRowTerminals] {
        var saved: [String: SavedRowTerminals] = [:]
        for (path, tabs) in tabsByRow {
            saved[path] = SavedRowTerminals(
                tabs: tabs.map { tab in
                    SavedTab(
                        name: tab.name,
                        layout: tab.layout.map { id in
                            let pane = tab.panes[id]
                            return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
                        },
                        focused: tab.layout.leaves.firstIndex(of: tab.focusedPaneID)
                    )
                },
                selectedTab: tabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0
            )
        }
        return saved
    }

    /// Rebuilds a row's saved tabs with fresh shells in the saved folders. Folders that are gone fall back to the
    /// row's own. Replaces nothing: a row that already has tabs keeps them.
    public func restore(_ saved: SavedRowTerminals, for context: PaneContext) {
        guard tabs(inRow: context.rowPath).isEmpty, !saved.tabs.isEmpty else { return }
        let tabs = saved.tabs.map { savedTab in
            let leaves = savedTab.layout.leaves
            let panes = leaves.map { makePane(context, command: .shell, directory: $0.folder) }
            var index = 0
            let layout: Layout<PaneID> = savedTab.layout.map { _ in
                defer { index += 1 }
                return panes[index].id
            }
            let tab = TerminalTab(id: TabID(nextTab), name: savedTab.name, pane: panes[0])
            nextTab += 1
            tab.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
            tab.layout = layout
            tab.focusedPaneID =
                savedTab.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
            return tab
        }
        tabsByRow[context.rowPath] = tabs
        selectedTabByRow[context.rowPath] = tabs[min(max(saved.selectedTab, 0), tabs.count - 1)].id
    }

    private func makePane(_ context: PaneContext, command: PaneCommand, directory: String?) -> Pane {
        defer { nextPane += 1 }
        return Pane(
            id: PaneID(nextPane), context: context, command: command, settings: settings,
            emulator: engine.makeEmulator(size: preferredSize), directory: directory)
    }
}
