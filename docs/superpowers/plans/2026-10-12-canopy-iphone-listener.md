# Canopy on iPhone, Milestone 1: the Listener and Pairing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A paired phone can reach Canopy over Tailscale, see every row and agent, and follow changes live, before any iPhone code exists.

**Architecture:** A new `CanopyWire` module holds the control protocol, agent states, and the phone's own types, and builds for iOS.
In the app, `PhoneService` owns the paired phones (`PhoneRegistry`), a TCP `PhoneListener` bound to the Mac's Tailscale addresses that lets only paired phones past `phone.hello`, and a `PhoneHub` that sends each subscriber the inbox whenever it changes.
`canopy phone pair|list|remove|status` reach the service through `phones.*` methods on the control socket.

**Tech Stack:** Swift 6, Swift Testing, Network.framework (`NWListener`, `NWPathMonitor`), CryptoKit, Core Image (the QR code), swift-argument-parser, Python 3 for the stand-in phone.

**Spec:** `docs/superpowers/specs/2026-10-12-canopy-iphone-design.md`, updated in this PR: CanopyWire, PhoneListener, Pairing, Phone methods, The iPhone app's pins, Security, and "Decisions made while building".

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings.
- `CanopyWire` has no platform-specific code: Foundation only, for macOS 15 and iOS 18.
- The listener binds only to addresses in `100.64.0.0/10` and `fd7a:115c:a1e0::/48` on `utun` interfaces, port 6974, except a dev build's `CANOPY_PHONE_LISTEN`.
- Tokens: 32 random bytes; only their SHA-256 is stored, compared in constant time; `phones.json` is mode 0600.
- Pairing codes expire after 5 minutes and work once.
- `phone.hello` within 10 seconds or the connection closes.
- After hello, only `phone.subscribe` and `phone.rows` in this milestone.
- `make lint`, `make build` with 0 warnings, `make test` three clean runs on a quiet machine, `make e2e`.
- Markdown: one sentence per line, no em dashes. Conventional commits, no trailers.
- Never quit or kill the release Canopy; kill dev builds by pid only.

## Review Focus

1. A phone that pipelines `phone.hello` and its first request in one write: the request must count as authenticated, not race the hello. Pinned by `aHelloAndARequestSentTogetherBothCount`, and by `aWrongTokenIsUnpairedAndCloses`, where the line after a failed hello is never answered.
2. Tailscale going down while a phone is connected: the listener closes the address's connections, not only the listener. Pinned by `listensOnlyWhileItHasAnAddress`.
3. A subscriber whose inbox went stale between the response and the stream starting must catch up at once. Pinned by `catchesUpASubscriberWhoseInboxIsStale`.
4. A second `phone.subscribe` on one connection must not double every event. Pinned by `aSecondSubscribeReplacesTheFirst`.
5. Guessing pairing codes: five wrong codes void all outstanding codes. Pinned by `fiveWrongCodesVoidEveryCodeOutstanding`.

## Decisions

| Question | Choice | Why |
|---|---|---|
| iOS platform | `.iOS(.v18)` on the package | SwiftPM has no per-target platforms; only `CanopyWire` is built for iOS. |
| Loopback for tests | `CANOPY_PHONE_LISTEN`, read only under `#if DEBUG`; a dev build without it listens nowhere | `make release` builds with `-c release`, which never defines `DEBUG`, so a release build cannot be pointed off the tailnet, and a dev build never competes with the release app for 6974. |
| Override in a release build | Ignored, and `phone status` names it | The author sees why the variable did nothing. |
| Does pairing authenticate | No, the phone says hello next | One way in for every connection. |
| Code guessing | Five wrong codes void every outstanding code | 30^8 codes and 5 minutes already make guessing hopeless; this bounds it outright. |
| Inbox updates | The whole inbox each time, coalesced for 100 ms, plus a 2 s poll | A few kilobytes; a phone that misses one cannot drift; seeing a done agent has no event. |
| Event lines | `{"v", "event", "subscription", "data"}` | Told apart from responses by the `event` key; the subscription is the request ID. |
| CLI methods | `phones.*` on the control socket | The phone's `phone.*` list stays exactly what a phone may call. |
| First-launch pins | Each repo's own checkout with an agent | Telling a default branch needs git or GitHub; the main checkout is where coordinators run. |
| MagicDNS name | `tailscale status --json`, falling back to the address | The QR code also carries the address as `addr`. |
| QR in the terminal | Core Image, half blocks, black on white | Reads right in dark and light terminals; no new dependency. |
| Last line | Left empty until milestone 2's transcripts | Background agents carry their task labels already. |

## File Structure

New:

| File | Responsibility |
|---|---|
| `Sources/CanopyWire/ControlProtocol.swift`, `JSONValue.swift` | moved from `CanopyCore/Control` |
| `Sources/CanopyWire/AgentState.swift` | `AgentState`, `AgentDot`, `PRState`, moved |
| `Sources/CanopyWire/PhoneProtocol.swift` | `PhoneMethod`, `PhonePort`, hello and pair types, `PhoneEvent`, `PhoneMessage` |
| `Sources/CanopyWire/PhoneInbox.swift` | `PhoneAgent`, `PhoneRow`, `PhonePR`, `PhoneInbox` and its sections, `PhoneRowsResult` |
| `Sources/CanopyWire/PairingLink.swift` | the `canopy-phone://pair` URL |
| `Sources/CanopyCore/Exports.swift` | `@_exported import CanopyWire` |
| `Sources/CanopyCore/Control/ControlError+Core.swift` | `ControlError` from `WorkspaceError` and `ControlClientError` |
| `Sources/CanopyCore/Control/LineBuffer.swift` | newline framing shared by the control socket and the listener |
| `Sources/CanopyCore/Control/PhonesMethods.swift` | `phones.*` names and types |
| `Sources/CanopyCore/Phone/PhoneRegistry.swift` | codes, tokens, `phones.json` |
| `Sources/CanopyCore/Phone/PhoneListener.swift` | binding, address following, `TailscaleAddresses`, `PhoneListenAddress` |
| `Sources/CanopyCore/Phone/PhoneConnection.swift` | the hello gate, `PhoneGate`, `PhoneSession`, `PhoneReply` |
| `Sources/CanopyCore/Phone/PhoneInboxBuilder.swift` | the inbox and rows from a snapshot and the terminals |
| `Sources/CanopyCore/Phone/PhoneHub.swift` | subscribers and when to send |
| `Sources/CanopyCore/Phone/PhoneService.swift` | ties it together; `TailscaleStatus` |
| `Sources/CanopyCLI/PhoneCommand.swift`, `QRCode.swift` | the CLI |
| `scripts/phone-client.py`, `scripts/e2e-phone.sh` | the stand-in phone and its e2e |
| Tests | `CanopyWireTests/*`, `PhoneRegistryTests`, `PhoneListenerTests`, `PhoneInboxBuilderTests`, `PhoneHubTests`, `PhoneServiceTests`, `PhonesControlTests`, `CanopyCLITests/PhoneCommandTests`, `Support/PhoneTestClient.swift`, `Support/Shared.swift` |

Modified: `Package.swift`, `ControlServer.swift` (uses `LineBuffer`), `ControlMethods.swift` (read-only list, `phones.paired` timeout), `WorkspaceControlHandler.swift` (`phones:` and the `phones.*` cases), `ActivityEvent.swift` and `ActivityReader.swift` (the `phone` source, `phone.paired`, `phone.removed`), `PaneAgent.swift` and `PullRequest.swift` (moved types), `CanopyCLI.swift`, `Client.swift` (passes `CANOPY_PHONE_LISTEN` to the app it launches), `AppModel.swift`, `Makefile`.

---

### Task 1: CanopyWire

- [x] Move `ControlProtocol.swift` and `JSONValue.swift` to `Sources/CanopyWire` with `git mv`, and `AgentState` out of `PaneAgent.swift`.
- [x] Move the two `ControlError` initializers that name Core types into `ControlError+Core.swift`.
- [x] `Package.swift`: `.target(name: "CanopyWire")`, `CanopyCore` depends on it, a `CanopyWire` library product, `.iOS(.v18)`, and `CanopyWireTests`.
- [x] `Sources/CanopyCore/Exports.swift`: `@_exported import CanopyWire`.

**Tests:** `ControlCodecTests`: a request with a newline in a string is one line and round-trips; agent states keep their raw names.
Every existing test still passes unchanged, which is the real check of the move.

**Commit:** `refactor: CanopyWire holds the control protocol and agent states`

### Task 2: The phone's wire types

**Interfaces (all in `CanopyWire`):**
- `PhoneMethod.hello | pair | subscribe | rows`, `PhonePort.standard = 6974`.
- `PhoneHelloParams { token }`, `PhoneHelloResult { mac, version, phone }`, `PhonePairParams { code, name }`, `PhonePairResult { token, phone, mac }`.
- `PhoneEvent { v, event, subscription, data: JSONValue }` with `PhoneEvent.inbox = "phone.inbox"`; `PhoneMessage.response | .event`, `init(line: Data) throws`.
- `PhoneAgent { pane, state, unseen, since (seconds since 1970), lastLine?, backgroundTasks? }` with `dot`.
- `PhoneRow { path, name, repo?, plugin?, isMain, pr?, agents }` with `lead` (most urgent, then latest) and `dot`.
- `PhoneInbox { rows }` with `sections(pinned: [String]) -> Sections { pinned, needsYou, done, running }`, `waitingCount`, `agentCount`, `defaultPins`.
- `PhoneRowsResult { sections: [Section { name, isPlugin, rows }] }`.
- `PairingLink { host, port, code, address? }`, `init?(url:)`, `url`, `hosts`.
- `AgentDot` and `PRState` move here from `CanopyCore`; `PRState(gitHub:isDraft:)` stays in Core as an extension.

**Tests:** `PairingLinkTests` (round trip, IPv6 host, hosts order, eight malformed links refused), `PhoneMessageTests` (events and responses told apart, `{}` refused), `PhoneInboxTests` (sections sorted newest first, seen done agents left out, pinned rows leave the sections in pin order and a pin for a removed row is dropped, counts, a row's most urgent agent, default pins).

**Commit:** `feat: the phone's wire types: hello, pairing, the inbox, and pairing links`

### Task 3: Pairing codes and paired phones

**Interfaces:** `actor PhoneRegistry(file:now:)` with `newCode() -> PairingCode`, `redeem(code:name:) throws -> (phone: PairedPhone, token: String)`, `authenticate(token:) -> PairedPhone?`, `remove(name:) throws -> PairedPhone`, `connected(_ id:)`, `waitForPairing(code:polling:) async -> PairedPhone?`, `phones`.
`PhoneRegistry.badCode` (`bad_pairing_code`) and `notFound(_:)` (`phone_not_found`).
`PairedPhone { id, name, tokenHash, pushToken?, pairedAt, lastConnected? }`.
A failed save rolls the new phone back and throws, so a phone never holds a token the Mac forgot.

**Tests (`PhoneRegistryTests`, with a `TestClock`):** a code pairs once and the token authenticates, a wrong or empty token does not; codes expire at 5 minutes; codes are read without case, spaces, or dash; five wrong codes void the outstanding code; the file holds the hash, not the token, at mode 0600, and a new registry reads it back; tokens are 32 bytes and differ; taken names get numbers; a blank name becomes `iPhone` and a long one 64 characters; removing revokes; `connected` records the time; `waitForPairing` returns the phone, or nil once the code expires.

**Commit:** `feat: pairing codes and paired phones, kept as token hashes in phones.json`

### Task 4: The listener and the hello gate

**Interfaces:**
- `PhoneListener(port:addresses:gate:)` with `refresh() async throws`, `endpoints: [PhoneEndpoint]`, `connectedPhoneIDs`, `disconnect(phoneID:)`, `stop()`.
- `PhoneGate(registry:macName:helloTimeout:handler:onPaired:)`, `PhoneGate.allowedMethods = [subscribe, rows]`.
- `typealias PhoneHandler = (ControlRequest, PhoneSession) async -> PhoneReply`; `PhoneReply(response, after:)`, whose `after` runs once the response is written; `PhoneSession { phone, send(_:), onClose(_:), isOpen }`.
- `NetworkInterfaceAddress.current()`, `TailscaleAddresses.select(_:)`, `PhoneListenAddress.resolve(environment:allowsOverride:)`.
- `LineBuffer` replaces `ControlConnection`'s own framing, with the same 1 MiB limit.

`PhoneConnection` puts each line through the gate in order (a chain of tasks), then queues its answer on a second chain that every write goes through, so answers and events leave in order and an `after` follows its response.

**Tests (`PhoneListenerTests`, over loopback with `PhoneTestClient`):** pair, hello, and a call; a hello and a request in one write both answered; methods off the list refused while the connection stays; a wrong token answers `unpaired`, closes, and leaves the request after it unanswered; any other first method answers `not_authenticated` and closes; pairing alone does not let a phone in; a bad code closes; silence closes; hello in time stays open; not JSON and a line over 1 MiB close with `bad_request`; removing a phone closes only its connections and runs its close handlers; events follow the response that started them; the listener closes, with its connections, when its address goes and opens again when it comes back.
`TailscaleAddressTests`: only CGNAT and the Tailscale ULA prefix on `utun`; this Mac's `lo0` is read.
`PhoneListenAddressTests`: the default, a dev override in IPv4 and bracketed IPv6, a release build ignoring it, five malformed overrides ignored.

**Commit:** `feat: the phone listener: Tailscale addresses only, hello first, and a fixed method list`

### Task 5: The inbox and its stream

**Interfaces:**
- `PhoneInboxBuilder.inbox(_ snapshot:terminals:) -> PhoneInbox` and `.rows(_:terminals:) -> PhoneRowsResult`, on the main actor: every repo's rows and external rows, then each active plugin's, with each pane whose agent is not none.
- `@MainActor PhoneHub(terminals:snapshot:updates:pollInterval:coalescing:)` with `start()`, `stop()`, `inbox`, `rows`, `subscribe(after:_:) -> UUID`, `unsubscribe(_:)`.

**Tests:** `PhoneInboxBuilderTests` (sidebar order across repo, external, and plugin rows; agents with their state and time; a plugin row named by its item; background task labels; unseen until seen; rows by section with PRs).
`PhoneHubTests` (an agent change sends, nothing changed sends nothing, a stale subscriber catches up, a new row sends, a seen agent goes out on the poll, unsubscribe stops, five changes at once send one inbox).

**Commit:** `feat: the phone's inbox and rows, built from the workspace and sent on each change`

### Task 6: PhoneService and the `phones.*` methods

**Interfaces:**
- `PhoneService(home:hub:activity:listen:macName:tailscaleAddresses:dnsName:)` with `start()`, `stop()`, `refresh()`, `pair() throws -> PhonesPairResult`, `waitForPairing(code:) -> PhoneInfo?`, `list()`, `remove(name:) throws -> PhoneInfo`, `status() -> PhonesStatusResult`.
  Its handler answers `phone.subscribe` (the inbox, then `phone.inbox` events through the hub, one subscription per connection) and `phone.rows`.
- `PhonesMethod.pair | paired | list | remove | status` and their types; `WorkspaceControlHandler(..., phones:)` answers them, or `phones_unavailable` without a service.
- `TailscaleStatus.dnsName()` and `dnsName(fromStatusJSON:)`.
- `ActivitySource.phone`, `ActivityType.phonePaired`, `ActivityType.phoneRemoved`.

**Tests:** `PhoneServiceTests` (pair, subscribe, an event on a pane's change, rows; a second subscribe replaces the first; list and remove, with the log; waiting for a code; status; listening on Tailscale links the MagicDNS name with the address as `addr`; without Tailscale it is closed, says why, refuses to pair, and opens on refresh once an address appears; a release build names the ignored override).
`TailscaleStatusTests` (the name without its final dot; nothing for missing or empty names and bad JSON).
`PhonesControlTests` (the CLI's five methods through the handler; `phones_unavailable`; `phone.rows` is unknown on the control socket).

**Commit:** `feat: PhoneService and the phones.* methods the CLI calls`

### Task 7: `canopy phone`

**Interfaces:** `PhoneCommand` with `pair [--json]`, `list`, `remove <name>`, `status`; `PhoneCommand.table(_:now:)`, `statusText(_:)`, `endpointText(_:)`; `QRCode.matrix(for:)` and `QRCode.text(_:quietZone:colored:)`.

**Tests (`CanopyCLITests/PhoneCommandTests`):** Core Image's QR detector reads the matrix back as the link; half blocks draw two rows per line inside the quiet zone; the colored form is black on bright white; the list table; status text when listening, when closed, and an IPv6 endpoint in brackets.

**Commit:** `feat: canopy phone pair, list, remove, and status, with a QR code in the terminal`

### Task 8: The app and e2e

- [x] `AppModel.startPhones()`: resolves `PhoneListenAddress` with `allowsOverride` true only under `#if DEBUG`, starts a `PhoneHub` on `workspace.updates()` and the service, and hands it to `WorkspaceControlHandler`; `shutdown()` stops both.
  The Mac's name comes from `SCDynamicStoreCopyComputerName`.
- [x] `Client.launch` passes `CANOPY_PHONE_LISTEN` to the app.
- [x] `scripts/phone-client.py` (pair, call, hello, wait-inbox, hold) and `scripts/e2e-phone.sh`, run by `make e2e`: status on loopback, pairing, a used code refused, a wrong token unpaired, four Core methods refused, `phone.rows`, the inbox following `term state` to waiting and to unseen done, removing a phone closing its held connection and revoking its token, and the log naming it.

**Commit:** `feat: the app listens for phones, and make e2e drives it with a stand-in phone`

## Verification

- `make lint`, `make build` (0 warnings), `make test` three times under load below the core count.
- `make e2e`, which runs `scripts/e2e-phone.sh`.
- The iOS build of `CanopyWire` waits for milestone 3's Xcode; until then `swift build` checks it, and it imports only Foundation.

## After Review

An independent opus review of `git diff main...feat/iphone` found nothing critical: no request reaches a phone handler without a valid token.
Fixed:

1. Major: `NWListener` can sit in `.waiting` for a port another app holds, and the first refresh never returned, which kept the control socket from opening because the app started phones first.
   `bind` now treats `.waiting` as a failure, gives up after 5 seconds, and installs one state handler for the listener's whole life; the app opens the control socket first and starts the listener in a task of its own.
   Test: `aTakenPortFailsTheRefreshInsteadOfHanging`.
2. A hello whose token check passed just before `phone remove` could set its phone after the removal's disconnect looked, and stay in.
   The connection now sets its phone first, then asks the registry whether the phone is still paired, closing with `unpaired` when not.
   Test: `aRemovedPhoneIsNotConnected`.
3. A dev build without the override listened on the tailnet port like the release app, and a mistyped override fell back to it.
   `PhoneListenAddress` is now `.tailscale`, `.address`, or `.closed`; dev builds are closed unless the override parses.
   Tests: `PhoneListenAddressTests`, `aDevBuildWithoutAnOverrideSaysHowToOpenIt`.
4. A refresh queued before `stop()` could bind again; the listener now has a `stopped` flag the refresh chain reads.
5. A second `phone.subscribe` left both subscriptions live for a moment; `PhoneHub.subscribe(after:replacing:_:)` swaps them in one main-actor step, and the close action is registered once per connection.
6. No keepalive and an unbounded send queue: TCP keepalive (30 s idle, 3 probes 10 s apart), and events waiting to be written are kept newest only, per event and subscription.
   Test: `theNewestEventAlwaysArrives`.
7. A pairing whose reply never reached the phone leaves a phone that cannot connect: documented under Failures, since `phone remove` clears it and holding the save until the write completes would let a phone hold a token the Mac forgot.
8. `seeingADoneAgentIsSentOnTheNextPoll` passed without the poll; it now waits for the done to go out first, and fails with a 60-second poll.
9. The 300 ms hello timeout in `helloInTimeKeepsTheConnectionOpen` could flake on a loaded runner; it is 2 seconds now.
10. `aWrongTokenIsUnpairedAndCloses` sends both lines in one write, so it exercises the gate's closing check.
11. New tests: `pairingStartsTheHelloTimeAgain`, `helloAgainAnswersAgain`, `anOldProtocolBeforeHelloCloses`, `anOldProtocolAfterHelloIsRefusedAndTheConnectionStays`, `fourWrongCodesVoidNothingAndARightOneStartsTheCountAgain`.
12. Nits: the service lets go of itself in `stop()`; `Data(base64URLEncoded:)` moved to the tests; the listener's close handler is private; `phones.json` is created at 0600 rather than set after; the hub's poll ends with the hub; the phone's types decode states they do not know.
    Left: an unreadable `phones.json` still reads as no phones, which fails closed; Canopy has no log to note it in.
