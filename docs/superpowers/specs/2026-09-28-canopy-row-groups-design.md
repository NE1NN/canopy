# Canopy row groups

Date: 2026-09-28
Status: design approved in conversation 2026-09-28, spec in review

## Summary

A repo's rows can be gathered into named groups, such as "Review" or "Spikes", that fold away in the sidebar.
A group is only a way of arranging the sidebar.
It lives in `state.json`, never in git, and deleting one never touches a worktree.
Everything the sidebar does with groups, an agent can do with `canopy group` and `canopy row move`.

## Goals

1. Name a set of rows in one repo and fold them away under a header.
2. Put a row in a group by dragging it, from its context menu, or from the CLI, and create a row straight into a group.
3. An agent can do all of it without the window, and sees each row's group in `canopy row list`.
4. A repo with no groups looks and behaves exactly as it does today.

## Non-goals

- Groups that span repos, and groups inside groups.
- Reordering groups.
  A new group goes after the repo's other groups.
- Dragging rows to another repo, and dragging repos.
- Unfolding a collapsed group while a drag hovers over it.
- Grouping the main row or external rows.
- A color or icon per group.
- Undo for group changes.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Scope | A group belongs to one repo, and a row can only join a group in its own repo | Rows of different repos never share a sidebar section today, and ports, PRs, and setup are all per repo. |
| Membership | Keyed by row path | A branch switch inside a row keeps its group, and `rowOrder`, layouts, and adoption already key rows by path. |
| Storage | `groups` on each repo in `state.json`, with `rowOrder` holding only ungrouped rows | Each row then sits in exactly one ordered list, so there is no second order to keep in step. |
| Unknown groups | An error, never created on the fly | A typo in an agent's `--group` should fail loudly rather than grow a stray group. |
| Empty groups | Stay until deleted | An agent can make a group before it creates the rows for it, and a group does not vanish when its last row is merged. |

## Data

### State

Each repo entry in `state.json` gains `groups`:

```json
{
  "path": "/Users/me/Projects/web-app",
  "dirName": "web-app",
  "adopted": [],
  "rowOrder": ["/Users/me/.canopy/worktrees/web-app/fix-login"],
  "groups": [
    {
      "name": "Review",
      "rows": [
        "/Users/me/.canopy/worktrees/web-app/feat-checkout",
        "/Users/me/.canopy/worktrees/web-app/feat-onboarding"
      ],
      "collapsed": false
    },
    {"name": "Spikes", "rows": ["/Users/me/.canopy/worktrees/web-app/spike-parser"], "collapsed": true}
  ]
}
```

- `groups` lists the repo's groups in sidebar order.
- A group's `rows` lists row paths in sidebar order.
- `collapsed` says whether the sidebar folds the group.
- `rowOrder` now holds only the ungrouped rows.
- Every Canopy and adopted row of a repo sits in exactly one place: `rowOrder` or one group's `rows`.

`groups`, and each of a group's fields, decode with decodeIfPresent, so files written before groups still load.
A `groups` value that cannot be read at all is dropped on its own, the way unreadable layouts are, so repos and rows still load.
`version` stays 1, since the change only adds fields.
An older Canopy ignores `groups` and leaves it out of its next save, so the rows come back ungrouped.

### Names

A group's name is trimmed of spaces and newlines at both ends.
After trimming it must not be empty, and it must not contain a control character such as a newline or a tab.
Names are unique within a repo ignoring case, so "Review" and "review" cannot both exist in one repo.
Two repos can each have a group with the same name.

Wherever a name is looked up, as with `--group review`, it is trimmed and matched ignoring case.
The stored name keeps the case it was given.
Renaming a group to another case of its own name is allowed.

### Keeping groups in step with git

Git still decides which rows exist.
Each time Canopy lists a repo's worktrees, it reconciles the repo's groups with that list:

1. A path that is no longer a Canopy or adopted row of the repo leaves its group.
   This covers a row removed with `canopy row rm` or plain git, and a row that was un-adopted.
2. A path found in more than one place, which only a hand-edited file can cause, stays in the first group that lists it and leaves `rowOrder`.
3. New rows go to the end of `rowOrder` as today, unless they were created into a group.
4. Empty groups stay.

A reconcile that changes anything saves `state.json`.
A missing row, whose folder is gone but which git still lists, stays in its group until it is pruned.
A worktree list that git fails to give changes nothing, and neither does a repo whose folder is missing, so its groups wait in `state.json` until it is located or removed.
Relocating a repo keeps its groups, since its rows' paths do not change.
Removing a repo drops its groups along with the rest of its entry.

A row created into a group appears in that group directly.
It never shows among the ungrouped rows first, even when a refresh lands while git is still creating it.

### In CanopyCore

The name rules, the reconcile, moves, the visible order for `⌘1` to `⌘9`, and the mapping from a pointer position to a drop destination all live in `CanopyCore` as plain functions and `Workspace` methods, so tests cover them without the UI.
Each `Row` in a snapshot carries its group's name, the way it carries its PR, and each `RepoSnapshot` lists its groups with their rows and collapsed flag.
Group changes touch only `state.json`, so they do not wait in the repo's git queue.

## Sidebar

### Order

Within each repo, the sidebar shows:

1. the main row
2. the ungrouped Canopy and adopted rows, in saved order
3. each group in saved order: its header, then its rows indented one step, unless the group is collapsed
4. the "N other worktrees" fold

```
+--------------------------+
| W web-app            5   |
|   main                   |
|   fix/login              |
|   v Review           2   |
|       feat/checkout #145 |
|       feat/onboarding    |
|   > Spikes           1   |
|   > 3 other worktrees    |
+--------------------------+
```

A repo with no groups looks exactly as it does today.
A missing repo shows no groups, as it shows no rows.
A folded repo shows only its header, hiding its groups with its rows, as the main spec's Folding repos describes.
The repo header's count still counts every row but external ones, grouped or not.
The ports panel lists rows in the same order, and still lists the ports of rows inside collapsed groups.

### Group header

- A header is one row tall and reads, left to right: a chevron in the mark column, the group's name, and its row count at the right.
  It is quieter than the repo header: the name is in the Body style and secondary color, and the count is tertiary.
  A long name is cut short with an ellipsis and shows whole on hover.
- Clicking the header anywhere but its buttons folds or unfolds the group, and the chevron turns the way the other worktrees fold's does.
  The fold is saved.
- On hover, the count gives way to `…` and `+`, the way the repo header's does.
  `+` opens the New Row sheet with the group picked.
  `…` holds Rename… and Delete Group….
  The header's context menu holds the same items.
- A collapsed group that holds the selected row draws its header with the selection fill, accent-tinted while the sidebar has the keyboard like a selected row, so the sidebar always shows where the window is.
  When the group's repo is folded too, the repo's header holds the selection instead.
- The chevron is the one repo headers, plugin section headers, and the other worktrees fold use.
- VoiceOver reads the header as one button, such as "Review, group, 2 rows, collapsed".
  A row inside a group adds "in Review" to its label.

### Creating, renaming, and deleting

- The repo's `…` menu and context menu gain New Group….
- New Group… and Rename… open a small popover with a name field, anchored to the repo header or the group header.
  Return saves and Escape cancels.
  A name that breaks the rules above shows why under the field and keeps the popover open.
- A new group goes after the repo's other groups, expanded.
- Delete Group… on a group with rows asks first in a popover: "Delete Review? Its 2 rows move out of the group. No worktree is touched."
  An empty group is deleted at once.
- A deleted group's rows go to the end of the ungrouped rows, in the order they had in the group.

### Move to Group

The context menu of a Canopy or adopted row gains a Move to Group submenu:

- each group of the row's repo, with a check on the row's current group, which does nothing when picked
- No Group, while the row is in a group
- New Group…, which creates a group and moves the row into it

Picking a group does what `canopy row move --group` does, and No Group what `--no-group` does.
The main row and external rows do not get the submenu.

### New Row sheet

When the repo has groups, the New Row sheet shows a Group picker with No Group and each group.
The repo's `+` opens the sheet on No Group, and a group's `+` on that group.
A repo with no groups gets the sheet as it is today.

### Selection and collapsed groups

- Collapsing the group that holds the selected row keeps the row selected and its terminals on screen.
- Selecting a row hidden in a collapsed group unfolds the group, and its repo if that is folded too, so the row scrolls into view.
  That happens when the row is picked from the ports panel, with `canopy row select`, or with `canopy row new --select`.

## Drag and drop

A row can be dragged to another place within its own repo.

- Canopy and adopted rows can be dragged, missing ones included.
  The main row and external rows cannot.
- A drag starts once the pointer moves a few points with the button held, so clicking still selects.
- The dragged row dims in place while its image follows the pointer.
- The drag carries the row's path in a pasteboard type private to Canopy, so dropping it in another app, or dropping text on the sidebar, does nothing.

Where the pointer is decides what the drop does:

| Pointer over | Drop | Indicator |
|---|---|---|
| a group header, collapsed or not | puts the row at the end of that group | the header takes the accent fill |
| the upper half of another Canopy or adopted row | puts the row just before that row, in that row's group or among the ungrouped rows | a line above that row |
| the lower half of such a row | puts the row just after it | a line below that row |
| the dragged row itself | nothing | none |
| the repo's main row | puts the row first among the ungrouped rows | a line below the main row |
| anything else, such as another repo, a repo header, the other worktrees fold, or the ports panel | nothing | none |

The line is 2 points of the accent color with a small ring at its leading end.
It starts at the indent the row would land at, so the end of a group reads differently from the end of the ungrouped rows.

- A drop that would leave the row where it already is changes nothing.
- Any other drop does exactly what the matching `canopy row move` does, and logs the same events with source `ui`.
  A drop on the main row is `--before` the first ungrouped row, or `--no-group` when there is none.
- A drop that fails, such as onto a row that went away mid-drag, shows the error in a toast.
- Dragging near the top or bottom edge of the sidebar's list scrolls it.
- Escape, or letting go anywhere that is not a target, cancels the drag.

## Keyboard

- `⌘1` to `⌘9` select the first nine visible rows across all repos, in sidebar order: each repo's main row, its ungrouped rows, then the rows of each group that is not collapsed.
  Rows in collapsed groups, rows of folded repos and folded plugin sections, and external rows get no number.
- The `⌘N` hints on hover and the row items in the menu bar follow the same numbering.
- `↑` and `↓` step through the same visible rows.
  From a selected row hidden in a collapsed group, `↓` goes to the first visible row after the group and `↑` to the last visible row before it.
  A row hidden in a folded repo or plugin section goes on from the repo's or section's place the same way.

## CLI

### Commands

| Command | Effect |
|---|---|
| `canopy group list [--repo <name>]` | list groups with their rows, in every repo or in one |
| `canopy group new <name> [--repo <name>]` | create an empty group after the repo's other groups |
| `canopy group rename <name> <new-name> [--repo <name>]` | rename a group |
| `canopy group rm <name> [--repo <name>]` | delete a group, moving its rows to the end of the ungrouped rows |
| `canopy group collapse <name> [--repo <name>]`, `canopy group expand <name> [--repo <name>]` | fold or unfold a group in the sidebar; safe to repeat |
| `canopy row move [<row>] (--group <name> \| --no-group \| --before <row> \| --after <row>) [--repo <name>]` | move a row into a group, out of one, or next to another row |
| `canopy row new <branch> [...] [--group <name>]` | create the row straight into a group |
| `canopy row list [--all]` | now shows each row's group |

- `group new`, `group rename`, `group rm`, `group collapse`, and `group expand` act on the repo resolved the usual way: `--repo`, then `CANOPY_REPO`, then the worktree containing the current folder.
- `group list` without `--repo` lists every repo's groups, like `row list`.
- `row move` resolves its row like `row rm`: the argument, a branch or a path, or else the row you are in.
  `--repo` settles a branch that exists in several repos.
- `row move` takes exactly one destination:
  - `--group <name>` puts the row at the end of that group.
  - `--no-group` puts it at the end of the ungrouped rows.
  - `--before <row>` and `--after <row>` name another Canopy or adopted row of the same repo, by branch or path, and put the row next to it, in that row's group or among the ungrouped rows.
- A move that would change nothing succeeds, logs no `row.moved`, and leaves the row where it is.
  `--group Review` for a row already in Review is such a move, so an agent can run it to make sure of a row's group without reordering it.
- `row new --group` checks the group before any git work, so a missing group fails at once and creates nothing.
  The new row goes at the end of the group.
- A group that does not exist is an error for every command, and no command creates one except `group new`.

### Output

`group list` prints one line per group, with its rows' branches in sidebar order:

```
GROUP   REPO     ROWS
Review  web-app  feat/checkout, feat/onboarding
Spikes  web-app  -
```

With `--json`, `group list` prints an array of groups, and `group new`, `group rename`, and `group rm` print one:

```json
{"repo": "web-app", "repoPath": "/Users/me/Projects/web-app", "name": "Review", "collapsed": false, "rows": [...]}
```

`rows` holds rows in the same form as `row list --json`.
`group rm` prints the group as it was just before, with the rows it let go of.
`row move --json` prints the moved row alone.

In text, the commands confirm what they did:

- `Created group Review in web-app.`
- `Renamed Review to Code review.`
- `Deleted group Review. Its 2 rows are ungrouped.`
- `Collapsed group Review in web-app.` and `Expanded group Review in web-app.`
- `Moved feat/checkout to Review.`, `Moved feat/checkout out of Review.`, or `Moved feat/checkout after fix/login.`
- `feat/checkout is already in Review.` for a move that changed nothing.

`row list` gains a GROUP column after BRANCH, with `-` for ungrouped rows.
It lists rows in sidebar order, the rows of collapsed groups included, and external rows last with `--all`.
With `--json`, each row carries `"group"` with its group's name, left out for an ungrouped row the way `"pr"` is.
`repo list` counts grouped rows among a repo's rows.

### Agent guide

`canopy agent-guide` gains a Groups section.
It lists the commands, says that groups belong to one repo and only arrange the sidebar, that a missing group is an error, and that `row move --group` is safe to repeat.
It adds an example:

```
canopy group new Review
canopy row new feat/checkout --group Review --run claude
canopy row list --json | jq -r '.[] | select(.group == "Review") | .branch'
```

## Control methods

| Method | Params | Result |
|---|---|---|
| `group.list` | `repo` | an array of groups |
| `group.new` | `target`, `name` | the group |
| `group.rename` | `target`, `name`, `newName` | the group |
| `group.remove` | `target`, `name` | the group as it was |
| `group.collapse`, `group.expand` | `target`, `name` | the group, folded or unfolded |
| `row.move` | `target`, and exactly one of `group`, `noGroup: true`, `before`, `after` | `row`, `moved`, false for a move that changed nothing, and `from`, the group it was in |
| `row.new` | gains `group` | as before, its row carrying the group |

`target` is the usual target hint.
`before` and `after` are a branch or a path, looked up among the moved row's repo.
A `row.move` request with no destination, or more than one, fails with `bad_params`.
`group.list` only reads, so `cli.call` leaves it out along with the other reads.
None of these methods runs git, so they get the default 30-second reply timeout.

## Activity events

| Type | Recorded when | `data` |
|---|---|---|
| `group.created` | a group is created | `name` |
| `group.renamed` | a group is renamed | `from`, `to` |
| `group.removed` | a group is deleted | `name`, `rows`, how many rows it let go of |
| `row.moved` | a row joins a group, leaves one, or changes group | `from`, `to`, each a group name or null for none |

- Group events carry the repo's name and path, the way `repo.added` does.
  `row.moved` carries its row, like other row events.
- `source` is `ui` or `cli`, as for other events.
- Reordering a row within its group, or among the ungrouped rows, logs no `row.moved`.
  The log records what rows are for, not where they sit.
- Deleting a group logs one `group.removed`, not a `row.moved` for each of its rows.
  Renaming one logs only `group.renamed`.
- A row created into a group logs `row.created`, then `row.moved` from null to the group.
- A row that leaves its group because it went away logs only `row.removed`.
- Folding and unfolding a group are not logged.
- A rename to the same name, or a move that changes nothing, logs nothing but its `cli.call`.

`canopy log` prints `group.created` with the name, `group.renamed` as `Review -> Code review`, `group.removed` as `Review, 2 rows`, and `row.moved` as `none -> Review`.
`--type group` matches every group event.

## Error codes

| Code | When |
|---|---|
| `invalid_group_name` | a name is empty after trimming, or holds a control character |
| `group_exists` | a new or renamed group's name matches another group in the repo, ignoring case |
| `group_not_found` | no group in the repo has that name; the message points at `canopy group list` |
| `cannot_move_main` | the row to move is the main checkout |
| `not_managed` | the row to move is an external worktree, the existing code that says to adopt it first |
| `invalid_anchor` | `--before` or `--after` names the row being moved, the main checkout, an external row, or a row in another repo |
| `bad_params` | `row.move` got no destination, or more than one |

The window shows the same messages: under the name field in the group popover, and in a toast for a failed move or drop.

## Testing

- **Unit tests** in `CanopyCore` cover:
  - decoding: files without `groups`, groups missing fields, an unreadable `groups`, and a round trip
  - names: trimming, empty names, control characters, uniqueness ignoring case, renaming to another case of the same name, and lookups ignoring case
  - the reconcile: rows gone from git or un-adopted leave their group, missing rows stay, a path listed twice keeps its first place, new rows join `rowOrder`, empty groups stay, and a branch switch keeps the group
  - moves: into, out of, and between groups, before and after rows in and out of groups, moves that change nothing, and every error code
  - the visible order, skipping collapsed groups across several repos
  - drop resolution from a pointer position: headers, row halves, the main row, places that are not targets, and drops that change nothing
  - the events each change logs, with their source, and that reorders, folds, and moves that change nothing log none
- **Git tests** against a real temporary repo: `row new` with a group puts the row straight into it, including with a refresh forced while git runs, and a missing group creates no worktree.
- **Control API tests** call each method through the in-process server, `bad_params` included.
- **End-to-end tests** in `scripts/e2e.sh` add a group, create a row into it, check the GROUP column and `"group"` in `row list`, move rows in every way, rename, delete a group and check no worktree changed, hit a missing group and a taken name, relaunch the app and check the groups came back, and read the events with `canopy log --type group`.
- **UI checks** use `scripts/ui-fixture.sh`, which gains groups, with window shots in dark and light:
  groups expanded and collapsed, a hovered header, the Move to Group menu, the name popover, a collapsed group holding the selection, and a drag in progress with its drop indicator.
  Drags are made with real posted mouse events: `scripts/ui.swift` gains `down`, `drag-to`, and `up`, so the button can stay held while a shot is taken, and each drop is checked with `canopy row list --json`.
  The `⌘N` hints are checked in a shot with a collapsed group.

## Delivery

One PR, `feat: row groups`, holds this spec, its plan, and the build.
The main spec's Sidebar rows section points here.
When the build lands, the main spec's command table, event table, and sidebar order each gain a line pointing here too.

## Decisions to review

These go beyond what was approved in conversation, each picked as the conservative option:

1. `row move --before` and `--after`, so dragging between rows has a CLI equivalent.
2. Names cannot contain control characters, and lookups ignore case.
3. No CLI command folded or unfolded a group at first, since that is view state like the ports panel's fold, but `group list --json` reported it.
   Since repos fold too, `canopy group collapse` and `canopy group expand` fold a group the way `canopy repo collapse` and `expand` fold a repo, so every fold in the sidebar has a command.
4. A collapsed group holding the selected row shows the selection on its header, and selecting a row hidden inside one, from the ports panel or the CLI, unfolds it.
5. `--group` for a row already in that group changes nothing rather than moving the row to the end.
6. Only group changes log `row.moved`, and deleting a group logs one event rather than one per row.
7. The New Row sheet gets a Group picker when the repo has groups.
8. Deleting a group asks first only when it has rows.
9. Groups cannot be reordered, and new ones go last.
10. An unreadable `groups` in `state.json` drops only the groups.
11. The main row is a drop target that means first among the ungrouped rows, so a row can leave a group by dragging even when no row is ungrouped.
