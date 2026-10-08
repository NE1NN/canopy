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

extension RemoteListeningPort {
    /// Where the master connects on the host: loopback of the family the server listens on, since a server on `::1`
    /// alone refuses `127.0.0.1`. An IPv6 address is in brackets, as `-L` needs it.
    public var target: String {
        switch address {
        case "0.0.0.0", "127.0.0.1": "127.0.0.1"
        case "::", "::1": "[::1]"
        default: address.contains(":") ? "[\(address)]" : address
        }
    }
}

public enum RemotePortAttribution {
    /// Each port's row, by stand-in: the row of the nearest session shell among a process and its ancestors, else
    /// the deepest row whose remote path holds its folder. `sessions` maps a tmux session to its row's stand-in and
    /// `shells` to its shell's pid. A port of two rows goes to its first process's row, and one of none is left out.
    public static func assign(
        _ ports: [RemoteListeningPort], rows: [RemoteRowEntry], sessions: [String: String], shells: [String: Int32]
    ) -> [String: [RemoteListeningPort]] {
        let standIns = Set(rows.map(\.standIn))
        var rowOfShell: [Int32: String] = [:]
        for (session, pid) in shells {
            if let standIn = sessions[session], standIns.contains(standIn) { rowOfShell[pid] = standIn }
        }
        let roots = rows.compactMap { row in RelayPaths.components(row.path).map { (row.standIn, $0) } }
        var byRow: [String: [RemoteListeningPort]] = [:]
        for port in ports {
            let row = port.processes.lazy.compactMap { process in
                ([process.pid] + process.ancestors).lazy.compactMap { rowOfShell[$0] }.first
                    ?? process.folder.flatMap { deepestRow(holding: $0, roots: roots) }
            }.first
            if let row { byRow[row, default: []].append(port) }
        }
        return byRow.mapValues { $0.sorted { $0.port < $1.port } }
    }

    private static func deepestRow(holding folder: String, roots: [(standIn: String, components: [Substring])])
        -> String?
    {
        guard let components = RelayPaths.components(folder) else { return nil }
        return
            roots
            .filter { !$0.components.isEmpty && components.starts(with: $0.components) }
            .max { $0.components.count < $1.components.count }?.standIn
    }
}

public enum LocalPortChooser {
    /// `remote` itself when it is free and no other forward holds it, else the next such port above it.
    public static func port(for remote: UInt16, taken: Set<UInt16>, isFree: (UInt16) -> Bool) -> UInt16? {
        (remote...UInt16.max).first { !taken.contains($0) && isFree($0) }
    }

    /// Nothing listens on the port on either loopback or either wildcard. ssh's forward succeeds on one family alone,
    /// which would leave a local server on the other answering some of `localhost`. Each bind sets SO_REUSEADDR, as ssh
    /// does, so connections a closed forward left in TIME_WAIT do not count, while a listener on that address still
    /// does; a specific address then binds beside a wildcard listener, hence the wildcards too. A Mac without IPv6
    /// needs only the IPv4 ones.
    public static func isFree(_ port: UInt16) -> Bool {
        var v4 = sockaddr_in()
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        v4.sin_family = sa_family_t(AF_INET)
        v4.sin_port = port.bigEndian
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = port.bigEndian
        for address in [INADDR_LOOPBACK, INADDR_ANY] {
            v4.sin_addr.s_addr = address.bigEndian
            guard canBind(AF_INET, &v4) == 0 else { return false }
        }
        for address in [in6addr_loopback, in6addr_any] {
            v6.sin6_addr = address
            let bound = canBind(AF_INET6, &v6)
            guard bound == 0 || bound == EADDRNOTAVAIL || bound == EAFNOSUPPORT else { return false }
        }
        return true
    }

    /// 0 when a socket of `family` binds `address`, else the error. The socket closes at once.
    private static func canBind<Address>(_ family: Int32, _ address: inout Address) -> Int32 {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Otherwise `::` would take IPv4 too, and fail beside any IPv4 listener rather than only beside an IPv6 one.
        if family == AF_INET6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
        return bound == 0 ? 0 : errno
    }
}
