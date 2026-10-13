# Canopy on the box, Milestone 4: the phone server on the box

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `canopy-box` serves phones directly over the tailnet, with the same `phone.*` methods the Mac serves, so the phone reads and answers box agents with the Mac off; `canopy phone pair|list|remove --on <host>` manage the box's phones from the Mac; a connected phone keeps the box on.

**Architecture:** `BoxPhoneSource` implements `PhoneSource` over `BoxDaemon`: the inbox and rows from its snapshot, transcripts from each pane's transcript path, replies as a bracketed paste then Return, answers and keys through `PhoneAnswerKeys` and tmux, and screens from `tmux capture-pane -e`.
`canopy-box serve` starts a `PhoneServer` on it, listening on the box's tailnet addresses, which `TailnetAddresses` reads with `getifaddrs` every 5 seconds, on `config.json`'s port or the standard one.
The daemon answers `box.pair`, `box.phones`, and `box.phoneRemove`, which the Mac's CLI reaches through the link with `--on`.

**Tech Stack:** Swift 6.4, Swift Testing, `PhoneTestClient`, tmux.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "Pairing with the box", "Conversations", "Tailscale", "Idle power-off", "Security", and Delivery item 4.

## Global Constraints

- Nothing runs against hindie-box or its tailnet: tests and the e2e use loopback through `CANOPY_BOX_PHONE_ADDRESS`, which only tests set.
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
- [ ] `BoxMain.serve` starts a `PhoneServer` with `BoxPhoneSource`, `box/phones.json`, the host's name from `config.json`, the port from `config.json` or 6974, and `CANOPY_BOX_PHONE_ADDRESS` in place of the tailnet for tests.
- [ ] Commit `feat: canopy-box listens for phones on the tailnet`.

### Task 3: Pairing from the Mac, and phones keeping the box on

- [ ] `box.pair`, `box.phones`, `box.phoneRemove` on the daemon; `canopy phone pair|list|remove --on <host>` through the link.
- [ ] Tests: `pairingThroughTheLinkGivesALinkForTheBox`, `aPhonePairedWithTheBoxReadsItsInbox` (a `PhoneTestClient` over loopback), `aConnectedPhoneKeepsTheBoxOn`, `removingAPhoneEndsItsConnection`.
- [ ] Commit `feat: phones pair with canopy-box from the Mac and keep the box on`.

### Task 4: The e2e

- [ ] `scripts/e2e-hosts.sh`: after the upgrade, `phone pair --on fake-box` with `CANOPY_BOX_PHONE_ADDRESS=127.0.0.1`, a phone client pairs, reads the inbox with the box pane's waiting agent, replies, and the reply reaches the pane; `phone remove --on` drops it.
- [ ] Commit `test: the hosts e2e pairs a phone with canopy-box`.

## Verification

- `make lint`, `make build`, `make test` three times, `make linux`, `make box`, `make e2e`, an opus review with After Review, CI.
