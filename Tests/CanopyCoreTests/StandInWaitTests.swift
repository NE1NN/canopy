import Foundation
import Testing

@testable import CanopyCore

/// A stand-in script that waits for its test to create a file must not poll forever once that test has died.
struct StandInWaitTests {
    static func run(_ script: String) async throws -> SubprocessResult {
        try await offPool {
            try Subprocess.run("/bin/bash", ["-c", script], environment: [:], directory: nil, timeout: .seconds(20))
        }
    }

    @Test func aStandInGivesUpWaitingOnceTheLimitPasses() async throws {
        let dir = try TempDir()
        let result = try await Self.run(Fixture.waitForFile(dir.sub("never"), seconds: 1) + "\necho went-on")

        #expect(!result.timedOut)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
    }

    @Test func aStandInGoesOnOnceItsFileAppears() async throws {
        let dir = try TempDir()
        let (waiting, go) = (dir.sub("waiting"), dir.sub("go"))
        let script = "touch '\(waiting)'\n" + Fixture.waitForFile(go) + "\necho went-on"
        let running = Task { try await Self.run(script) }
        #expect(await eventually { FileManager.default.fileExists(atPath: waiting) })
        let clock = ContinuousClock()
        let start = clock.now

        FileManager.default.createFile(atPath: go, contents: nil)
        let result = try await running.value

        #expect(String(decoding: result.stdout, as: UTF8.self) == "went-on\n")
        #expect(clock.now - start < .seconds(10))
    }
}
