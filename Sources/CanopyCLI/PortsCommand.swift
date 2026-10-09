import ArgumentParser
import CanopyCore

struct PortsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ports",
        abstract: "List and stop the ports your rows' processes listen on.",
        discussion: """
            A port belongs to the row whose terminal started its process, otherwise to the row whose folder the \
            process works in. Ports that belong to no row are not listed and cannot be stopped from here. A remote \
            row's ports are its host's, forwarded to this Mac's localhost, on the same port when it is free, else the \
            next free one.
            """,
        subcommands: [List.self, Stop.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the ports of the row you are in, or of every row.")

        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Flag(help: "List ports in every row.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PortMethod.list, PortsListParams(target: rowOptions.hint, all: all))
            try client.print(result) {
                let ports = try result.decode([PortInfo].self)
                return ports.isEmpty ? "No ports." : PortsCommand.table(ports)
            }
        }
    }

    /// A HOST column only when some port is on a host, whose PORT is the host's, with the Mac's after it when the two
    /// differ.
    static func table(_ ports: [PortInfo]) -> String {
        let remote = ports.contains { $0.host != nil }
        return Table.render(
            ["PORT", "PROCESS", "PID"] + (remote ? ["HOST"] : []) + ["REPO", "ROW"],
            ports.map { info in
                // A plugin row's owner is its plugin.
                [info.label, info.process, "\(info.pid)"] + (remote ? [info.host ?? "-"] : [])
                    + [info.repo ?? info.plugin ?? "-", info.row]
            })
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the process listening on a port in the row you are in.",
            discussion: """
                Sends SIGTERM, then SIGKILL if the port is still listening after 3 seconds. Any other ports the \
                process holds close too. A port in another row is refused unless you pass that --row, or --all. A \
                remote row's port is stopped on its host, and is found by its port there or by its port on this Mac.
                """
        )

        @Argument(help: "The port, for example 3000. A remote row's port can be its host's port or this Mac's.")
        var port: Int
        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Flag(help: "Stop the port in whichever row has it.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                PortMethod.stop, PortsStopParams(port: port, target: rowOptions.hint, all: all))
            try client.print(result) { PortsCommand.report(try result.decode(PortsStopResult.self)) }
        }
    }

    /// A line for each process stopped. A host's pids are told apart from this Mac's by the host.
    static func report(_ stopped: PortsStopResult) -> String {
        guard !stopped.stopped.isEmpty else {
            return "Nothing was stopped: what listened on port \(stopped.port) had already exited. Run `canopy ports`"
                + " to see what listens there now."
        }
        let killed = Set(stopped.killed)
        return stopped.stopped.map { info in
            let how =
                killed.contains(PortProcess(pid: info.pid, host: info.host))
                ? " It ignored SIGTERM, so it was killed." : ""
            let host = info.host.map { " on \($0)" } ?? ""
            return "Stopped \(info.process) (pid \(info.pid)) on port \(info.port)\(host).\(how)"
        }
        .joined(separator: "\n")
    }
}
