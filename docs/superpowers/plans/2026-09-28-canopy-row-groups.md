# Canopy Row Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a repo's rows be gathered into named groups that fold away in the sidebar, with every group action available to agents through `canopy group` and `canopy row move`.

**Architecture:** Groups live on each repo's entry in `state.json`, and `rowOrder` keeps only ungrouped rows, so each Canopy or adopted row sits in exactly one ordered list.
The rules (names, moves, the reconcile with git) are value-type methods on `RepoEntry`, and dropping a dragged row is a pure function over the sidebar's line frames, so both are tested without git or UI.
`Workspace` applies them, logs the events, and arranges each repo snapshot in sidebar order with each `Row` carrying its group's name, so the control API, the CLI, and the sidebar all read one arrangement.

**Tech Stack:** Swift 6.2, SwiftUI and AppKit on macOS 15, swift-argument-parser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`, approved with its eleven "Decisions to review" on 2026-09-28.
The main spec, `docs/superpowers/specs/2026-09-27-canopy-design.md`, covers what groups build on: "Sidebar order", "Sidebar rows", "Control API", and "Activity log".

## Global Constraints

- A group belongs to one repo, and a row can only join a group in its own repo.
- Order within a repo: the main row, the ungrouped rows, each group's header and its rows unless collapsed, then the other worktrees fold. A repo with no groups looks exactly as today.
- Names are trimmed of whitespace and newlines, must not be empty, must not hold a control character, and are unique per repo ignoring case. Lookups trim and ignore case. The stored name keeps its case.
- Membership is keyed by row path. Rows gone from git leave their group. Empty groups stay until deleted. A missing row stays in its group.
- `groups` and each group field decode with decodeIfPresent. An unreadable `groups` is dropped alone. `version` stays 1.
- A group that does not exist is an error, never created on the fly. Only `group new` and the UI's New Group create one.
- A move that changes nothing succeeds and logs no `row.moved`. Only a change of group logs `row.moved`. Deleting a group logs one `group.removed`.
- `⌘1` to `⌘9` and `↑`/`↓` follow the visible order, skipping rows in collapsed groups.
- Error codes: `invalid_group_name`, `group_exists`, `group_not_found`, `cannot_move_main`, `not_managed`, `invalid_anchor`, `bad_params`.
- Swift 6 language mode with strict concurrency, no warnings, and `make lint` clean after every task.
- UI checks use `scripts/ui-fixture.sh`, `scripts/ui.swift`, and `scripts/window-shot.swift` on a throwaway home. Never full-screen shots.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. **A refresh landing while `row new --group` runs git** must not show the new row among the ungrouped rows first, and must not log it twice.
   Pinned by `aRowCreatedIntoAGroupNeverShowsUngrouped` in Task 3, which stalls `git worktree add` and refreshes during it.
2. **A hand-edited `state.json`** with a path in two groups, a group without a name, two names differing only in case, or `groups` of the wrong type must load, keep repos and rows, and never show a row twice.
   Pinned by `groupsThatCannotBeTrustedAreCleanedOnLoad` and `anUnreadableGroupsListIsDroppedAlone` in Task 1.
3. **Dropping a row back where it came from**, onto itself, or on the main row when it is already first must change nothing and log nothing.
   Pinned by `dropsThatChangeNothingAreNoOps` in Task 5 and `movesThatChangeNothingLogNothing` in Task 2.
4. **`↑` and `↓` from a selected row hidden in a collapsed group** must continue from the group's place, not jump to the top or bottom of the sidebar.
   Pinned by `steppingFromAHiddenRowContinuesFromItsGroup` in Task 2.
5. **Deleting or renaming a group while `row new --group` for it runs** must still create the row, ungrouped, with a warning, rather than failing after the worktree exists.
   Pinned by `aGroupDeletedWhileItsRowIsCreatedLeavesTheRowUngrouped` in Task 3.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/CanopyCore/State/AppState.swift` | modify | `RepoEntry.groups` and its decoding |
| `Sources/CanopyCore/Rows/RowGroups.swift` | create | `RowGroup`, `GroupName`, `RowPlacement`, and `RepoEntry`'s group rules: add, rename, remove, move, reconcile |
| `Sources/CanopyCore/Rows/RowOrdering.swift` | delete | replaced by `RepoEntry.reconcile` |
| `Sources/CanopyCore/Rows/Row.swift` | modify | `Row.group` |
| `Sources/CanopyCore/Rows/RowDrop.swift` | create | `DropSlot`, `RowDropTarget`, and `RowDrop.target`, the pure drop resolution |
| `Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift` | modify | `GroupSnapshot`, `RepoSnapshot.groups`, `arranged(by:)`, visible rows, and stepping |
| `Sources/CanopyCore/Workspace/Workspace+Groups.swift` | create | group operations, moves, folding, revealing, and their events |
| `Sources/CanopyCore/Workspace/Workspace.swift` | modify | the reconcile on refresh, arranging snapshots |
| `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift` | modify | `createRow(group:)` |
| `Sources/CanopyCore/Workspace/WorkspaceError.swift` | modify | the new error cases |
| `Sources/CanopyCore/Activity/ActivityEvent.swift`, `ActivityReader.swift` | modify | event types and their `canopy log` text |
| `Sources/CanopyCore/Control/GroupMethods.swift` | create | `group.*` and `row.move` params and results |
| `Sources/CanopyCore/Control/ControlMethods.swift`, `WorkspaceControlHandler.swift` | modify | wiring, `row.new` `group`, read-only list |
| `Sources/CanopyCLI/GroupCommand.swift` | create | `canopy group list|new|rename|rm` |
| `Sources/CanopyCLI/RowCommand.swift`, `AgentGuide.swift`, `CanopyCLI.swift` | modify | `row move`, `row new --group`, the GROUP column, the Groups section |
| `Sources/CanopyApp/Sidebar/GroupViews.swift` | create | the group header, its menu, and the name and delete popovers |
| `Sources/CanopyApp/Sidebar/RowDragAndDrop.swift` | create | the row drag source, the list's drop delegate, and the indicator |
| `Sources/CanopyApp/Sidebar/SidebarView.swift`, `RowActionViews.swift`, `PortsPanel.swift` | modify | sections with groups, Move to Group, the sheet's picker, revealing from the ports panel |
| `Sources/CanopyApp/AppModel.swift` | modify | group actions, stepping, and the row being dragged |
| `scripts/bundle.sh` | modify | declares the private row pasteboard type |
| `scripts/ui.swift`, `scripts/ui-fixture.sh`, `scripts/e2e.sh` | modify | held drags, groups in the fixture, group cases |
| `docs/superpowers/specs/*.md` | modify | pointers from the main spec's tables |

## Task 1: Group rules on the repo entry

**Files:** Create `Sources/CanopyCore/Rows/RowGroups.swift`. Modify `AppState.swift`, `WorkspaceError.swift`. Test `Tests/CanopyCoreTests/RowGroupTests.swift`, `StateStoreTests.swift`.

**Interfaces:**
- Produces `RowGroup` (`name: String`, `rows: [String]`, `collapsed: Bool`), `RepoEntry.groups: [RowGroup]`.
- Produces `GroupName.validated(_:) throws -> String` and `GroupName.key(_:) -> String`.
- Produces `RowPlacement`: `.group(String)`, `.ungrouped`, `.before(String)`, `.after(String)`, the last two holding row paths.
- Produces on `RepoEntry`: `groupIndex(named:) -> Int?`, `groupName(of:) -> String?`, `holds(_:) -> Bool`, and mutating `addGroup(_:repo:) throws -> RowGroup`, `renameGroup(_:to:repo:) throws -> RowGroup`, `removeGroup(_:repo:) throws -> RowGroup`, `move(_:to:repo:) throws -> Bool`, `reconcile(present:joining:) -> Bool`.
- Produces `WorkspaceError.invalidGroupName`, `.groupExists(String, repo:)`, `.groupNotFound(String, repo:)`, `.cannotMoveMain`, `.invalidAnchor(String)`.

Tests, all pure:

- `namesAreTrimmedAndMustHoldSomething`: `"  Review \n"` becomes `"Review"`, and `""`, `"   "`, `"a\tb"`, and `"a\nb"` throw `invalidGroupName`.
- `namesAreUniqueIgnoringCase`: adding `"review"` next to `"Review"` throws `groupExists("Review", repo:)`.
- `renamingToAnotherCaseOfItsOwnNameIsAllowed`, and renaming onto another group's name throws `groupExists`.
- `lookupsTrimAndIgnoreCase`: `groupIndex(named: " REVIEW ")` finds `"Review"`.
- `removingAGroupUngroupsItsRowsInOrder`: its rows go to the end of `rowOrder` in group order.
- `movesPlaceRowsWhereAsked`: into a group (end), out of one (end of `rowOrder`), before and after rows inside and outside groups, each moving the path out of its old list.
- `movesThatChangeNothingReturnFalse`: `.group` for its own group, `.ungrouped` for an ungrouped row, `.after` the row just above it.
- `movesRejectBadTargets`: a missing group throws `groupNotFound`, an anchor that is the row itself or not held throws `invalidAnchor`, and a row the entry does not hold throws `rowNotFound`.
- `reconcileFollowsGit`: gone paths leave groups and `rowOrder`, new paths join `rowOrder`, a new path in `joining` joins that group, empty groups stay, and nothing changed returns false.
- `aPathInTwoPlacesKeepsTheFirstGroup`.
- In `StateStoreTests`: `groupsRoundTrip`, `groupsThatCannotBeTrustedAreCleanedOnLoad` (a group with no name, one with a blank name, two names differing in case, and a path in two groups load as one clean group per name with each path once), and `anUnreadableGroupsListIsDroppedAlone` (`"groups": 7` keeps the repo, its `adopted` and `rowOrder`).

- [ ] **Step 1: Write the failing tests** in `RowGroupTests.swift` and `StateStoreTests.swift`.
- [ ] **Step 2: Run `make test` and see them fail to compile** for want of `RowGroup` and the `RepoEntry` methods.
- [ ] **Step 3: Implement `RowGroups.swift`, `RepoEntry.groups`, and the error cases.**
  `RepoEntry.init(from:)` decodes `groups` with `try?` and cleans them: names validated, later case duplicates dropped, and each path kept only in the first group that lists it and removed from `rowOrder`.
- [ ] **Step 4: Run `make test` and `make lint` until clean.**
- [ ] **Step 5: Commit** `feat: group rules on the repo entry`.

## Task 2: Groups in the workspace

**Files:** Create `Sources/CanopyCore/Workspace/Workspace+Groups.swift`. Modify `Row.swift`, `WorkspaceSnapshot.swift`, `Workspace.swift`, `ActivityEvent.swift`, `ActivityReader.swift`. Delete `RowOrdering.swift` and its tests in `RowModelTests.swift`. Test `Tests/CanopyCoreTests/WorkspaceGroupTests.swift`, `ActivityReaderTests.swift`.

**Interfaces:**
- Consumes Task 1.
- Produces `Row.group: String?`, encoded as `"group"` and left out when nil.
- Produces `GroupSnapshot` (`name`, `collapsed`), `RepoSnapshot.groups`, `RepoSnapshot.arranged(by: RepoEntry) -> RepoSnapshot`, `RepoSnapshot.rows(inGroup:) -> [Row]`, `RepoSnapshot.visibleRows`, and `WorkspaceSnapshot.visibleRows` now skipping collapsed groups.
- Produces `WorkspaceSnapshot.steppingRow(from: String?, offset: Int) -> Row?` for `↑` and `↓`.
- Produces `GroupInfo` (`repo`, `repoPath`, `name`, `collapsed`, `rows: [Row]`) with `init(repo: RepoSnapshot, group: GroupSnapshot)`.
- Produces on `Workspace`: `createGroup(repoPath:name:) throws -> GroupInfo`, `renameGroup(repoPath:name:to:) throws -> GroupInfo`, `removeGroup(repoPath:name:) throws -> GroupInfo`, `setGroupCollapsed(repoPath:name:collapsed:) throws`, `moveRow(path:to:) throws -> MovedRow` (`row: Row`, `moved: Bool`), `revealRow(path:) throws`, and `groups(repoPath:) -> [GroupInfo]`.
- Produces `ActivityType.groupCreated`, `.groupRenamed`, `.groupRemoved`, `.rowMoved`.

`RepoSnapshot.rows` keeps meaning the main row and every Canopy and adopted row, now in sidebar order: main, ungrouped, then each group's rows.
So counts, PR lookups, target resolution, and ports keep working unchanged, and the sidebar filters `rows` by `group`.
Group changes run no git, so each one mutates the entry, saves, rearranges the repo's snapshot from the rows git last gave, and publishes.

Tests:

- `newRowsJoinTheUngroupedRowsAndGroupsHoldTheirs`: snapshot order is main, ungrouped, then each group's rows, with `group` set on each.
- `groupsSurviveRelaunchAndBranchSwitches`: a row switched to another branch with plain git keeps its group, and a new `Workspace` on the same home shows the same arrangement.
- `rowsGoneFromGitLeaveTheirGroupButGroupsStay`: removing a grouped worktree with plain git empties its group, which stays.
- `unadoptingARowTakesItOutOfItsGroup`.
- `movingRowsFollowsTheRules`: every error code through `moveRow`, including `cannotMoveMain`, `notManaged` for an external row, and `invalidAnchor` for a row in another repo.
- `movesThatChangeNothingLogNothing` and `reordersLogNothing`, while a change of group logs `row.moved` with `from` and `to`, and its source.
- `groupEventsCarryTheRepo`: `group.created`, `group.renamed`, and `group.removed` with `repo`, `path`, `data`, and the source from `ActivitySource.current`, and a rename to the same name logs nothing.
- `collapsedGroupsAreSkippedInTheVisibleOrder` across two repos.
- `steppingFromAHiddenRowContinuesFromItsGroup`: from a row in a collapsed group, `+1` is the first visible row after the group and `-1` the last visible row before it.
- `revealingARowUnfoldsItsGroup`, and folding is saved but never logged.
- In `ActivityReaderTests`: `groupEventsReadWell` for the four new lines of `canopy log` text.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run `make test` and see them fail.**
- [ ] **Step 3: Implement.** `refreshNow` replaces `RowOrdering.reconcile` with `RepoEntry.reconcile(present:joining:)` and builds the snapshot through `arranged(by:)`. `unadopt` no longer edits `rowOrder` itself; the refresh after it reconciles.
- [ ] **Step 4: Run `make test` and `make lint` until clean.**
- [ ] **Step 5: Commit** `feat: groups in the workspace`.

## Task 3: Creating a row into a group

**Files:** Modify `Workspace+RowLifecycle.swift`, `Workspace.swift`. Test `WorkspaceGroupTests.swift`.

**Interfaces:**
- Consumes Tasks 1 and 2.
- Produces `Workspace.createRow(repoPath:branch:base:group:)`, where `group` defaults to nil.

The group is looked up inside the repo's git queue before any git runs, so a missing group creates nothing.
Its path goes into `rowsJoiningGroups` before `git worktree add`, so a refresh that lists the half-made worktree reconciles it straight into the group.
Once `createRowNow` has returned, which logged `row.created`, `createRow` removes the path from `rowsJoiningGroups` and logs `row.moved` from null to the group.
If the group went away meanwhile, the row is ungrouped and `CreatedRow.warnings` says so.

Tests:

- `aRowCreatedIntoAGroupNeverShowsUngrouped`: a git wrapper stalls `worktree add` until the test has refreshed the repo, and no snapshot seen by a subscriber shows the path in `rowOrder`.
- `aMissingGroupCreatesNothing`: `groupNotFound`, and no worktree folder or branch.
- `rowCreatedIntoAGroupLogsCreatedThenMoved`.
- `aGroupDeletedWhileItsRowIsCreatedLeavesTheRowUngrouped`: the stalled git lets the test delete the group, and the row ends up ungrouped with a warning.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run `make test` and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test` and `make lint` until clean.**
- [ ] **Step 5: Commit** `feat: create a row straight into a group`.

## Task 4: `canopy group` and `canopy row move`

**Files:** Create `Sources/CanopyCore/Control/GroupMethods.swift`, `Sources/CanopyCLI/GroupCommand.swift`. Modify `ControlMethods.swift`, `WorkspaceControlHandler.swift`, `RowCommand.swift`, `AgentGuide.swift`, `CanopyCLI.swift`, `scripts/e2e.sh`. Test `Tests/CanopyCoreTests/GroupControlTests.swift`.

**Interfaces:**
- Consumes Tasks 2 and 3.
- Produces `GroupMethod.list`, `.new`, `.rename`, `.remove`, and `ControlMethod.rowMove`.
- Produces `GroupListParams` (`repo`), `GroupParams` (`target`, `name`), `GroupRenameParams` (`target`, `name`, `newName`), `RowMoveParams` (`target`, `group`, `noGroup`, `before`, `after`) with `placementCount`, `RowMoveResult` (`row`, `moved`), and `RowNewParams.group`.

`row.move` resolves its row with `TargetResolver.row`, and `before` or `after` with the same resolver scoped to the row's repo, so a branch in another repo is `invalid_anchor` rather than ambiguous.
`RowMoveResult` adds `moved` to the row the spec names, so the CLI can say "already in Review" without a second request, and `row move --json` still prints only the row.
`row select` and `row new --select` unfold a collapsed group through `Workspace.revealRow` before telling the UI.

Tests, through the in-process server:

- `groupsFlowOverTheSocket`: new, list, rename, remove, each result's shape, and `group.list` not logged as `cli.call`.
- `rowMoveTakesExactlyOneDestination`: none and two give `bad_params`.
- `rowMoveResolvesAnchorsInTheRowsRepo`.
- `rowNewWithAGroupPutsTheRowThere`, and `rowNewWithAMissingGroupFails` with `group_not_found`.
- `selectingAHiddenRowUnfoldsItsGroup`.

`scripts/e2e.sh` gains a step after "listing" that drives every command with a real app, checks the GROUP column and `"group"`, both errors, that `group rm` leaves the worktree, that `canopy log --type group` shows the events, and, just before the app is stopped for the last step, that groups come back after a relaunch.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run `make test` and see them fail.**
- [ ] **Step 3: Implement the methods, the commands, and the agent guide's Groups section.**
- [ ] **Step 4: Run `make test`, `make lint`, and `make e2e` until clean.**
- [ ] **Step 5: Commit** `feat: canopy group and canopy row move`.

## Task 5: Where a dragged row lands

**Files:** Create `Sources/CanopyCore/Rows/RowDrop.swift`. Test `Tests/CanopyCoreTests/RowDropTests.swift`.

**Interfaces:**
- Consumes `RowPlacement` from Task 1.
- Produces `DropSlot` (`repoPath`, `kind`: `.main(path)`, `.row(path, group: String?)`, `.header(String)`, `minY`, `maxY`), `RowDropTarget` (`placement`, `indicator`: `.header(String)`, `.above(path)`, `.below(path)`), and `RowDrop.target(dragging: Row, at y: Double, in slots: [DropSlot]) -> RowDropTarget?`.

Tests:

- `headersTakeTheRowAtTheirEnd`, collapsed or not.
- `rowHalvesPlaceBeforeOrAfter`, in and out of groups.
- `theMainRowMeansFirstAmongTheUngroupedRows`: `.before` the first ungrouped row that is not the dragged one, or `.ungrouped` when there is none.
- `otherReposAndGapsAreNotTargets`, and the dragged row itself is not one.
- `dropsThatChangeNothingAreNoOps`: applying each target to a `RepoEntry` with `move` returns false where the row already is.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run `make test` and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test` and `make lint` until clean.**
- [ ] **Step 5: Commit** `feat: where a dragged row lands`.

## Task 6: Groups in the sidebar

**Files:** Create `Sources/CanopyApp/Sidebar/GroupViews.swift`. Modify `SidebarView.swift`, `RowActionViews.swift`, `PortsPanel.swift`, `AppModel.swift`, `scripts/ui-fixture.sh`.

**Interfaces:**
- Consumes Tasks 2 and 3.
- Produces `AppModel.createGroup(in:name:) async -> String?`, `renameGroup(_:in:to:) async -> String?`, `removeGroup(_:in:)`, `setCollapsed(_:_:in:)`, `move(_:to:)`, and `createRow(in:branch:base:group:)`.
- Produces `AppModel.reveal(_ path: String)`, which selects a row and unfolds its group, and `scrollRequest`, which the list scrolls to.

Each repo section shows the ungrouped rows, then a `GroupHeaderView` per group with its rows indented one step, all filtered from `repo.rows` by `group`.
The header is a button that folds the group, with the count giving way to `…` and `+` on hover.
The name popover serves New Group… on the repo and in Move to Group, and Rename… on a group, and shows each error under its field.
Delete Group… asks first in a popover when the group has rows, and deletes an empty one at once.
VoiceOver reads a header as one button with its name, row count, and fold, and a grouped row's label adds its group.
The New Row sheet opens from a `NewRowRequest` carrying the repo and the group, and shows a Group picker when the repo has groups.
`↑` and `↓` use `steppingRow`, and the ports panel's branch headings call `reveal`.

The fixture gains a "Review" group in web-app holding feat/checkout-redesign and feat/onboarding-flow, and a collapsed "Later" group holding a new chore/bump-deps row.

- [ ] **Step 1: Build the views and model actions.**
- [ ] **Step 2: `make app`, open the fixture in dark and light, and shoot the window with groups expanded and collapsed, a hovered header, the Move to Group menu, the name popover with an error, and a collapsed group holding the selection.**
- [ ] **Step 3: Check with posted keys that `⌘N` hints and `↓` skip the collapsed group, and with `canopy row list --json` that menu moves landed.**
- [ ] **Step 4: Run `make build`, `make lint`, and `make test` until clean.**
- [ ] **Step 5: Commit** `feat: groups in the sidebar`.

## Task 7: Dragging rows

**Files:** Create `Sources/CanopyApp/Sidebar/RowDragAndDrop.swift`. Modify `SidebarView.swift`, `AppModel.swift`, `scripts/bundle.sh`, `scripts/ui.swift`.

**Interfaces:**
- Consumes `RowDrop` from Task 5 and `AppModel.move(_:to:)` from Task 6.
- Produces `UTType.canopyRow` (`com.ne1nn.canopy.row`, declared in the bundle's `UTExportedTypeDeclarations`), `AppModel.draggedRow`, and `ui down|drag-to|up`.

Canopy and adopted rows get `.onDrag` with the row's path under `UTType.canopyRow`, and set `model.draggedRow`.
The list holds one drop delegate, which reads every line's frame in the list's coordinate space, asks `RowDrop.target`, draws the indicator, and on drop calls `model.move`.
The dragged row dims while the drag is over the list.
If AppKit does not scroll the list near its edges by itself, the delegate scrolls it.

- [ ] **Step 1: Add `down`, `drag-to`, and `up` to `scripts/ui.swift`.**
- [ ] **Step 2: Build the drag source, the delegate, and the indicator.**
- [ ] **Step 3: With `make app` and the fixture, drag with posted mouse events onto a header, between rows in and out of a group, onto the main row, and into another repo, and check each with `canopy row list --json`. Shoot a drag held over a header and between rows, in dark and light.**
- [ ] **Step 4: Run `make build`, `make lint`, and `make test` until clean.**
- [ ] **Step 5: Commit** `feat: drag rows into and out of groups`.

## Task 8: Point the main spec at groups

**Files:** Modify `docs/superpowers/specs/2026-09-27-canopy-design.md` and `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`.

The main spec's "Sidebar order", its command table, and its event table each gain a line pointing at the groups spec.
The groups spec's control table says `row.move` answers with the row and whether it moved.

- [ ] **Step 1: Edit both specs.**
- [ ] **Step 2: Commit** `docs: point the main spec at row groups`.
