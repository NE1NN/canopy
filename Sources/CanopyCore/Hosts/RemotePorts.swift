import Foundation

/// A TCP port listening on a host, as `canopy-host probe --ports` reports it.
public struct RemoteListeningPort: Sendable, Equatable, Hashable, Codable {
    public var port: UInt16
    /// Of the addresses it listens on, the one loopback reaches best: a wildcard or IPv4 loopback before IPv6.
    public var address: String
    public var processes: [RemoteProcess]

    public init(port: UInt16, address: String, processes: [RemoteProcess]) {
        self.port = port
        self.address = address
        self.processes = processes
    }
}

/// A process on a host. Its pid means nothing on the Mac.
public struct RemoteProcess: Sendable, Equatable, Hashable, Codable {
    public var pid: Int32
    public var name: String
    /// Its parent first, up to the host's first process.
    public var ancestors: [Int32]
    public var folder: String?

    public init(pid: Int32, name: String, ancestors: [Int32], folder: String?) {
        self.pid = pid
        self.name = name
        self.ancestors = ancestors
        self.folder = folder
    }
}
