import Foundation
import Testing

@testable import CanopyCore

struct InstanceLockTests {
    @Test func secondLockOnTheSamePathIsRefused() throws {
        let dir = try TempDir()
        let first = try InstanceLock(path: dir.sub("app.lock"))

        #expect(throws: InstanceLockError.heldElsewhere(dir.sub("app.lock"))) {
            try InstanceLock(path: dir.sub("app.lock"))
        }
        _ = first
    }

    @Test func releasedLockCanBeTakenAgain() throws {
        let dir = try TempDir()
        do {
            _ = try InstanceLock(path: dir.sub("app.lock"))
        }
        _ = try InstanceLock(path: dir.sub("app.lock"))
    }

    @Test func waitingTakesTheLockOnceItIsReleased() async throws {
        let dir = try TempDir()
        let path = dir.sub("launch.lock")
        let holder = Task {
            let first = try InstanceLock(path: path)
            try await Task.sleep(for: .milliseconds(300))
            _ = first
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(throws: InstanceLockError.heldElsewhere(path)) { try InstanceLock(path: path) }

        _ = try await offPool { try InstanceLock.waiting(path: path, timeout: 3) }
        try await holder.value
    }

    @Test func waitingGivesUpAfterTheTimeout() async throws {
        let dir = try TempDir()
        let path = dir.sub("launch.lock")
        let first = try InstanceLock(path: path)

        await #expect(throws: InstanceLockError.heldElsewhere(path)) {
            try await offPool { try InstanceLock.waiting(path: path, timeout: 0.3) }
        }
        _ = first
    }
}
