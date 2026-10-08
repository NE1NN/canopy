# Remote Rows, Milestone 3, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dev server an agent starts in a remote row shows in the ports panel under that row and opens at `localhost` on the Mac, forwarded through the host's ssh master.

**Architecture:** `canopy-host probe` gains the host's listening TCP ports, read from `ss -ltnpH`, each with its processes, their ancestors, and their folders.
The app asks for them every 5 seconds while the host is connected, gives each port to the remote row whose tmux session it descends from, or else whose worktree holds its folder, and forwards it with `ssh -O forward -L` to the same Mac port when that is free, otherwise the next free one above.
The ports panel and `canopy ports` show remote ports beside local ones, with the host and the Mac's port, and stopping one runs `canopy-host stop-port` on the host, never `kill` on the Mac.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing, OpenSSH local forwarding through a control master, Python 3 and iproute2's `ss` on the host.

**Spec:** `docs/superpowers/specs/2026-10-08-canopy-remote-rows-design.md`, section "Ports", and the error table's last row.
**Earlier plans:** `docs/superpowers/plans/2026-10-08-canopy-remote-rows.md` (milestone 1) and `docs/superpowers/plans/2026-10-08-canopy-remote-relay.md` (milestone 2).

## How this plan is written

As in milestones 1 and 2, this plan fixes the files, the interfaces between tasks, and the tests each task must pass, and the commits hold the code.
A What was built section at the end says where the build differs.

## Global Constraints

- Swift 6 language mode, strict concurrency, zero warnings, `make lint` clean, `make test` not bare `swift test`.
- Nothing in tests or `make e2e` reaches `hindie-box`; only `scripts/e2e-hosts.sh --host hindie-box` does.
- A pid read on a host is never signalled on the Mac. Remote ports carry their host, and every stop path checks it.
- Test helpers never signal a pid they did not just confirm is theirs, and timing checks wait for a condition or measure on the thread doing the work.
- Never quit or kill the release Canopy; dev builds by pid only. Never touch solis-v1, ticket-manager, or usefastlane-landing.
- Markdown: one sentence per line, no em dashes. Commits: conventional prefixes, no Co-Authored-By trailers.
- Everything on the host is Python 3 and POSIX sh, with `ss` from iproute2, as Ubuntu 24.04 ships them.

## Review Focus

1. A remote pid never reaches `kill` on the Mac, and `stop-port` on the host signals a pid only while it still listens on the port it was asked about.
2. Forwards follow the host: one per remote port, gone when the port stops listening or the master stops, made again on a new connection, never two for one remote port.
3. The Mac port is free in both IPv4 and IPv6 loopback before it is used, and a forward that fails tries the next port rather than giving up or looping.
4. The master's own listening sockets on the Mac never show as a local row's ports.
5. Probing ports never slows the 2-second session probe, and a host whose `ss` is missing or fails shows no ports rather than an error.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Where ports are read | `canopy-host probe --ports`, the same probe with one more list | One ssh session per round, and the session list it needs for attribution comes in the same answer. |
| How often | Every 5 seconds per host, by time since the last ports probe, inside the 2-second probe loop | The spec's 5 seconds, without a second loop. |
| Forward target on the host | The address the server listens on: `127.0.0.1` for a wildcard or IPv4 loopback, `[::1]` for IPv6 loopback only, else the address itself | A Vite server on `::1` alone refuses `127.0.0.1`. |
| Mac port | The same port when nothing listens there on `127.0.0.1` or `::1`, else the next free one up to 65535, skipping ports other forwards hold | A local server on `::1` would otherwise catch `localhost:5173`. |
| A Mac port that frees later | The forward keeps its port | Moving a forward under an open browser tab breaks it. |
| Ports in the host's ephemeral range | Left out, read from `/proc/sys/net/ipv4/ip_local_port_range` | The same rule as local ports. |
| `ports stop <n>` | Matches a remote port by its host port or its Mac port | An agent on the host knows the first, one on the Mac may know either. |
| Stopping | `canopy-host stop-port --port <n> --pid <pid>...`: SIGTERM and SIGCONT, then SIGKILL after 3 seconds to those still listening | The same contract as `PortStopper`, checked on the host so a reused pid is never signalled. |

## What ssh does, checked on hindie-box

Checked on 2026-10-09 with OpenSSH on this Mac and Ubuntu 24.04's sshd:

- `ssh -O forward -L <p>:127.0.0.1:<q>` binds both `127.0.0.1:<p>` and `[::1]:<p>` on the Mac, in the master's process.
- When only one of the two is taken, the forward still succeeds and exits 0, bound to the other alone, so a local server on one family would catch some of `localhost:<p>`. Hence the chooser checks both before forwarding.
- When both are taken, it fails with "mux_client_forward: forwarding request failed: Port forwarding failed" and exits 255.
- Forwarding the same `-L` again exits 0, and cancelling one that does not exist prints "port not forwarded" and also exits 0.
- An IPv6 target is written `<p>:[::1]:<q>`, and works for a server bound to `::1` alone.
- `ss -ltnpH` prints `LISTEN 0 5 127.0.0.1:18431 0.0.0.0:* users:(("python3",pid=40275,fd=3))`, `[::1]:18432`, `[::]:22`, and `127.0.0.53%lo:53`; sockets of other users, root's here, have no `users:` part.
- The host's ephemeral range is `32768 60999`.
- A stream-local `-R` forward leaves its socket file behind when the master stops, and a later `-O forward -R` to that path fails with 255 until it is removed.

## File Structure

New:

| File | Responsibility |
|---|---|
| `Sources/CanopyCore/Hosts/RemotePorts.swift` | `RemoteListeningPort`, attribution to remote rows, choosing the Mac port, the forward target |
| `Sources/CanopyCore/Hosts/HostForwards.swift` | one host's forwards: the wanted set against the current one, through the master |
| `Tests/CanopyCoreTests/RemotePortsTests.swift`, `HostForwardsTests.swift`, `HostPortsScriptTests.swift` | tests |

Modified:

| File | Change |
|---|---|
| `Hosts/HostFiles.swift` | `probe --ports`, `stop-port` in `canopy-host`; the version moves |
| `Hosts/HostProbe.swift` | decode ports |
| `Hosts/SSHCommand.swift` | `forwardLocal(local:target:)`, `cancelLocal(local:target:)` |
| `Hosts/HostConnection.swift` | owns its `HostForwards`, cleared when the master stops |
| `Hosts/HostActivity.swift` (`HostMonitor`) | ports every 5 s, attribution, forwards, the latest remote ports per host |
| `Ports/PortAttribution.swift` | `RowPort.remote` |
| `Rows/RowLifecycle+Ports.swift` | merges remote groups, stops remote ports on the host, leaves out the masters' pids |
| `Control/PortMethods.swift`, `CanopyCLI/PortsCommand.swift`, `CanopyCLI/AgentGuide.swift` | `host`, `localPort`, and the forward's error in `PortInfo` and the table |
| `CanopyApp/Sidebar/PortsPanel.swift`, `CanopyApp/AppModel.swift` | the server mark, `5173 → 5174`, the error on hover |
| `scripts/fake-ssh` | `-O forward -L` and `-O cancel -L` through a small Python proxy |
| `scripts/e2e-hosts.sh`, `scripts/ui-fixture.sh` | a remote dev server end to end, and one in the fixture |

---

### Task 1: The host lists its ports and stops them

**Files:** modify `Hosts/HostFiles.swift`, `Hosts/HostProbe.swift`; test `HostPortsScriptTests.swift`, `HostProbeTests` (existing, if any).

**Interfaces:**
- `canopy-host probe --server <name> --home-id <id> --ports` adds `"ports": [{"port": 5173, "address": "127.0.0.1", "processes": [{"pid": 812, "name": "node", "ancestors": [800, 1], "folder": "/home/u/x"}]}]`, from `ss -ltnpH`; lines without `users:` (other users' sockets) are skipped; the same port on several addresses is one entry, with the loopback-friendly address by the rule in Decisions; ports in the ephemeral range are left out.
  Ancestors come from the `ps -A -o pid=,ppid=,tpgid=,comm=` table the probe already reads; folders from `/proc/<pid>/cwd`, else `lsof -a -p <pid> -d cwd -Fn` when there is no `/proc` (the fake host is the Mac).
  Without `ss`, or when it fails, `ports` is `[]`.
- Each session in the probe also carries `pid` (the pane's shell), which it already prints.
- `canopy-host stop-port --port <n> --pid <pid>...`: for each pid that `ss` shows listening on the port, SIGTERM then SIGCONT; waits up to 3 seconds for them to let go; SIGKILLs those still listening; prints `{"killed": [pids]}`. Pids not listening on the port are left alone.
- `HostProbe.Report` (which already has `sessions` and `pending`) gains `shells: [String: Int32]` (session to shell pid) and `ports: [RemoteListeningPort]`, and `HostProbe.command(homeID:ports:)` adds `--ports` when asked.
  The argument check in `canopy-host` accepts `--ports` only as the last argument of `probe`.
- `HostFiles.version` changes, so hosts reinstall.

**Tests** (Python against a stand-in `ss` first on PATH that prints fixed lines, and real child processes for ancestry): IPv4, IPv6, wildcard, `%lo` scoped, and several processes on one socket parse; the address rule; ephemeral ports go; a line without `users:` goes; missing `ss` gives `[]`; a process started by a session's shell lists that shell among its ancestors; `stop-port` stops a Python listener, leaves a pid not on the port alone, and kills one that ignores SIGTERM; Swift decodes the output.

**Commit:** `feat: canopy-host lists the host's listening ports and stops them`

### Task 2: Attribution, the Mac port, and the forward commands

**Files:** create `Hosts/RemotePorts.swift`; modify `Hosts/SSHCommand.swift`; test `RemotePortsTests.swift`, `SSHCommandTests.swift`.

**Interfaces:**
- `RemotePortAttribution.assign(_ ports: [RemoteListeningPort], rows: [RemoteRowEntry], sessions: [String: String] /* session to stand-in */, shells: [String: Int32]) -> [String: [RemoteListeningPort]]` by stand-in: the row of the nearest session shell among a process's ancestors, else the row whose remote path holds its folder (deepest), else none.
  A port with processes in two rows goes to the first process's row.
- `LocalPortChooser.port(for remote: UInt16, taken: Set<UInt16>, isFree: (UInt16) -> Bool) -> UInt16?`: `remote` when free and not taken, else the next above, nil past 65535.
- `LocalPortChooser.isFree(_:)`: binds `127.0.0.1` and `::1` (SO_REUSEADDR off) and closes; free only when both bind, or when `::1` is unavailable on the Mac.
- `RemoteListeningPort.target` (`127.0.0.1`, `[::1]`, or the address).
- `SSHCommand.forwardLocal(local: UInt16, target: String, port: UInt16)` -> `-S <control> -O forward -L <local>:<target>:<port> <alias>`, and `cancelLocal` with `-O cancel`.

**Tests:** ancestry wins over folder; folder fallback picks the deepest row and ignores a sibling with a shared prefix; a port in no row is left out; the chooser skips taken and busy ports and returns nil at the top; `isFree` is false for a port a test listener holds on `::1` only and on `127.0.0.1` only; the argv for both commands, IPv6 target included.

**Commit:** `feat: remote ports find their row and a port on the Mac`

### Task 3: Forwards and the 5-second ports probe

**Files:** create `Hosts/HostForwards.swift`; modify `Hosts/HostConnection.swift`, `Hosts/HostActivity.swift`, `Workspace/Workspace+Hosts.swift`, `scripts/fake-ssh`; test `HostForwardsTests.swift`, `RemoteRowTests.swift`.

**Interfaces:**
- `HostForwards` (inside `HostConnection`'s isolation): `apply(_ wanted: [RemoteListeningPort], run: …) async -> [UInt16: PortForward]` keyed by remote port, where `PortForward { local: UInt16?; error: String? }`.
  New ports get a Mac port and `-O forward`; a forward that exits nonzero tries the next free port, up to 20 tries, then keeps ssh's message for the panel and is tried again on the next round.
  Ports no longer wanted are cancelled with `-O cancel`.
  A new master generation starts from none, and stopping the master forgets them all.
- The Mac ports every host's forwards hold are known to the workspace, so one host never picks a port another host's forward holds.
- `HostConnection.forwardPorts(_:taken:) async -> [UInt16: PortForward]` and `HostConnection.masterPID` (nil while not connected).
- `HostMonitor` asks for ports when 5 seconds have passed for that host, attributes them with the host's remote rows and the panes' sessions, applies the forwards, and keeps `remotePorts: [String /* host */: [PortGroup]]`, which drops a host once it is no longer connected.
- `fake-ssh -O forward -L local:target:port` starts a detached Python TCP proxy from `127.0.0.1:local` and `[::1]:local` to `target:port`, records its pid with its own start time beside the control path, and fails with exit 255 and ssh's "Port forwarding failed" text only when it can bind neither, as real ssh does; `-O cancel -L` and the master's exit stop the proxies they recorded, only after checking each pid still runs that proxy.

**Tests:** on the fake host, a Python HTTP server started in a remote row's tmux session is forwarded, and a GET through the Mac port answers; a busy Mac port (a test listener) moves the forward to the next; the server stopping cancels the forward and frees the Mac port; dropping the master clears the forwards, and a reconnect forwards again; a server in no remote row is not forwarded; with a stand-in runner, two hosts wanting the same Mac port get two ports (the chooser's `taken` spans every host's forwards, kept by the workspace), and a failed forward moves to the next port, keeping ssh's message once it gives up.

**Commit:** `feat: remote rows' ports are forwarded to the Mac`

### Task 4: Ports panel, `canopy ports`, and stopping on the host

**Files:** modify `Ports/PortAttribution.swift`, `Rows/RowLifecycle+Ports.swift`, `Control/PortMethods.swift`, `CanopyCLI/PortsCommand.swift`, `CanopyCLI/AgentGuide.swift`, `CanopyApp/Sidebar/PortsPanel.swift`, `CanopyApp/AppModel.swift`; tests in `RemoteRowTests.swift` or a new `RemotePortsControlTests.swift`, and `PortsTests` (existing).

**Interfaces:**
- `RowPort.remote: RemotePort?` with `host`, `local: UInt16?`, `error: String?`; nil for local ports.
- `portGroups()` merges `HostMonitor`'s remote groups into sidebar order, and leaves out every connected master's pid from the local scan.
- `PortInfo` gains `host: String?` and `localPort: Int?`; the table gains a HOST column only when a port has one, and PORT reads `5173 → 5174` when the two differ.
- `stopPort` and `stopPorts` split by host: local ports go to `PortStopper`, remote ones to `canopy-host stop-port` through the master, and `killed` merges both.
- `ports stop <n>` matches `port` or `localPort`.
- The panel: a remote group's row mark is the server mark (`RemoteMark`), a badge reads `5173 → 5174` when the Mac port differs, clicking opens `http://localhost:<Mac port>`, a port without a forward is dimmed with ssh's message on hover, and the stop tooltip names the host.
- The agent guide's ports section says remote rows' ports are forwarded and how they show.

**Tests:** `ports list --json` in a remote row shows `host` and `localPort` for a forwarded fake-host server; the table's PORT and HOST columns; `ports stop 5173` from the remote row stops the server on the fake host (the test's own child, checked by pid and command) and never calls `kill` locally (a `PortStopper` scan stand-in records calls); `ports stop <Mac port>` does the same; the master's pid is not in the local groups.

**Commit:** `feat: remote ports in the ports panel and canopy ports`

### Task 5: End to end and UI checks

**Files:** `scripts/e2e-hosts.sh`, `scripts/ui-fixture.sh`.

**Steps added, on the fake host and `--host`:**
- `python3 -m http.server <port>` typed in the remote pane shows in `canopy ports --json` with `host` and `localPort`, and `curl http://localhost:<localPort>` answers from the host.
- A local listener on the same port first makes the forward take the next port.
- `canopy ports stop <port>` in the remote pane stops it, and the forward goes.
- The fixture's remote row runs a server, so the ports panel shows a remote port; window shots in light and dark of the panel with `5173 → 5174`.

**Commit:** `test: remote ports end to end`

### Task 6: Merge bar

- [ ] `make lint`, `make build` 0 warnings, `make test` three clean runs.
- [ ] `make e2e`, and `scripts/e2e-hosts.sh --host hindie-box`.
- [ ] UI checks: window shots of the ports panel with a remote port, light and dark.
- [ ] An independent opus review of `git diff main...HEAD` with the spec and this plan; findings fixed test-first, listed under After Review.
- [ ] CI `check` green.
- [ ] PR with click checks and Decisions to review; print `READY: PR #<n> <url>`.
