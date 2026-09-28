import Foundation

/// A named set of a repo's rows that the sidebar can fold away. Rows are kept by path, in sidebar order.
public struct RowGroup: Codable, Sendable, Equatable {
    public var name: String
    public var rows: [String]
    public var collapsed: Bool

    public init(name: String, rows: [String] = [], collapsed: Bool = false) {
        self.name = name
        self.rows = rows
        self.collapsed = collapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        rows = try container.decodeIfPresent([String].self, forKey: .rows) ?? []
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

public enum GroupName {
    /// The name as stored: trimmed, not empty, and free of control characters such as newlines.
    public static func validated(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw WorkspaceError.invalidGroupName(raw) }
        return name
    }

    /// Names are unique within a repo ignoring case, and looked up the same way.
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Where a moved row goes. `before` and `after` name another row by path.
public enum RowPlacement: Sendable, Equatable {
    /// The end of a group.
    case group(String)
    /// The end of the ungrouped rows.
    case ungrouped
    case before(String)
    case after(String)
}

/// Each Canopy or adopted row of a repo sits in exactly one list: `rowOrder` for the ungrouped rows, or one group's.
extension RepoEntry {
    public func groupIndex(named name: String) -> Int? {
        let key = GroupName.key(name)
        return groups.firstIndex { GroupName.key($0.name) == key }
    }

    public func groupName(of path: String) -> String? {
        groups.first { $0.rows.contains(path) }?.name
    }

    public func holds(_ path: String) -> Bool {
        rowOrder.contains(path) || groups.contains { $0.rows.contains(path) }
    }

    @discardableResult
    mutating func addGroup(_ name: String, repo: String) throws -> RowGroup {
        let name = try GroupName.validated(name)
        if let existing = groupIndex(named: name) {
            throw WorkspaceError.groupExists(groups[existing].name, repo: repo)
        }
        groups.append(RowGroup(name: name))
        return groups[groups.count - 1]
    }

    @discardableResult
    mutating func renameGroup(_ name: String, to newName: String, repo: String) throws -> RowGroup {
        let index = try requireGroup(name, repo: repo)
        let newName = try GroupName.validated(newName)
        if let other = groupIndex(named: newName), other != index {
            throw WorkspaceError.groupExists(groups[other].name, repo: repo)
        }
        groups[index].name = newName
        return groups[index]
    }

    /// Deletes a group. Its rows go to the end of the ungrouped rows, in their order.
    @discardableResult
    mutating func removeGroup(_ name: String, repo: String) throws -> RowGroup {
        let removed = groups.remove(at: try requireGroup(name, repo: repo))
        rowOrder += removed.rows
        return removed
    }

    /// Returns whether the row moved. A move that would leave it where it is changes nothing.
    mutating func move(_ path: String, to placement: RowPlacement, repo: String) throws -> Bool {
        guard holds(path) else { throw WorkspaceError.rowNotFound(path) }
        var moved = self
        moved.forget(path)
        switch placement {
        case .group(let name):
            let index = try requireGroup(name, repo: repo)
            guard !groups[index].rows.contains(path) else { return false }
            moved.groups[index].rows.append(path)
        case .ungrouped:
            guard !rowOrder.contains(path) else { return false }
            moved.rowOrder.append(path)
        case .before(let anchor), .after(let anchor):
            guard anchor != path, holds(anchor) else { throw WorkspaceError.invalidAnchor(anchor) }
            let offset = placement == .after(anchor) ? 1 : 0
            if let index = moved.rowOrder.firstIndex(of: anchor) {
                moved.rowOrder.insert(path, at: index + offset)
            } else if let group = moved.groups.firstIndex(where: { $0.rows.contains(anchor) }),
                let index = moved.groups[group].rows.firstIndex(of: anchor)
            {
                moved.groups[group].rows.insert(path, at: index + offset)
            }
        }
        guard moved != self else { return false }
        self = moved
        return true
    }

    /// Brings the lists in line with the repo's current Canopy and adopted rows, as git lists them. Rows that went away
    /// leave their list, and new rows go to the end of the group `joining` names for them, or else of `rowOrder`.
    /// Empty groups stay. Returns whether anything changed.
    mutating func reconcile(present: [String], joining: [String: String] = [:]) -> Bool {
        let original = self
        let isPresent = Set(present)
        var placed = Set<String>()
        for index in groups.indices {
            groups[index].rows = groups[index].rows.filter { isPresent.contains($0) && placed.insert($0).inserted }
        }
        rowOrder = rowOrder.filter { isPresent.contains($0) && placed.insert($0).inserted }
        for path in present where placed.insert(path).inserted {
            place(path, joining: joining[path])
        }
        return self != original
    }

    /// Puts a row the entry does not hold yet at the end of its group, or of the ungrouped rows if it has none or the
    /// group is gone.
    mutating func place(_ path: String, joining group: String?) {
        guard !holds(path) else { return }
        if let group, let index = groupIndex(named: group) {
            groups[index].rows.append(path)
        } else {
            rowOrder.append(path)
        }
    }

    /// Makes groups read from a file follow the rules: valid names unique ignoring case, and each path in one place,
    /// the first group that lists it.
    mutating func cleanGroups() {
        var names = Set<String>()
        var placed = Set<String>()
        groups = groups.compactMap { group in
            guard let name = try? GroupName.validated(group.name), names.insert(GroupName.key(name)).inserted else {
                return nil
            }
            return RowGroup(
                name: name, rows: group.rows.filter { placed.insert($0).inserted }, collapsed: group.collapsed)
        }
        rowOrder = rowOrder.filter { placed.insert($0).inserted }
    }

    private func requireGroup(_ name: String, repo: String) throws -> Int {
        guard let index = groupIndex(named: name) else {
            throw WorkspaceError.groupNotFound(name.trimmingCharacters(in: .whitespacesAndNewlines), repo: repo)
        }
        return index
    }

    /// Takes a row out of whichever list holds it.
    mutating func forget(_ path: String) {
        rowOrder.removeAll { $0 == path }
        for index in groups.indices {
            groups[index].rows.removeAll { $0 == path }
        }
    }
}
