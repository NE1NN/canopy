# Chat Tabs, Milestone 5: Agents and the Phone

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents open and drive chats through the `canopy` CLI as they drive terminals, and the iPhone app reads, replies to, and answers chats.

**Architecture:** On top of milestone 4 (PR 54).
`chat.new` opens a chat through `TerminalStore.openChat` with the model, mode, and session asked for, and sends `--prompt` as its first message.
The `term` methods that act on a pane's screen or keys take chat panes through their `ChatSession`: `send` sends a message or fills the draft, and `read` prints the conversation as text.
`TermInfo` and the phone's `PhoneAgent` gain `kind`, `terminal` or `chat`.
`PhonePanes` replies to and answers a chat through its session, and refuses its screen and keys with `not_a_terminal`; the phone app hides the Terminal tab and key bar for a chat.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, The CLI and the agent guide, The iPhone app, and milestone 5 under Delivery.

## Global Constraints

As milestone 1, and: `kind` is optional in CanopyWire, so an older phone app and an older box daemon keep working; a missing `kind` reads as `terminal`.

## Review Focus

1. `term send --enter` to a chat with an open permission or question must do what the composer does: deny, then send. Pinned by `termSendToAChatDeniesAnOpenPromptAndSends`.
2. `term send` without `--enter` must only fill the draft, never send. Pinned by `termSendWithoutEnterFillsTheDraft`.
3. `chat new` must never change which row is selected. The handler opens the tab through the store, which knows nothing of the app's selection, as `term new` does.
4. An older phone app must still read and answer a chat; only its Terminal tab errors. Pinned by `anAgentWithoutKindDecodesAsATerminal` and `phoneScreenOfAChatIsNotATerminal`.
5. `phone.reply` to a chat with an open prompt goes in as a message, not `prompt_open`. Pinned by `phoneReplyToAChatWithAnOpenPromptSendsIt`.

## Tasks

- [x] **Task 1: `chat new`.** `ChatMethod.new`, `ChatNewParams`, `ChatNewResult`, the handler, `RowLifecycle.newChat`, `ChatCommand`. Tests: `chatNewOpensAChatWithItsModelModeAndPrompt`, `chatNewRefusesAnUnknownModeAndASessionThatIsOpen`, an e2e step.
- [x] **Task 2: `term` on chats.** `send` (message or draft), `read` (the conversation as text, `--lines`), `list` with `kind`, `close` naming Claude as the busy program. Tests: `termSendToAChatDeniesAnOpenPromptAndSends`, `termSendWithoutEnterFillsTheDraft`, `termListShowsTheKind`, `closingAWorkingChatNamesClaude`; `term read` is checked in each.
- [x] **Task 3: The agent guide.** A Chats section: `chat new`, `term send`, `term wait`, `term read`.
- [x] **Task 4: The phone.** `PhoneAgent.kind`; `PhonePanes.reply` and `answer` through the chat's session; `screen` and `keys` refuse a chat. Tests: `phoneReplyToAChatWithAnOpenPromptSendsIt`, `phoneAnswerToAChatAllowsItsPermission`, `phoneAnswerToAChatAnswersItsQuestion`, `phoneScreenOfAChatIsNotATerminal`, `anAgentWithoutKindDecodesAsATerminal`.
- [x] **Task 5: The phone app.** No Terminal tab or key bar for a chat. Test: `aChatHasNoTerminalTab` in `ConversationModelTests`.

## Decisions to review

- `term send` without `--enter` adds to the chat's draft, as typing would; with `--enter` it sends the draft and the text together.
- A message sent before the author trusts the folder waits in the draft, and trusting sends it; `term read` says so. Before, it was dropped.
- `chat new --model` and `--mode` set that chat only; New Chat's defaults stay what the author last picked.
- `chat new --resume` of a session a pane already holds fails with `session_open`, naming the pane.
- A phone's "allow" on a chat's plan approves it with edits accepted, as Return on the terminal's first option does.
- `term list` shows `claude` as a chat's process while its Claude Code runs, and nothing otherwise.
- The CLI hands `CANOPY_CLAUDE` to the app it launches, as it does `CLAUDE_CONFIG_DIR`, so e2e chats run the stand-in.

## After Review
