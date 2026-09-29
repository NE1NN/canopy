# Canopy Full Screen Top Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full screen shows the whole top bar, the crumb, tabs, Split Pane, and New Tab, as a window does.

**Architecture:** The top bar is an overlay drawn in the window's title bar row, which `.windowStyle(.hiddenTitleBar)` leaves transparent (see "The title bar row" in `2026-09-28-canopy-ui-polish.md`).
Full screen moves the title bar and its toolbar into a window of their own, opaque over the top of the screen, so that window covered the bar.
The toolbar now shows in full screen only while the pointer is at the top, and whenever it does show, the bar sits below it instead of under it.
A small `TopBarPlacement` in CanopyCore decides where the bar goes, and a `FullScreenReader` tells the views whether the window is in full screen.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, and "The title bar row" in `docs/superpowers/plans/2026-09-28-canopy-ui-polish.md`.

## Cause

The author reported that in full screen the right end of the window, with the split button and `+`, was missing, as if the content ran past the screen.
It does not: the bar is laid out where it belongs, with its buttons inside the screen.
Full screen puts the title bar in its own window, which paints an opaque strip, 52 points tall, across the top of the screen.
It covers the whole top bar, crumb and tabs included, and leaves only the sidebar toggle showing.

It reproduces every time without the author's screens: a virtual display (`CGVirtualDisplay`, parked right of every real display) takes the dev build's window into full screen on a Space of its own, and window shots show the strip over the bar in dark and light, with the sidebar shown and hidden.

## Global Constraints

- A window looks exactly as before: the bar in the title bar row, 52 points tall, with 150 points of room for the traffic lights and the sidebar toggle while the sidebar is hidden.
- Full screen shows what a window shows, in dark and light, with the sidebar shown and hidden.
- The bar is never under the full screen title bar, whether it hides (the default here), shows because the window reopened in full screen, or shows because the author chose View > Always Show Toolbar in Full Screen.
- No warnings in Swift 6 language mode.

## Decisions to Review

1. **The toolbar hides in full screen until the pointer reaches the top of the screen** (`.windowToolbarFullScreenVisibility(.onHover)`), like the menu bar.
   Full screen then looks like the window, with the bar at the top.
   The sidebar toggle shows with the menu bar, and `⌃⌘S` still works.
   The alternative, keeping the toolbar, leaves an empty 52 point strip above the bar.
2. **When the toolbar does show in full screen, the bar goes below it** rather than under it.
   This covers a window that reopens in full screen and the View menu's Always Show Toolbar in Full Screen, where the hover setting does not apply.
3. **With the sidebar hidden in full screen, the crumb starts at the leading edge.**
   The traffic lights and the sidebar toggle are not over the bar in full screen, so the 150 point gap would be empty.
   PR 12's review noted this gap and left it.

## Review Focus

- A window that reopens in full screen at launch: the bar must go below the title bar as soon as the reader has read the window, one run loop turn after it attaches.
- Leaving full screen: the bar must return to the title bar row, with its 150 point inset when the sidebar is hidden.
- The toolbar revealed by the pointer in full screen slides the content down; the bar must stay whole and clickable.
- Clicks in the bar in full screen: tabs, Split Pane, New Tab.
- Dragging and double-clicking the bar in a window still move and zoom it.

---

## Task 1: Where the bar goes

**Files:**
- Create: `Sources/CanopyCore/Layout/TopBarPlacement.swift`
- Test: `Tests/CanopyCoreTests/TopBarPlacementTests.swift`

**Interfaces:**
- Produces: `TopBarPlacement(isSidebarHidden: Bool, isFullScreen: Bool)` with `fillsTitleBar: Bool` and `leadingInset: Double`, and the constants `TopBarPlacement.edge` (10) and `TopBarPlacement.windowControls` (150).

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test`
Expected: FAIL to build with "cannot find 'TopBarPlacement' in scope".

- [ ] **Step 3: Write `TopBarPlacement`**

```swift
/// Where the top bar sits. In a window it takes the title bar's row, which is transparent, and the traffic lights and
/// the sidebar toggle sit over the sidebar, or over the bar's leading end once the sidebar is hidden. Full screen moves
/// the title bar into a window of its own, opaque over the top of the screen whenever it shows, so the bar goes below
/// it, and the window controls are never over the bar.
public struct TopBarPlacement: Equatable, Sendable {
    public static let edge = 10.0
    /// Room for the traffic lights and the sidebar toggle.
    public static let windowControls = 150.0

    public var fillsTitleBar: Bool
    public var leadingInset: Double

    public init(isSidebarHidden: Bool, isFullScreen: Bool) {
        fillsTitleBar = !isFullScreen
        leadingInset = isSidebarHidden && !isFullScreen ? Self.windowControls : Self.edge
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: PASS, with the `TopBarPlacementTests` suite passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Layout/TopBarPlacement.swift Tests/CanopyCoreTests/TopBarPlacementTests.swift
git commit -m "feat: say where the top bar goes in a window and in full screen"
```

## Task 2: Full screen in the views

**Files:**
- Create: `Sources/CanopyApp/FullScreenReader.swift`
- Modify: `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/Terminal/TopBarView.swift`, `Sources/CanopyApp/Terminal/RowTerminalsView.swift`

**Interfaces:**
- Consumes: `TopBarPlacement` from Task 1.
- Produces: `FullScreenReader(isFullScreen: Binding<Bool>)`, the environment value `topBarFillsTitleBar`, and `TopBarView(row:isSidebarHidden:leadingInset:)`.

The reader watches its own window, so it never mistakes another window's full screen for this one's.
It reads the window's style mask once attached, because a window restored into full screen at launch may enter it before any view is listening.

- [ ] **Step 1: Add the reader**

```swift
import AppKit
import SwiftUI

/// Whether the view's window is in full screen. It flips as a transition starts, so the layout moves with the window,
/// and it reads the window once attached, since a window can reopen in full screen.
struct FullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
    }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [
                (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false),
            ].map { name, value in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(value) }
                }
            }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            // Not during the view update that attached this view.
            Task { @MainActor [weak self] in self?.onChange(isFullScreen) }
        }
    }
}
```

- [ ] **Step 2: Hide the full screen toolbar, and place the bar and the detail's empty strip by `TopBarPlacement`**

```diff
diff --git a/Sources/CanopyApp/RootView.swift b/Sources/CanopyApp/RootView.swift
index f59a6d9..5aae600 100644
--- a/Sources/CanopyApp/RootView.swift
+++ b/Sources/CanopyApp/RootView.swift
@@ -7,14 +7,18 @@ struct RootView: View {
     @Environment(AppModel.self) private var model
     @State private var columns = NavigationSplitViewVisibility.all
     @State private var detailFrame = CGRect.zero
+    @State private var isFullScreen = false
 
     var body: some View {
         @Bindable var model = model
+        let isSidebarHidden = columns == .detailOnly
+        let placement = TopBarPlacement(isSidebarHidden: isSidebarHidden, isFullScreen: isFullScreen)
         NavigationSplitView(columnVisibility: $columns) {
             SidebarView()
                 .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
         } detail: {
             RowDetailView()
+                .environment(\.topBarFillsTitleBar, placement.fillsTitleBar)
                 .onGeometryChange(for: CGRect.self) {
                     $0.frame(in: .global)
                 } action: {
@@ -23,13 +27,16 @@ struct RootView: View {
         }
         .overlay(alignment: .topLeading) {
             if let row = model.selectedRow, !row.isMissing {
-                TopBarView(row: row, isSidebarHidden: columns == .detailOnly)
+                TopBarView(row: row, isSidebarHidden: isSidebarHidden, leadingInset: placement.leadingInset)
                     .frame(width: detailFrame.width)
                     .offset(x: detailFrame.minX)
-                    .ignoresSafeArea(.container, edges: .top)
+                    .ignoresSafeArea(.container, edges: placement.fillsTitleBar ? .top : [])
             }
         }
         .frame(minWidth: 900, minHeight: 560)
+        // Full screen shows the bar at the top, as a window does, with the toolbar only while the pointer is there.
+        .windowToolbarFullScreenVisibility(.onHover)
+        .background(FullScreenReader(isFullScreen: $isFullScreen))
         .overlay(alignment: .bottom) {
             if let toast = model.toast {
                 ToastView(message: toast)
@@ -85,6 +92,18 @@ struct RootView: View {
     }
 }
 
+private struct TopBarFillsTitleBarKey: EnvironmentKey {
+    static let defaultValue = true
+}
+
+extension EnvironmentValues {
+    /// Whether the top bar takes the title bar's row, so the detail leaves that row to it.
+    var topBarFillsTitleBar: Bool {
+        get { self[TopBarFillsTitleBarKey.self] }
+        set { self[TopBarFillsTitleBarKey.self] = newValue }
+    }
+}
+
 struct RowDetailView: View {
     @Environment(AppModel.self) private var model
 
diff --git a/Sources/CanopyApp/Terminal/RowTerminalsView.swift b/Sources/CanopyApp/Terminal/RowTerminalsView.swift
index d75bdbf..6de7183 100644
--- a/Sources/CanopyApp/Terminal/RowTerminalsView.swift
+++ b/Sources/CanopyApp/Terminal/RowTerminalsView.swift
@@ -4,6 +4,7 @@ import SwiftUI
 /// The detail area for a row: the top bar with its tabs, and the selected tab's terminals.
 struct RowTerminalsView: View {
     @Environment(AppModel.self) private var model
+    @Environment(\.topBarFillsTitleBar) private var topBarFillsTitleBar
     let row: Row
 
     var body: some View {
@@ -34,8 +35,8 @@ struct RowTerminalsView: View {
                     }
                 }
             }
-            // The top bar takes the title bar's row. The window's title bar is hidden, so clicks reach it.
-            .ignoresSafeArea(.container, edges: .top)
+            // In a window the top bar takes the title bar's row. The title bar is hidden, so clicks reach it.
+            .ignoresSafeArea(.container, edges: topBarFillsTitleBar ? .top : [])
         }
     }
 }
diff --git a/Sources/CanopyApp/Terminal/TopBarView.swift b/Sources/CanopyApp/Terminal/TopBarView.swift
index 055c7d6..3393d9d 100644
--- a/Sources/CanopyApp/Terminal/TopBarView.swift
+++ b/Sources/CanopyApp/Terminal/TopBarView.swift
@@ -7,8 +7,9 @@ import SwiftUI
 struct TopBarView: View {
     @Environment(AppModel.self) private var model
     let row: Row
-    /// While the sidebar is hidden, the bar names the row and leaves room for the traffic lights and sidebar toggle.
+    /// While the sidebar is hidden, the bar names the row.
     let isSidebarHidden: Bool
+    let leadingInset: Double
     @State private var stripWidth = 0.0
 
     var body: some View {
@@ -48,8 +49,8 @@ struct TopBarView: View {
             IconButton(
                 title: "New Tab", systemImage: "plus", shortcut: "⌘T", size: 26, imageSize: 13, action: model.newTab)
         }
-        .padding(.leading, isSidebarHidden ? Self.trafficLightsInset : 10)
-        .padding(.trailing, 10)
+        .padding(.leading, leadingInset)
+        .padding(.trailing, TopBarPlacement.edge)
         .frame(height: Style.topBarHeight)
         .background {
             TitleBarArea()
@@ -59,9 +60,6 @@ struct TopBarView: View {
             Rectangle().fill(.separator).frame(height: 1)
         }
     }
-
-    /// Room for the traffic lights and the sidebar toggle, which sit over the bar's leading end.
-    static let trafficLightsInset = 150.0
 }
 
 /// Empty title bar space: dragging it moves the window, and double-clicking it does what the system setting says.
```

- [ ] **Step 3: Check it builds with no warnings and passes lint**

Run: `make lint && make build 2>&1 | grep -c warning:`
Expected: lint passes, and the count is 0.

- [ ] **Step 4: Check full screen with window shots**

Open the fixture with `scripts/ui-fixture.sh dark`, then `light`, and put the window into full screen.
The window shots must show the crumb, the tabs, Split Pane, and New Tab, with the sidebar shown and hidden, and a window must look as before.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyApp
git commit -m "fix: full screen shows the whole top bar"
```

## After Review

An independent reviewer read `git diff main...HEAD` with this plan and the spec.
Each finding and what became of it:

1. **The first read could overwrite a later notification.**
   The reader took the style mask when it attached and reported it one turn later, so a window that entered full screen in between got a stale `false`, and the bar went back under the title bar.
   Fixed: the task reads the window when it runs.
2. **A failed transition left the flag stuck.**
   Only the window's delegate, which SwiftUI owns, hears that a transition failed.
   Fixed: the reader also reads the style mask on `didEnterFullScreen`, `didExitFullScreen`, and `didResize`, so the flag settles on the window's real state.
   The `will` notifications still flip it at once, so the layout moves with the transition.
3. **Review Focus promised the right place from the first frame,** which the reader cannot do, since it reads one turn after it attaches.
   Fixed: the line now says so.
4. **Double-clicking the bar in full screen** zoomed, or tried to minimize a full screen window, which AppKit refuses.
   Fixed: it does nothing in full screen, like the system's title bar.
5. **The toolbar revealed by the pointer might slide over the bar instead of pushing it down.**
   Not changed: a window shot on the built-in display with the toolbar revealed shows the content pushed down, with the whole bar below the toolbar.
6. **The reader's observers are not removed when it is freed.**
   Not changed: they go whenever the view leaves its window, and each holds the view weakly and is scoped to that window.
7. **The spec still said the bar always takes the title bar row.**
   Fixed: "Tabs" says what full screen does.
8. **Point values moved into CanopyCore,** though `Style` holds every size.
   Fixed: `TopBarPlacement` keeps only the decisions, `fillsTitleBar` and `windowControlsOverBar`, and `Style.topBarInset` and `Style.windowControlsWidth` hold the 10 and 150 points.
9. **The environment key lived in `RootView.swift`,** though only `RowTerminalsView` reads it.
   Fixed: it moved there.

