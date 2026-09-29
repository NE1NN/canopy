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
