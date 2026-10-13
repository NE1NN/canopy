public struct Worktree: Sendable, Equatable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(
        path: String,
        head: String? = nil,
        branch: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Parses `git worktree list --porcelain -z`. The first entry is always the main worktree.
public enum WorktreeListParser {
    public static func parse(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var current: Worktree?

        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let finished = current {
                    worktrees.append(finished)
                    current = nil
                }
                continue
            }
            let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""

            switch key {
            case "worktree":
                if let finished = current {
                    worktrees.append(finished)
                }
                current = Worktree(path: value)
            case "HEAD":
                current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "bare":
                current?.isBare = true
            case "detached":
                current?.isDetached = true
            case "locked":
                current?.isLocked = true
            case "prunable":
                current?.isPrunable = true
            default:
                break
            }
        }
        if let finished = current {
            worktrees.append(finished)
        }
        return worktrees
    }
}
