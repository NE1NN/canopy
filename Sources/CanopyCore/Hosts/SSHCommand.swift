import Foundation

/// The ssh command lines Canopy runs for a host. One master holds the connection, and everything else goes through it.
public struct SSHCommand: Sendable, Equatable {
    public var executable: String
    public var controlPath: String
    /// The host as ~/.ssh/config names it.
    public var alias: String

    public init(executable: String, controlPath: String, alias: String) {
        self.executable = executable
        self.controlPath = controlPath
        self.alias = alias
    }

    /// The real ssh, unless CANOPY_SSH names a stand-in, which only tests and end-to-end runs set.
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["CANOPY_SSH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin/ssh"
    }

    /// Holds the connection until Canopy stops it. Keepalives notice a dead network within about 45 seconds, and
    /// BatchMode makes a login that needs a password fail rather than wait for one nobody can type.
    public func master() -> [String] {
        [
            executable, "-M", "-N", "-S", controlPath, "-o", "ControlPersist=no", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes", "--", alias,
        ]
    }

    /// Options for everything that goes through the master. ssh connects on its own when the master is gone or
    /// refuses a session, as past sshd's MaxSessions, and such a connection would hold the host awake out of
    /// Canopy's reach. A proxy that fails at once stops that, and is only used when the master is not.
    var throughMaster: [String] {
        ["-S", controlPath, "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes"]
    }

    /// Runs `remote` on the host through the master, with each word quoted for the remote shell.
    public func exec(_ remote: [String]) -> [String] {
        [executable] + throughMaster + ["--", alias, Self.shellQuoted(remote)]
    }

    /// Runs `remote` on the host in a terminal, through the master.
    /// ssh's notes, such as "Shared connection to … closed", stay out of the pane, which says what happened itself.
    public func attach(_ remote: [String]) -> [String] {
        [executable, "-t"] + throughMaster + ["-o", "LogLevel=ERROR", "--", alias, Self.shellQuoted(remote)]
    }

    /// Asks the master to forward the Unix socket `remote` on the host to `local` here, for as long as it runs.
    public func forward(remote: String, local: String) -> [String] {
        control("forward", ["-R", "\(remote):\(local)"])
    }

    /// Prints the settings ssh would use for the host, from ~/.ssh/config, without connecting.
    public func config() -> [String] {
        [executable, "-G", alias]
    }

    /// Asks the master to do something, such as `check` or `exit`.
    public func control(_ operation: String, _ arguments: [String] = []) -> [String] {
        [executable, "-S", controlPath, "-O", operation] + arguments + [alias]
    }

    /// Words joined for a POSIX shell, each in single quotes, so the host's shell sees them as they are.
    public static func shellQuoted(_ words: [String]) -> String {
        words.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }.joined(separator: " ")
    }
}
