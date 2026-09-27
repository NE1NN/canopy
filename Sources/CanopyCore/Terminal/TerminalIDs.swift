/// A pane's ID, such as `p12`. Agents see it as CANOPY_PANE.
public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "p\(number)" }
}

public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "t\(number)" }
}

/// The row a terminal belongs to.
public struct PaneContext: Sendable, Equatable {
    public var repoName: String
    public var repoPath: String
    public var rowName: String
    public var rowPath: String

    public init(row: Row, repoName: String) {
        self.repoName = repoName
        self.repoPath = row.repoPath
        self.rowName = row.displayName
        self.rowPath = row.path
    }
}
