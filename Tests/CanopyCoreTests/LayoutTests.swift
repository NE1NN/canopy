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

    @Test func shapeNamesTheArrangementForATabsIcon() {
        #expect(Grid.leaf("A").shape == .single)
        #expect(Grid.built(["A", "B"], perLine: 3).shape == .columns(2))
        #expect(Grid.built(["A", "B", "C"], perLine: 3).shape == .columns(3))
        #expect(Grid.built(["A", "B"], perLine: 1).shape == .rows(2))
        #expect(Grid.built(["A", "B", "C"], perLine: 2).shape == .grid)
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
