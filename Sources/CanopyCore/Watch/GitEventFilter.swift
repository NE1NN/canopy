/// Picks out the file events inside a repo's git folder that Canopy acts on.
/// Everything else (objects, index, logs, lock files) is noise from normal git use.
public enum GitEventFilter {
    /// Whether the event can change the repo's worktree list.
    public static func isRelevant(eventPath: String, gitDir: String) -> Bool {
        guard Paths.isInside(eventPath, gitDir), eventPath != gitDir else { return false }
        let relative = eventPath.dropFirst(gitDir.count).split(separator: "/").map(String.init)
        if relative == ["HEAD"] { return true }
        guard relative.first == "worktrees" else { return false }
        if relative.count <= 2 { return true }
        return relative.count == 3 && ["HEAD", "gitdir", "locked"].contains(relative[2])
    }

    /// Whether the event is a write to a remote-tracking branch's reflog, where git records pushes and fetches.
    /// `GitReflog.lastEntryIsPush` tells which one it was.
    public static func isRemoteRefLog(eventPath: String, gitDir: String) -> Bool {
        guard Paths.isInside(eventPath, gitDir), !eventPath.hasSuffix(".lock") else { return false }
        let relative = eventPath.dropFirst(gitDir.count).split(separator: "/")
        return relative.count > 4 && relative.starts(with: ["logs", "refs", "remotes"])
    }
}
