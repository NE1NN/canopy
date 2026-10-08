# Remote Rows, Milestone 2, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents in remote panes get the whole `canopy` CLI through a relay to the app, so Claude Code's hooks on the host drive the row's agent dots, and claude.ai artifact links opened on the host show in Canopy.

**Architecture:** The host's `canopy` is a Python relay that sends its arguments, folder, `CANOPY_*` variables, and stdin as one JSON line to a Unix socket on the host.
Each new connection forwards that socket, `~/.canopy/<home id>/app.sock`, to a per-host socket in the app with `ssh -O forward -R`.
The app translates the host's paths to stand-ins, runs its own bundled CLI with them, and answers with stdout, stderr, and the exit status.
Hook reports that find no app are saved on the host and replayed by the app before the pane attaches.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing, OpenSSH stream-local forwarding, Python 3 on the host.

**Spec:** `docs/superpowers/specs/2026-10-08-canopy-remote-rows-design.md`, sections "The CLI on the host" and the files and variables tables.
**Milestone 1's plan:** `docs/superpowers/plans/2026-10-08-canopy-remote-rows.md`.

## How this plan is written

As in milestone 1, this plan fixes the files, the interfaces between tasks, and the tests each task must pass, and the commits hold the code.
A What was built section at the end says where the build differs.

## Global Constraints

- Swift 6 language mode, strict concurrency, zero warnings, `make lint` clean, `make test` not bare `swift test`.
- Unix socket paths under 104 bytes on the Mac.
- Nothing in tests or `make e2e` reaches `hindie-box`; only `scripts/e2e-hosts.sh --host hindie-box` does.
- Test helpers never signal a pid they did not just confirm is theirs, and timing checks measure on the thread doing the work or wait for a condition (milestone 1's CI lessons).
- Never quit or kill the release Canopy; dev builds by pid only.
  Never touch solis-v1, ticket-manager, or usefastlane-landing.
- Markdown: one sentence per line, no em dashes.
  Commits: conventional prefixes, no Co-Authored-By trailers.
- The relay and everything on the host is Python 3 and POSIX sh only, as Ubuntu 24.04 ships them.

## Review Focus

1. A relayed CLI run must end when its relay hangs up, and never block the app's other relays or its control socket.
2. Path translation: a folder inside a remote row maps to that row's stand-in plus the same tail; anything else maps to the Canopy home, never to a host path the Mac would misread.
3. The forward must be there for every new connection, including after a dropped master, and a stale socket file must never block it.
4. A hook report that cannot be delivered must never make the hook fail or slow Claude, and must be replayed once, not lost and not twice.
5. `~/.local/bin/canopy` is created only when nothing else is there, and `xdg-open` hands every non-artifact link to the host's own.

## File Structure

New:

| File | Responsibility |
|---|---|
| `Sources/CanopyCore/Hosts/Relay.swift` | `RelayRequest`, `RelayReply`, path translation, the environment a relayed run gets |
| `Sources/CanopyCore/Hosts/HostRelayServer.swift` | the app's per-host socket: one request per connection, runs the CLI, stops it when the relay hangs up |
| `Tests/CanopyCoreTests/RelayTests.swift`, `HostRelayServerTests.swift`, `HostRelayScriptTests.swift` | tests |

Modified:

| File | Change |
|---|---|
| `Support/Subprocess.swift` | optional stdin data, through a temporary file |
| `Hosts/HostFiles.swift` | `relay`, `replay`, and `open` in `canopy-host`; `bin/canopy`, `bin/xdg-open`, and the `~/.local/bin/canopy` link in the install |
| `Hosts/RemoteAttach.swift` | `CANOPY_SOCKET`, `CANOPY_CLI`, `CANOPY_HOME_ID`, and PATH for the session |
| `Hosts/SSHCommand.swift` | `forward(remote:local:)` |
| `Workspace/Workspace+Hosts.swift` | the forward and relay server on each new connection, replay before attach, hooks at `host add` |
| `Agents/ClaudeHookMapping.swift`, `CanopyCLI/HooksCommand.swift` | `CANOPY_STARTED_AT` dates a relayed report; hooks commands on a host say `host add` keeps them |
| `CanopyCLI/RowCommand.swift`, a core helper | `row new` defaults to `CANOPY_HOST`, `--on local` |
| `CanopyCLI/AgentGuide.swift` | the CLI on hosts |
| `scripts/fake-ssh` | `-O forward -R` links the remote path to the local socket |
| `scripts/e2e-hosts.sh` | relay steps |

---

### Task 1: Relay messages, path translation, stdin for subprocesses

**Files:** create `Hosts/Relay.swift`, modify `Support/Subprocess.swift`, test `RelayTests.swift`, `SubprocessTests` (existing file).

**Interfaces:**
- `Subprocess.run(..., stdin: Data? = nil, ...)`: written to an unlinked temporary file opened as fd 0; nil keeps `/dev/null`.
- `public struct RelayRequest: Codable, Sendable { var version: String; var args: [String]; var cwd: String; var env: [String: String]; var stdin: String?; var age: Double? }` with stdin base64 and `age` seconds since the relay started.
- `public struct RelayReply: Codable, Sendable { var stdout: String; var stderr: String; var status: Int32 }`, base64 output, and `static func failure(_ message: String, status: Int32 = 1)`.
- `public enum RelayPaths { static func local(_ remote: String, rows: [RemoteRowEntry], home: String) -> String }`: the row whose path holds `remote` (path-component aware, longest match) gives its stand-in plus the tail; otherwise `home`.
- `public enum RelayRun { static func environment(for request: RelayRequest, host: String, rows: [RemoteRowEntry], home: CanopyHome, receivedAt: Date) -> [String: String] }`: only the request's `CANOPY_*` keys, then `CANOPY_HOME`, `CANOPY_HOST` = host, `CANOPY_ROW_PATH` translated, `CANOPY_STARTED_AT` = `receivedAt - age` as epoch seconds when age is given, and `PATH` from `GitEnvironment.current`.

**Tests:** stdin reaches `cat`; nil stdin reads empty; translation of the row's root, a subfolder, a sibling with a shared prefix (`feat-x2` is not inside `feat-x`), the longest of two nested matches, and an unrelated path to home; the environment drops non-`CANOPY_` keys, overrides `CANOPY_HOME` and `CANOPY_HOST`, and dates `CANOPY_STARTED_AT`; request and reply round-trip JSON.

**Commit:** `feat: relay messages and path translation for the CLI on hosts`

### Task 2: The host's relay, replay, and open

**Files:** modify `Hosts/HostFiles.swift`, test `HostRelayScriptTests.swift` (and `HostFilesTests`).

**Interfaces:**
- `canopy-host relay <args>`: reads `CANOPY_SOCKET`; outside a pane prints "Run canopy in a Canopy terminal on this host." and exits 1.
  Sends one `RelayRequest` line (version = `HostFiles.version`), reads one `RelayReply` line, writes stdout and stderr, exits with status.
  When the first argument is `agent-hook` and the socket cannot be reached, it writes the request to `~/.canopy/$CANOPY_HOME_ID/pending/$CANOPY_PANE.json` through a temporary file and a rename, and exits 0.
  Any other failure to reach the app prints "Canopy is not reachable from this host right now." and exits 1.
- `canopy-host replay --pane <pane> --home-id <id>`: prints the saved request and deletes it, or prints nothing.
- `canopy-host open <url>`: a claude.ai artifact link (the app's `ArtifactLink` rule, mirrored in Python) runs `canopy web open <url>` through the relay; anything else execs the next `xdg-open` on PATH after `~/.canopy/bin`, or prints "xdg-open: no handler for <url>" and exits 3.
- Install also writes `~/.canopy/bin/canopy` (`exec python3 ~/.canopy/bin/canopy-host relay "$@"`) and `~/.canopy/bin/xdg-open` (`exec python3 ~/.canopy/bin/canopy-host open "$@"`), mode 0755, and links `~/.local/bin/canopy` to `~/.canopy/bin/canopy` only when that path is missing or already such a link.

**Tests** (Python run directly against a socket server in the test): a request carries args, cwd, `CANOPY_*` only, stdin when piped, and an age; the reply's stdout, stderr, and status come out; no socket prints the message and exits 1; `agent-hook` with no app saves the pending file and exits 0, and a second save replaces it; replay prints and removes it once; `open` sends `web open` for `https://claude.ai/artifact/<id>` and runs a stand-in `xdg-open` later on PATH for `https://example.com`; install makes both scripts and the link, and leaves an existing `~/.local/bin/canopy` that is not Canopy's alone; the artifact rule agrees with `ArtifactLink(_:)` on a shared table of links.

**Commit:** `feat: canopy-host relays the CLI, keeps hook reports, and opens artifact links in Canopy`

### Task 3: The app's relay server

**Files:** create `Hosts/HostRelayServer.swift`, modify `Workspace/Workspace+Hosts.swift` (`HostTooling.relayCLI`), test `HostRelayServerTests.swift`.

**Interfaces:**
- `final class HostRelayServer: Sendable { init(socketPath:host:handler:); func start() throws; func stop() }`, listening with mode 0600, one request per connection on its own thread per connection.
- `Workspace.relay(_ request: RelayRequest, host: String) async -> RelayReply`: refuses another version with `relay_outdated` (stderr "Canopy updated its files on <host>; run it again.") and installs the files again; refuses when `HostTooling.relayCLI` is nil; otherwise runs the CLI with `RelayPaths.local` for the folder and `RelayRun.environment`, stdin, no timeout, stopped when the relay's connection hangs up (the server polls the connection for hang-up while the CLI runs).
- `HostTooling.relayCLI: String?`: the app passes its bundled `canopy`; tests pass a stand-in script.

**Tests:** a stand-in CLI that prints its args, folder, `CANOPY_ROW_PATH`, and stdin answers through the socket with translated paths; a nonzero exit comes back; another version gets `relay_outdated`; a client that hangs up stops a stand-in that sleeps (the stand-in's child is gone soon after); two requests at once both answer; the socket file is mode 0600.

**Commit:** `feat: the app serves its CLI to hosts`

### Fix between Tasks 3 and 4: each home's own files on a host

Two homes with different builds on one host, such as the release app and a dev build running `scripts/e2e-hosts.sh --host`, replaced each other's files in `~/.canopy/bin`, and since Task 3 each answered the other's relays with `relay_outdated` and installed again.
Each home's `canopy-host`, `canopy`, `xdg-open`, `tmux.conf`, and `files-version` now live in `~/.canopy/<home id>/`, as the spec's files table says.
A shared `~/.canopy/bin/canopy`, the same for every home and version and outside `HostFiles.version`, runs `~/.canopy/$CANOPY_HOME_ID/bin/canopy`, and `~/.local/bin/canopy` links to it.
`HostFiles.installCommand(homeID:)`, `HostFiles.versionCommand(homeID:)`, `HostProbe.command(homeID:)`, and `RemoteAttach.tmuxCommand(homeID:session:folder:environment:)` take the home id.
`canopy-host open` skips its own folder, `~/.canopy/bin`, and any other home's `bin` when it looks for the host's `xdg-open`.

**Commit:** `fix: each Canopy home keeps its own files on a host`

### Task 4: The forward, the pane's variables, and replay on attach

**Files:** modify `Hosts/SSHCommand.swift`, `Hosts/RemoteAttach.swift`, `Workspace/Workspace+Hosts.swift`, `Control/WorkspaceControlHandler.swift`, `scripts/fake-ssh`, `CanopyApp/AppModel.swift` (pass `relayCLI`); tests in `RemoteRowTests.swift`, `SSHCommandTests.swift`.

**Interfaces:**
- `SSHCommand.forward(remote:local:) -> [String]`: `-S <control> -O forward -R <remote>:<local> <alias>`.
- `HostPaths.relaySocket(home:homeID:)` on the host: `<host home>/.canopy/<home id>/app.sock`.
- `prepare` (each new connection): starts the host's relay server if not running, runs `mkdir -p` with mode 0700 and `rm -f` for the socket, then the forward; a failed forward is logged and leaves panes working without the CLI.
- The pane's session gets `CANOPY_SOCKET`, `CANOPY_CLI` (absolute, `<host home>/.canopy/<home id>/bin/canopy`), `CANOPY_HOME_ID`, and the tmux command sets `PATH="$HOME/.canopy/<home id>/bin:$PATH"` for the session.
- `host.attach`, after preparing and before answering ready, runs `canopy-host replay` for the pane and relays a saved request.
- `fake-ssh -O forward -R remote:local` links remote to local; `stopHosts` stops the relay servers.

**Tests:** the forward argv; after `prepareHost` on the fake host the host's socket answers a relayed `--version`-style stand-in; a dropped master and a reconnect forward again over a stale file; the session's environment has the four variables and PATH; a saved pending request is relayed once at attach (the stand-in CLI records each run).

**Commit:** `feat: each connection forwards the host's canopy to the app`

### Task 5: The CLI's own behavior on a host

**Files:** modify `Agents/ClaudeHookMapping.swift`, `CanopyCLI/HooksCommand.swift`, `CanopyCLI/RowCommand.swift`, a helper in `Rows/` for the target host, `CanopyCLI/AgentGuide.swift`; tests in `ClaudeHookTests.swift`, `RemoteRowTests.swift` or a new `RelayCLITests.swift`.

**Interfaces:**
- `AgentHook.request` takes `CANOPY_STARTED_AT` (epoch seconds) over the process start when present.
- `RowTarget.host(on: String?, environment:) -> String?`: `--on local` is this Mac, `--on <host>` that host, no `--on` with `CANOPY_HOST` set that host, else this Mac.
- `canopy hooks install|uninstall|status` with `CANOPY_HOST` set print "Canopy's hooks on <host> are kept by `canopy host add`." and exit 0 (status prints it too).
- The agent guide's Remote Rows section says the CLI works on hosts, that `row new` stays on the host unless `--on local`, and that `xdg-open` opens artifacts in Canopy.

**Tests:** `CANOPY_STARTED_AT` dates the report; the four `RowTarget` cases; the guide mentions `--on local`.

**Commit:** `feat: on a host, row new stays on the host, hooks point to host add, and reports carry their time`

### Task 6: Hooks on the host at `host add`

**Files:** modify `Workspace/Workspace+Hosts.swift`, maybe `Hosts/HostFiles.swift` for the write command; test `HostControlTests.swift`.

**Interfaces:**
- `host add`, after installing files: reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` on the host (missing reads as `{}`), applies `ClaudeHooks.installing`, and writes it back through a temporary file and a rename, with the content base64 in the command, only when it changed.
- An unreadable settings file fails `host add` with `host_command_failed` naming the file, and saves nothing.

**Tests:** a fresh host gets the hooks; a host with other settings keeps them byte-for-byte apart from the hooks; running `host add` twice changes nothing the second time; broken JSON fails and leaves the file.

**Commit:** `feat: host add installs Canopy's hooks in the host's Claude Code settings`

### Task 7: End to end

**Files:** `scripts/e2e-hosts.sh`, `scripts/ui-fixture.sh` if needed.

**Steps added, on the fake host and `--host`:**
- In the remote pane, `canopy row list` prints the repo's rows, and `canopy term list` lists the pane.
- A hook report piped to `canopy agent-hook` in the remote pane (a `Stop` event JSON) shows in `canopy term list --json` as the pane's agent state.
- `canopy web open https://example.com` in the remote pane opens a page in the remote row (`web list`); `xdg-open https://claude.ai/artifact/<id>` opens one too.
- With the forward gone (the app quit), an `agent-hook` in the pane exits 0 and leaves a pending file; after relaunch and reattach, the report shows and the file is gone.
- `row new e2e/second` typed in the remote pane makes a row on the same host.

**Commit:** `test: the CLI on hosts end to end`

### Fix after Task 7: the app acknowledges a request

While the Mac sleeps, or for the two seconds a quit app's master lingers, sshd on the host still accepts connections on the forwarded `app.sock`, but nothing answers.
The relay kept a hook's report only when it could not connect, so a report from an agent that finished while the Mac slept was lost, and held Claude for `HOOK_TIMEOUT`.
`HostRelayServer` now writes `{"ack": true}` as soon as it has read a request whose version it acknowledges (`HostFiles.version` by default), before running it, then the reply as before; a request of another version gets the reply alone.
The relay waits for the acknowledgement for 5 seconds for `agent-hook` and 10 for other commands.
Without one, or with a reply that came without one, `agent-hook` keeps its report and exits 0, and other commands print that Canopy is not reachable and exit 1, except that a reply without an acknowledgement is printed as before.
After the acknowledgement, `agent-hook` waits up to `HOOK_TIMEOUT` for the reply and keeps nothing, and other commands wait for the reply as long as it takes.

**Tests:** an app that never answers, one that hangs up, and one that replies without an acknowledgement each leave the hook's report kept; one that acknowledges and hangs up leaves none; a command an app never answers is not reachable; a reply without an acknowledgement is printed; the real server acknowledges a current request before its reply, while it runs, and answers another version with the reply alone.

**Commit:** `fix: a hook's report is kept when the app does not acknowledge it`

### Fix after the merge-bar run: a hook within Claude's timeout, and replay from the probe

Claude Code kills a hook at its timeout, which Canopy's hook entry sets to 5 seconds.
The relay's `agent-hook` waited up to 5 seconds to connect and 5 more for the acknowledgement, so with the Mac asleep Claude killed it just before it kept its report, and the report was lost.
It now counts one budget from when the relay starts: its standard input is read for at most 1 second, sending what arrived by then; the connection, the request, and the acknowledgement must all come within 3 seconds, or the report is kept; and after the acknowledgement the reply is waited for until 4 seconds.
The hook's timeout in the settings stays 5 seconds.
A kept report was replayed only when a pane attached, but after a short sleep the master can survive and no pane attaches again, so the row's agent dot stayed wrong.
`canopy-host probe` now takes `--home-id` and also prints `pending`, the panes with a kept report for this home, ignoring temporary and replay files and names outside the NAME rule.
`HostProbe.decode` returns a `HostProbe.Report` with the sessions and the pending panes, and reads output without `pending` as having none.
`HostMonitor.probe` replays each pending pane's report through `Workspace.replayKeptReport(pane:on:)`, in one task per host at a time, like the worktree listing, so the probe loop never waits for it.
Replay at attach stays.

**Tests:** a hook whose input never closes, against an app that is silent, exits 0 with its report kept; a hook whose budget is already spent keeps its report without connecting; the probe lists the panes with a kept report and ignores temporary, replay, and other files; a kept report a probe sees is run once, and a later probe runs nothing more.

**Commit:** `fix: a hook keeps its report within Claude's timeout, and the probe replays kept reports`

### Task 8: Merge bar

- [ ] `make lint`, `make build` 0 warnings, `make test` three clean runs.
- [ ] `make e2e`, and `scripts/e2e-hosts.sh --host hindie-box`.
- [ ] An independent opus review of `git diff main...HEAD` with the spec and this plan; findings fixed test-first, listed under After Review.
- [ ] CI `check` green.
- [ ] PR with click checks and Decisions to review; print `READY: PR #<n> <url>`.

## After Review

An independent review of `git diff main...HEAD` found these, each fixed test-first.

1. The host's `canopy` read all of its caller's standard input for every command, so `while read` loops lost their lines, an idle open pipe held each command 10 seconds, and `tail -f log | canopy ...` never ended.
   Now only `agent-hook` and `ticket connect` get input, from `RelayInput.commands` in `Relay.swift`, which the host's script is rendered from.
   `ticket connect` sends its first line alone, read a byte at a time within 10 seconds and 64 KiB, as `TokenInput` reads it on the Mac.
   `RelayInputTests` reads the CLI's sources and fails when a command that reads standard input is missing from the list, and an e2e step runs `canopy` in a `while read` loop in the remote pane.
   The CLI accepts no option before a subcommand, so options among a command's words are passed over without taking values.
2. After the acknowledgement a relayed command waited for its reply forever, so a `term wait` hung when the Mac slept or changed network.
   `HostRelayServer` now writes `{"alive": true}` every 15 seconds while an acknowledged call runs, and the relay passes over it and says Canopy is not reachable after 45 seconds with no line.
   Both intervals are injectable, `heartbeatInterval` on the server and `REPLY_SILENCE` in the script, and the hook's budget is as it was.
3. `mkdir -p -m 700` left the home's folder on the host as the install made it, readable by anyone, and the relay's socket is in it.
   Each forward now runs `chmod 700` on it too.
4. Every `CANOPY_*` variable from the host reached the Mac's CLI, including `CANOPY_APP`, `CANOPY_SSH`, and `CANOPY_SOCKET`.
   Now only `RelayRun.paneVariables` cross over: `CANOPY_PANE`, `CANOPY_REPO`, `CANOPY_ROW_PATH`, `CANOPY_PLUGIN`, and `CANOPY_ITEM`, which are what the CLI reads.
   `CANOPY_ROW`, which the reviewer listed, stays behind, since the CLI never reads it.
5. The relay named its folder with `os.getcwd()`, which resolves links, so on a host whose HOME is a link a folder in a remote row became the Canopy home.
   It now sends `$PWD` when that names the same folder as `.`.
6. A hook's relay hangs up 4 seconds after it starts, which cancelled an acknowledged `agent-hook` the app was still running.
   Such a run now goes on to its end, and other calls whose relay hangs up still stop.
7. `stop()` said a call it cancels answers nothing, but the killed CLI's output went back as the reply.
   The comment stated the better behavior, since a killed CLI's partial output and status 137 read as the command itself failing, so the server now answers nothing and the relay says Canopy is not reachable.
8. A remote pane's session from milestone 1 has no `CANOPY_HOME_ID`, so the shared `~/.canopy/bin/canopy` told it to run canopy in a Canopy terminal, which it was.
   It now says the terminal started before Canopy's CLI reached the host and a new Canopy terminal has it.
   Inside tmux `TERM_PROGRAM` is `tmux`, whatever the session was given, so the shim knows such a session by `CANOPY_HOST` and `CANOPY_PANE` instead.
   Hooks on hosts added before milestone 2 are not installed on their own; `canopy host add` installs them when run again.
9. `aHookWhoseInputNeverClosesKeepsItsReportWhenTheAppIsSilent` passed however long the hook took.
   It now checks the age the relay gave the report as it kept it, on the relay's own clock, is under 4 seconds.
10. Task 2's interface bullets, and a few lines above them, held several sentences each, and are now one sentence per line.

`HostClaudeSettings` reading `CLAUDE_CONFIG_DIR` from the non-interactive ssh environment stays as it is.
