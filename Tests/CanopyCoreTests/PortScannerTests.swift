import Foundation
import Testing

@testable import CanopyCore

/// A TCP socket listening on loopback, closed when released.
final class Listener {
    let fd: Int32
    let port: UInt16

    init(family: Int32 = AF_INET, port: UInt16 = 0) throws {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bound: Int32
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        self.fd = fd
        // sin_port and sin6_port sit at the same offset.
        self.port = UInt16(bigEndian: address.sin6_port)
    }

    deinit {
        close(fd)
    }
}

struct PortScannerTests {
    func mine(_ port: UInt16) -> [ListeningPort] {
        PortScanner.listeningPorts().filter { $0.pid == getpid() && $0.port == port }
    }

    @Test func findsAPortOnceAcrossIPv4AndIPv6() throws {
        let v4 = try Listener(family: AF_INET)
        let v6 = try Listener(family: AF_INET6, port: v4.port)

        let found = mine(v4.port)

        #expect(found.count == 1)
        #expect(found.first?.process == ProcessTable.name(of: getpid()))
        _ = v6
    }

    @Test func connectionsAndClosedListenersAreNotListed() throws {
        var listener: Listener? = try Listener()
        let port = try #require(listener?.port)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)
        // The accepted socket has the listener's port as its local port, but it is not listening.
        let accepted = accept(try #require(listener?.fd), nil, nil)
        defer { close(accepted) }
        #expect(accepted >= 0)
        #expect(mine(port).count == 1)

        listener = nil

        #expect(mine(port).isEmpty)
    }
}

struct ProcessTableTests {
    @Test func readsAChildsParentFolderAndName() throws {
        let dir = try TempDir()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.currentDirectoryURL = URL(fileURLWithPath: dir.path)
        try child.run()
        defer { child.terminate() }

        #expect(ProcessTable.parent(of: child.processIdentifier) == getpid())
        #expect(ProcessTable.folder(of: child.processIdentifier) == dir.path)
        #expect(ProcessTable.name(of: child.processIdentifier) == "sleep")
        #expect(ProcessTable.parent(of: 999_999) == nil)
    }
}
