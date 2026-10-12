# Canopy on iPhone, Milestone 3: The iPhone App

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftUI iPhone app pairs with Canopy on the Mac, shows the inbox and every row, opens an agent's conversation and terminal, answers its prompts and replies to it, and locks with Face ID.

**Architecture:** Everything but the views lives in a new package target, `CanopyPhone`, which builds for macOS and iOS, so `make test` covers each screen's model on the Mac against a fake Mac that speaks the real protocol.
`PhoneClient` matches responses to requests and routes events by subscription over a `PhoneChannel`, which `TCPTransport` opens with Network.framework.
`MacConnection` owns pairing, hello, the inbox subscription, and reconnecting; `InboxModel`, `RowsModel`, `ConversationModel`, `TerminalModel`, `AppLock`, and `SettingsModel` sit on it.
`Apps/CanopyiOS` holds the Xcode project, checked in, with a folder the project syncs, so adding a view needs no project edit, and a UI test target that walks every screen against a dev build.

**Tech Stack:** Swift 6.4, SwiftUI and Observation for iOS 18, Network.framework, Security (Keychain), LocalAuthentication, AVFoundation (QR scanning), Swift Testing, XCTest UI tests, Xcode 27.

**Spec:** `docs/superpowers/specs/2026-10-12-canopy-iphone-design.md`, updated in this PR: The iPhone app, Failures, and decisions 20 to 27.
**Mockups:** direction A in `~/Projects/canopy/build/pages/canopy-iphone/index.html` (outside git), and direction C's Rows and Terminal screens for those two tabs.

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings, in the package and in the Xcode project (`SWIFT_TREAT_WARNINGS_AS_ERRORS`).
- `CanopyWire` imports only Foundation; `CanopyPhone` imports only Foundation, Network, Observation, Security, Synchronization, and LocalAuthentication, so it builds and tests on macOS.
- Bundle ID `com.ne1nn.Canopy.Phone`, iOS 18 and later, iPhone only.
- Free signing keeps working: no push entitlement, no capability that needs a paid account.
  `phone.push` stays reserved for milestone 4.
- The app speaks protocol 1 exactly as the Mac serves it; it reads states, kinds, and fields it does not know the way `CanopyWire` already does.
- Light and dark follow the system, with the mockup's colors: the accent for working, yellow for waiting, green for done, a green ring for background.
- Markdown: one sentence per line, no em dashes.
  Conventional commits, no trailers.

## What the Mac serves

Milestones 1 and 2 built the Mac side; nothing in it changes here.

- Newline-delimited JSON over TCP; `PhoneMessage(line:)` tells responses from events.
- `phone.pair {code, name}` answers `{token, phone, mac}` and does not authenticate; `phone.hello {token}` must follow within 10 s and answers `{mac, version, phone}`.
  Errors: `unpaired`, `bad_pairing_code`, `not_authenticated`.
- `phone.subscribe` answers the `PhoneInbox`, then `phone.inbox` events carry the whole inbox again.
- `phone.rows` answers `PhoneRowsResult`.
- `phone.transcript {pane, before?, limit, follow}` answers `{pane, entries, older}`; following sends `phone.transcript` events with `PhoneTranscriptUpdate {entries, reset, older}`.
  Errors: `no_transcript`, `pane_not_found`.
- `phone.reply {pane, text}` answers `{reply}`, and `phone.delivered` follows with the reply's request ID as its subscription.
  Errors: `prompt_open`, `agent_not_running`.
- `phone.answer {pane, prompt, answer}`; `prompt_gone` when the prompt moved on.
- `phone.screen {pane}` answers a `PhoneScreen` with scrollback, then `phone.screen` events with the visible lines.
  `phone.keys {pane, text}`.
  `phone.seen {pane}`.
  `phone.unsubscribe {subscription}`.
- A connection's requests run one at a time in order, and it may hold 16 conversation and screen streams.

## Review Focus

1. A connection that drops while a conversation or terminal is open must come back by itself, with the conversation's entries kept and nothing shown twice.
   Pinned by `aConversationFollowsAgainAfterTheMacComesBack` and `aTerminalWatchesAgainAfterTheMacComesBack`.
2. An event that arrives before the code waiting for it is ready, as a stream's first event right behind its response, must not be lost.
   Pinned by `eventsRightBehindTheResponseAreKept`.
3. Keys typed fast in the Terminal tab must reach the pane in the order typed, even while an earlier `phone.keys` is still on its way.
   Pinned by `keysGoInTheOrderTyped`.
4. A reply the Mac refuses, or that never reaches it because the connection dropped, must stay in the box with the reason, never vanish.
   Pinned by `aReplyThatFailsStaysInTheBox` and `aReplyCutOffByADropStaysInTheBox`.
5. A Mac that removed the phone must send it back to Pairing once, with its token gone from the Keychain, and never loop reconnecting.
   Pinned by `anUnpairedPhoneGoesBackToPairingAndStopsTrying`.

## File Structure

New:

| File | Responsibility |
|---|---|
| `Sources/CanopyPhone/PhoneChannel.swift` | `PhoneTransport`, `PhoneChannel`, `PhoneTransportError` |
| `Sources/CanopyPhone/TCPTransport.swift` | lines over `NWConnection`, with a connect timeout and keepalive |
| `Sources/CanopyPhone/PhoneClient.swift` | requests, responses, and event streams on one channel |
| `Sources/CanopyPhone/PairedMac.swift` | `PairedMac`, `CredentialStore`, `KeychainCredentialStore`, `MemoryCredentialStore` |
| `Sources/CanopyPhone/MacConnection.swift` | pairing, hello, the inbox, reconnecting, unpaired |
| `Sources/CanopyPhone/PhoneProblem.swift` | errors as the sentences the app shows |
| `Sources/CanopyPhone/RelativeTime.swift` | "now", "4m", "2h", "3d" |
| `Sources/CanopyPhone/PinStore.swift` | pins on the phone, and the first launch's default pins |
| `Sources/CanopyPhone/InboxModel.swift` | the home screen's sections, Allow and Deny, pins |
| `Sources/CanopyPhone/RowsModel.swift` | `phone.rows` with live agents from the inbox |
| `Sources/CanopyPhone/ConversationModel.swift` | Chat: entries, older pages, replies, answers, seen, pane gone |
| `Sources/CanopyPhone/TerminalModel.swift` | the screen stream and keys in order |
| `Sources/CanopyPhone/StyledText.swift` | SGR escapes into styled runs |
| `Sources/CanopyPhone/AppLock.swift` | Face ID after 5 minutes away |
| `Sources/CanopyPhone/SettingsModel.swift` | the paired Mac, the lock, unpairing |
| `Sources/CanopyPhone/PairingModel.swift` | a scanned, pasted, or opened link, traded for a token |
| `Sources/CanopyPhone/PhoneApp.swift` | the models the screens share, and the app coming and going |
| `Sources/CanopyPhone/Observing.swift` | calling back when what a model reads changes |
| `Tests/CanopyPhoneTests/FakeMac.swift` | a `PhoneTransport` whose Mac a test scripts |
| `Tests/CanopyPhoneTests/*Tests.swift` | one file per model, plus the client and the TCP transport |
| `Apps/CanopyiOS/Canopy.xcodeproj` | the app and its UI tests, with a shared scheme |
| `Apps/CanopyiOS/Canopy/*.swift` | the views |
| `Apps/CanopyiOS/CanopyUITests/ScreenTour.swift` | every screen against a dev build, with screenshots |
| `scripts/phone-fixture.sh` | a dev build with agents in every state and a pairing link |
| `scripts/fake-claude.py` | a stand-in Claude Code: Claude Code's transcript format, `canopy agent-hook`, and answers to keys |
| `scripts/ios-install.sh` | the app signed with the author's team, installed with `xcrun devicectl` |
| `scripts/ios-shots.sh`, `scripts/make-app-icon.swift` | the tour in light and dark, and the icon |

Modified: `Package.swift` (the `CanopyPhone` library and its tests), `Makefile` (`ios`, `ios-install`, `ios-shots`, lint and format over `Apps`), `.gitignore` (the checked-in project), `.github/workflows/ci.yml` (`make ios`), the spec.

---

### Task 1: The phone's client

**Interfaces:** `protocol PhoneTransport: Sendable { func connect(host: String, port: UInt16) async throws -> any PhoneChannel }`; `protocol PhoneChannel: Sendable { func send(_ line: Data) async throws; var lines: AsyncThrowingStream<Data, any Error> { get }; func close() }`; `PhoneTransportError.refused | .timedOut | .unreachable(String) | .closed`; `TCPTransport(timeout:)`; `actor PhoneClient(channel:)` with `call(_:_:as:)`, `stream(_:_:as:) -> PhoneStream<R>` (`result`, `subscription`, `events: AsyncStream<PhoneEvent>`), `events(for:)`, `unsubscribe(_:)`, `close()`, `closed` (waits until the channel ends).

**Tests:** a call gets its own response when another's answer comes first; a `ControlError` from the Mac is thrown as it came; an event that comes right behind its stream's response is kept; events go only to their subscription; closing fails waiting calls with `.closed` and ends every stream; a line the client cannot read is skipped; the TCP transport splits lines across reads and joins several in one read, against a loopback listener; a port nothing listens on is `.refused`; a host that never answers is `.timedOut` after the timeout.

**Commit:** `feat: CanopyPhone's client speaks the phone protocol over TCP`

### Task 2: Pairing and staying connected

**Interfaces:** `PairedMac { host, port, address?, token, mac, phone, version }` (`Codable`); `protocol CredentialStore: Sendable { load() -> PairedMac?; save(_:) throws; clear() }`; `@MainActor @Observable MacConnection(transport:credentials:phoneName:sleep:)` with `paired`, `status: .connecting | .connected | .unreachable(PhoneProblem)`, `inbox`, `inboxAsOf`, `pairingNotice`, `start()`, `foreground()`, `background()`, `pair(_ link: PairingLink) async throws`, `unpair()`, `client() async throws -> PhoneClient` (waits for a connection), `generation`; `PhoneProblem { title, detail }` with `init(_ error: any Error, mac:)`.

**Tests:** pairing tries the name, then the address, saves the token, says hello on the same connection, and subscribes; a used code reads "That code expired or was already used"; an unreachable Mac while pairing says what to check; hello with the saved token on start; the inbox and its events update `inbox` and `inboxAsOf`; a drop keeps the last inbox, says unreachable, and retries after 1, 2, 4 s up to 30 s; `foreground()` retries at once; `background()` closes the connection and stops retrying; `unpaired` clears the token, sets the notice, returns to Pairing, and stops trying; `client()` waits for the next connection.

**Commit:** `feat: the phone pairs with the Mac and keeps its connection`

### Task 3: The inbox and the rows

**Interfaces:** `PinStore(defaults:)` with `pins`, `toggle(_ path:)`, `adoptDefaults(_:)`; `RelativeTime.short(since:now:)`; `@MainActor @Observable InboxModel(connection:pins:)` with `sections`, `waitingCount`, `agentCount`, `isStale`, `asOf`, `answer(_ item:, allow:)`, `answering`, `notice`, `togglePin(_ row:)`, `isPinned(_:)`; `@MainActor @Observable RowsModel(connection:)` with `sections`, `refresh()`, `isLoading`, `problem`.

**Tests:** sections follow pins, and a pinned row's agents stay out of the lists; the first inbox with an agent in a main checkout pins it, once; unpinning holds across launches; Allow and Deny send `phone.answer` with the prompt's ID and `allow`; `prompt_gone` says the prompt moved on and the item stays; an answer while unreachable says so; stale while unreachable, with the time of the last inbox; Rows shows each row's live agents from the inbox over `phone.rows`; a row the inbox gains or loses refreshes Rows.

**Commit:** `feat: the inbox and rows models, with pins and answers from the list`

### Task 4: The conversation

**Interfaces:** `@MainActor @Observable ConversationModel(connection:pane:)` with `start()`, `stop()`, `entries`, `older`, `loadOlder()`, `agent`, `row`, `paneGone`, `hasTranscript`, `tab: .chat | .terminal`, `draft`, `pending: PendingReply?` (`text`, `state: .sending | .sent | .delivered`), `replyProblem`, `send()`, `choose(question:option:)`, `selections`, `canSubmitAnswers`, `submitAnswers()`, `allow()`, `deny()`, `answerProblem`, `isAnswering`.

**Tests:** the first page, then follow events that add and grow entries by ID; a reset replaces everything; older pages go in front once; a drop and reconnect follows again and keeps entries without doubles; a reply goes Sent, then Delivered on its event, and the pending bubble goes once the transcript has the prompt; a refused reply (`prompt_open`, `agent_not_running`) keeps the draft with the reason; a reply cut off by a drop keeps the draft; one question with one choice answers on tap; several questions or a multiple choice answer only once each has a choice, with 0-based options; `prompt_gone` clears the choices and says why; Allow and Deny for a permission or plan; opening a done, unseen agent sends `phone.seen`, and so does one finishing while open; the pane leaving the inbox keeps the entries, says it is gone, and stops the stream; no transcript opens Terminal and leaves Chat saying why.

**Commit:** `feat: the conversation model follows, pages, replies, and answers`

### Task 5: The terminal

**Interfaces:** `StyledText.runs(_ line: String) -> [StyledRun]` with `StyledRun { text, style: TerminalStyle }` and `TerminalStyle { foreground, background: TerminalColor?, bold, dim, italic, underline, inverse, crossedOut }`, `TerminalColor.ansi(Int) | .rgb(UInt8, UInt8, UInt8)`; `@MainActor @Observable TerminalModel(connection:pane:)` with `start()`, `stop()`, `columns`, `lines` (scrollback then screen), `ctrl`, `type(_:)`, `backspace()`, `press(_ key: TerminalKey)`, `problem`.

**Tests:** plain text, bold and colored runs, 256 and true colors, resets, a sequence that is not SGR dropped, and a cut-off sequence at the end; the first screen with its scrollback, then screens replacing the visible lines; ctrl turns the next letter into its control character, once; keys go in the order typed while an earlier send waits; esc, tab, arrows, and Return send their sequences; a drop and reconnect watches again.

**Commit:** `feat: the terminal model draws styled screens and sends keys in order`

### Task 6: The lock and settings

**Interfaces:** `protocol Authenticator: Sendable { func authenticate(reason: String) async -> AuthResult; var isAvailable: Bool }`, `AuthResult.success | .failed | .unavailable`; `LocalAuthenticator`; `@MainActor @Observable AppLock(defaults:authenticator:now:)` with `isEnabled`, `isLocked`, `isCovered`, `isGuarding`, `canLock`, `launch()`, `phaseChanged(to: .active | .inactive | .background)`, `unlock()`; `@MainActor @Observable SettingsModel(connection:)` with `mac`, `host`, `address`, `phone`, `version`, `statusText`, `removeHint`, `unpair()`.

**Tests:** locked at launch when on; back within 5 minutes needs nothing, after 5 minutes needs Face ID; covered while away either way, so the app switcher never shows an agent; a failed Face ID stays locked; a phone with no passcode cannot lock and opens; off means never locked; unpairing forgets the token, closes the connection, and returns to Pairing.

**Commit:** `feat: Face ID locks the phone app after 5 minutes away`

### Task 7: The iPhone app

The Xcode project in `Apps/CanopyiOS`, hand-written in the Xcode 16 format with a folder the project syncs (`PBXFileSystemSynchronizedRootGroup`) for `Canopy/` and `CanopyUITests/`, a local package reference to the repo root, and a shared scheme.
The views follow the mockup's sizes: 28 pt bold titles, 12 pt uppercase group labels with counts, rounded 12 pt cards on the grouped background, 8 pt dots with a 2.5 pt halo, pulsing for working and background, the chat's blue bubbles, grey tool lines with a green dot when they passed, yellow question cards, chips, and the 18 pt rounded reply field with a round send button.

- `CanopyApp`, `RootView`: Pairing until paired, then the tab bar (Inbox with the waiting badge, Rows), the lock's cover, `canopy-phone://` links, and scene phases.
- `PairingView`, `QRScanner`: the camera with its square, Paste link, the error, and the notice after being removed.
- `InboxView`: the title with the settings button, the connection line, the unreachable banner, pinned rows, Needs you, Done, Running, Allow and Deny, swipe to pin, and the empty state.
- `RowsView`: repos and plugins, rows indented under their repo, dots and PR chips.
- `ConversationView`, `ChatView`, `PromptBar`, `Composer`: the title with its dot and state, Chat and Terminal, entries, older pages on scroll, chips, Allow and Deny, the reply box with its error.
- `TerminalView`, `KeyBar`, `KeyInput`: the monospaced screen scrolling sideways, pinch to zoom, esc, tab, ctrl, arrows, Return, and the keyboard.
- `SettingsView`: the paired Mac, this phone, Face ID, and Unpair.
- `LockView`, `Theme`, `AgentDotView`, and the icon from `scripts/make-app-icon.swift`.

Two models join the package for the views: `PairingModel(connection:)` with `pair(text:)`, `pair(_ url:)`, `isPairing`, `problem`, `notice`, refusing what is not a pairing link and pairing once while the camera sees the code again and again; and `PhoneApp(transport:credentials:defaults:authenticator:phoneName:)` with `launch()`, `open(_ url:)`, `phaseChanged(to:)`, which closes the connection in the background and locks only while paired.
Tests: a pasted link pairs; text that is not a link says so and connects nowhere; a failed pairing says why; the same code twice pairs once; an unpaired app never locks; the background closes the connection and the foreground opens it.

`make ios` builds it for the Simulator; `make ios-install` builds it signed for a device with `TEAM=<team id>` and installs it with `xcrun devicectl`.
DEBUG builds take `-ScreenTour`, which starts on settings of its own with a stand-in Face ID, for the screen tour; release builds have no such switch.
`make lint` and `make format` cover `Apps`.
CI runs `make ios`.

**Check:** `make ios` with 0 warnings, the app paired by `xcrun simctl openurl booted '<link>'` with a dev build over loopback.

**Commit:** `feat: the Canopy iPhone app: pairing, inbox, rows, conversation, terminal, and settings`

### Task 8: Every screen in the Simulator

`scripts/phone-fixture.sh` opens a dev build listening on loopback with a repo and a ticket row from the stand-in ticket-manager, and runs `scripts/fake-claude.py` in each agent's pane: it writes Claude Code's transcript format and reports through `canopy agent-hook` as Claude Code's hooks do, for a permission prompt, a question with options, done, working, background, and an idle row, and answers a reply, a digit, Return, and Escape as Claude Code would.
`ScreenTour` (XCUITest) opens the link, then walks Pairing, the inbox, Rows, a conversation with chips, an answered question, Terminal with the key bar, a reply, Settings, and the unreachable inbox once the script stops the Mac, saving a screenshot of each.
`scripts/ios-shots.sh` runs the tour in light and dark on a booted iPhone with the status bar at 9:41, carries out its requests to stop the Mac and start one that never paired, and checks on the Mac side, through `canopy log --type phone.call`, that the tour's answer, reply, and Allow each reached its pane.
It runs xcodebuild with `-collect-test-diagnostics never`, since a failure otherwise takes a sysdiagnose of about ten minutes.

**Check:** the shots, compared with the mockups one by one, in light and dark.

**Commit:** `test: a screen tour of the iPhone app against a dev build, in light and dark`

## Verification

- `make lint`, `make build` (0 warnings), `make test` three times under load below the core count.
- `make ios` (0 warnings) and `scripts/ios-shots.sh` passing.
- `make e2e`.

## After Review

An independent opus review of `git diff origin/main...feat/iphone-app` found two critical and two major problems, all fixed with tests:

1. Critical: a phone the Mac removed while a conversation or terminal was open froze.
   Their stream loops asked for a client again at once, which threw without suspending, so the main actor spun and SwiftUI never got to show Pairing.
   `MacConnection.client(after:)` now throws `NotPaired` once the phone has no Mac, and both loops end on it.
   Tests: `aConversationOpenWhenTheMacForgetsThePhoneStops`, `aTerminalOpenWhenTheMacForgetsThePhoneStops`, `waitingForAClientEndsWhenThePhoneIsUnpaired`.
2. Critical: the lock was an overlay on the root view, so the Settings sheet stayed above it, usable, and its switch could turn the lock off.
   The lock and the cover now show in a window of their own above sheets and the keyboard, and turning the lock off asks for Face ID first.
   Tests: `turningTheLockOffAsksForFaceIDFirst`, and the screen tour's lock over Settings, which leaves the app with Settings open, comes back, and checks the switch cannot be reached.
3. A pairing link opened while paired stopped the connection before pairing, left it stopped when pairing failed, and could leave a second reconnect loop running.
   Pairing now keeps the old connection until the new pairing works, and only then replaces it, and a failure while paired shows in the inbox.
   Tests: `aFailedPairingWhilePairedKeepsTheConnection`, `pairingAgainReplacesTheConnectionWithOneLoopOnly`, `aFailedLinkWhilePairedKeepsTheConnectionAndSaysWhy`.
4. A conversation or screen left before its first answer kept streaming on the Mac, so after 16 of them every conversation opened empty.
   `PhoneClient` now unsubscribes a stream whose caller gave up, once the Mac answers, and a conversation that cannot be followed says why instead of "Nothing said yet."
   Tests: `aStreamCancelledBeforeItsResponseIsUnsubscribedOnceItStarts`, `aCancelledStreamTheMacRefusedNeedsNoUnsubscribe`, `aConversationThatCannotOpenSaysWhy`.
5. A code that failed was tried again with every camera frame, which could void every outstanding code after five.
   The camera now waits for a new code; a paste or a link always tries.
   Tests: `aCodeThatFailedIsNotTriedAgainEachTimeTheCameraSeesIt`, `aPastedCodeIsTriedAgainEvenAfterItFailed`.
6. A failed older page left a spinner at the top of Chat for good; it now offers to try again.
   Test: `aFailedOlderPageCanBeTriedAgain`.
7. An older page asked for before a reset could join the new session; it is now dropped.
   Test: `anOlderPageFromBeforeAResetIsDropped`.
8. The terminal streamed while Chat showed, holding a second stream and up to four screens a second; it now streams only on its tab.
9. Leaving a conversation and coming back added another set of observers each time; each start now ends the last one's.
   Test: `startingAgainDoesNotDoubleTheChecks`.
10. Nits: the tour's assertions say what failed instead of drifting line numbers, and the plan has one sentence per line.

The tours in light and dark then turned up one more problem, in the fixture: `phone-fixture.sh stop` deleted the folder while the dev build was still quitting, which wrote its home back, so the next `stop` refused the folder and the next start failed.
It now waits for the app to quit, and knows its folder by name and home.

CodeRabbit then found six smaller problems, all fixed:

1. A page that starts where the phone's own does no longer counts as a new conversation, so it keeps the older cursor and an older page on its way.
   Test: `aNewPageThatStartsWhereThePhonesDoesKeepsItsOlderCursorAndPages`.
2. A pairing the Keychain cannot keep says so, rather than trying the used code on the next host and reading as expired.
   Test: `aPairingTheKeychainCannotKeepSaysSoAndTriesNoOtherHost`.
3. A loop that pairing again replaced cannot forget the new pairing when it hears its old token refused.
4. The Keychain store replaces the pairing in place, so a save that fails leaves the one before it.
5. Only the latest Rows refresh's answer lands.
6. The stand-in Claude takes a repeated digit or Return once.

The tours also showed the tour ending while the Mac that never paired was still setting up, so `ios-shots.sh` now waits for the tour's requests to finish before it stops the fixture.

Left as is: `ConversationView`'s initializer builds its two models again each time SwiftUI rebuilds the destination, which `@State` then drops.
They are two small objects with no work in their initializers, so holding them elsewhere would add a layer for nothing measurable.
`SettingsView` builds its `SettingsModel` in `body`, which holds no state of its own.
