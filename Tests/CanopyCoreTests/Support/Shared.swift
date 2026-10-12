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

/// Timers a test ends by hand, in the order they started.
final class ManualTimers: Sendable {
    private let waiting = Mutex<[CheckedContinuation<Void, Never>?]>([])

    func wait() async {
        await withCheckedContinuation { continuation in waiting.withLock { $0.append(continuation) } }
    }

    var count: Int { waiting.withLock { $0.count } }

    func fire(_ index: Int) {
        let continuation = waiting.withLock { timers -> CheckedContinuation<Void, Never>? in
            defer { timers[index] = nil }
            return timers[index]
        }
        continuation?.resume()
    }

    func fireAll() {
        for index in 0..<count { fire(index) }
    }
}
