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
