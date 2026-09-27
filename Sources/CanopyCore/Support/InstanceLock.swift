import Foundation

public enum InstanceLockError: Error, Equatable {
    case heldElsewhere(String)
    case cannotOpen(String, errno: Int32)
}

/// An exclusive flock(2) on a file, held until the value is released or the process exits.
public final class InstanceLock: Sendable {
    public let path: String
    private let descriptor: Int32

    public init(path: String) throws {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw InstanceLockError.cannotOpen(path, errno: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw InstanceLockError.heldElsewhere(path)
        }
        self.path = path
        self.descriptor = descriptor
    }

    /// Retries until the lock is free or `timeout` passes.
    public static func waiting(path: String, timeout: TimeInterval) throws -> InstanceLock {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try InstanceLock(path: path)
            } catch InstanceLockError.heldElsewhere where Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
