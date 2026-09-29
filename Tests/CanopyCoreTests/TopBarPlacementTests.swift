import Testing

@testable import CanopyCore

struct TopBarPlacementTests {
    @Test func aWindowsBarTakesTheTitleBarRow() {
        #expect(TopBarPlacement(isSidebarHidden: false, isFullScreen: false).fillsTitleBar)
        #expect(TopBarPlacement(isSidebarHidden: true, isFullScreen: false).fillsTitleBar)
    }

    /// Full screen draws the title bar in a window of its own, opaque, over the top of the screen whenever it shows.
    @Test func aFullScreenBarStaysBelowTheTitleBar() {
        #expect(!TopBarPlacement(isSidebarHidden: false, isFullScreen: true).fillsTitleBar)
        #expect(!TopBarPlacement(isSidebarHidden: true, isFullScreen: true).fillsTitleBar)
    }

    @Test func theSidebarHoldsTheWindowControlsWhileItShows() {
        #expect(TopBarPlacement(isSidebarHidden: false, isFullScreen: false).leadingInset == TopBarPlacement.edge)
    }

    @Test func aHiddenSidebarLeavesTheWindowControlsOverTheBar() {
        #expect(
            TopBarPlacement(isSidebarHidden: true, isFullScreen: false).leadingInset == TopBarPlacement.windowControls)
    }

    @Test func fullScreenKeepsTheWindowControlsOffTheBar() {
        #expect(TopBarPlacement(isSidebarHidden: true, isFullScreen: true).leadingInset == TopBarPlacement.edge)
        #expect(TopBarPlacement(isSidebarHidden: false, isFullScreen: true).leadingInset == TopBarPlacement.edge)
    }
}
