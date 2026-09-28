import Darwin

/// A TCP port a process listens on.
public struct ListeningPort: Sendable, Equatable, Hashable, Codable {
    public var port: UInt16
    public var pid: pid_t
    public var process: String

    public init(port: UInt16, pid: pid_t, process: String) {
        self.port = port
        self.pid = pid
        self.process = process
    }
}

public enum PortScanner {
    /// Every TCP port in the listening state held by one user's processes, read with libproc rather than `lsof`.
    /// A process listening on both IPv4 and IPv6 for a port counts once. Makes a few system calls per process, so
    /// call it off the Swift concurrency pool.
    public static func listeningPorts(uid: uid_t = getuid()) -> [ListeningPort] {
        var found = Set<ListeningPort>()
        for pid in processes(of: uid) {
            for port in listeningPorts(of: pid) {
                found.insert(ListeningPort(port: port, pid: pid, process: ProcessTable.name(of: pid) ?? "pid \(pid)"))
            }
        }
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func processes(of uid: uid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard bytes > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(
            UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func listeningPorts(of pid: pid_t) -> Set<UInt16> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return [] }
        var ports = Set<UInt16>()
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                info.psi.soi_kind == SOCKINFO_TCP,
                info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let port = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            ports.insert(UInt16(bigEndian: port))
        }
        return ports
    }
}
