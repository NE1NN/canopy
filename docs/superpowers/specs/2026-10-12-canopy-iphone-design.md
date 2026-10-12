# Canopy on iPhone design

Date: 2026-10-12
Status: draft for review.
The author approved the design in conversation on 2026-10-12, and this spec writes it down.
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
- The agent states the phone shows: working, waiting, done, background, and none.

and adds the phone's own types: the inbox, transcript entries, prompts, and the `phone.*` method names and parameters.
`CanopyCore` depends on `CanopyWire` and re-exports what it moved, so the CLI and app change only their imports where they must.
`Package.swift` gains `.iOS(.v18)` for this target only.

### PhoneListener

A TCP listener in the app, on port 6974, bound only to the Mac's Tailscale addresses: those in `100.64.0.0/10` and `fd7a:115c:a1e0::/48` on a `utun` interface.
It follows network changes, so it binds when Tailscale comes up and closes when it goes down.
Without Tailscale it stays closed, and `canopy phone status` says why.

Each connection must send `phone.hello` with its device token first.
Any other first message except `phone.pair`, a wrong token, or no message within 10 seconds closes the connection.
After `phone.hello` the connection may call only the methods in "Phone methods".
Requests go to the same handlers the control socket uses, so the phone and the CLI never disagree about state.

### Pairing

`canopy phone pair` makes a one-time pairing code that expires after 5 minutes and prints a QR code in the terminal.
The QR code holds `canopy-phone://pair?host=<MagicDNS name>&port=6974&code=<code>`, with the Tailscale address as a fallback host.
The phone scans it, connects, sends `phone.pair` with the code and its name, and gets back a device token: 32 random bytes.
The phone keeps the token in its Keychain.
The Mac keeps only the token's SHA-256, with the device's name, its push token, and when it last connected, in `CANOPY_HOME/phones.json`, and compares tokens in constant time.

`canopy phone list` shows paired phones.
`canopy phone remove <name>` forgets one and closes its connections at once.

### Phone methods

| Method | What it does |
|---|---|
| `phone.hello` | Authenticates the connection. Returns the Mac's name and Canopy's version. |
| `phone.pair` | Trades a pairing code for a device token. Allowed before `phone.hello`. |
| `phone.subscribe` | Returns the inbox, then streams changes to it: agent states, last lines, and rows coming and going. |
| `phone.rows` | Every row, by repo, with its agent states and PR numbers. |
| `phone.transcript` | One page of a pane's conversation, newest first, with a cursor for older pages. Streams new entries while the conversation is open. |
| `phone.reply` | Pastes text into a pane and presses Return. |
| `phone.answer` | Answers the pane's open prompt: a question's option, Allow, or Deny. |
| `phone.screen` | The pane's screen as text with colors, streamed while the Terminal tab is open. |
| `phone.keys` | Sends keys from the Terminal tab's key bar or keyboard into a pane. |
| `phone.push` | Registers or replaces the phone's push token. |
| `phone.seen` | Marks a done agent as seen, as looking at it on the Mac does. |

Mode 2 adds `phone.newRow`, which takes the same options as `canopy row new` plus a brief to start an agent with.

## Reading and answering agents

### Transcripts

Claude Code's hooks pass `transcript_path` with every event.
`ClaudeHookMapping` records it on the pane's agent next to the session ID, and it changes when the session does.

`TranscriptReader` in `CanopyCore` turns the JSONL file into entries:

- The author's prompts, as text.
- The agent's text.
- Each tool call as one line: "Ran make test", "Read ControlServer.swift and 3 more", "Edited 2 files".
  Consecutive calls of the same kind fold together.
  A failed call says so.
- A question, permission prompt, or plan as a prompt entry with its options.

Tool output, thinking, subagent transcripts, and hook messages are left out.
The reader reads backward from the end of the file for the first page, and follows the file's growth with a file-system source while a phone has the conversation open.
Lines it cannot parse are skipped, so a new Claude Code version degrades to missing entries instead of an error.

### Replies

`phone.reply` sends the text wrapped in bracketed paste markers, then Return as its own write, which is how `term send --enter` already sends Return.
The phone shows Sent when the Mac accepts it, and Delivered when the pane's next `UserPromptSubmit` hook arrives.
A reply to a working agent is allowed, and Claude Code queues it as it does at the Mac.

### Questions and permission prompts

When a pane goes to waiting, the Mac keeps what it is waiting on as the pane's open prompt, with an ID:

- `AskUserQuestion`: its questions and options, from the `PreToolUse` hook's tool input.
- A permission request: the tool and what it wants to run, from the `PermissionRequest` hook.
- `ExitPlanMode`: the plan.
- A question in the agent's last message, found the way `endsOnQuestion` finds it: no options, only a reply.

`phone.answer` takes the prompt's ID and the answer.
If the pane's open prompt has a different ID, or none, it answers `prompt_gone` and sends nothing.
Otherwise it sends the keys the author would press: the option's number for a question, Return for Allow, Escape for Deny.
The prompt closes on the next hook from that pane, whoever answered it.

### Terminal tab

`phone.screen` streams the pane's visible screen and scrollback at the Mac's width.
The phone draws it in a monospaced font, scrolls sideways, and pinch-zooms.
`phone.keys` sends the key bar's esc, tab, ctrl, and arrows, and whatever the author types.

## The iPhone app

A SwiftUI app in `Apps/CanopyiOS`, with its Xcode project checked in, depending on `CanopyWire` through the local package.
Bundle ID `com.ne1nn.Canopy.Phone`, iOS 18 and later.
`make ios` builds it, and `make ios-install` installs it on the plugged-in iPhone with `xcrun devicectl`.

Screens, as in the mockups:

- **Pairing**: a camera view that scans the QR code, and the error when the code expired or the Mac is unreachable.
- **Inbox**: pinned rows, then Needs you, Done, and Running, each item with its dot, name, time, and last line.
  Needs you holds waiting agents, Done holds done agents not yet seen, and Running holds working and background agents.
  Permission prompts show Allow and Deny in the list.
  A swipe pins or unpins a row.
  The first launch pins rows on a repo's default branch that have an agent.
- **Rows**: every row by repo, with dots and PR numbers, for rows the inbox leaves out.
- **Conversation**: Chat and Terminal, with chips for a question's options and a reply box.
- **Settings**: the paired Mac, Face ID lock, and unpairing.

The tab bar has Inbox and Rows.
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
  It reconnects with backoff, and at once when the app comes to the foreground.
- **The phone was removed** on the Mac: `phone.hello` fails with `unpaired`, and the app returns to Pairing.
- **The pane closed** while its conversation is open: the conversation says the pane is gone and keeps what it showed.
- **No transcript**, for an agent that is not Claude Code or a remote row: Chat says so and Terminal opens.
- **A reply or answer fails**: it stays in the reply box with the error, so nothing is lost.
- **No push key**: notifications are off, `canopy phone status` says so, and the app's Settings says notifications need setup on the Mac.

## Security

A paired phone can make any agent do anything that agent can do, so the token is the boundary that matters.
Tailscale keeps the listener off every network but the tailnet.
The token keeps other tailnet devices out, `phone remove` revokes a lost phone at once, and the method list keeps a phone from removing rows, repos, or hooks.
Face ID guards the app, and lock-screen actions need an unlocked phone.
The activity log records each phone method that changes something, with the phone's name, as it records CLI calls.

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
