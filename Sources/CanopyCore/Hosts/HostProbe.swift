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
    struct Output: Decodable {
        struct Session: Decodable {
            var name: String
            var busy: Bool
            var foreground: String?
            var folder: String?
            var title: String?
        }

        var sessions: [Session]
    }

    /// `canopy-host probe`'s output, by session name.
    public static func decode(_ data: Data) throws -> [String: SessionActivity] {
        let output = try JSONDecoder().decode(Output.self, from: data)
        return Dictionary(
            output.sessions.map {
                ($0.name, SessionActivity(busy: $0.busy, foreground: $0.foreground, folder: $0.folder, title: $0.title))
            }, uniquingKeysWith: { first, _ in first })
    }

    /// The command that probes this home's tmux server on a host, with this home's helper.
    public static func command(homeID: String) -> [String] {
        [
            "sh", "-c", #"exec python3 "$HOME/.canopy/$0/bin/canopy-host" probe --server "$1""#, homeID,
            HostPaths.tmuxServer(homeID: homeID),
        ]
    }
}
