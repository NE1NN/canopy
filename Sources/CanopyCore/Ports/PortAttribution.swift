import Darwin

/// A port in a row and every process listening on it: usually one, or a server and the workers sharing its socket.
public struct RowPort: Sendable, Equatable, Hashable {
    public var port: UInt16
    /// Sorted by pid. A remote port's pids are the host's, never to be signalled here.
    public var processes: [ListeningPort]
    /// Set for a port listening on a host.
    public var remote: RemotePort?

    public init(port: UInt16, processes: [ListeningPort], remote: RemotePort? = nil) {
        self.port = port
        self.processes = processes
        self.remote = remote
    }
}

extension RowPort {
    /// The port the Mac reaches it on: its own, or its forward's, nil while a remote port has none.
    public var macPort: UInt16? {
        guard let remote else { return port }
        return remote.local
    }
}

/// A port on a host, and where the Mac reaches it.
public struct RemotePort: Sendable, Equatable, Hashable {
    public var host: String
    /// The Mac port its forward listens on, nil while it has none.
    public var local: UInt16?
    /// Why it has no forward, as ssh said.
    public var error: String?

    public init(host: String, local: UInt16?, error: String?) {
        self.host = host
        self.local = local
        self.error = error
    }
}

/// A row's ports, sorted by number.
public struct PortGroup: Sendable, Equatable {
    public var rowPath: String
    public var ports: [RowPort]

    public init(rowPath: String, ports: [RowPort]) {
        self.rowPath = rowPath
        self.ports = ports
    }
}

public enum PortAttribution {
    /// Gives each port to at most one row: the row whose terminal started its process, else the row whose folder
    /// the process works in, the deepest when row folders nest. Ports of neither are left out. `rows` are row
    /// folders in sidebar order, which the groups keep, and `shells` holds each row's terminal shell pids.
    public static func assign(
        _ ports: [ListeningPort], rows: [String], shells: [String: [pid_t]],
        parent: (pid_t) -> pid_t?, folder: (pid_t) -> String?
    ) -> [PortGroup] {
        var rowOfShell: [pid_t: String] = [:]
        for (row, pids) in shells {
            for pid in pids { rowOfShell[pid] = row }
        }
        var byRow: [String: [ListeningPort]] = [:]
        for port in ports {
            let row =
                startingRow(of: port.pid, rowOfShell: rowOfShell, parent: parent)
                ?? folder(port.pid).flatMap { folder in
                    rows.filter { Paths.isInside(folder, $0) }.max { $0.count < $1.count }
                }
            if let row { byRow[row, default: []].append(port) }
        }
        return rows.compactMap { row in
            byRow[row].map { found in
                let ports = Dictionary(grouping: found, by: \.port).map { port, processes in
                    RowPort(port: port, processes: processes.sorted { $0.pid < $1.pid })
                }
                return PortGroup(rowPath: row, ports: ports.sorted { $0.port < $1.port })
            }
        }
    }

    /// The row of the nearest terminal shell among the process and its ancestors.
    private static func startingRow(
        of pid: pid_t, rowOfShell: [pid_t: String], parent: (pid_t) -> pid_t?
    ) -> String? {
        var current = pid
        var seen: Set<pid_t> = []
        while current > 1, seen.insert(current).inserted {
            if let row = rowOfShell[current] { return row }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }
}
