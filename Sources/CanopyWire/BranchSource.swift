/// Where a new row's branch came from.
public enum BranchSource: String, Codable, Sendable {
    /// A local branch was checked out.
    case local
    /// A branch on origin was checked out as a new local branch tracking it.
    case origin
    /// Nothing matched, so a new branch was created.
    case new
}
