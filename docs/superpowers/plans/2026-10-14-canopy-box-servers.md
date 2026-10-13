# Canopy on the box, Milestone 5: several servers in the iPhone app

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the iPhone app pairs with several servers, the Mac and `canopy-box`, keeps a connection to each, and shows them as one app: one Inbox across servers, Rows grouped by host, and Settings listing each server.

**Architecture:** `PairedMac` becomes `PairedServer`, each its own Keychain item, and `MacConnection` becomes `ServerConnection`, one per server, with pairing moved to a new `Servers` list that owns the connections in pairing order.
The models take `Servers`: the Inbox merges every server's sections, Rows keeps one `ServerRows` per server, and conversations and terminals take the pane's own `ServerConnection`.
Servers say their kind in `phone.hello`, `phone.pair`, and the pairing link, and the Mac marks its remote rows with their host, so the phone hides the Mac's copy of a box row when it is paired with that box.

**Tech Stack:** Swift 6.4, Swift Testing, SwiftUI on iOS 18, XCUITest, `FakeMac`.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "Servers", "Pairing with the box", "Inbox", "Rows", "Conversations", "Settings", the Failures row for a removed token, and Delivery item 5.

## Global Constraints

- The protocol stays version 1; phones and servers ignore fields they do not know, so every new wire field is optional.
- Kinds are `mac` and `box`; a server that does not say is a Mac.
- The phone already paired with the author's Mac keeps that pairing through the update: the old Keychain item (account `mac`) is read and moved, never dropped.
- Nothing runs against hindie-box or its tailnet.
- Swift 6 language mode, strict concurrency, no warnings; markdown one sentence per line, no em dashes; conventional commits, no trailers.

## Rulings

- A server's identity on the phone is a UUID made at pairing.
  Pairing again with a server whose host or Tailscale address matches one already paired replaces it in place, keeping its spot in the order.
- The pairing order is the order of `pairedAt`, saved with each server, since Keychain items have no order.
- A server whose token was removed shows as unpaired in Settings and drops out of the Inbox and Rows; its credentials stay until Remove, so it still shows after a relaunch.
  The app goes back to Pairing only when no server is left that is paired.
- The Mac lists box rows as remote rows, so a phone paired with both would see them twice.
  The Mac sends each remote row's host alias as `PhoneRow.host`; the phone drops the Mac's rows whose host is the name of a box it is paired with, whether or not that box is reachable now.
  A box's name is its alias on the Mac (`BoxConfig.host`), so the two match.
- Pane ids are only unique on their server, so the phone keys panes by `PaneRef(server:pane:)` everywhere.

## Review Focus

1. A phone paired with one Mac before this update opens paired, with the same token, after it.
   Pinned by `aPairingFromBeforeSeveralServersIsKept` in Task 2.
2. Two servers that both have a pane `p3` must never mix: reading, answering, and marking read go to the item's own server.
   Pinned by `samePaneOnTwoServersStaysApart` in Task 3.
3. One server out of reach must not hide or grey another's rows, and a stale server's items keep showing as of when it was last reached.
   Pinned by `oneServerOutOfReachLeavesTheOthers` in Task 3.
4. A token removed on one server sends the phone back to Pairing only when it was the last paired server.
   Pinned by `anUnpairedServerKeepsTheOthers` in Task 2.
5. Scanning a second server's code while paired adds it rather than replacing the first, and scanning the same server's code again replaces it.
   Pinned by `pairingAnotherServerAddsIt` and `pairingTheSameServerAgainReplacesIt` in Task 2.

---

### Task 1: Servers say their kind, and the Mac's remote rows say their host

**Files:**
- Modify: `Sources/CanopyWire/PhoneProtocol.swift` (`PhoneHelloResult`, `PhonePairResult`), `Sources/CanopyWire/PairingLink.swift`, `Sources/CanopyWire/PhoneInbox.swift` (`PhoneRow.host`)
- Modify: `Sources/CanopyServer/PhoneSource.swift` (`PhoneServerSettings.kind`), `Sources/CanopyServer/PhoneConnection.swift` (`PhoneGate`, `greeting`, the pair result), `Sources/CanopyServer/PhoneServer.swift` (`pair()` puts `kind` in the link)
- Modify: `Sources/CanopyBoxKit/BoxMain.swift` (kind `box`), `Sources/CanopyCore/Phone/PhoneInboxBuilder.swift` (a remote row's host)
- Modify: `scripts/phone-client.py` and `scripts/e2e-hosts.sh` (the box's hello says `box`)
- Test: `Tests/CanopyWireTests`, `Tests/CanopyServerTests/PhoneListenerTests.swift`, `Tests/CanopyServerTests/PhoneServerTests.swift`, `Tests/CanopyCoreTests/PhoneInboxBuilderTests.swift`, `Tests/CanopyBoxTests/BoxPhoneSourceTests.swift`

**Interfaces:**
- Produces: `PhoneServerKind` with `static let mac = "mac"`, `static let box = "box"`; `PhoneHelloResult.kind: String?`; `PhonePairResult.kind: String?`; `PairingLink.kind: String?` (query item `kind`); `PhoneRow.host: String?`; `PhoneServerSettings.kind: String` (default `mac`).

- [ ] Tests: `aLinkCarriesItsKind` and `aLinkWithoutAKindIsAMacs` (round trip and an old link), `anOldHelloWithoutAKindDecodes`, `theBoxSaysItIsABox` (hello and pair result from a server with kind `box`), `aRemoteRowSaysItsHost` (the builder sets `host` for a remote row and leaves it nil for a local one).
- [ ] Implement; the e2e's phone step checks that the box's hello says `box`.
- [ ] Commit `feat: servers tell phones their kind, and the Mac's remote rows their host`.

### Task 2: PairedServer, ServerConnection, and Servers

**Files:**
- Create: `Sources/CanopyPhone/PairedServer.swift` (from `PairedMac.swift`), `Sources/CanopyPhone/ServerConnection.swift` (from `MacConnection.swift`), `Sources/CanopyPhone/Servers.swift`
- Modify: `Sources/CanopyPhone/PairingModel.swift`, `Sources/CanopyPhone/PhoneProblem.swift`
- Test: `Tests/CanopyPhoneTests/ServerConnectionTests.swift` (from `MacConnectionTests.swift`), `Tests/CanopyPhoneTests/ServersTests.swift`, `Tests/CanopyPhoneTests/CredentialStoreTests.swift`, `Tests/CanopyPhoneTests/FakeMac.swift`

**Interfaces:**
- Produces:
  - `PairedServer { id: String, kind: String, name: String, host, port, address?, token, phone, version?, pairedAt: Date }`, decoding the old `PairedMac` JSON (`mac` for the name, no id, kind, or date).
  - `CredentialStore { loadAll() -> [PairedServer]; save(_: PairedServer) throws; remove(id: String) }`, sorted by `pairedAt`.
    `KeychainCredentialStore` keeps account `server.<id>` per server and moves the legacy `mac` item on first load.
  - `ServerConnection(server: PairedServer, transport:, credentials:, phoneName:, opened: PhoneClient? = nil, ...)` with `id`, `server`, `name`, `kind`, `status` (adds `.unpaired(String)`), `inbox`, `inboxAsOf`, `generation`, `start()`, `foreground()`, `background()`, `stop()`, `liveClient()`, `client(after:)`, `problem(_:)`.
  - `Servers(transport:, credentials:, phoneName:, ...)` with `connections: [ServerConnection]` in pairing order, `paired: [ServerConnection]` (not unpaired), `connection(id:)`, `pair(_ link: PairingLink) async throws -> ServerConnection`, `remove(id:)`, `start()`, `foreground()`, `background()`, `pairingNotice`.
  - `FakeMac(name:host:address:kind:)` instances, and `FakeNetwork` routing each host to its fake.

- [ ] Rename the tests and fake first, keeping every `MacConnectionTests` case as a `ServerConnectionTests` or `ServersTests` case.
- [ ] Tests: `aPairingFromBeforeSeveralServersIsKept`, `serversComeBackInPairingOrder`, `pairingAnotherServerAddsIt`, `pairingTheSameServerAgainReplacesIt`, `anUnpairedServerKeepsTheOthers`, `removingAServerForgetsOnlyIt`, `eachServerBacksOffOnItsOwn`, `helloUpdatesTheKindAndName`.
- [ ] Implement; commit `feat: the phone pairs with several servers`.

### Task 3: The models across servers

**Files:**
- Modify: `Sources/CanopyPhone/InboxModel.swift`, `Sources/CanopyPhone/RowsModel.swift` (split into `ServerRows` per server and `RowsModel` over them), `Sources/CanopyPhone/ConversationModel.swift`, `Sources/CanopyPhone/TerminalModel.swift`, `Sources/CanopyPhone/SettingsModel.swift`, `Sources/CanopyPhone/PhoneApp.swift`
- Test: `Tests/CanopyPhoneTests/InboxModelTests.swift`, `RowsModelTests.swift`, `ConversationModelTests.swift`, `TerminalModelTests.swift`, `AppLockTests.swift` (settings), `PhoneAppTests.swift`, `Connected.swift`

**Interfaces:**
- Consumes: Task 2's `Servers` and `ServerConnection`, Task 1's `PhoneRow.host`.
- Produces:
  - `PaneRef { server: String, pane: String }`, Hashable.
  - `InboxModel(servers:)`: `sections: Sections { needsYou: [Item], done: [Item] }` where `Item { server: ServerConnection, row: PhoneRow, agent: PhoneAgent, ref: PaneRef }`; needs-you oldest first and done newest first across servers, ties in pairing order; `answer`, `markRead`, `markAllRead` per item's server; `isStale(server)`, `staleServers`.
  - `RowsModel(servers:)`: `hosts: [Host { server: ServerConnection, sections: [PhoneRowsResult.Section], problem: PhoneProblem? }]` in pairing order, the Mac's rows of a paired box left out.
  - `ConversationModel(connection: ServerConnection, pane:)`, `TerminalModel(connection: ServerConnection, pane:)` unchanged otherwise.
  - `SettingsModel(servers:)`: `servers: [ServerSettings]` with name, kind, host, address, version, phone, status text, remove hint, and `remove(id:)`.
  - `PhoneApp.servers` in place of `PhoneApp.connection`; the lock guards once any server is paired.

- [ ] Tests: `samePaneOnTwoServersStaysApart`, `theInboxMergesServersByTime`, `oneServerOutOfReachLeavesTheOthers`, `theMacsCopyOfABoxRowIsLeftOut`, `rowsGroupByServerInPairingOrder`, `aServerAddedLaterGetsItsRows`, `settingsListEachServer`, and every existing model test against one server.
- [ ] Implement; commit `feat: one inbox and rows by host across the phone's servers`.

### Task 4: The app's screens

**Files:**
- Modify: `Apps/CanopyiOS/Canopy/RootView.swift`, `InboxView.swift`, `RowsView.swift`, `ConversationView.swift`, `SettingsView.swift`, `PairingView.swift`, `CanopyApp.swift` (the tour's store holds a list)
- Modify: `Apps/CanopyiOS/CanopyUITests/ScreenTour.swift`, `scripts/phone-fixture.sh` (a second server), `scripts/ios-shots.sh`

- [ ] Inbox: the connection line names a server only when one is out of reach ("Can't reach hindie-box", or "As of 10:42" when all are), and items open their own server's conversation.
- [ ] Rows: one header per server in pairing order, with its kind's symbol (laptop or server rack) and status; an unreachable server's rows grey alone.
- [ ] Conversation: the title's second line names the row's host when the phone has more than one server.
- [ ] Settings: a Servers section listing each with its status, a detail with name, kind, address, Tailscale IP, version, "Paired as", and Remove; Pair another server opens the scanner in a sheet; the footnote says to run `canopy phone pair --on <host>` on the Mac.
- [ ] The fixture starts a second server: `canopy-box serve` for macOS on its own throwaway home, with one repo and one waiting fake agent, its phone listener on loopback by `box/phone-listen`.
  The tour pairs with the Mac, then the box from Settings, and checks the merged Inbox, both hosts in Rows, and a box conversation.
- [ ] `scripts/ios-shots.sh` in light and dark; check every shot.
- [ ] Commit `feat: the iPhone app shows every server it is paired with`.

### Checks

- `make lint`, `make build`, `make test` three times, `make linux`, `make ios`, `scripts/ios-shots.sh`, `make e2e`, an opus review with After Review, CI.
