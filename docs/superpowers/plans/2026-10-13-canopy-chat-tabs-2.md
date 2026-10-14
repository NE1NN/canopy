# Chat Tabs, Milestone 2: Tools and Prompts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A chat shows what Claude's tools do and takes every kind of answer: diff cards, tool lines that open to their calls, running commands with their last lines, subagents with their call counts, question and plan cards, the mode, model, and context chips, and images.

**Architecture:** On top of milestone 1 (PR 48). `ChatBuilder` reads each result's structured data (`toolUseResult` in transcripts, `tool_use_result` in the stream) for diffs and counts subagent messages under their call. `ChatSession` keeps a queue of prompts of three kinds, the answer state of a question, expansion, tails of running commands read from Claude Code's task files, and the chat defaults. `ChatRows` keys rows by revision, expansion, and tail, so the table redraws exactly what changed.

**Tech Stack:** as milestone 1.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, milestone 2 under Delivery.

## Global Constraints

As milestone 1, and: nothing a row shows may change without its key changing, or the table keeps a stale height.

## What real Claude Code showed

- `set_model` answers success, but the next turn still runs on the old model; the one after uses the new one. So an idle chat ends its `claude` when the model changes, and the next message resumes the session on the new model; during a turn, `set_model` is sent.
- A local command such as the model switch echoes as a replayed user message (`<local-command-stdout>…`), which must not take a queued message.
- Switching to Bypass permissions later needs `--allow-dangerously-skip-permissions` at launch, which only makes it available.
- `initialize` lists models with `value`, `displayName`, and `resolvedModel`.
- A running command's output is in `/tmp/claude-<uid>/<folder>/<session>/tasks/<task>.output` while it runs.

## Review Focus

1. A pending question or plan must show once, as its card, not also as a history line. Pinned by the rows' filtering on the prompt's tool call.
2. Opening a tool line or diff card changes the row's height. Pinned by expansion living in the session and in the row key.
3. A model switch must reach the next message. Pinned by `ChatRealClaudeTests`, which switches to Sonnet and checks the next turn.
4. Typing at an open question answers it rather than denying it. Pinned by `answersAQuestionInItsOwnWords`.
5. A tail must stop when its command ends, and never read past a partial line. Pinned by `tailsARunningCommand`.

## Tasks

- [x] **Task 1: Diff cards.** `ChatEdit` from a result's `structuredPatch` or from an Edit, MultiEdit, or Write input; edits are `.edit` items, filled in by their result. `TranscriptParser.Record.toolUseResult`. Tests: `ChatEditTests` (3).
- [x] **Task 2: Questions and plans.** `ChatPermission.kind` (`permission`, `question`, `plan`); `pick`, `submitSelection`, typing as the answer, `approvePlan(acceptingEdits:)`; the cards, number keys 1 to 9, Return to submit or approve, Esc to decline; the waiting item hidden behind its card. The stand-in gains `plan`. Tests: `answersAQuestionByPickingAnOption`, `answersAQuestionInItsOwnWords`, `approvesAPlanAndSwitchesToAcceptingEdits`.
- [x] **Task 3: Chips.** `ChatDefaults` in `AppState`, `TerminalStore.chatDefaults`, `ChatSession.setMode` and `setModel`, `ClaudeModel` from `initialize`, `ChatFormat.modelName` and `modeName`, the chips. Tests: `modelsAndModes`, the real-Claude model switch.
- [x] **Task 4: Live tails.** `ChatSession.tails` read every 500 ms from the task file's last offset, five lines kept, the `.running` row. The stand-in gains `tail` and `FAKE_CLAUDE_TASKS`. Test: `tailsARunningCommand`.
- [x] **Task 5: Opening tool lines and diffs.** `ChatSession.expanded` and `toggle`, `ChatRow.item(_, expanded:)`, the calls with inputs and output excerpts.
- [x] **Task 6: Subagents.** `ChatBuilder.add(subagentLine:parent:)`, `ChatToolCall.innerCalls`, "· 3 tool calls". The stand-in gains `agent`. Test: `countsASubagentsToolCallsOnItsLine`.
- [x] **Task 7: Images.** `ChatSession.draftImages`, paste and drop as PNG, thumbnails with remove.

## Decisions to review

- An idle chat restarts its Claude Code on a model change (resuming the same session), because `set_model` lands a turn late.
- `--allow-dangerously-skip-permissions` is always passed, so the mode chip can offer Bypass permissions; it does not turn bypass on.
- The model chip lists Claude Code's own aliases (Opus, Sonnet, Haiku) until it has started and reported its models.
- Tool output in an opened line shows its first 12 lines.
- Images are sent as PNG whatever their source format.

## After Review

An independent opus review found 3 high, 6 medium, and 4 low findings, plus the tail test's flake; all fixed:

1. High: a Write that creates a file comes back with an empty patch, which blanked its card. A created file's content is its diff. Test: `aNewFileShowsItsContent`.
2. High: a question card kept its height when it moved to the next question. Its row key carries the step and the ticks.
3. High: a half-answered question carried over to the next prompt. Question state clears with the prompts, on close, at a turn's end, and on exit.
4. Medium: digits typed as an answer picked options. A digit picks only an option that exists, and never while an input method composes.
5. Medium: images went full size on the main thread. They are scaled to 1568 pixels and encoded off the main actor, as PNG or a JPEG under 5 MB, and thumbnails decode once.
6. Medium: pasting text from apps that also copy a picture attached the picture. Text wins.
7. Medium: picking a mode saved the reported model as the default, and Bypass or Plan became every new chat's mode. Only what the author picks is saved, and Bypass and Plan are never defaults.
8. Medium: an idle model switch killed background commands. With one running, `set_model` is sent instead; a restart tells the pane its process ended.
9. Medium: tail polling outlived a closed chat and read whole files. It stops with the chat, reads at most the last 16 KB, keeps a split character whole, and treats `\r` as a line end.
10. The tail test's flake: it compared strings and raced the stand-in's command; the stand-in's `tail hold` now runs until the test sends its next message.
11 to 16, low: the running card's clock and key come from the session; an empty question list falls back to a permission card; thumbnails are removed by ID; image drags are accepted by type; NotebookEdit shows its new source.
