# Chat Tabs, Milestone 3: Commands and Handoff

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `/` menu, `!` shell commands, Resume in a chat, and Open in Terminal, so a conversation moves between a chat and a terminal and every command has a home.

**Architecture:** On top of milestone 2 (PR 50).
`ChatBuilder` reads shell items from a TUI transcript's `<bash-input>` and `<bash-stdout>` lines and from the `<shell-run-by-user>` blocks a chat sends ahead of a message.
`ChatSession` runs `!` commands through a launcher the store supplies.
`ClaudeSessions` lists a row's conversations.
`TerminalStore.openInTerminal` replaces a chat tab with a terminal resuming its session, and `pane(holdingSession:)` keeps one owner per session.
`ChatCommandMenu` builds the `/` menu from `initialize` and `init`'s `terminal_slash_commands`.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, milestone 3 under Delivery.

## Tasks

- [x] **Task 1: Shell blocks.** `ChatContent.shell`, `ChatShell`; the builder reads TUI lines and blocks ahead of a message.
  Test: `readsShellCommandsAsShellBlocks`.
- [x] **Task 2: `!` commands.** `ChatSession.shellRuns`, `runShell` through the store's launcher (login shell, pane environment, row folder), output and exit, blocks sent with the next message, `$ shell command` hint, Esc stops.
  Test: `runsAShellCommandAndHandsItToClaudeWithTheNextMessage`.
- [x] **Task 3: Conversations.** `ClaudeSessions.list(folder:home:)` with titles from `custom-title`, `summary`, or the first prompt.
  Test: `ClaudeSessionsTests`.
- [x] **Task 4: Handoff.** `TerminalStore.pane(holdingSession:)`, `openInTerminal(_:running:)` (in place, same name, `claude --resume <id> --model <m> --permission-mode <mode> [prompt]`, `CANOPY_CLAUDE` as a stand-in).
  The chat header's Open in Terminal, the `+` menu's Resume in a chat (five newest), and the conversations sheet with search.
  A session a pane holds selects that pane.
  Test: `openInTerminalPutsATerminalResumingTheSessionInTheChatsPlace`.
- [x] **Task 5: The `/` menu.** `ClaudeInit.terminalCommands`, `ChatCommandMenu.items` (commands, then skills; full-screen ones open in a terminal; prefix matches first), the menu above the composer with ↑↓ and ⏎; `/resume` opens the sheet; commands with an argument go into the composer.
  Tests: `ChatCommandMenuTests`.

## Decisions to review

- The `/` menu lists what Claude Code reports once it runs; before a chat's first message it is empty.
- A full-screen command runs as the terminal's first prompt (`claude --resume <id> "/rewind"`), so Open in Terminal and the command are one step.
- A `!` command's stderr joins its stdout in the order printed, and it reads no input: `!cat` ends at once instead of waiting.
- A `!` command shows its last 30 lines until opened; Claude gets the last 30,000 bytes, as Claude Code's own `!` does.
- A `!` command reaches Claude as a `<shell-run-by-user>` block with its command, exit code, and output, ahead of the next message.
  The TUI's `<bash-input>` blocks would read the same, but Claude Code 2.1.296 does not echo a message holding them (checked against the real one), so a chat could not tell when Claude took it.
  A conversation resumed in a terminal shows the block as text.
- A `!` command runs while Claude is idle or working; Claude reads it with the next plain message, never with a `/` command, which must start its message.
- Open in Terminal sends what the chat had not sent yet (finished `!` commands and the draft) as the terminal's first message.
  A full-screen command from the `/` menu goes first instead.
  Pasted images that were not sent stay behind.
- A chat whose session a terminal holds says "Open in p12" with a button to show it, and starts when the terminal lets it go.

## After Review

An independent opus review found 4 high, 8 medium, and 4 low findings and missing tests; all fixed:

1. High: `!` commands outlived their chat.
   Closing a chat stops its command.
   Test: `aShellCommandStopsWithItsChat`.
2. High: `!` output grew without end on the main thread.
   It keeps about the last 60 KB and sends Claude the last 30 KB.
   Test: `outputKeepsItsEnd`.
3. High: a `!` command that read input waited forever.
   It reads `/dev/null`, and the shell's own input closes at once.
   Test: `aShellCommandReadsNoInputAndClaudeLearnsHowItEnded`.
4. High: `!` output vanished while queued and was lost when the message came back.
   It travels with its message, shows above it, and returns with it.
   Test: `shellCommandsWaitWithTheirMessageAndComeBackWhenItIsStopped`.
5. Medium: exit codes, stderr, and blank lines were lost.
   Stderr joins stdout, blank lines stay, and the exit code goes to Claude and back into the block.
6. Medium: output holding `</bash-stdout>` cut its block short.
   Blocks are cut at their last closing tags.
   Test: `outputThatHoldsItsOwnTagsStaysWhole`.
7. Medium: a `/` command after a `!` command could reach Claude as text.
   `!` output waits for the next plain message.
   Test: `aSlashCommandLeavesShellOutputForTheNextMessage`.
8. Medium: conversation titles missed Claude Code's `ai-title` records far down a transcript, and a first prompt holding an image dropped its conversation.
   Titles come from the end, prompts from up to 4 MB in.
   Test: `readsTheNewestTitleFromTheEndAndAPromptPastALargeImage`.
9. Medium: the `+` menu and the sheet read every transcript on the main thread, on each hover and keystroke.
   They load off the main thread, and titles are cached by file date and size.
10. Medium: Esc with the `/` menu open stopped Claude.
    It closes the menu.
11. Medium: Open in Terminal dropped a turn mid-step and lost the draft.
    It interrupts first and carries what was not sent.
    Test: `handingOffInterruptsAndReturnsWhatClaudeHasNotRead`.
12. Medium: a session could get two owners while a terminal started, or when a restored chat's session was open in a terminal.
    A terminal holds the session it resumes from the start, and a chat will not start on a held one.
    Test: `openInTerminalPutsATerminalResumingTheSessionInTheChatsPlace`.
13. Low: a second `!` command typed while one ran was lost.
    It stays in the composer.
14. Low: the name typed in full did not come first in the `/` menu, and the selection stayed put as the filter changed.
    Test: `theNameTypedInFullComesFirst`.
15. Low: conversations were listed from the Mac's home instead of the one chats use.
16. Low: output past 30 lines could not be seen, and a TUI block cut by a page could spin forever.
    Blocks open to all of their output, and a transcript's blocks never spin.
17. `ChatRealClaudeTests` now runs a failing `!` command and checks that Claude read its output and exit code.
    It showed that Claude Code does not echo a message holding `<bash-input>`, so the queued message never cleared; chats now send a block of their own, and the stand-in drops the echo as Claude Code does.

Also fixed along the way: a warning for a `switch` case handled twice, and, found while taking the shots, Return in an untrusted folder trusted it but left the typed message unsent, so the next Return sent it joined to whatever came after.
Trusting now sends what was written.
Test: `trustingSendsWhatWasWritten`.

CodeRabbit's review found six more, all fixed:

1. A `/` command picked from the menu in an untrusted folder was dropped.
   It waits in the draft, and trusting sends it.
2. A slow conversation list for an earlier row could replace the current row's in the `+` menu.
   Only a list read for the row still selected is kept.
3. Open in Terminal could start the terminal's Claude Code while the chat's was still exiting.
   It waits for that process to end.
4. Output holding a fence of three backticks broke the fence Open in Terminal wraps it in.
   The fence is longer than any run of backticks in the output.
   Test: `handingOffFencesOutputThatHoldsAFence`.
5. The title cache kept transcripts that were gone.
   Listing a folder forgets its missing ones.
6. This plan had lines with more than one sentence.

Also fixed: `aDialogOpeningDuringThePasteHoldsBackReturn` raced a two-second timer and failed under load.
Return now waits on the test, which lets it go once the dialog's hook has landed.
`TCPTests.bindsAgainAtOnceAfterClosing` failed on CI's macOS runner with "Address already in use", though not here in 100 runs under load, old or new.
Its client closed first, which can leave the server's side in LAST_ACK, and no option lets a bind past that.
Canopy's side now closes first, as when the address goes away, so its side is left in TIME_WAIT, which `SO_REUSEADDR` covers.
