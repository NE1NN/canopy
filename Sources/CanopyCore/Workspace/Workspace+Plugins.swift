import Foundation

/// Plugin rows live in state.json beside the repos, and each plugin's section rides in the same snapshot as the repos,
/// so the sidebar, ⌘1 to ⌘9, and target resolution read one source. What a plugin row looks like, and whether its
/// plugin is on, only live while Canopy runs.
extension Workspace {
    /// The built-in plugins, in the order their sections show.
    public func registerPlugins(_ infos: [PluginInfo]) {
        pluginInfos = infos
        publish()
    }

    public func setPlugin(_ id: String, on: Bool) {
        guard pluginsOn.contains(id) != on else { return }
        if on { pluginsOn.insert(id) } else { pluginsOn.remove(id) }
        publish()
    }

    public func setPluginWarning(_ id: String, _ warning: String?) {
        guard pluginWarnings[id] != warning else { return }
        pluginWarnings[id] = warning
        publish()
    }

    /// Replaces the looks of the plugin's rows at these paths. Paths that are not its rows are ignored.
    public func setPluginLooks(_ looks: [String: PluginRowLook], plugin id: String) {
        let paths = Set(state.plugins[id]?.rows.map(\.path) ?? [])
        var changed = false
        for (path, look) in looks where paths.contains(path) && pluginLooks[path] != look {
            pluginLooks[path] = look
            changed = true
        }
        if changed { publish() }
    }

    public func pluginEntry(_ id: String) -> PluginEntry? {
        state.plugins[id]
    }

    /// Adds a row at the end of its plugin's section. Each item has at most one row.
    @discardableResult
    public func addPluginRow(_ entry: PluginRowEntry, plugin id: String) throws -> PluginRow {
        guard let info = pluginInfos.first(where: { $0.id == id }) else { throw WorkspaceError.pluginNotFound(id) }
        var plugin = state.plugins[id] ?? PluginEntry()
        if let existing = plugin.rows.first(where: { $0.item == entry.item }) {
            throw WorkspaceError.itemHasRow(existing.path)
        }
        plugin.rows.append(entry)
        state.plugins[id] = plugin
        pluginLooks[entry.path] = nil
        try save()
        publish()
        return PluginRow(plugin: info.id, item: entry.item, title: entry.title, path: entry.path)
    }

    /// Forgets a plugin row, whether its plugin is on or off. Links to its item stay, so a new row for the item shows
    /// its linked rows again.
    @discardableResult
    public func removePluginRow(path: String) throws -> PluginRow {
        guard let (id, index) = pluginRowIndex(path) else { throw WorkspaceError.rowNotFound(path) }
        let entry = state.plugins[id]!.rows.remove(at: index)
        let row = PluginRow(
            plugin: id, item: entry.item, title: entry.title, path: entry.path, look: pluginLooks[path] ?? .plain)
        pluginLooks[path] = nil
        if state.selectedRowPath == path {
            state.selectedRowPath = nil
        }
        try save()
        publish()
        return row
    }

    /// Puts a plugin row just before or after another row of the same plugin. Returns whether it moved.
    public func movePluginRow(path: String, to placement: RowPlacement) throws -> Bool {
        guard let (id, index) = pluginRowIndex(path) else { throw WorkspaceError.rowNotFound(path) }
        let anchor: String
        switch placement {
        case .group, .ungrouped: throw WorkspaceError.pluginRowsHaveNoGroups
        case .before(let other), .after(let other): anchor = other
        }
        var rows = state.plugins[id]!.rows
        guard anchor != path, rows.contains(where: { $0.path == anchor }) else {
            throw WorkspaceError.invalidPluginAnchor(anchor)
        }
        let moved = rows.remove(at: index)
        let target = rows.firstIndex { $0.path == anchor }! + (placement == .after(anchor) ? 1 : 0)
        rows.insert(moved, at: target)
        guard rows != state.plugins[id]!.rows else { return false }
        state.plugins[id]!.rows = rows
        try save()
        publish()
        return true
    }

    public func setPluginPanelWidth(_ width: Double, plugin id: String) throws {
        guard state.plugins[id]?.panelWidth != width else { return }
        state.plugins[id, default: PluginEntry()].panelWidth = width
        try save()
        publish()
    }

    /// Ties a worktree row to one of a plugin's items.
    public func setPluginLink(_ link: PluginLink, forRow path: String) throws {
        guard state.plugins[link.plugin]?.links[path] != link.item else { return }
        state.plugins[link.plugin, default: PluginEntry()].links[path] = link.item
        try save()
        publish()
    }

    /// The item each linked worktree row is for, by the row's path, whether its plugin is on or not.
    var rowLinks: [String: PluginLink] {
        var links: [String: PluginLink] = [:]
        for (plugin, entry) in state.plugins {
            for (path, item) in entry.links {
                links[path] = PluginLink(plugin: plugin, item: item)
            }
        }
        return links
    }

    /// Drops the links of the rows `gone` names. The caller saves. Returns whether any went.
    @discardableResult
    func dropLinks(where gone: (String) -> Bool) -> Bool {
        var dropped = false
        for (plugin, entry) in state.plugins {
            let kept = entry.links.filter { !gone($0.key) }
            if kept.count != entry.links.count {
                state.plugins[plugin]?.links = kept
                dropped = true
            }
        }
        return dropped
    }

    /// Whether a path is where one of the repo's Canopy or adopted rows is or was: inside its Canopy folder, or
    /// adopted.
    func owns(_ entry: RepoEntry, _ path: String) -> Bool {
        let folder = Paths.canonical(home.worktreesRoot.appending(path: entry.dirName).path)
        return Paths.isInside(path, folder) || entry.adopted.contains(path)
    }

    /// Each registered plugin's section, with its rows as they look now.
    var pluginSections: [PluginSection] {
        pluginInfos.map { info in
            let entry = state.plugins[info.id] ?? PluginEntry()
            return PluginSection(
                info: info, isOn: pluginsOn.contains(info.id), warning: pluginWarnings[info.id],
                rows: entry.rows.map {
                    PluginRow(
                        plugin: info.id, item: $0.item, title: $0.title, path: $0.path,
                        look: pluginLooks[$0.path] ?? .plain)
                },
                panelWidth: entry.panelWidth, collapsed: entry.collapsed)
        }
    }

    private func pluginRowIndex(_ path: String) -> (String, Int)? {
        for (id, entry) in state.plugins {
            if let index = entry.rows.firstIndex(where: { $0.path == path }) { return (id, index) }
        }
        return nil
    }
}
