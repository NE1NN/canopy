import ArgumentParser

struct AgentGuide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide", abstract: "Print a manual for agents driving Canopy.")

    func run() {
        print(Self.text)
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

            canopy row list [--all]                       rows, and other tools' worktrees with --all
            canopy row new <branch> [--from <ref>] [--run <cmd>] [--no-setup] [--select]
            canopy row rm [<branch>] [--force] [--delete-branch]
            canopy row select [<branch>]
            canopy row adopt <path>                       show another tool's worktree as a row

        `row new` creates the branch and worktree, runs the repo's setup commands from .canopy/config.json in a
        Setup tab, waits for them, then types `--run` into a new terminal. If setup fails, the row stays, the
        command is not run, and `row new` exits 1. `row rm` runs teardown first, then removes the worktree.

        ## Terminals

            canopy term list [--all]                      ID, row, tab, process, title, and folder
            canopy term new [--tab <name> | --new-tab] [--run <cmd>] [--title <t>]
            canopy term send <id> <text> [--enter]        type text, then Return with --enter
            canopy term read <id> [--lines N]             the screen, or the last N lines with scrollback
            canopy term close <id> [--force]              --force if a program still runs in it

        Terminal IDs such as p12 stay unique across relaunches. `term send`, `read`, and `close` never start Canopy.

        ## Pull requests

            canopy pr [<branch>] [--refresh]              the row's PR: number, state, title, and URL

        Canopy looks up PRs with your `gh` login for its own and adopted rows, about once a minute and more often
        right after a push. `--refresh` asks GitHub now, for example right after `gh pr create`.
        `row list --json` also carries each row's PR as "pr" when it has one.

        ## Examples

        Start a parallel agent on a fix in its own row, then check on it:

            pane=$(canopy row new fix/login-redirect --run 'claude "fix the login redirect, ticket FL-123"' --json | jq -r .pane)
            canopy term read "$pane" --lines 40

        Run a dev server in its own tab of your row and watch it:

            pane=$(canopy term new --tab Server --run 'bun dev' --title 'dev server' --json | jq -r .pane)
            canopy term read "$pane"

        Clean up when the work is merged:

            canopy row rm fix/login-redirect --delete-branch
        """
}
