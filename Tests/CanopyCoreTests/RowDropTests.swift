import Testing

@testable import CanopyCore

struct RowDropTests {
    static func row(_ path: String, repo: String = "/web") -> Row {
        Row(repoPath: repo, path: path, branch: path, head: nil, rowClass: .canopy)
    }

    /// web: main, a, the Review header with b and c, and the collapsed Later header. api: main and e.
    static let slots: [DropSlot] = [
        DropSlot(repoPath: "/web", kind: .main("/web"), minY: 0, maxY: 26),
        DropSlot(repoPath: "/web", kind: .row("/web/a", group: nil), minY: 26, maxY: 52),
        DropSlot(repoPath: "/web", kind: .header("Review"), minY: 52, maxY: 78),
        DropSlot(repoPath: "/web", kind: .row("/web/b", group: "Review"), minY: 78, maxY: 104),
        DropSlot(repoPath: "/web", kind: .row("/web/c", group: "Review"), minY: 104, maxY: 130),
        DropSlot(repoPath: "/web", kind: .header("Later"), minY: 130, maxY: 156),
        DropSlot(repoPath: "/api", kind: .main("/api"), minY: 170, maxY: 196),
        DropSlot(repoPath: "/api", kind: .row("/api/e", group: nil), minY: 196, maxY: 222),
    ]

    func target(_ path: String, at y: Double) -> RowDropTarget? {
        RowDrop.target(dragging: Self.row(path), at: y, in: Self.slots)
    }

    @Test func dropSlotsNameTheirRow() {
        #expect(DropSlot.Kind.main("/web").rowPath == "/web")
        #expect(DropSlot.Kind.row("/web/a", group: "Review").rowPath == "/web/a")
        #expect(DropSlot.Kind.header("Review").rowPath == nil)
    }

    @Test func headersTakeTheRowAtTheirEnd() {
        #expect(target("/web/a", at: 60) == RowDropTarget(placement: .group("Review"), indicator: .header("Review")))
        #expect(target("/web/b", at: 77.9) == RowDropTarget(placement: .group("Review"), indicator: .header("Review")))
        #expect(target("/web/a", at: 140) == RowDropTarget(placement: .group("Later"), indicator: .header("Later")))
    }

    @Test func rowHalvesPlaceBeforeOrAfter() {
        #expect(target("/web/a", at: 80) == RowDropTarget(placement: .before("/web/b"), indicator: .above("/web/b")))
        #expect(target("/web/a", at: 100) == RowDropTarget(placement: .after("/web/b"), indicator: .below("/web/b")))
        #expect(target("/web/c", at: 30) == RowDropTarget(placement: .before("/web/a"), indicator: .above("/web/a")))
        #expect(target("/web/c", at: 51) == RowDropTarget(placement: .after("/web/a"), indicator: .below("/web/a")))
    }

    @Test func theMainRowMeansFirstAmongTheUngroupedRows() {
        #expect(target("/web/b", at: 10) == RowDropTarget(placement: .before("/web/a"), indicator: .below("/web")))
        #expect(target("/web/a", at: 10) == RowDropTarget(placement: .ungrouped, indicator: .below("/web")))
    }

    @Test func otherReposAndGapsAreNotTargets() {
        #expect(target("/web/a", at: 30) == nil)
        #expect(target("/web/a", at: 160) == nil)
        #expect(target("/web/a", at: 180) == nil)
        #expect(target("/web/a", at: 200) == nil)
        #expect(target("/web/a", at: -1) == nil)
        #expect(target("/web/a", at: 222) == nil)
    }

    @Test func dropsThatChangeNothingAreNoOps() throws {
        var entry = RepoEntry(path: "/web", dirName: "web", rowOrder: ["/web/a"])
        entry.groups = [RowGroup(name: "Review", rows: ["/web/b", "/web/c"]), RowGroup(name: "Later")]
        let before = entry
        let drops: [(String, Double)] = [("/web/a", 10), ("/web/b", 60), ("/web/c", 100), ("/web/b", 110)]

        for (path, y) in drops {
            let placement = try #require(target(path, at: y)).placement
            let moved = try entry.move(path, to: placement, repo: "web")
            #expect(!moved, "\(path) at \(y)")
        }
        #expect(entry == before)
    }
}
