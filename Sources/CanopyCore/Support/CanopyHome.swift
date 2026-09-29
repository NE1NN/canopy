import Foundation

public enum CanopyVersion {
    public static let current = "0.1.0"
}

public struct CanopyHome: Sendable, Equatable {
    public static let environmentKey = "CANOPY_HOME"
    public static let infoPlistKey = "CanopyHome"
    public static let defaultPath = "~/.canopy"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(path: String) {
        self.root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Order: the CANOPY_HOME variable, then the app bundle's CanopyHome key, then ~/.canopy.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHome: String? = nil
    ) -> CanopyHome {
        if let path = environment[environmentKey], !path.isEmpty {
            return CanopyHome(path: path)
        }
        if let bundleHome, !bundleHome.isEmpty {
            return CanopyHome(path: bundleHome)
        }
        return CanopyHome(path: defaultPath)
    }

    public var stateFile: URL { root.appending(path: "state.json") }
    public var configFile: URL { root.appending(path: "config.json") }
    public var worktreesRoot: URL { root.appending(path: "worktrees") }
    /// Repos cloned by Canopy, at repos/<owner>/<name>.
    public var reposRoot: URL { root.appending(path: "repos") }
    /// Plugin rows' folders, at plugins/<plugin>/<folder>.
    public var pluginsRoot: URL { root.appending(path: "plugins") }
    /// One JSON Lines file of activity events per local day.
    public var activityFolder: URL { root.appending(path: "activity") }
    /// ZDOTDIR for zsh terminals while command logging is on.
    public var zshShimFolder: URL { root.appending(path: "shell/zsh") }
    public var socketPath: String { root.appending(path: "canopy.sock").path }
    /// Held by the one app instance that owns this home.
    public var appLockPath: String { root.appending(path: "app.lock").path }
    /// Held by a CLI while it launches the app, so parallel calls launch it once.
    public var launchLockPath: String { root.appending(path: "launch.lock").path }

    public func ensureExists() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try manager.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
    }
}
