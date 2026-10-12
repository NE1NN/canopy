import Foundation

/// Waits for a condition the code under test reaches on its own, checking every 20 ms.
func eventually(
    timeout: Duration = .seconds(20),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
