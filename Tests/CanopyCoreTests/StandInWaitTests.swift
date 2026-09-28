import Foundation
import Testing

@testable import CanopyCore

/// A stand-in script that waits for its test to create a file must not poll forever once that test has died.
struct StandInWaitTests {
    func run(_ script: String) async throws -> SubprocessResult {
        try await offPool {
            try Subprocess.run("/bin/bash", ["-c", script], environment: [:], directory: nil, timeout: .seconds(20))
        }
    }

    @Test func aStandInGivesUpWaitingOnceTheLimitPasses() async throws {
        let dir = try TempDir()
        let result = try await run(Fixture.waitForFile(dir.sub("never"), limit: .seconds(1)) + "\necho went-on")

        #expect(!result.timedOut)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
    }

    @Test func aStandInGoesOnOnceItsFileExists() async throws {
        let dir = try TempDir()
        FileManager.default.createFile(atPath: dir.sub("go"), contents: nil)
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await run(Fixture.waitForFile(dir.sub("go")) + "\necho went-on")

        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
        #expect(clock.now - start < .seconds(10))
    }
}
