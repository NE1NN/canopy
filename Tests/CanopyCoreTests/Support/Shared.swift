import Synchronization

/// A value tests share with closures the code under test keeps.
final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>

    init(_ value: Value) {
        self.value = Mutex(value)
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        value.withLock { body(&$0) }
    }
}
