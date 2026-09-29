import Foundation

/// Where a branch exists: here, on origin, or both.
public enum BranchLocation: String, Codable, Sendable {
    case local, origin, both
}

/// A branch as `canopy branch list` and the New Row sheet show it.
public struct ListedBranch: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var location: BranchLocation
    /// Commits the local branch has that origin's does not, when the branch is in both places.
    public var ahead: Int?
    /// Commits origin's branch has that the local one does not, when the branch is in both places.
    public var behind: Int?
    /// When the newer of its local and origin commits was made, in ISO 8601.
    public var committedAt: String
    /// The row or worktree that has the branch checked out.
    public var row: BranchHolder?

    public var id: String { name }

    public init(
        name: String, location: BranchLocation, ahead: Int? = nil, behind: Int? = nil, committedAt: String,
        row: BranchHolder? = nil
    ) {
        self.name = name
        self.location = location
        self.ahead = ahead
        self.behind = behind
        self.committedAt = committedAt
        self.row = row
    }

    /// Where the branch is, and how the local branch compares with origin's.
    public var label: String {
        switch (location, ahead ?? 0, behind ?? 0) {
        case (.origin, _, _): "origin"
        case (.local, _, _), (.both, 0, 0): "local"
        case (.both, 0, let behind): "local, \(behind) behind"
        case (.both, let ahead, 0): "local, \(ahead) ahead"
        case (.both, _, _): "local ≠ origin"
        }
    }

    public func matches(_ search: SearchText) -> Bool {
        search.matches([name])
    }

    enum CodingKeys: String, CodingKey {
        case name, ahead, behind, committedAt, row
        case location = "where"
    }

    /// Writes nulls rather than leaving keys out, so every branch has the same fields.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(location, forKey: .location)
        try container.encode(ahead, forKey: .ahead)
        try container.encode(behind, forKey: .behind)
        try container.encode(committedAt, forKey: .committedAt)
        try container.encode(row, forKey: .row)
    }
}

/// A repo's branches, and what a new branch starts from.
public struct BranchListing: Codable, Sendable, Equatable {
    public var branches: [ListedBranch]
    /// Where a new branch starts when no start point is given, such as origin/main.
    public var defaultBase: String
    /// Why the list may be out of date, such as a failed fetch.
    public var warnings: [String]

    public init(branches: [ListedBranch], defaultBase: String, warnings: [String] = []) {
        self.branches = branches
        self.defaultBase = defaultBase
        self.warnings = warnings
    }
}
