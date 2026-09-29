public enum PortMethod {
    public static let list = "ports.list"
    public static let stop = "ports.stop"
}

/// One port as `canopy ports` shows it.
public struct PortInfo: Codable, Sendable, Equatable {
    /// Left out for a plugin's row, which names its plugin instead.
    public var repo: String?
    public var plugin: String?
    public var row: String
    public var rowPath: String
    public var port: Int
    public var pid: Int32
    public var process: String
}

public struct PortsListParams: Codable, Sendable {
    public var target: TargetHint
    /// Every row's ports, as when no row resolves.
    public var all: Bool

    public init(target: TargetHint = TargetHint(), all: Bool = false) {
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct PortsStopParams: Codable, Sendable {
    public var port: Int
    /// Limits the stop to the port in this row. Every row's with `all`, or when no row resolves.
    public var target: TargetHint
    public var all: Bool

    public init(port: Int, target: TargetHint = TargetHint(), all: Bool = false) {
        self.port = port
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(Int.self, forKey: .port)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct PortsStopResult: Codable, Sendable {
    public var port: Int
    public var stopped: [PortInfo]
    /// Processes that ignored SIGTERM and were killed.
    public var killed: [Int32]
}
