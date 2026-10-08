import Darwin

/// This Mac's listening ports, their processes, and how to stop them. Tests pass a stand-in, so they can tell nothing
/// was signalled here.
public struct LocalPorts: Sendable {
    public var scan: @Sendable () -> [ListeningPort]
    public var parent: @Sendable (pid_t) -> pid_t?
    public var folder: @Sendable (pid_t) -> String?
    public var stop: @Sendable ([ListeningPort]) async -> PortStopper.Outcome

    public init(
        scan: @escaping @Sendable () -> [ListeningPort],
        parent: @escaping @Sendable (pid_t) -> pid_t?,
        folder: @escaping @Sendable (pid_t) -> String?,
        stop: @escaping @Sendable ([ListeningPort]) async -> PortStopper.Outcome
    ) {
        self.scan = scan
        self.parent = parent
        self.folder = folder
        self.stop = stop
    }

    public static let system = LocalPorts(
        scan: { PortScanner.listeningPorts() }, parent: { ProcessTable.parent(of: $0) },
        folder: { ProcessTable.folder(of: $0) }, stop: { await PortStopper().stop($0) })
}

/// What stopping some ports signals, split by where their pids mean something: this Mac's processes, for
/// `PortStopper`, and each host's, for `canopy-host stop-port` there. A remote port's pids are the host's, so they
/// only ever land in `remote`.
public struct PortStops: Sendable, Equatable {
    public struct Remote: Sendable, Equatable {
        public var host: String
        /// The port on the host, which `stop-port` checks each pid still listens on.
        public var port: UInt16
        public var pids: [Int32]
    }

    public var local: [ListeningPort]
    /// In the order the ports came.
    public var remote: [Remote]

    public init(_ ports: [RowPort]) {
        local = []
        remote = []
        for port in ports {
            if let host = port.remote?.host {
                remote.append(Remote(host: host, port: port.port, pids: port.processes.map(\.pid)))
            } else {
                local += port.processes
            }
        }
    }

    /// The ports `ports stop <number>` means, with their rows: those listening on that number, or else the remote
    /// ones whose forward holds it on the Mac, so a port on a host is found by either number but never shadows a port
    /// that has the number as its own.
    public static func matching(_ number: UInt16, in groups: [PortGroup]) -> [(rowPath: String, port: RowPort)] {
        let all = groups.flatMap { group in group.ports.map { (rowPath: group.rowPath, port: $0) } }
        let own = all.filter { $0.port.port == number }
        return own.isEmpty ? all.filter { $0.port.remote != nil && $0.port.macPort == number } : own
    }
}

extension [PortGroup] {
    /// The other ports a port's processes listen on, which stopping them closes too. Pids are compared only with
    /// those of the same host, or of this Mac.
    public func otherPorts(of port: RowPort) -> [UInt16] {
        let host = port.remote?.host
        let pids = Set(port.processes.map(\.pid))
        let others = flatMap(\.ports).filter { other in
            other.port != port.port && other.remote?.host == host && other.processes.contains { pids.contains($0.pid) }
        }
        return Set(others.map(\.port)).sorted()
    }
}
