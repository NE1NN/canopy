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

- [x] **Task 1: Artifact items.** `ChatArtifact`, `ChatContent.artifact`; the builder makes a publish an artifact item filled in by its structured result (version from `seq`, else the count of publishes of that URL), keeps other Artifact actions as tool lines, and marks older versions replaced. Tests: `ChatArtifactTests`.
- [x] **Task 2: Opening live publishes.** `ChatSession.onArtifact`, the store opens the URL in the row's panel, reloads a panel already at it, and wants a thumbnail. The stand-in gains `artifact`. Tests: `opensOnlyWhatItPublishesLive`, `aRepublishReloadsThePanelInsteadOfOpeningAnother`.
- [x] **Task 3: Thumbnails.** `ArtifactThumbnails` (file per artifact and version), the app's snapshot after the panel loads, `ChatSession.thumbnailSaved`, the card's key.
- [x] **Task 4: Cards.** The card (thumbnail, title, type, version, private, Open beside, ••• with Open in a tab, Open in browser, Copy link) and the compact replaced card.
- [x] **Task 5: Links.** An artifact link in Claude's text opens in the panel on a single click; other web links open the default browser.

## Measured

On this milestone's build, which includes milestone 3, with the heavy-work lock held and the Mac otherwise quiet (load average 3 to 6).

- Opening a 2,000-message chat: about 195 ms, of which 55 ms reads and builds its newest page (461 lines, 347 rows) and 140 ms is the table's first full update with layout forced. Budget 300 ms.
  PR 48 reported 100 ms; its 43 ms for the rows was timed without forcing layout.
- Memory with that chat open: 83 to 117 MB.
- A 600-word reply streaming at 50 words a second, averaged over three runs: 28 to 32% of one core in a new chat, 34 to 37% in the 2,000-message chat. Budget 20%, so this is over.
  Milestone 1's build, measured the same way, gives 18 to 47%, so this is not new in milestones 2 to 4; PR 48's 14 to 21% came from a lighter test.
  Found and fixed here: Working's pulsing asterisk cost about 10% for as long as Claude worked, and costs under 1% now that Core Animation runs it.
  What remains is SwiftUI laying out the growing block three times per redraw (measuring it, drawing it, and scrolling to it). The next step is drawing the block Claude is writing with an AppKit text view, which is a change of its own.
- Scrolling: not measured, as before; scroll events posted to a background window do not arrive.

## Decisions to review

- A card's type is "Page" unless the result names one, as for a page made from an Artifact type; Claude Code 2.1.296's result names none for a plain page.
- A version is the one the result names (`seq`), or else the count of publishes of that URL in the conversation.
- Only the newest version of an artifact gets a full card; older ones are a dimmed line that opens the current version.
- A live publish opens in the row's panel, whatever the row's default placement, as the mockup shows it beside the chat.
- The snapshot is taken two seconds after the page loads, since an artifact draws inside a frame, and only while the page is at the artifact's address and answered with a success status.
  claude.ai answers its own "Page not found" with a success status, so a link to an artifact the author cannot open can still be snapped.
- A card whose artifact has no snapshot yet shows six grey tiles, as the mockup does.
- Only a publish seen live asks for a snapshot. Open beside on a card from history shows the artifact's newest version, which may have been published elsewhere since and is not that card's.
- Only a version the result names gets a snapshot, since a counted one changes as older pages load.

## After Review

An independent opus review found 2 medium-high, 1 medium, 1 low-medium, and 5 low findings; all fixed:

1. Medium-high: a republish reloaded in a row out of view used up its snapshot wish, so the card kept grey tiles.
   The wish stays until a snapshot is saved, and a page that comes back into view tries again.
2. Medium-high: the snapshot never checked again after its two-second wait, so a sign-in or a newer version could be saved under the wrong key.
   It checks the address, that no new load began, and that the page is in view, before and after taking it.
3. Medium: a publish whose result named no page stayed at "Publishing…" when its call and result were on different pages.
   It reads as a tool line wherever the page boundary falls.
   Test: `aResultThatNamesNoPageIsAToolLineWhicheverPageItIsOn`.
4. Low-medium: an `artifact_id` from a tool result could name a file outside the thumbnails folder.
   Only letters, digits, - and _ count; otherwise the URL's checked ID is used.
   Test: `anArtifactIDThatIsNoPlainNameIsNotAFileName`.
5. Low-medium: a republish reloaded whatever the panel had moved on to.
   It loads the artifact's address.
   Test: `aRepublishReloadsThePanelInsteadOfOpeningAnother`.
6. Low: Open beside on a card could save a newer version's snapshot under the card's version.
   Only live publishes ask for snapshots.
7. Low: wishes outlived their page.
   Closing a page drops its wish.
   Test: `closingAPageDropsItsSnapshotWish`.
8. Low: building rows read the disk for each card, and each card decoded its image twice.
   Which snapshots exist is read once and kept as they are saved, and images decode once.
9. Low: a counted version could get another card's snapshot once older pages loaded, and a saved snapshot redrew only the chat that asked.
   Only named versions get snapshots, and every chat redraws.
   Test: `aCountedVersionHasNoSnapshot`.

Seen while taking the shots: twice in about eight runs, both on a busy machine, the panel stayed empty in window shots although its page had loaded, as its snapshot shows; a page opened after it in the same panel stayed empty too.
It did not happen again in later runs, with or without a fresh build, and the first time was before any change here touched the web views.

Found while measuring, and fixed:

- Working's asterisk pulsed through SwiftUI's symbol effect, which redrew its row every frame for as long as Claude worked, about 10% of a core. Core Animation runs the pulse now.
- Each draw of the reply looked for paragraph breaks from the start of the reply. It looks from the last settled block.
- A long paragraph or code block is drawn less often as it grows, up to 300 ms apart.
- The turn's token count redrew the chat each time Claude Code reported it. It shows at most four times a second.
- Tests: `streamingInPiecesSettlesAsTheWholeTextWould`, `aLongBlockIsDrawnLessOften`.

