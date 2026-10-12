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
