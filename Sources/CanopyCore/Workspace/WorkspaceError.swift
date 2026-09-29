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
    /// Local branches a PR's row could have used, none of which is the PR's.
    case branchExists([String], pr: Int)
    case invalidPullRequest(String)
    case pullRequestInOtherRepo(String, origin: String)
    case pullRequestNotFound(Int, repo: String)
    case pullRequestFetchFailed(Int, reason: String)
    case worktreeDirty(String)
    case cannotRemoveMain
    case notManaged(String)
    case badConfig(String, reason: String)
    case teardownFailed(Int32)
    case teardownStopped
    case paneNotFound(String)
    case paneBusy(String, program: String)
    case paneExited(String)
    case waitTimeout([String], String)
    case paneClosed(String)
    case agentStopped(String)
    case settingsInvalid(String, reason: String)
    case settingsWriteFailed(String, reason: String)
    case configInvalid(String, reason: String)
    case configWriteFailed(String, reason: String)
    case noPullRequestLookup(String)
    case notOnGitHub(String)
    case ghUnavailable(String)
    case ghFailed(String)
    case portNotFound(Int)
    case portInOtherRow(Int, row: String)
    case invalidCloneSource(String)
    case cloneNeedsFolder(String)
    /// `holding` says what the folder holds, such as "a clone of <url>", or is nil for anything that is not a repo.
    case folderTaken(String, holding: String?)
    case cloneFailed(String, reason: String)
    case cloneCancelled
    case invalidGroupName(String)
    case groupExists(String, repo: String)
    case groupNotFound(String, repo: String)
    case cannotMoveMain
    case invalidAnchor(String)
    case invalidPluginAnchor(String)
    case pluginRowsHaveNoGroups
    case pluginNotFound(String)
    case pluginOff(String, id: String)
    /// The path of the row the item already has.
    case itemHasRow(String)
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
        case .branchExists: "branch_exists"
        case .invalidPullRequest, .pullRequestInOtherRepo: "invalid_pr"
        case .pullRequestNotFound: "pr_not_found"
        case .pullRequestFetchFailed: "git_failed"
        case .worktreeDirty: "worktree_dirty"
        case .cannotRemoveMain: "cannot_remove_main"
        case .notManaged: "not_managed"
        case .badConfig: "bad_config"
        case .teardownFailed: "teardown_failed"
        case .teardownStopped: "teardown_stopped"
        case .paneNotFound: "pane_not_found"
        case .paneBusy: "pane_busy"
        case .paneExited: "pane_exited"
        case .waitTimeout: "wait_timeout"
        case .paneClosed: "pane_closed"
        case .agentStopped: "agent_stopped"
        case .settingsInvalid: "settings_invalid"
        case .settingsWriteFailed: "settings_write_failed"
        case .configInvalid: "config_invalid"
        case .configWriteFailed: "config_write_failed"
        case .noPullRequestLookup: "no_pr_lookup"
        case .notOnGitHub: "not_github"
        case .ghUnavailable: "gh_unavailable"
        case .ghFailed: "gh_failed"
        case .portNotFound: "port_not_found"
        case .portInOtherRow: "port_in_other_row"
        case .invalidCloneSource: "invalid_clone_source"
        case .cloneNeedsFolder: "missing_target"
        case .folderTaken: "folder_taken"
        case .cloneFailed: "clone_failed"
        case .cloneCancelled: "clone_cancelled"
        case .invalidGroupName: "invalid_group_name"
        case .groupExists: "group_exists"
        case .groupNotFound: "group_not_found"
        case .cannotMoveMain: "cannot_move_main"
        case .invalidAnchor, .invalidPluginAnchor: "invalid_anchor"
        case .pluginRowsHaveNoGroups: "bad_params"
        case .pluginNotFound: "plugin_not_found"
        case .pluginOff: "plugin_off"
        case .itemHasRow: "item_has_row"
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
        case .branchExists(let names, let number) where names.count == 1:
            "Branch \(names[0]) already exists and is not PR #\(number)'s branch. Pass another --branch."
        case .branchExists(let names, let number):
            "Branches \(names.joined(separator: " and ")) already exist and are not PR #\(number)'s. "
                + "Pass --branch to name the row's branch."
        case .invalidPullRequest(let text): "Pass a PR number, #number, or PR URL, not \"\(text)\"."
        case .pullRequestInOtherRepo(let repo, let origin):
            "That PR is in \(repo), but this repo's origin is \(origin). Pass --repo for a repo whose origin is \(repo)."
        case .pullRequestNotFound(let number, let repo): "\(repo) has no PR #\(number)."
        case .pullRequestFetchFailed(let number, let reason): "Could not fetch PR #\(number) from origin: \(reason)"
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
        case .waitTimeout(let ids, let target):
            "\(ids.joined(separator: ", ")) did not become \(target) before the timeout."
        case .paneClosed(let id): "\(id) closed during the wait."
        case .agentStopped(let id):
            "The agent in \(id) stopped without finishing: it exited, was interrupted, or was set to none."
        case .settingsInvalid(let path, let reason):
            "\(path) is not settings Claude Code can read (\(reason)). Nothing was changed."
        case .settingsWriteFailed(let path, let reason): "Could not write \(path): \(reason). Nothing was changed."
        case .configInvalid(let path, let reason):
            "\(path) is not settings Canopy can read (\(reason)). Nothing was changed."
        case .configWriteFailed(let path, let reason): "Could not write \(path): \(reason). Nothing was changed."
        case .noPullRequestLookup(let name):
            "Canopy only looks up PRs for its own and adopted rows on a branch, and \(name) is not one."
        case .notOnGitHub(let repo): "\(repo)'s origin is not on GitHub, so its rows have no PRs."
        case .ghUnavailable(let warning): warning
        case .ghFailed(let message): "Pull requests did not load: \(message)"
        case .portNotFound(let port):
            "No row's process listens on port \(port). Run `canopy ports --all`; Canopy only stops its rows' ports."
        case .portInOtherRow(let port, let row):
            "Port \(port) belongs to \(row), not to this row. Pass --row \(row), or --all to stop it anywhere."
        case .invalidCloneSource(let text): "Pass owner/repo or a URL to clone, not \"\(text)\"."
        case .cloneNeedsFolder(let text): "Canopy cannot tell which folder \(text) goes in. Pass --into."
        case .folderTaken(let path, let holding?):
            "\(path) already holds \(holding). Pass --into to clone somewhere else."
        case .folderTaken(let path, nil):
            "\(path) is already there and is not an empty folder. Pass --into to clone somewhere else."
        case .cloneFailed(let source, let reason): "Could not clone \(source): \(reason)"
        case .cloneCancelled: "The clone was stopped before it finished."
        case .invalidGroupName: "A group name cannot be empty or hold control characters such as a newline."
        case .groupExists(let name, let repo): "\(repo) already has a group named \(name)."
        case .groupNotFound(let name, let repo): "\(repo) has no group named \"\(name)\". Run `canopy group list`."
        case .cannotMoveMain: "The main checkout always comes first and cannot join a group."
        case .invalidAnchor(let name):
            "--before and --after take another Canopy or adopted row of the same repo, and \(name) is not one."
        case .invalidPluginAnchor(let name):
            "--before and --after take another row of the same plugin, and \(name) is not one."
        case .pluginRowsHaveNoGroups: "Plugin rows have no groups. Move them with --before or --after."
        case .pluginNotFound(let id): "No plugin is named \"\(id)\". Run `canopy plugin list`."
        case .pluginOff(let name, let id): "\(name) is off. Run `canopy plugin enable \(id)` to turn it on."
        case .itemHasRow(let path):
            "That item already has a row at \(path). Run `canopy row select \(path)` to show it."
        case .git(let error): error.description
        }
    }
}
