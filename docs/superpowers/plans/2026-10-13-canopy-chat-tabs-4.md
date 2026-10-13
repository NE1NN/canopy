# Chat Tabs, Milestone 4: Artifacts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Artifacts Claude publishes from a chat open beside it, and the chat shows a card for each, with a thumbnail, its version, and what it can do.

**Architecture:** On top of milestone 3 (PR 51).
`ChatBuilder` turns an Artifact publish into an `.artifact` item that its structured result fills in, and marks older versions of the same artifact as replaced.
`ChatSession` reports publishes it sees live, never ones it reads from history.
`TerminalStore` opens them in the row's panel by the artifact viewer's rules, reloads a panel already showing the URL, and asks for a thumbnail.
The app snapshots the page once the panel has loaded it and keeps the snapshot in `CANOPY_HOME/thumbnails/`.

**Tech Stack:** as milestone 1, and WebKit's `takeSnapshot` for thumbnails.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-chat-tabs-design.md`, Artifacts and milestone 4 under Delivery.

## Global Constraints

As milestone 1, and: nothing a row shows may change without its key changing, so a thumbnail that arrives changes its card's key.

## What real Claude Code showed

- An Artifact publish's structured result (`toolUseResult` in a transcript, `tool_use_result` in the stream) has `url`, `artifact_id`, `title`, `seq` (the version), `audience` ("owner" for a private one), `icon`, and `updated`.
- Its text result says "Published <file> at <url> (Version N, version id …)".
- The same tool also answers `quickstart`, `read`, `list`, and asset uploads, which publish nothing.

## Review Focus

1. A conversation read from history must not open its artifacts again. Pinned by `opensOnlyWhatItPublishesLive`.
2. A republish of a URL the panel shows must show the new version, not open a second page. Pinned by `aRepublishReloadsThePanelInsteadOfOpeningAnother`.
3. A thumbnail must never be a sign-in page. Only a page still at the artifact's URL is snapped.
4. Cards for one artifact must agree on which version is current, also across older pages loaded later. Pinned by `marksOlderVersionsReplaced`.
5. A failed publish must say so, not show an empty card. Pinned by `aFailedPublishStaysAToolLine`.

## Tasks

- [ ] **Task 1: Artifact items.** `ChatArtifact`, `ChatContent.artifact`; the builder makes a publish an artifact item filled in by its structured result (version from `seq`, else the count of publishes of that URL), keeps other Artifact actions as tool lines, and marks older versions replaced. Tests: `ChatArtifactTests`.
- [ ] **Task 2: Opening live publishes.** `ChatSession.onArtifact`, the store opens the URL in the row's panel, reloads a panel already at it, and wants a thumbnail. The stand-in gains `artifact`. Tests: `opensOnlyWhatItPublishesLive`, `aRepublishReloadsThePanelInsteadOfOpeningAnother`.
- [ ] **Task 3: Thumbnails.** `ArtifactThumbnails` (file per artifact and version), the app's snapshot after the panel loads, `ChatSession.thumbnailSaved`, the card's key.
- [ ] **Task 4: Cards.** The card (thumbnail, title, type, version, private, Open beside, ••• with Open in a tab, Open in browser, Copy link) and the compact replaced card.
- [ ] **Task 5: Links.** An artifact link in Claude's text opens in the panel on a single click; other web links open the default browser.

## Decisions to review

## After Review
