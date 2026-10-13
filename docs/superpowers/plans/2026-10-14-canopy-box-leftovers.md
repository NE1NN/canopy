# Canopy on the box: the last deferred items

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** settle every item the milestone plans deferred that milestone 8 left: fix the ones that can hurt or that lack a test, and record why the rest stay as they are.

**Architecture:** fixes in place, each with a test that fails without it where a test can reach it.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`; the deferred lists in the After Review sections of the milestone 2, 3a, 3b, 4, and 5 plans, and the milestone 8 plan's Rulings.

## Fixed

- [x] The relay's framing is tested on the box: heartbeats during a long call, a relayed call stopping when its caller hangs up, and a hook landing after its caller hangs up.
  The last found a bug: the acknowledgement went out before the hook started, so a hook whose process was already gone was dropped. The work now starts first.
- [x] canopy-box holds a lock on its home (`box/serve.lock`) from the start, so two daemons started at the same moment never both load and save its state; `InstanceLock` moved to `CanopySystem` to build on Linux.
- [x] canopy-box reads the machine's name on a thread of its own at start, as it may take a DNS lookup, rather than on its actor's first poll.
- [x] `bundle.sh` without Docker leaves out a canopy-box older than its sources, as hosts would install it over a newer build; hosts keep theirs.

## Left as they are

- `nextPane` sent as 1 in `box.adopt`: the box takes the larger of it and its own count, and moves past every pane it has, so the value never decides a name.
- The box's phone port read once at start: nothing sets `phonePort` yet; when the Mac grows a setting for it, applying a change belongs with that setting.
- `StateStore.save`'s fsync and `DirectoryWatcher`'s FSEvents setup on the app's pool: they hold it for milliseconds on a save or a new watch, tests already keep their own work off the pool, and moving the save off the workspace actor would give up its ordering.
- A tmux listing for each hook from a session outside every row: such hooks come only from sessions canopy-box does not track, and a listing takes milliseconds.
- The Linux subprocess wait after a timeout's SIGKILL: it holds only that call's own thread, and box code shares no handle.
- `pidfd_open` in place of the 5 ms poll: the box's children are short git and tmux runs, so the poll costs little, and `pidfd_open` would still need the poll on kernels before 5.3.

## Checks

`make lint`, `make build` with no warnings, `make test` three times clean, `make e2e`, `make linux`, an opus review with its findings fixed below, and CI's `check`.
