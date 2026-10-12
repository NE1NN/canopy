# Canopy on iPhone design

Date: 2026-10-12
Status: approved, milestones 1 to 3 built.
The author approved the design in conversation on 2026-10-12, and this spec writes it down.
Milestone 1's PR settled what the design left open once it met the code; "Decisions made while building" lists each.
The author picked direction A from three mockups, kept outside git in the main checkout's `build/pages/canopy-iphone/`.

## Summary

A native iPhone app lets the author check in on Canopy's agents and answer them while away from the Mac.
Its home screen is an inbox that sorts agents by what they need: waiting for the author, done, or still running, with pinned rows such as `main` on top.
Opening a row shows its agent's conversation as text, read from Claude Code's transcript, with a reply box, one-tap answers to questions, and Allow and Deny for permission prompts.
A Terminal tab shows the pane itself for the rare case Chat is not enough.
The Mac sends push notifications when an agent waits or finishes, and permission prompts can be answered from the lock screen.
The phone reaches the Mac over Tailscale, through a listener that only accepts paired phones, with no server or database of Canopy's in between.
Starting new work from the phone, the author's "mode 2", comes after the first version, through a New task sheet.

## Goals

1. From the phone, the author sees every agent that is waiting, done, or running, sorted in that order.
2. The author reads an agent's conversation as text and replies to it.
3. The author answers multiple-choice questions and permission prompts with one tap.
4. A push notification arrives when an agent starts waiting or finishes, unless the author is at the Mac.
5. Permission prompts can be answered from the notification without opening the app.
6. Only phones the author paired can reach Canopy, and only over the author's tailnet.
7. The design leaves room for starting rows from the phone without restructuring.

## Non-goals

- A cloud database, a relay, or any server of Canopy's.
  The Mac is the only source of truth, and everything goes between the author's own devices.
- Reaching the Mac without Tailscale.
- The Ports panel, the activity log, plugins, groups, and row or repo management on the phone.
- Chat for remote rows on ssh hosts in the first version.
  Their transcripts live on the host, so they get states, notifications, and the Terminal tab only.
- Chat for agents other than Claude Code.
  Other panes get the Terminal tab.
- iPad and Mac Catalyst layouts.
- The App Store.
  The app installs from Xcode, and TestFlight can come later.
- Waking a sleeping Mac.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Home screen | An inbox sorted by what agents need, with pinned rows on top | The author picked direction A. Every row stays reachable, but idle rows stay off the home screen. |
| App type | Native SwiftUI | The author's choice. It gets lock-screen action buttons, which iOS web apps do not, and shares Swift code with the Mac. |
| How the phone reaches the Mac | Tailscale, directly to the Mac | The author's choice. Nothing listens on the public internet, and there is no copy of terminals or transcripts on anyone's servers. |
| Cloud database | None | The Mac holds the live state and nothing runs while it sleeps, so a copy adds sync work and an internet path into terminals running with permissions bypassed. |
| Second lock | A device token from pairing, on top of Tailscale | Another device on the tailnet, or a shared node, must not reach Canopy. |
| Protocol | The control protocol's newline-delimited JSON, over TCP | The app and CLI already speak it, and WireGuard already encrypts the tailnet. |
| What the phone may call | A fixed list of `phone.*` methods | A lost phone must not remove rows, repos, or hooks. |
| Conversation source | Claude Code's transcript file, found through the hooks | Text reads well at phone width. A terminal drawn for 120 columns does not. |
| Replies | A bracketed paste, then Return | Typed long messages into a busy Claude Code pane lost all but their tail on 2026-10-08. A paste arrives whole. |
| Permission answers | Keystrokes into the pane, after checking the prompt is still the same one | A blocking `PermissionRequest` hook would hide the prompt from the author at the Mac. |
| Push | The Mac app calls Apple's push service with the author's key | No server of Canopy's. |
| When to push | On a move to waiting or done, unless the Mac had input in the last 2 minutes and its screen is unlocked | The phone should not buzz for something the author is already looking at. |
| Shared code | A new `CanopyWire` module that builds for macOS and iOS | `CanopyCore` opens ptys and builds only for macOS. |
| App lock | Face ID when the app opens after 5 minutes away, on by default | A paired phone can make agents do anything they can do. |

## Architecture

```
iPhone app ──Tailscale (WireGuard)──▶ PhoneListener in Canopy.app ──▶ the same handlers the CLI reaches
     ▲                                        │
     └──── Apple Push Notification service ◀──┘ PhonePush
```

### CanopyWire

A new library target with no platform-specific code, built for macOS 15 and iOS 18.
It takes from `CanopyCore`:

- `ControlRequest`, `ControlResponse`, `ControlError`, `ControlCodec`, and `JSONValue`.
- The agent states the phone shows: working, waiting, done, background, and none, with `AgentDot`, which orders them by urgency.
- `PRState`, for the PR numbers on the Rows tab.

and adds the phone's own types: the inbox, transcript entries, prompts, pairing links, and the `phone.*` method names and parameters.
The inbox's sorting into pinned rows, Needs you, Done, and Running lives here too, so the Mac's tests cover what the phone shows.
`CanopyCore` depends on `CanopyWire` and re-exports it with `@_exported import`, so the CLI and app change no imports.
`ControlError`'s initializers from `WorkspaceError` and the CLI's socket errors stay in `CanopyCore` as an extension.
SwiftPM sets platforms for a whole package, so `Package.swift` adds `.iOS(.v18)` to the package's platforms and a `CanopyWire` library product.
Only `CanopyWire` is ever built for iOS; the other targets still need macOS.

### PhoneListener

A TCP listener in the app, on port 6974, bound only to the Mac's Tailscale addresses: those in `100.64.0.0/10` and `fd7a:115c:a1e0::/48` on a `utun` interface.
It follows network changes through `NWPathMonitor`, so it binds when Tailscale comes up and closes when it goes down, with the connections on an address that went away.
Without Tailscale it stays closed, and `canopy phone status` says why.

Tests and `make e2e` run on Macs without Tailscale, so a dev build listens on the one address `CANOPY_PHONE_LISTEN` names, such as `127.0.0.1:7123`, and nowhere else.
Without it, or with something that is not a numeric IPv4 or IPv6 address and a port, a dev build does not listen at all, so it never takes the tailnet port from the release app or answers a paired phone with `unpaired`.
The CLI passes the variable on to the app it launches, as it passes `CANOPY_HOME`.
A release build refuses the override at compile time: the app reads it only under `#if DEBUG`, which SwiftPM defines for debug builds and never for `-c release`, which `make release` and `make install` use.
A release build that finds the variable set ignores it, and `canopy phone status` names it as ignored.
The app opens its control socket before the listener starts, so nothing the network does can keep the CLI out, and an address the listener cannot have within 5 seconds, as when another app holds the port, counts as a failure that the next network change tries again.
TCP keepalive notices a phone that vanished without closing, as when it sleeps or leaves Wi-Fi, within about a minute.
A phone that stops reading holds one waiting inbox or screen, the newest, not every one since; conversation updates, which each carry only what changed, are all kept.

Each connection must send `phone.hello` with its device token first.
Any other first message except `phone.pair`, a wrong token, or no `phone.hello` within 10 seconds closes the connection, after an error naming why: `not_authenticated`, `unpaired`, or `bad_pairing_code`.
`phone.pair` does not authenticate the connection: the phone sends `phone.hello` with its new token next, and the 10 seconds start again.
Lines pass this gate one at a time and in order, so a phone may send `phone.hello` and its next request together.
After `phone.hello` the connection may call only the methods in "Phone methods"; any other gets `method_not_allowed` and the connection stays open.
Requests reach the same workspace and terminals the control socket's handlers use, so the phone and the CLI never disagree about state.
The control socket does not answer `phone.*` methods.

A connection's requests are handled one at a time in the order they came, each answered before the next starts, so keys go in in the order sent and an unsubscribe finds the stream it names.
Streams send events, one JSON object per line like responses, told apart by their `event` key: `{"v": 1, "event": "phone.inbox", "subscription": "<the request's id>", "data": {...}}`.
A stream's first event never comes before the response to the request that started it.

### Pairing

`canopy phone pair` makes a one-time pairing code that expires after 5 minutes and prints a QR code in the terminal, black on white whatever the terminal's colors, then waits until a phone uses the code.
`--json` prints the code and link without waiting.
A code is eight letters and digits from an alphabet without 0, 1, I, L, O, or U, shown as `K7QX-M2PD`; case, spaces, and the dash do not matter.
Five wrong codes in a row void every code outstanding, so none can be guessed.
The QR code holds `canopy-phone://pair?host=<MagicDNS name>&port=6974&code=<code>&addr=<Tailscale address>`, and the phone tries `addr` when the name does not resolve.
The MagicDNS name comes from `tailscale status --json`, through the Tailscale app's CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale` or Homebrew's; without it, `host` is the address too.
The pairing code is refused while the listener is closed, with `phone_listener_closed`.
The phone scans it, connects, sends `phone.pair` with the code and its name, and gets back a device token: 32 random bytes.
The phone keeps the token in its Keychain.
The Mac keeps only the token's SHA-256, with the device's name, its push token, and when it last connected, in `CANOPY_HOME/phones.json`, readable only by the author, and compares tokens in constant time.
A name another phone has gets a number, as `iPhone 2`.

`canopy phone list` shows paired phones.
`canopy phone remove <name>` forgets one and closes its connections at once.
`canopy phone status` says where the listener listens or why it does not, how many phones are paired and connected, and whether notifications work.
The commands reach the app through `phones.pair`, `phones.paired`, `phones.list`, `phones.remove`, and `phones.status` on the control socket, which only the author's own processes can open.

### Phone methods

| Method | What it does |
|---|---|
| `phone.hello` | Authenticates the connection. Returns the Mac's name and Canopy's version. |
| `phone.pair` | Trades a pairing code for a device token. Allowed before `phone.hello`. |
| `phone.subscribe` | Returns the inbox, then streams changes to it: agent states, last lines, and rows coming and going. A second call on the same connection replaces the first. |
| `phone.rows` | Every row, by repo then plugin, with its agents and PR. |
| `phone.transcript` | One page of a pane's conversation, newest first, with a cursor for older pages. Streams new entries while the conversation is open. |
| `phone.reply` | Pastes text into a pane and presses Return. |
| `phone.answer` | Answers the pane's open prompt: a question's option, Allow, or Deny. |
| `phone.screen` | The pane's screen as text with colors, streamed while the Terminal tab is open. |
| `phone.keys` | Sends keys from the Terminal tab's key bar or keyboard into a pane. |
| `phone.push` | Registers or replaces the phone's push token. |
| `phone.seen` | Marks a done agent as seen, as looking at it on the Mac does. |
| `phone.unsubscribe` | Stops a stream another request started: the inbox, a conversation, or a screen. |

Mode 2 adds `phone.newRow`, which takes the same options as `canopy row new` plus a brief to start an agent with.

The inbox is every row in sidebar order, repos then plugins, each with its name, repo or plugin, whether it is the repo's own checkout, and an entry per pane whose agent is not none or that has a conversation to read: its state, whether a done is unseen, when it reached the state, its open prompt, whether it has a transcript, its last line, and what a background agent waits on.
The last line is what the open prompt wants ("Wants to run npx convex deploy", "Asks: …", "Has a plan ready"), what a background agent waits on, or the conversation's last entry: the last line of the agent's text, a tool group's line, or "You: …".
Each change sends the whole inbox again, since it is a few kilobytes and a phone that misses one cannot drift.
Changes made together go out as one after 100 milliseconds, and a poll every 2 seconds sends what has no event of its own, such as the author seeing a done agent on the Mac.
`phone.rows` adds PRs and groups rows by repo; the Rows tab lays live agent states from the inbox over it.

## Reading and answering agents

### Transcripts

Claude Code's hooks pass `transcript_path` with every event.
`ClaudeHookMapping` records it on the pane's agent next to the session ID, and it changes when the session does.
It stays after the agent exits, so a conversation can still be read; a remote row's transcript lives on its host, so its panes have none.
`canopy agent-hook` hands the path and the open prompt to the app in `term.state`'s params, as it hands the state.

`TranscriptParser` and `TranscriptReader` in `CanopyCore` turn the JSONL file into entries, each with an ID that stays the same while the entry grows:

- **prompt**: the author's words. A paste, which Claude Code keeps between `<pasted_content id="…">` tags, reads as the text pasted, and an image as `[image]`.
- **text**: the agent's text.
- **tools**: consecutive tool calls of the same kind as one line, by the first call: "Ran make test and 2 more", "Read ControlServer.swift and 3 more", "Edited 2 files", "Searched for …", "Fetched developer.apple.com", "Ran an agent: …", "Updated the to-do list", "Used notion-search".
  A failed call adds ", failed", or ", 1 failed" to a group, and a call the author turned down at a permission prompt ", declined".
- **question**: an `AskUserQuestion` call with its questions and options, and the answer once there is one ("Blue; Large", "Apple, Plum", or "Declined").
- **plan**: an `ExitPlanMode` call with the plan, and "Approved" or "Declined".
- **notice**: a slash command (`/clear`), an interrupt, a background task finishing, or the conversation being compacted.

Tool output, thinking, `ToolSearch`, subagent lines, meta lines, local command output, attachments, and system lines are left out.
Lines it cannot parse are skipped, so a new Claude Code version degrades to missing entries instead of an error.

`phone.transcript` reads backward from the end of the file in chunks from 64 KB, so the first page of a long session costs one read of its end.
A page lists its entries oldest first, with `older`, the byte offset where the next older page ends.
Results of the page's last calls are looked for up to 256 KB past it.
A group of calls that straddles two pages shows as two groups.
With `follow`, a `TranscriptFollower` checks the file's size every 300 ms, which also notices the pane moving to another session's file, and sends entries that are new or changed since the last it sent, newer than the newest the phone has: a group sent again as it grows replaces the one with its ID.
A move to another session sends the new conversation with `reset`.
`phone.unsubscribe` with the request's ID stops following, and so does closing the connection.

### Replies

`phone.reply` sends the text as one bracketed paste, then Return as its own write once the program has read the paste and 200 ms have passed, which is how `term send --enter` already sends Return.
Newlines go in as Return, as a terminal pastes them, and escape characters are left out, so a reply cannot end its own paste.
The phone shows Sent when the Mac answers, and Delivered when `phone.delivered` arrives with the reply's request ID, sent when the pane's next `UserPromptSubmit` hook arrives.
A reply to a working agent is allowed, and Claude Code queues it as it does at the Mac.
A reply needs a Claude Code session holding the pane, or it answers `agent_not_running`, so it never runs as shell commands.
While the agent shows a dialog that keys answer, a reply answers `prompt_open`, since its Return would answer the dialog; it is checked again just before Return, in the same turn of the main actor that writes it, so a dialog that opens during the paste keeps the text in Claude Code's input and gets no Return.
A reply the agent never takes is forgotten when its agent stops or after 10 minutes, so a later prompt typed at the Mac never reads as its Delivered.
Checked with Claude Code 2.1.296: a 40-line, 2,930-character reply lands whole in the transcript.

### Questions and permission prompts

When a pane goes to waiting, the Mac keeps what it is waiting on as the pane's open prompt, with an ID:

- `AskUserQuestion`: its questions and options, from the `PreToolUse` hook's tool input.
- A permission request: the tool and what it wants to run (a command, a file, a URL, a query, or an MCP tool's name), from the `PermissionRequest` hook.
- `ExitPlanMode`: the plan.
- A question in the agent's last message, found the way `endsOnQuestion` finds it: its last paragraph, with no options, answered only by a reply.

Claude Code 2.1.296 sends `PreToolUse`, then a `PermissionRequest` for the same tool, then a `permission_prompt` `Notification` for one `AskUserQuestion` or `ExitPlanMode`, so a hook that describes the open prompt again keeps its ID, and a notification leaves it as it is.
The prompt closes when the agent's state leaves waiting, by a hook, when any key is typed into the dialog at the Mac (a digit or an arrow makes what the phone saw out of date), and the moment `phone.answer` takes an answer, so a second answer to the same prompt gets `prompt_gone`.

`phone.answer` takes the prompt's ID and the answer.
If the pane's open prompt has a different ID, or none, it answers `prompt_gone` and sends nothing.
Otherwise it sends the keys the author would press, each as a write of its own 150 ms apart, as checked against Claude Code 2.1.296:

| Prompt | Keys |
|---|---|
| One question | The option's digit, which picks and submits. |
| Several questions | Each question's digit, then `1` on the review that follows to submit. |
| A multiple choice | Each chosen option's digit, which toggles it, then Down past the options and "Type something" to Submit, Return, and `1` on the review. |
| Permission | Return for Allow, the highlighted "Yes". Escape for Deny, which interrupts the agent with no hook, as at the Mac. |
| Plan | Return to approve, which takes the dialog's first option, as Return does at the Mac. Escape to keep planning. |

The phone offers only the options it was given; "Type something" and "Chat about this" are left to a reply or the Terminal tab.

### Terminal tab

`phone.screen` answers with the pane's screen at the Mac's width and up to 500 lines of scrollback above it, each line with SGR escape sequences for its colors and styles, then sends the visible screen whenever it changes, four times a second at most, until `phone.unsubscribe`.
The phone draws it in a monospaced font, scrolls sideways, and pinch-zooms.
`phone.keys` sends the key bar's esc, tab, ctrl, and arrows, and whatever the author types, as they are.
A connection may follow 16 conversations and screens at once.

## The iPhone app

A SwiftUI app in `Apps/CanopyiOS`, with its Xcode project checked in, depending on the local package.
Its views live in the Xcode project; everything else, the connection, pairing, and each screen's model, lives in a `CanopyPhone` package target that builds for macOS and iOS, so `make test` covers it on the Mac against a fake Mac that speaks the real protocol.
Bundle ID `com.ne1nn.Canopy.Phone`, iOS 18 and later, iPhone only.
`make ios` builds it for the Simulator, and `make ios-install TEAM=<team id>` signs it with the author's Apple ID and installs it on the plugged-in iPhone with `xcrun devicectl`.
`scripts/ios-shots.sh` walks every screen in the Simulator against a dev build, in light and dark.

Screens, as in the mockups:

- **Pairing**: a camera view that scans the QR code, a Paste link button for `canopy phone pair --json`'s link, `canopy-phone://` links opening the app, and the error when the code expired or the Mac is unreachable.
- **Inbox**: pinned rows, then Needs you, Done, and Running, each item with its dot, name, time, and last line.
  Needs you holds waiting agents, Done holds done agents not yet seen, and Running holds working and background agents.
  Permission prompts show Allow and Deny in the list.
  A swipe pins or unpins a row.
  The first launch pins each repo's own checkout, its `main` row, when an agent runs there.
- **Rows**: every row by repo, with dots and PR numbers, for rows the inbox leaves out.
- **Conversation**: Chat and Terminal, with chips for a question's options and a reply box.
- **Settings**: the paired Mac, Face ID lock, and unpairing.
  Unpairing forgets the token on the phone; the Mac lists the phone until `canopy phone remove`, which Settings names.

Pins live on the phone.
The first launch pins each repo's own checkout, its `main` row, when an agent runs there.

The tab bar has Inbox and Rows, and the inbox's title bar has the Settings button.
The inbox badge counts agents waiting for the author.
Light and dark both follow the system, with Canopy's agent colors: the accent for working, yellow for waiting, green for done, and a green ring for background.

## Notifications

`canopy phone push-key <p8 file> --key-id <id> --team-id <id>` stores the author's push key in the login Keychain.
`PhonePush` in the app signs a JWT with it and posts to Apple's push service over HTTP/2, to the sandbox for builds from Xcode and production for TestFlight, as the phone reports when it registers.

A push goes out when a pane's agent moves to waiting or done.
It is skipped when the Mac's screen is unlocked and it had keyboard or pointer input in the last 2 minutes.
Several changes within 3 seconds go out as one notification per pane.
Working and background never notify.

| Notification | Title | Body | Actions |
|---|---|---|---|
| Permission prompt | `<row> wants to run a command` | What it wants to run | Allow, Deny, Open |
| Question with options | `<row> asks` | The question | Open |
| Waiting | `<row> is waiting` | The last line | Open |
| Done | `<row>` | Done, and the last line | Open |

Allow and Deny require the phone to be unlocked.
Tapping either connects to the Mac in the background and sends `phone.answer`.
If the Mac is unreachable or answers `prompt_gone`, a local notification says so.
Tapping a notification opens its row's conversation.

## Failures

- **The Mac is unreachable** because Tailscale is off, the Mac sleeps, or Canopy is not running: the app shows the last inbox it had, greyed, with "as of" and the time, and a banner naming what to check.
  It reconnects with backoff, 1, 2, 4, 8, 16, then every 30 seconds, and at once when the app comes to the foreground.
  In the background iOS suspends the app, so it closes the connection there and opens it again on the way back.
  An open conversation or terminal follows again on the new connection, keeping what it showed.
- **The connection drops while pairing**, after the Mac saved the phone but before its token arrived: the Mac keeps a phone that can never connect, `canopy phone list` shows it never seen, and `canopy phone remove` clears it.
- **The phone was removed** on the Mac: `phone.hello` fails with `unpaired`, and the app returns to Pairing.
- **The pane closed** while its conversation is open: the conversation says the pane is gone and keeps what it showed.
  An agent that ends also leaves the inbox, so the phone asks the Mac, and only `pane_not_found` means the pane closed.
- **No transcript**, for an agent that is not Claude Code or a remote row: Chat says so and Terminal opens.
- **A reply or answer fails**: it stays in the reply box with the error, so nothing is lost.
- **No push key**: notifications are off, `canopy phone status` says so, and the app's Settings says notifications need setup on the Mac.

## Security

A paired phone can make any agent do anything that agent can do, so the token is the boundary that matters.
Tailscale keeps the listener off every network but the tailnet.
The token keeps other tailnet devices out, `phone remove` revokes a lost phone at once, and the method list keeps a phone from removing rows, repos, or hooks.
Face ID guards the app, and lock-screen actions need an unlocked phone.
The activity log records each phone method that changes something (`phone.reply`, `phone.answer`, `phone.keys`) as `phone.call`, with the phone's name and pane, under a new `phone` source.
A reply's text is logged only while command logging is on, and keys never are.
Pairing and removing a phone record `phone.paired` and `phone.removed`.

## Testing

- Core tests: `TranscriptReader` against recorded transcript files covering prompts, text, folded tool calls, prompts with options, and unparseable lines.
- Core tests: the listener's token check, the method list, the hello timeout, and pairing codes expiring and working once.
- Core tests: the open-prompt guard, the keys each answer sends, and Delivered following `UserPromptSubmit`.
- Core tests: when a push goes out, when it is skipped, coalescing, and the payloads.
- App tests: each screen's model against a fake connection, including unreachable, unpaired, and `prompt_gone`.
- `make e2e`: pairs a test client with a dev build over loopback in place of Tailscale, subscribes, reads a transcript, replies, and answers a prompt from a stand-in agent.
- UI checks in the iOS Simulator, with screenshots in light and dark of every screen.

## Delivery

One PR per milestone:

1. `CanopyWire`, `PhoneListener`, pairing, the method list, `phone.subscribe`, `phone.rows`, and `canopy phone pair|list|remove|status`.
   Testable from the CLI and e2e before any iPhone code.
2. `TranscriptReader`, open prompts, `phone.transcript`, `phone.reply`, `phone.answer`, `phone.screen`, `phone.keys`, and `phone.seen`.
3. The iPhone app: pairing, inbox, rows, conversation, terminal, and settings.
4. Notifications: `phone.push`, `canopy phone push-key`, `PhonePush`, and the lock-screen actions.
5. Mode 2: the New task sheet and `phone.newRow`.

The author asked for milestones 1 to 3 first.
Milestones 4 and 5 wait until the author has a paid Apple Developer account.
Until then the app installs with free signing, which expires after 7 days.

## Owed by the author

- Tailscale on the Mac and the iPhone, signed in to the same tailnet, before milestone 3 can be tried on the phone.
- Full Xcode, before milestone 3.
- A paid Apple Developer account and a push key, before milestone 4.

## Decisions made while building

Milestone 1 (the listener and pairing):

1. `.iOS(.v18)` goes on the whole package, since SwiftPM has no per-target platforms.
2. `CanopyWire` also holds `AgentDot`, `PRState`, and the inbox's sorting, so the Mac's tests cover what the phone shows.
3. A dev build listens only where `CANOPY_PHONE_LISTEN` says, read under `#if DEBUG`, and not at all without it; a release build ignores it and says so in `canopy phone status`.
4. `phone.pair` does not authenticate the connection; the phone says hello with its new token, as on every later connection.
5. Five wrong pairing codes in a row void every outstanding code.
6. The inbox is every row with its agents, sent whole on each change, rather than a list of changes.
7. The first launch pins each repo's own checkout with an agent, since telling a repo's default branch needs git or GitHub.
8. The CLI calls `phones.*` methods on the control socket; the phone's own `phone.*` methods are served only by the listener.
9. Events carry an `event` key and the ID of the request that started them.
10. `canopy phone pair` waits for the phone and says which one paired; `--json` returns at once.
11. The phone's own types read an agent or PR state they do not know as none or open, so a newer Mac cannot spoil an older phone's inbox while both speak protocol 1.

Milestone 2 (reading and answering agents):

12. Following a conversation polls the transcript's size every 300 ms rather than a file-system source, which also notices the pane moving to another session's file.
13. `phone.unsubscribe` is a new phone method, since a phone opens and leaves conversations and screens on one connection.
14. Approving a plan sends Return, the dialog's first option, which Claude Code 2.1.296 labels "Yes, and use auto mode" where auto mode is on offer, as Return does at the Mac.
15. A multiple choice is answered with the toggles, Down to Submit, Return, and `1`, and "Type something" and "Chat about this" are not offered on the phone.
16. Panes whose Claude Code is idle stay in the inbox, with state none, for their conversations.
17. Replies send newlines as Return and leave out escape characters.
18. A reply is refused while a dialog is open, and needs a Claude Code session in the pane.
19. A phone's requests on one connection run one at a time, in order.

Milestone 3 (the iPhone app):

20. The app's models live in a `CanopyPhone` package target, so `make test` and CI cover them without a Simulator; the Xcode project holds only views.
21. The Xcode project syncs its folders, in the Xcode 16 project format, so a new view needs no project edit.
22. Pairing also takes a pasted link and `canopy-phone://` links, since the Simulator has no camera and a link is quicker than a scan when the Mac is far away.
23. Unpairing on the phone forgets its token only; revoking it stays with `canopy phone remove` on the Mac, which the phone cannot call.
24. The app closes its connection in the background and opens it again in the foreground, since iOS suspends it anyway.
25. The lock covers the app whenever it is not in front, so the app switcher never shows an agent; an unpaired app has nothing to lock; a phone with no passcode cannot lock and opens.
26. The greyed compose button of the mockup waits for mode 2, since a button that does nothing reads as broken; the inbox's title bar has Settings instead.
27. A reply is shown at the end of the chat as Sending, Sent, then Delivered until the transcript has the prompt, and one question with one choice answers on tap, while several questions or a multiple choice need Send answers.
