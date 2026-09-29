import ArgumentParser
import CanopyCore
import Foundation

struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "List plugins, turn them on and off, and open rows for their items.",
        discussion: """
            A plugin adds rows that are not worktrees, such as one per support ticket, in a section of its own \
            below the repos. Each row has a folder under CANOPY_HOME/plugins/<plugin>/, which the plugin fills \
            with files about its item. A plugin does nothing until it is turned on, which writes its section of \
            config.json.
            """,
        subcommands: [List.self, Enable.self, Disable.self, Items.self, New.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the built-in plugins, whether each is on, and how it is doing.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PluginMethod.list, JSONValue.null)
            try client.print(result) {
                let plugins = try result.decode([PluginListing].self)
                guard !plugins.isEmpty else { return "No plugins." }
                let table = Table.render(
                    ["PLUGIN", "ON", "ROWS", "STATUS"],
                    plugins.map { [$0.id, $0.on ? "yes" : "no", "\($0.rows)", $0.status ?? "-"] })
                let warnings = plugins.compactMap { plugin in plugin.warning.map { "\(plugin.name): \($0)" } }
                return ([table] + warnings).joined(separator: "\n")
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn a plugin on, keeping the rest of config.json as it is.")

        @Argument(help: "The plugin's id, as `canopy plugin list` shows it.")
        var plugin: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PluginMethod.enable, PluginEnableParams(plugin: plugin))
            let listing = try result.decode(PluginListing.self)
            if let warning = listing.warning {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(result) { "Turned on \(listing.name)." }
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn a plugin off. Its rows stay for when it is on again.",
            discussion: "The terminals in its rows close, and a program running in one stops this unless --force."
        )

        @Argument(help: "The plugin's id, as `canopy plugin list` shows it.")
        var plugin: String
        @Flag(help: "Close its rows' terminals even while programs run in them.")
        var force = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PluginMethod.disable, PluginDisableParams(plugin: plugin, force: force))
            try client.print(result) { "Turned off \(try result.decode(PluginListing.self).name)." }
        }
    }

    struct Items: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List a plugin's items, as its picker does, with the row each already has.",
            discussion: "`canopy plugin list --json` names each plugin's filters."
        )

        @Argument(help: "The plugin's id.")
        var plugin: String
        @Option(help: "Keep the items that match this text.")
        var query: String?
        @Option(
            name: .customLong("filter"),
            help: ArgumentHelp("One of the plugin's filters, by id. Repeat for its toggles.", valueName: "id"))
        var filters: [String] = []
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                PluginMethod.items, PluginItemsParams(plugin: plugin, query: query, filters: filters))
            try client.print(result) {
                let items = try result.decode([PluginItem].self)
                guard !items.isEmpty else { return "No items." }
                return Table.render(
                    ["ITEM", "TITLE", "DETAILS", "ROW"],
                    items.map { item in
                        let details = ([item.subtitle].compactMap { $0 } + item.accessories.map { $0.text ?? $0.help })
                        return [
                            item.id, item.title, details.isEmpty ? "-" : details.joined(separator: " · "),
                            item.row?.path ?? "-",
                        ]
                    })
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a row for one of a plugin's items.",
            discussion: """
                The plugin fills the row's folder with files about the item, then --run is typed into a new \
                terminal there. An item that already has a row fails with item_has_row, naming the row: show it \
                with `canopy row select <path>` instead.
                """
        )

        @Argument(help: "The plugin's id.")
        var plugin: String
        @Argument(help: "What names the item, such as its id.")
        var reference: String
        @Option(name: .customLong("run"), help: "Command to type into a new terminal in the row.")
        var command: String?
        @Flag(help: "Switch the Canopy window to the new row.")
        var select = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                PluginMethod.new, PluginNewParams(plugin: plugin, reference: reference, run: command, select: select))
            let created = try result.decode(PluginRowCreated.self)
            try client.print(result) {
                var lines = ["Opened \(created.row.displayName) in \(created.row.path)."]
                if let pane = created.pane, let command {
                    lines.append("Running \(command) in \(pane).")
                }
                return lines.joined(separator: "\n")
            }
            if let fillError = created.fillError {
                fflush(stdout)
                FileHandle.standardError.write(Data("error: \(fillError)\n".utf8))
                throw ExitCode(1)
            }
        }
    }
}
