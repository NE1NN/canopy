import Foundation

/// Settings from CANOPY_HOME/config.json. Missing keys and a missing or unreadable file use the defaults.
public struct GlobalConfig: Codable, Sendable, Equatable {
    /// The add rule starts a new line of panes rather than make any narrower than this many columns.
    public var minPaneColumns: Int

    public init(minPaneColumns: Int = 80) {
        self.minPaneColumns = minPaneColumns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minPaneColumns = max(try container.decodeIfPresent(Int.self, forKey: .minPaneColumns) ?? 80, 20)
    }

    public static func load(from url: URL) -> GlobalConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(GlobalConfig.self, from: data)
        else { return GlobalConfig() }
        return config
    }
}
