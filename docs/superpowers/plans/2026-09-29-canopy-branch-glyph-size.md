# Smaller, Lighter Row Marks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The branch, pull request, and trunk marks beside each row sit next to the 13-point row text like an SF Symbol of the same weight, instead of dominating the row.

**Architecture:** The three glyph shapes move onto one grid meant for a single 12-point frame, where a unit is half a point and every vertical line sits on an odd unit, so a 1-point stroke lands on whole pixels at 1x and 2x.
A `MarkShape` protocol shares the scaling and a `mark(_:)` modifier that strokes and frames a mark, so the sidebar rows, the drag preview, linked rows, the ports panel, and the New Row sheet all draw the same size and weight.

**Tech Stack:** Swift 6 language mode, SwiftUI on macOS 15.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Sidebar", the row line's icon, and the author's note on 2026-09-29 with a sidebar screenshot: "the branch logo for merged not merged and pr open is too thick. make it smaller."

## Global Constraints

- Every mark state (plain branch, open, draft, merged, closed, the main row's trunk, and a missing row) keeps the same size and weight, so marks swap in place when a PR opens or merges.
- State colors stay GitHub's, and stay readable in dark and light, on the plain, hovered, and selected rows, focused or not.
- The row text's leading edge does not move: the sidebar's mark column stays 16 points and the New Row sheet's stays 14.
- Lines stay crisp at 1x and 2x.
- Swift 6 strict concurrency with no warnings, and `swift format lint --strict` clean.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. A PR opening or merging on a row: the mark swaps from branch to PR glyph in the same 9 by 10 point box, so the name does not shift.
   Checked in the window shots, where branch and PR rows sit on adjacent lines.
2. A 1x display: the vertical lines are 1 pixel wide and solid, not 2 pixels at half strength.
   Checked with the prototype render at scale 1 described under UI Checks.
3. The open PR's green on the focused selection's accent fill in light mode stays readable at the thinner stroke.
   Checked in the light window shot with the open PR row selected and the sidebar focused.
4. The draft gray and a missing row's tertiary color at a 1-point stroke do not fade into the sidebar background.
   Checked in the dark and light window shots.
5. Other places that draw a row mark (drag preview, linked rows in a plugin panel, the ports panel, the New Row sheet) keep the same size as the sidebar.
   All of them go through `mark(_:)`, so none can pick another size or stroke.

The app target has no test target, and these are drawing changes, so the checks are the window shots and pixel zooms under UI Checks rather than unit tests.

## Design

The old marks were drawn on a 24-unit grid scaled into a 14-point frame with a 2-point stroke.
That stroke is about 3.4 units of the grid, much heavier than the 13-point text's stems (about 1.2 points) or an SF Symbol beside it, and 2 points at a 14/24 scale puts line edges between pixels.

Prototypes rendered at 1x and 2x beside 13-point text and SF Symbols compared 9, 10, and 11-point marks with 1 and 1.25-point strokes:

- 1.25 points is 2.5 pixels at 2x, so every line has a soft edge.
- 9 points looked undersized next to the text in the real sidebar, and 11 points with a 1-point line looked spindly.
- 10 points tall with a 1-point stroke matched the height of the text's ascenders and read closest to the SF Symbols in the plugin rows.

A 1-point line is crisp at 1x only when its center is on a half point, that is an odd unit of the half-point grid.
With the mark centered in its frame, two vertical lines on odd units must be 5 or 7 points apart, so the branch and PR marks are 9 points wide (5 points apart, circles of 3 units' radius) and 10 tall.
The PR mark's short horizontal arrow line sits level with its top commit's center on an even unit, which only softens that 1.5-point segment at 1x, where the arrowhead is a few pixels anyway.
The trunk sits on unit 11, half a point left of center, so its line is crisp too.

The arrowhead is 2 units deep and 6 tall, with its tip at unit 12, so it clears the top commit's circle and the branch's corner at this size.

## File Structure

- Modify `Sources/CanopyApp/Sidebar/BranchGlyph.swift`: `MarkShape` with `path(on:)` and `mark(_:)`, the three glyphs redrawn on the new grid, and `RowMark` drawing through `mark(_:)` with no size parameter.
- Modify `Sources/CanopyApp/Sidebar/PortsPanel.swift`: the ports panel's `RowMark` loses its own 12-point size, which is now every mark's size.
- Modify `Sources/CanopyApp/Sidebar/NewRowSheet.swift`: the sheet's PR and branch lines draw through `mark(_:)` in their 14-point column, and its own stroke goes.
- Modify `docs/superpowers/specs/2026-09-27-canopy-design.md`: the row icon's size and stroke.

## Task 1: One grid, one size, one stroke

**Files:**
- Modify: `Sources/CanopyApp/Sidebar/BranchGlyph.swift`
- Modify: `Sources/CanopyApp/Sidebar/PortsPanel.swift`
- Modify: `Sources/CanopyApp/Sidebar/NewRowSheet.swift`
- Modify: `docs/superpowers/specs/2026-09-27-canopy-design.md`

**Interfaces:**
- Produces: `protocol MarkShape: Shape { func path(on grid: inout Path) }`, and `MarkShape.mark(_ style: some ShapeStyle) -> some View`, a 12 by 12 point view.
- `RowMark(row:)` keeps its call sites; its `size` parameter goes.

- [ ] **Step 1: Replace the glyphs in `BranchGlyph.swift`**

Everything above `RowMark` becomes:

```swift
/// A branch, pull request, or trunk mark, drawn on a 24-unit grid meant for a 12-point frame, so a unit is half a
/// point. Each mark is 9 points wide and 10 tall, about the height of the row text's ascenders. The vertical lines sit
/// on odd units, so with the 1-point stroke their edges land on whole pixels at 1x and 2x.
protocol MarkShape: Shape {
    func path(on grid: inout Path)
}

extension MarkShape {
    func path(in rect: CGRect) -> Path {
        var grid = Path()
        path(on: &grid)
        let scale = min(rect.width, rect.height) / 24
        return grid.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }

    /// The mark at the one size and weight it is drawn for.
    func mark(_ style: some ShapeStyle) -> some View {
        stroke(style, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .frame(width: 12, height: 12)
    }
}

/// The git branch mark: a trunk ending in a commit, and a branch curving in from a commit at the top right.
struct BranchGlyph: MarkShape {
    func path(on grid: inout Path) {
        grid.move(to: CGPoint(x: 7, y: 3))
        grid.addLine(to: CGPoint(x: 7, y: 15))
        grid.addEllipse(in: CGRect(x: 4, y: 15, width: 6, height: 6))
        grid.addEllipse(in: CGRect(x: 14, y: 3, width: 6, height: 6))
        grid.move(to: CGPoint(x: 17, y: 9))
        grid.addQuadCurve(to: CGPoint(x: 10, y: 18), control: CGPoint(x: 17, y: 18))
    }
}

/// The pull request mark: a trunk with a commit on top, and a branch from a commit at the bottom right back towards
/// the trunk, ending in an arrow. It fills the same box as the branch mark, so the two swap cleanly.
struct PullRequestGlyph: MarkShape {
    func path(on grid: inout Path) {
        grid.addEllipse(in: CGRect(x: 4, y: 3, width: 6, height: 6))
        grid.move(to: CGPoint(x: 7, y: 9))
        grid.addLine(to: CGPoint(x: 7, y: 21))
        grid.addEllipse(in: CGRect(x: 14, y: 15, width: 6, height: 6))
        grid.move(to: CGPoint(x: 17, y: 15))
        grid.addLine(to: CGPoint(x: 17, y: 8.5))
        grid.addQuadCurve(to: CGPoint(x: 14.5, y: 6), control: CGPoint(x: 17, y: 6))
        grid.addLine(to: CGPoint(x: 12, y: 6))
        grid.move(to: CGPoint(x: 14, y: 3))
        grid.addLine(to: CGPoint(x: 12, y: 6))
        grid.addLine(to: CGPoint(x: 14, y: 9))
    }
}

/// The main checkout's mark: the trunk, a line through a commit.
struct TrunkGlyph: MarkShape {
    func path(on grid: inout Path) {
        grid.move(to: CGPoint(x: 11, y: 3))
        grid.addLine(to: CGPoint(x: 11, y: 8.5))
        grid.addEllipse(in: CGRect(x: 7.5, y: 8.5, width: 7, height: 7))
        grid.move(to: CGPoint(x: 11, y: 15.5))
        grid.addLine(to: CGPoint(x: 11, y: 21))
    }
}
```

- [ ] **Step 2: Draw `RowMark` through `mark(_:)`**

```swift
/// A row's mark: its PR in the PR's state color, the trunk for the main checkout, or a muted branch.
struct RowMark: View {
    let row: Row

    var body: some View {
        if let pr = row.pullRequest {
            PullRequestGlyph().mark(pr.state.color)
        } else if row.rowClass == .main {
            TrunkGlyph().mark(row.isMissing ? .tertiary : .secondary)
        } else {
            BranchGlyph().mark(row.isMissing ? .tertiary : .secondary)
        }
    }
}
```

- [ ] **Step 3: The ports panel and the New Row sheet**

```diff
--- a/Sources/CanopyApp/Sidebar/PortsPanel.swift
+++ b/Sources/CanopyApp/Sidebar/PortsPanel.swift
                             case .worktree(let row)?:
-                                RowMark(row: row, size: 12)
+                                RowMark(row: row)
```

```diff
--- a/Sources/CanopyApp/Sidebar/NewRowSheet.swift
+++ b/Sources/CanopyApp/Sidebar/NewRowSheet.swift
         case .pullRequest(let pr):
             PullRequestGlyph()
-                .stroke(pr.state.color, style: ItemLine.stroke)
-                .frame(width: 14, height: 14)
+                .mark(pr.state.color)
+                .frame(width: 14)
@@
         case .branch(let branch):
             BranchGlyph()
-                .stroke(.secondary, style: ItemLine.stroke)
-                .frame(width: 14, height: 14)
+                .mark(.secondary)
+                .frame(width: 14)
@@
-
-    private static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
 }
```

- [ ] **Step 4: The spec**

Under the row line's icon bullet in "Sidebar":

```markdown
  The glyphs are line drawings with a 1-point stroke, 10 points tall like the name's ascenders.
  The branch and pull request glyphs fill the same 9 by 10 point box, so one swaps for the other in place when a PR opens.
```

- [ ] **Step 5: Lint and build**

Run: `make lint && swift build 2>&1 | grep -cE "warning:|error:"`
Expected: lint prints nothing, and the count is 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/CanopyApp/Sidebar docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "fix: smaller, lighter row marks"
```

## UI Checks

Run on `make app` with `scripts/ui-fixture.sh dark` and `light`, plus, in the throwaway home only: `spike/new-parser`'s other worktree removed and made a Canopy row so the closed PR shows in the sidebar, the Later group expanded, and `python3 -m http.server` on free ports in three rows so the ports panel lists them (the fixture's own 5173 and 8080 can be taken by another agent's fixture).
Shoot the window with `scripts/window-shot.swift`, crop the sidebar rows, and zoom the mark column with nearest-neighbor scaling to judge stroke weight and pixel edges.

- Dark and light, before and after: main's trunk, merged, plain branch, closed, open selected, draft, and a grouped branch.
- The focused selection (accent fill) and the unfocused one (gray fill).
- The ports panel's marks.
- The New Row sheet's PR and branch lines.
- A prototype render of the marks at scale 1 and 2 through `ImageRenderer`, zoomed to pixels, for 1x crispness, since this Mac's display is 2x.
