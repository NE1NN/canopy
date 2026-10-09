import ArgumentParser
import CanopyCore
import Foundation

struct TermCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "term",
        abstract: "Open, drive, and read terminals.",
        subcommands: [List.self, New.self, Send.self, Read.self, Close.self, State.self, Wait.self]
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
                    ["ID", "ROW", "TAB", "PROCESS", "AGENT", "TITLE", "FOLDER"],
                    panes.map { pane in
                        let process = pane.exited.map { "exited (\($0))" } ?? pane.foreground ?? ""
                        return [
                            pane.pane, pane.row, pane.tab, process, pane.agent?.rawValue ?? "", pane.title, pane.folder,
                        ]
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
            let result = client.call(
                TermMethod.send, TermSendParams(pane: id, text: text, enter: enter), launchIfNeeded: false)
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

        func validate() throws {
            if let lines, lines < 1 { throw ValidationError("--lines must be at least 1.") }
        }
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TermMethod.read, TermReadParams(pane: id, lines: lines), launchIfNeeded: false)
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
            let result = client.call(TermMethod.close, TermCloseParams(pane: id, force: force), launchIfNeeded: false)
            try client.print(result) { "Closed \(id)." }
        }
    }

    struct State: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report an agent's state in a terminal, your own by default.",
            usage: "canopy term state [<id>] <working|waiting|done|background|none> [--json]",
            discussion: """
                Agents that Claude Code's hooks do not cover report this way: working while they take a turn, \
                waiting when they need you, done when they finish, background when their turn ended but work they \
                started still runs, and none when they stop.
                """
        )

        @Argument(
            help: ArgumentHelp("An optional terminal ID, such as p12, then the state.", valueName: "id-and-state"))
        var values: [String]
        @OptionGroup var output: OutputOptions

        func validate() throws {
            guard (1...2).contains(values.count) else { throw ValidationError("Pass a state, and optionally an ID.") }
            guard AgentState(rawValue: values.last!) != nil else {
                throw ValidationError("The state must be working, waiting, done, background, or none.")
            }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let pane =
                values.count == 2
                ? values[0] : ProcessInfo.processInfo.environment["CANOPY_PANE"].flatMap { $0.isEmpty ? nil : $0 }
            guard let pane else {
                client.fail(ControlError(WorkspaceError.missingTarget(flag: "a terminal ID")))
            }
            let result = client.call(
                TermMethod.state, TermStateParams(pane: pane, state: AgentState(rawValue: values.last!)),
                launchIfNeeded: false)
            try client.print(result) {
                let reported = try result.decode(TermStateResult.self)
                return "\(reported.pane) \(reported.state.rawValue)"
            }
        }
    }

    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wait until an agent in one of the terminals is done or waiting for you.",
            discussion: """
                A terminal already in the state counts at once, unless something was typed or sent into it since. \
                any means done or waiting, never background. \
                It fails when the time runs out, when one of the terminals closes, or when its agent stops.
                """
        )

        @Argument(help: "Terminal IDs, such as p12.")
        var ids: [String]
        @Option(name: .customLong("for"), help: ArgumentHelp("done, waiting, background, or any.", valueName: "state"))
        var target = AgentWaitTarget.any
        @Option(help: "How long to wait, such as 90s, 30m, or 2h.")
        var timeout = "30m"
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if ids.isEmpty { throw ValidationError("Pass at least one terminal ID.") }
            if TimeSpan.seconds(timeout) == nil { throw ValidationError("--timeout takes a span such as 90s or 30m.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let seconds = TimeSpan.seconds(timeout) ?? TermWaitParams.defaultTimeout
            let result = client.call(
                TermMethod.wait, TermWaitParams(panes: ids, target: target, timeout: seconds), launchIfNeeded: false,
                wait: .upTo(seconds + 10))
            try client.print(result) {
                let reached = try result.decode(TermWaitResult.self)
                return "\(reached.pane) \(reached.state.rawValue)"
            }
        }
    }
}

extension AgentWaitTarget: ExpressibleByArgument {}
