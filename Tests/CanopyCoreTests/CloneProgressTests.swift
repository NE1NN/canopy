import Foundation
import Testing

@testable import CanopyCore

struct CloneProgressTests {
    @Test func readsTheLatestPhaseAndPercent() {
        let output = """
            Cloning into '/tmp/x'...
            remote: Enumerating objects: 30, done.
            remote: Counting objects: 100% (30/30), done.
            Receiving objects:  10% (3/30)\rReceiving objects:  46% (14/30), 1.20 MiB | 2.00 MiB/s\r
            """

        #expect(
            CloneProgress.latest(in: Data(output.utf8)) == CloneProgress(phase: "Receiving objects", fraction: 0.46))
    }

    @Test func dropsTheRemotePrefix() {
        let output = "remote: Compressing objects:  50% (5/10)\r"

        #expect(
            CloneProgress.latest(in: Data(output.utf8)) == CloneProgress(phase: "Compressing objects", fraction: 0.5))
    }

    @Test func skipsALineStillBeingWritten() {
        let output = "Resolving deltas:  75% (3/4)\rResolving del"

        #expect(CloneProgress.latest(in: Data(output.utf8)) == CloneProgress(phase: "Resolving deltas", fraction: 0.75))
    }

    @Test func isNilBeforeAnyPercent() {
        #expect(CloneProgress.latest(in: Data("Cloning into '/tmp/x'...\n".utf8)) == nil)
        #expect(CloneProgress.latest(in: Data([0xFF, 0xFE])) == nil)
    }
}
