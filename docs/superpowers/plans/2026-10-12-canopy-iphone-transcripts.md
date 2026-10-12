# Canopy on iPhone, Milestone 2: Reading and Answering Agents

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A paired phone reads an agent's conversation as text, replies to it, answers its questions and permission prompts, sees and drives its terminal, and marks it seen.

**Architecture:** Hooks now carry each pane's transcript path and the prompt a waiting agent waits on, which `PaneAgent` keeps with an ID.
`TranscriptParser` and `TranscriptReader` turn Claude Code's JSONL into entries a page at a time from the end, and `TranscriptFollower` sends what grows.
`PhonePanes` on the main actor pastes replies, presses the keys an answer needs, sends keys, marks agents seen, and reads styled screens; `PhoneService` serves the new `phone.*` methods and keeps each connection's streams.

**Tech Stack:** Swift 6, Swift Testing, SwiftTerm (styled lines), Python 3 for the stand-in phone, Claude Code 2.1.296 with Haiku for the real-agent e2e.

**Spec:** `docs/superpowers/specs/2026-10-12-canopy-iphone-design.md`, updated in this PR: Transcripts, Replies, Questions and permission prompts, Terminal tab, Phone methods, the inbox, Security, and decisions 12 to 17.

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings.
- `CanopyWire` imports only Foundation.
- Replies are one bracketed paste, then Return as its own write.
- An answer is sent only while the prompt it names is still the pane's open prompt.
- Lines the parser cannot read are skipped, never an error.
- Test fixtures are real transcripts with usernames, hostnames, and paths scrubbed.
- `make lint`, `make build` with 0 warnings, `make test` three clean runs on a quiet machine, `make e2e`.
- Markdown: one sentence per line, no em dashes. Conventional commits, no trailers.

## How Claude Code 2.1.296 behaves

Captured on 2026-10-12 in a throwaway folder: `claude -p --model haiku` for tool calls, and an interactive Haiku session in a private tmux server for the dialogs, with a hook that appended every event's stdin to a file.
Interactive capture needs `env -i`: an inherited `CLAUDE_CODE_CHILD_SESSION` turns transcript saving off.

- One `tool_use` per assistant line; its `tool_result` in a later user line, with `is_error` on failure; a call turned down at a permission prompt reads "The user doesn't want to proceed…", followed by a user line "[Request interrupted by user for tool use]".
- `AskUserQuestion` fires `PreToolUse`, then `PermissionRequest` with the same `tool_input`, then a `permission_prompt` `Notification`, then `PostToolUse` with `tool_input.answers`.
  Its result reads `Your questions have been answered: "Q"="A", "Q2"="B".`
- A one-question picker takes a digit and submits. Several questions take a digit each, then a review where `1` submits. A multiple choice toggles with digits (the cursor stays on the first option), and Submit sits past the options and "Type something".
- A Bash permission dialog offers 1 Yes (highlighted), 2 always allow the folder, 3 switch to auto mode, 4 No. Return allows. Escape prints "Interrupted · What should Claude do instead?" and runs no hook.
- `ExitPlanMode`'s dialog offers 1 Yes and use auto mode (highlighted), 2 Yes and approve edits by hand, 3 Tell Claude what to change. Escape rejects it, stays in plan mode, and runs no hook.
- A pasted reply is kept in the transcript between `<pasted_content id="…">` and `</pasted_content id="…">`.
- The folder trust dialog's default is "No, exit": Down, then Return trusts.

## Review Focus

1. An answer racing the agent: the prompt the phone saw is replaced (a new permission) before the answer arrives. Pinned by `anAnswerToAPromptThatMovedOnSendsNothing` and the e2e's stale answer.
2. A long reply into a busy pane losing all but its tail. Pinned by `aLongReplyLandsWhole` and the e2e's 40-line reply checked against the transcript.
3. The permission request and notification after an `AskUserQuestion` must not give the prompt a new ID, or the phone's answer would be refused. Pinned by `aQuestionStaysTheSamePromptThroughItsPermissionRequestAndNotification`.
4. A followed conversation must not resend pages the phone has not asked for. Pinned by `olderEntriesThanThePhoneHasAreLeftForItsPages`.
5. Reply text that tries to end the paste and type keys. Pinned by `aReplyCannotEndItsOwnPaste`.

## File Structure

New:

| File | Responsibility |
|---|---|
| `Sources/CanopyWire/Transcript.swift` | `TranscriptEntry`, `PromptQuestion`, `OpenPrompt` |
| `Sources/CanopyWire/PhoneProtocol.swift` (grown) | the new methods, params, results, and events |
| `Sources/CanopyCore/Phone/TranscriptParser.swift` | lines to entries |
| `Sources/CanopyCore/Phone/TranscriptReader.swift` | pages from the end |
| `Sources/CanopyCore/Phone/TranscriptFollower.swift` | following a conversation |
| `Sources/CanopyCore/Phone/TranscriptTails.swift` | each transcript's last entry, for last lines |
| `Sources/CanopyCore/Phone/PhoneAnswerKeys.swift` | an answer's keys |
| `Sources/CanopyCore/Phone/PhonePanes.swift` | replies, answers, keys, seen, screens, Delivered |
| `Sources/CanopyCore/Phone/PhoneStreams.swift` | each connection's streams, and `ScreenWatcher` |
| `scripts/phone-claude-e2e.py`, `scripts/e2e-phone-claude.sh` | the real-Claude e2e |
| `Tests/CanopyCoreTests/Fixtures/Transcripts/{tools,prompts,edges}.jsonl` | scrubbed captures and hand-written edge lines |
| Tests | `TranscriptReaderTests` (parser and reader), `TranscriptFollowerTests`, `AgentPromptTests`, `PhoneAnswerKeysTests`, `PhonePanesTests`, `PhoneServicePaneTests` |

Modified: `PaneAgent.swift` (`AgentPrompt`, `transcriptPath`, `prompt`, `answer(promptID:)`), `ClaudeHookMapping.swift`, `TermMethods.swift` (`transcriptPath` and `prompt` in `term.state`), `Pane.swift` (`paste`, `press`, `answerPrompt`, `onPrompted`), `TerminalStore` (`AgentEvent.prompted`), `TerminalEmulator.swift` and `SwiftTermEmulator.swift` (`styledLines`), `PhoneInboxBuilder.swift`, `PhoneHub.swift`, `PhoneService.swift`, `PhoneConnection.swift` (the method list), `ActivityEvent.swift` (`phone.call`), `AppModel.swift`, `Package.swift` (test fixtures), `scripts/phone-client.py`, `Makefile`.

---

### Task 1: Transcripts into entries

**Interfaces:** `TranscriptEntry { id, kind: prompt|text|tools|question|plan|notice, text, at, failed, questions?, answer? }`; `TranscriptParser.entries(from: [Data]) -> [TranscriptEntry]`; `TranscriptReader.page(of: URL, before: Int?, limit: Int) throws -> Page { entries, older, bytesRead }`, throwing `.missing`.

**Tests:** the `tools` capture folds two reads and three commands (one failed) and an edit; IDs are unique and times rise; the `prompts` capture gives questions with their answers, a declined call and its interrupt, a plan declined, two questions answered "Blue; Large", a multiple choice "Apple, Plum"; the `edges` lines leave out meta, local output, sidechains, an unreadable line, and `ToolSearch`, and read a slash command, an image, folded searches, reads, an agent, edits across two tools, a fetch, a to-do list, an MCP tool, a task notification, an interrupt, a compaction, and a paste; a question with no result yet has no answer and a command with no result is not failed; pages of a 300-turn transcript come newest first and join up exactly; the first page of a 2,000-turn transcript reads under 200 KB; a missing file is `.missing`; a half-written last line waits.

**Commit:** `feat: TranscriptReader turns Claude Code transcripts into the phone's conversation`

### Task 2: Transcripts and open prompts from hooks

**Interfaces:** `AgentReport.transcriptPath`, `AgentReport.prompt: AgentPrompt?`; `PaneAgent.transcriptPath`, `PaneAgent.prompt: OpenPrompt?`, `PaneAgent.answer(promptID:) -> Bool`; `ClaudeHookMapping.prompt(for:)`, `lastParagraph(_:)`; `TermStateParams.transcriptPath`, `.prompt` (a prompt it cannot read is dropped, keeping the state).

**Tests:** every hook carries its transcript; a question's prompt has its options, and its permission request describes the same prompt; a Bash permission names its command, other tools their file, URL, or MCP name; a plan; a turn ending on a question wants a reply with its last paragraph; a notification names no prompt; a question keeps its ID through permission request and notification and closes on `PostToolUse`; a new prompt gets a new ID; Escape and Return close a permission prompt; answering closes it at once and only once; the agent ending closes the prompt but keeps the transcript; a new session brings its transcript and another session's does not count; `term.state` carries both; the existing hook tests now expect prompts.

**Commit:** `feat: hooks name each pane's transcript and the prompt a waiting agent waits on`

### Task 3: Replies, answers, keys, seen, and screens on panes

**Interfaces:** `PhoneAnswerKeys.keys(for: OpenPrompt, PhoneAnswer) throws -> [String]`; `Pane.paste(_:)`, `Pane.press(_:pause:)`, `Pane.answerPrompt(id:)`; `AgentEvent.prompted(Pane)`; `TerminalEmulator.styledLines(_:)`; `@MainActor PhonePanes(terminals:)` with `start()`, `stop()`, `reply(_:delivered:)`, `answer(_:)`, `keys(_:)`, `seen(_:)`, `screen(_:scrollback:)`, `transcriptURL(_:)`, and `promptGone`, `noTranscript`.

**Tests:** `PhoneAnswerKeysTests` (one question, two, a multiple choice, permissions and plans, seven answers that do not fit, a permission given options, a reply prompt); `PhonePanesTests` against the read recorder (a reply is one paste and then Return alone, 200 lines land whole, escape characters are dropped, Delivered on the next prompt and only once, an answer's keys one read each and only once with a stale ID refused, Allow is Return and moves the agent to working, keys as they are, seen, a missing pane, the screen with its scrollback, the transcript only once a hook names it).

**Commit:** `feat: replies as one bracketed paste, answers as the keys the author would press, and styled screens`

### Task 4: Following a conversation

**Interfaces:** `TranscriptFollower(pane:following:path:sent:interval:send:)` with `start()`, `stop()`, `isStopped`; `PhoneTranscriptUpdate { pane, entries, reset }`.

**Tests:** new entries are sent and a folded group is sent again with its first call's ID; entries older than the newest the phone has are left to its pages; a new session sends `reset`; nothing changed sends nothing; it stops when the pane has no transcript.

**Commit:** `feat: TranscriptFollower sends a conversation's new and grown entries`

### Task 5: Prompts and last lines in the inbox

**Interfaces:** `PhoneAgent.prompt`, `.hasTranscript`, `.lastLine`; `PhoneInboxBuilder.inbox(_:terminals:tails:)`; `@MainActor TranscriptTails` with `last(in:)` and `keep(only:)`.

**Tests:** five prompts carry their IDs and read "Wants to run …", "Wants to use Write: …", "Asks: …", "Has a plan ready", "Asks: …"; a done agent's last line is its text's last line; an idle Claude stays with state none for its conversation; a background agent names what it waits on.

**Commit:** `feat: the inbox carries open prompts and each agent's last line`

### Task 6: The phone's methods

**Interfaces:** `phone.transcript`, `phone.reply`, `phone.answer`, `phone.screen`, `phone.keys`, `phone.seen`, `phone.unsubscribe` in `PhoneGate.allowedMethods` and `PhoneService`; `PhoneStreams` (16 per connection); `ScreenWatcher`; `ActivityType.phoneCall`.

**Tests (`PhoneServicePaneTests`, through the listener):** a page and its follow events, an older page, and nothing after unsubscribing; `no_transcript` and `pane_not_found`; a reply's Delivered event with its ID, and the log naming the phone and the text; a stale answer refused and Deny sent as Escape; keys sent and not logged; a screen and its change; seen.

**Commit:** `feat: phone.transcript, reply, answer, screen, keys, seen, and unsubscribe`

### Task 7: A real Claude Code from the phone

`scripts/e2e-phone-claude.sh`, in `make e2e` where Claude Code is installed, starts a dev build on loopback, pairs `scripts/phone-claude-e2e.py`, and runs `claude --model haiku --permission-mode default` in the main row.
The stand-in phone answers the trust dialog with `phone.keys`, sends a 40-line reply and checks the transcript holds it whole, answers a one-question picker, a two-question picker, and a multiple choice and checks each answer in the transcript, allows a Bash command and checks its file and transcript line, then refuses a stale answer and denies another command and checks its file is not there.
It removes the run's transcripts from `~/.claude/projects` afterwards.

**Commit:** `test: a real Claude Code answered from the phone: a long reply, pickers, and permission prompts`

## Verification

- `make lint`, `make build` (0 warnings), `make test` three times under load below the core count.
- `make e2e`, with `scripts/e2e-phone-claude.sh` passing against Claude Code 2.1.296.

## After Review

An independent opus review of `git diff origin/main...feat/iphone-transcripts` found one critical and four major problems, all fixed with tests:

1. Critical: a reply's Return answered whatever dialog was open, allowing a command or approving a plan the phone never saw.
   `PhonePanes.reply` now refuses with `prompt_open` while the agent waits on a dialog, and `Pane.paste(_:returnIf:)` checks again after the paste is read, in the same main-actor turn that writes Return.
   Tests: `aReplyNeverAnswersADialogThePhoneDidNotSee`, `aDialogOpeningDuringThePasteHoldsBackReturn`, `aReplyToAQuestionInTheMessageIsFine`.
2. A reply to a pane whose Claude Code had exited went to the shell, which runs a bracketed paste on Return.
   Replies need a session holding the pane, else `agent_not_running`. Test: `aReplyNeedsClaudeCodeRunning`.
3. Queued events were coalesced by subscription, which dropped transcript deltas the follower had already counted as sent.
   Only the inbox and screens, which carry the whole of something, are sent latest-only now. Test: `eventsThatAreNotLatestOnlyAllArriveInOrder`.
4. Keys typed into a dialog at the Mac, other than Return and Escape, left the prompt open for the phone to answer.
   Any key into a dialog closes its prompt; a draft typed after a question in the message does not. Tests: `anyKeyAtTheMacClosesADialogsPrompt`, `typingADraftLeavesAReplyPromptOpen`.
5. A connection's requests ran concurrently, so keys could reorder and an unsubscribe could miss a stream not yet added.
   Each request is now handled, answered, and its `after` run before the next. Test: `aConnectionsRequestsRunOneAfterAnother`.
6. Transcript reads could grow to megabytes: the follower reads at most 1 MB back and the inbox's tails 256 KB.
7. Delivered could name a reply the agent never took: waiting replies are forgotten when the agent stops, and after 10 minutes. Test: `aReplyTheAgentNeverTookIsForgottenWhenItEnds`.
8. A session switch's reset now carries its own `older` cursor, and following with `before` is refused. Test: `followingStartsFromTheNewestPage`.
9. A group the phone has that changes later, as when an earlier call fails after a later group was sent, is sent again. Test: `aGroupThePhoneHasThatChangesLaterIsSentAgain`.
10. A page starting inside a line with several entries takes all of them, and a line's second text entry is named by its place in the line, not in the parse. Tests: `aPageStartingInsideALineTakesAllOfItsEntries`, `idsDoNotDependOnWhereReadingStarts`.
11. A picker read only in part cannot be answered, rather than sending answers meant for another question. Test: `aPartlyReadPickerCannotBeAnswered`.
12. A transcript named by a hook but not written yet is an empty page that is still followed. Test: `aTranscriptNotWrittenYetIsEmptyAndStillFollowed`.
13. The e2e no longer leaves screen streams open, and removes its transcripts only after the app and Claude Code have quit.
14. Nits: the inbox's last lines are cut to one line of 80 characters; `PhoneStreams` cancels outside its lock; `Page.bytesRead` is internal.
    Left: `styledLines` finds the buffer's end the same way `recentText` does, which is a few hundred line lookups four times a second while a screen is open.

The screen test also ran into bash's "child setpgid" message landing after the output on a busy machine, so it checks the scrollback runs into the screen rather than which line is last.
