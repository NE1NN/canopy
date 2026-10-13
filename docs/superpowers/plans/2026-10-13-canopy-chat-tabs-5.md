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
3. `chat new` must never change which row is selected. Pinned by `chatNewLeavesTheSelectionAlone`.
4. An older phone app must still read and answer a chat; only its Terminal tab errors. Pinned by `anAgentWithoutKindDecodesAsATerminal` and `phoneScreenOfAChatIsNotATerminal`.
5. `phone.reply` to a chat with an open prompt goes in as a message, not `prompt_open`. Pinned by `phoneReplyToAChatWithAnOpenPromptSendsIt`.

## Tasks

- [ ] **Task 1: `chat new`.** `ChatMethod.new`, `ChatNewParams`, `ChatNewResult`, the handler, `RowLifecycle.newChat`, `ChatCommand`. Tests: `chatNewOpensAChatWithItsModelModeAndPrompt`, `chatNewLeavesTheSelectionAlone`, an e2e step.
- [ ] **Task 2: `term` on chats.** `send` (message or draft), `read` (the conversation as text, `--lines`), `list` with `kind`, `close` naming Claude as the busy program. Tests: `termSendToAChatDeniesAnOpenPromptAndSends`, `termSendWithoutEnterFillsTheDraft`, `termReadPrintsTheConversation`, `termListShowsTheKind`.
- [ ] **Task 3: The agent guide.** A Chats section: `chat new`, `term send`, `term wait`, `term read`.
- [ ] **Task 4: The phone.** `PhoneAgent.kind`; `PhonePanes.reply` and `answer` through the chat's session; `screen` and `keys` refuse a chat. Tests: `phoneReplyToAChatWithAnOpenPromptSendsIt`, `phoneAnswerToAChatAnswersItsQuestion`, `phoneScreenOfAChatIsNotATerminal`, `anAgentWithoutKindDecodesAsATerminal`.
- [ ] **Task 5: The phone app.** No Terminal tab or key bar for a chat. Test: `aChatHasNoTerminalTab` in `ConversationModelTests`.

## Decisions to review

## After Review
