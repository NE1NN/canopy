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
}
