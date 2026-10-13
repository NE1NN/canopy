# Canopy on the box, Milestone 3b: the Mac's link

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac installs and runs `canopy-box` on a host, talks to it through its ssh master, and on an upgraded host takes the host's rows, panes, and agent states from it, so the box is the one source of truth; `canopy host upgrade` switches a host over and `--undo` switches it back.

**Architecture:** The app bundle carries `canopy-box` for x86_64 and arm64 Linux.
`BoxInstall` copies it to `~/.canopy/<home id>/bin/canopy-box` when the host's copy differs, writes a systemd user unit, and starts it.
`BoxLink`, one per upgraded host, forwards a socket of the app's own to the daemon's `box.sock` through the master, says hello, configures the daemon, subscribes, and makes requests.
`Workspace` takes an upgraded host's rows from the snapshots and makes and removes its rows through the link; `BoxMirror` on the main actor opens tabs for the daemon's panes, mirrors their agents onto the Mac's panes, and sends what happens at the Mac (closing a pane, keys that move an agent, seeing a finish) to the daemon.
The host's relay uses `box.sock` once the Mac has marked the host adopted, so hooks and the box's CLI go to the daemon.

**Tech Stack:** Swift 6.4, Swift Testing, `scripts/fake-ssh` with a fake `systemctl`, tmux.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "The Mac's link to the box", "The CLI on the box", "The service", "Switching hindie-box over", and Delivery item 3.

## Global Constraints

- A host that is not upgraded behaves exactly as before: every existing test and `make e2e` pass unchanged.
- Nothing here runs against hindie-box: the author's steps (lingering, the `busy` check, `host upgrade hindie-box`) stay theirs, and `scripts/e2e-hosts.sh --host <real host>` skips the box part unless `--with-box` is passed.
- The daemon is installed for the Mac's own home id only; e2e runs use a throwaway home on the fake host.
- Swift 6 language mode, strict concurrency, no warnings.
- Markdown one sentence per line, no em dashes.
- Conventional commits, no trailers.

## Rulings carried from the spec

- The Mac keeps probing an upgraded host with `canopy-host probe` for its panes' busy state, titles, folders, and ports, rather than taking them from the daemon's snapshot.
  The probe is proven, ports need it anyway, and the snapshot then carries only what the box owns: rows, panes, and agents.
  The Mac stops replaying kept reports on an upgraded host, since the daemon replays them.
- The daemon's version is the SHA-256 of its binary: the Mac copies its bundled binary whenever the host's differs, so every build updates the box, and `box.hello` still carries the protocol version.
- Without systemd, as on the fake host or a box whose user manager is not running, the install starts the daemon with `setsid nohup`, and says lingering is off; systemd is used where `systemctl --user` answers.
- The Mac's sidebar does not show the box's clones as rows: the Mac has its own main checkout, and the phone shows the box's main rows from milestone 5.
- Keys typed into a box pane at the Mac reach the daemon's key rules through a new method, `box.typed`, so Escape at the Mac clears a working agent there too.

## Review Focus

1. A daemon that restarts, or a master that drops and comes back, must bring the link back with a fresh snapshot, never leaving the Mac's panes on stale agent states.
   Pinned by `aLinkComesBackAfterTheDaemonRestarts` in Task 3.
2. A pane the author closes at the Mac must not come back as a new tab from a snapshot sent before the daemon closed it.
   Pinned by `aClosedPaneIsNotReopenedByAnOldSnapshot` in Task 5.
3. Upgrading must not touch a session or a worktree, and `--undo` must give back every row and pane, including panes the daemon made.
   Pinned by `upgradeAndUndoKeepEverySession` in Task 6 and the e2e.
4. A host whose `box.sock` is gone, as after `--undo`, must have its relay use the Mac's socket again at once.
   Pinned by `theRelayUsesTheBoxOnlyWhileItsSocketExists` in Task 4.
5. An install over a running daemon must replace the binary atomically and restart it, never leaving a half-written file to run.
   Pinned by `anInstallReplacesTheBinaryWhole` in Task 2.

---

### Task 1: Daemon hardening from 3a's review

**Interfaces:** `BoxMethod.typed` (params `BoxKeysParams`), `BoxDaemon.typed(_:)`.

Steps:
- [ ] Tests: `aClientThatSendsAfterItsRequestDoesNotSpin` (a relay call whose client writes more bytes keeps its thread under 20% CPU), `aFullDisconnectCancelsItsCalls` (a `box.wait` from a client that closes ends at once), `paneNewTypesItsCommandOnceTheShellIsUp`, `readSaysWhyTmuxFailed`, `typedKeysMoveTheAgentWithoutReachingThePane`.
- [ ] Implement: `hungUp` drains what it peeks; the server cancels a connection's calls when the peer hangs up fully (POLLHUP), not on a half-close; `UnixListener` sleeps 100 ms on EMFILE; `paneNew` waits up to 5 s for the pane's shell to be in the foreground; `read` keeps tmux's message; `box.typed`.
- [ ] Commit: `fix: canopy-box hardening from its review, and box.typed`.

### Task 2: The binary on the host, and its service

**Interfaces:**
- `BoxBinaries`: where the app's bundled binaries are (`Contents/Resources/box/<arch>/canopy-box`), or `CANOPY_BOX_BINARY` for tests and e2e; `func binary(forHostArch:) -> String?`.
- `BoxInstall.install(on: HostConnection, homeID:, binaries:) async throws -> BoxInstallReport { updated: Bool, systemd: Bool, lingering: Bool? }`.
- `BoxInstall.stop(on:homeID:)`, for `--undo`.
- `HostProcessLauncher.run(_:timeout:stdin:)`, so a binary goes up through the master's standard input.

Steps:
- [ ] `scripts/bundle.sh` runs `make box` when Docker answers and copies both binaries into the bundle; without Docker it warns and leaves them out, and hosts then cannot be upgraded.
- [ ] Tests with a stand-in launcher that records commands and a fake host folder: `anInstallCopiesOnlyWhenTheHashDiffers`, `anInstallReplacesTheBinaryWhole` (temporary file then rename), `theUnitRestartsAlwaysAndStartsAtBoot`, `withoutSystemdItStartsDetached`, `lingeringOffIsReported`.
- [ ] Implement; commit `feat: the Mac installs canopy-box on a host and keeps it running`.

### Task 3: BoxLink

**Interfaces:**
- `SSHCommand.forwardSocket(local:remote:)`, `-O forward -L local:remote`; `HostPaths.boxSocket(home:homeID:alias:)` beside the relay's.
- `public actor BoxLink { init(alias:, socketPath:, configure: BoxConfig); func start(); func stop(); func snapshots() -> AsyncStream<BoxSnapshot>; func call<R: Decodable>(_ method: String, _ params: some Encodable) async throws -> R; var isConnected: Bool }`, reconnecting every second while started.
- `scripts/fake-ssh` takes `-L <local socket>:<remote socket>`, linking the paths as it does `-R`.

Steps:
- [ ] Tests in `CanopyCoreTests` against an in-process `BoxServer`: `theLinkConfiguresSubscribesAndCalls`, `callsAnswerOutOfOrder`, `aLinkComesBackAfterTheDaemonRestarts`, `aCallWithoutALinkFailsAsHostUnreachable`.
- [ ] Implement; commit `feat: the Mac's link to canopy-box`.

### Task 4: Rows from the box, and the relay's switch

**Interfaces:**
- `HostEntry.box: Bool`, saved as `"box": true` in the host's section.
- `Workspace.applyBoxSnapshot(_:host:)`: the host's remote rows become the snapshot's rows that are not main, matched to repos by `HostEntry.repos` names, with stand-ins made for new ones and rows gone from the box forgotten, their terminals closed by the caller.
- On an upgraded host, `createRemoteRow`, `removeRemoteRow`, and `remoteHasUncommittedChanges` go through the link, and `refreshRemote` reads nothing.
- `HostFiles` relay: uses `~/.canopy/<home id>/box/box.sock` while it and the `adopted` mark beside it exist, else `$CANOPY_SOCKET`.

Steps:
- [ ] Tests: `aSnapshotsRowsBecomeRemoteRows`, `aRowGoneFromTheBoxIsForgotten`, `rowNewOnAnUpgradedHostGoesThroughTheLink`, `theRelayUsesTheBoxOnlyWhileItsSocketExists` (the relay script run against a temporary home with and without `box.sock` and the `adopted` mark).
- [ ] Implement; commit `feat: an upgraded host's rows come from canopy-box, and its relay talks to it`.

### Task 5: BoxMirror: panes and agents on the Mac

**Interfaces:**
- `PaneAgent.init(mirroring: BoxPane)` in `CanopyAgents`; `Pane.mirror(_ agent: PaneAgent)`, which reports the change as any other.
- `@MainActor final class BoxMirror { init(workspace:, terminals:); func apply(_ snapshot: BoxSnapshot, host: String) }`: opens a tab for each box pane with no Mac pane (by `remoteSession`), mirrors agents, and remembers panes closed at the Mac for 10 s so an older snapshot cannot reopen them.
- `RowLifecycle` on an upgraded host: a closed pane sends `box.paneClose`, keys that change an agent send `box.typed`, and a seen pane sends `box.seen`.
- `HostMonitor` skips replaying kept reports on upgraded hosts.

Steps:
- [ ] Tests: `aBoxPaneOpensATabInItsRow`, `anAgentFromTheBoxShowsOnItsPane`, `aClosedPaneIsNotReopenedByAnOldSnapshot`, `closingAPaneAtTheMacClosesItOnTheBox`, `escapeAtTheMacReachesTheBox`, `seenAtTheMacReachesTheBox`.
- [ ] Implement; commit `feat: an upgraded host's panes and agents come from canopy-box`.

### Task 6: `canopy host upgrade` and `--undo`

**Interfaces:**
- `HostMethod.upgrade` (`HostUpgradeParams { alias, undo }`, result `HostUpgradeResult { alias, rows, panes, missing, warnings }`); `canopy host upgrade <alias> [--undo]`.
- `Workspace.upgradeHost(_:)`: connect, install files, `BoxInstall.install`, link up, `box.configure`, `box.adopt` with the host's rows, the Mac panes' sessions and agents, and the next pane number, then `box: true`.
- `Workspace.undoUpgrade(_:)`: `box.release`, the released rows back into `state.json`, the released panes onto their Mac panes or new tabs, `BoxInstall.stop`, `box: false`.
- `host list` shows `box` in STATE for an upgraded host; `HostInfo.box`.

Steps:
- [ ] Tests: `upgradeAndUndoKeepEverySession` (against a fake host folder, a stand-in launcher, and an in-process daemon), `upgradeNeedsTheBinaries`, `undoGivesBackPanesTheBoxMade`.
- [ ] Implement; commit `feat: canopy host upgrade and --undo`.

### Task 7: The e2e

- [ ] `scripts/e2e-hosts.sh`: build `canopy-box` for macOS, point `CANOPY_BOX_BINARY` at it, put a fake `systemctl` on the fake host, and after today's steps: `host upgrade`, a hook from a box pane's relay reaching the Mac's dot, `canopy row new` run in a box pane making a row that appears on the Mac, a pane opened on the box appearing as a tab, `host upgrade --undo` giving it all back, and the daemon stopped.
  With `--host <alias>`, the box part runs only with `--with-box`.
- [ ] `make e2e` passes; commit `test: the hosts e2e upgrades the fake host to canopy-box and back`.

## Verification

- `make lint`, `make build`, `make test` three times, `make linux`, `make box`, `make app` with the binaries in the bundle, `make e2e`.
- An opus review of the whole branch, its findings fixed, and an After Review section here; CI's `check` and `linux` pass.

## After Review

An opus review of the whole branch found one critical issue and seven important ones; each is fixed:

- **Critical: a failed `host upgrade` left a running daemon that swallowed every hook.** The relay chose `box.sock` whenever it existed, so hooks went to a daemon that had not taken the panes, and `--undo` refused a host that was not marked upgraded.
  The relay now uses the box only once the Mac has written `~/.canopy/<home id>/box/adopted`, after the box takes the panes; a failed upgrade removes the mark and stops the daemon, and `--undo` removes it before the box lets go (`theRelayUsesTheBoxOnlyWhileItsSocketExists`, red then green).
- A daemon restart kept the link waiting up to two minutes on a call that would never be answered, since ssh's forward takes a connection and closes it while the host's socket is gone; calls now fail as the connection ends, so the link comes back within a second (`aForwardWithNoDaemonBehindItIsTriedAgainEverySecond`, red then green).
- Stopping a link cleared its forward's generation, so a second upgrade on one connection removed the socket ssh would not bind again; the forward now stays for its connection.
- `--undo` saved the host as not upgraded only after stopping the daemon, so a failed stop left an empty snapshot to forget every row; it saves first, and a failed stop is a warning.
- Rows gone from a snapshot ended their sessions through the Mac's panes; their terminals now close here and the box ends the sessions it removed.
- A pane closed at the Mac while the link was down, or before the box had seen it, kept its session and came back; tmux now ends what the box did not (the e2e closes a box pane at the Mac and sees its session go).
- The app never updated or restarted the daemon after upgrading; it now checks and starts it once per connection.
- `--undo` gave back only panes the Mac already had; it now restores missing rows and opens tabs for the box's panes.

Deferred minors, for milestone 4, which reworks the box's side for phones:

- Each call's timeout task is never cancelled, holding the link for up to two minutes per call.
- `nextPane` is sent as 1; harmless while box panes are `b<N>` and the Mac's `p<N>`.
- A hook naming a session falls back to any host's pane with that session; after `--undo` on two hosts at once, a `b1` could land on the wrong one.
- Two callers of `ensureBoxLink` in one connection can forward twice.
- `bundle.sh` without Docker bundles whatever `build/box` holds, which may be stale.
- A daemon started without systemd, then a host that gains systemd, can run two daemons, the second restarting every two seconds.
- When a host's `repos` key differs from the Mac repo's name, adopt and `rowNew` name the repo differently.
- A shared-folder row and a box row with one leaf name share a stand-in.
- Tests the plan named that are covered elsewhere or not at all: `paneClose` is in the e2e, `typed` and `seen` have no test, and nothing installs a different binary over a running daemon.
