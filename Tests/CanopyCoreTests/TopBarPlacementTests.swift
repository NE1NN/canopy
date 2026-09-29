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
        #expect(!TopBarPlacement(isSidebarHidden: false, isFullScreen: false).windowControlsOverBar)
    }

    @Test func aHiddenSidebarLeavesTheWindowControlsOverTheBar() {
        #expect(TopBarPlacement(isSidebarHidden: true, isFullScreen: false).windowControlsOverBar)
    }

    @Test func fullScreenKeepsTheWindowControlsOffTheBar() {
        #expect(!TopBarPlacement(isSidebarHidden: true, isFullScreen: true).windowControlsOverBar)
        #expect(!TopBarPlacement(isSidebarHidden: false, isFullScreen: true).windowControlsOverBar)
    }
}
