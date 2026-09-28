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
    let activity: ActivityLog
    private(set) var snapshot = WorkspaceSnapshot()
    private(set) var toast: String?
    var selectedRowPath: String? {
        didSet {
            guard selectedRowPath != oldValue else { return }
            sidebarKeepsKeyboard = isSteppingRows
            selectionChanged()
            updateViewing()
        }
    }
    /// True after ↑ or ↓ in the sidebar picked the row, so its terminal does not take the keyboard from the sidebar.
    private(set) var sidebarKeepsKeyboard = false
    @ObservationIgnored private var isSteppingRows = false
    private var started = false
    private var toastTask: Task<Void, Never>?
    private var server: ControlServer?

    init(home: CanopyHome) {
        self.home = home
        let config = GlobalConfig.load(from: home.configFile)
        let activity = ActivityLog(folder: home.activityFolder, logsCommands: config.logCommands)
        let workspace = Workspace(home: home, activity: activity)
        let terminals = TerminalStore(
            engine: SwiftTermEngine(),
            settings: .current(
                home: home, cliDirectory: Self.bundledCLIDirectory(), logsCommands: config.logCommands),
            activity: activity)
        self.config = config
        self.activity = activity
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
        portsCollapsed = await workspace.portsCollapsed
        let saved = await workspace.savedTerminals
        terminals.continueNumbering(from: await workspace.savedNextPane)
        snapshot = await workspace.snapshot
        restoreTerminals(saved)
        let updates = await workspace.updates()
        Task { [weak self] in
            for await snapshot in updates {
                self?.apply(snapshot)
            }
        }
        await startControlServer()
        startRefreshingWhileVisible()
        startWatchingAgents()
        await offerHooksIfNeeded()
    }

    func shutdown() {
        workspace.stopClones()
        portsTask?.cancel()
        activityTask?.cancel()
        server?.stop()
        server = nil
        terminals.closeAll()
        activity.flushNow()
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

    /// ↑ and ↓ in the sidebar. From no selection, down picks the first row and up the last. From a row hidden in a
    /// collapsed group, they go on from the group's place.
    func selectRow(offset: Int) {
        guard let row = snapshot.steppingRow(from: selectedRowPath, offset: offset) else { return }
        isSteppingRows = true
        defer { isSteppingRows = false }
        selectedRowPath = row.path
    }

    /// Once the sidebar lets go of the keyboard, rows selected later hand it to their terminal again.
    func sidebarLostKeyboard() {
        sidebarKeepsKeyboard = false
    }

    func menuTitle(forRow number: Int) -> String {
        let rows = snapshot.visibleRows
        return number <= rows.count ? rows[number - 1].displayName : "Row \(number)"
    }

    func refresh() {
        Task { await workspace.refreshAll() }
    }

    /// Selects a row once the snapshot has it, so a row created a moment ago gets its terminal. The control API has
    /// already unfolded a group hiding it.
    func select(_ path: String) async {
        apply(await workspace.snapshot)
        selectedRowPath = path
        scrollRequest = ScrollRequest(path: path)
    }

    /// Selects a row from outside the list, as the ports panel does, unfolding a group that hides it.
    func reveal(_ path: String) {
        selectedRowPath = path
        Task {
            do {
                try await workspace.revealRow(path: path)
            } catch {
                show(error)
            }
            await select(path)
        }
    }

    struct ScrollRequest: Equatable {
        let path: String
        let id = UUID()
    }

    /// A row the sidebar should scroll to even though the selection did not change.
    private(set) var scrollRequest: ScrollRequest?

    /// Creates a row, starts its setup, and selects it. Returns an error message for the sheet to show, or nil.
    func createRow(in repo: RepoSnapshot, branch: String, base: String?, group: String? = nil) async -> String? {
        do {
            let created = try await workspace.createRow(
                repoPath: repo.path, branch: branch, base: base, group: group)
            let preparing = rows.prepare(created.row, repoName: repo.name, setup: true, run: nil)
            // A row created into a collapsed group unfolds it, since the new row is selected.
            try? await workspace.revealRow(path: created.row.path)
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

    // MARK: Groups

    /// Returns an error message for the name popover to show, or nil.
    func createGroup(in repo: RepoSnapshot, name: String) async -> String? {
        await message { try await $0.createGroup(repoPath: repo.path, name: name) }
    }

    /// The row menu's New Group…: makes the group, then moves the row into it.
    func createGroup(named name: String, moving row: Row) async -> String? {
        await message { workspace in
            let group = try await workspace.createGroup(repoPath: row.repoPath, name: name)
            _ = try await workspace.moveRow(path: row.path, to: .group(group.name))
        }
    }

    func renameGroup(_ group: GroupSnapshot, in repo: RepoSnapshot, to name: String) async -> String? {
        await message { try await $0.renameGroup(repoPath: repo.path, name: group.name, to: name) }
    }

    func removeGroup(_ group: GroupSnapshot, in repo: RepoSnapshot) {
        perform { try await $0.removeGroup(repoPath: repo.path, name: group.name) }
    }

    func setCollapsed(_ group: GroupSnapshot, _ collapsed: Bool, in repo: RepoSnapshot) {
        perform { try await $0.setGroupCollapsed(repoPath: repo.path, name: group.name, collapsed: collapsed) }
    }

    /// The row being dragged in the sidebar, set when its drag starts, so drops only react to Canopy's own rows.
    var draggedRow: Row?
    /// Whether that drag is over the repo list, where the row dims in place.
    var isDraggingRowOverList = false
    /// Where the dragged row would land, which the list draws.
    var rowDropTarget: RowDropTarget?

    /// Move to Group and drops. A failure shows in a toast.
    func move(_ row: Row, to placement: RowPlacement) {
        perform { _ = try await $0.moveRow(path: row.path, to: placement) }
    }

    private func message(_ action: @escaping @Sendable (Workspace) async throws -> Void) async -> String? {
        do {
            try await action(workspace)
            return nil
        } catch {
            return (error as? WorkspaceError)?.message ?? "\(error)"
        }
    }

    // MARK: Ports

    /// Nil until the first scan, so the panel never says nothing is listening before it has looked.
    private(set) var ports: [PortGroup]?
    /// Ports being stopped, shown dimmed until they close.
    private(set) var stoppingPorts: Set<StoppingPort> = []
    var portsCollapsed = false {
        didSet {
            guard portsCollapsed != oldValue else { return }
            let collapsed = portsCollapsed
            perform { try await $0.setPortsCollapsed(collapsed) }
        }
    }
    @ObservationIgnored private var portsTask: Task<Void, Never>?
    @ObservationIgnored private var occlusionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var portScansStarted = 0
    @ObservationIgnored private var portScanShown = 0

    struct StoppingPort: Hashable {
        let rowPath: String
        let port: UInt16
    }

    @ObservationIgnored private var activityTask: Task<Void, Never>?

    /// Ports scan every 2 seconds and running dots refresh every second while any part of the window can be seen,
    /// and both at once when it comes back into view.
    private func startRefreshingWhileVisible() {
        portsTask = repeating(every: .seconds(2)) { await $0.refreshPorts() }
        activityTask = repeating(every: .seconds(1)) { $0.terminals.refreshActivity() }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.occlusionState.contains(.visible) else { return }
                self?.terminals.refreshActivity()
                Task { await self?.refreshPorts() }
            }
        }
    }

    /// Runs `work` every `interval` while any part of the window can be seen.
    private func repeating(every interval: Duration, _ work: @escaping (AppModel) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if NSApp.occlusionState.contains(.visible) {
                    await work(self)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// A scan that started before a stop can finish after the one that follows it, so only newer results are shown.
    func refreshPorts() async {
        portScansStarted += 1
        let scan = portScansStarted
        let groups = await rows.portGroups()
        guard scan > portScanShown else { return }
        portScanShown = scan
        if groups != ports {
            ports = groups
        }
    }

    func stop(_ ports: [RowPort], inRow path: String) {
        let stopping = ports.map { StoppingPort(rowPath: path, port: $0.port) }
        stoppingPorts.formUnion(stopping)
        Task {
            await rows.stopPorts(Set(ports.map(\.port)), inRow: path)
            await refreshPorts()
            stoppingPorts.subtract(stopping)
        }
    }

    func isStopping(_ port: RowPort, inRow path: String) -> Bool {
        stoppingPorts.contains(StoppingPort(rowPath: path, port: port.port))
    }

    /// The other ports a port's processes listen on, which stopping them closes too.
    func otherPorts(of port: RowPort) -> [UInt16] {
        let pids = Set(port.processes.map(\.pid))
        let all = (ports ?? []).flatMap(\.ports)
        let others = all.filter { other in
            other.port != port.port && other.processes.contains { pids.contains($0.pid) }
        }
        return Set(others.map(\.port)).sorted()
    }

    // MARK: Agents

    @ObservationIgnored private var activationObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private let sounds = AgentSoundPlayer()

    /// Keeps the terminals told what the author has in front of them, and plays a sound when an agent finishes or
    /// needs the author anywhere else.
    private func startWatchingAgents() {
        terminals.onAgentAlert = { [weak self] _, state in self?.playSound(for: state) }
        let names = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didChangeOcclusionStateNotification,
        ]
        activationObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateViewing() }
            }
        }
        updateViewing()
    }

    private func updateViewing() {
        let viewing = AgentViewing(
            rowPath: selectedRowPath, isFrontmost: NSApp.isActive && NSApp.occlusionState.contains(.visible))
        if terminals.viewing != viewing {
            terminals.viewing = viewing
        }
    }

    /// Reads config.json each time, so a changed sound applies without relaunching.
    private func playSound(for state: AgentState) {
        guard let sound = AgentSound.sound(for: state, in: GlobalConfig.load(from: home.configFile)) else { return }
        sounds.play(sound, fallback: AgentSound.fallback(for: state))
    }

    /// The Claude Code settings file the launch offer would write, while the offer is on screen.
    var hooksOffer: ClaudeSettingsFile?

    /// Offers once per home to install Canopy's Claude Code hooks, to people who use Claude Code.
    private func offerHooksIfNeeded() async {
        let environment = ProcessInfo.processInfo.environment
        let settings = ClaudeSettingsFile.resolve(
            explicit: nil, environment: environment, homeDirectory: NSHomeDirectory())
        let folder = ClaudeSettingsFile.configFolder(environment: environment, homeDirectory: NSHomeDirectory())
        let offered = await workspace.agentHooksOffered
        guard ClaudeHooksOffer.shouldOffer(alreadyOffered: offered, settings: settings, configFolder: folder) else {
            return
        }
        hooksOffer = settings
        perform { try await $0.setAgentHooksOffered() }
    }

    func installHooks(into settings: ClaudeSettingsFile) {
        hooksOffer = nil
        do {
            try settings.install()
        } catch {
            show(error)
        }
    }

    // MARK: Terminals

    func context(for row: Row) -> PaneContext {
        PaneContext(row: row, repoName: snapshot.repo(path: row.repoPath)?.name ?? "")
    }

    /// A close waiting for the user to confirm, because a program still runs in the terminal.
    struct PendingClose {
        enum Target {
            case pane(PaneID)
            case tab(TabID, row: String)
        }

        let target: Target
        let title: String
        let message: String
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
            pendingClose = PendingClose(
                target: .pane(pane.id), title: "Close this terminal?", message: "\(program) is still running in it.")
        } else {
            terminals.closePane(pane.id)
            focusSelectedTerminal()
        }
    }

    /// Closes a tab and all its terminals, first asking if any of them are running programs.
    func requestCloseTab(_ tab: TerminalTab, inRow path: String) {
        let busy = tab.paneList.compactMap { $0.isBusy ? $0.foreground?.name : nil }
        if busy.isEmpty {
            terminals.closeTab(tab.id, inRow: path)
        } else {
            pendingClose = PendingClose(
                target: .tab(tab.id, row: path), title: "Close \(tab.name)?",
                message: BusyTerminals.closeWarning(busy))
        }
    }

    func confirmClose() {
        switch pendingClose?.target {
        case .pane(let id): terminals.closePane(id)
        case .tab(let id, let path): terminals.closeTab(id, inRow: path)
        case nil: break
        }
        pendingClose = nil
        focusSelectedTerminal()
    }

    // MARK: Grid

    /// The size of the selected tab's grid, for the add rule and for finding neighbors.
    var gridSize = CGSize(width: 1000, height: 700) {
        didSet { terminals.fits = addRuleFits() }
    }
    @ObservationIgnored private let config: GlobalConfig

    /// The least room a pane may shrink to: 20 columns and 5 rows, plus its padding and header.
    var minimumPaneSize: CGSize {
        let cell = SwiftTermEmulator.cellSize
        let padding = TerminalContainerView.padding
        return CGSize(
            width: 20 * cell.width + TerminalContainerView.horizontalInset,
            height: 5 * cell.height + padding.top + padding.bottom + PaneHeader.height)
    }

    /// ⌘D and the tab bar's split button.
    /// Adds a pane by the add rule, keeping panes at least `minPaneColumns` wide on a line.
    func splitPane() {
        guard let row = selectedRow, !row.isMissing else { return }
        terminals.addPane(for: context(for: row), fits: addRuleFits())
        focusSelectedTerminal()
    }

    /// Whether a line of that many panes keeps each at least `minPaneColumns` wide in the current grid.
    private func addRuleFits() -> (Int) -> Bool {
        let minimumWidth =
            Double(config.minPaneColumns) * SwiftTermEmulator.cellSize.width + TerminalContainerView.horizontalInset
        let width = gridSize.width
        return { width / Double($0) >= minimumWidth }
    }

    /// ⌘⌥ and an arrow.
    func focusNeighbor(_ direction: Direction) {
        guard let row = selectedRow else { return }
        if terminals.focusNeighbor(inRow: row.path, toward: direction, in: CGRect(origin: .zero, size: gridSize))
            != nil
        {
            focusSelectedTerminal()
        }
    }

    func resize(_ tab: TerminalTab, divider: DividerID, to position: Double, in rect: CGRect) {
        terminals.resize(tab, divider: divider, to: position, in: rect, minimum: minimumPaneSize)
    }

    /// The pane being dragged by its header, so drops only react to Canopy's own pane drags.
    var draggedPane: PaneID?

    func movePane(_ moved: PaneID, to zone: DropZone, of target: PaneID) {
        terminals.movePane(moved, to: zone, of: target)
    }

    // MARK: Saving layouts

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Nothing is saved until the saved layouts were restored, or quitting early would erase them.
    @ObservationIgnored private var terminalsRestored = false
    /// Saved tabs of rows that were missing at launch, kept and saved again until the row comes back.
    @ObservationIgnored private var deferredTerminals: [String: SavedRowTerminals] = [:]

    /// Rebuilds the tabs saved for rows that exist. Runs before the first selection, so a restored row does not also
    /// get a fresh terminal.
    private func restoreTerminals(_ saved: [String: SavedRowTerminals]) {
        deferredTerminals = saved
        restoreDeferredTerminals()
        terminalsRestored = true
        terminals.onChange = { [weak self] in self?.scheduleSave() }
    }

    /// Restores deferred rows that came back, and forgets rows git no longer lists once every repo refreshed cleanly.
    private func restoreDeferredTerminals() {
        let allHealthy = snapshot.repos.allSatisfy { !$0.isMissing && $0.error == nil }
        for (path, rowTerminals) in deferredTerminals {
            if let row = snapshot.row(path: path) {
                guard !row.isMissing else { continue }
                terminals.restore(rowTerminals, for: context(for: row))
                deferredTerminals[path] = nil
            } else if allHealthy {
                deferredTerminals[path] = nil
            }
        }
    }

    /// Saves a second after the last change, so a burst of changes writes state.json once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await saveTerminals()
        }
    }

    /// Reads each pane's folder now, so a `cd` since the last change is kept too.
    func saveTerminals() async {
        guard terminalsRestored else { return }
        do {
            try await workspace.setSavedTerminals(
                terminals.saved().merging(deferredTerminals) { live, _ in live }, nextPane: terminals.nextPaneNumber)
        } catch {
            show(error)
        }
    }

    /// ⌘W. Only for the main window itself, so it never closes a terminal behind a sheet or a closed window.
    func closeFocusedPane() {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
            let pane = selectedTab?.focused
        else { return }
        requestClose(pane)
    }

    /// Hands the keyboard back to the terminal on screen, as after renaming a tab.
    func focusSelectedTerminal() {
        (selectedTab?.focused.emulator as? SwiftTermEmulator)?.focus()
    }

    func selectTab(offset: Int) {
        guard let row = selectedRow else { return }
        terminals.selectTab(offset: offset, inRow: row.path)
    }

    // MARK: Repos

    enum FolderRequest {
        case addRepo
        case locate(RepoSnapshot)
    }

    /// SwiftUI resets `isChoosingFolder` before calling the completion, so the request lives in its own property.
    var isChoosingFolder = false
    private(set) var folderRequest = FolderRequest.addRepo

    /// The sidebar's +, File > Add Repo…, the empty states, and Locate… for a missing repo.
    func chooseFolder(for request: FolderRequest) {
        folderRequest = request
        isChoosingFolder = true
    }

    func folderChosen(_ result: Result<URL, any Error>) {
        switch (result, folderRequest) {
        case (.success(let url), .addRepo): perform { try await $0.addRepo(path: url.path) }
        case (.success(let url), .locate(let repo)): relocateRepo(repo, to: url)
        case (.failure(let error), _): show(error)
        }
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

    // MARK: Cloning

    /// The Repos `+` menu and File > Clone Repo….
    var isShowingCloneSheet = false

    func showCloneSheet() {
        isShowingCloneSheet = true
    }

    func gitHubRepos() async -> Result<[GitHubRepoSummary], GHFailure> {
        await workspace.gitHubRepos()
    }

    /// Where a clone of `text` goes, or nil while it is not something to clone.
    func cloneFolder(for text: String) -> String? {
        try? CloneSource(text).defaultFolder(in: home)
    }

    /// Clones a repo into its default folder and selects its main row. Cancelling the calling task stops the clone.
    func cloneRepo(_ text: String, progress: @escaping @Sendable (CloneProgress) -> Void) async throws {
        let repo = try await workspace.cloneRepo(text, progress: progress)
        if let main = repo.rows.first {
            await select(main.path)
        }
    }

    // MARK: Internals

    private func apply(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        terminals.closeRowsGone(from: snapshot)
        terminals.followRowNames(in: snapshot)
        if terminalsRestored, !deferredTerminals.isEmpty {
            restoreDeferredTerminals()
        }
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
