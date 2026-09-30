import Foundation

/// A new plugin row, ready.
public struct PluginRowCreated: Sendable, Equatable, Codable {
    public var row: PluginRow
    /// The terminal started for `run`, such as "p12".
    public var pane: String?
    /// Why the plugin could not fill the folder. The row stays, and `run` is skipped.
    public var fillError: String?

    public init(row: PluginRow, pane: String? = nil, fillError: String? = nil) {
        self.row = row
        self.pane = pane
        self.fillError = fillError
    }
}

public struct PluginRowRemoved: Sendable, Equatable, Codable {
    public var row: PluginRow
    /// Where the folder went in the Trash, or nil when it was already gone.
    public var trashedTo: String?

    public init(row: PluginRow, trashedTo: String? = nil) {
        self.row = row
        self.trashedTo = trashedTo
    }
}

/// A built-in plugin as `canopy plugin list` shows it.
public struct PluginListing: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var on: Bool
    /// The plugin's own line, such as "connected as me@example.com", while it is on.
    public var status: String?
    /// Why it is not working, with the fix.
    public var warning: String?
    public var rows: Int
    public var filters: PluginFilters
    /// Whether the sidebar folds its section.
    public var collapsed: Bool

    public init(
        id: String, name: String, on: Bool, status: String?, warning: String?, rows: Int, filters: PluginFilters,
        collapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.on = on
        self.status = status
        self.warning = warning
        self.rows = rows
        self.filters = filters
        self.collapsed = collapsed
    }
}

/// Starts and stops the built-in plugins, and makes and removes their rows. It sits beside `RowLifecycle` on the main
/// actor, where terminals live, and the window and the control API both come through it.
@MainActor
public final class PluginHost {
    public nonisolated let workspace: Workspace
    public let terminals: TerminalStore
    public let plugins: [any CanopyPlugin]
    /// Selects rows for `select`, as the control API does.
    public var ui: (any ControlUIBridge)?
    /// Something worth telling the author, such as a folder the plugin could not fill again.
    public var onNotice: (String) -> Void = { _ in }
    /// Called with the paths of rows whose terminals are about to close because their plugin turned off.
    public var onClosingRows: ([String]) -> Void = { _ in }
    public var viewing = PluginViewing() {
        didSet {
            if viewing != oldValue { publishStates() }
        }
    }
    /// The workspace as last published, which the plugins' states come from.
    private(set) var snapshot = WorkspaceSnapshot()

    private let trash: any FolderTrash
    private let configFile: PluginConfigFile
    private var contexts: [String: PluginContext] = [:]
    /// Each plugin's section of config.json, as last read or written.
    private var sections: [String: JSONValue] = [:]
    private var on: Set<String> = []
    /// Plugins whose `start` succeeded.
    private var running: Set<String> = []
    private var lastStates: [String: PluginState] = [:]
    private var updates: Task<Void, Never>?
    private var queues = KeyedQueue()
    /// Why each plugin that is on but not running failed to start.
    private var startFailures: [String: any Error] = [:]

    public init(
        workspace: Workspace, terminals: TerminalStore, plugins: [any CanopyPlugin], secrets: any SecretStore,
        bundleID: String, trash: any FolderTrash = SystemTrash()
    ) {
        self.workspace = workspace
        self.terminals = terminals
        self.plugins = plugins
        self.trash = trash
        configFile = PluginConfigFile(url: workspace.home.configFile)
        for plugin in plugins {
            let id = plugin.info.id
            contexts[id] = PluginContext(
                info: plugin.info, folder: workspace.home.pluginsRoot.appending(path: id),
                secrets: PluginSecrets(store: secrets, bundleID: bundleID, plugin: id, home: workspace.home),
                activity: workspace.activity, host: self)
        }
    }

    public func context(_ id: String) -> PluginContext? {
        contexts[id]
    }

    // MARK: Turning plugins on and off

    /// Registers the plugins with the workspace, then starts each one config.json turns on and makes its rows' missing
    /// folders again.
    public func start() async {
        await workspace.registerPlugins(plugins.map(\.info))
        snapshot = await workspace.snapshot
        let stream = await workspace.updates()
        updates = Task { [weak self] in
            for await snapshot in stream {
                self?.snapshotChanged(snapshot)
            }
        }
        do {
            sections = try PluginConfig.sections(in: workspace.home.configFile)
        } catch {
            onNotice("No plugins started. \(Self.message(error))")
        }
        for plugin in plugins where PluginConfig.isOn(sections[plugin.info.id]) {
            await turnOn(plugin)
        }
    }

    /// Stops every plugin that is on, for quitting.
    public func stop() async {
        updates?.cancel()
        for plugin in plugins where on.contains(plugin.info.id) {
            if let context = contexts[plugin.info.id] {
                await plugin.stop(context)
                context.finish()
            }
        }
    }

    public func list() async -> [PluginListing] {
        let snapshot = await workspace.snapshot
        var listings: [PluginListing] = []
        for plugin in plugins {
            listings.append(await listing(plugin, in: snapshot))
        }
        return listings
    }

    /// Writes the plugin's section of config.json with `fields` and without `"enabled": false`, then starts it. A
    /// plugin that is on starts again if its section changed or its last start failed.
    @discardableResult
    public func enable(_ id: String, with fields: [String: JSONValue] = [:]) async throws -> PluginListing {
        let plugin = try requirePlugin(id)
        return try await serialized(id) { try await self.enableNow(plugin, with: fields) }
    }

    /// Closes the terminals in the plugin's rows, asking first while programs run in them, writes `"enabled": false`
    /// in its section of config.json, and stops it. Its rows stay in state.json for when it is on again.
    @discardableResult
    public func disable(_ id: String, force: Bool) async throws -> PluginListing {
        let plugin = try requirePlugin(id)
        return try await serialized(id) { try await self.disableNow(plugin, force: force) }
    }

    /// Sets one key of the plugin's section of config.json, or takes it out when `value` is nil, without starting or
    /// stopping the plugin, which reads the new value from its context. `enabled` changes only through `enable` and
    /// `disable`, which start and stop the plugin with it.
    public func setConfig(_ id: String, key: String, to value: JSONValue?) async throws {
        _ = try requirePlugin(id)
        guard key != "enabled" else {
            throw ControlError(code: "bad_params", message: "Turn a plugin on or off with plugin enable or disable.")
        }
        try await serialized(id) { try await self.setConfigNow(id, key: key, to: value) }
    }

    private func setConfigNow(_ id: String, key: String, to value: JSONValue?) throws {
        sections[id] = try configFile.set(id, key: key, to: value)
    }

    /// Folds or unfolds the plugin's section, on or off.
    @discardableResult
    public func setCollapsed(_ id: String, _ collapsed: Bool) async throws -> PluginListing {
        let plugin = try requirePlugin(id)
        try await workspace.setPluginCollapsed(id, collapsed: collapsed)
        return await listing(plugin, in: await workspace.snapshot)
    }

    private func enableNow(_ plugin: any CanopyPlugin, with fields: [String: JSONValue]) async throws -> PluginListing {
        let id = plugin.info.id
        let section = try configFile.enable(id, fields: fields)
        let changed = sections[id] != section
        sections[id] = section
        if on.contains(id) {
            if changed || !running.contains(id) {
                await plugin.stop(context(of: plugin))
                await turnOn(plugin)
            }
        } else {
            await turnOn(plugin)
            workspace.activity.record(ActivityType.pluginEnabled, data: ["plugin": .string(id)])
        }
        return await listing(plugin, in: await workspace.snapshot)
    }

    private func disableNow(_ plugin: any CanopyPlugin, force: Bool) async throws -> PluginListing {
        let id = plugin.info.id
        guard on.contains(id) else { return await listing(plugin, in: await workspace.snapshot) }
        let paths = (await workspace.snapshot.section(id)?.rows ?? []).map(\.path)
        let busy = paths.flatMap(terminals.busyPanes(inRow:))
        if !busy.isEmpty, !force {
            throw WorkspaceError.pluginBusy(plugin.info.name, id: id, programs: Self.programs(busy))
        }
        sections[id] = try configFile.disable(id)
        // Off first, so nothing restores the rows' terminals while they close.
        on.remove(id)
        running.remove(id)
        await workspace.setPlugin(id, on: false)
        await workspace.setPluginWarning(id, nil)
        publishStates()
        onClosingRows(paths)
        for path in paths {
            terminals.closeRow(path: path)
        }
        await plugin.stop(context(of: plugin))
        workspace.activity.record(ActivityType.pluginDisabled, data: ["plugin": .string(id)])
        return await listing(plugin, in: await workspace.snapshot)
    }

    /// Makes the rows' missing folders before the rows show, so no terminal starts in one that is gone, then starts the
    /// plugin and lets it fill them.
    private func turnOn(_ plugin: any CanopyPlugin) async {
        let id = plugin.info.id
        let remade = await makeMissingFolders(of: plugin)
        on.insert(id)
        await workspace.setPluginWarning(id, nil)
        await workspace.setPlugin(id, on: true)
        snapshot = await workspace.snapshot
        publishStates()
        do {
            try await plugin.start(context(of: plugin))
            running.insert(id)
            startFailures[id] = nil
        } catch {
            running.remove(id)
            startFailures[id] = error
            await workspace.setPluginWarning(id, Self.message(error))
        }
        // In the background, so launching never waits on a plugin's network.
        if running.contains(id) {
            for row in remade {
                Task { await self.fill(row, plugin: plugin) }
            }
        }
    }

    /// Changes to a plugin's on or off state run one at a time, so a disable and an enable never interleave.
    private func serialized<T: Sendable>(_ id: String, _ operation: @escaping @Sendable () async throws -> T)
        async throws -> T
    {
        try await queues.enqueue(id, operation).value
    }

    // MARK: Rows

    /// The plugin's items, each with the row it already has.
    public func items(_ id: String, matching query: PluginQuery) async throws -> [PluginItem] {
        let plugin = try requireRunning(id)
        let items = try await plugin.items(matching: query, context: context(of: plugin))
        let snapshot = await workspace.snapshot
        return items.map { item in
            var item = item
            item.row = snapshot.pluginRow(plugin: id, item: item.id)
            return item
        }
    }

    /// Makes a row for the item a reference names: its folder under CANOPY_HOME/plugins/<plugin>/, filled by the
    /// plugin, then selects it when asked and types `run` into a new terminal in it. An item that has a row fails with
    /// `item_has_row`, and one the plugin cannot seed makes nothing.
    public func createRow(_ id: String, reference: String, run: String?, select: Bool) async throws
        -> PluginRowCreated
    {
        let plugin = try requireRunning(id)
        let context = context(of: plugin)
        let item = try await plugin.resolve(reference, context: context)
        if let existing = await workspace.snapshot.pluginRow(plugin: id, item: item) {
            throw WorkspaceError.itemHasRow(existing.path)
        }
        let seed = try await plugin.seed(for: item, context: context)
        let folder = try await makeFolder(named: seed.folderName, plugin: id)
        let run = run ?? seed.run
        var row: PluginRow
        do {
            row = try await workspace.addPluginRow(
                PluginRowEntry(item: item, title: seed.title, path: folder), plugin: id)
        } catch {
            // Another request made the item's row while this one was on its way.
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
        // Its plugin sees the row at once, not only when the workspace's update arrives.
        snapshotChanged(await workspace.snapshot)
        var fillError: String?
        do {
            try await plugin.fill(row, context: context)
        } catch {
            fillError = Self.message(error)
        }
        record(ActivityType.pluginRowCreated, row)
        row = await workspace.snapshot.section(id)?.rows.first { $0.path == row.path } ?? row
        // The terminal opens first, so selecting the row does not also give it a blank one. A plugin turned off while
        // the row was made gets no terminal in it.
        let pane = run.flatMap { _ in
            fillError == nil && on.contains(id) ? terminals.openTab(for: PaneContext(pluginRow: row)).focused : nil
        }
        if select {
            await self.select(row.path)
        }
        if let pane, let run {
            await pane.run(run)
        }
        return PluginRowCreated(row: row, pane: pane?.id.description, fillError: fillError)
    }

    /// Moves the row's folder to the Trash, asking first while programs run in its terminals, then closes them and
    /// forgets the row. Links to its item stay. A folder outside the plugin's own, as a hand-edited state.json can
    /// name, is left where it is.
    public func removeRow(_ row: PluginRow, force: Bool) async throws -> PluginRowRemoved {
        let busy = terminals.busyPanes(inRow: row.path)
        if !busy.isEmpty, !force {
            throw WorkspaceError.rowBusy(row.displayName, programs: Self.programs(busy))
        }
        // Moving a folder that shells are in is fine, and a move that fails leaves their programs running.
        var trashedTo: URL?
        if isOwnFolder(row), FileManager.default.fileExists(atPath: row.path) {
            do {
                trashedTo = try trash.trash(URL(fileURLWithPath: row.path))
            } catch {
                throw WorkspaceError.trashFailed(row.path, reason: error.localizedDescription)
            }
        }
        terminals.closeRow(path: row.path)
        let removed = try await workspace.removePluginRow(path: row.path)
        snapshotChanged(await workspace.snapshot)
        record(ActivityType.pluginRowRemoved, removed)
        return PluginRowRemoved(row: removed, trashedTo: trashedTo?.path)
    }

    /// Makes the row's folder again if it was deleted outside Canopy, and lets its plugin fill it, before a terminal
    /// opens there.
    public func ensureFolder(_ row: PluginRow) async {
        guard !FileManager.default.fileExists(atPath: row.path) else { return }
        await refill(row)
    }

    /// The item a link's reference names, for `row.new`, before any git work.
    public func resolveLink(plugin id: String, reference: String) async throws -> PluginLink {
        let plugin = try requireRunning(id)
        return PluginLink(plugin: id, item: try await plugin.resolve(reference, context: context(of: plugin)))
    }

    func select(_ path: String) async {
        try? await workspace.revealRow(path: path)
        try? await workspace.setSelectedRow(path: path)
        await ui?.selectRow(path: path)
    }

    // MARK: Control methods

    /// The plugins' methods that only read, which the activity log leaves out.
    public var readOnlyMethods: Set<String> {
        plugins.reduce(into: []) { $0.formUnion($1.readOnlyMethods) }
    }

    public func handles(_ method: String) -> Bool {
        plugins.contains { $0.methods.contains(method) }
    }

    /// Hands a control method to the plugin that declared it, whether it is on or off, with the plugin's row the
    /// command's target points at.
    public func call(_ method: String, params: JSONValue, target: TargetHint, row: PluginRow?) async throws -> JSONValue
    {
        guard let plugin = plugins.first(where: { $0.methods.contains(method) }) else {
            throw ControlError(code: "unknown_method", message: "Unknown method \(method)")
        }
        let call = PluginCall(
            method: method, params: params, target: target, row: row?.plugin == plugin.info.id ? row : nil)
        return try await plugin.handle(call, context: context(of: plugin))
    }

    // MARK: State

    func section(_ id: String) -> JSONValue? {
        sections[id]
    }

    func state(of id: String) -> PluginState {
        let rows = snapshot.section(id)?.rows ?? []
        return PluginState(
            isOn: on.contains(id), rows: rows, selectedRow: rows.first { $0.path == snapshot.selectedRowPath },
            viewing: viewing)
    }

    private func snapshotChanged(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        publishStates()
    }

    private func publishStates() {
        for plugin in plugins {
            let id = plugin.info.id
            let state = state(of: id)
            guard lastStates[id] != state else { continue }
            lastStates[id] = state
            contexts[id]?.publish(state)
        }
    }

    // MARK: Folders

    /// Makes a folder for a new row under the plugin's folder, named after `name` with anything that would leave it or
    /// trouble a shell taken out, and `-2`, `-3`, and so on added while the name is taken, including by a row whose
    /// folder is gone.
    private func makeFolder(named name: String, plugin id: String) async throws -> String {
        let parent = workspace.home.pluginsRoot.appending(path: id)
        do {
            for folder in [workspace.home.pluginsRoot, parent] {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw WorkspaceError.folderFailed(parent.path, reason: error.localizedDescription)
        }
        // Compared ignoring case, as the file system usually does.
        let taken = Set(await workspace.snapshot.plugins.flatMap(\.rows).map { $0.path.lowercased() })
        let base = Self.folderName(name)
        let root = Paths.canonical(parent.path)
        var suffix = 1
        while true {
            let path = root + "/" + (suffix == 1 ? base : "\(base)-\(suffix)")
            suffix += 1
            if taken.contains(path.lowercased()) { continue }
            if mkdir(path, 0o700) == 0 { return path }
            guard errno == EEXIST else {
                throw WorkspaceError.folderFailed(path, reason: String(cString: strerror(errno)))
            }
        }
    }

    /// `name` as one folder name: path separators and control characters become `-`, leading dots and spaces go, and
    /// it stops at a whole character within 200 bytes, leaving room for a suffix under the file system's 255.
    static func folderName(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control ? "-" : Character(scalar)
        }
        var cleaned = ""
        for character in String(scalars).drop(while: { $0 == "." || $0.isWhitespace }) {
            guard cleaned.utf8.count + character.utf8.count <= 200 else { break }
            cleaned.append(character)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "row" : cleaned
    }

    /// Makes the plugin's rows' missing folders, empty, and returns the rows it made them for.
    private func makeMissingFolders(of plugin: any CanopyPlugin) async -> [PluginRow] {
        let rows = await workspace.snapshot.section(plugin.info.id)?.rows ?? []
        return rows.filter { !FileManager.default.fileExists(atPath: $0.path) && makeRowFolder($0) }
    }

    private func refill(_ row: PluginRow) async {
        guard makeRowFolder(row), running.contains(row.plugin),
            let plugin = plugins.first(where: { $0.info.id == row.plugin })
        else { return }
        await fill(row, plugin: plugin)
    }

    /// Only a folder inside the plugin's own is made again.
    private func makeRowFolder(_ row: PluginRow) -> Bool {
        guard isOwnFolder(row) else { return false }
        do {
            try FileManager.default.createDirectory(
                atPath: row.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            onNotice("Could not make \(row.path) again: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether the row's folder is inside its plugin's folder, where Canopy made it.
    private func isOwnFolder(_ row: PluginRow) -> Bool {
        let parent = Paths.canonical(workspace.home.pluginsRoot.appending(path: row.plugin).path)
        return Paths.isInside(Paths.canonical(row.path), parent) && Paths.canonical(row.path) != parent
    }

    private func fill(_ row: PluginRow, plugin: any CanopyPlugin) async {
        do {
            try await plugin.fill(row, context: context(of: plugin))
        } catch {
            onNotice("\(plugin.info.name) could not fill \(row.displayName) again: \(Self.message(error))")
        }
    }

    // MARK: Internals

    private func listing(_ plugin: any CanopyPlugin, in snapshot: WorkspaceSnapshot) async -> PluginListing {
        let id = plugin.info.id
        let isOn = on.contains(id)
        return PluginListing(
            id: id, name: plugin.info.name, on: isOn, status: isOn ? await plugin.status(context(of: plugin)) : nil,
            warning: snapshot.section(id)?.warning, rows: snapshot.section(id)?.rows.count ?? 0,
            filters: plugin.filters, collapsed: snapshot.section(id)?.collapsed ?? false)
    }

    private func requirePlugin(_ id: String) throws -> any CanopyPlugin {
        guard let plugin = plugins.first(where: { $0.info.id == id }) else { throw WorkspaceError.pluginNotFound(id) }
        return plugin
    }

    /// The plugin, if it is on and its start succeeded.
    private func requireRunning(_ id: String) throws -> any CanopyPlugin {
        let plugin = try requirePlugin(id)
        guard on.contains(id) else {
            throw WorkspaceError.pluginOff(
                plugin.info.name, command: plugin.turnOnCommand(config: sections[id] ?? .object([:])))
        }
        guard running.contains(id) else { throw Self.notStarted(plugin.info.name, startFailures[id]) }
        return plugin
    }

    /// Why a plugin that is on is not running. A start that failed with a code of its own, such as `keychain_failed`,
    /// keeps it, so every command that needs the plugin fails the same way.
    static func notStarted(_ name: String, _ failure: (any Error)?) -> any Error {
        if let failure = failure as? ControlError,
            failure.code != WorkspaceError.pluginNotStarted(name, reason: "").code
        {
            return failure
        }
        return WorkspaceError.pluginNotStarted(name, reason: failure.map(message) ?? "")
    }

    private func context(of plugin: any CanopyPlugin) -> PluginContext {
        contexts[plugin.info.id]!
    }

    private func record(_ type: String, _ row: PluginRow) {
        workspace.activity.record(
            type, row: row.title, path: row.path, data: ["plugin": .string(row.plugin), "item": .string(row.item)])
    }

    public nonisolated static func message(_ error: any Error) -> String {
        switch error {
        case let error as WorkspaceError: error.message
        case let error as ControlError: error.message
        default: "\(error)"
        }
    }

    /// The programs running in busy panes, each once.
    private static func programs(_ panes: [Pane]) -> [String] {
        var seen = Set<String>()
        return panes.map { $0.foreground?.name ?? "A program" }.filter { seen.insert($0).inserted }
    }
}
