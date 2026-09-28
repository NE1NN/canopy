import ArgumentParser
import CanopyCore

struct PortsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ports",
        abstract: "List and stop the ports your rows' processes listen on.",
        discussion: """
            A port belongs to the row whose terminal started its process, otherwise to the row whose folder the \
            process works in. Ports that belong to no row are not listed and cannot be stopped from here.
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
                guard !ports.isEmpty else { return "No ports." }
                return Table.render(
                    ["PORT", "PROCESS", "PID", "REPO", "ROW"],
                    ports.map { ["\($0.port)", $0.process, "\($0.pid)", $0.repo, $0.row] }
                )
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the process listening on a port in the row you are in.",
            discussion: """
                Sends SIGTERM, then SIGKILL if the port is still listening after 3 seconds. Any other ports the \
                process holds close too. A port in another row is refused unless you pass that --row, or --all.
                """
        )

        @Argument(help: "The port, for example 3000.")
        var port: Int
        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Flag(help: "Stop the port in whichever row has it.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                PortMethod.stop, PortsStopParams(port: port, target: rowOptions.hint, all: all))
            try client.print(result) {
                let stopped = try result.decode(PortsStopResult.self)
                return stopped.stopped.map { info in
                    let how = stopped.killed.contains(info.pid) ? " It ignored SIGTERM, so it was killed." : ""
                    return "Stopped \(info.process) (pid \(info.pid)) on port \(info.port).\(how)"
                }
                .joined(separator: "\n")
            }
        }
    }
}
