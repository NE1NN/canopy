/// Where the top bar sits. In a window it takes the title bar's row, which is transparent, and the traffic lights and
/// the sidebar toggle sit over the sidebar, or over the bar's leading end once the sidebar is hidden. Full screen moves
/// the title bar into a window of its own, opaque over the top of the screen whenever it shows, so the bar goes below
/// it, and the window controls are never over the bar.
public struct TopBarPlacement: Equatable, Sendable {
    public var fillsTitleBar: Bool
    public var windowControlsOverBar: Bool

    public init(isSidebarHidden: Bool, isFullScreen: Bool) {
        fillsTitleBar = !isFullScreen
        windowControlsOverBar = isSidebarHidden && !isFullScreen
    }
}
