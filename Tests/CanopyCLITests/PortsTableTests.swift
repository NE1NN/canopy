import Testing

@testable import CanopyCLI
@testable import CanopyCore

struct PortsTableTests {
    func info(_ port: Int, pid: Int32, host: String? = nil, localPort: Int? = nil, error: String? = nil) -> PortInfo {
        PortInfo(
            repo: "demo", row: host == nil ? "main" : "feat/web", rowPath: "/w", port: port, pid: pid,
            process: "node", host: host, localPort: localPort, forwardError: error)
    }

    @Test func localPortsHaveNoHostColumn() {
        #expect(
            PortsCommand.table([info(3000, pid: 812)])
                == """
                PORT  PROCESS  PID  REPO  ROW
                3000  node     812  demo  main
                """)
    }

    @Test func aRemotePortNamesItsHostAndTheMacPortWhenItDiffers() {
        let table = PortsCommand.table([
            info(3000, pid: 812),
            info(5173, pid: 40, host: "box", localPort: 5174),
            info(8000, pid: 41, host: "box", localPort: 8000),
            info(9000, pid: 42, host: "box", error: "Port forwarding failed"),
        ])

        #expect(
            table == """
                PORT                  PROCESS  PID  HOST  REPO  ROW
                3000                  node     812  -     demo  main
                5173 → 5174           node     40   box   demo  feat/web
                8000                  node     41   box   demo  feat/web
                9000 (not forwarded)  node     42   box   demo  feat/web
                """)
    }

    /// A host's pids and this Mac's are different processes, even when their numbers are the same.
    @Test func aKilledProcessIsNamedOnlyWhereItWasKilled() {
        let report = PortsCommand.report(
            PortsStopResult(
                port: 5173, stopped: [info(3000, pid: 40), info(5173, pid: 40, host: "box", localPort: 5173)],
                killed: [PortProcess(pid: 40, host: "box")]))

        #expect(
            report == """
                Stopped node (pid 40) on port 3000.
                Stopped node (pid 40) on port 5173 on box. It ignored SIGTERM, so it was killed.
                """)
    }

    /// What stopped is printed, and each host that could not stop its port after it, as an error.
    @Test func aHostThatCouldNotStopItsPortIsNamedAfterWhatStopped() {
        let result = PortsStopResult(
            port: 5173, stopped: [info(5173, pid: 40, host: "box", localPort: 5173)], killed: [],
            failures: [
                PortStopFailure(
                    host: "other", port: 5173,
                    error: ControlError(code: "host_command_failed", message: "A command on other failed: exit 1"))
            ])

        #expect(PortsCommand.report(result) == "Stopped node (pid 40) on port 5173 on box.")
        #expect(
            PortsCommand.failures(result) == ["Could not stop port 5173 on other: A command on other failed: exit 1"])
        #expect(PortsCommand.failures(PortsStopResult(port: 5173, stopped: [], killed: [])).isEmpty)
    }

    @Test func aStopThatSignalledNothingSaysSo() {
        let report = PortsCommand.report(PortsStopResult(port: 5173, stopped: [], killed: []))

        #expect(report.hasPrefix("Nothing was stopped: what listened on port 5173 had already exited."))
    }
}
