# Chat Tabs, Milestone 3: Commands and Handoff

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `/` menu, `!` shell commands, Resume in a chat, and Open in Terminal, so a conversation moves between a chat and a terminal and every command has a home.

**Architecture:** On top of milestone 2 (PR 50). `ChatBuilder` reads `<bash-input>` and `<bash-stdout>` as shell items, from TUI transcripts and from blocks a chat sends ahead of a message. `ChatSession` runs `!` commands through a launcher the store supplies. `ClaudeSessions` lists a row's conversations. `TerminalStore.openInTerminal` replaces a chat tab with a terminal resuming its session, and `pane(holdingSession:)` keeps one owner per session. `ChatCommandMenu` builds the `/` menu from `initialize` and `init`'s `terminal_slash_commands`.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, milestone 3 under Delivery.

## Tasks

- [x] **Task 1: Shell blocks.** `ChatContent.shell`, `ChatShell`; the builder reads TUI lines and blocks ahead of a message. Test: `readsShellCommandsAsShellBlocks`.
- [x] **Task 2: `!` commands.** `ChatSession.shellRuns`, `runShell` through the store's launcher (login shell, pane environment, row folder), output and exit, blocks sent with the next message, `$ shell command` hint, Esc stops. Test: `runsAShellCommandAndHandsItToClaudeWithTheNextMessage`.
- [x] **Task 3: Conversations.** `ClaudeSessions.list(folder:home:)` with titles from `custom-title`, `summary`, or the first prompt. Test: `ClaudeSessionsTests`.
- [x] **Task 4: Handoff.** `TerminalStore.pane(holdingSession:)`, `openInTerminal(_:running:)` (in place, same name, `claude --resume <id> --model <m> --permission-mode <mode> [prompt]`, `CANOPY_CLAUDE` as a stand-in). The chat header's Open in Terminal, the `+` menu's Resume in a chat (five newest), and the conversations sheet with search. A session a pane holds selects that pane. Test: `openInTerminalPutsATerminalResumingTheSessionInTheChatsPlace`.
- [x] **Task 5: The `/` menu.** `ClaudeInit.terminalCommands`, `ChatCommandMenu.items` (commands, then skills; full-screen ones open in a terminal; prefix matches first), the menu above the composer with ↑↓ and ⏎; `/resume` opens the sheet; commands with an argument go into the composer. Tests: `ChatCommandMenuTests`.

## Decisions to review

- The `/` menu lists what Claude Code reports once it runs; before a chat's first message it is empty.
- A full-screen command runs as the terminal's first prompt (`claude --resume <id> "/rewind"`), so Open in Terminal and the command are one step.
- Shell output shows its last 30 lines; Claude gets all of it.
- A `!` command runs while Claude is idle or working; Claude reads it with the next message either way.

## After Review

Filled in after the independent review.
