public enum WorkspaceError: Error, Sendable, Equatable {
    case homeInUse(String)
    case pathNotFound(String)
    case notAGitRepo(String)
    case bareRepo(String)
    case repoNotFound(String)
    case alreadyRegistered(String)
    case rowNotFound(String)
    case ambiguousRow(String, repos: [String])
    case missingTarget(flag: String)
    case invalidBranch(String)
    case invalidBase(String)
    /// `row` is where the branch is checked out, when Canopy knows.
    case branchCheckedOut(String, row: Row?)
    /// `fetchFailure` says why origin's branches may be out of date.
    case branchNotFound(String, fetchFailure: String?)
    case worktreeDirty(String)
    case cannotRemoveMain
    case notManaged(String)
    case badConfig(String, reason: String)
    case teardownFailed(Int32)
    case teardownStopped
    case paneNotFound(String)
    case paneBusy(String, program: String)
    case paneExited(String)
    case noPullRequestLookup(String)
    case notOnGitHub(String)
    case ghUnavailable(String)
    case ghFailed(String)
    case portNotFound(Int)
    case portInOtherRow(Int, row: String)
    case git(GitError)

    public var code: String {
        switch self {
        case .homeInUse: "home_in_use"
        case .pathNotFound: "path_not_found"
        case .notAGitRepo: "not_a_git_repo"
        case .bareRepo: "bare_repo"
        case .repoNotFound: "repo_not_found"
        case .alreadyRegistered: "already_registered"
        case .rowNotFound: "row_not_found"
        case .ambiguousRow: "ambiguous_row"
        case .missingTarget: "missing_target"
        case .invalidBranch: "invalid_branch"
        case .invalidBase: "invalid_base"
        case .branchCheckedOut: "branch_checked_out"
        case .branchNotFound: "branch_not_found"
        case .worktreeDirty: "worktree_dirty"
        case .cannotRemoveMain: "cannot_remove_main"
        case .notManaged: "not_managed"
        case .badConfig: "bad_config"
        case .teardownFailed: "teardown_failed"
        case .teardownStopped: "teardown_stopped"
        case .paneNotFound: "pane_not_found"
        case .paneBusy: "pane_busy"
        case .paneExited: "pane_exited"
        case .noPullRequestLookup: "no_pr_lookup"
        case .notOnGitHub: "not_github"
        case .ghUnavailable: "gh_unavailable"
        case .ghFailed: "gh_failed"
        case .portNotFound: "port_not_found"
        case .portInOtherRow: "port_in_other_row"
        case .git: "git_failed"
        }
    }

    public var message: String {
        switch self {
        case .homeInUse(let path): "Another Canopy is already using \(path)."
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
        case .invalidBase(let ref): "No commit matches --from \(ref)."
        case .branchCheckedOut(let name, let row?):
            switch row.rowClass {
            case .main: "Branch \(name) is checked out in the main checkout at \(row.path)."
            case .canopy, .adopted:
                "Branch \(name) already has a row at \(row.path). Run `canopy row select \(name)` to show it."
            case .external:
                "Branch \(name) is checked out in another tool's worktree at \(row.path). "
                    + "Run `canopy row adopt \(row.path)` to show it as a row."
            }
        case .branchCheckedOut(let name, nil): "Branch \(name) is already checked out in another worktree."
        case .branchNotFound(let name, nil):
            "No branch \(name) here or on origin. Leave out --existing to create it."
        case .branchNotFound(let name, let failure?):
            "No branch \(name) here or in what Canopy last saw of origin, because \(failure)."
        case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
        case .cannotRemoveMain: "The main checkout cannot be removed."
        case .notManaged(let path): "\(path) belongs to another tool. Adopt it first."
        case .badConfig(let path, let reason): "Could not read \(path): \(reason)"
        case .teardownFailed(let code):
            "Teardown failed with exit code \(code). Its tab shows why. Pass --force to remove the row anyway."
        case .teardownStopped: "Teardown stopped because its tab was closed. The row was not removed."
        case .paneNotFound(let id): "No terminal \(id). Run `canopy term list --all`."
        case .paneBusy(let id, let program): "\(program) is still running in \(id). Pass --force to close it anyway."
        case .paneExited(let id): "The shell in \(id) has exited. Close it, or restart it from the window."
        case .noPullRequestLookup(let name):
            "Canopy only looks up PRs for its own and adopted rows on a branch, and \(name) is not one."
        case .notOnGitHub(let repo): "\(repo)'s origin is not on GitHub, so its rows have no PRs."
        case .ghUnavailable(let warning): warning
        case .ghFailed(let message): "Pull requests did not load: \(message)"
        case .portNotFound(let port):
            "No row's process listens on port \(port). Run `canopy ports --all`; Canopy only stops its rows' ports."
        case .portInOtherRow(let port, let row):
            "Port \(port) belongs to \(row), not to this row. Pass --row \(row), or --all to stop it anywhere."
        case .git(let error): error.description
        }
    }
}
