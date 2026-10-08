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
    /// On a host, its port there.
    public var port: Int
    /// On a host, the host's pid, which means nothing on this Mac.
    public var pid: Int32
    public var process: String
    /// The host a remote row's port listens on. Left out for this Mac's ports.
    public var host: String? = nil
    /// The Mac port a remote port is forwarded to, which `localhost` opens. Left out while it has none.
    public var localPort: Int? = nil
    /// Why a remote port has no forward, as ssh said.
    public var forwardError: String? = nil
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
    /// The processes signalled. A remote port's pids from the last probe that no longer listen are left out.
    public var stopped: [PortInfo]
    /// Processes that ignored SIGTERM and were killed, on this Mac and on hosts.
    public var killed: [PortProcess]
}

/// A process on this Mac, or on a host, whose pids are a different machine's.
public struct PortProcess: Codable, Sendable, Hashable {
    public var pid: Int32
    /// Left out for this Mac's processes.
    public var host: String?

    public init(pid: Int32, host: String?) {
        self.pid = pid
        self.host = host
    }
}
