/// A pane's ID, such as `p12`. Agents see it as CANOPY_PANE.
public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "p\(number)" }

    /// Reads "p12" back, as dragged panes and `canopy term` carry it.
    public init?(_ text: String) {
        guard text.hasPrefix("p"), let number = Int(text.dropFirst()), number > 0 else { return nil }
        self.number = number
    }
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
