# Canopy on the box, Milestone 8: finishing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** close the spec's last gap and the deferred issues that would hurt someone using the box: new hosts run canopy-box from the start, removing a host stops it, and the link, the daemon, and the listeners hold up under races, restarts, and exhausted resources.

**Architecture:** no new parts.
`host add` upgrades a new host through the same path as `host upgrade`, and `host rm` stops the box's service through `BoxInstall.stop` without waking the host.
The rest are fixes in place, each with a test that fails before it.

**Tech Stack:** Swift 6.4, Swift Testing, the fake host (`scripts/fake-ssh`), tmux.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "Settings" ("New hosts added with `canopy host add` are upgraded from the start"), "The service", and "Failures"; the deferred lists in the After Review sections of the milestone 3a, 3b, 4, and 5 plans.

## Global Constraints

- Nothing runs against hindie-box or AWS; the e2e uses the fake host, and `scripts/e2e-hosts.sh --host <alias>` never starts canopy-box on its own.
- Swift 6 language mode, strict concurrency, no warnings; markdown one sentence per line, no em dashes; conventional commits, no trailers.

## Rulings

- `host add` upgrades only a host it has not seen; adding again updates settings and touches no daemon.
  `--no-box` keeps a new host on the Mac's relay.
  An upgrade that fails leaves the host added, on the relay, with a warning naming `canopy host upgrade <host>`.
- `host rm` stops an upgraded host's canopy-box and removes its unit, reaching the host without its wake command; a host it cannot reach is removed anyway, with a warning saying how to stop canopy-box there.
- Of the deferred items, these are fixed here, most severe first: two `ensureBoxLink` callers racing; a plain daemon left running beside a new systemd unit; the TCP listener spinning when out of descriptors; the box's activity log trapping on a write error and growing forever; a hook or `term` call reaching another host's pane by session name; a host whose `repos` key differs from the Mac's repo name; a shared-folder row and a box row sharing a stand-in; rows of a repo taken out of the box's settings; the reply delivery tracker.
- Left as they are, each harmless today or perf-only: `nextPane` sent as 1, the box's phone port read once at start, `ProcessInfo.hostName` on the first poll, a tmux listing per hook outside every row, `StateStore`'s fsync and FSEvents setup on the pool, the Linux subprocess poll, the relay framing tests for heartbeats, and `bundle.sh` without Docker, which already warns.

## Review Focus

1. Removing an upgraded host that is off neither wakes it nor fails, and says canopy-box may still run there.
   Pinned by `removingAnUpgradedHostThatIsOffWarnsWithoutWakingIt` in Task 1.
2. A new host whose canopy-box cannot start is still added and usable through the Mac.
   Pinned by `aNewHostWhoseBoxCannotStartStaysOnTheRelayAndSaysHowToRetry` in Task 1.
3. Two link starts at once leave one forward and a working link.
   Pinned in Task 2.
4. Out of descriptors, the phone listener waits instead of spinning, and accepts again once some free up.
   Pinned in Task 3.
5. After `--undo` on two hosts with panes named alike, each host's hooks reach its own pane.
   Pinned in Task 4.

---

### Task 1: `host add` upgrades new hosts, and `host rm` stops the box

- [x] `HostAddParams.box`, `--no-box`, the handler's upgrade after a new host's add; `HostConnection.connect(waking:)`; `Workspace.stopBox` from `removeHost`, whose warnings `host rm` prints.
- [x] Tests: `HostBoxLifecycleTests`; the hosts e2e adds the fake host again at its end and checks canopy-box starts and stops; the fixture and the e2e's earlier adds pass `--no-box`.

### Task 2: the link and the daemon

- [ ] `ensureBoxLink` keeps one start in flight per host, which other callers await.
- [ ] Installing under systemd stops a daemon started as a plain process first.

### Task 3: listeners and logs

- [ ] `TCPListener` suspends its accept source for 100 ms when out of descriptors, as `UnixListener` sleeps.
- [ ] The box's activity log appends without trapping and keeps its last 5 MB.

### Task 4: rows and panes across hosts

- [ ] Hooks and pane lookups by session name match the host the relay names.
- [ ] The box gets the host's own `repos` key, and its snapshots map back by it.
- [ ] A stand-in leaf another entry holds gets a distinct name.
- [ ] Rows of a repo taken out of the box's settings can be removed through the worktree's own git directory.

### Task 5: reply delivery on the box

- [ ] Each reply's tracker ends at its deadline on its own, and only the oldest reply waiting in a pane is marked delivered per take.

### Checks

`make lint`, `make build` with no warnings, `make test` three times clean, `make e2e`, `make linux`, an opus review with its findings fixed below, and CI's `check`.
