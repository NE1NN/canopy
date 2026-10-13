import CanopyTestSupport
import Foundation
import Synchronization
import Testing

@testable import CanopySystem

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

struct UnixSocketTests {
    /// A short folder for sockets, since a Unix socket's path must fit in about a hundred bytes.
    final class SocketFolder: Sendable {
        let path: String

        init() throws {
            path = "/tmp/canopy-unix-\(getuid())-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        func socket(_ name: String = "s.sock") -> String { path + "/" + name }

        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Answers each line with the line reversed, until the client hangs up.
    static func reverser(_ connection: UnixConnection) {
        while let line = try? connection.readLine(deadline: nil) {
            try? connection.write(Data(line.reversed()) + Data([0x0A]), deadline: .now + .seconds(5))
        }
        connection.close()
    }

    static func bindWithoutListening(_ path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        #if canImport(Glibc)
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound != 0 { throw UnixSocketError.system("bind", errno: errno) }
    }

    @Test func echoesLinesBothWays() async throws {
        let folder = try SocketFolder()
        let listener = try UnixListener(path: folder.socket(), accept: Self.reverser)
        defer { listener.close() }
        let reply = try await offPool {
            let client = try UnixConnection.connect(path: folder.socket())
            defer { client.close() }
            try client.write(Data("abc\ndef\n".utf8), deadline: .now + .seconds(5))
            let first = try client.readLine(deadline: .now + .seconds(5))
            let second = try client.readLine(deadline: .now + .seconds(5))
            return [first, second].map { $0.map { String(decoding: $0, as: UTF8.self) } }
        }
        #expect(reply == ["cba", "fed"])
    }

    @Test func servesManyConnectionsAtOnce() async throws {
        let folder = try SocketFolder()
        let listener = try UnixListener(path: folder.socket(), accept: Self.reverser)
        defer { listener.close() }
        let replies = try await withThrowingTaskGroup(of: String?.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await offPool {
                        let client = try UnixConnection.connect(path: folder.socket())
                        defer { client.close() }
                        try client.write(Data("\(index)x\n".utf8), deadline: .now + .seconds(10))
                        return try client.readLine(deadline: .now + .seconds(10)).map {
                            String(decoding: $0, as: UTF8.self)
                        }
                    }
                }
            }
            return try await group.reduce(into: Set<String?>()) { $0.insert($1) }
        }
        #expect(replies == Set((0..<20).map { "x" + String(String($0).reversed()) }))
    }

    @Test func theFolderAndSocketAreTheUsersAlone() throws {
        let folder = try SocketFolder()
        let inner = folder.path + "/box"
        let listener = try UnixListener(path: inner + "/s.sock") { $0.close() }
        defer { listener.close() }
        var info = stat()
        #expect(lstat(inner, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(lstat(inner + "/s.sock", &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func aFolderOfAnothersIsRefused() throws {
        // A folder this user cannot make private: the root folder, owned by root, unless the tests run as root.
        guard getuid() != 0 else { return }
        #expect(throws: UnixSocketError.folderNotPrivate("/")) {
            try UnixListener(path: "/s-\(UUID().uuidString.prefix(6)).sock") { $0.close() }
        }
    }

    @Test func aStaleSocketFileIsReplaced() async throws {
        let folder = try SocketFolder()
        // A socket file nothing listens on, as a daemon that was killed leaves. Bound and never listening, so no
        // child another test spawns meanwhile can hold a listening copy of it.
        try Self.bindWithoutListening(folder.socket())
        #expect(FileManager.default.fileExists(atPath: folder.socket()))
        let listener = try UnixListener(path: folder.socket(), accept: Self.reverser)
        defer { listener.close() }
        let reply = try await offPool {
            let client = try UnixConnection.connect(path: folder.socket())
            defer { client.close() }
            try client.write(Data("ok\n".utf8), deadline: .now + .seconds(5))
            return try client.readLine(deadline: .now + .seconds(5))
        }
        #expect(reply == Data("ko".utf8))
    }

    @Test func aLiveServerIsNotReplaced() throws {
        let folder = try SocketFolder()
        let listener = try UnixListener(path: folder.socket()) { $0.close() }
        defer { listener.close() }
        #expect(throws: UnixSocketError.alreadyRunning(folder.socket())) {
            try UnixListener(path: folder.socket()) { $0.close() }
        }
    }

    @Test func aTooLongPathFails() throws {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: UnixSocketError.pathTooLong(path)) { try UnixListener(path: path) { $0.close() } }
        #expect(throws: UnixSocketError.pathTooLong(path)) { try UnixConnection.connect(path: path) }
    }

    @Test func connectingToNothingFails() throws {
        let folder = try SocketFolder()
        #expect(throws: UnixSocketError.self) { try UnixConnection.connect(path: folder.socket()) }
    }

    @Test func aReadPastItsDeadlineTimesOut() async throws {
        let folder = try SocketFolder()
        let held = Mutex<[UnixConnection]>([])
        let listener = try UnixListener(path: folder.socket()) { connection in held.withLock { $0.append(connection) } }
        defer {
            listener.close()
            held.withLock { $0.forEach { $0.close() } }
        }
        let started = ContinuousClock.now
        let outcome = try await offPool {
            let client = try UnixConnection.connect(path: folder.socket())
            defer { client.close() }
            return Result { try client.readLine(deadline: .now + .milliseconds(200)) }
        }
        #expect(throws: UnixSocketError.timedOut) { try outcome.get() }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aLineAfterThePeerClosesIsNil() async throws {
        let folder = try SocketFolder()
        let listener = try UnixListener(path: folder.socket()) { connection in
            try? connection.write(Data("last".utf8), deadline: .now + .seconds(5))
            connection.close()
        }
        defer { listener.close() }
        let lines = try await offPool {
            let client = try UnixConnection.connect(path: folder.socket())
            defer { client.close() }
            // A last line without its newline still counts, then the end.
            return [
                try client.readLine(deadline: .now + .seconds(5)), try client.readLine(deadline: .now + .seconds(5)),
            ]
        }
        #expect(lines == [Data("last".utf8), nil])
    }

    @Test func writingToAClosedPeerFailsWithoutSignal() async throws {
        let folder = try SocketFolder()
        let listener = try UnixListener(path: folder.socket()) { $0.close() }
        defer { listener.close() }
        let failed = try await offPool {
            let client = try UnixConnection.connect(path: folder.socket())
            defer { client.close() }
            _ = try? client.readLine(deadline: .now + .seconds(5))
            let big = Data(repeating: 0x61, count: 1 << 20)
            for _ in 0..<10 {
                do {
                    try client.write(big, deadline: .now + .seconds(5))
                } catch {
                    return true
                }
            }
            return false
        }
        #expect(failed)
    }

    @Test func hangingUpIsSeen() async throws {
        let folder = try SocketFolder()
        let seen = Mutex<Bool?>(nil)
        let listener = try UnixListener(path: folder.socket()) { connection in
            seen.withLock { $0 = connection.hungUp(within: .seconds(10)) }
            connection.close()
        }
        defer { listener.close() }
        try await offPool {
            let client = try UnixConnection.connect(path: folder.socket())
            usleep(100_000)
            client.close()
        }
        #expect(await eventually { seen.withLock { $0 } == true })
    }

    @Test func closingStopsAcceptingAndRemovesTheFile() throws {
        let folder = try SocketFolder()
        let listener = try UnixListener(path: folder.socket()) { $0.close() }
        listener.close()
        #expect(!FileManager.default.fileExists(atPath: folder.socket()))
        #expect(throws: UnixSocketError.self) { try UnixConnection.connect(path: folder.socket()) }
        listener.close()
    }
}
