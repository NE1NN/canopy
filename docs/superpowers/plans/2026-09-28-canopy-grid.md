# Canopy Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a tab hold a tiling grid of terminals that can be split with the add rule, resized, rearranged by dragging, navigated with the keyboard, and restored on relaunch.

**Architecture:** All layout math lives in `CanopyCore` as pure functions on a generic `Layout` tree, tested without UI.
`TerminalTab` holds a `Layout<PaneID>` and its panes, and `TerminalStore` saves every row's tabs as `SavedRowTerminals` in `state.json`.
The app places panes with SwiftUI at the frames the core computes, keyed by pane so terminals are never rebuilt.

**Tech Stack:** Swift 6.2, SwiftUI and AppKit on macOS 15, SwiftTerm 1.20.0 through the existing emulator, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, sections "Tabs and the grid" and "Persistence".

## Global Constraints

The constraints of `docs/superpowers/plans/2026-09-28-canopy-terminals-tabs.md` still hold.
In addition:
- The add rule's minimum pane width is 80 columns in the terminal font plus pane padding, configurable as `minPaneColumns` in `CANOPY_HOME/config.json`.
- Manual resizing keeps every pane at least 20 columns and 5 rows.
- Dropping a pane on the outer quarter of another's edge splits that pane 50/50 on that side; the middle swaps them.
- Keys: `⌘D` adds a pane by the add rule, `⌘⌥` and an arrow focuses the neighboring pane.
- `state.json` is written about a second after a change and again on quit. Pane folders are read from the shell at save time. Launch rebuilds layouts with fresh shells and never re-runs commands.

## Review Focus

1. **A narrow window** must keep adding panes as new lines rather than squeezing a line below the minimum width. Pinned by `narrowTabsWrapSooner` in Task 1.
2. **Resizing into a nested split** must stop at the nested panes' minimums, not only the direct neighbor's. Pinned by `resizingClampsBothSidesToTheirMinimums` in Task 1.
3. **Neighbor ties**, such as pressing up from a full-width pane under two panes, must pick the same pane every time. Pinned by `neighborsAreFoundByPosition` in Task 1 across repeated runs.
4. **A saved folder that no longer exists** must restore into the row's folder, not fail or land in `/`. Pinned by `restoringIntoAFolderThatIsGoneUsesTheRowsFolder` in Task 2.
5. **An older `state.json` without layouts** must still load. Pinned by `stateFileKeepsTerminalsAndOldFilesStillLoad` in Task 2.

## Decisions Made While Planning

- **SwiftUI places the panes, not an AppKit grid view.** The spec chose AppKit for view-level control of drag, drop, and resize. With the frames coming from the core, SwiftUI's `DragGesture` on 7-point divider grips, `onDrag` on pane headers, and a `DropDelegate` that reports the pointer's position give that control. Checked in the running app: dividers resize, a dragged header lands on the right edge zone, and every terminal keeps its screen.
- **`Layout` is generic over its leaves**, so the same tree holds live `PaneID`s and saved `SavedPane` folders.
- **Rows are restored eagerly on launch**, as the spec says, before the first selection, so a restored row does not also get a fresh terminal.
- **Quitting saves before the terminals close**: `applicationShouldTerminate` returns `.terminateLater`, saves with every pane's current folder, then replies.
- **Focus follows the first responder.** Clicking into a pane focuses it in the store, and keyboard focus moves (`⌘⌥` arrows, closing a pane, splitting) hand the keyboard to the newly focused terminal.

## After Review

An independent review of the branch found no blockers. Its fixes are folded into the tasks above:
- Setup and teardown track their own pane, so panes split off the Setup tab survive setup finishing.
- Nothing is saved until saved layouts are restored, and rows missing at launch keep their saved tabs until they return.
- A same-axis split's minimum size accounts for unequal shares, and a pair that cannot fit its minimums does not jump.
- Negative or non-finite shares are rejected, and a `state.json` whose layouts cannot be read still loads its repos.
- Only Canopy's own pane drags are accepted as drops, and dividers do not jump when grabbed off center.

## Every PR

- Start from the latest `main` after PR 5 merged: `git switch main && git pull --ff-only && git switch -c feat/grid`.
- Before pushing, run `make lint && make build && make test && make e2e`.

---

## Task 1: Layout math

**Files:**
- Create: `Sources/CanopyCore/Layout/Layout.swift`, `Sources/CanopyCore/Layout/LayoutGeometry.swift`
- Test: `Tests/CanopyCoreTests/LayoutTests.swift`

**Interfaces:**
- Produces: `Axis`, `Edge`, `Direction`, `Layout<Leaf>` (`.leaf`, `.split`, `leaves`, `contains`, `map`, `normalized()`, `adding(_:fits:)`, `removing(_:)`, `swapping(_:_:)`, `moving(_:to:of:)`, `frames(in:)`, `dividers(in:)`, `resizing(_:to:in:minimum:)`, `neighbor(of:toward:in:)`), `DividerID`, `LayoutDivider`, `DropZone.at(_:in:)`, and `Codable` for layouts of `Codable` leaves.

- [ ] **Step 1: Write the failing tests**

The add rule tests are the spec's own wide and narrow sequences.

`Tests/CanopyCoreTests/LayoutTests.swift` (new):

```swift
import CoreGraphics
import Foundation
import Testing

@testable import CanopyCore

typealias Grid = Layout<String>

extension Layout {
    /// Adds each leaf in turn with the add rule, where a line may hold up to `perLine` panes.
    static func built(_ leaves: [Leaf], perLine: Int) -> Layout {
        var layout = Layout.leaf(leaves[0])
        for leaf in leaves.dropFirst() {
            layout = layout.adding(leaf, fits: { $0 <= perLine })
        }
        return layout
    }
}

struct LayoutTests {
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func wideTabsFillTheLineThenWrap() {
        #expect(Grid.built(["A", "B"], perLine: 3) == .split(.row, [.leaf("A"), .leaf("B")], [0.5, 0.5]))
        #expect(
            Grid.built(["A", "B", "C"], perLine: 3) == .split(.row, ["A", "B", "C"].map(Grid.leaf), Grid.equal(3)))
        #expect(
            Grid.built(["A", "B", "C", "D"], perLine: 3)
                == .split(
                    .column, [.split(.row, ["A", "B", "C"].map(Grid.leaf), Grid.equal(3)), .leaf("D")], [0.5, 0.5]))
    }

    @Test func narrowTabsWrapSooner() {
        let row = Grid.split(.row, [.leaf("A"), .leaf("B")], [0.5, 0.5])
        #expect(Grid.built(["A", "B", "C"], perLine: 2) == .split(.column, [row, .leaf("C")], [0.5, 0.5]))
        #expect(
            Grid.built(["A", "B", "C", "D"], perLine: 2)
                == .split(.column, [row, .split(.row, [.leaf("C"), .leaf("D")], [0.5, 0.5])], [0.5, 0.5]))
    }

    @Test func growingTheBottomLineKeepsLineHeights() {
        let layout = Grid.split(.column, [.leaf("A"), .leaf("B")], [0.7, 0.3])

        #expect(
            layout.adding("C", fits: { _ in true })
                == .split(.column, [.leaf("A"), .split(.row, [.leaf("B"), .leaf("C")], [0.5, 0.5])], [0.7, 0.3]))
    }

    @Test func normalizingDropsLoneSplitsAndMergesSameAxis() {
        let nested = Grid.split(.row, [.leaf("A"), .split(.row, [.leaf("B"), .leaf("C")], [0.5, 0.5])], [0.5, 0.5])
        #expect(nested.normalized() == .split(.row, ["A", "B", "C"].map(Grid.leaf), [0.5, 0.25, 0.25]))
        #expect(Grid.split(.column, [.leaf("A")], [1]).normalized() == .leaf("A"))
    }

    @Test func removingGivesSiblingsTheSpaceInProportion() {
        let layout = Grid.split(.row, ["A", "B", "C"].map(Grid.leaf), [0.5, 0.3, 0.2])

        #expect(layout.removing("A") == .split(.row, [.leaf("B"), .leaf("C")], [0.6, 0.4]))
        #expect(Grid.split(.row, [.leaf("A"), .leaf("B")], [0.5, 0.5]).removing("A") == .leaf("B"))
        #expect(Grid.leaf("A").removing("A") == nil)
        #expect(layout.removing("Z") == layout)
    }

    @Test func droppingOnAnEdgeSplitsTheTargetInHalf() {
        let layout = Grid.split(.row, ["A", "B", "C"].map(Grid.leaf), Grid.equal(3))

        #expect(
            layout.moving("A", to: .bottom, of: "C")
                == .split(.row, [.leaf("B"), .split(.column, [.leaf("C"), .leaf("A")], [0.5, 0.5])], [0.5, 0.5]))
        #expect(
            layout.moving("C", to: .left, of: "A")
                == .split(.row, ["C", "A", "B"].map(Grid.leaf), [0.25, 0.25, 0.5]))
        #expect(layout.moving("A", to: .left, of: "A") == layout)
        #expect(layout.swapping("A", "C") == .split(.row, ["C", "B", "A"].map(Grid.leaf), Grid.equal(3)))
    }

    @Test func framesAndDividersFollowTheShares() {
        let layout = Grid.split(
            .column, [.split(.row, [.leaf("A"), .leaf("B")], [0.25, 0.75]), .leaf("C")], [0.5, 0.5])

        let frames = layout.frames(in: rect)
        #expect(frames["A"] == CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(frames["B"] == CGRect(x: 300, y: 0, width: 900, height: 400))
        #expect(frames["C"] == CGRect(x: 0, y: 400, width: 1200, height: 400))
        let dividers = layout.dividers(in: rect)
        #expect(dividers.map(\.id) == [DividerID(path: [], index: 0), DividerID(path: [0], index: 0)])
        #expect(dividers[1].line == CGRect(x: 300, y: 0, width: 0, height: 400))
    }

    @Test func resizingClampsBothSidesToTheirMinimums() {
        let layout = Grid.split(
            .row, [.leaf("A"), .split(.column, [.leaf("B"), .leaf("C")], [0.5, 0.5])], [0.5, 0.5])
        let divider = DividerID(path: [], index: 0)
        let minimum = CGSize(width: 200, height: 100)

        #expect(layout.resizing(divider, to: 300, in: rect, minimum: minimum).frames(in: rect)["A"]?.width == 300)
        #expect(layout.resizing(divider, to: 50, in: rect, minimum: minimum).frames(in: rect)["A"]?.width == 200)
        #expect(layout.resizing(divider, to: 1150, in: rect, minimum: minimum).frames(in: rect)["A"]?.width == 1000)

        let inner = DividerID(path: [1], index: 0)
        let squeezed = layout.resizing(inner, to: 790, in: rect, minimum: minimum).frames(in: rect)
        #expect(squeezed["C"]?.height == 100)
    }

    @Test func resizingRespectsUnequalNestedShares() {
        let nested = Grid.split(.row, [.leaf("C"), .leaf("D")], [0.8, 0.2])
        let layout = Grid.split(.row, [.leaf("X"), .split(.column, [nested, .leaf("E")], [0.5, 0.5])], [0.5, 0.5])
        let minimum = CGSize(width: 200, height: 100)

        let frames = layout.resizing(DividerID(path: [], index: 0), to: 1150, in: rect, minimum: minimum)
            .frames(in: rect)

        #expect(frames["D"].map { $0.width >= 199.9 } == true)
    }

    @Test func aPairTooSmallForItsMinimumsStaysPut() {
        let layout = Grid.split(.row, [.leaf("A"), .leaf("B")], [0.3, 0.7])
        let small = CGRect(x: 0, y: 0, width: 300, height: 800)

        #expect(
            layout.resizing(DividerID(path: [], index: 0), to: 250, in: small, minimum: CGSize(width: 200, height: 100))
                == layout)
    }

    @Test func neighborsAreFoundByPosition() {
        let layout = Grid.split(
            .column, [.split(.row, [.leaf("A"), .leaf("B")], [0.5, 0.5]), .leaf("C")], [0.5, 0.5])

        #expect(layout.neighbor(of: "A", toward: .right, in: rect) == "B")
        #expect(layout.neighbor(of: "B", toward: .down, in: rect) == "C")
        #expect(layout.neighbor(of: "C", toward: .up, in: rect) == "A")
        #expect(layout.neighbor(of: "A", toward: .left, in: rect) == nil)
    }

    @Test func dropZonesAreTheOuterQuartersAndTheMiddle() {
        let pane = CGRect(x: 100, y: 100, width: 400, height: 200)

        #expect(DropZone.at(CGPoint(x: 120, y: 200), in: pane) == .edge(.left))
        #expect(DropZone.at(CGPoint(x: 480, y: 200), in: pane) == .edge(.right))
        #expect(DropZone.at(CGPoint(x: 300, y: 110), in: pane) == .edge(.top))
        #expect(DropZone.at(CGPoint(x: 300, y: 290), in: pane) == .edge(.bottom))
        #expect(DropZone.at(CGPoint(x: 300, y: 200), in: pane) == .center)
        #expect(DropZone.at(CGPoint(x: 50, y: 50), in: pane) == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let layout = Grid.built(["A", "B", "C", "D"], perLine: 2)

        let decoded = try JSONDecoder().decode(Grid.self, from: JSONEncoder().encode(layout))

        #expect(decoded == layout)
        for bad in [
            #"{"axis": "row", "children": [], "fractions": []}"#,
            #"{"axis": "row", "children": [{"pane": "A"}, {"pane": "B"}], "fractions": [-0.5, 1.5]}"#,
        ] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Grid.self, from: Data(bad.utf8)) }
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter LayoutTests`
Expected: build failure, `cannot find type 'Layout' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Layout/Layout.swift` (new):

```swift
import CoreGraphics

public enum Axis: String, Codable, Sendable {
    /// Children side by side, left to right.
    case row
    /// Children stacked, top to bottom.
    case column
}

public enum Edge: Sendable, CaseIterable {
    case left, right, top, bottom

    var axis: Axis { self == .left || self == .right ? .row : .column }
    var putsMovedFirst: Bool { self == .left || self == .top }
}

/// A tab's arrangement of panes: a single pane, or a split whose children each take a share of its extent.
/// Every operation returns a normalized layout: no split has one child, and no split sits directly inside a
/// split of the same axis.
public indirect enum Layout<Leaf: Hashable & Sendable>: Hashable, Sendable {
    case leaf(Leaf)
    /// Children in order, with their shares of the split's width (row) or height (column). Shares sum to 1.
    case split(Axis, [Layout], [Double])

    public var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }

    public func contains(_ leaf: Leaf) -> Bool {
        leaves.contains(leaf)
    }

    public func map<T: Hashable & Sendable>(_ transform: (Leaf) -> T) -> Layout<T> {
        switch self {
        case .leaf(let leaf): .leaf(transform(leaf))
        case .split(let axis, let children, let fractions): .split(axis, children.map { $0.map(transform) }, fractions)
        }
    }

    public func normalized() -> Layout {
        guard case .split(let axis, let children, let fractions) = self else { return self }
        var mergedChildren: [Layout] = []
        var mergedFractions: [Double] = []
        for (child, fraction) in zip(children.map { $0.normalized() }, fractions) {
            if case .split(let childAxis, let grandchildren, let childFractions) = child, childAxis == axis {
                mergedChildren += grandchildren
                mergedFractions += childFractions.map { $0 * fraction }
            } else {
                mergedChildren.append(child)
                mergedFractions.append(fraction)
            }
        }
        if mergedChildren.count == 1 { return mergedChildren[0] }
        let total = mergedFractions.reduce(0, +)
        return .split(
            axis, mergedChildren, mergedFractions.map { total > 0 ? $0 / total : 1 / Double(mergedFractions.count) })
    }

    // MARK: Adding, removing, moving

    /// The add rule: fill the bottom line of panes to the right while `fits` says a line of that many panes keeps
    /// each wide enough, then start a new line below. Lines and the panes in a grown line get equal shares.
    public func adding(_ leaf: Leaf, fits: (Int) -> Bool) -> Layout {
        var lines: [Layout]
        if case .split(.column, let children, _) = self {
            lines = children
        } else {
            lines = [self]
        }
        let lastLine = lines[lines.count - 1]
        var lastLineCount = 2
        if case .split(.row, let children, _) = lastLine {
            lastLineCount = children.count + 1
        }
        if fits(lastLineCount) {
            var panes = [lastLine]
            if case .split(.row, let children, _) = lastLine {
                panes = children
            }
            panes.append(.leaf(leaf))
            lines[lines.count - 1] = .split(.row, panes, Self.equal(panes.count))
            return lines.count == 1 ? lines[0].normalized() : .split(.column, lines, lineFractions).normalized()
        }
        lines.append(.leaf(leaf))
        return Layout.split(.column, lines, Self.equal(lines.count)).normalized()
    }

    /// Existing line heights stay as they were when the add rule grows the bottom line.
    private var lineFractions: [Double] {
        if case .split(.column, _, let fractions) = self { return fractions }
        return [1]
    }

    /// Removes a pane. Its siblings take its space in proportion to their shares. Nil when nothing is left.
    public func removing(_ leaf: Leaf) -> Layout? {
        switch self {
        case .leaf(let own):
            return own == leaf ? nil : self
        case .split(let axis, let children, let fractions):
            var keptChildren: [Layout] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removing(leaf) {
                    keptChildren.append(kept)
                    keptFractions.append(fraction)
                }
            }
            guard !keptChildren.isEmpty else { return nil }
            return Layout.split(axis, keptChildren, keptFractions).normalized()
        }
    }

    public func swapping(_ first: Leaf, _ second: Leaf) -> Layout {
        map { $0 == first ? second : $0 == second ? first : $0 }
    }

    /// Takes `leaf` out and splits `target` on `edge`, 50/50, with `leaf` on that side.
    public func moving(_ leaf: Leaf, to edge: Edge, of target: Leaf) -> Layout {
        guard leaf != target, contains(target), let rest = removing(leaf) else { return self }
        return rest.replacing(target) { targetLayout in
            let pair: [Layout] = edge.putsMovedFirst ? [.leaf(leaf), targetLayout] : [targetLayout, .leaf(leaf)]
            return .split(edge.axis, pair, [0.5, 0.5])
        }
        .normalized()
    }

    private func replacing(_ leaf: Leaf, with make: (Layout) -> Layout) -> Layout {
        switch self {
        case .leaf(let own):
            return own == leaf ? make(self) : self
        case .split(let axis, let children, let fractions):
            return .split(axis, children.map { $0.replacing(leaf, with: make) }, fractions)
        }
    }

    static func equal(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(count), count: count)
    }
}

extension Layout: Codable where Leaf: Codable {
    private enum CodingKeys: String, CodingKey {
        case pane, axis, children, fractions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let leaf = try container.decodeIfPresent(Leaf.self, forKey: .pane) {
            self = .leaf(leaf)
            return
        }
        let axis = try container.decode(Axis.self, forKey: .axis)
        let children = try container.decode([Layout].self, forKey: .children)
        let fractions = try container.decode([Double].self, forKey: .fractions)
        guard !children.isEmpty, children.count == fractions.count,
            fractions.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .fractions, in: container, debugDescription: "A split needs one positive share per child.")
        }
        self = Layout.split(axis, children, fractions).normalized()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let leaf):
            try container.encode(leaf, forKey: .pane)
        case .split(let axis, let children, let fractions):
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
            try container.encode(fractions, forKey: .fractions)
        }
    }
}
```

`Sources/CanopyCore/Layout/LayoutGeometry.swift` (new):

```swift
import CoreGraphics

/// A boundary between two neighboring children of one split: the split's path from the root, as child indexes,
/// and the index of the child before the boundary.
public struct DividerID: Hashable, Sendable {
    public var path: [Int]
    public var index: Int

    public init(path: [Int], index: Int) {
        self.path = path
        self.index = index
    }
}

public struct LayoutDivider: Hashable, Sendable {
    public var id: DividerID
    /// The axis of the split, so a `row` divider is a vertical line dragged left and right.
    public var axis: Axis
    /// The line itself: zero wide for `row`, zero tall for `column`.
    public var line: CGRect
}

public enum Direction: Sendable {
    case left, right, up, down
}

public enum DropZone: Hashable, Sendable {
    case edge(Edge)
    case center

    /// The outer quarter along each edge splits the target on that side. The middle swaps the two panes.
    public static func at(_ point: CGPoint, in rect: CGRect) -> DropZone? {
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        let distances: [(Edge, Double)] = [
            (.left, (point.x - rect.minX) / rect.width),
            (.right, (rect.maxX - point.x) / rect.width),
            (.top, (point.y - rect.minY) / rect.height),
            (.bottom, (rect.maxY - point.y) / rect.height),
        ]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 0.25 ? .edge(nearest.0) : .center
    }
}

extension Layout {
    /// Where each pane goes in `rect`, whose origin is its top-left corner.
    public func frames(in rect: CGRect) -> [Leaf: CGRect] {
        var frames: [Leaf: CGRect] = [:]
        visit(rect, path: []) { layout, rect, _ in
            if case .leaf(let leaf) = layout { frames[leaf] = rect }
        }
        return frames
    }

    public func dividers(in rect: CGRect) -> [LayoutDivider] {
        var dividers: [LayoutDivider] = []
        visit(rect, path: []) { layout, rect, path in
            guard case .split(let axis, _, let fractions) = layout else { return }
            var offset = 0.0
            for index in 0..<(fractions.count - 1) {
                offset += fractions[index]
                let line =
                    axis == .row
                    ? CGRect(x: rect.minX + rect.width * offset, y: rect.minY, width: 0, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + rect.height * offset, width: rect.width, height: 0)
                dividers.append(LayoutDivider(id: DividerID(path: path, index: index), axis: axis, line: line))
            }
        }
        return dividers
    }

    /// Moves a divider to `position`, an x for `row` splits and a y for `column` splits, keeping every pane on
    /// both sides at least `minimum` in size where the space allows.
    public func resizing(_ divider: DividerID, to position: Double, in rect: CGRect, minimum: CGSize) -> Layout {
        guard let splitRect = locate(divider.path, in: rect) else { return self }
        return updatingSplit(at: divider.path[...]) { axis, children, fractions in
            let index = divider.index
            guard index + 1 < children.count else { return fractions }
            let extent = axis == .row ? splitRect.width : splitRect.height
            let origin = axis == .row ? splitRect.minX : splitRect.minY
            guard extent > 0 else { return fractions }
            let before = fractions[..<index].reduce(0, +)
            let pair = fractions[index] + fractions[index + 1]
            let lowest = children[index].minimumExtent(along: axis, minimum: minimum) / extent
            let highest = pair - children[index + 1].minimumExtent(along: axis, minimum: minimum) / extent
            var share = (position - origin) / extent - before
            // When the pair cannot fit both minimums, leave it as it is rather than jump.
            guard highest >= lowest - 1e-9 else { return fractions }
            share = min(max(share, lowest), highest)
            var updated = fractions
            updated[index] = share
            updated[index + 1] = pair - share
            return updated
        }
    }

    /// The pane next to `leaf` in `direction`: one that touches it on that side and overlaps it across, preferring
    /// the one level with its middle.
    public func neighbor(of leaf: Leaf, toward direction: Direction, in rect: CGRect) -> Leaf? {
        let frames = frames(in: rect)
        guard let source = frames[leaf] else { return nil }
        let tolerance = 1.0
        let candidates = frames.filter { other, frame in
            guard other != leaf else { return false }
            switch direction {
            case .left: return abs(frame.maxX - source.minX) <= tolerance && overlap(frame, source, .column) > 0
            case .right: return abs(frame.minX - source.maxX) <= tolerance && overlap(frame, source, .column) > 0
            case .up: return abs(frame.maxY - source.minY) <= tolerance && overlap(frame, source, .row) > 0
            case .down: return abs(frame.minY - source.maxY) <= tolerance && overlap(frame, source, .row) > 0
            }
        }
        let across: Axis = direction == .left || direction == .right ? .column : .row
        let middle = across == .column ? source.midY : source.midX
        // Prefer the pane level with the source's middle, then the one sharing the longest edge, then the one
        // further left or up, so ties never depend on dictionary order.
        func rank(_ frame: CGRect) -> (Bool, Double, Double) {
            let range = across == .column ? frame.minY...frame.maxY : frame.minX...frame.maxX
            return (range.contains(middle), overlap(frame, source, across), across == .column ? frame.minY : frame.minX)
        }
        return candidates.min { first, second in
            let (firstLevel, firstOverlap, firstPosition) = rank(first.value)
            let (secondLevel, secondOverlap, secondPosition) = rank(second.value)
            if firstLevel != secondLevel { return firstLevel }
            if firstOverlap != secondOverlap { return firstOverlap > secondOverlap }
            return firstPosition < secondPosition
        }?.key
    }

    // MARK: Internals

    private func visit(_ rect: CGRect, path: [Int], _ body: (Layout, CGRect, [Int]) -> Void) {
        body(self, rect, path)
        guard case .split(let axis, let children, let fractions) = self else { return }
        var offset = 0.0
        for (index, (child, fraction)) in zip(children, fractions).enumerated() {
            let childRect =
                axis == .row
                ? CGRect(
                    x: rect.minX + rect.width * offset, y: rect.minY, width: rect.width * fraction, height: rect.height)
                : CGRect(
                    x: rect.minX, y: rect.minY + rect.height * offset, width: rect.width, height: rect.height * fraction
                )
            child.visit(childRect, path: path + [index], body)
            offset += fraction
        }
    }

    private func locate(_ path: [Int], in rect: CGRect) -> CGRect? {
        var found: CGRect?
        visit(rect, path: []) { _, rect, visited in
            if visited == path { found = rect }
        }
        return found
    }

    private func updatingSplit(
        at path: ArraySlice<Int>, _ update: (Axis, [Layout], [Double]) -> [Double]
    ) -> Layout {
        guard case .split(let axis, var children, let fractions) = self else { return self }
        guard let first = path.first else { return .split(axis, children, update(axis, children, fractions)) }
        guard children.indices.contains(first) else { return self }
        children[first] = children[first].updatingSplit(at: path.dropFirst(), update)
        return .split(axis, children, fractions)
    }

    /// The least width (row) or height (column) this subtree needs so each pane keeps `minimum`.
    func minimumExtent(along axis: Axis, minimum: CGSize) -> Double {
        switch self {
        case .leaf:
            return axis == .row ? minimum.width : minimum.height
        case .split(let splitAxis, let children, let fractions):
            let extents = children.map { $0.minimumExtent(along: axis, minimum: minimum) }
            guard splitAxis == axis else { return extents.max() ?? 0 }
            // Each child keeps its share as the whole grows or shrinks, so the tightest child sets the minimum.
            return zip(extents, fractions).map { $1 > 0 ? $0 / $1 : .infinity }.max() ?? 0
        }
    }
}

private func overlap(_ first: CGRect, _ second: CGRect, _ axis: Axis) -> Double {
    axis == .column
        ? min(first.maxY, second.maxY) - max(first.minY, second.minY)
        : min(first.maxX, second.maxX) - max(first.minX, second.minX)
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, four times.
Expected: all tests pass every time, 13 more than before this task.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Layout Tests/CanopyCoreTests/LayoutTests.swift
git commit -m "feat: tiling layout math for tabs"
```

## Task 2: Tabs hold a grid that is saved and restored

`TerminalTab` swaps its single pane for a layout, its panes, and a focused pane.
Code that used `tab.pane` for a freshly opened tab now uses `tab.focused`.

**Files:**
- Modify: `Sources/CanopyCore/Terminal/TerminalStore.swift` (rewritten), `Pane.swift`, `PtyProcess.swift`, `TerminalIDs.swift`, `TerminalEmulator.swift`
- Create: `Sources/CanopyCore/State/SavedTerminals.swift`, `Sources/CanopyCore/State/GlobalConfig.swift`
- Modify: `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `Sources/CanopyCore/Rows/RowLifecycle.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`, `RowTerminalsView.swift`, `TabBarView.swift` (the `tab.focused` rename only)
- Test: `Tests/CanopyCoreTests/GridStoreTests.swift` and the renamed uses in existing tests

**Interfaces:**
- Consumes: Task 1's `Layout`.
- Produces: `TerminalTab.layout`, `panes`, `focusedPaneID`, `paneList`, `focused`; `TerminalStore.onChange`, `openTab(for:name:command:directory:)`, `addPane(for:fits:)`, `closePane(_:)`, `focus(_:)`, `focusNeighbor(inRow:toward:in:)`, `movePane(_:to:of:)`, `resize(_:divider:to:in:minimum:)`, `tab(containing:)`, `saved()`, `restore(_:for:)`; `Pane.startDirectory`, `Pane.currentDirectory`; `PtyProcess.currentDirectory(of:)`; `PaneID.init?(_ text:)`; `BusyTerminals.closeWarning(_:)`; `SavedPane`, `SavedTab`, `SavedRowTerminals`; `AppState.terminals`; `Workspace.savedTerminals`, `setSavedTerminals(_:)`; `GlobalConfig.load(from:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/GridStoreTests.swift` (new):

```swift
import CoreGraphics
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct GridStoreTests {
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func addingPanesFollowsTheAddRuleAndFocusesTheNewOne() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context)

        let second = terminals.addPane(for: context, fits: { $0 <= 2 })
        let third = terminals.addPane(for: context, fits: { $0 <= 2 })

        #expect(tab.paneList.count == 3)
        #expect(tab.focusedPaneID == third.id)
        #expect(
            tab.layout
                == .split(
                    .column,
                    [.split(.row, [.leaf(tab.paneList[0].id), .leaf(second.id)], [0.5, 0.5]), .leaf(third.id)],
                    [0.5, 0.5]))
    }

    @Test func closingAPaneFocusesItsNeighborAndTheLastClosesTheTab() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context)
        let first = tab.focused
        let second = terminals.addPane(for: context, fits: { _ in true })

        terminals.closePane(second.id)
        #expect(tab.focusedPaneID == first.id)
        #expect(tab.layout == .leaf(first.id))
        #expect(second.status == .exited(Pane.closedExitCode))

        terminals.closePane(first.id)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
    }

    @Test func movingSwappingAndFocusingNeighbors() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context)
        let a = tab.focused.id
        let b = terminals.addPane(for: context, fits: { _ in true }).id

        terminals.movePane(a, to: .edge(.bottom), of: b)
        #expect(tab.layout == .split(.column, [.leaf(b), .leaf(a)], [0.5, 0.5]))
        terminals.movePane(a, to: .center, of: b)
        #expect(tab.layout == .split(.column, [.leaf(a), .leaf(b)], [0.5, 0.5]))

        terminals.focus(a)
        #expect(terminals.focusNeighbor(inRow: dir.path, toward: .down, in: rect)?.id == b)
        #expect(tab.focusedPaneID == b)
        #expect(terminals.focusNeighbor(inRow: dir.path, toward: .down, in: rect) == nil)
    }

    @Test func resizingGoesThroughTheLayoutClamps() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tab = terminals.openTab(for: context)
        terminals.addPane(for: context, fits: { _ in true })

        terminals.resize(
            tab, divider: DividerID(path: [], index: 0), to: 10, in: rect, minimum: CGSize(width: 300, height: 100))

        #expect(tab.layout.frames(in: rect)[tab.paneList[0].id]?.width == 300)
    }

    @Test func savedTabsRestoreWithFreshShellsInTheirFolders() async throws {
        let dir = try TempDir()
        let sub = dir.sub("sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let server = terminals.openTab(for: context)
        terminals.renameTab(server.id, inRow: dir.path, to: "Server")
        let moved = terminals.addPane(for: context, fits: { _ in true })
        terminals.openTab(for: context)
        terminals.selectTab(server.id, inRow: dir.path)
        await moved.run("cd sub")
        #expect(await eventually { moved.currentDirectory == sub })

        let saved = try #require(terminals.saved()[dir.path])
        terminals.closeAll()
        let restored = Fixture.terminals(dir)
        defer { restored.closeAll() }
        restored.restore(saved, for: context)

        let tabs = restored.tabs(inRow: dir.path)
        #expect(tabs.map(\.name) == ["Server", "Terminal"])
        #expect(restored.selectedTab(inRow: dir.path)?.name == "Server")
        let panes = tabs[0].paneList
        #expect(panes.count == 2)
        #expect(tabs[0].focusedPaneID == panes[1].id)
        #expect(await eventually { panes[1].currentDirectory == sub })
        #expect(await eventually { panes[0].currentDirectory == dir.path })
    }

    @Test func restoringIntoAFolderThatIsGoneUsesTheRowsFolder() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let saved = SavedRowTerminals(
            tabs: [SavedTab(name: "Terminal", layout: .leaf(SavedPane(folder: dir.sub("gone"))), focused: 0)],
            selectedTab: 3)

        terminals.restore(saved, for: Fixture.context(dir.path))

        let pane = try #require(terminals.selectedTab(inRow: dir.path)?.focused)
        #expect(await eventually { pane.currentDirectory == dir.path })
    }

    @Test func changesAreReported() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        var changes = 0
        terminals.onChange = { changes += 1 }

        let tab = terminals.openTab(for: Fixture.context(dir.path))
        terminals.renameTab(tab.id, inRow: dir.path, to: "Build")
        terminals.closeTab(tab.id, inRow: dir.path)

        #expect(changes == 3)
    }

    @Test func stateFileKeepsTerminalsAndOldFilesStillLoad() throws {
        let saved = SavedRowTerminals(
            tabs: [SavedTab(name: "T", layout: .leaf(SavedPane(folder: "/w")), focused: 0)], selectedTab: 0)
        let state = AppState(terminals: ["/w": saved])

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(decoded.terminals == ["/w": saved])
        let old = try JSONDecoder().decode(AppState.self, from: Data(#"{"version": 1, "repos": []}"#.utf8))
        #expect(old.terminals.isEmpty)
        let broken = #"{"version": 1, "repos": [{"path": "/r", "dirName": "r"}], "terminals": {"/w": {"tabs": 3}}}"#
        let kept = try JSONDecoder().decode(AppState.self, from: Data(broken.utf8))
        #expect(kept.repos.map(\.path) == ["/r"])
        #expect(kept.terminals.isEmpty)
    }
}

struct GridSettingsTests {
    @Test func paneIDsReadBack() {
        #expect(PaneID("p12") == PaneID(12))
        #expect(PaneID("12") == nil)
        #expect(PaneID("p0") == nil)
        #expect(PaneID("px") == nil)
    }

    @Test func globalConfigDefaultsAndBounds() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("config.json"))
        #expect(GlobalConfig.load(from: url).minPaneColumns == 80)
        try #"{"minPaneColumns": 100}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 100)
        try #"{"minPaneColumns": 3}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 20)
        try "{".write(to: url, atomically: true, encoding: .utf8)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 80)
    }
}

struct CloseWarningTests {
    @Test func tabCloseWarningCountsTerminals() {
        #expect(BusyTerminals.closeWarning(["bun"]) == "A terminal in it is running a program: bun.")
        #expect(
            BusyTerminals.closeWarning(["bun", "claude"]) == "2 terminals in it are running programs: bun, claude.")
    }
}
```

`Tests/CanopyCoreTests/PaneTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/PaneTests.swift
+++ b/Tests/CanopyCoreTests/PaneTests.swift
@@ -12,7 +12,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(row)).pane
+        let pane = terminals.openTab(for: Fixture.context(row)).focused
         await pane.run(#"printf 'ready:%s:%s:%s\n' "$CANOPY_PANE" "$CANOPY_ROW" "$(pwd -P)""#)
 
         #expect(await eventually { pane.screen.text.contains("ready:p1:feat/x:\(row)") })
@@ -23,7 +23,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
         await pane.run(#"printf '%s|%s\n' "it's" "héllo ✓ $CANOPY_ROW""#)
 
         #expect(await eventually { pane.screen.text.contains("it's|héllo ✓ feat/x") })
@@ -33,7 +33,7 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
         let firstShell = try #require(pane.pid)
 
         #expect(await eventually { pane.foreground?.name == "bash" })
@@ -57,7 +57,7 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         pane.screen.onTitle?("my title")
@@ -76,7 +76,7 @@ struct PaneTests {
     @Test func closingEndsTheProcessAndWakesWaiters() async throws {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 30")).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 30")).focused
         let group = try #require(pane.pid)
         let waiter = Task { await pane.waitForExit() }
         try await Task.sleep(for: .milliseconds(100))
@@ -92,7 +92,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("echo working; exit 4")).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("echo working; exit 4")).focused
 
         #expect(await pane.waitForExit() == 4)
         #expect(pane.screen.text.contains("working"))
@@ -104,7 +104,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.sub("gone"))).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.sub("gone"))).focused
         await pane.run(#"echo "at:$(pwd -P)""#)
 
         #expect(await eventually { pane.screen.text.contains("at:\(dir.sub("user-home"))") })
```

`Tests/CanopyCoreTests/RowSetupTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/RowSetupTests.swift
+++ b/Tests/CanopyCoreTests/RowSetupTests.swift
@@ -53,6 +53,20 @@ struct RowSetupTests {
         #expect(await task.value.setup.status == .succeeded)
     }
 
+    @Test func panesSplitOffTheSetupTabOutliveSetup() async throws {
+        let dir = try TempDir()
+        let (repo, rows) = try await setUp(dir, config: #"{"setup": ["sleep 0.5"]}"#)
+        defer { rows.terminals.closeAll() }
+        let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/split").row
+        let task = rows.prepare(row, repoName: "demo", setup: true, run: nil)
+
+        let extra = rows.terminals.addPane(for: PaneContext(row: row, repoName: "demo"), fits: { _ in true })
+        #expect(await task.value.setup.status == .succeeded)
+
+        #expect(extra.status == .running)
+        #expect(rows.terminals.tabs(inRow: row.path).flatMap(\.paneList).map(\.id) == [extra.id])
+    }
+
     @Test func failedSetupStaysOpenAndSkipsRun() async throws {
         let dir = try TempDir()
         let config = #"{"setup": ["exit 5", "touch \"$CANOPY_ROOT_PATH/../never\""]}"#
@@ -83,7 +97,7 @@ struct RowSetupTests {
 
         let pane = try #require(ready.pane)
         #expect(await eventually { read(dir.sub("ran")) == "\(pane)\n" })
-        #expect(rows.terminals.tabs(inRow: row.path).map(\.pane.id) == [pane])
+        #expect(rows.terminals.tabs(inRow: row.path).map(\.focused.id) == [pane])
     }
 
     @Test func runStartsAtOnceWithoutSetupCommands() async throws {
@@ -97,7 +111,7 @@ struct RowSetupTests {
         #expect(rows.terminals.tabs(inRow: row.path).count == 1)
         let ready = await task.value
         #expect(ready.setup.status == .none)
-        #expect(ready.pane == rows.terminals.tabs(inRow: row.path).first?.pane.id)
+        #expect(ready.pane == rows.terminals.tabs(inRow: row.path).first?.focused.id)
     }
 
     @Test func setupCanBeSkipped() async throws {
@@ -173,7 +187,7 @@ struct RowSetupTests {
         let config = #"{"teardown": ["echo \"$CANOPY_ROW\" > \"$CANOPY_ROOT_PATH/../teardown.out\""]}"#
         let (repo, rows) = try await setUp(dir, config: config)
         let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/done").row
-        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).pane.pid)
+        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).focused.pid)
 
         try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)
 
@@ -233,7 +247,7 @@ struct RowSetupTests {
         let dir = try TempDir()
         let (repo, rows) = try await setUp(dir, config: nil)
         let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/x").row
-        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).pane.pid)
+        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).focused.pid)
 
         try await rows.removeRepo(path: repo)
 
@@ -247,13 +261,13 @@ struct RowSetupTests {
         let (repo, rows) = try await setUp(dir, config: nil)
         defer { rows.terminals.closeAll() }
         let main = try #require(await rows.workspace.snapshot.repos.first?.rows.first)
-        let pane = rows.terminals.openTab(for: PaneContext(row: main, repoName: "demo")).pane
+        let pane = rows.terminals.openTab(for: PaneContext(row: main, repoName: "demo")).focused
         #expect(await eventually { pane.foreground?.name == "bash" })
         try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
 
         try await rows.relocateRepo(path: repo, to: dir.sub("moved"))
 
-        #expect(rows.terminals.tabs(inRow: dir.sub("moved")).map(\.pane.id) == [pane.id])
+        #expect(rows.terminals.tabs(inRow: dir.sub("moved")).map(\.focused.id) == [pane.id])
         #expect(pane.context.rowPath == dir.sub("moved"))
         #expect(pane.status == .running)
     }
```

`Tests/CanopyCoreTests/TerminalStoreTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/TerminalStoreTests.swift
+++ b/Tests/CanopyCoreTests/TerminalStoreTests.swift
@@ -38,7 +38,7 @@ struct TerminalStoreTests {
 
         #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal 2", "Terminal 3", "Terminal"])
         #expect(Set(terminals.panes.map(\.id)).count == 3)
-        #expect(terminals.pane(tabs[1].pane.id) === tabs[1].pane)
+        #expect(terminals.pane(tabs[1].focused.id) === tabs[1].focused)
     }
 
     @Test func closingTheSelectedTabSelectsItsRightNeighbor() throws {
@@ -55,7 +55,7 @@ struct TerminalStoreTests {
         terminals.closeTab(tabs[2].id, inRow: dir.path)
         #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)
 
-        terminals.closePane(tabs[0].pane.id)
+        terminals.closePane(tabs[0].focused.id)
         #expect(terminals.tabs(inRow: dir.path).isEmpty)
         #expect(terminals.selectedTab(inRow: dir.path) == nil)
     }
@@ -105,10 +105,10 @@ struct TerminalStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let groups = [
-            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
-            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
+            terminals.openTab(for: Fixture.context(dir.path)).focused.pid,
+            terminals.openTab(for: Fixture.context(dir.path)).focused.pid,
         ].compactMap { $0 }
-        let kept = terminals.openTab(for: Fixture.context(other)).pane
+        let kept = terminals.openTab(for: Fixture.context(other)).focused
 
         terminals.closeRow(path: dir.path)
 
@@ -121,8 +121,8 @@ struct TerminalStoreTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let idle = terminals.openTab(for: Fixture.context(dir.path)).pane
-        let busy = terminals.openTab(for: Fixture.context(dir.path)).pane
+        let idle = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let busy = terminals.openTab(for: Fixture.context(dir.path)).focused
 
         await busy.run("sleep 30")
 
@@ -162,12 +162,12 @@ struct TerminalStoreTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let main = terminals.openTab(for: Fixture.context("/old/demo", repoPath: "/old/demo")).pane
-        let elsewhere = terminals.openTab(for: Fixture.context(dir.sub("wt"), repoPath: "/old/demo")).pane
+        let main = terminals.openTab(for: Fixture.context("/old/demo", repoPath: "/old/demo")).focused
+        let elsewhere = terminals.openTab(for: Fixture.context(dir.sub("wt"), repoPath: "/old/demo")).focused
 
         terminals.moveRows(ofRepo: "/old/demo", to: "/new/demo")
 
-        #expect(terminals.tabs(inRow: "/new/demo").map(\.pane.id) == [main.id])
+        #expect(terminals.tabs(inRow: "/new/demo").map(\.focused.id) == [main.id])
         #expect(terminals.tabs(inRow: "/old/demo").isEmpty)
         #expect(main.context.rowPath == "/new/demo")
         #expect(elsewhere.context.rowPath == dir.sub("wt"))
@@ -183,7 +183,7 @@ struct TerminalStoreTests {
         defer { terminals.closeAll() }
         terminals.preferredSize = TerminalSize(columns: 150, rows: 45)
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
 
         #expect(pane.emulator.size == TerminalSize(columns: 150, rows: 45))
     }
```

`Tests/CanopyCoreTests/WorkspaceTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/WorkspaceTests.swift
+++ b/Tests/CanopyCoreTests/WorkspaceTests.swift
@@ -185,7 +185,7 @@ struct WorkspaceTests {
         async let relocation = workspace.relocateRepo(path: b, to: dir.sub("b-moved"))
         try await Task.sleep(for: .milliseconds(300))
         try await workspace.removeRepo(path: a)
-        try await relocation
+        _ = try await relocation
 
         #expect(await workspace.snapshot.repos.map(\.path) == [dir.sub("b-moved"), c])
     }
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "GridStoreTests|GridSettingsTests"`
Expected: build failure, `value of type 'TerminalTab' has no member 'paneList'`.

- [ ] **Step 3: Implement**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -210,14 +210,14 @@ final class AppModel {
     /// ⌘W. Only for the main window itself, so it never closes a terminal behind a sheet or a closed window.
     func closeFocusedPane() {
         guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
-            let pane = selectedTab?.pane
+            let pane = selectedTab?.focused
         else { return }
         requestClose(pane)
     }
 
     /// Hands the keyboard back to the terminal on screen, as after renaming a tab.
     func focusSelectedTerminal() {
-        (selectedTab?.pane.emulator as? SwiftTermEmulator)?.focus()
+        (selectedTab?.focused.emulator as? SwiftTermEmulator)?.focus()
     }
 
     func selectTab(offset: Int) {
```

`Sources/CanopyApp/Terminal/RowTerminalsView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/RowTerminalsView.swift
+++ b/Sources/CanopyApp/Terminal/RowTerminalsView.swift
@@ -21,11 +21,11 @@ struct RowTerminalsView: View {
             VStack(spacing: 0) {
                 TabBarView(row: row)
                 PaneView(
-                    pane: tab.pane,
-                    onClose: { model.requestClose(tab.pane) },
+                    pane: tab.focused,
+                    onClose: { model.requestClose(tab.focused) },
                     onSizeChange: { model.terminals.preferredSize = $0 }
                 )
-                .id(tab.pane.id)
+                .id(tab.focused.id)
             }
         } else {
             ContentUnavailableView {
```

`Sources/CanopyApp/Terminal/TabBarView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/TabBarView.swift
+++ b/Sources/CanopyApp/Terminal/TabBarView.swift
@@ -17,7 +17,7 @@ struct TabBarView: View {
                             tab: tab,
                             isSelected: tab.id == selected,
                             onSelect: { model.terminals.selectTab(tab.id, inRow: row.path) },
-                            onClose: { model.requestClose(tab.pane) },
+                            onClose: { model.requestClose(tab.focused) },
                             onRename: { name in
                                 model.terminals.renameTab(tab.id, inRow: row.path, to: name)
                                 model.focusSelectedTerminal()
```

`Sources/CanopyCore/Rows/RowLifecycle.swift` (modify):

```diff
--- a/Sources/CanopyCore/Rows/RowLifecycle.swift
+++ b/Sources/CanopyCore/Rows/RowLifecycle.swift
@@ -59,7 +59,7 @@ public final class RowLifecycle {
         }
 
         guard !commands.isEmpty else {
-            let pane = run.map { _ in terminals.openTab(for: context).pane }
+            let pane = run.map { _ in terminals.openTab(for: context).focused }
             let report = SetupReport(status: setup ? .none : .skipped)
             return Task {
                 if let pane, let run { await pane.run(run) }
@@ -68,11 +68,12 @@ public final class RowLifecycle {
         }
 
         let script = SetupScript.render(commands, label: "Setup")
-        let tab = terminals.openTab(for: context, name: "Setup", command: .script(script))
+        // The setup pane, not its tab: the user may split the Setup tab while setup runs.
+        let setupPane = terminals.openTab(for: context, name: "Setup", command: .script(script)).focused
         return Task {
-            let code = await tab.pane.waitForExit()
+            let code = await setupPane.waitForExit()
             guard code == 0 else {
-                let closed = !terminals.tabs(inRow: row.path).contains { $0.id == tab.id }
+                let closed = terminals.tab(containing: setupPane.id) == nil
                 let message =
                     closed
                     ? "Setup stopped because its tab was closed."
@@ -81,11 +82,14 @@ public final class RowLifecycle {
             }
             var pane: Pane?
             if run != nil {
-                pane = terminals.openTab(for: context).pane
-            } else if terminals.tabs(inRow: row.path).count == 1 {
+                pane = terminals.openTab(for: context).focused
+            } else if terminals.tabs(inRow: row.path).count == 1,
+                terminals.tab(containing: setupPane.id)?.1.paneList.count == 1
+            {
                 terminals.openTab(for: context)
             }
-            terminals.closeTab(tab.id, inRow: row.path)
+            // Closes the tab only if setup's pane was all it held.
+            terminals.closePane(setupPane.id)
             if let pane, let run { await pane.run(run) }
             return RowPreparation(setup: SetupReport(status: .succeeded, exitCode: 0), pane: pane?.id)
         }
@@ -143,11 +147,12 @@ public final class RowLifecycle {
         }
         guard !commands.isEmpty else { return }
         let script = SetupScript.render(commands, label: "Teardown")
-        let tab = terminals.openTab(
-            for: PaneContext(row: row, repoName: repoName), name: "Teardown", command: .script(script))
-        let code = await tab.pane.waitForExit()
+        let teardownPane = terminals.openTab(
+            for: PaneContext(row: row, repoName: repoName), name: "Teardown", command: .script(script)
+        ).focused
+        let code = await teardownPane.waitForExit()
         guard code != 0, !force else { return }
-        let closed = !terminals.tabs(inRow: row.path).contains { $0.id == tab.id }
+        let closed = terminals.tab(containing: teardownPane.id) == nil
         throw closed ? WorkspaceError.teardownStopped : WorkspaceError.teardownFailed(code)
     }
 }
```

`Sources/CanopyCore/State/AppState.swift` (modify):

```diff
--- a/Sources/CanopyCore/State/AppState.swift
+++ b/Sources/CanopyCore/State/AppState.swift
@@ -27,11 +27,17 @@ public struct AppState: Codable, Sendable, Equatable {
     public var version: Int
     public var repos: [RepoEntry]
     public var selectedRowPath: String?
+    /// Each row's tabs and layouts, keyed by row path, rebuilt with fresh shells on launch.
+    public var terminals: [String: SavedRowTerminals]
 
-    public init(version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil) {
+    public init(
+        version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil,
+        terminals: [String: SavedRowTerminals] = [:]
+    ) {
         self.version = version
         self.repos = repos
         self.selectedRowPath = selectedRowPath
+        self.terminals = terminals
     }
 
     public init(from decoder: any Decoder) throws {
@@ -39,5 +45,7 @@ public struct AppState: Codable, Sendable, Equatable {
         version = try container.decode(Int.self, forKey: .version)
         repos = try container.decodeIfPresent([RepoEntry].self, forKey: .repos) ?? []
         selectedRowPath = try container.decodeIfPresent(String.self, forKey: .selectedRowPath)
+        // Layouts that cannot be read are dropped on their own, so repos and rows still load.
+        terminals = (try? container.decodeIfPresent([String: SavedRowTerminals].self, forKey: .terminals)) ?? [:]
     }
 }
```

`Sources/CanopyCore/State/GlobalConfig.swift` (new):

```swift
import Foundation

/// Settings from CANOPY_HOME/config.json. Missing keys and a missing or unreadable file use the defaults.
public struct GlobalConfig: Codable, Sendable, Equatable {
    /// The add rule starts a new line of panes rather than make any narrower than this many columns.
    public var minPaneColumns: Int

    public init(minPaneColumns: Int = 80) {
        self.minPaneColumns = minPaneColumns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minPaneColumns = max(try container.decodeIfPresent(Int.self, forKey: .minPaneColumns) ?? 80, 20)
    }

    public static func load(from url: URL) -> GlobalConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(GlobalConfig.self, from: data)
        else { return GlobalConfig() }
        return config
    }
}
```

`Sources/CanopyCore/State/SavedTerminals.swift` (new):

```swift
/// A pane as saved: only its folder. Restoring starts a fresh shell there and never re-runs old commands.
public struct SavedPane: Codable, Hashable, Sendable {
    public var folder: String

    public init(folder: String) {
        self.folder = folder
    }
}

public struct SavedTab: Codable, Equatable, Sendable {
    public var name: String
    public var layout: Layout<SavedPane>
    /// The focused pane's position in layout order.
    public var focused: Int?

    public init(name: String, layout: Layout<SavedPane>, focused: Int?) {
        self.name = name
        self.layout = layout
        self.focused = focused
    }
}

/// A row's tabs as saved in state.json.
public struct SavedRowTerminals: Codable, Equatable, Sendable {
    public var tabs: [SavedTab]
    public var selectedTab: Int

    public init(tabs: [SavedTab], selectedTab: Int) {
        self.tabs = tabs
        self.selectedTab = selectedTab
    }
}
```

`Sources/CanopyCore/Terminal/Pane.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/Pane.swift
+++ b/Sources/CanopyCore/Terminal/Pane.swift
@@ -25,12 +25,16 @@ public final class Pane: Identifiable {
     @ObservationIgnored private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
     @ObservationIgnored private var isClosed = false
 
+    /// The folder the shell starts in, when restored into one other than the row's.
+    public let startDirectory: String?
+
     init(
         id: PaneID, context: PaneContext, command: PaneCommand, settings: ShellSettings,
-        emulator: any TerminalEmulator
+        emulator: any TerminalEmulator, directory: String? = nil
     ) {
         self.id = id
         self.context = context
+        self.startDirectory = directory
         self.settings = settings
         self.emulator = emulator
         emulator.onInput = { [weak self] in self?.input($0) }
@@ -95,10 +99,16 @@ public final class Pane: Identifiable {
         }
     }
 
-    /// The row's folder, or the home folder if the row's folder is gone.
+    /// The shell's working folder now, so a `cd` is remembered across relaunches.
+    public var currentDirectory: String? {
+        process.flatMap { PtyProcess.currentDirectory(of: $0.pid) }
+    }
+
+    /// The folder it was restored into, or the row's folder, or the home folder if both are gone.
     private var directory: String {
-        FileManager.default.fileExists(atPath: context.rowPath)
-            ? context.rowPath : settings.baseEnvironment["HOME"] ?? NSHomeDirectory()
+        let exists = { FileManager.default.fileExists(atPath: $0) }
+        if let startDirectory, exists(startDirectory) { return startDirectory }
+        return exists(context.rowPath) ? context.rowPath : settings.baseEnvironment["HOME"] ?? NSHomeDirectory()
     }
 
     private func start(_ command: PaneCommand) {
```

`Sources/CanopyCore/Terminal/PtyProcess.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/PtyProcess.swift
+++ b/Sources/CanopyCore/Terminal/PtyProcess.swift
@@ -255,6 +255,17 @@ public final class PtyProcess: @unchecked Sendable {
         readSource = nil
     }
 
+    /// The working folder of a process, read from the kernel.
+    public static func currentDirectory(of pid: pid_t) -> String? {
+        var info = proc_vnodepathinfo()
+        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
+        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
+        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
+            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
+        }
+        return path.isEmpty ? nil : path
+    }
+
     static func exitCode(fromWaitStatus status: Int32) -> Int32 {
         let signal = status & 0x7f
         return signal == 0 ? (status >> 8) & 0xff : 128 + signal
```

`Sources/CanopyCore/Terminal/TerminalEmulator.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/TerminalEmulator.swift
+++ b/Sources/CanopyCore/Terminal/TerminalEmulator.swift
@@ -66,13 +66,25 @@ public enum TabNaming {
 }
 
 public enum BusyTerminals {
-    /// For the quit confirmation, such as "3 terminals are running processes: claude, bun. Quitting stops them."
-    public static func quitWarning(_ names: [String]) -> String {
+    /// For closing a tab, such as "2 terminals in it are running programs: claude, bun."
+    public static func closeWarning(_ names: [String]) -> String {
+        let list = unique(names).joined(separator: ", ")
+        return names.count == 1
+            ? "A terminal in it is running a program: \(list)."
+            : "\(names.count) terminals in it are running programs: \(list)."
+    }
+
+    static func unique(_ names: [String]) -> [String] {
         var unique: [String] = []
         for name in names where !unique.contains(name) {
             unique.append(name)
         }
-        let list = unique.joined(separator: ", ")
+        return unique
+    }
+
+    /// For the quit confirmation, such as "3 terminals are running processes: claude, bun. Quitting stops them."
+    public static func quitWarning(_ names: [String]) -> String {
+        let list = unique(names).joined(separator: ", ")
         return names.count == 1
             ? "1 terminal is running a process: \(list). Quitting stops it."
             : "\(names.count) terminals are running processes: \(list). Quitting stops them."
```

`Sources/CanopyCore/Terminal/TerminalIDs.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/TerminalIDs.swift
+++ b/Sources/CanopyCore/Terminal/TerminalIDs.swift
@@ -7,6 +7,12 @@ public struct PaneID: Hashable, Sendable, CustomStringConvertible {
     }
 
     public var description: String { "p\(number)" }
+
+    /// Reads "p12" back, as dragged panes and `canopy term` carry it.
+    public init?(_ text: String) {
+        guard text.hasPrefix("p"), let number = Int(text.dropFirst()), number > 0 else { return nil }
+        self.number = number
+    }
 }
 
 public struct TabID: Hashable, Sendable, CustomStringConvertible {
```

`Sources/CanopyCore/Terminal/TerminalStore.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/TerminalStore.swift
+++ b/Sources/CanopyCore/Terminal/TerminalStore.swift
@@ -1,3 +1,4 @@
+import CoreGraphics
 import Foundation
 import Observation
 
@@ -6,13 +7,30 @@ import Observation
 public final class TerminalTab: Identifiable {
     public let id: TabID
     public internal(set) var name: String
-    /// A tab holds one pane until the grid arrives.
-    public let pane: Pane
+    public internal(set) var layout: Layout<PaneID>
+    public internal(set) var panes: [PaneID: Pane]
+    public internal(set) var focusedPaneID: PaneID
 
     init(id: TabID, name: String, pane: Pane) {
         self.id = id
         self.name = name
-        self.pane = pane
+        self.layout = .leaf(pane.id)
+        self.panes = [pane.id: pane]
+        self.focusedPaneID = pane.id
+    }
+
+    /// Panes in layout order: left to right, then top to bottom.
+    public var paneList: [Pane] {
+        layout.leaves.compactMap { panes[$0] }
+    }
+
+    /// The pane `⌘W` closes and typing goes to.
+    public var focused: Pane {
+        panes[focusedPaneID] ?? paneList[0]
+    }
+
+    var repoPath: String? {
+        paneList.first?.context.repoPath
     }
 }
 
@@ -25,6 +43,8 @@ public final class TerminalStore {
     private var selectedTabByRow: [String: TabID] = [:]
     /// The size new terminals start at, so one opened in the background already fits the window.
     public var preferredSize = TerminalSize.standard
+    /// Called after any change worth saving: tabs, names, layouts, focus, or selection.
+    @ObservationIgnored public var onChange: () -> Void = {}
     @ObservationIgnored public let settings: ShellSettings
     @ObservationIgnored private let engine: any TerminalEngine
     @ObservationIgnored private var nextPane = 1
@@ -48,7 +68,7 @@ public final class TerminalStore {
     }
 
     public var panes: [Pane] {
-        tabsByRow.values.flatMap { $0.map(\.pane) }
+        tabsByRow.values.flatMap { $0.flatMap(\.paneList) }
     }
 
     public func pane(_ id: PaneID) -> Pane? {
@@ -60,21 +80,24 @@ public final class TerminalStore {
     }
 
     public func busyPanes(inRow path: String) -> [Pane] {
-        tabs(inRow: path).map(\.pane).filter(\.isBusy)
+        tabs(inRow: path).flatMap(\.paneList).filter(\.isBusy)
     }
 
+    // MARK: Tabs
+
     /// Opens a tab with one pane at the end of the row's tab bar and selects it.
     @discardableResult
-    public func openTab(for context: PaneContext, name: String? = nil, command: PaneCommand = .shell) -> TerminalTab {
+    public func openTab(
+        for context: PaneContext, name: String? = nil, command: PaneCommand = .shell, directory: String? = nil
+    ) -> TerminalTab {
         let tabs = tabs(inRow: context.rowPath)
-        let pane = Pane(
-            id: PaneID(nextPane), context: context, command: command, settings: settings,
-            emulator: engine.makeEmulator(size: preferredSize))
-        let tab = TerminalTab(id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.map(\.name)), pane: pane)
-        nextPane += 1
+        let tab = TerminalTab(
+            id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.map(\.name)),
+            pane: makePane(context, command: command, directory: directory))
         nextTab += 1
         tabsByRow[context.rowPath] = tabs + [tab]
         selectedTabByRow[context.rowPath] = tab.id
+        onChange()
         return tab
     }
 
@@ -89,6 +112,7 @@ public final class TerminalStore {
     public func selectTab(_ id: TabID, inRow path: String) {
         guard tabs(inRow: path).contains(where: { $0.id == id }) else { return }
         selectedTabByRow[path] = id
+        onChange()
     }
 
     /// Moves the selection by `offset` tabs, wrapping around at the ends.
@@ -97,46 +121,124 @@ public final class TerminalStore {
         guard let current = selectedTab(inRow: path), let index = tabs.firstIndex(where: { $0.id == current.id })
         else { return }
         let count = tabs.count
-        selectedTabByRow[path] = tabs[((index + offset) % count + count) % count].id
+        selectTab(tabs[((index + offset) % count + count) % count].id, inRow: path)
     }
 
     public func renameTab(_ id: TabID, inRow path: String, to name: String) {
         let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
         guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }) else { return }
         tab.name = trimmed
+        onChange()
     }
 
-    /// Closes a tab and its terminal. If it was selected, the tab to its right takes over, or else the new last tab.
+    /// Closes a tab and its terminals. If it was selected, the tab to its right takes over, or else the new last tab.
     public func closeTab(_ id: TabID, inRow path: String) {
         var tabs = tabs(inRow: path)
         guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
         let wasSelected = selectedTab(inRow: path)?.id == id
-        tabs.remove(at: index).pane.close()
+        for pane in tabs.remove(at: index).paneList {
+            pane.close()
+        }
         tabsByRow[path] = tabs.isEmpty ? nil : tabs
         if tabs.isEmpty {
             selectedTabByRow[path] = nil
         } else if wasSelected {
             selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
         }
+        onChange()
     }
 
-    /// Closing a tab's last pane closes the tab. Every tab holds one pane until the grid arrives.
+    // MARK: Panes
+
+    /// Adds a pane to the row's selected tab by the add rule, where `fits` says whether a line of that many panes
+    /// keeps each one wide enough, and focuses it. Opens a tab if the row has none.
+    @discardableResult
+    public func addPane(for context: PaneContext, fits: (Int) -> Bool) -> Pane {
+        guard let tab = selectedTab(inRow: context.rowPath) else {
+            return openTab(for: context).focused
+        }
+        let pane = makePane(context, command: .shell, directory: nil)
+        tab.panes[pane.id] = pane
+        tab.layout = tab.layout.adding(pane.id, fits: fits)
+        tab.focusedPaneID = pane.id
+        onChange()
+        return pane
+    }
+
+    /// Closes a pane and hands its space to its neighbors. Closing a tab's last pane closes the tab.
     public func closePane(_ id: PaneID) {
+        guard let found = tab(containing: id) else { return }
+        let (path, tab) = found
+        guard let layout = tab.layout.removing(id) else {
+            closeTab(tab.id, inRow: path)
+            return
+        }
+        if tab.focusedPaneID == id {
+            // Focus moves to the pane that came before it in layout order, or else the one after.
+            let order = tab.layout.leaves
+            let index = order.firstIndex(of: id) ?? 0
+            tab.focusedPaneID = index > 0 ? order[index - 1] : order[index + 1]
+        }
+        tab.panes.removeValue(forKey: id)?.close()
+        tab.layout = layout
+        onChange()
+    }
+
+    public func focus(_ id: PaneID) {
+        guard let tab = tab(containing: id)?.1, tab.focusedPaneID != id else { return }
+        tab.focusedPaneID = id
+        onChange()
+    }
+
+    /// Focuses the pane next to the focused one in `direction`, laid out in `rect`. Returns it, if there is one.
+    @discardableResult
+    public func focusNeighbor(inRow path: String, toward direction: Direction, in rect: CGRect) -> Pane? {
+        guard let tab = selectedTab(inRow: path),
+            let neighbor = tab.layout.neighbor(of: tab.focusedPaneID, toward: direction, in: rect)
+        else { return nil }
+        focus(neighbor)
+        return tab.panes[neighbor]
+    }
+
+    /// Drops `moved` on `target`: on an edge it splits the target 50/50, and in the middle the two swap.
+    /// Both must be in the same tab.
+    public func movePane(_ moved: PaneID, to zone: DropZone, of target: PaneID) {
+        guard moved != target, let tab = tab(containing: moved)?.1, tab.panes[target] != nil else { return }
+        switch zone {
+        case .center: tab.layout = tab.layout.swapping(moved, target)
+        case .edge(let edge): tab.layout = tab.layout.moving(moved, to: edge, of: target)
+        }
+        onChange()
+    }
+
+    public func resize(
+        _ tab: TerminalTab, divider: DividerID, to position: Double, in rect: CGRect, minimum: CGSize
+    ) {
+        let layout = tab.layout.resizing(divider, to: position, in: rect, minimum: minimum)
+        guard layout != tab.layout else { return }
+        tab.layout = layout
+        onChange()
+    }
+
+    public func tab(containing id: PaneID) -> (String, TerminalTab)? {
         for (path, tabs) in tabsByRow {
-            if let tab = tabs.first(where: { $0.pane.id == id }) {
-                closeTab(tab.id, inRow: path)
-                return
+            if let tab = tabs.first(where: { $0.panes[id] != nil }) {
+                return (path, tab)
             }
         }
+        return nil
     }
 
+    // MARK: Rows
+
     public func closeRow(path: String) {
-        for tab in tabs(inRow: path) {
-            tab.pane.close()
+        for pane in tabs(inRow: path).flatMap(\.paneList) {
+            pane.close()
         }
         tabsByRow[path] = nil
         selectedTabByRow[path] = nil
         seenRows.remove(path)
+        onChange()
     }
 
     /// Closes the terminals of rows that are gone from a repo git could list, such as a worktree removed with
@@ -144,7 +246,7 @@ public final class TerminalStore {
     /// Repos that are missing or failed to refresh keep their terminals.
     public func closeRowsGone(from snapshot: WorkspaceSnapshot) {
         for (path, tabs) in tabsByRow {
-            guard let repoPath = tabs.first?.pane.context.repoPath,
+            guard let repoPath = tabs.first?.repoPath,
                 let repo = snapshot.repo(path: repoPath), !repo.isMissing, repo.error == nil
             else { continue }
             if repo.allRows.contains(where: { $0.path == path }) {
@@ -157,18 +259,18 @@ public final class TerminalStore {
 
     /// Closes every terminal in a repo's rows, for when the repo is unregistered.
     public func closeRows(ofRepo repoPath: String) {
-        for (path, tabs) in tabsByRow where tabs.first?.pane.context.repoPath == repoPath {
+        for (path, tabs) in tabsByRow where tabs.first?.repoPath == repoPath {
             closeRow(path: path)
         }
     }
 
     /// Follows a repo that moved: rows inside its old folder move with it, and every pane learns its new paths.
     public func moveRows(ofRepo oldRepoPath: String, to newRepoPath: String) {
-        for (path, tabs) in tabsByRow where tabs.first?.pane.context.repoPath == oldRepoPath {
+        for (path, tabs) in tabsByRow where tabs.first?.repoPath == oldRepoPath {
             let newPath = Paths.isInside(path, oldRepoPath) ? newRepoPath + path.dropFirst(oldRepoPath.count) : path
-            for tab in tabs {
-                tab.pane.context.repoPath = newRepoPath
-                tab.pane.context.rowPath = newPath
+            for pane in tabs.flatMap(\.paneList) {
+                pane.context.repoPath = newRepoPath
+                pane.context.rowPath = newPath
             }
             tabsByRow[path] = nil
             tabsByRow[newPath] = tabs
@@ -179,6 +281,7 @@ public final class TerminalStore {
                 seenRows.insert(newPath)
             }
         }
+        onChange()
     }
 
     public func closeAll() {
@@ -186,4 +289,58 @@ public final class TerminalStore {
             closeRow(path: path)
         }
     }
+
+    // MARK: Saving and restoring
+
+    /// Every row's tabs as they would be restored: names, layouts, and each pane's current folder.
+    public func saved() -> [String: SavedRowTerminals] {
+        var saved: [String: SavedRowTerminals] = [:]
+        for (path, tabs) in tabsByRow {
+            saved[path] = SavedRowTerminals(
+                tabs: tabs.map { tab in
+                    SavedTab(
+                        name: tab.name,
+                        layout: tab.layout.map { id in
+                            let pane = tab.panes[id]
+                            return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
+                        },
+                        focused: tab.layout.leaves.firstIndex(of: tab.focusedPaneID)
+                    )
+                },
+                selectedTab: tabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0
+            )
+        }
+        return saved
+    }
+
+    /// Rebuilds a row's saved tabs with fresh shells in the saved folders. Folders that are gone fall back to the
+    /// row's own. Replaces nothing: a row that already has tabs keeps them.
+    public func restore(_ saved: SavedRowTerminals, for context: PaneContext) {
+        guard tabs(inRow: context.rowPath).isEmpty, !saved.tabs.isEmpty else { return }
+        let tabs = saved.tabs.map { savedTab in
+            let leaves = savedTab.layout.leaves
+            let panes = leaves.map { makePane(context, command: .shell, directory: $0.folder) }
+            var index = 0
+            let layout: Layout<PaneID> = savedTab.layout.map { _ in
+                defer { index += 1 }
+                return panes[index].id
+            }
+            let tab = TerminalTab(id: TabID(nextTab), name: savedTab.name, pane: panes[0])
+            nextTab += 1
+            tab.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
+            tab.layout = layout
+            tab.focusedPaneID =
+                savedTab.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
+            return tab
+        }
+        tabsByRow[context.rowPath] = tabs
+        selectedTabByRow[context.rowPath] = tabs[min(max(saved.selectedTab, 0), tabs.count - 1)].id
+    }
+
+    private func makePane(_ context: PaneContext, command: PaneCommand, directory: String?) -> Pane {
+        defer { nextPane += 1 }
+        return Pane(
+            id: PaneID(nextPane), context: context, command: command, settings: settings,
+            emulator: engine.makeEmulator(size: preferredSize), directory: directory)
+    }
 }
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -175,6 +175,17 @@ public actor Workspace {
         await refresh(repoPath: state.repos[index].path)
     }
 
+    /// Each row's saved tabs and layouts, from state.json.
+    public var savedTerminals: [String: SavedRowTerminals] {
+        state.terminals
+    }
+
+    public func setSavedTerminals(_ terminals: [String: SavedRowTerminals]) throws {
+        guard state.terminals != terminals else { return }
+        state.terminals = terminals
+        try save()
+    }
+
     public func setSelectedRow(path: String?) throws {
         guard state.selectedRowPath != path else { return }
         state.selectedRowPath = path
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`, three times.
Expected: all tests pass every time.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: tabs hold a grid of panes that is saved and restored"
```

## Task 3: Split, resize, rearrange, and restore in the app

**Files:**
- Create: `Sources/CanopyApp/Terminal/GridView.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`, `CanopyApp.swift`, `RootView.swift`
- Modify: `Sources/CanopyApp/Terminal/PaneView.swift`, `TerminalSurface.swift`, `RowTerminalsView.swift`, `SwiftTermEmulator.swift`, `TabBarView.swift`

**Interfaces:**
- Consumes: Task 2's store and saved state.
- Produces: `GridView(tab:)`, `DividerHandle`, `DropHighlight`, `PaneDropDelegate`; `AppModel.splitPane()`, `focusNeighbor(_:)`, `resize(_:divider:to:in:)`, `movePane(_:to:of:)`, `requestCloseTab(_:inRow:)`, `saveTerminals()`, `gridSize`, `minimumPaneSize`; `SwiftTermEmulator.cellSize`; `PaneHeader.height`; menu items Split Pane (`⌘D`) and Focus Pane Left, Right, Above, Below (`⌘⌥` arrows).

- [ ] **Step 1: Write the changes**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -59,6 +59,9 @@ final class AppModel {
         if let notice = await workspace.loadNotice {
             show(notice)
         }
+        let saved = await workspace.savedTerminals
+        snapshot = await workspace.snapshot
+        restoreTerminals(saved)
         let updates = await workspace.updates()
         Task { [weak self] in
             for await snapshot in updates {
@@ -172,8 +175,14 @@ final class AppModel {
 
     /// A close waiting for the user to confirm, because a program still runs in the terminal.
     struct PendingClose {
-        let pane: PaneID
-        let program: String
+        enum Target {
+            case pane(PaneID)
+            case tab(TabID, row: String)
+        }
+
+        let target: Target
+        let title: String
+        let message: String
     }
 
     var pendingClose: PendingClose?
@@ -194,17 +203,132 @@ final class AppModel {
     /// Closes a terminal, first asking if a program other than the shell still runs in it.
     func requestClose(_ pane: Pane) {
         if pane.isBusy, let program = pane.foreground?.name {
-            pendingClose = PendingClose(pane: pane.id, program: program)
+            pendingClose = PendingClose(
+                target: .pane(pane.id), title: "Close this terminal?", message: "\(program) is still running in it.")
         } else {
             terminals.closePane(pane.id)
+            focusSelectedTerminal()
+        }
+    }
+
+    /// Closes a tab and all its terminals, first asking if any of them are running programs.
+    func requestCloseTab(_ tab: TerminalTab, inRow path: String) {
+        let busy = tab.paneList.compactMap { $0.isBusy ? $0.foreground?.name : nil }
+        if busy.isEmpty {
+            terminals.closeTab(tab.id, inRow: path)
+        } else {
+            pendingClose = PendingClose(
+                target: .tab(tab.id, row: path), title: "Close \(tab.name)?",
+                message: BusyTerminals.closeWarning(busy))
         }
     }
 
     func confirmClose() {
-        if let pending = pendingClose {
-            terminals.closePane(pending.pane)
+        switch pendingClose?.target {
+        case .pane(let id): terminals.closePane(id)
+        case .tab(let id, let path): terminals.closeTab(id, inRow: path)
+        case nil: break
         }
         pendingClose = nil
+        focusSelectedTerminal()
+    }
+
+    // MARK: Grid
+
+    /// The size of the selected tab's grid, for the add rule and for finding neighbors.
+    var gridSize = CGSize(width: 1000, height: 700)
+    @ObservationIgnored private lazy var config = GlobalConfig.load(from: home.configFile)
+
+    /// The least room a pane may shrink to: 20 columns and 5 rows, plus its padding and header.
+    var minimumPaneSize: CGSize {
+        let cell = SwiftTermEmulator.cellSize
+        let padding = TerminalContainerView.padding
+        return CGSize(
+            width: 20 * cell.width + padding.left + padding.right,
+            height: 5 * cell.height + padding.top + padding.bottom + PaneHeader.height)
+    }
+
+    /// ⌘D. Adds a pane by the add rule, keeping panes at least `minPaneColumns` wide on a line.
+    func splitPane() {
+        guard let row = selectedRow, !row.isMissing else { return }
+        let padding = TerminalContainerView.padding
+        let minimumWidth =
+            Double(config.minPaneColumns) * SwiftTermEmulator.cellSize.width + padding.left + padding.right
+        let width = gridSize.width
+        terminals.addPane(for: context(for: row), fits: { width / Double($0) >= minimumWidth })
+        focusSelectedTerminal()
+    }
+
+    /// ⌘⌥ and an arrow.
+    func focusNeighbor(_ direction: Direction) {
+        guard let row = selectedRow else { return }
+        if terminals.focusNeighbor(inRow: row.path, toward: direction, in: CGRect(origin: .zero, size: gridSize))
+            != nil
+        {
+            focusSelectedTerminal()
+        }
+    }
+
+    func resize(_ tab: TerminalTab, divider: DividerID, to position: Double, in rect: CGRect) {
+        terminals.resize(tab, divider: divider, to: position, in: rect, minimum: minimumPaneSize)
+    }
+
+    /// The pane being dragged by its header, so drops only react to Canopy's own pane drags.
+    var draggedPane: PaneID?
+
+    func movePane(_ moved: PaneID, to zone: DropZone, of target: PaneID) {
+        terminals.movePane(moved, to: zone, of: target)
+    }
+
+    // MARK: Saving layouts
+
+    @ObservationIgnored private var saveTask: Task<Void, Never>?
+    /// Nothing is saved until the saved layouts were restored, or quitting early would erase them.
+    @ObservationIgnored private var terminalsRestored = false
+    /// Saved tabs of rows that were missing at launch, kept and saved again until the row comes back.
+    @ObservationIgnored private var deferredTerminals: [String: SavedRowTerminals] = [:]
+
+    /// Rebuilds the tabs saved for rows that exist. Runs before the first selection, so a restored row does not also
+    /// get a fresh terminal.
+    private func restoreTerminals(_ saved: [String: SavedRowTerminals]) {
+        deferredTerminals = saved
+        restoreDeferredTerminals()
+        terminalsRestored = true
+        terminals.onChange = { [weak self] in self?.scheduleSave() }
+    }
+
+    /// Restores deferred rows that came back, and forgets rows git no longer lists once every repo refreshed cleanly.
+    private func restoreDeferredTerminals() {
+        let allHealthy = snapshot.repos.allSatisfy { !$0.isMissing && $0.error == nil }
+        for (path, rowTerminals) in deferredTerminals {
+            if let row = snapshot.row(path: path) {
+                guard !row.isMissing else { continue }
+                terminals.restore(rowTerminals, for: context(for: row))
+                deferredTerminals[path] = nil
+            } else if allHealthy {
+                deferredTerminals[path] = nil
+            }
+        }
+    }
+
+    /// Saves a second after the last change, so a burst of changes writes state.json once.
+    private func scheduleSave() {
+        saveTask?.cancel()
+        saveTask = Task {
+            try? await Task.sleep(for: .seconds(1))
+            guard !Task.isCancelled else { return }
+            await saveTerminals()
+        }
+    }
+
+    /// Reads each pane's folder now, so a `cd` since the last change is kept too.
+    func saveTerminals() async {
+        guard terminalsRestored else { return }
+        do {
+            try await workspace.setSavedTerminals(terminals.saved().merging(deferredTerminals) { live, _ in live })
+        } catch {
+            show(error)
+        }
     }
 
     /// ⌘W. Only for the main window itself, so it never closes a terminal behind a sheet or a closed window.
@@ -279,6 +403,9 @@ final class AppModel {
     private func apply(_ snapshot: WorkspaceSnapshot) {
         self.snapshot = snapshot
         terminals.closeRowsGone(from: snapshot)
+        if terminalsRestored, !deferredTerminals.isEmpty {
+            restoreDeferredTerminals()
+        }
         if selectedRowPath == nil, let saved = snapshot.selectedRowPath, snapshot.row(path: saved) != nil {
             selectedRowPath = saved
         } else if let path = selectedRowPath, snapshot.row(path: path) == nil {
```

`Sources/CanopyApp/CanopyApp.swift` (modify):

```diff
--- a/Sources/CanopyApp/CanopyApp.swift
+++ b/Sources/CanopyApp/CanopyApp.swift
@@ -33,13 +33,22 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
 
     func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
         let busy = model.terminals.busyPanes.compactMap(\.foreground?.name)
-        guard !busy.isEmpty else { return .terminateNow }
+        guard busy.isEmpty || confirmQuit(busy) else { return .terminateCancel }
+        // Save layouts with every pane's current folder before the terminals close.
+        Task {
+            await model.saveTerminals()
+            NSApp.reply(toApplicationShouldTerminate: true)
+        }
+        return .terminateLater
+    }
+
+    private func confirmQuit(_ busy: [String]) -> Bool {
         let alert = NSAlert()
         alert.messageText = "Quit Canopy?"
         alert.informativeText = BusyTerminals.quitWarning(busy)
         alert.addButton(withTitle: "Quit")
         alert.addButton(withTitle: "Cancel")
-        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
+        return alert.runModal() == .alertFirstButtonReturn
     }
 
     func applicationWillTerminate(_ notification: Notification) {
@@ -55,6 +64,9 @@ struct TerminalCommands: Commands {
             Button("New Tab", action: model.newTab)
                 .keyboardShortcut("t")
                 .disabled(!model.canOpenTerminal)
+            Button("Split Pane", action: model.splitPane)
+                .keyboardShortcut("d")
+                .disabled(!model.canOpenTerminal)
         }
         // Replacing the save group also drops File > Close, so ⌘W closes a terminal rather than the window.
         CommandGroup(replacing: .saveItem) {
@@ -69,6 +81,15 @@ struct TerminalCommands: Commands {
             Button("Show Next Tab") { model.selectTab(offset: 1) }
                 .keyboardShortcut("}", modifiers: .command)
             Divider()
+            Button("Focus Pane on the Left") { model.focusNeighbor(.left) }
+                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
+            Button("Focus Pane on the Right") { model.focusNeighbor(.right) }
+                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
+            Button("Focus Pane Above") { model.focusNeighbor(.up) }
+                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
+            Button("Focus Pane Below") { model.focusNeighbor(.down) }
+                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
+            Divider()
         }
     }
 }
```

`Sources/CanopyApp/RootView.swift` (modify):

```diff
--- a/Sources/CanopyApp/RootView.swift
+++ b/Sources/CanopyApp/RootView.swift
@@ -25,14 +25,14 @@ struct RootView: View {
             model.refresh()
         }
         .alert(
-            "Close this terminal?",
+            model.pendingClose?.title ?? "",
             isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } }),
             presenting: model.pendingClose
         ) { _ in
-            Button("Close Terminal", role: .destructive, action: model.confirmClose)
+            Button("Close", role: .destructive, action: model.confirmClose)
             Button("Cancel", role: .cancel) {}
         } message: { pending in
-            Text("\(pending.program) is still running in it.")
+            Text(pending.message)
         }
         .alert(
             "Remove \(model.pendingRepoRemoval?.repo.name ?? "") from Canopy?",
```

`Sources/CanopyApp/Terminal/GridView.swift` (new):

```swift
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

/// A tab's panes, placed by its layout. Dividers resize, and a pane's header drags it onto another pane.
struct GridView: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab
    @State private var hover: DropHover?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = tab.layout.frames(in: rect)
            ZStack(alignment: .topLeading) {
                // Keyed by pane, so a terminal is never rebuilt when the layout around it changes.
                ForEach(tab.layout.leaves, id: \.self) { id in
                    if let pane = tab.panes[id], let frame = frames[id] {
                        PaneView(
                            pane: pane,
                            isFocusedPane: tab.focusedPaneID == id,
                            onClose: { model.requestClose(pane) },
                            onFocus: { model.terminals.focus(id) },
                            onDragStart: { model.draggedPane = id },
                            onSizeChange: { model.terminals.preferredSize = $0 }
                        )
                        .onDrop(
                            of: [.plainText],
                            delegate: PaneDropDelegate(target: id, size: frame.size, model: model, hover: $hover)
                        )
                        .overlay { DropHighlight(zone: hover?.target == id ? hover?.zone : nil) }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(tab.layout.dividers(in: rect), id: \.id) { divider in
                    DividerHandle(divider: divider) { position in
                        model.resize(tab, divider: divider.id, to: position, in: rect)
                    }
                }
            }
            .coordinateSpace(.named(GridView.space))
            .onAppear { model.gridSize = geometry.size }
            .onChange(of: geometry.size) { model.gridSize = geometry.size }
        }
    }

    static let space = "grid"
}

struct DropHover: Equatable {
    var target: PaneID
    var zone: DropZone?
}

/// A thin line between panes with a wider grip to drag.
struct DividerHandle: View {
    let divider: LayoutDivider
    let onDrag: (Double) -> Void
    private let grip = 7.0
    /// Where the line was when the drag began, so grabbing the grip off center does not make it jump.
    @State private var startPosition: Double?

    var body: some View {
        let line = divider.line
        let isRow = divider.axis == .row
        Rectangle()
            .fill(.separator)
            .frame(width: isRow ? 1 : line.width, height: isRow ? line.height : 1)
            .frame(width: isRow ? grip : line.width, height: isRow ? line.height : grip)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: isRow ? .trailing : .bottom))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(GridView.space))
                    .onChanged { value in
                        let start = startPosition ?? Double(isRow ? line.minX : line.minY)
                        startPosition = start
                        onDrag(start + (isRow ? value.translation.width : value.translation.height))
                    }
                    .onEnded { _ in startPosition = nil }
            )
            .offset(x: isRow ? line.minX - grip / 2 : line.minX, y: isRow ? line.minY : line.minY - grip / 2)
    }
}

/// Shows where a dragged pane would land: half the target for an edge, all of it for a swap.
struct DropHighlight: View {
    let zone: DropZone?

    var body: some View {
        GeometryReader { geometry in
            if let zone {
                let size = geometry.size
                let area: CGRect =
                    switch zone {
                    case .center: CGRect(origin: .zero, size: size)
                    case .edge(.left): CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
                    case .edge(.right): CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
                    case .edge(.top): CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
                    case .edge(.bottom): CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
                    }
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    )
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.15), value: zone)
    }
}

struct PaneDropDelegate: DropDelegate {
    let target: PaneID
    let size: CGSize
    let model: AppModel
    @Binding var hover: DropHover?

    /// Only a pane dragged from this grid, and not onto itself.
    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = model.draggedPane else { return false }
        return dragged != target && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover = DropHover(target: target, zone: DropZone.at(info.location, in: CGRect(origin: .zero, size: size)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if hover?.target == target { hover = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = DropZone.at(info.location, in: CGRect(origin: .zero, size: size))
        hover = nil
        defer { model.draggedPane = nil }
        guard let zone, let moved = model.draggedPane else { return false }
        model.movePane(moved, to: zone, of: target)
        return true
    }
}
```

`Sources/CanopyApp/Terminal/PaneView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/PaneView.swift
+++ b/Sources/CanopyApp/Terminal/PaneView.swift
@@ -4,14 +4,31 @@ import SwiftUI
 /// One terminal with its header, and a strip below it once its shell has exited.
 struct PaneView: View {
     let pane: Pane
+    /// Whether it is its tab's focused pane, which takes the keyboard when the tab comes into view.
+    var isFocusedPane = true
     let onClose: () -> Void
+    var onFocus: () -> Void = {}
+    var onDragStart: () -> Void = {}
     var onSizeChange: (TerminalSize) -> Void = { _ in }
     @State private var isFocused = false
 
     var body: some View {
         VStack(spacing: 0) {
             PaneHeader(title: pane.title, isFocused: isFocused, onClose: onClose)
-            TerminalSurface(pane: pane, onFocusChange: { isFocused = $0 }, onSizeChange: onSizeChange)
+                // The header is the handle for dragging the pane onto another one.
+                .onDrag {
+                    onDragStart()
+                    return NSItemProvider(object: pane.id.description as NSString)
+                }
+            TerminalSurface(
+                pane: pane,
+                takesFocus: isFocusedPane,
+                onFocusChange: { focused in
+                    isFocused = focused
+                    if focused { onFocus() }
+                },
+                onSizeChange: onSizeChange
+            )
             if case .exited(let code) = pane.status {
                 ExitStrip(code: code)
             }
@@ -27,6 +44,8 @@ struct PaneView: View {
 }
 
 struct PaneHeader: View {
+    static let height = 24.0
+
     let title: String
     let isFocused: Bool
     let onClose: () -> Void
@@ -54,7 +73,7 @@ struct PaneHeader: View {
         }
         .padding(.leading, 10)
         .padding(.trailing, 6)
-        .frame(height: 24)
+        .frame(height: Self.height)
         .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
         .overlay(alignment: .bottom) {
             Rectangle().fill(.separator).frame(height: 1)
```

`Sources/CanopyApp/Terminal/RowTerminalsView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/RowTerminalsView.swift
+++ b/Sources/CanopyApp/Terminal/RowTerminalsView.swift
@@ -20,12 +20,8 @@ struct RowTerminalsView: View {
         } else if let tab = model.terminals.selectedTab(inRow: row.path) {
             VStack(spacing: 0) {
                 TabBarView(row: row)
-                PaneView(
-                    pane: tab.focused,
-                    onClose: { model.requestClose(tab.focused) },
-                    onSizeChange: { model.terminals.preferredSize = $0 }
-                )
-                .id(tab.focused.id)
+                GridView(tab: tab)
+                    .id(tab.id)
             }
         } else {
             ContentUnavailableView {
```

`Sources/CanopyApp/Terminal/SwiftTermEmulator.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
+++ b/Sources/CanopyApp/Terminal/SwiftTermEmulator.swift
@@ -8,6 +8,12 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
     static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
     static let scrollback = 10_000
 
+    /// The size of one character cell in the terminal font.
+    static let cellSize: CGSize = {
+        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
+        return CGSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
+    }()
+
     /// Terminal.app's ANSI colors, which read well on light and dark backgrounds alike.
     private static let palette: [SwiftTerm.Color] = [
         (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
```

`Sources/CanopyApp/Terminal/TabBarView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/TabBarView.swift
+++ b/Sources/CanopyApp/Terminal/TabBarView.swift
@@ -17,7 +17,7 @@ struct TabBarView: View {
                             tab: tab,
                             isSelected: tab.id == selected,
                             onSelect: { model.terminals.selectTab(tab.id, inRow: row.path) },
-                            onClose: { model.requestClose(tab.focused) },
+                            onClose: { model.requestCloseTab(tab, inRow: row.path) },
                             onRename: { name in
                                 model.terminals.renameTab(tab.id, inRow: row.path, to: name)
                                 model.focusSelectedTerminal()
```

`Sources/CanopyApp/Terminal/TerminalSurface.swift` (modify):

```diff
--- a/Sources/CanopyApp/Terminal/TerminalSurface.swift
+++ b/Sources/CanopyApp/Terminal/TerminalSurface.swift
@@ -6,6 +6,7 @@ import SwiftUI
 /// The terminal view belongs to the pane, so it keeps its screen while its tab or row is out of view.
 struct TerminalSurface: NSViewRepresentable {
     let pane: Pane
+    var takesFocus = true
     var onFocusChange: (Bool) -> Void = { _ in }
     var onSizeChange: (TerminalSize) -> Void = { _ in }
 
@@ -15,6 +16,7 @@ struct TerminalSurface: NSViewRepresentable {
     }
 
     func updateNSView(_ container: TerminalContainerView, context: Context) {
+        container.takesFocus = takesFocus
         container.onFocusChange = onFocusChange
         container.onSizeChange = onSizeChange
     }
@@ -28,6 +30,7 @@ final class TerminalContainerView: NSView {
     static let padding = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)
 
     private let emulator: SwiftTermEmulator
+    var takesFocus = true
     var onFocusChange: (Bool) -> Void = { _ in }
     var onSizeChange: (TerminalSize) -> Void = { _ in }
     private var focusObservation: NSKeyValueObservation?
@@ -70,8 +73,10 @@ final class TerminalContainerView: NSView {
                 self.onFocusChange(window.firstResponder === self.emulator.view)
             }
         }
-        // A terminal that comes into view takes the keyboard.
-        window?.makeFirstResponder(emulator.view)
+        // The tab's focused terminal takes the keyboard when it comes into view.
+        if takesFocus {
+            window?.makeFirstResponder(emulator.view)
+        }
     }
 
     override func viewDidChangeEffectiveAppearance() {
```

- [ ] **Step 2: Build without warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:"`
Expected: no output.

- [ ] **Step 3: Check it in the running app**

Start a dev build against a throwaway home with a selected row and check, with window screenshots:
- `⌘D` three times adds panes by the add rule. In a window too narrow for two 80-column panes, each goes on a new line.
- `⌘⌥↑` moves focus to the pane above, and typing goes there.
- Dragging a divider resizes its neighbors and stops at 20 columns or 5 rows.
- Dragging a pane's header onto another pane's lower quarter puts it below that pane, splitting the space 50/50.
- `cd /tmp` in one pane, `⌘Q`, relaunch: the same tabs, layout, and proportions come back, and that pane's prompt is in `/tmp`.

- [ ] **Step 4: Commit and open the PR**

```bash
make lint && make build && make test && make e2e
git add Sources
git commit -m "feat: split, resize, and rearrange panes, and restore layouts on relaunch"
git push -u origin feat/grid
```

Open the PR with a Summary, a Testing section, and `🤖 Generated with [Claude Code](https://claude.com/claude-code)` at the end.
