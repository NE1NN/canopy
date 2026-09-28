import Foundation

/// Runs `work` on a thread of its own, for work that blocks as long as a child process runs. Dispatch lends its global
/// queues a fixed number of threads, 64 on a small Mac. Once they all wait on children, every block queued there waits
/// too, and a timeout counted inside one starts late.
func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.name = "canopy.blocking"
        thread.start()
    }
}
