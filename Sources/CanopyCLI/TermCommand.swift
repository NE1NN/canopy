import ArgumentParser
import CanopyCore
import Foundation

struct TermCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "term",
        abstract: "Open, drive, and read terminals.",
        subcommands: [List.self, New.self, Send.self, Read.self, Close.self]
    )

    struct RowOptions: ParsableArguments {
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @Option(help: "Row branch or path. Defaults to the row you are in.")
        var row: String?

        var hint: TargetHint { Client.hint(repo: repo, row: row) }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the terminals in the row you are in, or in every row.")

        @OptionGroup var rowOptions: RowOptions
        @Flag(help: "List terminals in every row.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.list, TermListParams(target: rowOptions.hint, all: all))
            try client.print(result) {
                let panes = try result.decode([TermInfo].self)
                return Table.render(
                    ["ID", "ROW", "TAB", "PROCESS", "TITLE", "FOLDER"],
                    panes.map { pane in
                        let process = pane.exited.map { "exited (\($0))" } ?? pane.foreground ?? ""
                        return [pane.pane, pane.row, pane.tab, process, pane.title, pane.folder]
                    }
                )
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a terminal in the row you are in and optionally run a command in it.",
            discussion: "It joins the row's selected tab by the add rule unless --tab or --new-tab says otherwise."
        )

        @OptionGroup var rowOptions: RowOptions
        @Option(help: "Add it to the tab with this name, opening that tab if needed.")
        var tab: String?
        @Flag(help: "Open it in a new tab.")
        var newTab = false
        @Option(name: .customLong("run"), help: "Command to type into it once its shell is ready.")
        var command: String?
        @Option(help: "Title for its header instead of the running program's.")
        var title: String?
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if tab != nil && newTab { throw ValidationError("Pass --tab or --new-tab, not both.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                TermMethod.new,
                TermNewParams(target: rowOptions.hint, tab: tab, newTab: newTab, run: command, title: title))
            try client.print(result) {
                let opened = try result.decode(TermNewResult.self)
                return "Opened \(opened.pane) in tab \(opened.tab)."
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Type text into a terminal.")

        @Argument(help: "Terminal ID, such as p12.")
        var id: String
        @Argument(help: "Text to type.")
        var text: String
        @Flag(help: "Press Return after the text.")
        var enter = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.send, TermSendParams(pane: id, text: text, enter: enter))
            try client.print(result) { "Sent to \(id)." }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a terminal's screen, or its last lines including scrollback, as plain text.")

        @Argument(help: "Terminal ID, such as p12.")
        var id: String
        @Option(help: "Print the last this many lines, scrollback included, instead of the visible screen.")
        var lines: Int?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.read, TermReadParams(pane: id, lines: lines))
            try client.print(result) { try result.decode(TermReadResult.self).text }
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a terminal.")

        @Argument(help: "Terminal ID, such as p12.")
        var id: String
        @Flag(help: "Close it even while a program runs in it.")
        var force = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.close, TermCloseParams(pane: id, force: force))
            try client.print(result) { "Closed \(id)." }
        }
    }
}
