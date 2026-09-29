import CanopyCore
import Foundation

/// The Tickets section of `canopy agent-guide`, which it prints only while the plugin is on.
public enum TicketsGuide {
    /// On while config.json has a tickets section that does not say `"enabled": false`.
    public static func isOn(configFile: URL) -> Bool {
        guard let sections = try? PluginConfig.sections(in: configFile) else { return false }
        return PluginConfig.isOn(sections[TicketMethod.plugin])
    }

    public static let text = """
        ## Tickets

            canopy ticket list [--mine | --unowned] [--waiting] [--query <text>] [--closed]
            canopy ticket new <ticket> [--run <cmd>] [--select]
            canopy ticket show [<ticket>] [--refresh] [--md]
            canopy ticket select [<ticket>]
            canopy ticket rm [<ticket>] [--force]
            canopy row new <branch> --repo <repo> [--ticket <ticket>]

        Tickets brings Discord support tickets in from ticket-manager. Each ticket you open is a row in the Tickets
        section, with a folder under CANOPY_HOME/plugins/tickets/ and terminals like any row, which start in that
        folder. ticket.md there is the ticket's handover block: the conversation, its problems, and what to
        investigate. Canopy rewrites it when it fetches a newer copy, and `ticket show --md` prints the latest.
        ticket.json is ticket-manager's last response for the ticket.

        A <ticket> is 853, 0853, 0853-sameergoyal, ticket-0853-sameergoyal, closed-0853-sameergoyal, or a
        ticket-manager id. A number looks at the rows' tickets and open tickets first, then at closed ones, and fails
        with ticket_ambiguous, naming each match, when two share it. In a ticket row, commands without a <ticket> use
        the row's. `ticket new` fails with ticket_has_row, naming the row, when the ticket has one: `ticket select` it
        instead. `ticket new` runs config.json's `run` in the new row unless --run gives another. `ticket list` shows
        each ticket's row.

        A fix belongs in a worktree row. `canopy row new` run in a ticket row's terminal links the new row to the
        ticket, and so does --ticket anywhere. The linked row shows the ticket's label, such as #0853, and
        `row list --json` carries the link as "link".

        Errors: plugin_off and token_rejected say to run `canopy ticket connect <url>`, which only the author can do.
        tickets_unreachable means ticket-manager did not answer: `ticket show` then prints its saved copy, with a note
        on stderr saying how old it is.

            canopy ticket list --mine --waiting
            canopy ticket new 853 --run 'claude "$(cat ticket.md)"'
            canopy row new fix/shadowban-check --repo solis-v1 --run 'claude "fix the shadowban check, see #0853"'
        """
}
