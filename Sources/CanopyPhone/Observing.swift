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

/// Returns once `condition` holds, checking it again each time something it reads changes, or once the task is
/// cancelled.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled {
        let once = ResumeOnce()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.continuation = continuation
                let met = withObservationTracking(condition) {
                    Task { @MainActor in once.resume() }
                }
                if met || Task.isCancelled { once.resume() }
            }
        } onCancel: {
            Task { @MainActor in once.resume() }
        }
    }
}

@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, Never>?

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
