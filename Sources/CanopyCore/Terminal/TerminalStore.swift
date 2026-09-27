import Foundation
import Observation

@MainActor
@Observable
public final class TerminalTab: Identifiable {
    public let id: TabID
    public internal(set) var name: String
    /// A tab holds one pane until the grid arrives.
    public let pane: Pane

    init(id: TabID, name: String, pane: Pane) {
        self.id = id
        self.name = name
        self.pane = pane
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
    @ObservationIgnored public let settings: ShellSettings
    @ObservationIgnored private let engine: any TerminalEngine
    @ObservationIgnored private var nextPane = 1
    @ObservationIgnored private var nextTab = 1

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
        tabsByRow.values.flatMap { $0.map(\.pane) }
    }

    public func pane(_ id: PaneID) -> Pane? {
        panes.first { $0.id == id }
    }

    public var busyPanes: [Pane] {
        panes.filter(\.isBusy)
    }

    public func busyPanes(inRow path: String) -> [Pane] {
        tabs(inRow: path).map(\.pane).filter(\.isBusy)
    }

    /// Opens a tab with one pane at the end of the row's tab bar and selects it.
    @discardableResult
    public func openTab(for context: PaneContext, name: String? = nil, command: PaneCommand = .shell) -> TerminalTab {
        let tabs = tabs(inRow: context.rowPath)
        let pane = Pane(
            id: PaneID(nextPane), context: context, command: command, settings: settings,
            emulator: engine.makeEmulator(size: preferredSize))
        let tab = TerminalTab(id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.map(\.name)), pane: pane)
        nextPane += 1
        nextTab += 1
        tabsByRow[context.rowPath] = tabs + [tab]
        selectedTabByRow[context.rowPath] = tab.id
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
    }

    /// Moves the selection by `offset` tabs, wrapping around at the ends.
    public func selectTab(offset: Int, inRow path: String) {
        let tabs = tabs(inRow: path)
        guard let current = selectedTab(inRow: path), let index = tabs.firstIndex(where: { $0.id == current.id })
        else { return }
        let count = tabs.count
        selectedTabByRow[path] = tabs[((index + offset) % count + count) % count].id
    }

    public func renameTab(_ id: TabID, inRow path: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }) else { return }
        tab.name = trimmed
    }

    /// Closes a tab and its terminal. If it was selected, the tab to its right takes over, or else the new last tab.
    public func closeTab(_ id: TabID, inRow path: String) {
        var tabs = tabs(inRow: path)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab(inRow: path)?.id == id
        tabs.remove(at: index).pane.close()
        tabsByRow[path] = tabs.isEmpty ? nil : tabs
        if tabs.isEmpty {
            selectedTabByRow[path] = nil
        } else if wasSelected {
            selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Closing a tab's last pane closes the tab. Every tab holds one pane until the grid arrives.
    public func closePane(_ id: PaneID) {
        for (path, tabs) in tabsByRow {
            if let tab = tabs.first(where: { $0.pane.id == id }) {
                closeTab(tab.id, inRow: path)
                return
            }
        }
    }

    public func closeRow(path: String) {
        for tab in tabs(inRow: path) {
            tab.pane.close()
        }
        tabsByRow[path] = nil
        selectedTabByRow[path] = nil
    }

    public func closeAll() {
        for path in Array(tabsByRow.keys) {
            closeRow(path: path)
        }
    }
}
