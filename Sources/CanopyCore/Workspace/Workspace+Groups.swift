import Foundation

/// A group with its rows, as `canopy group` prints it.
public struct GroupInfo: Codable, Sendable, Equatable {
    public var repo: String
    public var repoPath: String
    public var name: String
    public var collapsed: Bool
    public var rows: [Row]

    public init(repo: String, repoPath: String, name: String, collapsed: Bool, rows: [Row]) {
        self.repo = repo
        self.repoPath = repoPath
        self.name = name
        self.collapsed = collapsed
        self.rows = rows
    }

    public init(repo: RepoSnapshot, group: GroupSnapshot) {
        self.init(
            repo: repo.name, repoPath: repo.path, name: group.name, collapsed: group.collapsed,
            rows: repo.rows(inGroup: group.name))
    }
}

public struct MovedRow: Sendable, Equatable {
    public var row: Row
    /// False when the row was already where it was asked to go.
    public var moved: Bool
    /// The group the row was in before, nil if it was ungrouped.
    public var from: String?
}

/// Groups only arrange the sidebar, so changing them runs no git: each change edits the repo's entry, saves it, and
/// rearranges the rows git last listed.
extension Workspace {
    public func groups(repoPath: String) -> [GroupInfo] {
        guard let repo = snapshot.repo(path: repoPath) else { return [] }
        return repo.groups.map { GroupInfo(repo: repo, group: $0) }
    }

    @discardableResult
    public func createGroup(repoPath: String, name: String) throws -> GroupInfo {
        let created = try changeEntry(repoPath: repoPath) { entry, repo in try entry.addGroup(name, repo: repo) }
        recordGroup(ActivityType.groupCreated, repoPath: repoPath, data: ["name": .string(created.name)])
        return try groupInfo(repoPath: repoPath, name: created.name)
    }

    @discardableResult
    public func renameGroup(repoPath: String, name: String, to newName: String) throws -> GroupInfo {
        let (from, to) = try changeEntry(repoPath: repoPath) { entry, repo in
            let from = entry.groupIndex(named: name).map { entry.groups[$0].name }
            return (from, try entry.renameGroup(name, to: newName, repo: repo).name)
        }
        if let from, from != to {
            recordGroup(
                ActivityType.groupRenamed, repoPath: repoPath, data: ["from": .string(from), "to": .string(to)])
        }
        return try groupInfo(repoPath: repoPath, name: to)
    }

    /// Deletes a group, moving its rows to the end of the ungrouped rows. Returns the group as it was.
    @discardableResult
    public func removeGroup(repoPath: String, name: String) throws -> GroupInfo {
        let removed = try groupInfo(repoPath: repoPath, name: name)
        try changeEntry(repoPath: repoPath) { entry, repo in _ = try entry.removeGroup(name, repo: repo) }
        recordGroup(
            ActivityType.groupRemoved, repoPath: repoPath,
            data: ["name": .string(removed.name), "rows": .number(Double(removed.rows.count))])
        return removed
    }

    /// Folding is how the sidebar looks, so it is saved but not logged.
    public func setGroupCollapsed(repoPath: String, name: String, collapsed: Bool) throws {
        try changeEntry(repoPath: repoPath) { entry, repo in
            guard let index = entry.groupIndex(named: name) else {
                throw WorkspaceError.groupNotFound(name.trimmingCharacters(in: .whitespacesAndNewlines), repo: repo)
            }
            entry.groups[index].collapsed = collapsed
        }
    }

    /// Unfolds the group holding a row, so selecting the row shows it.
    public func revealRow(path: String) throws {
        guard let row = snapshot.row(path: path), let group = row.group,
            snapshot.repo(path: row.repoPath)?.groups.first(where: { $0.name == group })?.collapsed == true
        else { return }
        try setGroupCollapsed(repoPath: row.repoPath, name: group, collapsed: false)
    }

    /// Moves a Canopy or adopted row within its repo. Only a change of group is logged, as `row.moved`.
    public func moveRow(path: String, to placement: RowPlacement) throws -> MovedRow {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        switch row.rowClass {
        case .main: throw WorkspaceError.cannotMoveMain
        case .external: throw WorkspaceError.notManaged(path)
        case .canopy, .adopted: break
        }
        let from = row.group
        let moved = try changeEntry(repoPath: row.repoPath) { entry, repo in
            try entry.move(path, to: placement, repo: repo)
        }
        let current = snapshot.row(path: path) ?? row
        if current.group != from {
            record(
                ActivityType.rowMoved, current,
                data: ["from": from.map(JSONValue.string) ?? .null, "to": current.group.map(JSONValue.string) ?? .null])
        }
        return MovedRow(row: current, moved: moved, from: from)
    }

    /// Applies `change` to the repo's entry, and saves and republishes it if the entry changed.
    @discardableResult
    func changeEntry<T>(repoPath: String, _ change: (inout RepoEntry, String) throws -> T) throws -> T {
        let index = try entryIndex(repoPath: repoPath)
        var entry = state.repos[index]
        let result = try change(&entry, snapshot.repo(path: repoPath)?.name ?? entry.dirName)
        guard entry != state.repos[index] else { return result }
        state.repos[index] = entry
        try save()
        rearrange(repoPath: repoPath)
        publish()
        return result
    }

    func rearrange(repoPath: String) {
        guard let entry = state.repos.first(where: { $0.path == repoPath }), let repo = repoSnapshots[repoPath] else {
            return
        }
        repoSnapshots[repoPath] = repo.arranged(by: entry)
    }

    private func groupInfo(repoPath: String, name: String) throws -> GroupInfo {
        let repoName = snapshot.repo(path: repoPath)?.name ?? ""
        guard let repo = snapshot.repo(path: repoPath) else { throw WorkspaceError.repoNotFound(repoPath) }
        let key = GroupName.key(name)
        guard let group = repo.groups.first(where: { $0.id == key }) else {
            throw WorkspaceError.groupNotFound(name.trimmingCharacters(in: .whitespacesAndNewlines), repo: repoName)
        }
        return GroupInfo(repo: repo, group: group)
    }

    private func recordGroup(_ type: String, repoPath: String, data: [String: JSONValue]) {
        activity.record(type, repo: snapshot.repo(path: repoPath)?.name, path: repoPath, data: data)
    }
}
