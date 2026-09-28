import Foundation

/// Settings from CANOPY_HOME/config.json. Missing keys and a missing or unreadable file use the defaults.
public struct GlobalConfig: Codable, Sendable, Equatable {
    /// The add rule starts a new line of panes rather than make any narrower than this many columns.
    public var minPaneColumns: Int
    /// Whether commands run in zsh terminals go into the activity log. Commands can contain secrets.
    public var logCommands: Bool
    /// Whether a sound plays when an agent finishes or needs the author.
    public var agentSounds: Bool
    /// A system sound's name, such as Glass, or a sound file's path. Empty for silence.
    public var agentDoneSound: String
    public var agentWaitingSound: String

    public init(
        minPaneColumns: Int = 80, logCommands: Bool = true, agentSounds: Bool = true,
        agentDoneSound: String = AgentSound.fallback(for: .done),
        agentWaitingSound: String = AgentSound.fallback(for: .waiting)
    ) {
        self.minPaneColumns = minPaneColumns
        self.logCommands = logCommands
        self.agentSounds = agentSounds
        self.agentDoneSound = agentDoneSound
        self.agentWaitingSound = agentWaitingSound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minPaneColumns = max(try container.decodeIfPresent(Int.self, forKey: .minPaneColumns) ?? 80, 20)
        logCommands = try container.decodeIfPresent(Bool.self, forKey: .logCommands) ?? true
        agentSounds = try container.decodeIfPresent(Bool.self, forKey: .agentSounds) ?? true
        agentDoneSound =
            try container.decodeIfPresent(String.self, forKey: .agentDoneSound) ?? AgentSound.fallback(for: .done)
        agentWaitingSound =
            try container.decodeIfPresent(String.self, forKey: .agentWaitingSound)
            ?? AgentSound.fallback(for: .waiting)
    }

    public static func load(from url: URL) -> GlobalConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(GlobalConfig.self, from: data)
        else { return GlobalConfig() }
        return config
    }
}

/// The sound that plays when a pane's agent becomes done or waiting.
public enum AgentSound {
    /// A system sound's name or a file's path, or nil for no sound.
    public static func sound(for state: AgentState, in config: GlobalConfig) -> String? {
        guard config.agentSounds else { return nil }
        let sound =
            switch state {
            case .done: config.agentDoneSound
            case .waiting: config.agentWaitingSound
            case .working, .none: ""
            }
        return sound.isEmpty ? nil : sound
    }

    /// What plays by default, and in place of a sound that cannot be found.
    public static func fallback(for state: AgentState) -> String {
        state == .waiting ? "Ping" : "Glass"
    }
}
