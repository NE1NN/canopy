import Observation

/// Calls `changed` with the value now, then again each time something it reads changes, for as long as `isActive`.
@MainActor
func observe<Value: Equatable>(
    _ value: @escaping @MainActor () -> Value, while isActive: @escaping @MainActor () -> Bool,
    _ changed: @escaping @MainActor (Value) -> Void
) {
    guard isActive() else { return }
    let current = withObservationTracking(value) {
        Task { @MainActor in observe(value, while: isActive, changed) }
    }
    changed(current)
}

/// Returns once `condition` holds, checking it again each time something it reads changes.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let met = withObservationTracking(condition) {
                Task { @MainActor in once.resume() }
            }
            if met { once.resume() }
        }
    }
}

@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
