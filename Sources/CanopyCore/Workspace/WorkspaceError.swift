public enum WorkspaceError: Error, Sendable, Equatable {
    case pathNotFound(String)
    case notAGitRepo(String)
    case bareRepo(String)
    case repoNotFound(String)
    case rowNotFound(String)
    case git(GitError)

    public var code: String {
        switch self {
        case .pathNotFound: "path_not_found"
        case .notAGitRepo: "not_a_git_repo"
        case .bareRepo: "bare_repo"
        case .repoNotFound: "repo_not_found"
        case .rowNotFound: "row_not_found"
        case .git: "git_failed"
        }
    }

    public var message: String {
        switch self {
        case .pathNotFound(let path): "No such folder: \(path)"
        case .notAGitRepo(let path): "Not a git repository: \(path)"
        case .bareRepo(let path): "Bare repositories have no checkout to show: \(path)"
        case .repoNotFound(let name): "No registered repo matches \"\(name)\". Run `canopy repo list`."
        case .rowNotFound(let name): "No row matches \"\(name)\". Run `canopy row list`."
        case .git(let error): error.description
        }
    }
}
