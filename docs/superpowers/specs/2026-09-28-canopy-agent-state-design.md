# Canopy agent state design

Date: 2026-09-28
Status: draft for review.
The author approved the design in conversation on 2026-09-28, and this spec writes it down.

## Summary

When an AI agent in a Canopy terminal finishes its turn, Canopy plays a sound and colors the terminal's row.
Green means the agent is done and the author has not looked yet.
Yellow means it is waiting for the author, because it asked a question or needs a permission.
A pulsing dot means it is working.
An idle agent shows nothing, which fixes today's running dot that stays on for as long as `claude` runs.

Canopy learns the state from Claude Code's hooks, which call `canopy agent-hook`.
Other agents report the same states with `canopy term state`, and agents wait on each other with `canopy term wait`.

## Goals

1. Show each pane's agent state in the sidebar, the tab bar, and the pane header.
2. Play a sound when an agent finishes or starts waiting, unless the author is already looking at it.
3. Learn the state from Claude Code however `claude` was started, with no wrapper command.
4. Give agents the same information and control through the CLI.
5. Record state changes in the activity log.

## Non-goals

- Reading a terminal's screen to guess what an agent is doing.
- Hooks for agents other than Claude Code.
  They report with `canopy term state`.
- Desktop notifications.
  The sound and the dots are the whole alert.
- Keeping agent states across relaunches.
  Quitting stops every agent anyway.
- Editing project or local Claude Code settings.
  Canopy only touches the user settings file.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| How Canopy learns the state | Claude Code hooks calling `canopy agent-hook` | Works however `claude` starts, with no wrapper to keep in step with Claude Code's flags. |
| Where the hooks go | Claude Code's user settings file, merged with what is there | Hooks there reach every session, and hook entries merge across settings files, so project hooks keep working. |
| Which session speaks for a pane | The first Claude Code session to report, until it ends | An agent may run `claude -p` inside its own pane, and that session must not move the pane's state. |
| Hook timing | In the background, except `Stop`, `StopFailure`, and `SessionEnd` | Background hooks never hold Claude up, but `claude -p` kills background hooks when it exits, and the last turn's end must still arrive. |
| Look | A solid dot where the running dot is today | The author picked it from the options. |
| Programs that are not agents | No dot in the sidebar or the tab bar | A dev server's row would otherwise keep a dot forever, the problem this fixes. Pane headers keep their running mark. |

## States

A pane has one agent state at a time.

| State | Means |
|---|---|
| none | No agent is reporting, or it has not started a turn. |
| working | The agent is taking a turn. |
| waiting | The agent needs the author: a permission, a question, or a plan to approve. |
| done | The agent finished its turn. |

A done pane is also unseen until the author looks at it, as described under Seen.
The sidebar and the tab bar show green only while it is unseen, but `canopy term list` shows done either way.

States live in memory only.
Quitting Canopy ends every agent, so nothing is saved.

### What changes a state

A state changes on reports from Claude Code's hooks or from `canopy term state`, on keys typed into the pane, and when the agent's program exits.

**Reports** are covered under Hook mapping and CLI.
A report that names the state the pane is already in changes nothing, with one exception.
A done report on a done pane is a new finish, so the pane becomes unseen again and the sound plays.
Agents like Codex report only finished turns, never working, so this is how their second finish shows.

**Keys.**
Claude Code runs no hook when the author interrupts a turn, or when a permission prompt is dismissed with Escape, so Canopy watches for those keys itself.

| State | Key | New state |
|---|---|---|
| working | Escape or Control-C | none |
| waiting on a prompt | Return | working |
| waiting on a prompt | Escape or Control-C | none |

A pane waits on a prompt after any waiting report except a turn that ended on a question.
A turn that ended on a question waits at Claude Code's own input line, where typing only drafts the answer, so that pane waits until the next prompt is submitted.
Text sent with `canopy term send` counts as typed.
A wrong guess corrects itself: if a turn goes on after an Escape that did not interrupt it, its next tool call reports working again.

**Exits.**
When the pane's shell is back in the foreground after a program, the state goes to none.
Canopy already checks each pane's foreground program every second while the window can be seen, and once when it comes back into view.
This clears the state after a crash that skipped `SessionEnd`, and for agents that never report their exit.
Closing the pane, or its shell exiting, clears it too.

### Which reports count

Reports from Claude Code carry the session ID.
A pane listens to one session at a time.
The first session to report to a pane with no session takes it.
Reports from other sessions are ignored until that session lets go, which happens on its `SessionEnd`, when the program exits as above, or when the pane closes.
This keeps a `claude -p` that an agent runs inside its own pane from moving that pane's state.
A `SessionStart` whose source is not `startup` comes from the `claude` that already holds the pane, switching conversations with resume, clear, compact, or fork, so it moves the pane to the new session.
Reports from `canopy term state` carry no session and always count.

Background hooks can arrive out of order.
Each report carries the time its hook process started, which is the order Claude Code started the hooks in.
Canopy ignores a report that started before the last change it applied to that pane.
Changes from keys and exits take the time Canopy saw them.

## Claude Code hooks

### canopy agent-hook

Claude Code's hooks run `canopy agent-hook`.
It reads the hook's JSON from stdin, turns it into a report by the table below, and sends it to the app as a `term.state` request.
It always exits 0 and never prints anything.
A hook's output can reach Claude as context, and a nonzero exit shows as a hook error in the transcript.

It does nothing, quietly, when:

- `CANOPY_PANE` or `CANOPY_HOME` is not set, as outside Canopy's terminals;
- stdin is a terminal, as when a person runs it by hand;
- the event maps to no report;
- the socket is missing or refuses the connection, as while the app is not running.

It never launches the app.
It writes the request and exits without waiting for the reply, and gives up if the socket has not accepted it within one second, so a busy app never holds Claude up.
Hooks run with Claude Code's environment, which it inherited from the pane's shell, so they see the pane's variables.

### Hook mapping

| Event | Matcher | Condition | Report |
|---|---|---|---|
| `SessionStart` | all | | takes the pane, state unchanged |
| `UserPromptSubmit` | | | working |
| `PreToolUse` | `AskUserQuestion\|ExitPlanMode` | | waiting |
| `PermissionRequest` | all | from the main agent, not a subagent | waiting |
| `Notification` | `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` | | waiting |
| `Notification` | `agent_completed` | | done |
| `Elicitation` | all | | waiting |
| `ElicitationResult` | all | | working |
| `PostToolUse`, `PostToolUseFailure` | all | from the main agent, not a subagent | working |
| `Stop` | | a background subagent or workflow is still running | working |
| `Stop` | | the final message ends on a question | waiting |
| `Stop` | | otherwise | done |
| `StopFailure` | all | | done |
| `SessionEnd` | all | | none, and the session lets go of the pane |

- `PostToolUse` is how a pane leaves waiting when a permission is granted away from its keyboard, such as through Remote Control.
  It also moves a pane back to working when a background task wakes the agent after its turn ended.
- Tool calls from subagents are left out.
  A background subagent keeps calling tools while the main agent waits on a question, and those calls must not clear the yellow.
- `PermissionRequest` from a subagent, one whose input has `agent_id`, is left out.
  Claude Code also runs it for background subagents that cannot show a prompt, and denies those at once.
  When a subagent's prompt does show, the `permission_prompt` notification follows about six seconds later.
- `SubagentStop` is not hooked, because a subagent finishing is not the agent finishing.
- `idle_prompt` is not hooked.
  It comes a minute after a turn ends and adds nothing.
- The question rule reads `last_assistant_message`.
  It takes the last line that is not blank, removes trailing whitespace and the closing marks `*`, `_`, `` ` ``, `)`, `]`, `"`, `'`, `”`, and `’`, and checks whether what is left ends in `?` or `？`.
- The background rule counts `background_tasks` entries of type `subagent` or `workflow`.
  Those end on their own and wake the agent, so the turn is not over.
  Shell and monitor tasks can run forever, such as a dev server, so they do not hold a pane in working.
- `StopFailure` ends a turn on an API error, such as a rate limit.
  It counts as done, so the author comes to look.

### canopy hooks

`canopy hooks install | uninstall | status [--settings <file>]` manages Canopy's hooks in Claude Code's user settings file.
The file is `--settings` when given, else `$CLAUDE_CONFIG_DIR/settings.json` when that is set, else `~/.claude/settings.json`, which is where Claude Code itself looks.
These commands edit a file and never talk to the app, so they work while it is not running.
Claude Code's file watcher picks up the change, so sessions already running start or stop reporting without a restart.

- **install** adds each of Canopy's hooks that is missing, and replaces a Canopy hook whose fields differ, such as one from an older Canopy.
  Running it twice changes nothing.
- **uninstall** removes every hook handler whose command runs `"$CANOPY_CLI" agent-hook`, then any matcher group left with no handlers, any event left with no groups, and the `hooks` key if it is left empty.
  Everything else stays as it was.
- **status** says whether all of Canopy's hooks are there (installed), only some are there or some differ (outdated), or none are (not installed).
  It exits 1 unless they are installed, like `canopy status` when the app is not running.

Each prints what it found or did and the file's path.
With `--json` each prints `{"settings": "<path>", "state": "installed"}`, where the state is `installed`, `outdated`, or `not_installed` after the command ran.

`install` and `status` warn when the file sets `"disableAllHooks": true`, since Claude Code then runs none of them.

Writing the file:

- Keys keep their order, and the file is written with two-space indentation, as Claude Code writes it.
  A file Claude Code wrote comes back byte for byte after an install and an uninstall.
- It is written to a temporary file beside it and renamed over it, keeping its permissions.
- If it is a symbolic link, as dotfile setups often make it, the file it points to is written and the link stays.
- If the file changed between reading and writing, Canopy reads it again and redoes the change.
- A missing file is created, with its folder.
- A file that is not a JSON object is left alone, and the command fails with `settings_invalid`.

### What install writes

Every handler runs the same command:

```sh
[ -z "$CANOPY_CLI" ] || "$CANOPY_CLI" agent-hook >/dev/null 2>&1 || true
```

`CANOPY_CLI` is a new pane variable holding the path of the CLI inside the app that owns the pane.
In terminals outside Canopy the command does nothing.
In a Canopy terminal it runs that app's own CLI, which reports to that app's `CANOPY_HOME`.
A dev build's panes therefore report to the dev build even when the author's `PATH` puts the installed release CLI first.
Panes of a release that predates this feature have no `CANOPY_CLI` and run nothing.
The `|| true` keeps any failure, such as a CLI gone after the app moved, out of Claude's transcript.

| Event | Matcher | Handler |
|---|---|---|
| `SessionStart` | none | background |
| `UserPromptSubmit` | none | background |
| `PreToolUse` | `AskUserQuestion\|ExitPlanMode` | background |
| `PermissionRequest` | none | background |
| `PostToolUse` | none | background |
| `PostToolUseFailure` | none | background |
| `Notification` | `permission_prompt\|elicitation_dialog\|elicitation_url_dialog\|agent_needs_input\|agent_completed` | background |
| `Elicitation` | none | background |
| `ElicitationResult` | none | background |
| `Stop` | none | inline |
| `StopFailure` | none | inline |
| `SessionEnd` | none | end |

Each event gets its own matcher group holding one handler.

- A background handler is `{"type": "command", "command": <command>, "async": true}`.
- An inline handler is `{"type": "command", "command": <command>, "timeout": 5}`.
  It returns in milliseconds, and the timeout only caps a hang.
- The end handler is `{"type": "command", "command": <command>}`.
  It leaves the timeout out so Claude Code keeps its 1.5 second budget for `SessionEnd` hooks.

### Offering the install

On launch, Canopy offers to install the hooks when Claude Code's config folder exists, the hooks are not installed, and the offer was never shown from this `CANOPY_HOME`.
The offer is an alert:

> **Show when Claude Code finishes?**
> Canopy can add hooks to ~/.claude/settings.json so it knows when Claude Code in its terminals is working, done, or waiting for you.
> Your other hooks stay as they are, and `canopy hooks uninstall` takes Canopy's out.
>
> [Add Hooks] [Not Now]

The alert names the file it would actually write.
`state.json` records that the offer was shown, whichever button was pressed, so it never comes back.
`canopy hooks install` works any time after a Not Now.
A failed install shows in a toast.

## Seen

A done pane is unseen until the author sees it.
The author sees a pane when all of these hold:

- Canopy is the active app,
- its window is visible, not minimized or hidden,
- the pane's row is selected,
- and the pane's tab is that row's selected tab.

A pane that finishes while seen is never unseen, so it never turns green.
Seeing a waiting pane changes nothing.
Yellow stays until the agent works again, because seeing a question does not answer it.

## Sounds

A sound plays when a pane becomes done or waiting, unless it is the pane the author is focused on.
That is the focused pane of the selected row's selected tab, while Canopy is the active app with its window visible.
Another pane in the tab on screen still plays the sound, since the author's attention is on the focused one.
A sound that is already playing is not started again, so several panes finishing together play it once.

`config.json` holds three keys:

| Key | Default | Meaning |
|---|---|---|
| `agentSounds` | `true` | `false` turns both sounds off. |
| `agentDoneSound` | `"Glass"` | Played when a pane becomes done. |
| `agentWaitingSound` | `"Ping"` | Played when a pane becomes waiting. |

A sound is a name from `/System/Library/Sounds` or `~/Library/Sounds` without its extension, or a path to a sound file.
An empty string silences that one sound, and a name that cannot be found plays the default instead.
Canopy reads these keys each time a sound is due, so changes apply without relaunching.

## Looks

### The dot

| State | Dot |
|---|---|
| working | the accent color, pulsing between 35% and full opacity about every 1.6 seconds |
| waiting | yellow |
| done and unseen | green |

Each dot is 6 points across with a 2.5 point halo of its own color at 22% opacity, the shape of today's running dot.
The working dot is today's running dot, pulsing.
Green and yellow are the system's green and yellow, with the yellow darkened in light mode so it holds up against a white sidebar.
With Reduce Motion on, the working dot holds still.

The most urgent state wins wherever one dot stands for several panes: waiting, then done and unseen, then working.

### Sidebar row

A row's dot stands for all of its panes, in every tab.
It sits where the running dot is today, right-aligned before the PR number.
Programs that are not agents no longer put a dot on a row.
The ports panel already shows servers.
The row's accessibility label says "agent working", "agent waiting for you", or "agent done" in place of "running a program".

A row can show a green done dot beside an open PR's green number.
They stay apart by shape and position:

- the dot is a round mark with a soft halo, while the PR shows as a line glyph at the row's start and a `#number` in text;
- the dot keeps its own slot, the row's 8 point spacing before the number, and slides with the number on hover;
- the halo marks the dot as a status light rather than part of the PR.

The UI shots show both on one row, in dark and light, so the author can judge them together.

### Tab bar

A tab's dot stands for its panes.
It takes the running dot's slot after the tab's name at 5 points, and gives way to the tab's `x` on hover, as today.
Programs that are not agents no longer put a dot on a tab.

### Pane header

The pane header's status mark shows the pane's own agent dot while it has one to show.
Otherwise it keeps today's marks: the running dot while a program runs, the terminal glyph while the shell is idle, and the check or cross after an exit.
In a tab with several panes, this is how the author finds the one that asked.

### Collapsed row groups

Once row groups land from `feat/row-groups`, a collapsed group's header shows the most urgent dot among its rows.
Whichever of the two PRs merges second adds it.

## CLI

| Command | Effect |
|---|---|
| `canopy term list [--all]` | gains an AGENT column: working, done, waiting, or blank |
| `canopy term state [<id>] <working\|done\|waiting\|none>` | reports a pane's agent state, the pane it runs in by default |
| `canopy term wait <id>... [--for done\|waiting\|any] [--timeout <span>]` | waits until one of the panes reaches the state, then prints which pane and what state |
| `canopy hooks install\|uninstall\|status [--settings <file>]` | manages Canopy's Claude Code hooks |
| `canopy agent-hook` | what Claude Code's hooks run, hidden from help |

`term state` and `term wait` never launch the app, like `term send`.
`canopy agent-guide` gains all of them.

### term list

The table gains an AGENT column after PROCESS.
With `--json`, each terminal gains `"agent"`, left out when the state is none, like `foreground` and `exited`.

### term state

It sets the state the same way a hook report does, without a session.
Without an ID it acts on `CANOPY_PANE`, and fails with `missing_target` outside a Canopy terminal.
It prints `p12 done`, and with `--json` prints `{"pane": "p12", "state": "done"}`.

Codex, for example, can report its finished turns with its `notify` setting in `~/.codex/config.toml`:

```toml
notify = ["sh", "-c", "[ -z \"$CANOPY_CLI\" ] || \"$CANOPY_CLI\" term state done", "codex-notify"]
```

Codex adds its JSON as a last argument, which the shell leaves unused.

### term wait

- `--for` defaults to `any`, which means done or waiting.
- `--timeout` defaults to `30m`, and takes a span the way `canopy log --since` does, such as `90s`, `30m`, or `2h`.
- A pane already in the state counts at once, unless something was typed or sent into it since it got there.
  So `canopy term send p12 "next step" --enter` followed by `canopy term wait p12` waits for the next finish rather than returning the last one.
- When several panes qualify at once, the first in argument order wins.
- A pane with no agent when the wait starts can still start one and reach the state.
- It prints `p12 done`, and with `--json` prints `{"pane": "p12", "state": "done"}`.
- It fails with `pane_not_found` for an unknown ID, `wait_timeout` when the time runs out, `pane_closed` when one of the panes closes, and `agent_stopped` when a pane's state goes from working, waiting, or done to none during the wait, as when its agent exits or is interrupted.

### Control methods

| Method | Params | Result |
|---|---|---|
| `term.state` | `pane`, `state`, and from hooks `session`, `event`, and `at` | `pane` and its `state` afterwards |
| `term.wait` | `panes`, `for`, and `timeout` in seconds | `pane` and `state` |

`state` is one of `working`, `waiting`, `done`, and `none`.
`event` is the hook event's name, which goes into the activity log.
A waiting report whose `event` is `Stop` is a turn that ended on a question, and every other waiting report is a prompt, for the key rules.
`at` is when the hook process started, in seconds since 1970, and reports without it take the time they arrive.
When a report is ignored, the result carries the state the pane kept.

`cli.call` leaves out `term.state` and `term.wait`.
Hooks send `term.state` on every tool call, and it records its own `agent.*` events, while `term.wait` only reads.
The CLI waits for `term.wait`'s reply for its timeout plus 10 seconds.

## Activity log

| Type | Recorded when | `data` |
|---|---|---|
| `agent.working`, `agent.waiting`, `agent.done` | a pane's state becomes that state, including a repeat done | `pane`, `from`, `via`, and `session` when a hook sent it |
| `agent.cleared` | a pane's state goes to none | the same |

`from` is the previous state, or null for none.
`via` says what caused the change: the hook event's name such as `Stop`, `term.state` for the command, `key` for a key rule, or `exit` for the program exiting or the pane closing.
`source` is `cli` for reports and `ui` for keys and exits.
The events carry the pane's repo, row, and path like the other `term.*` events.
A pane that finishes while the author watches still logs `agent.done`, since the log records what the agent did.

## Error codes

| Code | When |
|---|---|
| `pane_not_found` | an ID names no terminal, as today |
| `missing_target` | `term state` without an ID outside a Canopy terminal, as today |
| `bad_params` | an unknown state or `--for` value, or a negative timeout, as today |
| `wait_timeout` | `term wait` ran out of time |
| `pane_closed` | a pane closed during `term wait` |
| `agent_stopped` | a pane's state went to none during `term wait` |
| `settings_invalid` | the settings file is not a JSON object, and nothing was changed |
| `settings_write_failed` | the settings file could not be written, and nothing was changed |

`agent-hook` never reports an error.

## Testing

Two things on this machine must stay untouched, because every agent on it, including the ones building this feature, depends on them.

- **The real Claude Code settings file.**
  Tests, `make e2e`, and UI checks never resolve `~/.claude/settings.json`.
  `hooks` tests pass `--settings` or set `CLAUDE_CONFIG_DIR` to a temporary folder, and the shared helper fails any test whose resolved settings path is the real one.
  `scripts/e2e.sh` and `scripts/ui-fixture.sh` set `CLAUDE_CONFIG_DIR` to their temporary folder, so the dev build's install offer can only write there.
- **The release app's socket.**
  Anything that runs `canopy` sets `CANOPY_HOME` to a temporary folder and clears `CANOPY_PANE` and `CANOPY_CLI`, which the agent's own terminal would pass down.

Unit tests, in `CanopyCore`:

- the hook mapping, run on recorded hook JSON for every row of the table, with the question rule's edge cases, background tasks by type, and subagent permission requests;
- the pane rules: session ownership and letting go, out-of-order reports, repeated reports, a repeat done, the key rules, exits, and closes;
- the seen and sound decisions against the selected row and tab, the active app, and the focused pane;
- the most urgent dot for rows and tabs;
- the settings file: installing into a missing file, an empty object, and a file with other hooks; a second install changing nothing; an older Canopy hook replaced; an uninstall giving back the file byte for byte; key order kept; a symbolic link written through; an invalid file left alone; a file changed mid-write redone;
- `term wait`: a state reached at once, a stale state after input, several panes, a timeout, a closed pane, and a stopped agent.

Control and CLI tests:

- `term.state` and `term.wait` over the socket, the `agent` field in `term.list`, and `cli.call` leaving both out;
- `agent-hook` exiting 0 with no output outside Canopy, with the app not running, and on input it cannot read, and never launching the app.

`make e2e`:

- recorded hook JSON piped into `canopy agent-hook` for a real pane of the dev build, checked with `term list`, `term wait`, `term state`, and `canopy log --type agent`;
- `canopy hooks install`, `status`, and `uninstall` against a settings file in the temporary folder.

Once, with real Claude Code:
a plan step runs `claude --settings <temporary file with Canopy's hooks>` in a pane of the dev build and drives it with `canopy term send`.
It checks the real hook payloads for a prompt, a finish, a question, a permission prompt and its answer, an interrupt, and `/clear`.
The dev build's pane supplies its own `CANOPY_HOME` and `CANOPY_CLI`, and the hooks exist for that run only.

UI checks:
the fixture puts panes in every state with `canopy term state`.
Window shots in dark and light show each dot on rows, a done dot beside an open PR's number on one row, tab dots, pane header marks, and the install offer.

The PR lists the author's hand checks, including installing the hooks for real, hearing both sounds, and the seen and focus rules.

## Delivery

One PR, `feat: agent state, with a bell when an agent finishes`, holding this spec, its plan, and the code.
`feat/row-groups` and `feat/repo-clone` change the sidebar at the same time, and whichever merges second rebases.

## Risks

- **Claude Code's hook events can change.**
  The mapping is one table in `CanopyCore` with tests on recorded payloads, and events it does not know map to nothing.
- **The question rule is a guess.**
  A turn ending on a rhetorical question shows yellow, and one that asks without a question mark shows green.
  Both still play a sound.
- **The key rules are guesses too.**
  A wrong one corrects itself at the agent's next hook.
- **Pulsing dots cost redraws.**
  The plan measures CPU with several agents working at once.

## Decisions to review

These go beyond what the author approved in conversation, or pick one reading of it.

1. Programs that are not agents no longer put a dot on rows or tabs, and pane headers keep their running mark.
2. Pane headers show the agent dot too, so the pane that asked can be found in a split tab.
3. A pane listens to one Claude Code session at a time, so a nested `claude -p` cannot move it.
4. A turn that ends while a background subagent or workflow runs keeps the pane working.
5. Escape and Control-C clear a working pane, and on a prompt Return means working and Escape means none, because Claude Code sends no hook for either.
6. A turn that ended on a question stays yellow while the author types, until the prompt is submitted.
7. `term wait` defaults to `--for any` and `--timeout 30m`, and treats a state as stale once the pane gets input.
8. A done report on a done pane is a new finish, for agents that only report finishes.
9. The hook command runs `$CANOPY_CLI`, a new pane variable, rather than `canopy` from `PATH`.
10. `Stop`, `StopFailure`, and `SessionEnd` hooks run inline, the rest in the background.
11. `StopFailure` counts as done.
12. Sound settings apply live, an unknown sound name plays the default, and an empty one is silent.
13. The install offer appears only when Claude Code's config folder exists, once per `CANOPY_HOME`.
14. The settings file keeps its key order and is rewritten with two-space indentation, with no backup copy.
15. Activity events have one type per state and leave out the agent's message text.
