import Foundation

/// Settings from CANOPY_HOME/config.json. Missing keys and a missing or unreadable file use the defaults.
public struct GlobalConfig: Codable, Sendable, Equatable {
    /// The add rule starts a new line of panes rather than make any narrower than this many columns.
    public var minPaneColumns: Int
    /// Whether commands run in zsh terminals go into the activity log. Commands can contain secrets.
    public var logCommands: Bool

    public init(minPaneColumns: Int = 80, logCommands: Bool = true) {
        self.minPaneColumns = minPaneColumns
        self.logCommands = logCommands
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minPaneColumns = max(try container.decodeIfPresent(Int.self, forKey: .minPaneColumns) ?? 80, 20)
        logCommands = try container.decodeIfPresent(Bool.self, forKey: .logCommands) ?? true
    }

    public static func load(from url: URL) -> GlobalConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(GlobalConfig.self, from: data)
        else { return GlobalConfig() }
        return config
    }
}
