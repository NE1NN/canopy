/// Decides which file events inside a repo's git folder can change its worktree list.
/// Everything else (objects, index, logs, lock files) is noise from normal git use.
public enum GitEventFilter {
    public static func isRelevant(eventPath: String, gitDir: String) -> Bool {
        guard Paths.isInside(eventPath, gitDir), eventPath != gitDir else { return false }
        let relative = eventPath.dropFirst(gitDir.count).split(separator: "/").map(String.init)
        if relative == ["HEAD"] { return true }
        guard relative.first == "worktrees" else { return false }
        if relative.count <= 2 { return true }
        return relative.count == 3 && ["HEAD", "gitdir", "locked"].contains(relative[2])
    }
}
