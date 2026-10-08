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

    /// Runs `remote` on the host through the master, with each word quoted for the remote shell.
    public func exec(_ remote: [String]) -> [String] {
        [executable, "-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "--", alias] + [
            Self.shellQuoted(remote)
        ]
    }

    /// Runs `remote` on the host in a terminal, through the master, forwarding each remote socket to a local one.
    public func attach(_ remote: [String], forwards: [(remote: String, local: String)] = []) -> [String] {
        var argv = [executable, "-t", "-S", controlPath, "-o", "ControlMaster=no"]
        for forward in forwards {
            argv += ["-R", "\(forward.remote):\(forward.local)"]
        }
        return argv + ["--", alias, Self.shellQuoted(remote)]
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
