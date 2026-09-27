public enum WorkspaceError: Error, Sendable, Equatable {
    case pathNotFound(String)
    case notAGitRepo(String)
    case bareRepo(String)
    case repoNotFound(String)
    case alreadyRegistered(String)
    case rowNotFound(String)
    case ambiguousRow(String, repos: [String])
    case missingTarget(flag: String)
    case invalidBranch(String)
    case branchCheckedOut(String)
    case worktreeDirty(String)
    case cannotRemoveMain
    case notManaged(String)
    case git(GitError)

    public var code: String {
        switch self {
        case .pathNotFound: "path_not_found"
        case .notAGitRepo: "not_a_git_repo"
        case .bareRepo: "bare_repo"
        case .repoNotFound: "repo_not_found"
        case .alreadyRegistered: "already_registered"
        case .rowNotFound: "row_not_found"
        case .ambiguousRow: "ambiguous_row"
        case .missingTarget: "missing_target"
        case .invalidBranch: "invalid_branch"
        case .branchCheckedOut: "branch_checked_out"
        case .worktreeDirty: "worktree_dirty"
        case .cannotRemoveMain: "cannot_remove_main"
        case .notManaged: "not_managed"
        case .git: "git_failed"
        }
    }

    public var message: String {
        switch self {
        case .pathNotFound(let path): "No such folder: \(path)"
        case .notAGitRepo(let path): "Not a git repository: \(path)"
        case .bareRepo(let path): "Bare repositories have no checkout to show: \(path)"
        case .repoNotFound(let name): "No registered repo matches \"\(name)\". Run `canopy repo list`."
        case .alreadyRegistered(let path): "\(path) is already registered."
        case .rowNotFound(let name): "No row matches \"\(name)\". Run `canopy row list`."
        case .ambiguousRow(let name, let repos):
            "\"\(name)\" exists in several repos (\(repos.joined(separator: ", "))). Pass --repo."
        case .missingTarget(let flag): "Could not tell which one you mean. Pass \(flag)."
        case .invalidBranch(let name): "Not a valid branch name: \(name)"
        case .branchCheckedOut(let name): "Branch \(name) is already checked out in another worktree."
        case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
        case .cannotRemoveMain: "The main checkout cannot be removed."
        case .notManaged(let path): "\(path) belongs to another tool. Adopt it first."
        case .git(let error): error.description
        }
    }
}
