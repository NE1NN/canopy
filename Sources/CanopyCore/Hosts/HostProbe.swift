import Foundation

/// What a host says one of Canopy's tmux sessions is doing.
public struct SessionActivity: Codable, Sendable, Equatable {
    /// A program other than the shell holds the session's terminal.
    public var busy: Bool
    public var foreground: String?
    public var folder: String?
    public var title: String?

    public init(busy: Bool, foreground: String? = nil, folder: String? = nil, title: String? = nil) {
        self.busy = busy
        self.foreground = foreground
        self.folder = folder
        self.title = title
    }
}

public enum HostProbe {
    /// What one probe of a host found.
    public struct Report: Sendable, Equatable {
        /// By session name.
        public var sessions: [String: SessionActivity]
        /// The panes with a hook report the host kept for this home.
        public var pending: [String]
        /// Each session's shell's pid on the host, by session name.
        public var shells: [String: Int32] = [:]
        /// Only when the probe asked for them, and nil when the host could not list them, which says nothing about
        /// what listens there.
        public var ports: [RemoteListeningPort]? = nil
    }

    struct Output: Decodable {
        struct Session: Decodable {
            var name: String
            var pid: Int32?
            var busy: Bool
            var foreground: String?
            var folder: String?
            var title: String?
        }

        var sessions: [Session]
        /// Missing from helpers that do not list them.
        var pending: [String]?
        var ports: [RemoteListeningPort]?
    }

    /// `canopy-host probe`'s output.
    public static func decode(_ data: Data) throws -> Report {
        let output = try JSONDecoder().decode(Output.self, from: data)
        let sessions = Dictionary(
            output.sessions.map {
                ($0.name, SessionActivity(busy: $0.busy, foreground: $0.foreground, folder: $0.folder, title: $0.title))
            }, uniquingKeysWith: { first, _ in first })
        let shells = Dictionary(
            output.sessions.compactMap { session in session.pid.map { (session.name, $0) } },
            uniquingKeysWith: { first, _ in first })
        return Report(sessions: sessions, pending: output.pending ?? [], shells: shells, ports: output.ports)
    }

    /// The command that probes this home's tmux server and kept reports on a host, with this home's helper, and with
    /// `ports`, the host's listening ports.
    public static func command(homeID: String, ports: Bool = false) -> [String] {
        let probe = #"exec python3 "$HOME/.canopy/$0/bin/canopy-host" probe --server "$1" --home-id "$0""#
        return ["sh", "-c", probe + (ports ? " --ports" : ""), homeID, HostPaths.tmuxServer(homeID: homeID)]
    }
}
