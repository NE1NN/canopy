import Foundation

public enum HostMethod {
    public static let add = "host.add"
    public static let list = "host.list"
    public static let remove = "host.remove"
}

public struct HostAddParams: Codable, Sendable {
    public var alias: String
    /// Registered repos' names or paths, each to its clone on the host, which may start with `~/`.
    public var repos: [String: String]
    public var wake: String?
    public var idleDetachMinutes: Int?

    public init(alias: String, repos: [String: String], wake: String? = nil, idleDetachMinutes: Int? = nil) {
        self.alias = alias
        self.repos = repos
        self.wake = wake
        self.idleDetachMinutes = idleDetachMinutes
    }
}

public struct HostRemoveParams: Codable, Sendable {
    public var alias: String

    public init(alias: String) {
        self.alias = alias
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public var alias: String
    public var state: HostState
    public var repos: [String: String]
    public var wake: String?
    public var idleDetachMinutes: Int
    /// The host's remote rows, by stand-in path.
    public var rows: [String]
    /// Panes open in the host's rows, which the app fills in.
    public var panes: [String]
    /// Why the host could not be reached, after it failed to.
    public var error: String?
    /// This home's tmux server on the host, as `tmux -L` names it.
    public var tmuxServer: String
    /// What `host add` found that may need the author, such as a low MaxSessions.
    public var warnings: [String]

    public init(
        alias: String, state: HostState, repos: [String: String], wake: String?, idleDetachMinutes: Int,
        rows: [String], tmuxServer: String, panes: [String] = [], error: String? = nil, warnings: [String] = []
    ) {
        self.tmuxServer = tmuxServer
        self.warnings = warnings
        self.alias = alias
        self.state = state
        self.repos = repos
        self.wake = wake
        self.idleDetachMinutes = idleDetachMinutes
        self.rows = rows
        self.panes = panes
        self.error = error
    }
}

/// `host.list`: every host config.json names, and why any it names could not be read.
public struct HostListing: Codable, Sendable, Equatable {
    public var hosts: [HostInfo]
    public var warnings: [String]

    public init(hosts: [HostInfo], warnings: [String]) {
        self.hosts = hosts
        self.warnings = warnings
    }
}
