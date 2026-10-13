import CanopyGit
import CanopyWire

/// canopy-box's failures, with the codes and messages the Mac gives for the same thing.
enum BoxErrors {
    static func repoNotFound(_ name: String) -> ControlError {
        ControlError(code: "repo_not_found", message: "No registered repo matches \"\(name)\". Run `canopy repo list`.")
    }

    static func rowNotFound(_ name: String) -> ControlError {
        ControlError(code: "row_not_found", message: "No row matches \"\(name)\". Run `canopy row list`.")
    }

    static func paneNotFound(_ id: String) -> ControlError {
        ControlError(code: "pane_not_found", message: "No terminal \(id). Run `canopy term list --all`.")
    }

    static let cannotRemoveMain = ControlError(
        code: "cannot_remove_main", message: "The main checkout cannot be removed.")

    static func worktreeDirty(_ path: String) -> ControlError {
        ControlError(
            code: "worktree_dirty", message: "\(path) has uncommitted changes. Pass --force to remove it anyway.")
    }

    static func checkedOut(_ branch: String, mainAt path: String) -> ControlError {
        ControlError(
            code: "branch_checked_out", message: "Branch \(branch) is checked out in the main checkout at \(path).")
    }

    static func checkedOut(_ branch: String, rowAt path: String) -> ControlError {
        ControlError(code: "branch_checked_out", message: "Branch \(branch) already has a row at \(path).")
    }

    static func checkedOutElsewhere(_ branch: String) -> ControlError {
        ControlError(
            code: "branch_checked_out", message: "Branch \(branch) is already checked out in another worktree.")
    }

    static func git(_ error: GitError) -> ControlError {
        ControlError(code: "git_failed", message: error.description)
    }

    static func notConfigured() -> ControlError {
        ControlError(
            code: "not_configured", message: "Canopy on the Mac has not set up this host yet. Run `canopy host add`.")
    }

    static func branch(_ error: BranchError) -> ControlError {
        switch error {
        case .invalidBranch(let name):
            ControlError(code: "invalid_branch", message: "Not a valid branch name: \(name)")
        case .invalidBase(let base):
            ControlError(code: "invalid_base", message: "No commit matches --from \(base).")
        case .branchNotFound(let name, nil):
            ControlError(
                code: "branch_not_found",
                message: "No branch \(name) here or on origin. Leave out --existing to create it.")
        case .branchNotFound(let name, let failure?):
            ControlError(
                code: "branch_not_found",
                message: "No branch \(name) here or in what Canopy last saw of origin, because \(failure).")
        }
    }

    /// Runs `body`, giving git's and the branch rules' failures the Mac's codes.
    static func mapped<T>(
        isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as BranchError {
            throw branch(error)
        } catch let error as GitError {
            throw git(error)
        }
    }
}
