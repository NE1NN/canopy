# Canopy on the box, Milestone 6: waking the box from the phone

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a box that has powered itself off is one tap away: the phone signs `ec2:StartInstances` with a key that can only start that instance, then connects once Canopy on the box answers.

**Architecture:** `canopy host wake-key <host>` keeps an access key in the Mac's login Keychain, and every `box.configure` carries it to `canopy-box`, which keeps it in `wake.json` with the instance id and region it reads from the instance metadata service.
`phone.hello` from a box answers with the wake key, which the phone keeps with that server.
The phone's `Waker` signs `StartInstances` with AWS Signature Version 4 using CryptoKit, posts it to the region's EC2 endpoint, and then asks the box's connection to retry until it answers; the Inbox shows a card for a box out of reach with a wake key, and Settings has Wake now.

**Tech Stack:** Swift 6.4, Swift Testing, CryptoKit, URLSession on the phone, POSIX TCP on the box, XCUITest.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "Waking the box", the `wake.json` and `box.configure` rows of "canopy-box", "Settings", "Failures", "Security", and Delivery item 6.

## Global Constraints

- Nothing runs against AWS or hindie-box: the IAM user and its key stay the author's step, so tests use a fake instance metadata service and a fake EC2 endpoint on loopback.
- The phone wakes the box only on a tap, never on launch.
- The secret never reaches a log: not the Mac's activity log, not the box's, not `--json` output.
- Every new wire field is optional; the protocol stays version 1.
- Swift 6 language mode, strict concurrency, no warnings; markdown one sentence per line, no em dashes; conventional commits, no trailers.

## Rulings

- The Mac's Keychain is where the key lives; `box.configure` carries it on every link connect, so the box's `wake.json` follows the Mac, and `canopy host wake-key <host> --clear` removes it from both.
  `host wake-key` needs an upgraded host, since only `canopy-box` hands keys to phones.
- `canopy-box` reads the instance id and region with IMDSv2 over plain HTTP to `169.254.169.254`, once at start and again when a hello finds them missing; tests point it at loopback with `box/imds`, `<address> <port>`, loopback only, as `box/phone-listen` does.
  Without an instance id the box sends no wake key, since the phone could not use it.
- The phone repeats `StartInstances` every 10 seconds while EC2 answers `IncorrectInstanceState`, for at most 2 minutes, then asks the box's connection to retry every 10 seconds for at most 5 minutes.
- A failure names its step: AWS refused the key (`AuthFailure`, `UnauthorizedOperation`, `InvalidClientTokenId`, `SignatureDoesNotMatch`, or HTTP 401 or 403), the instance did not start (anything else, or `IncorrectInstanceState` past 2 minutes), or it started and Canopy did not answer.
- The phone's EC2 endpoint is `https://ec2.<region>.amazonaws.com/`; only the screen tour's debug build may point it elsewhere, by launch environment.

## Review Focus

1. A key change on the Mac reaches the phone on its next connect, and a cleared key stops the Wake card.
   Pinned by `helloCarriesTheWakeKeyAndItsClearing` in Task 3.
2. A tap while a wake is under way starts no second one.
   Pinned by `aSecondTapWhileWakingDoesNothing` in Task 3.
3. The secret is in no log.
   Pinned by `theWakeKeyIsNotLogged` in Task 1.
4. A box whose instance metadata service does not answer still serves phones, without a wake key.
   Pinned by `withoutInstanceMetadataThereIsNoWakeKey` in Task 2.
5. The signature matches AWS's own: the published `get-vanilla` example, and a `StartInstances` request checked against an independent implementation.
   Pinned by `signsAWSsExample` and `signsStartInstances` in Task 3.

---

### Task 1: The Mac keeps the key and hands it to the box

**Files:**
- Modify: `Sources/CanopyAgents/BoxProtocol.swift` (`BoxConfig.wake: BoxWakeKey?`), `Sources/CanopyCore/Control/HostMethods.swift` (`HostMethod.wakeKey`, `HostWakeKeyParams`), `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, `Sources/CanopyCore/Workspace/Workspace+Box.swift`, `Sources/CanopyCore/Hosts/BoxLink.swift` (`reconfigure()`), `Sources/CanopyCLI/HostCommand.swift` (`WakeKey`), `Sources/CanopyCLI/SecretPrompt.swift`
- Test: `Tests/CanopyCoreTests/HostWakeKeyTests.swift`, `Tests/CanopyCLITests`

- [ ] Tests: `aWakeKeyIsKeptInTheKeychainAndSentToTheBox`, `clearingTheKeyRemovesItFromBoth`, `aHostNotUpgradedRefusesAWakeKey`, `theWakeKeyIsNotLogged`.
- [ ] Commit `feat: canopy host wake-key keeps a key to start the box and hands it to canopy-box`.

### Task 2: The box learns its instance and tells phones the key

**Files:**
- Create: `Sources/CanopyBoxKit/InstanceMetadata.swift`
- Modify: `Sources/CanopyBoxKit/BoxDaemon.swift` (`wake.json`), `Sources/CanopyBoxKit/BoxMain.swift`, `Sources/CanopyWire/PhoneProtocol.swift` (`PhoneWake`, `PhoneHelloResult.wake`), `Sources/CanopyServer/PhoneSource.swift`, `Sources/CanopyServer/PhoneConnection.swift`
- Test: `Tests/CanopyBoxTests/InstanceMetadataTests.swift`, `Tests/CanopyBoxTests/BoxPhoneSourceTests.swift`

- [ ] Tests: `readsTheInstanceAndRegionWithAToken` (a fake IMDSv2 on loopback), `withoutInstanceMetadataThereIsNoWakeKey`, `theWakeKeyLivesInWakeJsonNotConfigJson`, `aBoxsHelloCarriesItsWakeKey`.
- [ ] Commit `feat: canopy-box reads its instance and hands phones the wake key`.

### Task 3: The phone wakes the box

**Files:**
- Create: `Sources/CanopyPhone/SigV4.swift`, `Sources/CanopyPhone/Waker.swift`
- Modify: `Sources/CanopyPhone/PairedServer.swift` (`wake`), `Sources/CanopyPhone/ServerConnection.swift`, `Sources/CanopyPhone/PhoneApp.swift`, `Sources/CanopyPhone/SettingsModel.swift`
- Test: `Tests/CanopyPhoneTests/SigV4Tests.swift`, `Tests/CanopyPhoneTests/WakerTests.swift`

- [ ] Tests: `signsAWSsExample`, `signsStartInstances`, `helloCarriesTheWakeKeyAndItsClearing`, `aTapStartsTheInstanceAndConnectsOnceItAnswers`, `aStoppingInstanceIsAskedAgain`, `aRefusedKeySaysSo`, `anInstanceThatNeverStartsSaysSo`, `aStartedBoxThatNeverAnswersSaysSo`, `aSecondTapWhileWakingDoesNothing`.
- [ ] Commit `feat: the phone wakes a box with its start-only key`.

### Task 4: The waking card, Settings, the e2e, and the tour

**Files:**
- Modify: `Apps/CanopyiOS/Canopy/InboxView.swift`, `SettingsView.swift`, `CanopyApp.swift`; `Apps/CanopyiOS/CanopyUITests/ScreenTour.swift`; `scripts/phone-fixture.sh`, `scripts/ios-shots.sh`, `scripts/e2e-hosts.sh`, `scripts/phone-client.py`
- Create: `scripts/fake-aws.py` (a fake IMDSv2 and EC2 `StartInstances` on loopback)

- [ ] Inbox: a card per box out of reach with a wake key, "devbox is off" with Wake, then "Waking devbox" with how long ago it started, then the failed step with Wake again.
- [ ] Settings: a box's detail says whether a wake key is set and for which instance, with Wake now.
- [ ] The e2e sets a key on the fake host and checks the phone's hello carries it with the fake instance.
- [ ] The tour stops the fixture's box, wakes it from the card through the fake EC2, which starts the box's daemon again, and sees it connect.
- [ ] Commit `feat: the Inbox wakes a box that is off`.

### Checks

- `make lint`, `make build`, `make test` three times, `make linux`, `make ios`, `scripts/ios-shots.sh`, `make e2e`, an opus review with After Review, CI.
