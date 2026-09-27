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

    /// Whether a write in the git folder updated a remote-tracking branch, which is what `git push` leaves behind.
    public static func isRemoteRefChange(eventPath: String, gitDir: String) -> Bool {
        guard Paths.isInside(eventPath, gitDir), !eventPath.hasSuffix(".lock") else { return false }
        let relative = eventPath.dropFirst(gitDir.count).split(separator: "/")
        return relative == ["packed-refs"] || (relative.count > 2 && relative.starts(with: ["refs", "remotes"]))
    }
}
