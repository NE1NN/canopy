# Row Indent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every line a repo holds sits one step in under the repo's header, so the sidebar reads repo, then group, then row.

**Architecture:** A `SidebarDepth` in CanopyCore says how many steps in each sidebar line sits, and `Style.leadingInset(_:)` turns a depth into points.
Each sidebar line takes its leading inset from those two instead of its own literal, so one step is the same everywhere.
Fills stay the full width of the list, as they already are for a group's rows, and only the content moves in.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md` (Sidebar rows, Folding repos) and `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md` (its Order diagram already draws the main row one step in).

## The bug

The author's screenshot on 2026-09-29 shows the repo header's tile and the rows under it starting at the same x.
The rows do not read as the repo's children, while a group's rows do read as the group's, since they sit one step in.
In the author's words: "it should be like a bit pushed like how in a group row is aligned".

## Layout numbers

Every sidebar line is an `HStack(spacing: 8)` whose first item is 16 points wide (the tile, a row's mark, a chevron, or the warning's triangle), inside a fill that starts at the list's edge.
Content starts 7 points in from the fill's edge.
So a header's name, or a group header's name, starts at 7 + 16 + 8 = 31.

One step is therefore 24 points, the width of a mark and its gap, which is what `Style.groupIndent` already is.
With a step of 24 and content at 7 + 24 × depth:

| Line | Depth | Mark at | Name at |
|---|---|---|---|
| Repo or plugin header | 0 | 7 (tile) | 31 |
| Main row, ungrouped row, group header, PR warning, other worktrees fold, plugin row | 1 | 31 | 55 |
| A group's row, a row inside the other worktrees fold | 2 | 55 | 79 |

Each line's mark sits under the name of the header it belongs to, and each step is the same size.

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings.
- CanopyCore holds logic and no UI, CanopyApp keeps logic out of views.
- Markdown: one sentence per line, no em dashes.
- Conventional commit prefixes, no Co-Authored-By trailers.
- Two other agents change the sidebar at the same time (`fix/branch-glyph-size`, `fix/repo-menu-click`), so the diff stays on leading insets and nothing else.

## Review Focus

1. Rows inside the other worktrees fold: they belong to the fold as a group's rows belong to their group, so they sit at depth 2, not at the fold's depth.
2. The drop indicator while dragging a row: its ring must start at the mark of the depth the row would land at, 31 among the ungrouped rows and 55 in a group, or it points at the wrong level.
3. A folded repo or group holding the selection: the header's fill is unchanged, full width, so it still lines up with the fills of the rows around it.
4. Plugin sections: the plugin header works like a repo header, so its rows and its warning sit at depth 1 too.
5. Narrow sidebars: a group's branch names now start at 79 points, so long names truncate in the middle sooner; hover hints and the `x` stay at the trailing edge, where they were.

Items 1 and 2 have Core tests in Task 1, and every item is a UI check in Task 3.

---

### Task 1: `SidebarDepth` in CanopyCore

**Files:**
- Create: `Sources/CanopyCore/Rows/SidebarDepth.swift`
- Test: `Tests/CanopyCoreTests/SidebarDepthTests.swift`

**Interfaces:**
- Produces: `public enum SidebarDepth: Int { case header, section, group }`, `Row.sidebarDepth: SidebarDepth`, `DropSlot.Kind.sidebarDepth: SidebarDepth?` (nil for a group header's slot, which shows the drop as a fill and has no row depth).

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import CanopyCore

struct SidebarDepthTests {
    static func row(_ rowClass: RowClass, group: String? = nil) -> Row {
        var row = Row(repoPath: "/web", path: "/web/a", branch: "a", head: nil, rowClass: rowClass)
        row.group = group
        return row
    }

    @Test func aRepoHoldsItsRowsOneStepIn() {
        #expect(Self.row(.main).sidebarDepth == .section)
        #expect(Self.row(.canopy).sidebarDepth == .section)
        #expect(Self.row(.adopted).sidebarDepth == .section)
    }

    @Test func aGroupHoldsItsRowsTwoStepsIn() {
        #expect(Self.row(.canopy, group: "Review").sidebarDepth == .group)
        #expect(Self.row(.adopted, group: "Review").sidebarDepth == .group)
    }

    /// The other worktrees fold is a group of its own, so its rows sit under it as a group's rows do.
    @Test func otherWorktreesSitInsideTheirFold() {
        #expect(Self.row(.external).sidebarDepth == .group)
    }

    /// The drop line starts at the depth the dragged row would land at.
    @Test func dropSlotsTakeTheirRowsDepth() {
        #expect(DropSlot.Kind.main("/web").sidebarDepth == .section)
        #expect(DropSlot.Kind.row("/web/a", group: nil).sidebarDepth == .section)
        #expect(DropSlot.Kind.row("/web/a", group: "Review").sidebarDepth == .group)
        #expect(DropSlot.Kind.header("Review").sidebarDepth == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter SidebarDepthTests`
Expected: a build failure, `value of type 'Row' has no member 'sidebarDepth'`.

- [ ] **Step 3: Write the implementation**

```swift
/// How many steps in from its section's header a sidebar line sits. Each step is the same size, so the sidebar reads
/// repo, then group, then row.
public enum SidebarDepth: Int, Sendable {
    /// A repo's or a plugin's header.
    case header
    /// What a header holds: the main row, ungrouped rows, group headers, the PR warning, the other worktrees fold, and
    /// a plugin's rows.
    case section
    /// What a group or the other worktrees fold holds.
    case group
}

extension Row {
    public var sidebarDepth: SidebarDepth {
        group != nil || rowClass == .external ? .group : .section
    }
}

extension DropSlot.Kind {
    /// The depth of the row this slot is, where a row dropped beside it lands. A group's header has none, since a drop
    /// there shows as its fill.
    public var sidebarDepth: SidebarDepth? {
        switch self {
        case .main: .section
        case .row(_, let group): group == nil ? .section : .group
        case .header: nil
        }
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter SidebarDepthTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Rows/SidebarDepth.swift Tests/CanopyCoreTests/SidebarDepthTests.swift
git commit -m "feat: say how deep each sidebar line sits"
```

### Task 2: Lines take their inset from their depth

**Files:**
- Modify: `Sources/CanopyApp/Style/Style.swift` (replace `groupIndent`)
- Modify: `Sources/CanopyApp/Sidebar/SidebarView.swift` (`RepoSection.line`, `RepoHeaderView`, `RowLineView`, `OtherWorktreesToggle`, `RepoWarningView`)
- Modify: `Sources/CanopyApp/Sidebar/GroupViews.swift` (`GroupHeaderView`)
- Modify: `Sources/CanopyApp/Sidebar/RowDragAndDrop.swift` (`RowDropIndicator`)
- Modify: `Sources/CanopyApp/Plugins/PluginSectionView.swift` (`PluginHeaderView`)
- Modify: `Sources/CanopyApp/Plugins/PluginRowViews.swift` (`PluginRowLineView`)

**Interfaces:**
- Consumes: `SidebarDepth`, `Row.sidebarDepth`, `DropSlot.Kind.sidebarDepth` from Task 1.
- Produces: `Style.leadingInset(_ depth: SidebarDepth) -> Double`.

- [ ] **Step 1: Replace `groupIndent` in `Style`**

```swift
    /// One step of the sidebar's tree: a mark's width and its gap, so a line's mark sits under its header's name.
    static let indentStep = 24.0

    /// Where a sidebar line's content starts inside its fill, which always spans the list.
    static func leadingInset(_ depth: SidebarDepth) -> Double {
        7 + Double(depth.rawValue) * indentStep
    }
```

- [ ] **Step 2: Headers use depth 0**

In `RepoHeaderView` and `PluginHeaderView`, `.padding(.leading, 7)` becomes `.padding(.leading, Style.leadingInset(.header))`.
`RepoHeaderView`'s comment on the chevron no longer says the tile lines up with the rows' marks, since the marks now line up with the name:

```swift
            // The tile holds the header's mark column, so the chevron follows the name.
```

- [ ] **Step 3: A repo's own lines use depth 1**

`GroupHeaderView`, `OtherWorktreesToggle`, `RepoWarningView`, and `PluginRowLineView` each change `.padding(.leading, 7)` to `.padding(.leading, Style.leadingInset(.section))`.

- [ ] **Step 4: Rows take their own depth**

`RowLineView` drops its `indent` property and pads with `Style.leadingInset(row.sidebarDepth)`, so a group's rows and other worktrees get depth 2 without their caller saying so.
`RepoSection.line(for:)` loses its `indent` parameter, and the group's `ForEach` calls `line(for: row)`.

- [ ] **Step 5: The drop line starts at the landing depth**

```swift
        if let slot = pluginSlots.first(where: { $0.path == path }) {
            return (below ? slot.maxY : slot.minY, .section)
        }
        guard let slot = slots.first(where: { $0.kind.rowPath == path }), let depth = slot.kind.sidebarDepth else {
            return nil
        }
        return (below ? slot.maxY : slot.minY, depth)
```

with `placement` returning `(Double, SidebarDepth)?` and `let leading = Style.leadingInset(depth)`.

- [ ] **Step 6: Build and lint**

Run: `make lint && make build 2>&1 | grep -c "warning:"`
Expected: lint clean, 0 warnings.

- [ ] **Step 7: Commit**

```bash
git commit -am "fix: indent rows under their repo"
```

### Task 3: Spec and UI checks

**Files:**
- Modify: `docs/superpowers/specs/2026-09-27-canopy-design.md` (Sidebar rows, Folding repos)

- [ ] **Step 1: Amend the spec**

Sidebar rows gains a paragraph on depth after the repo header's description:

```markdown
Everything a repo holds sits one step in under its header: the main row, ungrouped rows, group headers, the PR warning, and the other worktrees fold.
A group's rows, and the rows the other worktrees fold shows, sit a second step in.
A step is a mark's width and its gap, so each line's mark sits under the name of the header it belongs to, and the sidebar reads repo, then group, then row.
A plugin's section works the same way: its warning and rows sit one step in under its header.
Fills for hover and selection still span the list's width at every depth.
```

Folding repos' chevron bullet stops saying the tile lines up with the rows' marks:

```markdown
  It follows the name rather than sitting in the mark column, because the tile holds that column.
```

- [ ] **Step 2: UI checks**

`make app`, then `scripts/ui-fixture.sh dark` and `scripts/ui-fixture.sh light`.
The fixture has three repos with api-server folded, web-app's Review group open and Later folded, other worktrees, PR rows in every state, agent dots, a selected row, and two plugin sections.
Shoot the window with `swift scripts/window-shot.swift <pid>` before (on origin/main) and after, and crop the sidebar.
Check in both appearances:
- the main row's mark sits under the repo name's leading edge, and a group's rows' marks under the group's name
- the group chevron sits in the same column as the main row's mark
- the selection and hover fills start at the list's edge at every depth, and a folded header holding the selection lines up with them
- the `⌘N` hint, the `x`, PR numbers, link chips, and agent dots stay at the trailing edge
- other worktrees, expanded, sit one step in under the fold's chevron
- plugin rows and the plugin warning sit one step in under the plugin's name
- dragging a row shows the drop line's ring at the mark of the depth it would land at

- [ ] **Step 3: Commit**

```bash
git commit -am "docs: rows sit one step in under their repo"
```

## Decisions to review

- Rows inside the other worktrees fold sit two steps in, under the fold, as a group's rows do, instead of level with the fold.
- Fills keep spanning the list's width at every depth, as a group's rows already did, rather than starting at the indent.
- The step stays 24 points, the existing group indent, so a line's mark sits under its header's name.
