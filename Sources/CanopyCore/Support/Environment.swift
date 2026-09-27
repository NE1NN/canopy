import Foundation

public enum ShellEnvironment {
    private static let marker = "__CANOPY_PATH__"

    /// PATH as the user's interactive login shell sets it. Apps started by launchd only get
    /// /usr/bin:/bin:/usr/sbin:/sbin, which breaks git hooks that call Homebrew tools like git-lfs.
    public static func loginPath(shell: String, timeout: Duration) -> String? {
        let command = "printf '\(marker)%s\(marker)' \"$PATH\""
        guard
            let result = try? Subprocess.run(
                shell, ["-ilc", command], environment: ProcessInfo.processInfo.environment,
                directory: NSHomeDirectory(), timeout: timeout),
            !result.timedOut
        else { return nil }
        let output = String(decoding: result.stdout, as: UTF8.self)
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// The login PATH for the user's shell, resolved once per process.
    public static let userLoginPath: String? = loginPath(
        shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: .seconds(5)
    )
}

public enum GitEnvironment {
    /// Variables that point git at a different repository than the one it runs in.
    static let repositoryOverrides = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"]

    public static func build(base: [String: String], loginPath: String?) -> [String: String] {
        var environment = base
        for key in repositoryOverrides {
            environment[key] = nil
        }
        if let loginPath {
            environment["PATH"] = loginPath
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        return environment
    }

    public static var current: [String: String] {
        build(base: ProcessInfo.processInfo.environment, loginPath: ShellEnvironment.userLoginPath)
    }
}
