# Canopy on the box, Milestone 4: the phone server on the box

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `canopy-box` serves phones directly over the tailnet, with the same `phone.*` methods the Mac serves, so the phone reads and answers box agents with the Mac off; `canopy phone pair|list|remove --on <host>` manage the box's phones from the Mac; a connected phone keeps the box on.

**Architecture:** `BoxPhoneSource` implements `PhoneSource` over `BoxDaemon`: the inbox and rows from its snapshot, transcripts from each pane's transcript path, replies as a bracketed paste then Return, answers and keys through `PhoneAnswerKeys` and tmux, and screens from `tmux capture-pane -e`.
`canopy-box serve` starts a `PhoneServer` on it, listening on the box's tailnet addresses, which `TailnetAddresses` reads with `getifaddrs` every 5 seconds, on `config.json`'s port or the standard one.
The daemon answers `box.phones.pair`, `box.phones.paired`, `box.phones.list`, `box.phones.remove`, and `box.phones.status`, which the Mac's CLI reaches through the link with `--on`.

**Tech Stack:** Swift 6.4, Swift Testing, `PhoneTestClient`, tmux.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "Pairing with the box", "Conversations", "Tailscale", "Idle power-off", "Security", and Delivery item 4.

## Global Constraints

- Nothing runs against hindie-box or its tailnet: tests and the e2e put the listener on loopback with the file `box/phone-listen`, which only tests write and which takes loopback only.
- The phone protocol stays version 1; the box's `phone.hello` adds `kind: box`, which older phones ignore.
- A box pane's `kind` is `terminal`, or left out.
- Swift 6 language mode, strict concurrency, no warnings; markdown one sentence per line, no em dashes; conventional commits, no trailers.

## Rulings carried from the spec

- `TailnetAddresses` keeps the Mac's rule: `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, on `tailscale0` on Linux; the tailnet name comes from `tailscale status --json`'s `Self.DNSName`, or the address when Tailscale's CLI does not answer.
- The daemon's activity log is a JSONL file under `box/activity/` with `phone.call`, `phone.paired`, and `phone.removed`, the Mac's types and fields.

## Review Focus

1. A reply must never be pasted into a pane whose agent opened a dialog meanwhile.
   Pinned by `aReplyWaitsOutADialog` in Task 1.
2. An answer to a prompt the Mac or another phone already answered must fail with `prompt_gone`.
   Pinned by `aSecondAnswerIsPromptGone` in Task 1.
3. A phone connected with no agent working keeps the box on; one that drops stops counting within a tick.
   Pinned by `aConnectedPhoneKeepsTheBoxOn` in Task 3.

---

### Task 1: BoxPhoneSource

- [ ] Tests in `CanopyBoxTests/BoxPhoneSourceTests.swift` against `BoxTestHome`: `theInboxListsWaitingAndDoneAgents`, `rowsGroupTheBoxsRowsByRepoWithTheMainFirst`, `aTranscriptIsThePanesFile`, `aReplyGoesInAsAPasteThenReturn`, `aReplyWaitsOutADialog`, `anAnswerTypesItsKeys`, `aSecondAnswerIsPromptGone`, `seenClearsTheGreen`, `theScreenHasColours`.
- [ ] Implement; commit `feat: canopy-box is a phone source`.

### Task 2: Tailnet addresses and the listener

- [ ] Tests: `onlyTailnetAddressesOnTailscale0Count` (a pure function over fake interface lists), `theNameComesFromTailscaleStatus` (a stand-in `tailscale`), `withoutTailscaleThereIsNoListenerAndStatusSaysWhy`.
- [ ] `BoxMain.serve` starts a `PhoneServer` with `BoxPhoneSource`, `box/phones.json`, the host's name from `config.json`, the port from `config.json` or 6974, and `box/phone-listen` in place of the tailnet for tests.
- [ ] Commit `feat: canopy-box listens for phones on the tailnet`.

### Task 3: Pairing from the Mac, and phones keeping the box on

- [ ] `box.phones.pair`, `box.phones.paired`, `box.phones.list`, `box.phones.remove`, `box.phones.status` on the daemon; `canopy phone pair|list|remove --on <host>` through the link.
- [ ] Tests: `pairingThroughTheLinkGivesALinkForTheBox`, `aPhonePairedWithTheBoxReadsItsInbox` (a `PhoneTestClient` over loopback), `aConnectedPhoneKeepsTheBoxOn`, `removingAPhoneEndsItsConnection`.
- [ ] Commit `feat: phones pair with canopy-box from the Mac and keep the box on`.

### Task 4: The e2e

- [ ] `scripts/e2e-hosts.sh`: after the upgrade, `phone pair --on fake-box` with `127.0.0.1` in `box/phone-listen`, a phone client pairs, reads the inbox with the box pane's waiting agent, replies, and the reply reaches the pane; `phone remove --on` drops it.
- [ ] Commit `test: the hosts e2e pairs a phone with canopy-box`.

## Verification

- `make lint`, `make build`, `make test` three times, `make linux`, `make box`, `make e2e`, an opus review with After Review, CI.

## After Review

An opus review found no critical issues and seven important ones:

- A reply checked for a dialog 200 ms before pressing Return; the check and Return now go together (`aReplyWaitsOutADialog`).
- `phone pair --on` gave up after the link's two-minute call wait while the code lasts five; pairing now waits as long as the code.
- The phone's screen dropped blank rows, pulling scrollback into it; it now has exactly the screen's rows (`aMostlyEmptyScreenKeepsItsRows`).
- The test override could put the listener on any address in any build; it now takes loopback only, and status says when it is on (`anOverrideWinsForTests` checks the filter).
- The box's inbox listed plain shells and the screen's footer as the last line; it now skips panes with no agent and words prompts and background work as the Mac does (`aPlainShellIsNoAgentInTheInbox`).
- Ruling: `kind=box` in the pairing link and `phone.hello` waits for milestone 5, where the phone first tells servers apart; older phones ignore it either way.
- Tests the plan named but did not write (delivery, a stand-in `tailscale`, a phone over loopback in unit tests, a dropping phone) are covered by the hosts e2e or deferred; the e2e pairs, reads, replies, and removes a phone.

Before merging, `HostMonitorRoundTests.aStuckPortsProbeHoldsUpNoOtherHost` failed in two of three full runs.
`make test`'s strict pool has one Swift concurrency thread, and samples of a full run showed it busy 94% of the time, over half of that in tests waiting for subprocesses and in `TempDir` deleting its folder.
Each actor hop then waited up to a second, and milestone 3b's hop onto each connection to read its box flag pushed the test's rounds past its 20-second waits.
Tests now run subprocesses through `Subprocess.runOffPool`, `TempDir` deletes on a queue of its own, and `HostConnection.isBox` is read without a hop; the test's first wait went from over 20 seconds to about 10.
`aPortNobodyHoldsIsFree`, which failed once along the way when another test's socket took the port it had just let go, tries a few ports.
Left for later: `StateStore.save`'s fsync and `DirectoryWatcher`'s FSEvents setup still block the pool briefly in the app as in tests.

Deferred minors: the delivery tracker outlives its window on a quiet box and marks several replies at once; the activity log uses the legacy `FileHandle.write`, which traps on I/O errors on Linux, and is never pruned; the phone listener starts before the socket check; the Mac's transcript-based last line is not used on the box.
