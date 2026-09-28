import ArgumentParser
import CanopyCore
import Foundation

struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Print what happened in Canopy, oldest first.",
        discussion: """
            Canopy logs repos and rows coming and going, rows switching branch, pull requests opening and changing \
            state, terminals opening and exiting, commands that finish in zsh terminals, and canopy calls that \
            change something. It reads the log files in CANOPY_HOME/activity directly, so it works while Canopy \
            is not running.

            Times can be 30s, 15m, 2h, 3d, 1w, today, yesterday, a date like 2026-09-27, a local time like \
            2026-09-27T14:30 or 14:30, or a full ISO 8601 timestamp.
            """
    )

    @Option(help: "Start here. Defaults to 24 hours ago.")
    var since = "24h"
    @Option(help: "Stop before this time.")
    var until: String?
    @Option(
        help: ArgumentHelp(
            "Only events of this type, such as term.command, or of this kind, such as row. Repeat or separate with commas.",
            valueName: "type"))
    var type: [String] = []
    @OptionGroup var output: OutputOptions

    func run() throws {
        let client = Client(json: output.json)
        let since: Date
        let until: Date?
        do {
            since = try LogTime.parse(self.since)
            until = try self.until.map { try LogTime.parse($0) }
        } catch let error as LogTimeError {
            client.fail(ControlError(code: "bad_params", message: error.description))
        }
        let types = type.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let events = ActivityReader.events(
            in: client.home.activityFolder, since: since, until: until, types: types.filter { !$0.isEmpty })
        try client.print(try .from(events)) {
            guard !events.isEmpty else { return "No activity." }
            return Table.render(
                ["TIME", "TYPE", "SOURCE", "REPO", "ROW", "DETAILS"],
                events.map { [$0.localTime, $0.type, $0.source.rawValue, $0.repo ?? "", $0.row ?? "", $0.summary] }
            )
        }
    }
}
