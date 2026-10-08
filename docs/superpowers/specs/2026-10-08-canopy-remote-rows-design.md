# Canopy remote rows

Date: 2026-10-08
Status: design approved in conversation 2026-10-08

## Summary

A registered repo can have rows whose worktree lives on another machine, reached with `ssh`.
The author's case is an AWS box, `hindie-box`, where agents run while Canopy on the Mac stays the place they are driven from.
A remote row sits among its repo's local rows with a server mark, and its terminals open on the box in its worktree.
Programs in them run inside tmux on the box, so an agent keeps working while the Mac sleeps, and Canopy reattaches when it reconnects.
Agents on the box get the whole `canopy` CLI through a small relay, so agent dots, `term send`, and `row new` work there as they do locally.
Remote rows get PR badges from the Mac's own `gh`, and their dev servers' ports show in the ports panel and are forwarded to the Mac on their own.
A box that is off is started with a command the author configures, and panes that sit idle detach so the box can power itself off.

## Goals

1. `canopy row new <branch> --on <host>`, or the New Row sheet, makes a worktree on the host and a row for it in the repo's section.
2. A remote row's terminals open in its worktree on the host, and survive the Mac sleeping, losing the network, and Canopy quitting.
3. Agents on the host can use every `canopy` command, and Claude Code's hooks there drive the row's agent dots.
4. Remote rows show their PR badges, and their listening ports, forwarded to the same port on the Mac when it is free.
5. A host that is off is started when Canopy needs it, and a host Canopy is not using is let go, so it can power itself off.
6. Nothing about local rows changes.

## Non-goals

- Cloning a repo onto a host.
  The clone must exist, and `canopy host add` says so when it does not.
- Remote repos with no local clone, and a host's own worktrees that Canopy did not make.
- Running a repo's setup and teardown commands in remote rows.
- Logging the commands typed in remote terminals.
  The zsh shim is local, and the host may not have zsh.
- Managing hosts from the window.
  Hosts are added once, with the CLI.
- Copying files between the Mac and a host, and opening a remote row in Finder or an editor.
- Hosts that are not Linux.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Shape | Rows of a local repo, marked with their host | The author's work is "this branch of solis-v1, on the box". PR badges, groups, ordering, and the New Row sheet come from the repo. |
| A remote row's identity | A stand-in folder on the Mac, `CANOPY_HOME/remote/<host>/<repo>/<slug>` | Selection, layouts, groups, agent state, and saved terminals are keyed by local path, and `Paths.canonical` would rewrite a path like `/home/ubuntu/…` through this Mac's `/home` symlink. Two hosts can hold the same remote path. |
| Persistence | Each pane is a tmux session on the host | An agent keeps running while the Mac sleeps or Canopy quits, and Canopy reattaches. |
| Connection | One ssh master per host, owned by the app | A pane opens in about 0.1 s through the master rather than 1 s through a fresh Session Manager handshake, and the app decides when the host is let go. |
| Agents on the host | The whole `canopy` CLI, through a relay that runs the app's own CLI on the Mac | The author's choice. The CLI is a macOS program, and a relay keeps the host's CLI the same version as the app without a Linux build. |
| Trust | Anything on the host can drive Canopy as a local agent can | The author's choice, which follows from the whole CLI. |
| Idle hosts | Panes detach after 30 minutes with no program running and no typing | The author's choice, so the box's idle power-off can run while Canopy stays open. |
| Ports | Forwarded on their own as they appear | The author's choice, so `localhost:5173` opens the box's dev server. |
| Setup and teardown | Not run in remote rows | solis-v1 has none, and running them remotely needs the setup pane to run on the host. |
| Host management | CLI only | A host is set up once. |

## Hosts

### Config

`config.json` gains `hosts`, keyed by the ssh alias:

```json
"hosts": {
  "hindie-box": {
    "repos": { "solis-v1": "/home/ubuntu/Projects/fastlane/solis-v1" },
    "wake": "aws ec2 start-instances --profile lyra --instance-ids i-069bf8c49e5f996ab",
    "idleDetachMinutes": 30
  }
}
```

`repos` maps a registered repo's name, as `canopy row new --repo` takes it, to its clone's absolute path on the host.
Names are matched as the Tickets plugin's `repo` is: exactly, then by the repo whose path ends in the name.
`wake` is optional, run with the author's login shell on the Mac when the host cannot be reached.
`idleDetachMinutes` is optional, 30 by default, and 0 turns detaching off.
A host whose section cannot be read is left out, with a warning in `canopy host list`, and the others still load.

### Adding a host

`canopy host add <alias> --repo <repo>=<path>... [--wake <command>] [--idle-detach <minutes>]` connects to the host and checks, in order:

1. ssh reaches it, running `wake` first when it does not, as below.
2. It is Linux, and has `git`, `tmux` 3.0 or later, and `python3`.
3. Each `<path>` is a git checkout, given as `~/…` or absolute and saved absolute.
4. Each `<repo>` is a registered repo.

Then it installs Canopy's files on the host, writes Canopy's hooks into the host's Claude Code settings, and saves the host.
A check that fails saves nothing and names the fix.
Running it again for a host that exists updates its repos and options, and installs the files again.
`canopy host rm <alias>` refuses while the host has rows, naming them, and otherwise forgets it, leaving the host's files.

### Files on the host

Canopy keeps its files under `~/.canopy` on the host, each Mac's Canopy home in its own folder named by its id (below):

| Path | What |
|---|---|
| `~/.canopy/<home id>/bin/canopy-host` | one Python 3 script with four commands: `relay`, `probe`, `replay`, and `open` |
| `~/.canopy/<home id>/bin/canopy` | runs this home's `canopy-host relay` |
| `~/.canopy/<home id>/bin/xdg-open` | runs this home's `canopy-host open`, first on its remote panes' PATH |
| `~/.canopy/<home id>/tmux.conf` | Canopy's tmux settings |
| `~/.canopy/<home id>/files-version` | the version of this home's files |
| `~/.canopy/<home id>/app.sock` | the app's relay socket, forwarded from the Mac while the host is connected |
| `~/.canopy/<home id>/pending/` | agent reports the relay could not deliver |
| `~/.canopy/bin/canopy` | the same for every home and version: runs `~/.canopy/$CANOPY_HOME_ID/bin/canopy`, and outside a Canopy pane fails with "Run canopy in a Canopy terminal on this host." |
| `~/.local/bin/canopy` | a link to `~/.canopy/bin/canopy`, made when nothing else is there, so login shells and shells that reorder PATH find it |
| `~/.canopy/worktrees/<repo>/<slug>` | remote rows' worktrees, named as local rows' folders are |

A home's scripts and `tmux.conf` carry the app's version, and are installed again whenever the app connects and finds another version in `files-version`.
So two homes with different builds on one host, such as the release app and a dev build, never replace each other's files.
The shared `~/.canopy/bin/canopy` has no version, and is written only when it differs.
Builds from before homes had their own folders kept their files in `~/.canopy/bin` and `~/.canopy/tmux.conf`, and those are left for any such build still using them.
A Mac's Canopy home has an id, 8 random hex digits made the first time and kept in `CANOPY_HOME/home-id`.
It is not derived from the Mac's host name, which macOS changes with the network: a new id would leave running sessions in a tmux server the panes no longer look for.
The tmux server is `-L canopy-<home id>` and the forwarded sockets are named with it, so a dev build and the release app never share sessions on one host.

### The connection

The app runs one ssh master per host, `ssh -M -N` with `ControlPersist=no`, as a child it stops itself.
Its control socket is `CANOPY_HOME/ssh/<home id>-<host hash>` when that is under 104 bytes, and `/tmp/canopy-<uid>/` otherwise.
Every pane, git call, probe, and forward runs through it, and never around it: each has `-o ProxyCommand=/usr/bin/false`, which ssh only uses when the master is gone or refuses a session.
sshd allows a few sessions per connection (`MaxSessions`, 10 unless set), and each attached pane holds one, so `host add` warns when the host allows fewer than 20.
The master starts when something needs the host, and stops once the host has no attached panes and nothing has used it for 10 minutes, or when its panes detach for idleness, or when the app quits.

A host is in one of these states, which `canopy host list` shows:

| State | Meaning |
|---|---|
| `connected` | the master is up |
| `connecting` | the master is starting |
| `waking` | `wake` ran and the master is retrying |
| `unreachable` | it could not connect, with ssh's message |
| `detached` | its panes detached for idleness |
| `idle` | not connected, and nothing needs it |

**Waking.** When the master fails to start and the host has `wake`, the app runs `wake` at most once every 2 minutes and retries every 10 seconds for 5 minutes.
Starting an instance that runs already changes nothing, so the app need not tell an instance that is off from a network that is down.
After 5 minutes the host is `unreachable` until something asks for it again.
A refused key, a changed host key, or a bad ssh config makes it `unreachable` at once, since no retry fixes those.
A name that does not resolve is retried, as the Mac may be offline for now; `host add` alone treats it as a typo when `~/.ssh/config` gives the alias no host name or proxy.

**Idle detach.** The app tracks, for each host, when a key was last typed into any of its panes and whether any of them runs a program.
Once none has run a program or been typed into for `idleDetachMinutes`, the app detaches the host's panes and stops the master.
A claude waiting at its prompt runs a program, which matches the box's own rule that a running claude keeps it on.

## Remote rows

### Making one

`canopy row new <branch> --on <host> [--repo <repo>] [--base <ref>] [--group <group>] [--run <command>] [--select]` makes a remote row.
The New Row sheet gains a "Where" pop-up, This Mac and each host whose `repos` has the repo, next to Group, and remembers the choice per repo.

The branch is chosen by the rules a local row uses, run against the host's clone through the master: a local branch on the host, fast-forwarded when only behind origin, then origin's, then a new branch from `--base` or origin's default branch.
The host's clone is fetched first, as the local clone is.
The worktree is made with `git worktree add` in `~/.canopy/worktrees/<repo>/<slug>` on the host, avoiding folders that exist there.
The app then makes the stand-in folder, with mode 0700, writes `remote.json` into it with the host and the remote path, and records the row.
A branch that a row on the same host holds fails with `branch_checked_out`, as locally.
A local row and a remote row can hold the same branch, since each machine's git only knows its own.
`--run` is sent to the first pane with `tmux send-keys` once its session exists.
When the branch has `.canopy/config.json`, the result notes that remote rows do not run setup.

### What Canopy saves

A repo's entry in `state.json` gains `remote`, its remote rows as last seen:

```json
"remote": [
  {
    "host": "hindie-box",
    "path": "/home/ubuntu/.canopy/worktrees/solis-v1/feat-x",
    "standIn": "/Users/me/.canopy/remote/hindie-box/solis-v1/feat-x",
    "branch": "feat/x",
    "head": "8ff389e7af…"
  }
]
```

The stand-in path is the row's path everywhere a row path is used, including `rowOrder`, groups, `selectedRowPath`, and `terminals`.
An older `state.json` without `remote` loads as having none.
A stand-in folder deleted outside Canopy is made again at launch and before a terminal opens.

### Listing

The snapshot puts remote rows among their repo's rows, with the row class `remote` and a `host`.
Reconciling the order with git's list keeps them, since local git never lists them.
The app reads the host's `git worktree list --porcelain` after each change it makes there, and every 30 seconds while the host is connected, and updates each row's branch and head.
A worktree the host no longer has marks its row missing, with Remove, as a local row whose folder is gone.
While the host is not connected, rows keep what was last seen, so Canopy never wakes a host to draw the sidebar.

### The sidebar

A remote row reads like a local one, followed by a server mark and the host's name in the secondary color.
Hovering shows the host and the remote path.
Remote rows take part in groups, dragging, `⌘1` to `⌘9`, and the arrow keys like local rows.

### Removing one

`canopy row rm <path>`, and Remove in the sidebar, check the remote worktree for uncommitted changes over ssh, refusing without `--force` as locally.
Then the app kills the row's tmux sessions, runs `git worktree remove` on the host, forgets the row, moves the stand-in folder to the Trash, and with `--delete-branch` deletes the branch on the host.
A host that cannot be reached fails the removal with `host_unreachable`, unless `--force`, which forgets the row and leaves the host's worktree, and says so.

## Terminals

### Attaching

A remote pane runs `canopy remote-attach` in its pty, in the stand-in folder, a hidden CLI command that:

1. asks the app over the control socket to connect the pane's host, and prints the host's state while it waits, such as "Starting hindie-box…";
2. runs `ssh -t` through the master, forwarding the pane's socket on the host (below) to the app, and runs on the host `tmux -L canopy-<home id> -f ~/.canopy/<home id>/tmux.conf new-session -A -s <session> -c <folder>`, with the pane's variables set in the session;
3. when ssh ends, asks the app what next.

The session is `p<pane number>`, and is saved with the pane, so a relaunched Canopy reattaches to the same running program.
The relaunched pane takes that number again, so the `CANOPY_PANE` that the session's programs have still names it.
`<folder>` is the remote row's path, or the folder the pane was last in when it is restored.
`new-session -A` makes a session that is gone, as after the host restarts, so the pane then starts a fresh shell where it was.

| ssh ended because | The pane |
|---|---|
| the remote shell exited, which ends the session | ends, as a local shell exiting does |
| the connection dropped | prints "Lost hindie-box, reconnecting…" and attaches again once the host is connected; keys typed meanwhile reach the session then, as type-ahead does |
| the master refused the session, as past `MaxSessions`, and refuses a command too | names `MaxSessions` and waits for Return |
| the panes detached for idleness | prints "Detached so hindie-box can sleep. Press Return to reconnect." and attaches again on Return |
| the host stayed unreachable | prints ssh's message and "Press Return to try again." |

The pane's variables on the host are those a local pane gets, with these differences:

| Variable | Value |
|---|---|
| `CANOPY_ROW_PATH` | the remote path |
| `CANOPY_ROOT_PATH` | the host's clone |
| `CANOPY_HOST` | the host's alias |
| `CANOPY_SOCKET` | the host's forwarded socket, `~/.canopy/<home id>/app.sock` |
| `CANOPY_CLI` | `~/.canopy/<home id>/bin/canopy` |
| `CANOPY_HOME_ID` | the home id, which names the home's folder on the host |
| `PATH` | `~/.canopy/<home id>/bin` first, so `canopy` and `xdg-open` are this home's |
| `CANOPY_HOME`, `ZDOTDIR` | not set |

### tmux

Canopy's `tmux.conf` hides the status bar, leaves the mouse to the outer terminal, sets `escape-time` to 0, passes titles and OSC 52 copies through, and turns off the alternate screen for the outer terminal, so lines scrolled off a session's single window go into Canopy's own scrollback.
Scrolling and selecting text then work as in a local pane.
After a reconnect only the current screen is drawn again, and older output is in tmux's copy mode.

### Busy state and titles

The local process of a remote pane is the attach command, so the app asks the host instead.
While a host is connected, the app runs `canopy-host probe` on it through the master every 2 seconds.
It prints, for each session of this home's tmux server, the foreground command, whether it is the shell, the session's folder, and its title.
It also prints `pending`, the panes with a hook report kept for this home, and the app replays each of them as "Reports that cannot be delivered" says, one host's at a time, without holding up the next probe.
A remote pane is busy while its foreground command is not its shell, which drives the close warnings, the agent state clearing when the program exits, and the pane's title.
Its folder is what saved terminals and `term list` record.

### Closing

Closing a remote pane, its tab, or its row kills its tmux session, asking first while it runs a program, as locally.
`term rm --force` and `row rm --force` skip asking.
Quitting Canopy and stopping the master only detach.

## The CLI on the host

### The relay

`~/.canopy/<home id>/bin/canopy` sends what it was run with to the app and prints the answer:

- It connects to `$CANOPY_SOCKET`, and outside a Canopy pane fails with "Run canopy in a Canopy terminal on this host."
- It sends one JSON line holding its version, its arguments, its working folder, the `CANOPY_*` variables, and, for a command that reads standard input on the Mac, that input when it is not a terminal, base64-encoded.
  Those commands are `agent-hook` and `ticket connect`, listed once in the app's code, from which the relay is written.
  Every other command sends none and reads none, so a command in a `while read` loop leaves the loop its lines, and a pipe that never closes, as from `tail -f`, holds nothing.
  `ticket connect` sends its first line alone, read a byte at a time within 10 seconds and 64 KiB, as the Mac's CLI reads a token.
- It waits for the app's acknowledgement, `{"ack": true}`, which the app sends as soon as it has read a request of the relay's version, before running it.
  sshd on the host accepts connections on the forwarded socket even while the Mac sleeps, or for the seconds a quit app's master lingers, so without one the relay could not tell an app that has its request from nothing at all.
  With no acknowledgement within 10 seconds, or with the connection ending first, it prints "Canopy is not reachable from this host right now." and exits 1.
- It reads one JSON line back holding stdout, stderr, and the exit status, writes them out, and exits with that status.
  It waits for that line as long as the command runs, since a command such as `term wait` may run long.
  While the command runs, the app writes a heartbeat, `{"alive": true}`, every 15 seconds, which the relay passes over.
  A Mac that sleeps or changes network can leave the host's sshd holding the connection for hours, so after 45 seconds with no line the relay prints that Canopy is not reachable and exits 1.
  A request of another version gets only that line, `relay_outdated`, so an older relay never reads a line it does not expect.

Each new connection to a host forwards `~/.canopy/<home id>/app.sock` on the host to the host's socket in the app, `CANOPY_HOME/hosts/<host hash>.sock`, through the master with `ssh -O forward -R`, removing a stale file at that path first.
One forward serves every pane on the host, since each request names its pane, and it lasts as long as the master.
sshd makes the socket readable by its user alone.
The app serves one request per connection on that socket and knows which host it came from.
It runs its own CLI with the arguments, with `CANOPY_HOME` set to its home, `CANOPY_PANE` as sent, and the row's stand-in in place of the remote row's path in `CANOPY_ROW_PATH` and in the working folder.
The relay sends how long ago it started, so `agent-hook` dates its report by when the hook ran on the host, not when the app ran the CLI.
A run whose relay hangs up is stopped.
A working folder outside the host's remote rows becomes the Canopy home, so the CLI targets nothing by folder.
The CLI's run ends when the connection closes, and has no terminal, so a command that prompts, such as `ticket connect`, reads standard input instead.
`row new` run through the relay without `--on` makes its row on the same host, and `--on local` makes a local one.
`hooks install`, `uninstall`, and `status` through the relay say the host's hooks are kept by `canopy host add`.

### Opening links

Claude Code on Linux opens links with `xdg-open`, and the remote panes' `~/.canopy/<home id>/bin/xdg-open` runs `canopy-host open`.
A claude.ai artifact link, by the rule the app uses for ⌘-clicks, becomes `canopy web open <url>` through the relay, so the artifact opens in the remote row.
Anything else goes to the next `xdg-open` on the PATH that is not one of Canopy's, and without one it fails as a missing `xdg-open` does.

### Hooks

`canopy host add` reads the host's `~/.claude/settings.json`, or the file in `$CLAUDE_CONFIG_DIR` there, adds Canopy's hooks with the same code `canopy hooks install` uses, and writes it back through a temporary file and a rename.
The hook command is unchanged, since `$CANOPY_CLI` names the relay on the host.

### Reports that cannot be delivered

Claude Code kills a hook at its timeout, 5 seconds, so `agent-hook` works to a budget counted from when the relay starts.
It reads its standard input for at most 1 second, and sends what arrived by then, so a pipe that never closes cannot hold it.
When it cannot reach the app, or the app does not acknowledge its request within 3 seconds of the relay starting, the relay saves the request in `~/.canopy/<home id>/pending/p<pane number>.json` on the host, replacing one already there, and exits 0, as a hook must.
A reply that comes without an acknowledgement means the app ran nothing, so the report is saved then too.
Once acknowledged, the report is the app's: the relay waits for the reply until 4 seconds after it started and exits 0 whatever comes, saving nothing.
An acknowledgement lost on its way back saves a report the app has run, so its replay runs it twice; that is rare, and better than losing it.
`canopy-host replay --pane p<n>` prints and removes the pane's saved request, and the app runs it as if the relay had just sent it.
The app replays a pane's report before answering `host.attach` with the ssh command, and whenever a probe lists the pane as pending.
After a short sleep the master can survive and no pane attaches again, and a report saved while the app was slow under load would otherwise wait for the next attach, so the probe replays most of them.
An agent that finished while the Mac slept therefore shows as done within a probe of Canopy reconnecting.

## Pull requests

Remote rows' branches join their repo's pull request lookups, which use the Mac's `gh` and the GitHub repo of the local clone's origin.
A remote row's head or branch changing in the 30-second listing looks the row's pull request up again, as a push does locally.

## Ports

While a host is connected, `canopy-host probe` also lists its listening TCP ports every 5 seconds, from `ss -ltnpH`, with each process's id, its ancestors' ids, and its folder.
A port belongs to the remote row one of whose tmux sessions the process descends from, or else to the remote row whose worktree holds the process's folder.
Ports that belong to no remote row are left out.

Each port found is forwarded through the master, `ssh -O forward -L`, to the same port on the Mac when that is free, and otherwise to the next free port above it.
The forward goes when the port stops listening on the host or the master stops.
The ports panel lists a remote row's ports under it with the server mark, and shows `5173 → 5174` when the Mac's port differs.
Clicking one opens the Mac's port in the browser.
Stopping one sends SIGTERM to its process on the host, never to the local ssh.
`canopy ports` lists them with `host` and `localPort`, and `ports stop` takes them.

## Commands

| Command | Method | Effect |
|---|---|---|
| `canopy host add <alias> --repo <repo>=<path>... [--wake <cmd>] [--idle-detach <min>]` | `host.add` | check the host, install Canopy's files and hooks, and save it |
| `canopy host list` | `host.list` | each host with its state, repos, rows, and panes |
| `canopy host rm <alias>` | `host.remove` | forget a host without rows |
| `canopy row new <branch> --on <host>` | `row.new` | a remote row |
| `canopy row list`, `row rm`, `row select`, `row move`, `term *`, `ports`, `pr show` | as now | take remote rows, with `host` and `remotePath` in `--json` |
| `canopy remote-attach` | `host.attach`, `host.next` | hidden, run by remote panes |

`canopy agent-guide` gains a Remote Rows section, with `--on`, how the CLI works on a host, and that the host's agents use the host's own `gh` and git.

### Activity events

| Type | Recorded when | `data` |
|---|---|---|
| `host.added`, `host.removed` | a host is added or forgotten | `host` |
| `host.connected`, `host.detached`, `host.unreachable` | a host's state changes | `host`, and `reason` for `unreachable` |
| `host.woken` | `wake` ran | `host` |

Row and terminal events about a remote row add `host` and `remotePath` to `data`.

## Error handling

| Case | Canopy |
|---|---|
| ssh does not know the alias | `host add` fails with `host_unknown`, saying to add it to `~/.ssh/config`. |
| The alias is `local`, which `row new --on local` keeps for this Mac | `host add` fails with `host_reserved`, saying to give the host another alias. |
| ssh cannot log in, or the host is not Linux, or lacks git, tmux 3.0, or python3 | `host add` fails with `host_unfit`, naming what is missing. |
| A `--repo` path is not a git checkout, or the repo is not registered | `host add` fails with `repo_not_found`, naming it. |
| `row new --on` names a host Canopy does not have, or one without the repo | `host_not_found` or `host_has_no_repo`, naming the hosts that have the repo. |
| The host cannot be reached | Commands that need it fail with `host_unreachable` and ssh's message, and panes print it and wait for Return. |
| git fails on the host | `git` with git's message, as locally. |
| A socket path would be 104 bytes or longer | The app uses `/tmp/canopy-<uid>/`, which is short. |
| The relay finds no socket | It prints that it must run in a Canopy terminal on this host, and exits 1. |
| The relay and the app disagree on the relay's version | The app answers with `relay_outdated` and installs its version again, and the relay prints that and exits 1. |
| A port cannot be forwarded | The ports panel shows it without a forward, with ssh's message on hover. |

## Testing

- **CanopyCore unit tests** cover the hosts config, `remote` in `state.json`, remote rows surviving reconciling, stand-in paths, parsing `git worktree list`, `canopy-host probe`'s output, and `ss`, building the ssh, tmux, and forward commands, socket paths, the relay's path translation, port attribution and local port choice, and the host state machine, with waking, retries, the idle timer, and stopping the master, on a test clock.
- **`make e2e`** gains a fake host: a stand-in `ssh` that runs commands on the Mac, with the host's home in a throwaway folder, and real tmux, which becomes a dev dependency with `brew install tmux`.
  It drives a dev build through `host add`, `row new --on`, typing into a remote pane, a hook report through the relay, `term send` and `row list` from a remote pane, a dropped connection reattaching, idle detach on a short timer, a fake port forwarded, and `row rm`.
- **`scripts/e2e-remote.sh <host>`** runs the same steps against a real host, plus `claude` in a remote row turning its dot green, a PR badge for a pushed branch, a dev server opened through its forward, and waking a stopped host.
  It is run by hand against `hindie-box` before each milestone is called done.
- **UI checks** use `scripts/ui-fixture.sh`, which gains a remote row on the fake host, with window shots of the row, the New Row sheet's Where pop-up, the ports panel's forwarded port, and a pane's reconnecting and detached messages, in light and dark.

## Delivery

Each milestone has its own plan and branch, and a PR only when the author asks.

1. **Hosts, remote rows, and terminals**: hosts and `host` commands, the master and host states, waking and idle detach, remote rows and their listing, `remote-attach` and tmux, busy state, PR badges, the New Row sheet, the fake host, and the e2e.
2. **The CLI on the host**: the relay, the host socket, path translation, hooks on the host, and pending reports.
3. **Ports**: the probe's ports, attribution, forwarding, and the ports panel.

## Decisions to review

- Remote rows are identified by a stand-in folder on the Mac, and their saved state lives in the repo's entry in `state.json`.
- A local row and a remote row may hold the same branch.
- Canopy reads a host's worktrees only while it is connected, so the sidebar can trail a branch an agent switched while the Mac was away.
- One tmux session per pane, on a tmux server per Canopy home, with the alternate screen off so scrollback stays Canopy's.
- The relay runs the app's CLI, so the host never has its own copy of Canopy's logic.
- A relayed `row new` defaults to the host it came from.
- `wake` runs whenever the host cannot be reached, at most every 2 minutes, rather than Canopy telling a stopped instance from a network failure.
- The master stops 10 minutes after its last use, and at once when panes detach for idleness.
- Ports are forwarded to the same Mac port when free, otherwise the next free one.
- Removing a remote row while its host is unreachable needs `--force`, and leaves the host's worktree.
