import Foundation
import Synchronization

/// Marks `fd`'s socket as draining, and returns whether the kernel reports it so within 20 seconds.
///
/// A process that closes its copy of a socket while another process reads that copy with proc_pidfdinfo, as port
/// scans and `lsof` do, makes the kernel drain the socket itself, in every process that holds it. Every new child
/// closes its copies of the parent's sockets as it starts. Here a copy in this process is closed while a thread reads
/// it, which the kernel treats the same way. It blocks, so call it through `offPool`.
func drainSocket(_ fd: Int32) -> Bool {
    // One drain at a time: under a low descriptor limit only one slot is left at the top for the copy.
    drainLock.withLock { _ in drainAlone(fd) }
}

private let drainLock = Mutex(())

private func drainAlone(_ fd: Int32) -> Bool {
    // Copies sit far above the numbers other tests get, which are handed out lowest first, so the reading thread never
    // reads another test's descriptor.
    var limit = rlimit()
    getrlimit(RLIMIT_NOFILE, &limit)
    let floor = Int32(clamping: Int(clamping: min(limit.rlim_cur, 4096)) - 1)
    let target = DrainTarget()
    Thread {
        var info = socket_fdinfo()
        while !target.done.load(ordering: .relaxed) {
            let copy = target.copy.load(ordering: .relaxed)
            if copy >= 0 {
                _ = proc_pidfdinfo(getpid(), copy, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            }
        }
    }.start()
    defer { target.done.store(true, ordering: .relaxed) }
    let deadline = ContinuousClock.now + .seconds(20)
    while !isDraining(fd) {
        guard ContinuousClock.now < deadline else { return false }
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, floor)
        guard copy >= 0 else { return false }
        target.copy.store(copy, ordering: .relaxed)
        usleep(10)
        target.copy.store(-1, ordering: .relaxed)
        close(copy)
    }
    return true
}

func isDraining(_ fd: Int32) -> Bool {
    var info = socket_fdinfo()
    let size = Int32(MemoryLayout<socket_fdinfo>.size)
    return proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &info, size) == size
        && Int32(info.psi.soi_state) & SOI_S_DRAINING != 0
}

private final class DrainTarget: Sendable {
    let copy = Atomic<Int32>(-1)
    let done = Atomic(false)
}
