# Panes on an upgraded host start in the Mac's stand-in folder

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every pane on an upgraded host is a pane of canopy-box, so its agent shows on the Mac and the phone, and the sessions already started in the wrong folder show theirs once the fix is installed, with nothing restarted.

**Architecture:** fixes in place on both sides of the box link, each with a test that fails without it, and e2e steps on the fake host.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md` (canopy-box is the one source of truth for an upgraded host's rows and panes).

## What was wrong

The author saw no agent on a hindie-box row whose Claude had worked for 25 minutes.
All 21 tmux sessions on the box had started with the Mac's stand-in folder, such as `~/.canopy/remote/hindie-box/solis-v1/<row>` on the Mac.
The box has no such folder, so tmux started each in the home folder.
canopy-box took a session as a pane only when its start folder was inside one of its rows, so it had 18 rows and no panes, and dropped every hook from them.

Chat tabs milestone 1 (PR 48) moved a terminal's state into `TerminalBody`.
Before it, a remote pane's folder fell back to `context.remote?.path`, the row's folder on the host; after it, to `context.rowPath`, the stand-in.
Reproduced on the fake host from `main`: a pane opened in a remote row of an upgraded host started in the stand-in, and canopy-box listed no panes.
No other place since PR 48 swaps a host path for a stand-in.

## Tasks

- [x] A remote pane starts in the row's folder on the host (`PaneRemote.startFolder`).
  A folder outside the row there, such as a stand-in an older build saved or the home folder tmux fell back to, gives way to the row's folder, in a new pane, a restored one, `host.attach`, and `host upgrade`.
- [x] canopy-box takes a session outside every row by the row its `CANOPY_ROW_PATH` names, read with `tmux show-environment`, or else by the row holding its current folder (`BoxDaemon.placement`).
  The poll, the reconcile at start, and a hook from a session the box has not seen yet share one path (`take`).
  Every live session on hindie-box carries the right `CANOPY_ROW_PATH`, so this repairs them on the first poll after the new canopy-box starts.
- [x] The systemd unit stops canopy-box alone (`KillMode=process`).
  A tmux server canopy-box starts, as for a phone's task that is the first pane since the host booted, runs in its unit; without this an update's restart, or a crash, would end every session and agent in it.
- [x] e2e on the fake host: a pane opened on the upgraded host starts in its row's folder there and canopy-box takes it, and a session started outside every row with `CANOPY_ROW_PATH` set is taken, shows on the Mac, and closes from there.
  The first step fails on `main`.
- [x] The hosts e2e names what holds the port when its local listener cannot bind, for a flake seen once in this work and not reproduced in two more runs.

## Decisions to review

- The Mac still starts an upgraded host's sessions over its own ssh, and canopy-box takes each on its next poll or the pane's first hook.
  Having canopy-box start them (`box.paneOpen`, built and then dropped after review) would have lost the ssh login's `SSH_AUTH_SOCK` and locale in every new pane, put the tmux server in canopy-box's systemd unit, where it dies with the user's manager when lingering is off, and kept new panes from opening while canopy-box is down.
  With the right start folder and `CANOPY_ROW_PATH` on every session, the box cannot miss one.
- Sessions are placed by their start folder first, then `CANOPY_ROW_PATH`, then their current folder.
  The start folder is the old rule and costs no tmux call; the variable is what the Mac or the box said the pane's row is.
- A remote pane's start folder must be inside its row on the host.
  Before PR 48 a pane whose shell had moved elsewhere restarted there; now it restarts in the row.
- An idle agent in a repaired session shows from its next hook, as when its next prompt starts.
  Its earlier hooks were dropped, and nothing on the box says which transcript belongs to which pane.
- `KillMode=process` leaves anything else canopy-box started running when it stops, such as a git it was waiting on; those end on their own.

## Checks

`make lint`, `make build` with no warnings, `make test` three times clean, `make e2e`, `make linux`, an opus review with its findings fixed below, and CI's `check`.

## After Review

An opus review found three major issues and four minor ones, then rechecked the rework and found one more minor one.

- Major, fixed by dropping `box.paneOpen`: sessions canopy-box started lost the ssh login's environment, could die with the user's systemd manager, and could not open while canopy-box was down.
  The Mac starts sessions as before; see the first decision.
- Minor, fixed: a pane closed while a poll was listing tmux's sessions came back from that listing until the next poll.
  Closes are dated once tmux has killed the session (`closedPanes`), and a listing taken before then cannot bring the pane back.
- Minor, fixed: a session no row holds cost a `tmux show-environment` call on every poll.
  canopy-box remembers it until its folder or the rows change (`unplaced`).
- Minor, gone with `box.paneOpen`: a pane open could report success for a session that had just ended, and the box path threw where the old one coped without a row.
- CodeRabbit, minor, fixed: a session whose `CANOPY_ROW_PATH` was set after it started stayed unplaced while its folder and the rows stayed the same.
  A hook from it looks at the session afresh, since a hook says an agent runs there.
- Not changed: a tmux server canopy-box starts for a phone's task still dies with the user's manager when lingering is off, as before this branch.
  Lingering is the author's step on each host, and `host upgrade` already warns when it is off; it is on for hindie-box.
