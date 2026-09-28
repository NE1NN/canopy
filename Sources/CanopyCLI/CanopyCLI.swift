import ArgumentParser
import CanopyCore
import Foundation

@main
struct CanopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canopy",
        abstract: "Drive Canopy from the command line.",
        version: CanopyVersion.current,
        subcommands: [
            Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, PortsCommand.self, PRCommand.self,
            AgentGuide.self,
        ]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether Canopy is running.")

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = Client(json: output.json)
        guard ControlClient.canConnect(socketPath: client.home.socketPath) else {
            if output.json {
                print(#"{"running": false}"#)
            } else {
                print("Canopy is not running (home: \(client.home.root.path)).")
            }
            throw ExitCode(1)
        }
        let result = client.call(ControlMethod.status, JSONValue.null, launchIfNeeded: false)
        try client.print(result) {
            let status = try result.decode(StatusResult.self)
            return "Canopy \(status.version) is running (pid \(status.pid), home: \(status.home))."
        }
    }
}
