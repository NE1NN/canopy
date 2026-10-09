import CoreGraphics
import Foundation
import Observation

/// A terminal tab's panes: their layout, and the one with focus.
@MainActor
@Observable
public final class TerminalGrid {
    public internal(set) var layout: Layout<PaneID>
    public internal(set) var panes: [PaneID: Pane]
    public internal(set) var focusedPaneID: PaneID

    init(layout: Layout<PaneID>, panes: [Pane], focusedPaneID: PaneID) {
        self.layout = layout
        self.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        self.focusedPaneID = focusedPaneID
    }

    convenience init(pane: Pane) {
        self.init(layout: .leaf(pane.id), panes: [pane], focusedPaneID: pane.id)
    }

    /// Panes in layout order: left to right, then top to bottom.
    public var paneList: [Pane] {
        layout.leaves.compactMap { panes[$0] }
    }

    /// The pane `⌘W` closes and typing goes to.
    public var focused: Pane {
        panes[focusedPaneID] ?? paneList[0]
    }
}

/// A tab in a row's tab bar: terminals, or one web page.
@MainActor
@Observable
public final class TerminalTab: Identifiable {
    public enum Content {
        case terminals(TerminalGrid)
        case web(WebPage)
    }

    public let id: TabID
    public let content: Content
    /// A terminal tab's name. A web tab is named after its page.
    var terminalName: String

    init(id: TabID, name: String, grid: TerminalGrid) {
        self.id = id
        self.terminalName = name
        self.content = .terminals(grid)
    }

    init(id: TabID, page: WebPage) {
        self.id = id
        self.terminalName = ""
        self.content = .web(page)
    }

    public var name: String {
        page?.displayTitle ?? terminalName
    }

    public var grid: TerminalGrid? {
        if case .terminals(let grid) = content { grid } else { nil }
    }

    public var page: WebPage? {
        if case .web(let page) = content { page } else { nil }
    }

    /// Panes in layout order, none for a web tab.
    public var paneList: [Pane] {
        grid?.paneList ?? []
    }

    public var focused: Pane? {
        grid?.focused
    }

    /// Nil for a plugin row's tab.
    var repoPath: String? {
        paneList.first?.context.repoPath ?? page?.context.repoPath
    }
}

/// What remote panes need from their hosts.
@MainActor
public protocol RemotePaneHooks: AnyObject {
    /// Types a command and Return into the pane's session, once the host has it.
    func run(_ text: String, in pane: Pane) async
    /// The user closed these panes, so their sessions on the host end too.
    func closed(_ panes: [Pane])
}

/// Every row's tabs and terminals. Terminals keep running while their row or tab is out of view.
@MainActor
@Observable
public final class TerminalStore {
    /// Each row's tabs in tab bar order, keyed by row path.
    public internal(set) var tabsByRow: [String: [TerminalTab]] = [:]
    var selectedTabByRow: [String: TabID] = [:]
    /// Each row's panel page, keyed by row path.
    public internal(set) var panelsByRow: [String: WebPanel] = [:]
    /// Where a new page opens: where the author last moved one.
    public var webPlacement = WebPlacement.panel {
        didSet {
            if webPlacement != oldValue { onChange() }
        }
    }
    /// The size new terminals start at, so one opened in the background already fits the window.
    public var preferredSize = TerminalSize.standard
    /// Called after any change worth saving: tabs, names, layouts, focus, or selection.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// The add rule's width check for panes added without the window's help, as by `canopy term new`.
    /// The app keeps it in step with the grid's width.
    @ObservationIgnored public var fits: (Int) -> Bool = { $0 <= 2 }
    @ObservationIgnored public let settings: ShellSettings
    @ObservationIgnored public let activity: ActivityLog
    @ObservationIgnored private let engine: any TerminalEngine
    @ObservationIgnored private var nextPane = 1
    @ObservationIgnored var nextTab = 1
    @ObservationIgnored var nextWebPage = 1
    /// Rows seen in a snapshot while they had terminals, so a row created a moment ago is not mistaken for one
    /// that went away.
    @ObservationIgnored private var seenRows: Set<String> = []
    /// What the author has in front of them. The app keeps it current.
    @ObservationIgnored public var viewing = AgentViewing() {
        didSet { markSeenOnScreen() }
    }
    /// Called when a pane's agent finishes or needs the author, unless the author is focused on that pane.
    @ObservationIgnored public var onAgentAlert: (Pane, AgentState) -> Void = { _, _ in }
    /// Called after a link ⌘-clicked in a pane was followed, with where it went. An artifact is open in the pane's row
    /// by then, and the app hands anything else to the browser or the file's app.
    @ObservationIgnored public var onFollowLink: (Pane, TerminalLink) -> Void = { _, _ in }
    /// Called when a page leaves its row, so the app can drop its web view.
    @ObservationIgnored public var onPageClosed: (WebPageID) -> Void = { _ in }
    @ObservationIgnored private var agentObservers: [UUID: (AgentEvent) -> Void] = [:]
    /// Reaches remote panes' hosts. Set by whoever owns the workspace.
    @ObservationIgnored public weak var remoteHooks: (any RemotePaneHooks)?

    public init(engine: any TerminalEngine, settings: ShellSettings, activity: ActivityLog? = nil) {
        self.engine = engine
        self.settings = settings
        self.activity = activity ?? ActivityLog(folder: settings.home.activityFolder)
    }

    /// The number the next pane gets, saved so IDs keep counting up across launches.
    public var nextPaneNumber: Int { nextPane }

    public func continueNumbering(from number: Int) {
        nextPane = max(nextPane, number)
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

    /// Updates every pane's `isRunningProgram`.
    public func refreshActivity() {
        for pane in panes {
            pane.refreshActivity()
        }
    }

    // MARK: Tabs

    /// Opens a tab with one pane at the end of the row's tab bar and selects it.
    @discardableResult
    public func openTab(
        for context: PaneContext, name: String? = nil, command: PaneCommand = .shell, directory: String? = nil,
        select: Bool = true
    ) -> (tab: TerminalTab, pane: Pane) {
        let tabs = tabs(inRow: context.rowPath)
        let pane = makePane(context, command: command, directory: directory)
        let tab = TerminalTab(
            id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.filter { $0.grid != nil }.map(\.name)),
            grid: TerminalGrid(pane: pane))
        nextTab += 1
        tabsByRow[context.rowPath] = tabs + [tab]
        if select || selectedTabByRow[context.rowPath] == nil {
            selectedTabByRow[context.rowPath] = tab.id
        }
        markSeenOnScreen()
        onChange()
        return (tab, pane)
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
        markSeenOnScreen()
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
        guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }), tab.grid != nil else {
            return
        }
        tab.terminalName = trimmed
        onChange()
    }

    /// Closes a tab and its terminals. If it was selected, the tab to its right takes over, or else the new last tab.
    public func closeTab(_ id: TabID, inRow path: String) {
        var tabs = tabs(inRow: path)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab(inRow: path)?.id == id
        let removed = tabs.remove(at: index)
        for pane in removed.paneList {
            pane.close()
        }
        removed.page.map(retire)
        endSessions(of: removed.paneList)
        tabsByRow[path] = tabs.isEmpty ? nil : tabs
        if tabs.isEmpty {
            selectedTabByRow[path] = nil
        } else if wasSelected {
            selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
        }
        markSeenOnScreen()
        onChange()
    }

    // MARK: Panes

    /// Adds a pane to the row's selected tab by the add rule, where `fits` says whether a line of that many panes
    /// keeps each one wide enough, and focuses it. Opens a tab if the row has none, and does nothing in a web tab.
    @discardableResult
    public func addPane(for context: PaneContext, fits: (Int) -> Bool) -> Pane? {
        guard let tab = selectedTab(inRow: context.rowPath) else {
            return openTab(for: context).pane
        }
        guard let grid = tab.grid else { return nil }
        return addPane(to: grid, for: context, fits: fits)
    }

    /// Opens a terminal where `canopy term new` asks: in a new tab, in the terminal tab with `name` (opening it if
    /// the row has none by that name), or in the row's selected tab. A web tab selected gets a new tab beside it.
    /// It never changes which tab or pane the user is on.
    public func openTerminal(for context: PaneContext, tabNamed name: String?, newTab: Bool) -> (TerminalTab, Pane) {
        let named = name.flatMap { name in tabs(inRow: context.rowPath).first { $0.grid != nil && $0.name == name } }
        guard !newTab, name == nil || named != nil, let tab = named ?? selectedTab(inRow: context.rowPath),
            let grid = tab.grid
        else {
            return openTab(for: context, name: name, select: false)
        }
        return (tab, addPane(to: grid, for: context, fits: fits, focus: false))
    }

    private func addPane(
        to grid: TerminalGrid, for context: PaneContext, fits: (Int) -> Bool, focus: Bool = true
    ) -> Pane {
        let pane = makePane(context, command: .shell, directory: nil)
        grid.panes[pane.id] = pane
        grid.layout = grid.layout.adding(pane.id, fits: fits)
        if focus { grid.focusedPaneID = pane.id }
        onChange()
        return pane
    }

    /// Closes a pane and hands its space to its neighbors. Closing a tab's last pane closes the tab.
    public func closePane(_ id: PaneID) {
        guard let (path, tab) = tab(containing: id), let grid = tab.grid else { return }
        guard let layout = grid.layout.removing(id) else {
            closeTab(tab.id, inRow: path)
            return
        }
        if grid.focusedPaneID == id {
            // Focus moves to the pane that came before it in layout order, or else the one after.
            let order = grid.layout.leaves
            let index = order.firstIndex(of: id) ?? 0
            grid.focusedPaneID = index > 0 ? order[index - 1] : order[index + 1]
        }
        if let pane = grid.panes.removeValue(forKey: id) {
            pane.close()
            endSessions(of: [pane])
        }
        grid.layout = layout
        onChange()
    }

    public func focus(_ id: PaneID) {
        guard let grid = tab(containing: id)?.1.grid, grid.focusedPaneID != id else { return }
        grid.focusedPaneID = id
        onChange()
    }

    /// Focuses the pane next to the focused one in `direction`, laid out in `rect`. Returns it, if there is one.
    @discardableResult
    public func focusNeighbor(inRow path: String, toward direction: Direction, in rect: CGRect) -> Pane? {
        guard let grid = selectedTab(inRow: path)?.grid,
            let neighbor = grid.layout.neighbor(of: grid.focusedPaneID, toward: direction, in: rect)
        else { return nil }
        focus(neighbor)
        return grid.panes[neighbor]
    }

    /// Drops `moved` on `target`: on an edge it splits the target 50/50, and in the middle the two swap.
    /// Both must be in the same tab.
    public func movePane(_ moved: PaneID, to zone: DropZone, of target: PaneID) {
        guard moved != target, let grid = tab(containing: moved)?.1.grid, grid.panes[target] != nil else { return }
        switch zone {
        case .center: grid.layout = grid.layout.swapping(moved, target)
        case .edge(let edge): grid.layout = grid.layout.moving(moved, to: edge, of: target)
        }
        onChange()
    }

    public func resize(
        _ grid: TerminalGrid, divider: DividerID, to position: Double, in rect: CGRect, minimum: CGSize
    ) {
        let layout = grid.layout.resizing(divider, to: position, in: rect, minimum: minimum)
        guard layout != grid.layout else { return }
        grid.layout = layout
        onChange()
    }

    public func tab(containing id: PaneID) -> (String, TerminalTab)? {
        for (path, tabs) in tabsByRow {
            if let tab = tabs.first(where: { $0.grid?.panes[id] != nil }) {
                return (path, tab)
            }
        }
        return nil
    }

    // MARK: Rows

    /// Closes a row's terminals and drops its pages. The pages are not logged as closed, since a row's pages also close
    /// this way when Canopy quits, and come back when it starts.
    public func closeRow(path: String) {
        let panes = tabs(inRow: path).flatMap(\.paneList)
        closeRowQuietly(path: path)
        endSessions(of: panes)
    }

    /// Closes the row's terminals here and leaves remote sessions running on their hosts.
    private func closeRowQuietly(path: String) {
        for pane in tabs(inRow: path).flatMap(\.paneList) {
            pane.close()
        }
        for page in pages(inRow: path).map(\.page) {
            onPageClosed(page.id)
        }
        tabsByRow[path] = nil
        selectedTabByRow[path] = nil
        panelsByRow[path] = nil
        seenRows.remove(path)
        onChange()
    }

    /// Closes the terminals of rows that are gone from a repo git could list, such as a worktree removed with
    /// plain git, so they neither keep running out of reach nor come back when a new row reuses the folder.
    /// Repos that are missing or failed to refresh keep their terminals.
    public func closeRowsGone(from snapshot: WorkspaceSnapshot) {
        for path in rowPaths {
            guard let repoPath = repoPath(ofRow: path),
                let repo = snapshot.repo(path: repoPath), !repo.isMissing, repo.error == nil
            else { continue }
            if repo.allRows.contains(where: { $0.path == path }) {
                seenRows.insert(path)
            } else if seenRows.contains(path) {
                closeRow(path: path)
            }
        }
    }

    /// Keeps each pane's repo and row names in step with the sidebar, so a row whose checkout moved to another branch
    /// is logged and listed by its name now. Shells already running keep the CANOPY_ROW they started with.
    public func followRowNames(in snapshot: WorkspaceSnapshot) {
        for pane in panes {
            guard case .repo(let name, let path) = pane.context.owner,
                let row = snapshot.row(path: pane.context.rowPath),
                let repo = snapshot.repo(path: row.repoPath)
            else { continue }
            if pane.context.rowName != row.displayName { pane.context.rowName = row.displayName }
            if name != repo.name { pane.context.owner = .repo(name: repo.name, path: path) }
        }
        for page in rowPaths.flatMap({ pages(inRow: $0).map(\.page) }) {
            guard case .repo(let name, let path) = page.context.owner,
                let row = snapshot.row(path: page.context.rowPath),
                let repo = snapshot.repo(path: row.repoPath)
            else { continue }
            if page.context.rowName != row.displayName { page.context.rowName = row.displayName }
            if name != repo.name { page.context.owner = .repo(name: repo.name, path: path) }
        }
    }

    /// Closes every terminal and page in a repo's rows, for when the repo is unregistered.
    public func closeRows(ofRepo repoPath: String) {
        for path in rowPaths where self.repoPath(ofRow: path) == repoPath {
            closeRow(path: path)
        }
    }

    /// Rows with tabs or a panel.
    var rowPaths: Set<String> {
        Set(tabsByRow.keys).union(panelsByRow.keys)
    }

    /// Nil for a plugin's row.
    func repoPath(ofRow path: String) -> String? {
        tabs(inRow: path).lazy.compactMap(\.repoPath).first ?? panelsByRow[path]?.page.context.repoPath
    }

    /// Follows a repo that moved: rows inside its old folder move with it, and every pane learns its new paths.
    public func moveRows(ofRepo oldRepoPath: String, to newRepoPath: String) {
        for path in rowPaths where repoPath(ofRow: path) == oldRepoPath {
            let newPath = Paths.isInside(path, oldRepoPath) ? newRepoPath + path.dropFirst(oldRepoPath.count) : path
            for pane in tabs(inRow: path).flatMap(\.paneList) {
                if case .repo(let name, _) = pane.context.owner {
                    pane.context.owner = .repo(name: name, path: newRepoPath)
                }
                pane.context.rowPath = newPath
            }
            for page in pages(inRow: path).map(\.page) {
                if case .repo(let name, _) = page.context.owner {
                    page.context.owner = .repo(name: name, path: newRepoPath)
                }
                page.context.rowPath = newPath
            }
            let tabs = tabsByRow.removeValue(forKey: path)
            tabsByRow[newPath] = tabs
            let panel = panelsByRow.removeValue(forKey: path)
            panelsByRow[newPath] = panel
            if let selected = selectedTabByRow.removeValue(forKey: path) {
                selectedTabByRow[newPath] = selected
            }
            if seenRows.remove(path) != nil {
                seenRows.insert(newPath)
            }
        }
        onChange()
    }

    /// Closes every terminal, as Canopy quits. Sessions on hosts keep running, so relaunching joins them again.
    public func closeAll() {
        for path in rowPaths {
            closeRowQuietly(path: path)
        }
    }

    private func endSessions(of panes: [Pane]) {
        let remote = panes.filter { $0.remoteSession != nil }
        if !remote.isEmpty { remoteHooks?.closed(remote) }
    }

    // MARK: Saving and restoring

    /// Every row's tabs and panel as they would be restored: names, layouts, each pane's current folder, and each
    /// page's address and title.
    public func saved() -> [String: SavedRowTerminals] {
        var saved: [String: SavedRowTerminals] = [:]
        for path in rowPaths {
            let tabs = tabs(inRow: path)
            saved[path] = SavedRowTerminals(
                tabs: tabs.map { savedTab($0, inRow: path) },
                selectedTab: tabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0,
                panel: panelsByRow[path].map { SavedWebPanel(page: savedPage($0.page), hidden: $0.isHidden) })
        }
        return saved
    }

    private func savedTab(_ tab: TerminalTab, inRow path: String) -> SavedTab {
        switch tab.content {
        case .web(let page):
            return SavedTab(name: tab.name, web: savedPage(page))
        case .terminals(let grid):
            return SavedTab(
                name: tab.name,
                layout: grid.layout.map { id in
                    let pane = grid.panes[id]
                    if let session = pane?.remoteSession {
                        return SavedPane(
                            folder: pane?.currentDirectory ?? pane?.remoteFolder ?? path, session: session)
                    }
                    return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
                },
                focused: grid.layout.leaves.firstIndex(of: grid.focusedPaneID))
        }
    }

    private func savedPage(_ page: WebPage) -> SavedWebPage {
        SavedWebPage(
            url: page.url.absoluteString, title: page.title,
            opened: page.openedURL == page.url ? nil : page.openedURL.absoluteString)
    }

    /// Rebuilds a row's saved tabs with fresh shells in the saved folders, and its pages, which load once they show.
    /// Folders that are gone fall back to the row's own, and pages that are not web addresses are dropped. Replaces
    /// nothing: a row that already has tabs keeps them, and one that has a panel keeps it.
    public func restore(_ saved: SavedRowTerminals, for context: PaneContext) {
        let path = context.rowPath
        if tabs(inRow: path).isEmpty {
            let restored = saved.tabs.enumerated().compactMap { index, savedTab in
                restoredTab(savedTab, for: context).map { (index, $0) }
            }
            if let first = restored.first {
                tabsByRow[path] = restored.map(\.1)
                selectedTabByRow[path] = (restored.last { $0.0 <= saved.selectedTab } ?? first).1.id
            }
        }
        if panelsByRow[path] == nil, let panel = saved.panel, let page = restoredPage(panel.page, for: context) {
            panelsByRow[path] = WebPanel(page: page, isHidden: panel.hidden)
        }
    }

    private func restoredTab(_ saved: SavedTab, for context: PaneContext) -> TerminalTab? {
        if let web = saved.web {
            guard let page = restoredPage(web, for: context) else { return nil }
            defer { nextTab += 1 }
            return TerminalTab(id: TabID(nextTab), page: page)
        }
        guard let savedLayout = saved.layout else { return nil }
        var panes: [Pane] = []
        for leaf in savedLayout.leaves {
            let kept = leaf.session.flatMap(PaneID.init).flatMap { id in
                pane(id) == nil && !panes.contains { $0.id == id } ? id : nil
            }
            panes.append(makePane(context, command: .shell, directory: leaf.folder, session: leaf.session, id: kept))
        }
        var index = 0
        let layout: Layout<PaneID> = savedLayout.map { _ in
            defer { index += 1 }
            return panes[index].id
        }
        let focused = saved.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
        defer { nextTab += 1 }
        return TerminalTab(
            id: TabID(nextTab), name: saved.name,
            grid: TerminalGrid(layout: layout, panes: panes, focusedPaneID: focused))
    }

    private func restoredPage(_ saved: SavedWebPage, for context: PaneContext) -> WebPage? {
        guard let url = WebAddress.parse(saved.url) else { return nil }
        defer { nextWebPage += 1 }
        return WebPage(
            id: WebPageID(nextWebPage), url: url, title: saved.title, context: context,
            openedURL: saved.opened.flatMap(WebAddress.parse))
    }

    /// A remote row's terminals attach to their host rather than start a shell here. A restored one takes the ID its
    /// session is named after, which the session's shell and the agents in it know as CANOPY_PANE.
    private func makePane(
        _ context: PaneContext, command: PaneCommand, directory: String?, session: String? = nil, id: PaneID? = nil
    ) -> Pane {
        let id = id ?? PaneID(nextPane)
        nextPane = max(nextPane, id.number + 1)
        let command = context.remote != nil && command == .shell ? .remoteAttach : command
        let pane = Pane(
            id: id, context: context, command: command, settings: settings,
            emulator: engine.makeEmulator(size: preferredSize), activity: activity, directory: directory,
            session: session)
        pane.runRemotely = { [weak self] pane, text in await self?.remoteHooks?.run(text, in: pane) }
        pane.onAgentChange = { [weak self] in self?.agentChanged($0, $1) }
        pane.onClose = { [weak self] in self?.notifyAgentObservers(.closed($0)) }
        pane.onOpenLink = { [weak self] pane, link in
            guard let self else { return }
            self.onFollowLink(pane, self.followLink(link, from: pane))
        }
        return pane
    }

    // MARK: Agents

    /// Calls `handler` with every agent change and pane close until `stopObservingAgents`.
    public func observeAgents(_ handler: @escaping (AgentEvent) -> Void) -> UUID {
        let id = UUID()
        agentObservers[id] = handler
        return id
    }

    public func stopObservingAgents(_ id: UUID) {
        agentObservers[id] = nil
    }

    /// How many agent observers listen, so tests report only once a wait is in place.
    var agentObserverCount: Int { agentObservers.count }

    func notifyAgentObservers(_ event: AgentEvent) {
        for observer in agentObservers.values {
            observer(event)
        }
    }
}
