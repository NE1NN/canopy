import Synchronization

/// A value tests share with closures the code under test keeps.
public final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>

    public init(_ value: Value) {
        self.value = Mutex(value)
    }

    public func withLock<T>(_ body: (inout Value) -> T) -> T {
        value.withLock { body(&$0) }
    }
}

/// Timers a test ends by hand, in the order they started.
public final class ManualTimers: Sendable {
    public init() {}

    private let waiting = Mutex<[CheckedContinuation<Void, Never>?]>([])

    public func wait() async {
        await withCheckedContinuation { continuation in waiting.withLock { $0.append(continuation) } }
    }

    public var count: Int { waiting.withLock { $0.count } }

    public func fire(_ index: Int) {
        let continuation = waiting.withLock { timers -> CheckedContinuation<Void, Never>? in
            defer { timers[index] = nil }
            return timers[index]
        }
        continuation?.resume()
    }

    public func fireAll() {
        for index in 0..<count { fire(index) }
    }
}
