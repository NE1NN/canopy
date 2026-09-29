# The Repo Menu Opens on Every Click Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A click anywhere on a sidebar header's `…` opens its menu and never folds the repo, group, or plugin section, while a click on the rest of the header still folds it.

**Architecture:** `IconMenu` gives its menu label the 22-point frame and a `contentShape`, as `IconButton` already does, so the whole button takes clicks instead of only the glyph's pixels.
Each foldable header (repo, group, plugin section) splits into a summary, which VoiceOver reads as the one button that folds it, and its hover buttons beside it, which VoiceOver reads as controls of their own.

**Tech Stack:** Swift 6 language mode, SwiftUI on macOS 15.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Sidebar", and the author's report on 2026-09-29: "the 3 dots for each repo idk why most of the times it doesnt work when clicked. i think it's because it thinks im trying to collapse/uncollapse action instead."

## Global Constraints

- A click anywhere in a `…` button's 22 by 22 point box opens its menu, hovered first or not, with the repo expanded or folded, in dark and light.
- A click on the rest of a header (tile, name, chevron, tags, the gap between the buttons, the dot and count) still folds or unfolds it.
- VoiceOver reads a header and its `…` and `+` as separate controls, and a header's label still says its row count and agent dot.
- The headers look the same as on `main`, including which part gives way in a narrow sidebar.
- Swift 6 strict concurrency with no warnings, and `swift format lint --strict` clean.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. A click on the edge of the `…` box, where the glyph's pixels are not: opens the menu.
   Checked by the click loop at the box's center, 7.5 points above, below, left, and right of it, and 10 points out on both diagonals.
2. A click without a hover first, as when the pointer jumps straight to the button: opens the menu, not a fold.
   The click loop runs every point both ways.
3. The `+` beside `…`: opens the New Row sheet at every point of its box and never folds.
   Checked by the click loop with the sheet counted as its own outcome.
4. A missing repo in a narrow sidebar, where the header always shows `Locate…` and `…`: the name keeps its width and `Locate…` gives way first, as on `main`.
   Checked in window shots at the 252-point sidebar on `main` and on this branch.
5. VoiceOver on a hovered header: the header stays a plain button and does not become a menu button, and the header's context menu and named actions still work.
   Checked with an accessibility tree dump and `AXPress` / `AXShowMenu` performed through the accessibility API.

The app target has no test target, and the bug is SwiftUI hit testing with no logic to move into CanopyCore, so the regression check is the scripted click loop under "Click Loop", run against the dev build.

## Reproduction

`scripts/ui-fixture.sh dark` opened the dev build from `84ad205` (PR 30, collapse a repo), and the click loop below clicked web-app's `…` and the Later group's `…`.
The `…` box is 22 by 22 points; its glyph, the 12-point medium `ellipsis`, is about 13 by 3 points of it.
Each point was clicked five times with a hover first and five without, or three times for the group.

| Point in the `…` box | Repo, hover | Repo, no hover | Group, hover | Group, no hover |
| --- | --- | --- | --- | --- |
| Glyph center | menu 5 of 5 | menu 5 of 5 | menu 4, nothing 1 | menu 3 of 3 |
| 3.5 to 4 points above or below center | fold 9, nothing 1 | fold 10 of 10 | fold 10 of 10 | fold 6 of 6 |
| 7.5 points above or below | fold 10 of 10 | fold 10 of 10 | not run | not run |
| 7.5 to 8 points left or right | fold 9, nothing 1 | fold 10 of 10 | fold 8, nothing 2 | fold 6 of 6 |
| Near a corner | fold 10 of 10 | fold 10 of 10 | fold 10 of 10 | fold 6 of 6 |

A click on the glyph itself opened the menu every time.
A click anywhere else in the box folded the repo or group every time, except a few clicks that did nothing when another app took focus in the middle of the run.
The `+` beside it opened the New Row sheet from the corner of its box and never folded.

## Cause

`IconMenu` put `.frame(width: 22, height: 22)` and its hover fill on the `Menu`, outside its label:

```swift
Menu { items } label: {
    Image(systemName: systemImage)
        .font(.system(size: 12, weight: .medium))
}
.menuStyle(.button)
.buttonStyle(.plain)
.menuIndicator(.hidden)
.frame(width: 22, height: 22)
```

A plain-style button hit-tests only what its label draws, and the label is the glyph alone, so only the three dots' pixels took clicks.
The frame outside it only made the view bigger, and the header under it has `.contentShape(Rectangle()).onTapGesture(perform: toggle)`, so every click that missed the dots folded the header.
The `…` looked like a 22-point button because the hover fill drew that box, but about a tenth of it took clicks.
`IconButton` already puts its frame and `.contentShape(Rectangle())` inside its label, which is why `+` always worked.

`IconMenu` has three other callers: the Repos section's `+` (Add), the group header's `…`, and the plugin section header's `…`.
The group and plugin headers folded the same way; the Repos `+` sits on no tap gesture, so a click off its glyph did nothing.

A second problem showed up while checking VoiceOver: each header was `.accessibilityElement(children: .combine)` over its whole content, so while hovered, the `…` merged into it and the header read as a menu button, with the `+` as a duplicate named action.

## Design

`IconMenu` draws its frame, hover fill, and `contentShape` inside the menu's label, matching `IconButton`, so the whole 22-point box is the button.

Each foldable header keeps its tap gesture, hover, context menu, and popovers on the whole row, so every part that is not a button still folds.
Inside it, a `summary` view holds the tile, name, chevron, and tags, and carries the header's accessibility: one element, its label, value, traits, fold action, and named actions.
The spacer, agent dot, count, and hover buttons sit beside the summary in the row.
The dot and count are hidden from VoiceOver, since the header's label already says them, and the buttons stay controls of their own.
The summary has `.layoutPriority(1)`, so in a narrow sidebar the name keeps its width and a missing repo's `Locate…` gives way first, as on `main`.
Without it, a missing repo at the 252-point sidebar showed its name as "d" and `Locate…` whole, where `main` shows "docs" and "Loca…".

The group header also gains the "New Row…" named action the repo and plugin headers have, since its `+` shows only on hover.

## File Structure

- Modify `Sources/CanopyApp/Style/Style.swift`: `IconMenu` moves its frame, hover fill, and `contentShape` into the label.
- Modify `Sources/CanopyApp/Sidebar/SidebarView.swift`: `RepoHeaderView` gets a `summary` and `showsButtons`.
- Modify `Sources/CanopyApp/Sidebar/GroupViews.swift`: `GroupHeaderView` the same, plus the "New Row…" named action.
- Modify `Sources/CanopyApp/Plugins/PluginSectionView.swift`: `PluginHeaderView` the same.

## Task 1: The `…` takes clicks across its whole box

**Files:**
- Modify: `Sources/CanopyApp/Style/Style.swift`

- [ ] **Step 1: Run the click loop on the unfixed build and see off-glyph clicks fold**

Run: `make app && scripts/ui-fixture.sh dark`, then the "Click Loop" for web-app's `…`.
Expected: the glyph center opens the menu, every other point folds the repo.

- [ ] **Step 2: Move the frame into the label**

```diff
@@ -162,12 +162,13 @@ struct IconMenu<Items: View>: View {
         } label: {
             Image(systemName: systemImage)
                 .font(.system(size: 12, weight: .medium))
+                .frame(width: 22, height: 22)
+                .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
+                .contentShape(Rectangle())
         }
         .menuStyle(.button)
         .buttonStyle(.plain)
         .menuIndicator(.hidden)
-        .frame(width: 22, height: 22)
-        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
         .foregroundStyle(isHovering ? .primary : .secondary)
         .onHover { isHovering = $0 }
         .help(title)
```

- [ ] **Step 3: Rebuild and rerun the click loop**

Run: `scripts/ui-fixture.sh stop && make app && scripts/ui-fixture.sh dark`, then the "Click Loop" for web-app's `…`.
Expected: every point opens the menu, hovered first or not, and none folds the repo.

## Task 2: Headers read their buttons as separate controls

**Files:**
- Modify: `Sources/CanopyApp/Sidebar/SidebarView.swift`
- Modify: `Sources/CanopyApp/Sidebar/GroupViews.swift`
- Modify: `Sources/CanopyApp/Plugins/PluginSectionView.swift`

**Interfaces:**
- Each header view keeps its initializer and call sites; `summary` and `showsButtons` are private.

- [ ] **Step 1: See the hovered header become a menu button**

Hover web-app's header and dump the accessibility tree with the `ax` tool under "Click Loop".
Expected on the unfixed build: `AXMenuButton desc=web-app, repo, 7 rows` with actions `AXShowMenu`, `AXPress`, `New Row…`, and `New Row in web-app…`, and no separate `More for web-app`.

- [ ] **Step 2: Split the repo header**

```diff
@@ -241,35 +241,18 @@ struct RepoHeaderView: View {
 
     var body: some View {
         HStack(spacing: 8) {
-            RepoTile(mark: repo.mark, isDimmed: repo.isMissing)
-            // The tile holds the header's mark column, so the chevron follows the name.
-            HStack(spacing: 0) {
-                Text(repo.name)
-                    .font(Style.body.weight(.semibold))
-                    .foregroundStyle(repo.isMissing ? .secondary : .primary)
-                    .lineLimit(1)
-                    .truncationMode(.middle)
-                DisclosureChevron(isExpanded: !repo.collapsed)
-            }
-            if repo.isMissing {
-                TagView(text: "missing")
-            }
-            if let error = repo.error {
-                Image(systemName: "exclamationmark.triangle.fill")
-                    .font(Style.meta)
-                    .foregroundStyle(.orange)
-                    .help(error)
-            }
+            summary
             Spacer(minLength: 4)
             if let agentDot {
                 AgentDotView(dot: agentDot)
+                    .accessibilityHidden(true)
             }
             if repo.isMissing {
                 Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
                     .controlSize(.small)
                     .help("Find where \(repo.name) moved")
                 RepoMenu(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true })
-            } else if isHovering || isNamingGroup {
+            } else if showsButtons {
                 RepoMenu(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true })
                 IconButton(title: "New Row in \(repo.name)…", systemImage: "plus", action: onNewRow)
             } else {
@@ -278,6 +261,7 @@ struct RepoHeaderView: View {
                     .monospacedDigit()
                     .foregroundStyle(.tertiary)
                     .padding(.trailing, 5)
+                    .accessibilityHidden(true)
             }
         }
         .padding(.leading, Style.leadingInset(.header))
@@ -294,12 +278,40 @@ struct RepoHeaderView: View {
                 await model.createGroup(in: repo, name: name)
             }
         }
+    }
+
+    /// The tile, name, and tags, which VoiceOver reads as one button that folds the repo, its label saying the row count
+    /// and agent dot too. The header's buttons stay controls of their own: combined into it, they would make it a menu
+    /// button. It keeps its width before them, so a narrow sidebar shortens "Locate…" before the name.
+    private var summary: some View {
+        HStack(spacing: 8) {
+            RepoTile(mark: repo.mark, isDimmed: repo.isMissing)
+            // The tile holds the header's mark column, so the chevron follows the name.
+            HStack(spacing: 0) {
+                Text(repo.name)
+                    .font(Style.body.weight(.semibold))
+                    .foregroundStyle(repo.isMissing ? .secondary : .primary)
+                    .lineLimit(1)
+                    .truncationMode(.middle)
+                DisclosureChevron(isExpanded: !repo.collapsed)
+            }
+            if repo.isMissing {
+                TagView(text: "missing")
+            }
+            if let error = repo.error {
+                Image(systemName: "exclamationmark.triangle.fill")
+                    .font(Style.meta)
+                    .foregroundStyle(.orange)
+                    .help(error)
+            }
+        }
+        .layoutPriority(1)
         .accessibilityElement(children: .combine)
         .accessibilityLabel(accessibilityLabel)
         .accessibilityValue(repo.collapsed ? "Collapsed" : "Expanded")
         .accessibilityAddTraits(holdsSelection ? [.isButton, .isSelected] : .isButton)
         .accessibilityAction { toggle() }
-        // The header reads as one button, so its own buttons are reached as named actions.
+        // The buttons beside it show only on hover, so what they do is also here as named actions.
         .accessibilityActions {
             if repo.isMissing {
                 Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
@@ -309,6 +321,8 @@ struct RepoHeaderView: View {
         }
     }
 
+    private var showsButtons: Bool { isHovering || isNamingGroup }
+
     /// A folded repo holding the selected row shows the selection, so the sidebar always says where the window is.
     private var holdsSelection: Bool { model.selectionFold == .repo(repo.path) }
 
```

- [ ] **Step 3: Split the group header the same way, with its "New Row…" action**

```diff
@@ -27,17 +27,13 @@ struct GroupHeaderView: View {
 
     var body: some View {
         HStack(spacing: 8) {
-            DisclosureChevron(isExpanded: !group.collapsed)
-            Text(group.name)
-                .font(Style.body.weight(.medium))
-                .foregroundStyle(.secondary)
-                .lineLimit(1)
-                .truncationMode(.tail)
+            summary
             Spacer(minLength: 4)
             if let agentDot {
                 AgentDotView(dot: agentDot)
+                    .accessibilityHidden(true)
             }
-            if isHovering || isRenaming || isConfirmingDelete {
+            if showsButtons {
                 IconMenu(title: "More for \(group.name)", systemImage: "ellipsis") {
                     GroupMenuItems(rename: { isRenaming = true }, delete: requestDelete)
                 }
@@ -48,6 +44,7 @@ struct GroupHeaderView: View {
                     .monospacedDigit()
                     .foregroundStyle(.tertiary)
                     .padding(.trailing, 5)
+                    .accessibilityHidden(true)
             }
         }
         .padding(.leading, Style.leadingInset(.section))
@@ -71,6 +68,21 @@ struct GroupHeaderView: View {
                 model.removeGroup(group, in: repo)
             }
         }
+    }
+
+    /// The chevron and name, which VoiceOver reads as one button that folds the group, its label saying the row count and
+    /// agent dot too. The header's buttons stay controls of their own: combined into it, they would make it a menu
+    /// button.
+    private var summary: some View {
+        HStack(spacing: 8) {
+            DisclosureChevron(isExpanded: !group.collapsed)
+            Text(group.name)
+                .font(Style.body.weight(.medium))
+                .foregroundStyle(.secondary)
+                .lineLimit(1)
+                .truncationMode(.tail)
+        }
+        .layoutPriority(1)
         .accessibilityElement(children: .combine)
         .accessibilityLabel(
             "\(group.name), group, \(count == 1 ? "1 row" : "\(count) rows")"
@@ -79,8 +91,14 @@ struct GroupHeaderView: View {
         .accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
         .accessibilityAddTraits(holdsSelection ? [.isButton, .isSelected] : .isButton)
         .accessibilityAction { toggle() }
+        // `+` shows only on hover, so what it does is also here as a named action.
+        .accessibilityActions {
+            Button("New Row…", action: onNewRow)
+        }
     }
 
+    private var showsButtons: Bool { isHovering || isRenaming || isConfirmingDelete }
+
     private var fill: Color {
         if isDropTarget { return Style.focusedSelectionFill }
         if holdsSelection { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
```

- [ ] **Step 4: Split the plugin section header the same way**

```diff
@@ -47,16 +47,11 @@ struct PluginHeaderView: View {
 
     var body: some View {
         HStack(spacing: 8) {
-            PluginTile(info: section.info)
-            HStack(spacing: 0) {
-                Text(section.info.name)
-                    .font(Style.body.weight(.semibold))
-                    .lineLimit(1)
-                DisclosureChevron(isExpanded: !section.collapsed)
-            }
+            summary
             Spacer(minLength: 4)
             if let agentDot {
                 AgentDotView(dot: agentDot)
+                    .accessibilityHidden(true)
             }
             if isHovering {
                 IconMenu(title: "More for \(section.info.name)", systemImage: "ellipsis") {
@@ -69,6 +64,7 @@ struct PluginHeaderView: View {
                     .monospacedDigit()
                     .foregroundStyle(.tertiary)
                     .padding(.trailing, 5)
+                    .accessibilityHidden(true)
             }
         }
         .padding(.leading, Style.leadingInset(.header))
@@ -79,6 +75,22 @@ struct PluginHeaderView: View {
         .onTapGesture(perform: toggle)
         .onHover { isHovering = $0 }
         .contextMenu { PluginMenuItems(section: section, onNewRow: onNewRow) }
+    }
+
+    /// The tile and name, which VoiceOver reads as one button that folds the section, its label saying the row count and
+    /// agent dot too. The header's buttons stay controls of their own: combined into it, they would make it a menu
+    /// button.
+    private var summary: some View {
+        HStack(spacing: 8) {
+            PluginTile(info: section.info)
+            HStack(spacing: 0) {
+                Text(section.info.name)
+                    .font(Style.body.weight(.semibold))
+                    .lineLimit(1)
+                DisclosureChevron(isExpanded: !section.collapsed)
+            }
+        }
+        .layoutPriority(1)
         .accessibilityElement(children: .combine)
         .accessibilityLabel(accessibilityLabel)
         .accessibilityValue(section.collapsed ? "Collapsed" : "Expanded")
```

- [ ] **Step 5: Check the accessibility tree**

Run: `make app`, relaunch the fixture, hover web-app's header, and run `ax <pid>`.
Expected, hovered or not:

```
AXButton desc=web-app, repo, 7 rows value=Expanded actions=["AXShowMenu", "AXPress", "Name:New Row…"]
AXMenuButton desc=More for web-app actions=["AXShowMenu"]
AXButton desc=New Row in web-app… actions=["AXShowMenu", "AXPress"]
AXButton desc=Later, group, 1 row, agent done value=Collapsed actions=["AXShowMenu", "AXPress", "Name:New Row…"]
AXButton desc=Tickets, plugin, 3 rows value=Expanded actions=["AXShowMenu", "AXPress", "Name:New Ticket Row…"]
```

The last three lines of the hovered header only appear while it is hovered.
A missing repo reads `docs, repo, 0 rows, missing` with the `Locate…` named action, then `Locate…` and `More for docs` as their own controls.
`ax <pid> "web-app, repo, 7 rows" AXPress` folds the repo, and `AXShowMenu` on it opens its context menu.

- [ ] **Step 6: Run the click loop in dark and light, then commit**

Run: `matrix.sh dark` and `matrix.sh light` from "Click Loop".
Expected: every `…` point reads `menu 3`, every `+` point `sheet 2`, and every fold point `fold 2`.

```bash
make format && make lint && make build
git add Sources
git commit -m "fix: the repo menu opens on every click"
```

## Click Loop

The loop drives the dev build from `scripts/ui-fixture.sh` with `scripts/ui.swift`, and reads each click's outcome without the window: a menu is an on-screen window of the app above layer 0, a sheet is a second window at layer 0, and a fold is the `collapsed` field of `canopy repo list`, `group list`, or `plugin list`.
After each click it presses Escape, and puts back any fold, so every click starts from the same state.
Build `ui` once with `swiftc -O -o build/ui scripts/ui.swift`, and the helpers below with `swiftc -O -o <folder>/<name> <folder>/<name>.swift`, in one folder outside the repo.
Coordinates are window points, window-shot pixels divided by 2; with the fixture's 252-point sidebar, every header's `…` is centered at x 199.5 and its `+` at 229.5.
Pointer events need the dev build frontmost, so the loop reactivates it before each click and retries a click another app's window refused; it still fails while someone else uses the Mac.

`menus.swift`:

```swift
// Prints how many menu windows (layer above 0) the app with this pid has on screen.
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let menus = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 0 && (($0[kCGWindowLayer as String] as? Int) ?? 0) < 1000 }
print(menus.count)
```

`sheets.swift`:

```swift
// Prints how many windows at layer 0 the app with this pid has on screen beyond its main window: sheets.
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count - 1)
```

`ax.swift`, which dumps the accessibility tree, or performs an action on the element whose description matches exactly:

```swift
// Dumps the app's accessibility tree under its main window, with each element's role, label, value, and actions.
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
// With a third argument, performs that action on the first element whose description is exactly the filter.
let perform = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return v
}
func actions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    // A custom action is named "Name:<title>" and then lines about its target: keep the title.
    return (names as? [String] ?? []).map { String($0.split(separator: "\n").first ?? "") }
}
func dump(_ e: AXUIElement, _ depth: Int) {
    guard depth < 40 else { return }
    let role = attr(e, "AXRole") as? String ?? "?"
    let desc = attr(e, "AXDescription") as? String ?? ""
    let title = attr(e, "AXTitle") as? String ?? ""
    let value = attr(e, "AXValue").map { "\($0)" } ?? ""
    let line = "\(String(repeating: "  ", count: depth))\(role) title=\(title) desc=\(desc) value=\(value) actions=\(actions(e))"
    if let perform {
        if desc == filter { print(AXUIElementPerformAction(e, perform as CFString).rawValue); exit(0) }
    } else if filter.isEmpty || line.contains(filter) { print(line) }
    for child in attr(e, "AXChildren") as? [AXUIElement] ?? [] { dump(child, depth + 1) }
}
let app = AXUIElementCreateApplication(pid)
for w in attr(app, "AXWindows") as? [AXUIElement] ?? [] { dump(w, 0) }
```

`probe.sh`, which clicks points on one header and counts what each click did:

```bash
#!/usr/bin/env bash
# probe.sh <pid> <kind repo|group|plugin|none> <name> <hover 0|1> <times> <x> <y>...
# Clicks each point <times> times and prints menu/fold/nothing counts per point, restoring the fold after each click.
# Run from the repo root, with the tools below built next to this script.
S=$(dirname "$0")
pid=$1 kind=$2 name=$3 hover=$4 times=$5; shift 5
source build/ui-fixture.env
cli() { CANOPY_HOME=$work/home "build/Canopy Dev.app/Contents/Resources/bin/canopy" "$@"; }
state() {
  if [[ $kind == none ]]; then echo same; return; fi
  if [[ $kind == plugin ]]; then cli plugin list --json | python3 -c "import json,sys; print([p['collapsed'] for p in json.load(sys.stdin) if p['id']=='$name'][0])"; return; fi
  if [[ $kind == repo ]]; then cli repo list --json | python3 -c "import json,sys; print([r['collapsed'] for r in json.load(sys.stdin) if r['name']=='$name'][0])"
  else cli group list --repo web-app --json | python3 -c "
import json,sys
d=json.load(sys.stdin)
def walk(o):
  if isinstance(o,dict):
    if o.get('name')=='$name' and 'collapsed' in o: print(o['collapsed']); sys.exit()
    for v in o.values(): walk(v)
  elif isinstance(o,list):
    for v in o: walk(v)
walk(d)"; fi
}
before=$(state)
while (( $# >= 2 )); do
  x=$1 y=$2; shift 2
  m=0 f=0 n=0 sh=0 skipped=0
  for ((i = 0; i < times; i++)); do
    build/ui activate $pid >/dev/null; build/ui move $pid 20 580 >/dev/null; sleep 0.3
    if [[ $hover == 1 ]]; then build/ui move $pid $x $y >/dev/null; sleep 0.5; fi
    # Another app in front (another agent's dev build, or the author) makes the click refuse: try that one again.
    if ! build/ui click $pid $x $y >/dev/null 2>&1; then ((i--)); ((skipped++)); sleep 1; continue; fi
    sleep 0.6
    menus=$($S/menus $pid); sheets=$($S/sheets $pid); now=$(state)
    (( sheets > 0 )) && ((sh++))
    if (( menus > 0 )); then ((m++)); fi
    # Escape closes a menu, or the New Row sheet a `+` opens.
    build/ui key $pid 53 >/dev/null; sleep 0.5
    if [[ $now != "$before" ]]; then ((f++))
      verb=expand; [[ $before == True ]] && verb=collapse
      if [[ $kind == plugin ]]; then cli plugin $verb "$name" >/dev/null
      elif [[ $kind == repo ]]; then cli repo $verb "$name" >/dev/null; else cli group $verb "$name" --repo web-app >/dev/null; fi
      sleep 0.4
    fi
    (( menus == 0 && sheets == 0 )) && [[ $now == "$before" ]] && ((n++))
  done
  echo "($x,$y) hover=$hover: menu $m, sheet $sh, fold $f, nothing $n of $times ($skipped retried)"
done
```

`matrix.sh`, which launches the fixture and runs the probe over every header:

```bash
#!/usr/bin/env bash
# matrix.sh <dark|light>: rebuilt fixture, then every header's `…`, `+`, and fold area, with web-app expanded and collapsed.
# Run from the repo root after make app.
S=$(dirname "$0")
scripts/ui-fixture.sh stop; scripts/ui-fixture.sh $1 | tail -1; source build/ui-fixture.env; P=$pid; sleep 3
cli() { CANOPY_HOME=$work/home "build/Canopy Dev.app/Contents/Resources/bin/canopy" "$@"; }
box() { local x=$1 y=$2; echo $x $y $x $(echo "$y-7.5"|bc) $x $(echo "$y+7.5"|bc) $(echo "$x-7.5"|bc) $y $(echo "$x+7.5"|bc) $y $(echo "$x-10"|bc) $(echo "$y-10"|bc) $(echo "$x+10"|bc) $(echo "$y+10"|bc); }
echo "== $1: web-app expanded: repo …"; $S/probe.sh $P repo web-app 1 3 $(box 199.5 97.5); $S/probe.sh $P repo web-app 0 3 $(box 199.5 97.5)
echo "== group Later …"; $S/probe.sh $P group Later 1 3 $(box 199.5 306.5); $S/probe.sh $P group Later 0 3 $(box 199.5 306.5)
echo "== + on repo and group"; $S/probe.sh $P repo web-app 1 2 $(box 229.5 97.5); $S/probe.sh $P group Later 1 2 $(box 229.5 306.5)
echo "== fold areas: repo name, chevron, gap, left edge, before …; group name, gap"; $S/probe.sh $P repo web-app 1 2 60 97.5 106 97.5 214.5 97.5 21 97.5 170 97.5; $S/probe.sh $P group Later 1 2 60 306.5 214.5 306.5
echo "== Repos + menu"; $S/probe.sh $P none x 0 3 $(box 229.5 65)
cli repo collapse web-app >/dev/null; sleep 0.8
echo "== web-app collapsed: repo …"; $S/probe.sh $P repo web-app 1 3 $(box 199.5 97.5); $S/probe.sh $P repo web-app 0 3 $(box 199.5 97.5)
echo "== plugin Tickets …, +, fold"; $S/probe.sh $P plugin tickets 1 3 $(box 199.5 219.5); $S/probe.sh $P plugin tickets 0 3 $(box 199.5 219.5); $S/probe.sh $P plugin tickets 1 2 229.5 219.5 60 219.5 214.5 219.5
cli repo expand web-app >/dev/null
```

Each line reads like `(199.5,90.0) hover=0: menu 3, sheet 0, fold 0, nothing 0 of 3 (0 retried)`.

## UI Checks

Run on the fixed build rebased onto `00c9f8d` (PRs 31 and 32), with the fixture's sidebar at 252 points.

| Where | Dark | Light |
| --- | --- | --- |
| web-app `…`, expanded, 7 points, hover and not | menu 42 of 42 | menu 42 of 42 |
| web-app `…`, folded, 7 points, hover and not | menu 42 of 42 | menu 41 of 42, 1 lost, then 10 of 10 |
| Later group `…`, 7 points, hover and not | menu 42 of 42 | menu 42 of 42 |
| Tickets plugin `…`, 7 points, hover and not | menu 42 of 42 | menu 42 of 42 |
| Repos `+` (Add) menu, 7 points | menu 21 of 21 | menu 20 of 21, then 10 of 10 |
| Repo, group, and plugin `+`, 7 points each | sheet 30 of 30, no fold | sheet 30 of 30, no fold |
| Name, chevron, left edge, gap between buttons, before `…` | fold 18 of 18 | fold 18 of 18 |

The two lost light clicks happened while the window briefly left the window list ("no window for pid"), with another agent's dev build running beside it, and the same points passed 10 of 10 when run again.

Window shots with each menu opened by a click off its glyph, in dark and light: web-app's menu with the repo expanded and folded, the Later group's, and the Tickets section's.
The hover fill now covers the whole 22-point box the button answers to.
A missing repo's header at the 252-point sidebar is pixel for pixel the same as on `main`.

## Decisions to Review

- The group header gains a "New Row…" accessibility action, like the repo and plugin headers, since its `+` shows only on hover and VoiceOver never hovers.
- A missing repo keeps "Locate…" as a named action on its header although the button now reads as its own control, so the header offers the same actions whether a VoiceOver user lands on it or on its buttons.
- The regression check is the scripted click loop in this plan, not a test: nothing outside the window decides where a click lands, and the app target has no tests.

## Follow-ups

- In a narrow sidebar (seen at 252 points), a missing repo's `Locate…` truncates to "Loca…", on `main` as well; it is also in the `…` menu.
- The dev builds share one defaults domain, so a sidebar width one agent's dev build saves is the next one's starting width, and click coordinates move with it.
