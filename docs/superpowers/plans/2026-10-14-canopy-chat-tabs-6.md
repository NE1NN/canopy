# Chat Tabs, Follow-up: Streaming Cost, Phone Delivery, and Two Flakes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** What the five milestones left open: a streaming reply within the 20% CPU budget, phone reply delivery checked against the real headless Claude Code, and two flaky tests fixed.

**Architecture:** On top of milestone 5 (PR 55).
The block Claude is still writing is drawn by an AppKit text view, measured with TextKit, instead of a SwiftUI row laid out three times per redraw; it becomes a normal SwiftUI row once it settles.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, Performance and The iPhone app.

## Tasks

- [x] **Task 1: The growing block in AppKit.**
- [x] **Task 2: Phone reply delivery against the real Claude Code.**
- [x] **Task 3: `RemoteImageLoaderTests` and `ConversationModelTests` flakes.**

## The growing block in AppKit

`StreamingTextView` draws the block Claude is still writing with TextKit 1.
Its text is edited in place from the first character that changed, and it is laid out in pages 80 points tall, each its own text view on one shared layout manager, so a redraw repaints only the last page.
Its row height comes from its own layout rather than the SwiftUI sizer.
`ChatTextLines` in CanopyCore flattens a block into styled paragraphs with `MarkdownView`'s spacing and indents, so the switch to `MarkdownView` when the block settles does not move the text.
A block that needs more than text stays a SwiftUI row: a table, and inside a list or quote a code block, quote, or rule, or an item that opens with a list.

The rows are split in two halves.
The conversation is read in `ChatView`'s body, so opening a chat stays one SwiftUI pass.
What comes after it (the text being written, queued messages, prompts, the status line) is followed by `ChatList`'s coordinator with Observation, outside SwiftUI, so streaming no longer updates `ChatView`.
When both change at once, as when a reply settles into an item, they are shown together.

Streamed text lines are decoded into only the fields Canopy reads, and the text is drawn 20 times a second instead of 30.
Each draw costs about the same however little it adds, so the draw rate is what moved the numbers last; the spec allowed at most 30.

### Measured

On dev builds with the heavy-work lock held and load average 3.5 to 6, using the stand-in Claude at 50 words a second.
Each scenario was run three times; CPU time is what Canopy used over 6 seconds of streaming, and `ps` is the decaying average earlier PRs reported.

| Scenario | Before (milestone 5) | Debug build | Optimized build |
|---|---|---|---|
| `prose 600`, new chat | 35.3% `ps`, 37.0 to 37.7% CPU time | 19.7 to 21.3% | 17.3 to 17.7% |
| `prose 600`, 2,000-message chat | 29.7% `ps`, 37.3 to 37.8% CPU time | 17.8 to 19.5% | 16.0 to 17.0% |
| `slow 600`, 2,000-message chat | 32.7% `ps`, 36.2 to 38.3% CPU time | 18.2 to 19.7% | 15.8 to 17.8% |
| Working, no text | | 0.5% | 0.3 to 0.5% |

The optimized build is what `make release` ships: it is `swift build -c release` with `DEBUG` defined only so it can launch the stand-in Claude.
Runs on the same build vary by about 3 points from one round to the next.
The 2,000-message chat opens as before: Canopy uses 0.62 to 0.64 seconds of CPU from launch to showing it, the same as milestone 5.

## Phone reply delivery, checked against the real Claude Code

A phone reply to a chat counts as delivered when the chat's Claude Code fires `UserPromptSubmit`.
Checked against headless Claude Code 2.1.296 (`claude -p --input-format stream-json`, Haiku) with a `UserPromptSubmit` hook passed by `--settings`:

- A message sent while idle: one hook call, with its text.
- Two messages sent 10 seconds into a turn, during a Bash step: one hook call each, in order, and each echoed on its own.

So each message a chat sends gets its own `UserPromptSubmit`, as delivery assumes, and nothing changed.
Delivery is still credited in order per pane, as for a terminal: a message the author sends on the Mac before a pending phone reply is taken counts as that reply's delivery.

## The two flakes

- `RemoteImageLoaderTests.viewsAskingAtOnceShareOneDownloadAndTheCacheKeepsIt` failed when `NSCache` dropped the image it checks, which it may do whenever the machine runs short of memory, as during a full test run.
  Box server PR 60 fixed the same flake the same way (`LoadedImages`, `KeptImages`), so merging main kept its version.
- The phone's `ConversationModelTests` flake came from coming back to the foreground while an attempt was under way.
  PR 60 fixed it too: the attempt under way finishes, within its 10 second timeout, and the next one starts at once; merging main kept that.
  What stays from this PR is that a connect whose task is cancelled gives up at once, in `TCPChannel.open` and between hosts, pinned by `aConnectNobodyWaitsForAnyMoreIsGivenUp`.

## Decisions to review

- **20 draws a second instead of 30.** At 30, the debug build measured 20 to 24% and the optimized one 18 to 24%, over or at the line.
  Text appears two or three words at a time instead of one or two.
  Moving it back is the one constant in `ChatSession.streamingInterval`.
- **Measuring the optimized build.** The budget is for Canopy as it ships, and the debug build runs this code unoptimized; both are reported.
- **Blocks nested in lists and quotes stay SwiftUI rows while they stream.** Drawing their boxes and bars in TextKit is possible, but a code block inside a list item is the less common case and costs more code than it saves.

## After Review

An Opus review of the branch found these, all fixed:

1. A reply settling into an item showed twice for a frame, because the conversation and what is pending landed on different run loop turns.
   They are now shown together.
2. Blocks nested in a list or quote, such as a code block in a numbered step, lost their box, bar, or rule while streaming, and their streamed height stuck once they settled.
   Those blocks now stay SwiftUI rows, and a settled block is always measured by SwiftUI.
3. A quote's text changed from grey to full color as it settled, because `InlineText` set its own color over the quote's.
   `InlineText` now takes its color from the environment, so a settled quote stays grey as `MarkdownView` meant.
4. A block with an emoji was laid out again from its start on every draw, because the comparison read the text storage, where TextKit had swapped in the emoji font.
   It now compares with the text it last built.
5. A scroll made between two updates was dropped, so a mouse-wheel tick could be pulled back to the bottom.
   It is now checked once the table settles, and any scroll up stops following, so a slow trackpad scroll is not pulled back either.
6. A hard line break or code line inside a list item started its next line at the marker instead of the text.
7. Page bookkeeping could add pages without end for text that got shorter or a row with no width yet.

And from the lower findings: the column sits on the pixel grid as SwiftUI centers it, code clips at its box's border, a reply's blocks keep their settled 10-point spacing while streaming, an empty code block measures the same both ways, and an item opening with a list stays a SwiftUI row.

Not changed: `TCPChannel.open` can start a connection that a cancel just closed, between its check and `start`.
Starting a cancelled `NWConnection` only reports `.cancelled`, which the handler ignores once the opener has been resumed, so nothing leaks.

Found while measuring, also fixed: showing the conversation only together with what is pending made a chat open outside SwiftUI's update, which cost a fifth of a second of CPU; it now waits only when pending rows are on screen.
And a view getting taller is no longer taken for the author scrolling up.

Found while checking shots, also fixed: a line of only `-` or `=` under a line of text, as when a nested item starts, drew that line as a heading until the next word came.
