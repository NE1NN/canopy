# Canopy chat tabs design

Date: 2026-10-13
Status: draft for review.
The author approved the UI mockup, the engine, and each design section in conversation on 2026-10-13, and this spec writes them down.

## Summary

A row's tab bar offers a chat next to terminals: `+` opens a menu with New Terminal (⌘T) and New Chat (⇧⌘T).
A chat tab runs Claude Code headless through its streaming JSON mode and draws the conversation natively: the author's messages in bubbles, Claude's text as a document, tool calls folded into one-line groups, diffs as cards, and permission prompts, questions, and plans as cards answered with a click or a key.
A chat is a pane with a chat body instead of a terminal, so it has a pane ID, its agent reports through Claude Code's hooks as a terminal's does, and `canopy term`, agent dots, the activity log, and the iPhone app work with it.
The agent in a chat gets the same environment as one in a terminal, so it runs every `canopy` command.
A conversation moves between a chat and a terminal with Open in Terminal and Resume in a chat, since both run the same Claude Code session.
Artifacts Claude publishes open beside the chat in the artifact viewer's panel, and the chat shows a card for each.
Chat tabs are for local rows first; remote rows and the box come later.

The approved mockup is https://claude.ai/artifact/6EqY65kmwcqx68rH6qTPBd (private to the author), with its board sources in `~/.canopy/briefs/chat-tabs-mockup/`.

## Goals

1. The `+` menu offers New Terminal, New Chat, the row's recent Claude conversations to resume in a chat, and More conversations….
2. A chat does everything an agent in a terminal does: tools, permissions, questions, plans, slash commands, skills, `!` shell commands, interrupting, and every `canopy` command.
3. Replies stream word by word, and prompts are answered with a click or a key, never by keystrokes typed into a TUI.
4. A chat survives relaunch and resumes its session.
5. A conversation moves from a chat to a terminal and back without losing anything.
6. Agent dots, `term wait`, the phone inbox, Chat, replies, and answers work for chats.
7. Published artifacts open beside the chat, and a republish dims the older card.
8. A 2,000-message conversation costs about what a 20-message one does, and the budgets under Performance hold.
9. Light and dark both look right.

## Non-goals

- Chats in remote rows on ssh hosts and on the box.
  New Chat is disabled there for now; Remote rows and the box says what comes later.
- Agents other than Claude Code.
- Splitting a chat tab or mixing a chat with terminals in one tab's grid.
  A chat tab holds one chat; the row's artifact panel still shows beside it.
- Syntax colors in code blocks.
- Canopy's own versions of Claude Code's full-screen pickers (`/rewind`, `/hooks`, `/login`, and the like).
  They open in a terminal.
- Editing or deleting earlier messages.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Engine | Claude Code headless: `claude -p --input-format stream-json --output-format stream-json`, partial messages on, `--permission-prompt-tool stdio` | The spike on 2026-10-13 showed everything the boards need works this way, with streaming text and structured prompts, and nothing depends on Claude Code's screens. The author confirmed it. |
| Fallback engine | None | A TUI in a hidden pty would add nothing the headless mode lacks and would break when Claude Code's screens change. |
| What a chat is | A pane whose body is a chat instead of a terminal | Pane IDs, `CANOPY_PANE`, hooks, agent dots, `term` methods, the activity log, and the phone already key on panes, so chats get them without a second copy. |
| What a chat tab holds | One chat pane | The mockup shows a chat beside the artifact panel, not in a grid. |
| Where `claude` starts | The author's login shell, with the pane's environment, in the row's folder | Hooks need the author's PATH; the spike's hooks failed without it. |
| When `claude` starts | When the author first sends something | A restored chat shows its history from the transcript, and ten restored chats cost no processes until used. |
| Who owns a session | Canopy, one owner at a time | Claude Code lets two processes open one session at once, and their histories would split. |
| A new chat's model and mode | What the author picked last, remembered across rows; the first time, Claude Code's settings (Opus, Ask before edits) | The author agreed. |
| Message layout | The author's messages in bubbles, Claude's as plain document text | Option 1 on the mockup's question board, which the author approved. |
| Markdown | Apple's `swift-markdown` package | Tested, and it reads GitHub tables; a home-made parser would not be. |
| Conversation list | An `NSTableView` with SwiftUI cells and cached row heights | It keeps steady scrolling at thousands of rows of varying height, where `LazyVStack` jumps. Milestone 1 measures it before anything builds on it. |
| `!` commands | Canopy runs them and hands Claude the result with the next message | Headless Claude Code sends `!` to the model as a request. The TUI saves `!` as `<bash-input>` and `<bash-stdout>` messages that Claude reads on its next turn, and Canopy sends the same. |
| Folder trust | Canopy asks, with its own card | Headless Claude Code skips the trust dialog. |
| Remote rows and the box | Later | The author chose local rows first. |

## What the spike found

Checked on 2026-10-13 with Claude Code 2.1.296 in a throwaway repo, through `-p` with stream-json in and out, `--include-partial-messages`, `--verbose`, and `--permission-prompt-tool stdio`.

Works headless:

- **Streaming.** Text arrives as deltas, about 26 a second at most, and tool calls arrive with their inputs.
  An edit's result carries a `structuredPatch` with its hunks.
- **Permissions.** A `control_request` with subtype `can_use_tool` names the tool, its input, a description, `blocked_path` when there is one, and `permission_suggestions`.
  A `control_response` with `allow` (and `updatedPermissions` for Always allow, which writes `.claude/settings.local.json` as the TUI does) or `deny` with a message answers it.
  The message reaches Claude as the tool's error, which is how "tell Claude what to do instead" works.
- **AskUserQuestion.** The same request with `requires_user_interaction: true` and the questions and options as input.
  `allow` with the input plus `answers`, a map from question text to the chosen label, answers it.
- **Plan mode.** `set_permission_mode` with `plan` enters it.
  `ExitPlanMode` arrives as a request with `plan` and `planFilePath`; `allow` approves it, and `updatedPermissions` with `setMode: acceptEdits` approves it with edits accepted.
- **Modes and models.** `set_permission_mode` switches live to `default`, `acceptEdits`, `auto`, `plan`, or `bypassPermissions`, and `/model` and `/effort` switch live.
  A session starts in `default` unless told otherwise, so the chat always passes its mode.
- **Slash commands.** `/model`, `/context`, `/compact` (with `compacting` status and a `compact_boundary`), `/clear`, `/cost`, `/usage`, `/effort`, `/mcp`, and user and project skills work and answer in markdown.
  `initialize` lists every command with its description and argument hint.
  `/resume`, `/rewind`, and `/hooks` answer "isn't available in this environment".
  `/clear` starts a new session ID, announced by `conversation_reset` and the next `init`.
- **Interrupting.** A `control_request` with subtype `interrupt` stops the running tool and ends the turn; the process and session stay.
- **Messages sent mid-turn.** Claude reads them after the current tool, in the same turn, as in the TUI.
- **Images.** An image content block in the user message works.
- **Hooks.** Every hook Canopy installs fires as in a terminal: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, the `permission_prompt` `Notification`, `PostToolUse`, and `Stop`.
- **Transcripts.** The session writes the same JSONL file in the same folder, with `entrypoint: sdk-cli`, which `TranscriptParser` does not look at.
- **Resuming.** `claude --resume <id>` in a terminal shows the chat's whole history, and `claude -p --resume <id>` afterwards knows what was said in the terminal; the ID stays the same.

What Canopy fills in:

- `!` goes to the model as a request, so Canopy runs it.
- A running command's output is not in the stream.
  `task_started` names a task ID about 3 seconds in, and Claude Code writes the output to `$TMPDIR/claude-<uid>/<cwd slug>/<session>/tasks/<task id>.output` while it runs and removes it after.
- The trust dialog is skipped.
- Nothing stops a terminal and a chat from opening one session at the same time.
- A headless `claude` with a long conversation held about 360 MB; the author's terminal `claude` processes held 170 to 195 MB, not the same conversations.

The control protocol is what Anthropic's Agent SDK speaks to the CLI.
It is not a published spec, so ClaudeStream ignores what it does not know, and `make e2e` checks it against the installed Claude Code.

## Architecture

```
ChatView (CanopyApp) ── observes ──► ChatSession (CanopyCore) ── owns ──► ClaudeStream ── stdin/stdout ──► claude -p
     │                                     │                                                                  │
     └ composer, cards, list               ├ ChatHistory: transcript pages (TranscriptReader)                  hooks
                                           └ Pane (chat body): ID, context, agent state  ◄── canopy agent-hook ┘
```

### Panes with two kinds of body

`Pane` keeps what every pane has: its ID, row context, agent state, title, status, and activity logging.
What belongs to a terminal (the emulator, the pty process, command marks, typing, pasting, pressing keys, the foreground process) moves into a terminal body, and a pane's body is either that or a `ChatSession`.
Code that needs a terminal asks for the terminal body and refuses chats with `not_a_terminal`, so nothing reaches a chat as keystrokes.

`TerminalTab.Content` gains `chat(Pane)` beside `terminals(TerminalGrid)` and `web(WebPage)`.
A chat tab is named after its conversation.
Selecting a chat tab focuses its composer.

### ClaudeStream

`ClaudeStream` in CanopyCore runs one `claude` process and speaks its JSON lines.

- It starts `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --permission-prompt-tool stdio --permission-mode <mode> --model <model>`, adding `--resume <id>` for an existing session.
  `--replay-user-messages` echoes each message once Claude takes it, which tells the chat when a queued message landed.
- It runs through `ShellSettings.script`, the interactive login shell that pane scripts use, as `exec claude …`, with `PaneEnvironment` for the chat's pane ID and the row's folder.
- It sends `initialize` first and keeps the command list it answers with.
- It decodes each line into a typed event: system (`init`, `status`, `compact_boundary`, `task_started`, `task_notification`, `conversation_reset`), stream deltas, assistant and user messages, results, rate limit events, and control requests and responses.
  Unknown types and fields are ignored.
- Control requests Canopy sends (`interrupt`, `set_permission_mode`) wait for their response with a timeout.
  A control request from Claude of a kind Canopy does not know gets an error response at once, so Claude never waits on it.
- Stderr is kept, its last 50 lines, for the failure notice.
- The process ends with the tab, or when the app quits.

### ChatSession

`ChatSession` is the chat body's model, observable, with no UI.
It holds:

- the conversation as a list of items with stable IDs (below), built from transcript pages and then live events;
- the open prompt, if any: a permission, a question, or a plan, with the control request ID that answers it;
- the session ID, which follows `init` and `conversation_reset`;
- the mode, model, effort, context use (input tokens over the model's context window, from each result's `modelUsage`), and rate limit state;
- working or idle, the turn's start time, and the turn's output tokens;
- messages queued while Claude works, until they are echoed back;
- `!` commands run since the last message, waiting to go with the next one.

Items are value types: a prompt, Claude's text, a tool group, an edit, a running command, a subagent, a question, a plan, a permission, a shell block, an artifact, and a notice.
Streaming changes only the last item, and changes reach the view at most 30 times a second.

The agent state still comes from the hooks, as for terminals, since the agent runs `canopy agent-hook` with `CANOPY_PANE`.
`ChatSession` also clears the state when its process exits, since a crash sends no `SessionEnd`.

### History

`TranscriptReader` reads the session's transcript from the end in chunks from 64 KB, as `phone.transcript` does, and `TranscriptParser` turns the lines into items.
The parser gains what a chat shows and the phone leaves out: an edit's patch, a shell block from `<bash-input>` and `<bash-stdout>`, an artifact publish, and a command's output as a notice.
The phone keeps its current entries; the new kinds are dropped from what it is sent.
Older pages load as the author scrolls up.
Live events take over from the end of the file; a message that is in both is matched by its UUID.

### The conversation in a folder

Claude Code keeps a folder's sessions in `~/.claude/projects/<folder with / and . as ->/`.
`ClaudeSessions` in CanopyCore lists a row's sessions there, newest first, with each one's title (the transcript's own title record when there is one, else the first line of its first prompt) and when it last changed.

## Running a chat

### Starting

New Chat opens a chat tab with an empty conversation and the composer focused.
Its model and mode are what the author picked last for a chat, saved in `AppState`; the first time, the model from Claude Code's settings and Ask before edits.
`claude` starts when the author sends the first message, so an unused chat costs nothing.

Before the first start in a folder, Canopy checks `~/.claude.json` for the folder's trust (`projects[<path>].hasTrustDialogAccepted`, looked up as Claude Code does: the folder or a parent, but no further up than its git root).
An untrusted folder shows a trust card with the folder, Claude Code's warning, and any permissions the folder's settings pre-approve.
Trust sets the flag in `~/.claude.json`, keeping every other key as it was and writing atomically, then reads it back; if another Claude Code process wrote over it, Canopy writes again, three times at most, and otherwise says it could not.
Not now closes the tab.

### Ownership of a session

A session has one owner at a time: a chat or a terminal.
Canopy knows each pane's session from its hooks.

- **Open in Terminal**, in the chat's header, interrupts Claude if it is working, ends the process, and replaces the chat tab in place with a terminal tab running `claude --resume <id> --model <model> --permission-mode <mode>`.
- **Resume in a chat**, in the `+` menu, lists the row's five newest sessions, and More conversations… opens a sheet with all of them and a search field.
  A session that a pane already holds shows that pane's tab name, and picking it selects that pane instead of opening a second owner.
- Restoring a chat whose session a terminal pane already holds, which happens when the author resumed it by hand, shows the chat as "Open in p12" with a button that selects that pane.

### Relaunching

A chat tab is saved with its session ID, model, mode, and title.
On relaunch it shows its history from the transcript, and `claude --resume` starts when the author sends something.
A transcript that is gone shows a notice and a Start a new chat button.

## The chat view

Sizes and colors follow the board sources in `~/.canopy/briefs/chat-tabs-mockup/`, with light colors added from Canopy's light palette.

### Header

The conversation's title, and Open in Terminal on the right.

### Messages

- The author's messages are bubbles on the right, with pasted images as thumbnails.
  A message queued while Claude works shows dimmed under "Claude reads this when the current step ends", and turns solid when Claude takes it.
- Claude's text is markdown drawn as document text: headings, paragraphs, lists, block quotes, tables, code blocks in a monospaced font, inline code, emphasis, and links.
  Markdown is parsed once per finished message and kept; while a message streams, only its last block is parsed again.
- Thinking is not shown; the status line says Thinking while it happens.
- Consecutive tool calls of one kind are one line, worded as the phone words them ("Read TopBarView.swift and 3 more", "Searched for SavedTab", "Ran make test and 2 more", "Fetched developer.apple.com"), with ", failed" or ", declined" as the phone adds them.
  Clicking the line lists the calls; each shows its input, and its output folded.
- An edit is a diff card: the file name, its +/− counts, and its hunks, showing six lines until opened.
- A running command is a card: "Running", the command, the elapsed time, and the last five lines of its task file, read from the last offset.
  When it ends it folds into its group line.
  If the task file is not where the spike found it, the card shows the command and elapsed time without a tail.
- A subagent is one line ("Ran an agent: <description>"), with its own calls folded inside.
- A slash command's output (`/context`, `/cost`) is a notice block, and so are compacting, `/clear`, an interrupt, and a background task finishing.
- A `!` command is a shell block: `$ <command>`, "you ran this", and its output, with the last 30 lines shown until opened.

The list keeps to the newest message while the author is at the bottom, and stays where it is while they have scrolled up, with a "Jump to latest" button.

### Status line

Above the composer: a dot in the agent's color, then one of

- Working · 1m 12s · ↓ 2.3k tokens (Thinking in place of Working while Claude thinks, Compacting while it compacts),
- Needs you · waiting 0:08,
- Done · 3m 40s,
- Rate limited · resets 7:10 pm, when a rate limit event says so.

### Composer

- Return sends; ⇧Return and ⌥Return add a line.
- Images can be pasted or dropped, and show as thumbnails above the text until sent.
- The placeholder is "Reply to Claude", and "Reply to Claude. It reads this when the current step ends." while it works.
- Chips below it: the mode (Ask before edits, Accept edits, Plan, Auto, Bypass permissions), the model (the models Claude Code offers), and context use ("22% of context").
  Changing the mode or model takes effect at once.
- Stop (esc) shows while Claude works and interrupts it.

### Prompts

A prompt is a card at the end of the conversation, and the status line says Needs you.

- **Permission.** "Claude wants to run a command" (or edit a file, fetch a URL, use a tool), what it wants to run in a monospaced box, the request's description line, and Allow (⏎), Always allow with the rule Claude Code suggests, such as "canopy row new", and Deny (esc).
  A file write or edit shows its diff.
  The composer's placeholder becomes "Or tell Claude what to do instead", and sending text denies with that text.
- **Question.** "Claude asks", the question, and each option as a row with its number, label, and description; "(Recommended)" at the end of a label becomes a Recommended tag.
  Number keys 1 to 4 pick, and "Something else…" sends what the author types as the answer.
  Several questions are answered one after another and sent together; a multiple choice shows checkboxes and a Submit button.
  The composer's placeholder becomes "Or chat about this instead", and sending text denies the question with that text.
- **Plan.** The plan as markdown, then Approve and auto-accept edits, Approve and ask before edits, and Keep planning, with the composer's text sent as what to change.

Keys apply while the composer is empty: Return allows or approves, a digit picks, and esc denies, keeps planning, or stops.
With text in the composer, Return sends the text.

### Commands

Typing `/` at the start of the composer opens a menu above it: Commands, then Skills, each with its name and description, filtered as the author types, picked with ↑↓ and ⏎.
It comes from the command list `initialize` returned.
`/resume` opens the conversation sheet from the `+` menu.
Commands that need Claude Code's full screen (`/rewind`, `/hooks`, `/login`, `/logout`, `/doctor`, `/terminal-setup`, `/ide`) show "Opens in Terminal", and picking one does Open in Terminal and types it there.
The menu's footer says "Start with ! to run a shell command".

### `!` commands

`!` at the start of the composer switches it to shell mode, with a `$` badge.
Return runs the command through the author's login shell with the pane's environment, in the row's folder, and its output streams into a shell block; esc stops it.
Claude gets the command and its output with the author's next message, as a `<bash-input>` text block and a `<bash-stdout>`/`<bash-stderr>` text block ahead of the message, the records the TUI writes.
Until then the block says "Claude sees this with your next message".

### Artifacts

When a chat's Artifact tool call succeeds, Canopy finds the artifact URL in its result with `ArtifactLink` and opens it in the row with placement `panel`, by the artifact viewer's rules, so a URL the row already shows is not opened twice.
The chat shows an artifact card:

- a thumbnail, a snapshot of the page once the panel has loaded it, kept in `CANOPY_HOME/thumbnails/` by artifact ID and version;
- the title, from the call's input or the page's title;
- the type, the version, and "private";
- Open beside, and ••• with Open in a tab, Open in browser, and Copy link.

The version is the one the result names, or else the count of publishes to that URL in the conversation.
A newer publish of the same URL dims the older card to "Version 5 · replaced by version 6".
An artifact link in Claude's text opens in the panel on a single click; other links open the default browser.

## The CLI and the agent guide

| Command | Method | What it does |
|---|---|---|
| `canopy chat new [--repo <repo>] [--row <row>] [--prompt <text>] [--model <model>] [--mode <mode>] [--resume <session>] [--json]` | `chat.new` | Opens a chat tab in the row and prints its pane ID. With `--prompt`, sends it as the first message. Never changes which row is selected. |

The `term` commands take chat panes:

- `term send <pane> <text> --enter` sends a message; without `--enter` the text goes into the composer as a draft.
- `term read <pane> [--lines <n>]` prints the conversation as plain text, oldest first: "You: …", Claude's text, tool lines, and prompts.
- `term state`, `term wait`, and `term close` work as for terminals.
- `term list` gains a `kind` column, `terminal` or `chat`, and `kind` in its JSON.

`term new` and `row new --run` stay for terminals.
The agent guide gains a short section: open a chat with `chat new`, send to it with `term send`, wait with `term wait`, and read it with `term read`.

## The iPhone app

- `phone.transcript` reads a chat's transcript as it reads a terminal agent's, since the hooks hand over its path.
- Pane entries in the inbox and `phone.rows` gain an optional `kind`, `terminal` or `chat`, in CanopyWire.
- `phone.reply` to a chat sends the message straight to the chat.
  While a permission or question is open, the reply denies it with the reply's text, as the composer does, instead of answering `prompt_open`.
  Delivered still comes from the `UserPromptSubmit` hook.
- `phone.answer` to a chat answers its open prompt through the control response, with the structured answer, not keys.
- `phone.screen` and `phone.keys` on a chat answer `not_a_terminal`.
- The phone app hides the Terminal tab and key bar for a chat.
  An older phone app still reads and answers chats, and only its Terminal tab shows the error.

## Remote rows and the box

New Chat is disabled in remote rows, with the tooltip "Chats run in this Mac's rows for now".
`kind` is defined in CanopyWire, which the box server work also changes; until box chats exist, the box daemon reports `terminal` for its panes.
Chats on the box would run the same headless `claude` under a small process on the box that keeps it running through daemon restarts, as tmux keeps terminals.
The box server's agent is told, so its spec can name chats as a later addition.

## Performance

The author asked that chat tabs not hurt performance.
Each PR measures these on a dev build and lists the numbers in its body.

| What | Budget |
|---|---|
| Opening a chat with a 2,000-message transcript | Drawn in under 300 ms |
| Scrolling that chat | No hitches in Instruments' Animation Hitches: hitch time ratio under 5 ms/s |
| A reply streaming | Canopy's main process under 20% of one core |
| A 2,000-message chat on screen | Under 100 MB added to Canopy |
| A chat tab not on screen | No drawing, no timers |
| `claude` | Its memory reported next to a terminal `claude` holding the same conversation |

What keeps them:

- Only messages near the viewport are laid out, by the `NSTableView` list, with row heights cached by item ID and width.
- History loads by pages from the end of the transcript.
- Streaming updates are coalesced to 30 a second and change only the last item.
- Markdown and diffs are parsed once per message and kept.
- Tool output, diffs, and shell output stay folded until opened, and a live tail keeps five lines.
- Restored chats start no process until used.

## Failures

| Failure | What happens |
|---|---|
| `claude` is not found, or exits | A notice with its last lines of stderr and Start again, which resumes the same session. The pane's agent state clears. |
| Claude Code is older than 2.1.296 | Checked with `claude --version` before the first start: "Chats need Claude Code 2.1.296 or newer". |
| The login expired | The result's error shows as a notice with Open in Terminal to log in. |
| A rate limit | The status line shows it with its reset time. |
| A prompt whose process ended | The card closes as "No longer waiting". |
| A control request Canopy does not know | An error response at once. |
| A line that is not JSON, or an unknown event | Skipped. |
| Trust cannot be saved | The trust card says so and offers Open in Terminal, where Claude Code asks itself. |
| The transcript is gone | A notice and Start a new chat. |
| `!` command fails | Its block shows the output and exit code; Claude still gets it with the next message. |

## Testing

- **CanopyCore tests:**
  - ClaudeStream decoding against stream logs captured from the installed Claude Code, checked in as fixtures with personal details removed.
  - ChatSession building items from events: streaming text, tool groups, edits, running commands, subagents, prompts, `/clear`'s new session, queued messages.
  - Control round trips (allow, always allow, deny with text, answers, plan approval with a mode, interrupt, mode changes) against `scripts/fake-claude.py`, which gains a stream-json mode.
  - The parser's new items, and history pages joining live events.
  - `ClaudeSessions` listing a folder's sessions and their titles.
  - Trust lookup and writing, with a concurrent writer.
  - `SavedTab` round trips with a chat, and an older `state.json`.
  - `chat.new` and the `term` methods on chat panes, and `not_a_terminal`.
  - Phone replies and answers to chats.
- **`make e2e`** drives a real `claude` on Haiku in a throwaway repo through `chat new` and `term`: a turn, Allow, Always allow, Deny with text, a question, a plan approved with edits accepted, an interrupt, `!`, `/compact`, hooks reaching the pane (`term wait`), and Open in Terminal and back.
- **UI checks:** `scripts/ui-fixture.sh` gains chat tabs held in each board's state by the fake Claude, and each PR has window shots of every state it adds, in light and dark.
- **Performance:** the measurements under Performance, in each PR body.

## Delivery

Five milestones, one plan and one PR each.
Each PR clears the merge bar, then prints `READY: <PR URL>` with how to try it, and waits for the author to say merge; the author tests chat tabs before anything lands.

1. **A working chat.** Panes with terminal and chat bodies, ClaudeStream, ChatSession, the `+` menu with New Chat and ⇧⌘T, messages with markdown and streaming, the status line, the composer with Stop, permission cards, the trust card, saved state and relaunch, and the list meeting the budgets.
2. **Tools and prompts.** Tool groups, diff cards, live tails, subagents, questions, plans, the mode, model, and context chips, queued messages, and images.
3. **Commands and handoff.** The `/` menu, `!` commands, notices, Resume in a chat and the conversation sheet, Open in Terminal, and full-screen commands handed to a terminal.
4. **Artifacts.** Opening in the panel, cards with thumbnails and versions, and single-click artifact links.
5. **Agents and the phone.** `canopy chat new`, `term` on chat panes, the agent guide, `kind`, phone replies and answers for chats, and the phone app hiding the Terminal tab.

## Risks

- **The control protocol changes.** It is the Agent SDK's, not a published spec.
  Decoding ignores the unknown, and `make e2e` runs against the installed Claude Code, so a change shows as a failing check rather than a broken chat.
- **The task file moves.** The live tail is the one thing read from Claude Code's private files; without it a running command shows no tail and nothing else breaks.
- **`~/.claude.json` is shared.** Every Claude Code process rewrites it, so the trust write reads back and retries.
- **An interactive login shell without a terminal.** Startup files that expect a terminal may print warnings or wait; milestone 1 checks the author's zsh setup, and stderr shows in the failure notice.
- **Memory.** Each chat's `claude` is a process like a terminal's; starting it only when used keeps idle chats free.

## Decisions to review

- A chat tab holds one chat, with no splits.
- A new chat starts with the last model and mode the author picked, Ask before edits the first time.
- `claude` starts on the first message, not when a chat opens or is restored.
- A reply from the phone while a prompt is open denies it with the reply's text, where today a terminal's answers `prompt_open`.
- `term send` without `--enter` drafts into the composer.
- Full-screen commands open in a terminal instead of getting native versions.
- No syntax colors in code blocks in the first version.
