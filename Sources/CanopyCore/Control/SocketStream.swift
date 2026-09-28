import Foundation

/// Reads and writes a connected socket, waiting in poll(2) and never inside read(2) or write(2).
///
/// Every new process starts with a copy of each socket its parent has open, and closes it as it starts: in the child
/// after fork, or during posix_spawn and exec. If a port scan or `lsof` is reading that copy with proc_pidfdinfo at
/// that moment, the kernel marks the socket itself as draining, in every process that holds it. From then on a read or
/// write that has to wait fails with EBADF at once, even while a reply is on its way. A wait in poll(2) is unaffected.
struct SocketStream {
    let fd: Int32
    /// When to stop waiting. Nil waits as long as it takes.
    let deadline: ContinuousClock.Instant?

    /// Makes `fd` non-blocking.
    init(fd: Int32, deadline: ContinuousClock.Instant?) {
        self.fd = fd
        self.deadline = deadline
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                let code = errno
                guard code == EINTR || code == EAGAIN else { throw ControlClientError.writeFailed(errno: code) }
                guard try wait(for: POLLOUT) else { throw ControlClientError.writeFailed(errno: errno) }
            }
        }
    }

    /// Whatever has arrived, once at least one byte has. Empty when the other side has closed.
    func read() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count >= 0 {
                return Data(chunk[0..<count])
            }
            let code = errno
            guard code == EINTR || code == EAGAIN, try wait(for: POLLIN) else {
                throw ControlClientError.connectionClosed
            }
        }
    }

    /// Returns once `event` may be ready, or false if poll(2) itself failed, with `errno` set.
    private func wait(for event: Int32) throws -> Bool {
        var request = pollfd(fd: fd, events: Int16(event), revents: 0)
        while true {
            var limit: Int32 = -1
            if let deadline {
                let left = deadline - .now
                guard left > .zero else { throw ControlClientError.timedOut }
                limit = Int32(clamping: Int((left / .milliseconds(1)).rounded(.up)))
            }
            let ready = poll(&request, 1, limit)
            if ready > 0 {
                return true
            }
            if ready < 0 && errno != EINTR && errno != EAGAIN {
                return false
            }
        }
    }
}
