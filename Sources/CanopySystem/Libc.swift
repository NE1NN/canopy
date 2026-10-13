import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Glibc)
    let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
    let streamSocket = SOCK_STREAM
#endif

// Linux marks a descriptor close-on-exec as it is made, so a child spawned on another thread at that moment never
// inherits it. Darwin's spawns close every descriptor anyway, with POSIX_SPAWN_CLOEXEC_DEFAULT.
#if canImport(Glibc)
    let closeOnExecSocket = Int32(SOCK_CLOEXEC.rawValue)
#elseif canImport(Musl)
    let closeOnExecSocket = SOCK_CLOEXEC
#else
    let closeOnExecSocket: Int32 = 0
#endif

func sendBytes(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Foundation.send(fd, bytes, count, 0)
    #else
        Foundation.send(fd, bytes, count, Int32(MSG_NOSIGNAL))
    #endif
}

func makeNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
}

func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) throws {
    var value = value
    guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw TCPError.system("setsockopt", errno: errno)
    }
}
