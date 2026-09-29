/// Resolves `--repo` and row arguments. Order: explicit argument, then CANOPY_* variables,
/// then the worktree containing the current folder. Anything else is an error naming the flag.
public enum TargetResolver {
    public static func repo(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> RepoSnapshot {
        if let repo = try repoIfKnown(for: hint, in: snapshot) { return repo }
        throw WorkspaceError.missingTarget(flag: "--repo")
    }

    public static func row(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> Row {
        if let name = hint.row {
            if isPath(name) {
                guard let row = snapshot.row(path: Paths.canonical(name)) else {
                    throw WorkspaceError.rowNotFound(name)
                }
                return row
            }
            let scope = try repoIfKnown(
                for: TargetHint(repo: hint.repo, envRepo: hint.envRepo, envRowPath: hint.envRowPath, cwd: hint.cwd),
                in: snapshot)
            let candidates = (scope.map { [$0] } ?? snapshot.repos).flatMap { repo in
                repo.allRows.filter { $0.branch == name }.map { (repo.name, $0) }
            }
            switch candidates.count {
            case 0: throw WorkspaceError.rowNotFound(name)
            case 1: return candidates[0].1
            default: throw WorkspaceError.ambiguousRow(name, repos: candidates.map(\.0))
            }
        }
        if let path = hint.envRowPath, let row = snapshot.row(path: Paths.canonical(path)) {
            return row
        }
        if let cwd = hint.cwd, let row = deepestRow(containing: Paths.canonical(cwd), in: snapshot) {
            return row
        }
        throw WorkspaceError.missingTarget(flag: "a row argument")
    }

    /// A worktree row, as `row(for:in:)` finds it, or a row of a plugin that is on. A plugin row is found by its path,
    /// by CANOPY_ROW_PATH, or by the folder the CLI runs in, and never by a name.
    public static func sidebarRow(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> SidebarRow {
        if let name = hint.row {
            guard isPath(name) else { return .worktree(try row(for: hint, in: snapshot)) }
            guard let row = snapshot.sidebarRow(path: Paths.canonical(name)) else {
                throw WorkspaceError.rowNotFound(name)
            }
            return row
        }
        if let path = hint.envRowPath, let row = snapshot.sidebarRow(path: Paths.canonical(path)) {
            return row
        }
        if let cwd = hint.cwd {
            let path = Paths.canonical(cwd)
            let rows =
                snapshot.repos.flatMap(\.allRows).map(SidebarRow.worktree)
                + snapshot.activePlugins.flatMap(\.rows).map(SidebarRow.plugin)
            if let row = rows.filter({ Paths.isInside(path, $0.path) }).max(by: { $0.path.count < $1.path.count }) {
                return row
            }
        }
        throw WorkspaceError.missingTarget(flag: "a row argument")
    }

    static func repoIfKnown(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> RepoSnapshot? {
        if let name = hint.repo {
            guard let repo = match(repo: name, in: snapshot) else { throw WorkspaceError.repoNotFound(name) }
            return repo
        }
        if let row = hint.row, isPath(row), let found = snapshot.row(path: Paths.canonical(row)) {
            return snapshot.repo(path: found.repoPath)
        }
        if let name = hint.envRepo, let repo = match(repo: name, in: snapshot) {
            return repo
        }
        if let path = hint.envRowPath, let row = snapshot.row(path: Paths.canonical(path)) {
            return snapshot.repo(path: row.repoPath)
        }
        if let cwd = hint.cwd, let row = deepestRow(containing: Paths.canonical(cwd), in: snapshot) {
            return snapshot.repo(path: row.repoPath)
        }
        return nil
    }

    static func match(repo name: String, in snapshot: WorkspaceSnapshot) -> RepoSnapshot? {
        if isPath(name) {
            let path = Paths.canonical(name)
            return snapshot.repos.first { $0.path == path }
        }
        return snapshot.repos.first { $0.name == name }
    }

    static func deepestRow(containing path: String, in snapshot: WorkspaceSnapshot) -> Row? {
        snapshot.repos.flatMap(\.allRows)
            .filter { Paths.isInside(path, $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    static func isPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".")
    }
}
