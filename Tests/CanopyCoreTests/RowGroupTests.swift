import Testing

@testable import CanopyCore

struct RowGroupTests {
    /// Ungrouped rows a and b, "Review" holding c and d, and an empty "Later".
    func entry() -> RepoEntry {
        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: ["a", "b"])
        entry.groups = [RowGroup(name: "Review", rows: ["c", "d"]), RowGroup(name: "Later", collapsed: true)]
        return entry
    }

    /// Moves a row and says whether it moved, outside `#expect`, which cannot hold a mutating call.
    func moved(_ entry: inout RepoEntry, _ path: String, to placement: RowPlacement) throws -> Bool {
        try entry.move(path, to: placement, repo: "r")
    }

    @Test func namesAreTrimmedAndMustHoldSomething() throws {
        #expect(try GroupName.validated("  Review \n") == "Review")
        #expect(try GroupName.validated("Code review") == "Code review")
        for bad in ["", "   ", "\n", "a\tb", "a\nb", "a\u{7}b"] {
            #expect(throws: WorkspaceError.invalidGroupName(bad)) { try GroupName.validated(bad) }
        }
    }

    @Test func namesAreUniqueIgnoringCase() throws {
        var entry = entry()

        #expect(throws: WorkspaceError.groupExists("Review", repo: "r")) { try entry.addGroup(" review ", repo: "r") }
        #expect(throws: WorkspaceError.invalidGroupName(" ")) { try entry.addGroup(" ", repo: "r") }

        let added = try entry.addGroup(" Spikes ", repo: "r")
        #expect(added == RowGroup(name: "Spikes"))
        #expect(entry.groups.map(\.name) == ["Review", "Later", "Spikes"])
    }

    @Test func renamingToAnotherCaseOfItsOwnNameIsAllowed() throws {
        var entry = entry()

        let renamed = try entry.renameGroup("review", to: "REVIEW", repo: "r")
        #expect(renamed.name == "REVIEW")
        #expect(entry.groups.map(\.name) == ["REVIEW", "Later"])
        #expect(entry.groups[0].rows == ["c", "d"])

        #expect(throws: WorkspaceError.groupExists("Later", repo: "r")) {
            try entry.renameGroup("REVIEW", to: "later", repo: "r")
        }
        #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "r")) {
            try entry.renameGroup("Nope", to: "Other", repo: "r")
        }
        #expect(throws: WorkspaceError.invalidGroupName("")) { try entry.renameGroup("Later", to: "", repo: "r") }
    }

    @Test func lookupsTrimAndIgnoreCase() {
        let entry = entry()

        #expect(entry.groupIndex(named: " REVIEW ") == 0)
        #expect(entry.groupIndex(named: "later") == 1)
        #expect(entry.groupIndex(named: "Rev") == nil)
        #expect(entry.groupName(of: "d") == "Review")
        #expect(entry.groupName(of: "a") == nil)
        #expect(entry.holds("a") && entry.holds("d") && !entry.holds("z"))
    }

    @Test func removingAGroupUngroupsItsRowsInOrder() throws {
        var entry = entry()

        let removed = try entry.removeGroup("review", repo: "r")

        #expect(removed == RowGroup(name: "Review", rows: ["c", "d"]))
        #expect(entry.rowOrder == ["a", "b", "c", "d"])
        #expect(entry.groups.map(\.name) == ["Later"])
        #expect(throws: WorkspaceError.groupNotFound("Review", repo: "r")) {
            try entry.removeGroup("Review", repo: "r")
        }
    }

    @Test func movesPlaceRowsWhereAsked() throws {
        var entry = entry()

        #expect(try moved(&entry, "a", to: .group("later")))
        #expect(entry.rowOrder == ["b"])
        #expect(entry.groups[1].rows == ["a"])

        #expect(try moved(&entry, "b", to: .group("Review")))
        #expect(entry.rowOrder == [])
        #expect(entry.groups[0].rows == ["c", "d", "b"])

        #expect(try moved(&entry, "d", to: .ungrouped))
        #expect(entry.rowOrder == ["d"])
        #expect(entry.groups[0].rows == ["c", "b"])

        #expect(try moved(&entry, "a", to: .before("d")))
        #expect(entry.rowOrder == ["a", "d"])
        #expect(entry.groups[1].rows == [])

        #expect(try moved(&entry, "a", to: .after("c")))
        #expect(entry.rowOrder == ["d"])
        #expect(entry.groups[0].rows == ["c", "a", "b"])

        #expect(try moved(&entry, "b", to: .before("c")))
        #expect(entry.groups[0].rows == ["b", "c", "a"])

        #expect(try moved(&entry, "b", to: .after("a")))
        #expect(entry.groups[0].rows == ["c", "a", "b"])
    }

    @Test func movesThatChangeNothingReturnFalse() throws {
        var entry = entry()
        let before = entry

        #expect(try !moved(&entry, "c", to: .group("review")))
        #expect(try !moved(&entry, "d", to: .group("Review")))
        #expect(try !moved(&entry, "a", to: .ungrouped))
        #expect(try !moved(&entry, "b", to: .after("a")))
        #expect(try !moved(&entry, "a", to: .before("b")))
        #expect(try !moved(&entry, "d", to: .after("c")))
        #expect(entry == before)
    }

    @Test func movesRejectBadTargets() {
        var entry = entry()
        let before = entry

        #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "r")) {
            try entry.move("a", to: .group("Nope"), repo: "r")
        }
        #expect(throws: WorkspaceError.invalidAnchor("a")) { try entry.move("a", to: .before("a"), repo: "r") }
        #expect(throws: WorkspaceError.invalidAnchor("/r")) { try entry.move("a", to: .after("/r"), repo: "r") }
        #expect(throws: WorkspaceError.rowNotFound("z")) { try entry.move("z", to: .ungrouped, repo: "r") }
        #expect(entry == before)
    }

    @Test func reconcileFollowsGit() {
        var entry = entry()

        var changed = entry.reconcile(present: ["a", "b", "c", "d"])
        #expect(!changed)

        changed = entry.reconcile(present: ["a", "c", "e", "f"], joining: ["f": "later"])
        #expect(changed)
        #expect(entry.rowOrder == ["a", "e"])
        #expect(
            entry.groups == [
                RowGroup(name: "Review", rows: ["c"]), RowGroup(name: "Later", rows: ["f"], collapsed: true),
            ])

        changed = entry.reconcile(present: ["a", "e", "g"], joining: ["g": "Gone"])
        #expect(changed)
        #expect(entry.rowOrder == ["a", "e", "g"])
        #expect(entry.groups.map(\.rows) == [[], []])
    }

    @Test func aPathInTwoPlacesKeepsTheFirstGroup() {
        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: ["a", "b", "a"])
        entry.groups = [RowGroup(name: "One", rows: ["b", "c"]), RowGroup(name: "Two", rows: ["c", "b", "d", "d"])]

        let changed = entry.reconcile(present: ["a", "b", "c", "d"])

        #expect(changed)
        #expect(entry.rowOrder == ["a"])
        #expect(entry.groups.map(\.rows) == [["b", "c"], ["d"]])
    }
}
