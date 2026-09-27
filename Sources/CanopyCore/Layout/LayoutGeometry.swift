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
