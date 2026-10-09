import ArgumentParser
import CanopyCore
import CanopyTickets

struct AgentGuide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide", abstract: "Print a manual for agents driving Canopy.")

    /// The Tickets section comes after Plugin rows, only while config.json turns the plugin on.
    func run() {
        let home = CanopyHome.resolve(bundleHome: AppLocator.bundleHome())
        guard TicketsGuide.isOn(configFile: home.configFile) else {
            print(Self.text)
            return
        }
        print(Self.text.replacingOccurrences(of: "\n## Terminals\n", with: "\n\(TicketsGuide.text)\n\n## Terminals\n"))
    }

    static let text = """
        # Canopy for agents

        Canopy shows git worktrees as rows, each with tabs of terminals. You drive it with `canopy`.
        Add `--json` to commands that talk to Canopy for machine-readable output. They exit non-zero on failure,
        and with `--json` print {"error": {"code", "message"}}. `canopy status` says whether Canopy is running.

        ## Where commands act

        Commands about a repo or row use, in order: `--repo` and `--row` (or a row argument, a branch or a path),
        then CANOPY_REPO and CANOPY_ROW_PATH from your environment, then the worktree containing your current folder.
        Inside a Canopy terminal you rarely need flags. CANOPY_PANE is your own terminal's ID, such as p12.

        ## Repos and rows

            canopy repo add <path> | canopy repo list | canopy repo rm <name>
            canopy repo clone <owner/repo | url> [--into <dir>]
            canopy repo collapse [<repo>] | canopy repo expand [<repo>]

            canopy row list [--all]                       rows, and other tools' worktrees with --all
            canopy row new <branch> [--from <ref> | --existing] [--run <cmd>] [--no-setup] [--select]
            canopy row new --pr <n | #n | URL> [--branch <name>] [--group <name>] [--run <cmd>] [--no-setup] [--select]
            canopy row rm [<branch>] [--force] [--delete-branch]
            canopy row select [<branch>]
            canopy row adopt <path>                       show another tool's worktree as a row

        `repo clone` clones with your gh login into CANOPY_HOME/repos/<owner>/<name> and registers the repo. Run it
        again and it registers the folder it already made. `repo rm` only unregisters and never deletes files.
        `repo collapse` folds a repo away in the sidebar, and is safe to repeat: its rows keep running and stay in
        `row list`, but get no ⌘1 to ⌘9 until it is expanded, and `row select` of one of them expands it again.
        `repo list --json` carries the fold as "collapsed".

        `row new` creates the branch and worktree, runs the repo's setup commands from .canopy/config.json in a
        Setup tab, waits for them, then types `--run` into a new terminal. If setup fails, the row stays, the
        command is not run, and `row new` exits 1. `row rm` runs teardown first, then removes the worktree.

        `row new <branch>` fetches origin, then says in "source" which branch it used: `local` (an existing branch,
        fast-forwarded if it was only behind origin), `origin` (a new local branch tracking origin's), or `new`
        (created from --from, by default origin's default branch). A mistyped name makes a new branch, so pass
        `--existing` when you mean someone else's branch: it fails with branch_not_found instead. A branch with
        commits of its own is never reset. "notes" say what Canopy did, and "warnings" what may need you.

        `row new --pr` checks out a pull request's branch, including one from a fork, with gh pr checkout's names and
        tracking, and "pr" in the result is the PR. Pick the local name with `--branch`. A branch another row has
        fails with branch_checked_out, which names that row; use `canopy row select` or `canopy term` there instead.
        To find what to start from, list the repo's PRs and branches (see Pull requests and branches below).

        ## Groups

            canopy group list [--repo <name>]             groups and their rows
            canopy group new <name>                       an empty group, after the repo's others
            canopy group rename <name> <new-name>
            canopy group rm <name>                        its rows become ungrouped; no worktree is touched
            canopy row move [<row>] (--group <name> | --no-group | --before <row> | --after <row>)
            canopy row new <branch> --group <name>        create the row straight into a group, also with --pr
            canopy group collapse <name> | canopy group expand <name>

        A group belongs to one repo and only arranges the sidebar, where it can fold away. Names match ignoring
        case. A group that does not exist is an error (group_not_found), never created for you, so make it first
        with `group new`. `row move --group` is safe to repeat: a row already in the group stays where it is.
        `group collapse` and `group expand` fold a group like `repo collapse` folds a repo, and are safe to repeat too.
        `row list` shows each row's group, and `row list --json` carries it as "group".

        ## Plugin rows

            canopy plugin list                            built-in plugins, whether each is on, and its status
            canopy plugin enable <plugin>                 turn one on; disable <plugin> [--force] turns it off
            canopy plugin items <plugin> [--query <text>] [--filter <id>]...
                                                          its items, and the row each already has
            canopy plugin new <plugin> <reference> [--run <cmd>] [--select]
                                                          open a row for one of its items
            canopy plugin collapse <plugin> | canopy plugin expand <plugin>
                                                          fold its section, like `repo collapse`

        A plugin adds rows that are not worktrees, such as one per support ticket, in a section below the repos. Each
        has a folder under CANOPY_HOME/plugins/<plugin>/, which the plugin fills with files about the item, and tabs
        and terminals like any row. Terminals there get CANOPY_PLUGIN and CANOPY_ITEM, and no CANOPY_REPO or
        CANOPY_ROOT_PATH: a plugin row is in no repo, so pass --repo to commands about a repo. `row list` shows plugin
        rows after the repos', under their plugin, with "plugin", "item", "title", and "path" in --json. `row select`,
        `row rm`, and `row move --before/--after` take a plugin row's path, and `term` and `ports` work in it as in any
        row. `row rm` moves its folder to the Trash, and refuses while a program runs in it unless --force.
        `plugin new` fails with item_has_row, naming the row, when the item has one: `row select` that row instead.
        `plugin list --json` names each plugin's filters for `plugin items --filter`.

        `row new` run in a plugin row links the new worktree row to the row's item, so the item's panel lists it, and
        `row list --json` carries it as "link". Pass --no-link to leave it out.

        ## Remote rows

            canopy host add <alias> --repo <repo>=<path>... [--wake <cmd>] [--idle-detach <min>]
            canopy host list | rm <alias>
            canopy row new <branch> --on <host> [--run <cmd>]   a row whose worktree is on the host
            canopy row new <branch> --on local                  from a host, a row on this Mac

        A host is an ssh alias from ~/.ssh/config with a clone of the repo. A remote row's worktree is in
        ~/.canopy/worktrees/<repo>/ on the host, and its terminals open there inside tmux, so programs such as
        claude keep running while this Mac sleeps or Canopy quits, and the terminal joins them again when it
        reconnects. `row list` shows its class as remote:<host>, and its path is a stand-in folder on this Mac, which
        `row select` and `row rm` take. Panes detach after the host's idle minutes with nothing running and nothing
        typed, so it can power itself off; Return reconnects. A host that cannot be reached runs its --wake command,
        such as one that starts it.

        In a remote row's terminals, `canopy` works as it does here: it relays each command to Canopy on this Mac,
        so `term`, `web`, `row`, and the rest act on the remote row. `row new` there makes its row on the same host
        unless you pass `--on local`. The relay passes on no typing, so a command that would prompt, such as `ticket
        connect`, takes the first line of standard input piped to it, and at a terminal says to pipe it in. Other
        commands leave standard input to what runs after them. Claude Code on the host opens links with xdg-open, which opens claude.ai artifact links in Canopy, in
        your row, and hands any other link to the host's own xdg-open. `canopy host add` keeps Claude Code's hooks on
        the host, so `canopy hooks` there only says so. Agents on the host use the host's own git and gh, not this
        Mac's.

        ## Terminals

            canopy term list [--all]                      ID, row, tab, process, title, and folder
            canopy term new [--tab <name> | --new-tab] [--run <cmd>] [--title <t>]
            canopy term send <id> <text> [--enter]        type text, then Return with --enter
            canopy term read <id> [--lines N]             the screen, or the last N lines with scrollback
            canopy term close <id> [--force]              --force if a program still runs in it

        Terminal IDs such as p12 stay unique across relaunches. `term send`, `read`, and `close` never start Canopy.
        With --enter, Return goes in as a keystroke of its own once the program has read the text, or after 2 seconds if
        it is not reading, and a moment later; `term send` returns once it is in. Claude Code and Codex take a Return
        that arrives with the text for part of a paste, so this is what makes a long or multi-line message submit.
        Send to a program you just started once its prompt shows in `term read`: until it reads keys itself, the
        terminal hands it typed-ahead lines together with their Return.

        ## Web pages

            canopy web open <url> [--tab | --panel]       show a page in your row
            canopy web list [--all]                       ID, where it is, row, title, and URL
            canopy web close <id>                         close a page, such as w3

        After you publish a claude.ai artifact, run `canopy web open <its url>` so the author sees it in Canopy, next
        to you, instead of in a browser. `web open` also takes any http or https URL, such as your dev server's.
        A row shows a page in its panel on the right of the terminals or in a tab of its own, and opens new pages where
        the author last moved one; `--tab` or `--panel` picks for this page alone. A page the row shows already is shown
        where it is, so opening it again is safe. `web open` never changes which row the author has selected. A URL that
        is not http or https fails with invalid_url, and `web close` of a page no row has with page_not_found.

        ## Agent state

            canopy term state [<id>] <working|waiting|done|none>   report an agent's state, your terminal's by default
            canopy term wait <id>... [--for done|waiting|any] [--timeout 30m]
                                                          wait until one of them is done or waiting for its user
            canopy hooks install | uninstall | status     Claude Code hooks that report Claude's state on their own

        `term list` shows each terminal's agent state: working, waiting, done, or blank. Claude Code reports its own
        once `canopy hooks install` has added Canopy's hooks to ~/.claude/settings.json. Other agents report with
        `term state`, for example Codex, from ~/.codex/config.toml:

            notify = ["sh", "-c", "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" term state done", "codex-notify"]

        `term wait` returns at once for a terminal already in the state, unless something was typed or sent into it
        since then, so `term send ... --enter` followed by `term wait` waits for the next finish. It prints the
        terminal and its state, such as `p12 done`, and fails with wait_timeout, pane_closed, or agent_stopped.
        `term state` and `term wait` never start Canopy.

        ## Ports

            canopy ports [--all]                          what the row's processes listen on, or every row's
            canopy ports stop <port> [--all]              SIGTERM, then SIGKILL after 3 seconds if still listening

        A port belongs to the row whose terminal started its process, otherwise to the row whose folder the process
        works in. `ports stop` only stops your row's ports, or any row's with --all, never a port no row owns.
        Ports the system picks at random (49152 and up) are left out: they are tools like MCP servers.

        A remote row's ports are its host's: a server started in its terminals, or working in its worktree, is
        forwarded on its own to localhost on this Mac, on the same port when that is free there, else the next free one.
        The list shows the host in HOST, and PORT reads `5173 → 5174` when this Mac's port differs ("host" and
        "localPort" in --json); a port ssh could not forward reads `(not forwarded)`, with ssh's message as
        "forwardError". Its PID is the host's. `ports stop` takes either number and stops the server on the host.
        When one host stops its port and another cannot, it prints what stopped, then an error for the other, and
        exits 1; --json lists the other in "failures".

        ## Pull requests and branches

            canopy pr show [<branch>] [--refresh]         the row's PR: number, state, title, and URL
            canopy pr list [--query <text>] [--closed]    the repo's open PRs, most recently updated first
            canopy branch list [--query <text>]           local and origin branches, newest commit first

        `canopy pr` alone is `pr show`. Canopy looks up PRs with your `gh` login for its own and adopted rows, about
        once a minute and more often right after a push. `--refresh` asks GitHub now, for example right after
        `gh pr create`. `row list --json` also carries each row's PR as "pr" when it has one.

        `pr list` shows the 100 most recently updated open PRs, or PRs in any state with `--closed`. `--query` keeps
        those whose number, title, head branch, or author holds each word, and a number, #number, or URL looks that PR
        up even when it is closed. `branch list` fetches origin first, unless you pass `--no-fetch`. It says where each
        branch is ("where": local, origin, or both) and how many commits the local branch is "ahead" of or "behind"
        origin's. In both lists "row" is the row or worktree that has the item checked out, or null. Start a row on an
        item without one with `row new --pr <n>` or `row new <branch> --existing`, show one that has a row with
        `row select`, and adopt one in another tool's worktree ("class": "external") with `row adopt <path>`. These
        are the lists the New Row sheet shows.

        ## Activity

            canopy log [--since <when>] [--until <when>] [--type <t>]   what happened, oldest first

        Canopy logs repos and rows coming and going, plugins turning on and off, rows switching branch, PRs opening and
        changing state, terminals opening and exiting, web pages opening and closing, each command that finishes in a zsh terminal with its exit code
        and duration, and each canopy call that changes something. Each event's source says whether it came from the Canopy window (ui), a
        canopy command (cli), or outside Canopy (git). `--since` defaults to 24 hours ago and takes 30m, 2h, 3d, today,
        yesterday, 2026-09-27, or 2026-09-27T14:30. `--type row` matches every row event, `--type term.command` one.
        `canopy log` reads the log files directly, so it works while Canopy is not running.

        ## Examples

        Start a parallel agent on a fix in its own row, then check on it:

            pane=$(canopy row new fix/login-redirect --run 'claude "fix the login redirect, ticket FL-123"' --json | jq -r .pane)
            canopy term wait "$pane" --timeout 1h
            canopy term read "$pane" --lines 40

        Review a pull request in its own row:

            canopy row new --pr 123 --run 'claude "review this PR"'

        Review every open PR that has no row yet:

            canopy pr list --json | jq -r '.[] | select(.row == null) | .number' |
                while read -r n; do canopy row new --pr "$n" --run 'claude "review this PR"'; done

        Run a dev server in its own tab of your row and watch it:

            pane=$(canopy term new --tab Server --run 'bun dev' --title 'dev server' --json | jq -r .pane)
            canopy term read "$pane"

        See which commands failed in the last hour, in any row:

            canopy log --since 1h --type term.command --json | jq '.[] | select(.data.exit != 0) | .data.cmd'

        Keep your review rows together, and list them:

            canopy group new Review
            canopy row new feat/checkout --group Review --run claude
            canopy row list --json | jq -r '.[] | select(.group == "Review") | .branch'

        Clean up when the work is merged:

            canopy row rm fix/login-redirect --delete-branch
        """
}
