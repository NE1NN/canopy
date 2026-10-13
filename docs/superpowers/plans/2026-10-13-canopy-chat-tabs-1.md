# Chat Tabs, Milestone 1: A Working Chat

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A row's `+` menu and ⇧⌘T open a chat tab that runs Claude Code headless and draws its conversation natively: streaming markdown, folded tool calls, permission cards, Stop, folder trust, saved state and relaunch, within the performance budgets.

**Architecture:** A pane's body is now a terminal (`TerminalBody`, the old pty code) or a chat (`ChatSession`), so pane IDs, hooks, agent dots, `term` methods, the activity log, and the phone keep working.
`ChatSession` runs `claude -p` with stream-json both ways through `ClaudeStream` over a `PipeProcess`, started through the author's login shell with the pane's environment.
`ChatBuilder` turns transcript lines, which are also what Claude streams, into items; `ChatRows` says what shows; the app draws rows in an `NSTableView` of SwiftUI cells it measures itself.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI and AppKit, Apple's `swift-markdown` 0.9.0, Python 3 for the stand-in Claude, Claude Code 2.1.296 with Haiku for the real-Claude e2e.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, updated in this PR where real Claude Code corrected it (deny, interrupt, queued messages, trust lookup, the TUI's default mode).

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings.
- Logic in CanopyCore and CanopyAgents, views in CanopyApp.
- Nothing reaches a chat as keystrokes: terminal-only calls refuse chats with `not_a_terminal`.
- Unknown stream events are skipped; an unknown control request from Claude gets an error response at once.
- Tests never start the real `claude` or touch the author's `~/.claude.json`, except `ChatRealClaudeTests`, which runs only with `CANOPY_REAL_CLAUDE=1` (`make e2e`).
- `make lint`, `make build` with 0 warnings, `make test` three clean runs, `make e2e`.
- Markdown: one sentence per line, no em dashes. Conventional commits, no trailers.

## How Claude Code 2.1.296 behaves headless

From the spike and from `ChatRealClaudeTests` against the installed Claude Code:

- A deny's message reaches Claude as the tool's output, and Haiku refused one as possible prompt injection, so a deny always stops the turn (`interrupt: true`) and the author's text follows as the next message.
- An `interrupt` control request is acknowledged but does not answer a permission request that is open or on its way, and the turn then never ends; the chat denies such requests instead.
- Messages queued during one step come back as one `--replay-user-messages` echo with a text block each.
- `init` carries `claude_code_version` and `terminal_slash_commands` (doctor, color, focus, reload-plugins).
- `sleep` and `echo` run without a permission prompt; a bare `sleep 60` is blocked with a hint to use Monitor.
- Trust: in a git repo only the row's folder or the repo's main checkout counts, and accepting in a worktree writes the main checkout; outside git, any folder above counts.
- A project folder is the path with every character that is not a letter or digit turned into `-`.
- `claude` started by `zsh -i -l -c` with no terminal starts in about a second, with nothing on stderr, and finds `node` and `canopy` on the author's PATH.

## Review Focus

1. A permission request still on its way when the author presses Stop must not leave the turn hanging. Pinned by `stopDeniesAnOpenPrompt` and the real-Claude e2e's interrupt.
2. Messages taken together must all leave the queue. Pinned by `messagesTakenTogetherAllLeaveTheQueue` and the e2e's queued message.
3. A restored chat must show its history and resume the same session, and an older `state.json` must still load. Pinned by `savesAndRestoresTheConversation`, `resumesTheSessionWhenSentSomething`, and `aSavedChatTabRoundTripsThroughJSON`.
4. The trust write must keep every other key in `~/.claude.json`, survive a concurrent writer, and leave a file it cannot read alone. Pinned by the `ClaudeTrustTests`.
5. Terminal panes must behave exactly as before the `Pane` split. Pinned by the whole existing suite, which passes unchanged apart from reaching terminal calls through `pane.terminal`.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/CanopyCore/Chat/ChatMarkdown.swift` | markdown to `ChatBlock`s with inline styles in `AttributedString` |
| `Sources/CanopyCore/Chat/ClaudeEvent.swift` | `ClaudeEvent` decoding, `ClaudeInput` encoding |
| `Sources/CanopyCore/Chat/PipeProcess.swift` | a line-based child over pipes in its own process group |
| `Sources/CanopyCore/Chat/ClaudeStream.swift` | `ClaudeStream`, `ClaudeLaunch`, `ClaudeCommand` |
| `Sources/CanopyCore/Chat/ChatItem.swift`, `ChatBuilder.swift` | items and the incremental builder |
| `Sources/CanopyCore/Chat/ChatSession.swift` | one chat's state machine |
| `Sources/CanopyCore/Chat/ChatStreamText.swift` | streaming text parsed a block at a time |
| `Sources/CanopyCore/Chat/ChatRows.swift`, `ChatFormat.swift` | rows to draw, status wording |
| `Sources/CanopyCore/Chat/ClaudeTrust.swift`, `ClaudeProjects.swift` | trust in `~/.claude.json`, transcript paths |
| `Sources/CanopyCore/Terminal/Pane.swift`, `TerminalBody.swift` | panes with a terminal or chat body |
| `Sources/CanopyCore/Terminal/TerminalStore.swift`, `State/SavedTerminals.swift` | chat tabs, `SavedChat` |
| `Sources/CanopyAgents/TranscriptParser.swift`, `TranscriptReader.swift` | the parts chats reuse made public, `linePage` |
| `Sources/CanopyApp/Chat/*` | `ChatView`, `ChatList`, `ChatRowViews`, `MarkdownView`, `ChatComposer`, `ChatStyle` |
| `Sources/CanopyApp/Terminal/TopBarView.swift`, `CanopyApp.swift`, `AppModel.swift` | the `+` menu, ⇧⌘T, focus, close wording |
| `scripts/fake-claude-stream.py` | the stand-in Claude |
| `scripts/e2e-chat-claude.sh` | the real-Claude e2e, in `make e2e` |

## Tasks

Each task was built test first and checked alone; the commits are kept on the local branch `chat-m1-commits` and squashed into one for this PR after the rebase onto the box server's module split.

- [x] **Task 1: Markdown.** `ChatMarkdown.parse(_:) -> [ChatBlock]` with swift-markdown: paragraphs, headings, code with language, nested lists with start numbers, quotes, tables with alignment, rules, hard breaks; inline emphasis, strong, code, strikethrough, links; HTML kept as text; an unfinished fence reads as code. Tests: `ChatMarkdownTests` (8).
- [x] **Task 2: The codec.** `ClaudeEvent(line:)` for `init`, `status`, tasks, `conversation_reset`, messages (kept as their line, with replay, subagent parent, and context tokens), stream deltas, results, rate limits, `can_use_tool` requests, unknown requests, and control responses; `ClaudeInput` for user content with images, control requests, allow with permissions, deny with `interrupt`, and refusals. Tests: `ClaudeEventTests` (15).
- [x] **Task 3: PipeProcess.** `posix_spawn` with pipes, `SETSID`, signals reset, `F_SETNOSIGPIPE`; lines batched to the main actor with backpressure; stderr's last 50 lines; `terminate(grace:)` sends SIGTERM to the group, then SIGKILL only while the exit is unreaped. Tests: `PipeProcessTests` (9), 20 repeated runs clean.
- [x] **Task 4: ClaudeStream and the stand-in.** `start` sends `initialize` and keeps the command list; `request` waits for its response with a timeout; unknown requests are refused; stopping fails waiting requests. `scripts/fake-claude-stream.py` takes `claude -p`'s arguments and scenarios by message (`say`, `run`, `ask`, `pause`, `slow`, `hold`, `callback`, `crash`, `/clear`), writes a real-format transcript, and calls `$CANOPY_CLI agent-hook`. Tests: `ClaudeStreamTests` (9).
- [x] **Task 5: Items.** `ChatBuilder.add(line:)` folds tool calls by kind with the phone's wording, fills results in as they come, reads questions, plans, notices, prompts with images, skips sidechains and meta lines, ignores repeats, and `prepend` puts older pages in front with results across the seam. `TranscriptReader.linePage` reads raw lines from the end. Tests: `ChatBuilderTests` (9, including both recorded transcripts read as the phone reads them), `TranscriptLinePageTests` (4).
- [x] **Task 6: Trust.** `ClaudeTrust.isTrusted` and `trust` with the rules above, writing atomically through symlinks, keeping other keys, retrying a write another Claude Code dropped, refusing an unreadable file. Tests: `ClaudeTrustTests` (12).
- [x] **Task 7: ChatSession.** Starts `claude` on the first message, resuming its session; queued messages and their echoes; permission allow, always allow, deny then the text as the next message; Stop; questions and plans turned down until milestone 2; `/clear`; exits, version check from `init`, missing transcripts; history read on first show and older pages off the main actor; streaming redrawn at most every 33 ms, leading edge first. Tests: `ChatSessionTests` (21), `ChatRealClaudeTests` (1, opt-in).
- [x] **Task 8: Pane bodies.** `Pane` keeps ID, context, status, title, agent state, and logging; `TerminalBody` holds the pty, emulator, typing, pasting, keys, remote session, and titles; chat panes map Return and Esc actions onto the agent's key rules. `not_a_terminal` for `term send`, `term read`, `phone.screen`, `phone.keys`, `phone.reply`, `phone.answer` on chats. The existing suite reaches terminals through `pane.terminal`.
- [x] **Task 9: Chat tabs.** `TerminalTab.Content.chat`, `openChat`, renaming, closing, `closePane` on a chat, `SavedChat` and restore, `chatLauncher` and `chatTrust` hooks for tests, `Pane.hasRunningWork` for close and quit warnings. Tests: `ChatTabTests` (10).
- [x] **Task 10: Rows and the view.** `ChatRows` with item revisions as keys; `ChatFormat`; the chat view: header, `NSTableView` list measured at the drawn column width, bubbles, markdown, tool lines, notices, status line, permission, trust, and failure cards, composer with Stop and Send, Jump to latest; the `+` menu and ⇧⌘T. Tests: `ChatRowsTests` (5), `ChatFormatTests` (4), `ChatStreamTextTests` (3).
- [x] **Task 11: The real-Claude e2e.** `scripts/e2e-chat-claude.sh` in `make e2e`.

## Measured on a dev build

- Opening a 2,000-message chat: 57 ms reading its newest page (346 items) and 43 ms measuring and laying out its rows. Budget 300 ms.
- A 500 to 600 word reply streaming: Canopy's main process at 14 to 21% of one core, down from 31% before streaming a block at a time. Budget 20%.
- The app's memory with the long chat open: 114 to 118 MB. Each `claude -p` holds 200 to 360 MB.
- Scrolling was not measured: scroll events posted to a background window do not arrive, and the Animation Hitches trace did not save. Older pages are 150 lines, read off the main actor. Listed for the author's hand check.

## Decisions to review

- The stand-in is a new script, `scripts/fake-claude-stream.py`, rather than a mode of `fake-claude.py`, which draws a pty screen.
- `CANOPY_CLAUDE` in the app's environment replaces the `claude` command, for fixtures and e2e only.
- A new chat starts in `default` and leaves the model to Claude Code's settings, then saves the model Claude reports. The TUI now starts in `auto`.
- AskUserQuestion and ExitPlanMode are denied with a request to ask in plain text until milestone 2.
- Close and quit warn about a chat only while Claude works.
- Rows are measured by Canopy with one reused hosting controller, laid out before each measure, instead of automatic row heights.
- Parts of `TranscriptParser` in `CanopyAgents` are public so chats reuse its records and wording.

## After Review

An independent opus review of `git diff origin/main...HEAD` found 3 high, 5 medium, and 5 low findings, all fixed:

1. High: a second permission request replaced the first, which then never got an answer. Pending requests are a queue showing the oldest, and Stop or "do this instead" denies all of them. Tests: `answersPermissionsAskedTogetherOneByOne`, `stopDeniesEveryOpenPrompt`, and the stand-in's `two`.
2. High: `PipeProcess` wrote while holding its state lock, so a `claude` that stopped reading could freeze the main actor. Writes happen outside the lock on the serial write queue, which alone closes the descriptor, and `terminate` signals before closing input.
3. High: a subagent's streamed text joined the main reply. Stream events with a parent tool call are skipped. Test: `skipsASubagentsStreamedText`.
4. Medium: messages Claude never took vanished when it exited. They go back into the composer.
5. Medium: sending after the transcript went missing resumed a missing session. Sending starts a fresh conversation.
6. Medium: any read error of `~/.claude.json` counted as "no file", so the trust write could replace the whole config. Only a missing file counts; anything else is `unreadable`.
7. Medium: `initialize` went out after the first message. It is written synchronously when the process starts, and its answer fills the command list.
8. Medium: messages queued before an interrupt stayed queued forever. They go back into the composer when the interrupted turn ends.
9. Low: a first page that fit on screen never scrolled, so older pages never loaded. The list loads older pages until it can scroll.
10. Low: every restored chat read `~/.claude.json` at launch. Trust is read when a chat first shows, and again before sending if it was missing.
11. Low: a list of publish times grew for the life of a chat. It keeps a count and the shortest gap.
12. Low: a result arriving while an older page loaded was dropped. It is applied after the page goes in. Test: `aResultArrivingWhileAnOlderPageLoadsIsKept`.
13. Low: any echo without a matching message removed the first queued one. An echo without text removes nothing, and merged texts are matched joined too.

Not changed: the trust write still reads and renames without Claude Code's lock, so a Claude Code write in the same few milliseconds can be undone; the read-back check catches the case where Canopy's own key is lost. Large integers in `~/.claude.json` keep full precision up to 2^53, which covers every value Claude Code writes today.
