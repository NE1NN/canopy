import CanopySystem
import Foundation

/// Runs blocking work (socket reads, lock waits) on its own thread. On a Swift concurrency thread it would
/// hold one of the few threads the server needs to answer it, and a small CI machine deadlocks.
public func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await onOwnThread { Result { try work() } }.get()
}

/// Polls until `condition` holds or the timeout passes. Returns whether it held. The timeout is long because a loaded CI
/// runner can take many seconds to start a process, and a condition that holds returns at once anyway.
/// The condition runs on the caller's actor, so main-actor tests can read main-actor state.
public func eventually(
    timeout: Duration = .seconds(20),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
