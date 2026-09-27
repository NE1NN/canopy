public struct RowClassifier: Sendable {
    public var canopyWorktreesRoot: String
    public var homeDirectory: String

    public init(canopyWorktreesRoot: String, homeDirectory: String) {
        self.canopyWorktreesRoot = canopyWorktreesRoot
        self.homeDirectory = homeDirectory
    }

    public func classify(path: String, isMain: Bool, adopted: Set<String>) -> (RowClass, ExternalTag?) {
        if isMain { return (.main, nil) }
        if Paths.isInside(path, canopyWorktreesRoot) { return (.canopy, nil) }
        if adopted.contains(path) { return (.adopted, nil) }
        if Paths.isInside(path, homeDirectory + "/.superset") { return (.external, .superset) }
        if Paths.isInside(path, homeDirectory + "/conductor") { return (.external, .conductor) }
        return (.external, .other)
    }

    /// Turns parsed worktrees into rows. Bare entries are skipped; the first entry is the main checkout.
    public func rows(
        for worktrees: [Worktree],
        repoPath: String,
        adopted: Set<String>,
        fileExists: (String) -> Bool
    ) -> [Row] {
        worktrees.enumerated().compactMap { index, worktree in
            guard !worktree.isBare else { return nil }
            let path = Paths.canonical(worktree.path)
            let (rowClass, tag) = classify(path: path, isMain: index == 0, adopted: adopted)
            return Row(
                repoPath: repoPath,
                path: path,
                branch: worktree.branch,
                head: worktree.head,
                rowClass: rowClass,
                externalTag: tag,
                isMissing: worktree.isPrunable || !fileExists(path)
            )
        }
    }
}
