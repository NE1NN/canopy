import ArgumentParser
import CanopyCore
import CanopyTickets
import Foundation

struct TicketCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ticket",
        abstract: "Work on Discord support tickets from ticket-manager, each in a row of its own.",
        discussion: """
            A <ticket> is 853, 0853, 0853-sameergoyal, ticket-0853-sameergoyal, closed-0853-sameergoyal, or a \
            ticket-manager id. In a ticket row, commands without one use the row's ticket. Each ticket row's \
            folder holds ticket.md, the ticket's handover block, and ticket.json, ticket-manager's last response.
            """,
        subcommands: [List.self, New.self, Show.self, Select.self, Remove.self, Connect.self, Disconnect.self]
    )

    /// Reading a ticket may look through open, closed, and archived tickets, each allowed 15 seconds.
    static let readingWait = ReplyWait.upTo(90)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List open tickets, waiting customers first, then by latest activity, with each one's row.")

        @Flag(help: "Only tickets you own.")
        var mine = false
        @Flag(help: "Only tickets nobody owns.")
        var unowned = false
        @Flag(help: "Only tickets whose customer is waiting for a reply.")
        var waiting = false
        @Option(help: "Keep tickets whose name or customer holds each word.")
        var query: String?
        @Flag(help: "Closed and archived tickets instead of open ones.")
        var closed = false
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if mine, unowned { throw ValidationError("Pass --mine or --unowned, not both.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let owner: TicketOwnerFilter = mine ? .mine : unowned ? .unowned : .anyone
            let result = client.call(
                TicketMethod.list,
                TicketListParams(target: Client.hint(), owner: owner, waiting: waiting, query: query, closed: closed),
                wait: TicketCommand.readingWait)
            try client.print(result) {
                let entries = try result.decode([TicketListEntry].self)
                guard !entries.isEmpty else { return "No tickets." }
                return TicketText.listLines(entries, now: Date(), homeFolder: NSHomeDirectory()).joined(separator: "\n")
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a row for a ticket.",
            discussion: """
                The row's folder gets ticket.md and ticket.json, then --run, or config.json's `run`, is typed into a \
                new terminal there. A ticket that has a row fails with ticket_has_row, naming it: show it with \
                `canopy ticket select <ticket>` instead.
                """
        )

        @Argument(help: "The ticket, such as 853.")
        var ticket: String
        @Option(name: .customLong("run"), help: "Command to type into a new terminal in the row.")
        var command: String?
        @Flag(help: "Switch the Canopy window to the new row.")
        var select = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                TicketMethod.new,
                TicketNewParams(target: Client.hint(), reference: ticket, run: command, select: select),
                wait: .forever)
            let created = try result.decode(PluginRowCreated.self)
            try client.print(result) {
                var lines = ["Opened \(created.row.displayName) in \(created.row.path)."]
                if let pane = created.pane {
                    lines.append(command.map { "Running \($0) in \(pane)." } ?? "Running config.json's run in \(pane).")
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

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a ticket: its messages, problems, draft, notes, and fix rows.",
            discussion: """
                Canopy's copy is used while it is under 30 seconds old. When ticket-manager cannot be reached, the \
                copy Canopy has is printed, with a note on stderr saying how old it is.
                """
        )

        @Argument(help: "The ticket, such as 853. Defaults to the ticket row you are in.")
        var ticket: String?
        @Flag(help: "Ask ticket-manager even when Canopy's copy is fresh.")
        var refresh = false
        @Flag(help: "Print the ticket's handover markdown alone, as ticket.md holds it.")
        var md = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                TicketMethod.show,
                TicketShowParams(target: Client.hint(), reference: ticket, refresh: refresh, md: md),
                wait: TicketCommand.readingWait)
            let shown = try result.decode(TicketShowResult.self)
            if let stale = shown.stale {
                FileHandle.standardError.write(Data("note: \(stale)\n".utf8))
            }
            try client.print(result) {
                md
                    ? TicketText.clean(shown.ticket.handover)
                    : TicketText.show(shown, now: Date(), homeFolder: NSHomeDirectory())
            }
        }
    }

    struct Select: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a ticket's row in the Canopy window.")

        @Argument(help: "The ticket, such as 853. Defaults to the ticket row you are in.")
        var ticket: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                TicketMethod.select, TicketRefParams(target: Client.hint(), reference: ticket),
                wait: TicketCommand.readingWait)
            try client.print(result) { "Selected \(try result.decode(PluginRow.self).displayName)." }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a ticket's row. Its folder goes to the Trash, and its fix rows keep their link.",
            discussion: "A program running in one of its terminals stops this unless --force."
        )

        @Argument(help: "The ticket, such as 853. Defaults to the ticket row you are in.")
        var ticket: String?
        @Flag(help: "Remove it even while programs run in its terminals.")
        var force = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                TicketMethod.remove, TicketRemoveParams(target: Client.hint(), reference: ticket, force: force),
                wait: .forever)
            let removed = try result.decode(PluginRowRemoved.self)
            try client.print(result) {
                guard let trashedTo = removed.trashedTo else { return "Removed \(removed.row.displayName)." }
                return "Removed \(removed.row.displayName). Its folder is in the Trash at \(trashedTo)."
            }
        }
    }

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Connect Canopy to ticket-manager with a token, and turn Tickets on.",
            discussion: """
                The token is read without echoing it in a terminal, or from stdin otherwise. Canopy checks it with \
                ticket-manager and keeps it in the Keychain. A token ticket-manager rejects saves nothing. Make one \
                in ticket-manager with `npx convex run --prod api/apiTokens:create '{"email": "<email>", "label": \
                "canopy"}'`.
                """
        )

        @Argument(help: "ticket-manager's address: its deployment's .convex.site URL.")
        var url: String
        @Option(
            help: ArgumentHelp("ticket-manager's page for a ticket, with {id} where its id goes.", valueName: "url"))
        var web: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let token: String
            do {
                token = try SecretPrompt.read(prompt: "ticket-manager token for \(url): ")
            } catch let error as CLIError {
                client.fail(ControlError(code: "bad_params", message: error.description))
            }
            guard !token.isEmpty else {
                client.fail(ControlError(code: "bad_params", message: "No token was given. Type it, or pipe it in."))
            }
            let result = client.call(
                TicketMethod.connect, TicketConnectParams(url: url, token: token, web: web),
                wait: TicketCommand.readingWait)
            try client.print(result) {
                let connected = try result.decode(TicketConnectResult.self)
                return "Connected to \(connected.url) as \(connected.email)."
            }
        }
    }

    struct Disconnect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn Tickets off and delete its token. Ticket rows stay for when you connect again.",
            discussion: "The terminals in ticket rows close, and a program running in one stops this unless --force."
        )

        @Flag(help: "Close the ticket rows' terminals even while programs run in them.")
        var force = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(TicketMethod.disconnect, TicketDisconnectParams(force: force))
            try client.print(result) { "Disconnected Tickets. Its rows stay for when you connect again." }
        }
    }
}
