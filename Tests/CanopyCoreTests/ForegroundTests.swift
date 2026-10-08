import Foundation
import Testing

@testable import CanopyCore

struct ForegroundTests {
    /// The concurrency pool's threads block most signals, and a child would inherit that: ssh would never hear that the
    /// window changed size.
    @Test func aProgramStartedFromThePoolGetsEverySignal() async throws {
        let dir = try TempDir()
        let report = dir.sub("mask")
        let script =
            "import signal, sys; open(sys.argv[1], 'w').write(' '.join(sorted(s.name for s in "
            + "signal.pthread_sigmask(signal.SIG_BLOCK, []))))"

        let status = await Task.detached {
            await Foreground.run(["/usr/bin/python3", "-I", "-c", script, report])
        }.value

        #expect(status == 0)
        #expect(try String(contentsOfFile: report, encoding: .utf8) == "")
    }

    @Test func itsExitStatusAndSignalComeBack() async {
        #expect(await Foreground.run(["/bin/sh", "-c", "exit 3"]) == 3)
        #expect(await Foreground.run(["/bin/sh", "-c", "kill -9 $$"]) == 128 + 9)
        #expect(await Foreground.run(["/nonexistent"]) == 255)
    }
}
