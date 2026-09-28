# Canopy v1 design

Date: 2026-09-27
Status: approved 2026-09-27

## Summary

Canopy is a macOS app for working across many git worktrees at once.
It is terminal-first: each worktree gets tabs, and each tab holds a grid of terminals.
It is built to be driven by AI agents as much as by hand.
An agent in one worktree can create another worktree, start an agent in it, and check on it later, all through a CLI.

Canopy replaces Superset and Conductor in its author's daily flow.
It is a personal tool first, not a product.

## Glossary

- **Repo**: a git repository registered with Canopy, identified by the path of its main checkout.
- **Row**: one git worktree shown in the sidebar.
  The main checkout is also a row.
- **Tab**: a named page inside a row that holds a grid of terminals.
- **Pane**: one terminal inside a tab's grid.

## Goals

1. A sidebar of rows grouped by repo, showing each row's PR state.
2. A ports panel listing every port a row is listening on, grouped by row, with controls to stop them.
3. Tabs per row and a tiling grid of terminals per tab, with automatic placement, drag to rearrange, and drag to resize.
4. A `canopy` CLI that lets agents create and remove rows, open terminals, run commands in them, read their screens, and query activity.
5. An activity log that records what happened each day, so a future central AI can summarize the day.
6. A normal workday can be done entirely in Canopy.

## Non-goals for v1

- Keeping terminal processes alive when the app quits.
  Canopy is a single process by decision.
- Restoring scrollback after relaunch.
- The central AI, ticket integration, and day summaries.
  v1 only provides the CLI and the activity log they will build on.
- Git hosts other than GitHub.
- Command logging for shells other than zsh.
- Mapping Docker-published ports to rows.
- Moving panes between tabs or rows.
- Code signing with a Developer ID, notarization, and auto-update.
- Linux and Windows.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Stack | Swift 6, SwiftUI plus AppKit, SwiftTerm | Native and small, builds with Command Line Tools only. SwiftTerm is actively maintained. |
| Terminal engine | SwiftTerm behind a `TerminalEngine` interface | SwiftTerm's CPU renderer is the main risk under heavy agent redraw. The interface keeps libghostty available as a fallback. |
| Process model | Single process | Simpler. Processes die on quit, and layouts are restored on relaunch. |
| Repos | Many, grouped in the sidebar | The author works across several repos daily. |
| Row visibility | Main checkout, Canopy's folder, and adopted rows. Everything else collapsed. | One repo already has 30 worktrees from other tools. |
| Storage | `state.json` plus daily JSONL activity files | Both are small, single-writer, and readable by agents with `cat` and `jq`. SQLite waits until there is a query it serves. |
| Merging | The author reviews and merges every PR | The author wants to see every step. |

Alternatives considered for the stack:
Swift plus libghostty has the best terminal but relies on an embedding API Ghostty marked internal and unversioned in August 2026, and needs full Xcode 26 plus Zig to build.
Tauri plus xterm.js is what Conductor uses, but WKWebView caps WebGL contexts at 16 per page, has rendering corruption on macOS 26.5 without an xterm.js beta, and has open keyboard and IME bugs.
Electron is too heavy.

## Architecture

One Swift package with three targets.

- **`CanopyCore`** (library): all logic, no UI.
  Git access, worktree discovery and classification, repo config, PR lookup, port scanning, grid layout math, state storage, the activity log, and the control protocol types.
  Most tests live here.
- **`CanopyApp`** (app executable, renamed `Canopy` inside the bundle): the UI and the control server.
  SwiftUI draws the sidebar, tab bar, and window chrome.
  AppKit draws the terminal grid, because drag, drop, and resize need view-level control.
  SwiftTerm runs behind the `TerminalEngine` interface.
- **`CanopyCLI`** (CLI executable, product `canopy`): a thin client that sends requests to the app over a Unix socket.

The targets are not named `Canopy` and `canopy` because the default macOS file system ignores case, so the two build products would overwrite each other.

`make app` builds `Canopy Dev.app` and `make release` builds `Canopy.app`.
Both assemble the bundle with its `Info.plist`, place the CLI at `Contents/Resources/bin/canopy`, and sign it.
Signing uses a local self-signed certificate named "Canopy Dev" rather than ad hoc signing.
A stable signing identity keeps macOS privacy permissions from resetting on every rebuild.
`make signing-cert` creates the certificate in the login keychain once, and `make app` fails with a pointer to it if the certificate is missing.
`make install` copies the app to `~/Applications` and links the CLI into `~/.local/bin`.

### Data folder

Everything lives in `CANOPY_HOME`, which defaults to `~/.canopy`.

```
~/.canopy/
  state.json                 repos, adopted paths, row order, layouts
  config.json                global settings
  canopy.sock                control socket
  worktrees/<repo>/<slug>/   rows created by Canopy
  activity/2026-09-27.jsonl  activity log, one file per local day
  shell/zsh/                 zsh startup shim for command logging
```

The folder is created with mode 0700, and the socket and log files with mode 0600.

Dev builds use bundle ID `com.ne1nn.Canopy.dev` and `CANOPY_HOME=~/.canopy-dev`.
Release builds use `com.ne1nn.Canopy` and `~/.canopy`.
A dev build therefore never touches the instance the author is working in.

### Window layout

```
+------------------------+------------------------------------------------+
| solis-v1            +  | [Terminal] [Server] [+]                         |
|   main                 | +----------------------+----------------------+ |
|   fix/thai-overlay     | | claude               | zsh                  | |
|   fix/automation  #412 | |                      |                      | |
|   > Other worktrees 28 | |                      |                      | |
| canopy              +  | +----------------------+----------------------+ |
|   main                 | | bun dev                                     | |
|                        | |                                             | |
| PORTS                  | +---------------------------------------------+ |
| fix/thai-overlay     x |                                                 |
| [3000 x] [3001 x]      |                                                 |
+------------------------+------------------------------------------------+
```

## Repos and rows

### Registering repos

A repo is added from the UI or with `canopy repo add <path>`.
If the path is a linked worktree, Canopy resolves it to the main checkout.
A repo's display name is its folder name.
If two repos share a folder name, the parent folder name is added to tell them apart.
Removing a repo only unregisters it and never touches files.

### Discovery

Git decides which worktrees exist.
Canopy runs `git worktree list --porcelain` for each repo and never keeps its own list of worktrees.

Canopy watches each repo's git folder with FSEvents.
Changes under `.git/worktrees/`, to `.git/HEAD`, or to any worktree's `HEAD` trigger a refresh, debounced to 200 ms.
A worktree created anywhere, by anyone, therefore appears within a second.
A branch switch inside a row renames the row the same way.

### Classification

Each worktree gets exactly one class.

- **main**: the repo's main checkout.
- **canopy**: its path is under `CANOPY_HOME/worktrees/<repo>/`.
- **adopted**: its path is in the repo's adopted list in `state.json`.
- **external**: everything else.
  It is tagged "Superset" if its path is under `~/.superset/`, "Conductor" if under `~/conductor/`, and "other" otherwise.

A worktree whose folder is gone, or that git reports as prunable, is shown as missing with a Prune action.

### Sidebar order

Each repo group lists the main row first.
Canopy and adopted rows follow, in the order Canopy first saw them, so new rows appear at the bottom.
That order is saved in `state.json`.
External rows sit in a collapsed "Other worktrees (N)" group at the bottom of the repo.
Clicking an external row adopts it and selects it.

### Creating a row

From the `+` button next to a repo, or `canopy row new <branch>`:

1. Run `git fetch origin`.
2. Pick the folder `CANOPY_HOME/worktrees/<repo>/<slug>`, where the slug is the branch name with `/` replaced by `-`.
   If the folder exists, append `-2`, `-3`, and so on.
3. Run `git worktree add`:
   - If the branch exists locally, check it out.
   - Else if `origin/<branch>` exists, create a local branch tracking it.
   - Else create the branch from `--from <ref>`, defaulting to `origin/<default branch>`.
4. Run the repo's setup commands, if any, in a tab named "Setup".
5. Select the row if it was created from the UI or with `--select`.
   CLI-created rows do not steal focus by default.

If setup fails, the row still exists and the Setup tab stays open showing the failure.

### Removing a row

The `x` on a row, or `canopy row rm <branch>`:

- **canopy rows**: run teardown commands, close the row's terminals, then `git worktree remove`.
  If the worktree has uncommitted changes, the confirmation says so and offers Force remove.
  An "Also delete branch" option runs `git branch -D` afterwards.
- **adopted rows**: un-adopt only.
  Canopy never removes a worktree another tool created.
- **main rows**: cannot be removed.

### Repo config

A repo can commit `.canopy/config.json`:

```json
{
  "setup": ["cp \"$CANOPY_ROOT_PATH/.env.local\" .env.local", "bun install"],
  "teardown": ["docker compose down"]
}
```

Commands run in order with the row folder as working directory, and stop at the first failure.
They get these environment variables:

| Variable | Value |
|---|---|
| `CANOPY_ROOT_PATH` | the repo's main checkout |
| `CANOPY_ROW_PATH` | the row's folder |
| `CANOPY_REPO` | the repo's display name |
| `CANOPY_ROW` | the row's branch |

## Sidebar rows

A row line reads, left to right: icon, branch name, then a right-aligned PR number when a PR exists.

- The icon is a branch glyph when the row has no PR, and a pull request glyph when it has one.
- The PR glyph and number are colored by state:
  green for open, gray for draft, purple for merged, red for closed.
- Clicking the PR number opens the PR in the default browser.
  Clicking anywhere else on the row selects it.
- On hover, the PR number slides left to make room for the row's shortcut hint (`⌘8`) and an `x`.
- The selected row has a rounded highlight.
- `⌘1` to `⌘9` select the first nine visible rows across all repos, in sidebar order.
- A detached HEAD shows the short commit hash in place of a branch name.

## Terminals

### Engine interface

`CanopyCore` defines the engine interface, and the app provides the SwiftTerm implementation.
A session exposes:

- its NSView, its shell PID, and its current title
- writing input and resizing
- reading the visible screen and the last N lines of scrollback as plain text
- events for title changes, bell, and process exit with code

Nothing outside the SwiftTerm implementation imports SwiftTerm.

### Starting a shell

Each pane runs the user's login shell (`$SHELL -l`) in the row's folder, or in a saved folder when restoring.
The environment adds:

| Variable | Value |
|---|---|
| `TERM` | `xterm-256color` |
| `COLORTERM` | `truecolor` |
| `TERM_PROGRAM` | `Canopy` |
| `CANOPY_HOME` | the data folder |
| `CANOPY_REPO`, `CANOPY_ROW`, `CANOPY_ROW_PATH` | the pane's row |
| `CANOPY_PANE` | the pane ID, such as `p12` |
| `PATH` | the bundle's CLI folder prepended |

Agents inside any Canopy terminal can therefore run `canopy` without arguments naming the repo or row.

The font is the system monospaced font at 13 points.
Colors follow the system light or dark appearance.
Scrollback holds 10,000 lines per pane.

### Pane chrome

Each pane has a thin header with its title and a close button.
The title comes from the running program when it sets one, and falls back to the foreground process name.
The header is the drag handle.
The focused pane's header is highlighted.

### Process exit

When a pane's shell exits, the pane shows "exited (code N)".
Enter restarts the shell in the same folder, and `⌘W` closes the pane.

### Hidden panes

Switching rows or tabs removes panes from the window but keeps their sessions running.
Hidden panes cost no drawing, and their screens stay readable through the CLI.

### Quitting

If any pane's foreground process is something other than its shell, quitting asks for confirmation and lists them, for example "3 terminals are running processes."

## Tabs and the grid

### Tabs

Each row has its own tab bar.
Its right end has a split button, which adds a pane like `⌘D`, and a `+` button, which opens a tab like `⌘T`.
New tabs are named "Terminal", "Terminal 2", and so on, or take the name given with `--tab`.
Double-clicking a tab renames it.
Selecting a row that has no tabs opens one tab with one pane.
Closing a tab's last pane closes the tab.

### Layout model

A tab's layout is a tree.
A node is either a pane or a split.
A split has an axis, `row` (children left to right) or `column` (children top to bottom), a list of children, and a fraction for each child that sums to 1.
After every operation the tree is normalized: a split with one child is replaced by that child, and a split nested directly inside a split of the same axis is merged into it.

### Adding a pane

The add rule fills the bottom line of panes to the right until panes would get too narrow, then starts a new line below.

1. If the tab is empty, the new pane is the whole layout.
2. Take the lines: the root's children if the root is a `column` split, otherwise just the root.
3. Take the last line.
   Count the panes it would hold after adding one: its child count plus one if it is a `row` split, otherwise 2.
4. If the tab's width divided by that count is at least the minimum pane width, add the pane to the end of the last line and make that line's fractions equal.
   A last line that is not a `row` split becomes one, holding the old line and the new pane.
5. Otherwise add the pane as a new line at the bottom of the root, wrapping the root in a `column` split if needed, and make the line heights equal.

The minimum pane width is 80 columns in the current font plus pane padding.
It is configurable as `minPaneColumns` in `config.json`.

```
wide:   [A] -> [A|B] -> [A|B|C] -> [A|B|C]
                                   [  D  ]
narrow: [A] -> [A|B] -> [A|B] -> [A|B]
                        [ C ]    [C|D]
```

### Resizing

Dragging a divider changes the fractions of the two neighbors.
Manual resizing clamps each pane to at least 20 columns and 5 rows.

### Rearranging

Dragging a pane by its header shows drop zones on the pane under the cursor.
The outer quarter of each edge is a drop zone for that side, and the center is a swap zone.

- Dropping on an edge removes the dragged pane from the tree, then splits the target pane on that side, 50/50.
- Dropping on the center swaps the two panes.
- Dropping anywhere else cancels.

### Closing

Closing a pane removes it from the tree and hands its space to its siblings in proportion to their fractions.
If the pane's foreground process is not its shell, closing asks for confirmation.

### Keys

| Key | Action |
|---|---|
| `⌘T` | new tab |
| `⌘D` | add a pane using the add rule |
| `⌘W` | close the focused pane |
| `⌘⇧[` and `⌘⇧]` | previous and next tab |
| `⌘⌥` plus an arrow | focus the neighboring pane in that direction |
| `⌘1` to `⌘9` | select a row |

## Persistence

`state.json` holds:

- registered repos, each with its adopted paths and row order
- per row: its tabs, each tab's layout tree, each pane's folder, and the selected tab
- the selected row, the sidebar width, and whether the ports panel is collapsed
- a `version` number for future migrations

It is written through a temp file and an atomic rename, debounced to one second after a change, and again on quit.
Each pane's folder is read from its shell process at save time, so a `cd` is remembered.
On launch, Canopy rebuilds every layout with fresh shells in the saved folders.
It never re-runs old commands.

If `state.json` fails to parse, Canopy renames it to `state.json.broken-<timestamp>`, starts fresh, and says so.
Rows come from git, so only layouts are lost.

## PR badges

For each repo, Canopy makes one `gh api graphql` call.
The query has one aliased `pullRequests(headRefName:)` field per canopy or adopted row, ordered by last update, and only counts PRs whose head repository is the repo itself, so forks with the same branch name are ignored.
Main rows and external rows are not looked up.

A row's PR is its open PR if there is one, otherwise its most recently updated PR.
The state maps to the badge color as described above, with an open draft shown as draft.

Refresh triggers:

- every 60 seconds
- when the window gains focus, at most once every 15 seconds
- every 10 seconds for two minutes after a push is detected.
  Canopy watches the reflogs of remote-tracking branches in `.git/logs/refs/remotes/`, where git records each push as `update by push`.
  Fetches and pulls move the same branches but are not pushes, so they do not count.
- `canopy pr --refresh`

If `gh` is missing or not logged in, badges are hidden and the repo header shows a warning with the fix, such as `gh auth login`.
The GitHub repo is taken from the `origin` remote.
Repos whose `origin` is not on GitHub show no badges.

## Ports

### Scanning

Every 2 seconds while the window is visible, and on demand for the CLI, Canopy lists every TCP socket in the listening state owned by the current user.
It reads this with libproc (`proc_listpids`, `proc_pidinfo`, `proc_pidfdinfo`) rather than running `lsof`.
IPv4 and IPv6 sockets on the same port and process count as one port.
Ports in the system's random range (49152 and up by default) are left out.
Programs get those when they ask for any free port, as agents' MCP servers and debuggers do, and they are not servers to open or stop.

### Attribution

A port belongs to at most one row, decided in this order:

1. If the owning process descends from one of a row's pane shells, it belongs to that row.
2. Otherwise, if the owning process's working folder is inside a row's folder, it belongs to that row.
   When row folders are nested, the deepest match wins.
3. Otherwise it is not shown.

A row can own any number of ports.

### Panel

The ports panel sits at the bottom of the sidebar and can collapse.
It groups ports under their row's branch name, ordered like the sidebar, with ports sorted by number.

```
feat/new-feature                x
[3000 x] [3001 x] [3002 x]

feat/new-feature-2              x
[4173 x] [4175 x]
```

- Clicking a branch heading selects that row.
- Clicking a badge opens `http://localhost:<port>`.
- Hovering a badge shows the process name and PID.
- A badge's `x` stops the process listening on that port.
  Its tooltip names the process, because stopping it also closes any other ports it holds.
- A group's `x` stops every process holding a port in that row.
- Stopping sends SIGTERM, then SIGKILL if the port is still listening after 3 seconds.
- Badges wrap onto new lines.

## Control API

### Transport

The app listens on `CANOPY_HOME/canopy.sock`.
Messages are newline-delimited JSON, one request and one response per line.

```json
{"v": 1, "id": "7f3c", "method": "row.new", "params": {"branch": "fix/x", "run": "claude"}}
{"v": 1, "id": "7f3c", "result": {"row": {"repo": "solis-v1", "branch": "fix/x", "path": "..."}, "pane": "p12"}}
{"v": 1, "id": "7f3c", "error": {"code": "branch_exists", "message": "..."}}
```

A request with an unknown `v` gets a `version_mismatch` error.
The CLI ships inside the app bundle, so versions only drift when an old linked CLI is used.

If the CLI cannot connect, it launches the app in the background with `open -g -b <bundle id>` and waits up to 10 seconds for the socket.

### Target resolution

Commands that act on a repo or row resolve their target in this order:

1. An explicit `--repo` or `--row`, where a row can be a branch name or a path.
2. `CANOPY_REPO` and `CANOPY_ROW_PATH` from the environment.
3. The worktree containing the current folder, if its repo is registered.
4. Otherwise the command fails and names the missing flag.

A branch name that matches rows in several repos requires `--repo`.

### Commands

Every command accepts `--json` for machine output and prints readable text by default.
Every command exits non-zero on failure.

| Command | Effect |
|---|---|
| `canopy status` | whether the app is running, its version, and `CANOPY_HOME` |
| `canopy repo add <path>` | register a repo |
| `canopy repo list` | list repos |
| `canopy repo rm <name>` | unregister a repo |
| `canopy row list [--all]` | list rows, including external ones with `--all` |
| `canopy row new <branch> [--from <ref>] [--run <cmd>] [--no-setup] [--select]` | create a row, run setup, and optionally start a command in a new pane after setup succeeds |
| `canopy row rm <branch> [--force] [--delete-branch]` | remove or un-adopt a row |
| `canopy row select <branch>` | select a row in the UI |
| `canopy row adopt <path>` | adopt an external worktree |
| `canopy term list [--all]` | list panes with ID, row, tab, title, folder, and foreground process |
| `canopy term new [--tab <name> \| --new-tab] [--run <cmd>] [--title <t>]` | add a pane using the add rule and optionally run a command |
| `canopy term send <id> <text> [--enter]` | write text to a pane, optionally followed by Enter |
| `canopy term read <id> [--lines N]` | print the visible screen, or the last N lines including scrollback, as plain text |
| `canopy term close <id> [--force]` | close a pane |
| `canopy ports [--all]` | list ports for the resolved row, or for all rows with `--all` or when no row resolves |
| `canopy ports stop <port>` | stop the process holding a port |
| `canopy pr [--refresh]` | show the current row's PR |
| `canopy log [--since <when>] [--until <when>] [--type <t>]` | print activity events, from 24 hours ago by default |
| `canopy agent-guide` | print a manual written for agents |

`canopy log` reads the activity files directly, so it works while the app is not running.
Times can be a span back from now such as `30m`, `2h`, or `3d`, `today`, `yesterday`, a date, a local date and time, a time today, or a full ISO 8601 timestamp.
`--type` takes a type such as `term.command`, or a kind such as `row` for every row event.

`canopy agent-guide` explains rows, target resolution, and the commands, with worked examples such as spawning a parallel agent:

```
canopy row new fix/login-redirect --run 'claude "fix the login redirect, ticket FL-123"'
canopy term read p12 --lines 40
```

One line in a global `CLAUDE.md` pointing at `canopy agent-guide` is enough for any agent to learn Canopy.

## Activity log

### Format

Each event is one JSON line appended to `CANOPY_HOME/activity/<local date>.jsonl`.

```json
{"ts": "2026-09-27T21:15:03.123+10:00", "type": "row.created", "repo": "solis-v1", "row": "fix/login", "path": "...", "source": "cli", "data": {"class": "canopy"}}
```

`source` is `ui` for what is done in Canopy's window, including commands typed in its terminals, `cli` for a `canopy` command, or `git` for a change Canopy noticed rather than made, such as git run in any terminal, Canopy's own included, or a PR changing on GitHub.
`repo`, `row`, and `path` are left out when an event is not about one, as for `cli.call`.
One writer in the app serializes all appends.
Readers skip a trailing partial line and any line they cannot read.

### Events

| Type | Recorded when | `data` |
|---|---|---|
| `repo.added`, `repo.removed` | a repo is registered or unregistered | |
| `row.created`, `row.adopted`, `row.removed` | a row appears, is adopted, or goes away, including being un-adopted | `class` |
| `row.branch_changed` | a row's HEAD moves to another branch | `from`, `to`, null when detached |
| `pr.opened` | a row's branch goes from no PR, or a closed one, to a new PR | `number`, `title`, `state`, `url` |
| `pr.state_changed` | a PR moves between draft, open, merged, and closed | `number`, `from`, `to`, `url` |
| `term.opened`, `term.exited` | a pane's shell starts, including a restart, or exits | `pane`, `code` |
| `term.command` | a command finishes in a zsh pane | `pane`, `cmd`, `cwd`, `exit`, `durationMs` |
| `cli.call` | a `canopy` request changes something | `method`, `params`, `error` when it failed |

Row and PR changes are found by comparing each worktree list and each PR lookup with the one before.
The first one after launching or adding a repo only sets the baseline, so what already existed is not logged.
A PR lookup `gh` could not make keeps the baseline, so PRs coming back after `gh auth login` are not logged as new.
Among closed PRs a branch shows the most recently updated, so one closed PR taking over from another is not an opening.

git lists a worktree halfway through `git worktree add` with a detached, all-zero HEAD, so such a row is compared only once it is whole.
When Canopy creates, removes, or prunes a row itself, it marks the path with the source that asked before calling git, and refreshes leave the path alone until the operation ends.
The operation then logs how the row ended up, so each row change is logged once with the right `source`.
If git reports the main checkout somewhere other than where it was registered, the folder moved while git ran, and the repo shows as missing.

`cli.call` leaves out requests that only read: `status`, `repo list`, `row list`, `term list`, `term read`, `ports`, and `pr`.
Agents poll some of them every few seconds, which would bury everything else.

### Command logging

Canopy starts zsh with `ZDOTDIR` pointing at `CANOPY_HOME/shell/zsh`.
The `.zshenv` there puts `ZDOTDIR` back and sources the user's own `.zshenv`, so zsh then reads the user's `.zprofile`, `.zshrc`, and `.zlogin` from their usual place, and the user's setup is unchanged.
It adds `preexec` and `precmd` hooks.
After each command, `precmd` prints one private OSC 6973 sequence carrying the command, the folder it started in, its exit code, and its duration, percent-encoded.
The pane reads these from its output before the terminal engine draws it, and records `term.command`.

Each shell gets a random token in `CANOPY_COMMAND_TOKEN`.
The shim takes it out of the environment and puts it in every report, so output that happens to replay a report, such as `cat` of a recorded session, is ignored.
Each hook puts the other back if the user's `.zshrc` replaces its list, and the app writes the shim again before starting zsh if it went missing, since zsh pointed at an empty folder would skip the user's startup files.
A zsh started inside the pane, including `exec zsh`, runs without the shim, so its commands are not logged.

The shim sends no OSC 133 marks.
SwiftTerm acts on them, and a prompt mark sent from `precmd` starts a fresh line before zsh can show its `%` after output that did not end in a newline.
Nothing in Canopy reads them yet.

Commands can contain secrets.
The log never leaves the machine and only the user can read it.
A command starting with a space is left out when the user has `hist_ignore_space` set, and one matching `HISTORY_IGNORE` is left out too, as zsh keeps both out of the history file.
`zshaddhistory` hooks are not consulted.
`cli.call` events leave out `run` and `text` params that start with a space for the same reason.
`"logCommands": false` in `config.json` turns command logging off from the next launch: zsh starts without the shim, and `cli.call` events leave out the `run` and `text` params.

## Error handling

- **Git and setup failures**: the UI shows git's message in a toast.
  The CLI exits non-zero, and with `--json` prints `{"error": {"code", "message"}}`.
- **Missing repo folder**: the repo group shows "missing" with Locate and Remove.
- **Missing worktree folder**: the row shows "missing" with Prune.
- **`gh` unavailable**: covered under PR badges.
- **Shell exits**: covered under Terminals.
- **Corrupt `state.json`**: covered under Persistence.
- **App cannot launch from the CLI**: the CLI reports the path it tried and exits non-zero.

## Testing

- **Unit tests** use Swift Testing, since XCTest needs full Xcode.
  They cover the layout tree (add rule, resize clamps, drag moves, close, normalization), worktree classification, repo config parsing, PR selection, port attribution against a fake process table, protocol encoding, and activity log reading.
- **Git tests** run against real temporary repositories.
- **End-to-end tests** launch a dev build with `CANOPY_HOME` pointed at a temporary folder and drive it through `canopy`.
  The agent API doubles as the test driver.
  Screenshots of the window cover the UI.
- **Lint**: `swift format lint --strict`.
- **CI**: GitHub Actions on a macOS runner runs build, unit tests, and lint.
  macOS minutes on private repos cost ten times more, so end-to-end tests run locally.

## Delivery

Each item lands as its own branch and PR.
Branches and commit messages use conventional prefixes: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`.
PRs are squash-merged by the author after review.
`main` is protected and cannot be pushed to directly.

1. `docs`: this spec and the implementation plan.
2. `chore`: package scaffold, `make app`, signing, CI, and lint.
3. `feat`: repos and rows in the sidebar, with discovery, classification, adoption, and `⌘1` to `⌘9`.
4. `feat`: control socket, and the `canopy repo` and `canopy row` commands.
5. `feat`: terminals and tabs, plus setup and teardown, which run in a visible terminal tab.
6. `feat`: the grid, with the add rule, drag, resize, and restore on relaunch.
7. `feat`: `canopy term` commands and `canopy agent-guide`.
8. `feat`: PR badges.
9. `feat`: the ports panel.
10. `feat`: the activity log, the zsh shim, and `canopy log`.

Between PR 1 and PR 2 comes a throwaway spike that is never merged.
It runs Claude Code inside a minimal SwiftTerm window and checks rendering, speed under heavy output, screen reading, shell PID access, and custom OSC handling.
Findings are reported with screenshots before anything is built on SwiftTerm.
If SwiftTerm fails, a follow-up `docs` PR amends this spec before PR 2.

## Risks

- **SwiftTerm under heavy redraw.**
  Mitigated by the spike and the engine interface.
  The fallback is libghostty, pinned the way cmux pins it.
- **AppKit drag and drop for the grid** is the largest piece of UI work.
  The layout math lives in `CanopyCore` as pure functions so it can be tested without UI.
- **Single process** means quitting stops every agent.
  Mitigated by the quit confirmation and dev builds with their own data folder.
- **Private OSC handling in SwiftTerm** is not needed.
  Panes read the shim's command reports from the output before the engine draws it, so logging works whatever the engine.
