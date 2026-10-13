# Canopy on the box design

Date: 2026-10-13
Status: approved in conversation on 2026-10-13, waiting for the author's review of this file.
The author picked each decision below in conversation, section by section.
Mockups of the phone screens are at https://claude.ai/artifact/RSfrJZmSpnffA7s42BZDwd (private to the author).

## Summary

The author wants to code from the iPhone with the Mac fully off.
hindie-box, the EC2 box that already runs remote rows, gets a Canopy program of its own, `canopy-box`, which runs all the time the box is on.
It becomes the one source of truth for the box's rows: their worktrees, tmux sessions, agent states, open prompts, and transcripts.
The phone pairs with the box as well as the Mac, and talks to each directly over Tailscale.
The Mac stops tracking box rows itself and reads them from `canopy-box` through its ssh master, while its terminals still attach through tmux as today.
From the phone the author can read and answer box agents, and start new rows and agents on the box, with the Mac off.
When the box has powered itself off, the phone wakes it with an AWS key that can only start that one instance.
The phone's Inbox becomes a list of notifications, and its Rows tab groups rows by host, then repo, with each repo's main row first.

## Goals

1. With the Mac off, the phone lists the box's rows and agents, reads their conversations, replies, and answers prompts.
2. With the Mac off, the phone starts a new row on the box with a brief, and an agent starts working on it.
3. When the box is off, one tap on the phone starts it and connects once it is up.
4. The box still powers itself off when idle, and stays on while an agent works or a phone is connected.
5. There is one source of truth for a box row's state, whether the Mac is on or off.
6. Rows made on the box while the Mac was off show on the Mac the next time it connects, with no sync step.
7. The phone pairs with several servers and shows them in one app.
8. The six solis-v1 rows already on the box keep running untouched until the author switches the box over.

## Non-goals

- Push notifications from the box.
  They wait for milestone 4 of the iPhone spec and the author's paid Apple Developer account.
  The design leaves room for `canopy-box` to push with the same key later.
- Hosts other than Linux on x86_64 or arm64, and boxes outside AWS for waking.
- A server of Canopy's in the cloud, or a Lambda.
- The ports panel, PR lookups, the artifact viewer, and the Tickets plugin on the box.
  They stay on the Mac and work for box rows while the Mac is connected.
- Reading the box's activity log from the Mac.
- Waking the Mac.
- Chat tabs on the box, from the chat tabs spec (`2026-10-13-canopy-chat-tabs-design.md` on `feat/chat-tabs`).
  A later box chat would run headless `claude -p --input-format stream-json --output-format stream-json` under a small keeper process on the box, which keeps it alive through daemon restarts as tmux keeps terminals.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Who owns a box row | `canopy-box` on the box, for the Mac and the phone alike | The author wants one source of truth. Rows the phone makes with the Mac off then need no reconciling. |
| What `canopy-box` is written in | Swift, cross-compiled on the Mac with the static Linux SDK | One copy of the hook mapping, transcript parser, inbox, answer keys, and phone protocol, tested once. The author weighs maintainability over development cost. |
| How the phone wakes the box | The phone signs `ec2:StartInstances` with an IAM key that may only start that instance | Nothing to deploy or keep running. A lost phone's key can only start the box, and IAM revokes it. |
| What keeps the box awake | Working and background agents, and a connected phone | The author's choice. Waiting and done agents do not hold a c8i.8xlarge on overnight, as today. |
| Switching the existing box over | An explicit `canopy host upgrade hindie-box`, with `--undo` | The author's live rows switch only when the author says so, after testing on a throwaway home. |
| What a task from the phone runs | One agent command per server, set from the Mac | The phone picks the brief, never the program. It can still direct that agent to do anything the box's user can, as a reply already can on the Mac. |
| Reaching the box | Tailscale on the box | A fixed name and address on the tailnet, whatever public IP EC2 gives, and nothing on the public internet. |
| Inbox | Notifications: agents waiting for the author, and done agents not yet read | The author's choice. Running agents live in Rows. |
| Rows | Host, then repo, then the repo's main row as a large card, then its other rows | The author's choice. It replaces pins. |
| The box's clone | A row: the repo's main row on that host | The author's choice, so every host has a main. |
| Running `canopy-box` | A systemd user service per Canopy home, with lingering on | Canopy installs and restarts it without sudo after one `loginctl enable-linger`. |

## Architecture

```
iPhone ──tailnet──▶ Canopy.app on the Mac          Mac rows, as today
   │
   └──tailnet──▶ canopy-box on hindie-box          box rows, the one source of truth
                    ▲            │
Canopy.app ──ssh master: box.sock┘            tmux -L canopy-<home id>, one session per pane
            ──ssh master: tmux attach (terminal views, as today)
```

### Shared code

Two new library targets build for macOS and Linux, with nothing platform-specific:

- `CanopyAgents`: `ClaudeHookMapping`, `PaneAgent`, `OpenPrompt`, `TranscriptParser`, `TranscriptReader`, `TranscriptFollower`, `TranscriptTails`, `PhoneAnswerKeys`, and the branch rules `row new` uses to pick or make a branch.
- `CanopyServer`: the phone server, which is `PhoneRegistry`, the connection gate, the method list, streams, and the dispatch now in `PhoneService`, on top of a POSIX socket layer grown from `SocketStream`.

`CanopyWire` gains Linux as a platform, as it already has nothing platform-specific.
`CanopyCore` depends on both new targets and re-exports them, so the app and CLI change no imports.

The phone server reaches rows and panes through one protocol, `PhoneSource`, which lists rows and panes with their agents, reads a pane's screen, and writes text and keys to it.
The Mac implements it with `TerminalStore`, its ptys and SwiftTerm, as `PhoneInboxBuilder` and `PhonePanes` do today.
`canopy-box` implements it with tmux.
`PhoneInboxBuilder` becomes a pure function of what `PhoneSource` lists.

SHA-256 comes from `swift-crypto`, whose API matches CryptoKit and which uses CryptoKit on Apple platforms.
`Network` stays on the Mac only to learn its Tailscale addresses with `NWPathMonitor`.
`canopy-box` learns the box's tailnet addresses with `getifaddrs`, every 5 seconds and on start, keeping the same rule: addresses in `100.64.0.0/10` and `fd7a:115c:a1e0::/48` on `tailscale0`.
Subprocesses run through the existing `posix_spawn` helper, which builds on Linux.

### canopy-box

An executable target, `CanopyBox`, whose product is `canopy-box`.
`make box` builds it with `swift build -c release --swift-sdk x86_64-swift-linux-musl --product canopy-box` (and `aarch64` for arm64 hosts), a static binary with no dependencies on the box.
`make app` and `make install` build it too and put it in the app bundle's resources, so the Mac always carries the daemon matching its own version.
The static Linux SDK for the Mac's Swift is installed once with `swift sdk install`; `make box` names the command when it is missing.
`canopy-box` also builds for macOS, so `make e2e` runs it against the fake host.

One `canopy-box` runs per Canopy home id on a host, as each home already has its own folder there, so a dev build never meets the release app's rows.
It keeps its files under `~/.canopy/<home id>/box/`:

| Path | What |
|---|---|
| `box.sock` | the local socket the Mac and the box's CLI use, mode 0600 in a folder only the user can open |
| `state.json` | repos, rows, panes, agents, the next pane number, and the last PR states the Mac reported |
| `phones.json` | paired phones: each token's SHA-256, name, and when it last connected, as on the Mac |
| `config.json` | repos (name to clone path), the agent command, and the listener port, written by the Mac |
| `wake.json` | the wake key, mode 0600 |
| `instance.json` | the instance id and region, from the instance metadata service |
| `busy` | touched every 30 seconds while the box should stay on |
| `activity/` | the daemon's activity log, in the Mac's JSONL format |

It owns, for its home:

- **Rows.** Each registered repo's clone on the host is that repo's main row on the host, which cannot be removed.
  Other rows are worktrees in `~/.canopy/<home id>/worktrees/<repo>/<slug>`, made and removed by `canopy-box` with the same branch rules as local rows.
  The folder is the home's own, so a dev build's daemon and the release app's on one host never take each other's rows; rows the Mac made before the upgrade stay in `~/.canopy/worktrees/` and come over by `box.adopt`.
- **Panes.** One tmux session per pane on `tmux -L canopy-<home id>`, with the variables a remote pane gets today.
  A pane's id is its session name.
  Panes the Mac made keep their `p<N>` names; panes `canopy-box` makes are `b<N>`, from its own counter, so the two never collide.
  Every box pane is a terminal, so where the phone's wire types carry a pane `kind`, the daemon sends `terminal` or leaves it out.
- **Agents.** Hook reports from the box's Claude Code update each pane's `PaneAgent`, transcript path, and open prompt.
- **Transcripts.** They are files on the box, so box rows get Chat.
- **Screens and keys.** `tmux capture-pane -p -e` gives a pane's screen with its colors, with up to 500 lines of history.
  A reply goes in with `tmux load-buffer` and `paste-buffer -p -d`, a bracketed paste, then Return as its own `send-keys` once 200 ms have passed, matching the Mac's timing.
  Answers and keys go in with `send-keys`, 150 ms apart, as the Mac sends them.
  Each pane's foreground command and title come from `tmux list-panes -F`, every 2 seconds.
- **Ports.** It lists listening ports with `ss` every 5 seconds, as `canopy-host probe --ports` does today, for the Mac to forward.

On start it loads `state.json`, then reconciles it with `git worktree list` for each repo and with the tmux server's sessions.
A worktree it does not know that sits under `~/.canopy/<home id>/worktrees/<repo>/` becomes a row again, a session it does not know becomes a pane of the row whose folder holds it, and a saved row whose worktree is gone is marked missing.
So a lost or damaged `state.json` costs only pane order and agent states, which the next hook brings back.

### The Mac's link to the box

While the master is up, the app forwards a socket of its own, `CANOPY_HOME/hosts/<host hash>-box.sock`, to the daemon's `box.sock` with `ssh -O forward -L`.
ssh is the login, so the link has no token.
It speaks the control protocol's newline-delimited JSON, with these methods:

| Method | What it does |
|---|---|
| `box.hello` | Both sides' versions. A daemon older than the app is replaced, as below. |
| `box.configure` | Sets the repos, the agent command, the listener port, and the wake key. |
| `box.subscribe` | The box's rows, panes, agents, open prompts, last lines, foreground commands, titles, and ports, sent whole on each change and at most every 100 ms. |
| `box.rowNew`, `box.rowRemove` | Make or remove a row, with `row new`'s and `row rm`'s options. |
| `box.paneNew`, `box.paneClose` | Make a pane's tmux session in a row and return its id, or kill it. |
| `box.send`, `box.keys`, `box.read`, `box.wait` | What `term send`, `term read`, and `term wait` do, for a box pane. |
| `box.seen` | Marks a done agent seen. |
| `box.prs` | The Mac's latest PR states for box rows, kept for the phone. |
| `box.pair`, `box.phones`, `box.phoneRemove` | Pairing codes and paired phones, for `canopy phone pair --on`, `phone list --on`, and `phone remove --on`. |
| `box.adopt`, `box.release` | `host upgrade` and `host upgrade --undo`, below. |

On an upgraded host the Mac stops relaying hook reports through its own CLI, running `canopy-host probe`, listing worktrees every 30 seconds, and running git on the box to make or remove rows.
`HostMonitor` takes busy state, titles, idle detach, and ports from the `box.subscribe` stream instead.
The Mac still runs the master, attaches each terminal view with `ssh -t ... tmux attach-session -t <pane id>`, forwards ports, looks up PRs with its own `gh`, and runs the artifact viewer.

A box row the Mac has no stand-in for, as one made from the phone, gets its stand-in folder at the next connect, and its panes open as tabs.
The Mac's layouts of tabs and splits stay the Mac's own; a pane it has not placed opens as a new tab in its row.
The Mac keeps box rows in `state.json`'s `remote` as a cache, so the sidebar shows them while the box is off, and replaces that cache with the daemon's list on each connect.
Closing a box pane at the Mac sends `box.paneClose`, asking first while it runs a program, as today.

**Updates.** On connect the app compares `box.hello`'s version with its own.
An older daemon, or none, gets the binary from the app bundle, copied through the master to `~/.canopy/<home id>/bin/canopy-box` by a temporary file and a rename, then `systemctl --user restart`.
tmux runs apart from the daemon, so agents keep running through the restart, and hook reports in those seconds wait in `pending/`.
A newer daemon than the app is left alone, and the Mac uses the methods it knows.

### The CLI on the box

`canopy-host relay` on an upgraded host connects to `~/.canopy/<home id>/box/box.sock` instead of `$CANOPY_SOCKET`.
Sessions that started before the upgrade run the same script by path, so their hooks move over with no restart.

`canopy-box` answers itself:

- `agent-hook`, for any box pane.
- `row new` without `--on` or with `--on <this host>`, `row list` for its rows, and `row rm` for its rows.
- `term list`, `term send`, `term read`, and `term wait` for box panes.

Everything else, such as `web open`, `pr`, `ports`, `ticket`, `row new --on local`, and anything naming a Mac row or pane, it passes to the Mac over today's forwarded `app.sock`, with the same request the relay would have sent.
With the Mac not connected, those fail with "This needs Canopy on the Mac, which isn't connected." and exit 1.

When the daemon is down, the relay keeps hook reports in `pending/` as today, and `canopy-box` replays them as it starts.

## The phone

### Servers

The phone holds a list of servers instead of one Mac.
Each is its own Keychain item, holding its name, kind (`mac` or `box`), address, token, and for a box its wake key, and has its own connection with its own status and backoff.
`PairedMac` and `MacConnection` become `PairedServer` and `ServerConnection`, and the models take a list.
`phone.hello` answers with the server's kind and name, its agent command, and for a box its wake key, so a changed key or command reaches the phone on its next connect.
The protocol stays version 1; phones and servers ignore fields they do not know.

### Pairing with the box

`canopy phone pair --on hindie-box` on the Mac asks the daemon for a pairing code through the link, and prints the QR code as `canopy phone pair` does.
The link holds the box's MagicDNS name and Tailscale address, which the daemon reads from `tailscale status --json`, the daemon's port, the code, and `kind=box`.
The phone pairs with the daemon directly and keeps its own token for it.
`canopy phone list|remove --on <host>` list and remove phones paired with the box.
The daemon's pairing rules are the Mac's: codes expire after 5 minutes, five wrong codes void them all, tokens are compared in constant time.

### Inbox

The Inbox lists only what wants the author, across every server:

- **Needs you**: waiting agents, oldest first, with Allow and Deny on permission prompts.
  One leaves when its prompt is answered, here or at the Mac.
- **Done**: done agents not yet seen, newest first.
  One leaves when its conversation opens, when it is swiped left (Mark read), or with Mark all read in the section's header.
  Each sends `phone.seen` to its server, so the Mac's dot clears as well.

Items show their dot, row, time, and last line, without their host.
Working, background, and idle agents do not appear.
An empty Inbox says "All caught up", how many agents are running, and links to Rows.
The tab's badge counts every item in it.
The title bar holds New task and Settings.
`PhoneInbox.Sections` in `CanopyWire` changes to `needsYou` and `done`, and pins go.

### Rows

Rows lists every row, by host in pairing order, then by repo in the server's order.
Each repo shows its name, then its main row as a large card, then its other rows, each with its dot, PR number, and last line.
Each host's header says whether it is connected; a host that is not shows its rows greyed, as of when it was last reached.
On the box the PR numbers are the last ones the Mac reported, so they can trail while the Mac is off.

### Conversations

Box rows get Chat, Terminal, replies, and answers through the same `phone.*` methods, served by the daemon.
The conversation's title names the row's host.

### Waking the box

A box that does not answer shows in the Inbox as a card, "hindie-box is off", with Wake.
Tapping Wake, Wake now in Settings, or Start in New task for a box that is off:

1. signs `ec2:StartInstances` for the instance with AWS Signature Version 4, using CryptoKit's HMAC, and posts it to the region's EC2 endpoint;
2. repeats it every 10 seconds while the answer is `IncorrectInstanceState`, as for an instance still stopping, and stops once the answer says `pending` or `running`;
3. retries the server's connection on the usual backoff for up to 5 minutes.

The card shows "Waking hindie-box" with a spinner and "Started 40 s ago".
A failure names its step: AWS refused the key, the instance did not start, or it started and Canopy did not answer.
The phone only wakes the box on a tap, never when the app opens, so a glance at the Inbox cannot start the box.
`StartInstances` on a running instance changes nothing, so the key needs no other permission.

The IAM user's policy allows `ec2:StartInstances` on `arn:aws:ec2:ap-southeast-2:<account>:instance/i-069bf8c49e5f996ab` and nothing else.
`canopy host wake-key <host>` reads the access key id and secret from standard input, stores them in the Mac's login Keychain, and sends them to the daemon with `box.configure`.
The daemon reads its own instance id and region from the EC2 instance metadata service.

### New task

New task is a sheet with Where (each paired server, the last choice first), Repo, Branch, From, Brief, and the server's agent command shown read-only.
A server that is not connected is greyed, except a box with a wake key, which Start wakes first.
Start sends `phone.newRow` with the repo, branch, base, and brief.
The server makes the row by `row new`'s branch rules, opens a pane running its agent command with the brief added as one shell-quoted argument, and answers with the row and pane, and the phone opens that conversation.
The Mac serves `phone.newRow` for Mac rows too.

The agent command is set with `canopy host add <host> --agent "<command>"` for a box and `canopy phone agent "<command>"` for the Mac, saved in `config.json`.
Without one it is `claude --model 'opus[1m]' --permission-mode bypassPermissions`.
The phone cannot change it.

### Settings

Settings lists each server with its status.
A box's detail shows its tailnet name, whether a wake key is set and for which instance, its agent command, Wake now, and Unpair.
The Mac's detail shows its agent command and Unpair.
A footnote says to run `canopy phone pair --on <host>` on the Mac to add a server.
Face ID stays as it is.

## The box

Each of these is done only with the author's approval, as the box runs the author's work.

### Tailscale

Tailscale is installed from its own apt repository and joined as `hindie-box` through a login link the author opens.
Key expiry is turned off for that machine in the admin console, so it does not drop off the tailnet after 180 days.
It is not an ephemeral node, since those are removed while offline.
`canopy-box` listens for phones on the box's tailnet addresses only, port 6974 for the release app and the port `config.json` names for dev homes.
Without Tailscale it does not listen for phones, and `canopy host list` says so; the Mac's link still works.

### The service

`canopy host add` and `host upgrade` write `~/.config/systemd/user/canopy-box-<home id>.service`, with `Restart=always` and `RestartSec=2`, and enable and start it.
One `sudo loginctl enable-linger ubuntu`, run once by the author, starts user services at boot without a login.
`host add` checks lingering and Tailscale and names the fix for each missing one.

### Idle power-off

`/usr/local/sbin/idle-shutdown` gains one check: a `~/.canopy/*/box/busy` file touched in the last 2 minutes counts as activity, like a keystroke.
`canopy-box` touches it every 30 seconds while any pane's agent is working or background, or a phone is connected.
A daemon that crashed or hangs stops touching it, so it cannot hold the box on.
Waiting and done agents do not count.
The rest of the script's rules stay.

## Switching hindie-box over

`canopy host upgrade hindie-box`:

1. checks that the master is up, installs or updates `canopy-box` and its service, and waits for `box.hello`;
2. sends `box.configure`, then `box.adopt` with the host's rows, their branches and paths, their panes' session names and folders, each pane's agent state, transcript path, and open prompt, and the next pane number;
3. the daemon checks each session exists on the home's tmux server, records the rows, panes, and agents, makes the clone each repo's main row, and answers with what it took and what it did not find;
4. the Mac marks the host upgraded in `config.json`, installs the relay script that talks to the daemon, has the daemon replay any `pending/` reports, and stops probing.

Nothing is restarted, and no tmux session is touched.
`canopy host upgrade --undo` sends `box.release`, takes the daemon's rows and panes back into `state.json`, puts back today's relay script, and stops and disables the service, so the host runs as before.
New hosts added with `canopy host add` are upgraded from the start.

## Failures

| Case | What happens |
|---|---|
| The daemon is down while the box is up | Hooks keep reports in `pending/`, systemd restarts it, and it replays them. The Mac shows "Canopy isn't running on hindie-box" and its panes stay attached. |
| `state.json` is lost or damaged | The daemon rebuilds rows and panes from `git worktree list` and tmux, as in "canopy-box". |
| The Mac and the phone answer the same prompt | The prompt's ID check answers the second with `prompt_gone`. |
| The phone made rows while the Mac was off | They appear on the Mac at its next connect, with stand-ins and tabs. |
| A box CLI command needs the Mac and the Mac is not connected | It fails with "This needs Canopy on the Mac, which isn't connected." |
| Waking fails | The card names the step, and Wake can be tapped again. |
| The phone's token for the box was removed | `phone.hello` answers `unpaired`, and the phone shows that server as unpaired in Settings, keeping the others. |
| A daemon newer than the app | The app uses the methods it knows and does not replace it. |
| The box has no Tailscale | The Mac's link works, and the phone cannot reach the box; `canopy host list` says why. |

## Security

`box.sock` lives in a folder only the user can open, so only the user's own processes on the box, and the Mac through ssh, reach it.
Phones reach the daemon only over the tailnet, only with a token, and only through the `phone.*` method list.
The agent command is fixed by the Mac, so `phone.newRow` cannot start another program.
It does not limit what that agent does: with the default command's bypassed permissions, a paired phone can direct it to do anything the box's user can, as a reply to any agent already can.
The token, Tailscale, Face ID, and `canopy phone remove --on` are what guard that, and the box adds no sandbox of its own.
The wake key can only start one instance.
The daemon records `phone.call`, `phone.paired`, and `phone.removed` in its own activity log, under the same rules as the Mac.

## Testing

- `CanopyAgents` and `CanopyServer` tests run on macOS in `make test`, and on Linux in a new CI job, which also builds `canopy-box` for Linux.
- `canopy-box` tests: reconciling saved state with worktrees and sessions, adopting and releasing, the CLI split between daemon and Mac, the busy file's rule, and pane ids, against real tmux.
- App tests: the link's stream driving rows, busy state, and ports; stand-ins for rows made on the box; the cache while the box is off.
- Phone model tests against fake servers: several servers, the notification Inbox and Mark read, Rows by host, waking with a fake EC2 endpoint, including each failure, and New task.
- `make e2e` runs `canopy-box` for macOS on the fake host: `host add`, `host upgrade` and `--undo` with a running fake agent, hooks, `row` and `term` from a box pane, a phone pairing over loopback, Chat, a reply and an answer, `phone.newRow`, and the busy file.
- `scripts/e2e-hosts.sh --host hindie-box` gains the daemon, with a throwaway home id and repo, never touching the author's rows.
  It never stops the instance; waking is checked with a signed `StartInstances` on the running instance, which changes nothing.
- iOS screenshots of the Inbox, Rows, the waking card, New task, and Settings, in light and dark.

## Delivery

One PR per milestone, each with its own plan:

1. **The phone's Inbox and Rows**: the notification Inbox, Mark read, Rows with main cards, and pins removed.
   It helps with the Mac alone.
2. **Portable code**: `CanopyAgents`, `CanopyServer`, `PhoneSource`, `swift-crypto`, the Linux build, and the CI job, with no change in behaviour.
3. **`canopy-box`**: rows, panes over tmux, hooks, the box's CLI, the Mac's link, the service, `host upgrade` and `--undo`, and the e2e.
4. **The phone server on the box**: the tailnet listener, `phone pair|list|remove --on`, every `phone.*` method for box panes, and the busy file.
5. **Several servers in the iPhone app**: `PairedServer`, `ServerConnection`, the merged Inbox, Rows by host, and Settings.
6. **Waking**: `host wake-key`, the phone's signed wake, and the waking card.
7. **New task**: `phone.newRow` on the Mac and the box, agent commands, and the sheet.

## Owed by the author

- Approving, then opening the login link for, Tailscale on the box, and turning off its key expiry.
- `sudo loginctl enable-linger ubuntu` on the box, once.
- Approving the `busy` check in `idle-shutdown`.
- The IAM user with the start-only policy, its access key into `canopy host wake-key hindie-box`, and the user's ARN for the record.
- Running `canopy host upgrade hindie-box` once milestone 3 is merged and installed.

## Changes to the iPhone spec

This design replaces these parts of `2026-10-12-canopy-iphone-design.md`:

- "Chat for remote rows on ssh hosts in the first version" is no longer a non-goal: box rows get Chat.
- The Inbox's pinned rows and Running section, and swipe to pin, go; the Inbox is notifications, and Rows has main cards.
- The phone pairs with several servers, not one Mac.
- Mode 2 (milestone 5) is milestone 7 here, and covers the Mac and the box.

## Decisions to review

- The default agent command is `claude --model 'opus[1m]' --permission-mode bypassPermissions` until the author sets one.
- Agents started from the phone run with no sandbox beyond the box user's own rights, so a paired phone is as powerful on the box as the author's ssh login.
- The wake key's only permission is `ec2:StartInstances`; the phone uses its answer to know the instance is starting, and polls Tailscale after that.
- Daemon pane ids are their tmux session names, `b<N>` for new panes, so adopted `p<N>` sessions keep their names.
- The box's clone is the repo's main row on the box, and cannot be removed.
- The daemon passes Mac-bound CLI commands to the Mac rather than refusing them outright, so agents on the box keep the whole CLI while the Mac is connected.
- The daemon learns tailnet addresses by polling `getifaddrs` every 5 seconds.
- PR numbers on the phone for box rows are the Mac's last report, so they can trail while the Mac is off.
- New box rows go in `~/.canopy/<home id>/worktrees/<repo>/`, not the folder every home shares, so two homes' daemons on one host never adopt each other's worktrees (found in milestone 3a's review).
