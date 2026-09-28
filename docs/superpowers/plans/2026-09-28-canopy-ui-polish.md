# Canopy UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Canopy look like a designed Mac tool rather than a default SwiftUI app: a clear sidebar hierarchy, one compact type scale, quieter chrome, and each state drawn the same way everywhere, in dark and light.

**Architecture:** One `Style` file in `CanopyApp` holds every size, font, and fill.
The sidebar drops `List` for Canopy's own rows inside the native sidebar column, and the tab bar moves into the title bar row as a window-level overlay, since SwiftUI content under the title bar inside a split view column loses its clicks.
`CanopyCore` gains three small pieces with tests: an observable running flag on panes, a lasting letter and hue for each repo, and a layout shape for tab icons.

**Tech Stack:** Swift 6.2, SwiftUI and AppKit on macOS 15 and later, SwiftTerm 1.20.0, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Repos", "Sidebar rows", "Starting a shell", "Pane chrome", "Process exit", "Tabs", "Adding a pane", and "Panel" under ports.
Each task updates the spec where it changes what the spec says.

**Mockup:** `build/pages/ui-polish/index.html` (not committed), the direction the author approved on 2026-09-28.

## Design Direction

### Where it stands

Window shots of `main` in dark and light show:

- Three bars stack above every terminal: the window title with the row and repo, the tab bar, and the pane header.
  That is about 110 points of chrome before the first line of output.
- The sidebar uses the system's large sidebar size: 13 point names on 32 point rows, and gray lowercase repo names with no mark of their own.
  Repos and rows barely differ.
- Every row wears the same muted branch mark, so the main checkout looks like any other row.
- Selecting the first row under a repo paints the highlight over the repo header too (item 17 in the carry-over list).
- Repo names, rows, ports, and Add Repo use four unrelated text styles, and Add Repo is the largest text in the sidebar.
- In dark, the terminal and the chrome are nearly the same gray, so panes have no edge.
- SwiftTerm's scroller draws a knob down the right side of every pane.
- Terminal.app's ANSI palette is harsh on dark backgrounds and washed out on white.

### Principles

1. Terminals are the content.
   Chrome gets one bar, hairline borders, and muted text.
2. One compact scale for type, spacing, and fills, shared by the sidebar, tabs, pane headers, and ports.
3. Hierarchy comes from type and marks: uppercase section labels, a colored tile per repo, and primary names over muted details.
4. A state looks the same wherever it appears.
   GitHub's colors mean a PR's state, an accent dot means a program is running, orange means a warning, and a neutral fill means hover or selection.
5. Native where macOS does it well: the window, the split view, the sidebar material, the traffic lights and sidebar toggle, menus, sheets, popovers, and alerts.
   Custom where Canopy needs exact control: sidebar rows, tabs, and pane headers.

### Approach

The sidebar keeps the native sidebar column of `NavigationSplitView`, with its material, collapse, and resize.
Inside it, a `ScrollView` of Canopy's own rows replaces `List`.

Two alternatives were weighed:

- **Tune the native `List`** with `sidebarRowSize` and custom headers.
  It is the least code, but `List` has no hover state, its focused selection is a solid accent capsule (which is why PR colors turn white on a selected row today), and item 17 stays unexplained inside `List`.
- **Fully custom window chrome** without `NavigationSplitView`.
  It gives full control, but loses the system sidebar material, collapse, and resize, and works against the macOS 26 look.

Custom rows keep what `List` gave:

- `⌘1` to `⌘9` still select rows.
- `↑` and `↓` move the selection while the sidebar has focus.
- VoiceOver reads each row as one element with its branch, PR state, and whether a program is running.
- Context menus stay as they are.

Item 17 goes away with `List`.

### The title bar row

The tabs share the title bar row with the traffic lights, so one bar replaces the title strip and the tab bar.
A spike settled how, and each alternative failed in a way that matters:

- **Tabs as toolbar items** looked right, but once the tabs outgrow the bar, the toolbar folds the whole strip, buttons included, into its `»` overflow menu.
- **Tabs as content under a titled window's toolbar** draw, but the toolbar takes their clicks.
- **Hiding the window toolbar** also hides the traffic lights.
- **Tabs as content at the top of the detail column, with `.windowStyle(.hiddenTitleBar)`** work in a small spike app, but in Canopy the column drops every click in the title bar row once terminal panes are on screen.
  Hover still works there, so it only shows when clicking.
  Bisecting pinned it to the pane views but not to any single modifier, and a spike with the same modifiers never reproduced it.

What works: `.windowStyle(.hiddenTitleBar)`, the native toolbar kept for the traffic lights and sidebar toggle, and the top bar drawn as an overlay on the whole `NavigationSplitView`, placed over the detail column by the column's measured frame.
The detail column keeps an empty strip of the same height under it.
The bar is 52 points tall, the toolbar's own height, so the tabs line up with the traffic lights.
Its empty space moves the window with `WindowDragGesture`, and double-clicking it zooms or minimizes as the system's title bar setting says.

### Scale

All sizes and fills live in `Sources/CanopyApp/Style/Style.swift`, so no view picks its own numbers.

| Token | Value | Used for |
|---|---|---|
| Label | 10.5 pt semibold, uppercase, 0.6 pt tracking, tertiary | Repos, Ports |
| Meta | 11 pt, monospaced digits | PR numbers, ports, pane titles, shortcut hints, tags |
| Body | 12 pt | tabs, repo names in semibold, port groups, other worktrees |
| Row | 13 pt | branch names |
| Terminal | 13 pt system monospaced | unchanged from the spec |

- Heights: sidebar row 26, section label and repo header 28, top bar 52, tab 26, pane header 26.
- Radii: 6 for rows, tabs, and icon buttons; 5 for port badges; 4 for tags and repo tiles.
- Fills: hover at 4.5% black in light and 5.5% white in dark, selection at 7.5% and 10%.
  While the sidebar has keyboard focus, the selection turns to the accent color at 17% in light and 30% in dark.
- Chrome (the top bar, pane headers, and exit strips): #F5F5F7 in light, a step off the terminal's white, and the window's own gray in dark, where the terminal is the darker one.

The density is fixed and ignores the system's sidebar size setting, the way Xcode's navigators do.

### Sidebar

- The traffic lights and the sidebar toggle keep the top of the sidebar.
- A "Repos" label heads the list, with a `+` that adds a repo.
  It replaces the Add Repo button at the bottom.
  File > Add Repo… (`⇧⌘O`) and a button in each empty state also add one.
- Each repo header has a 16 point tile with the repo's first letter, the name in Body semibold, and the row count in tertiary.
  On hover the count gives way to `…` (the repo's menu) and `+` (new row).
- The tile's hue is one of eight, picked by a stable hash of the repo's path, so a repo keeps its color across launches.
- A missing repo shows a "missing" tag and a Locate… button in its header, and Remove stays in its menu (item 16).
- Rows share the header's two columns: the mark sits under the tile and the name under the repo name.
- The main checkout gets a trunk mark in place of the branch mark.
- After the name come a running dot, when a program runs in one of the row's terminals, and the PR number in its state color.
  Hover adds the `⌘N` hint and `×`, as today.
- A selected row keeps its PR colors.
- Other worktrees fold into a muted "3 other worktrees" disclosure row.
- The PR lookup warning, "missing", and tags from other tools use the Meta size.
- A row selected by `⌘N` or `canopy row select` scrolls into view.

### Ports

- The ports panel sits below the repo list, under a hairline, so rows never scroll under it.
- Its header is a "Ports" label with the port count and a chevron that collapses it.
- Each group shows the row's mark and name in Body, secondary, with the group's `×` on hover.
- Each badge shows the port number in monospaced Meta on a 5 point rounded fill, with its `×` on hover.
- With no repos, the panel hides, so the empty state stands alone.

### Top bar

- Each tab shows an icon for its layout (one pane, side by side, stacked, or both), its name in Body, and a slot at the end.
  The slot holds the running dot, or `×` on hover.
- The selected tab gets the neutral selection fill.
- Split Pane (`⌘D`) and New Tab (`⌘T`) buttons sit at the trailing end.
  Both are PR 11's buttons, restyled with the rest of the bar.
- While the sidebar is hidden, the row's repo tile, repo name, and branch show at the leading edge, so the window still says where you are.
- The window title stays set for the Window menu and Mission Control.

### Panes

- Each header is 26 points: a status mark, the title in Meta, and `×` on hover.
- The status mark is a terminal glyph while the shell is idle, the accent dot while a program runs, and a green check or red cross after the shell exits.
- The focused pane's header takes a light accent tint and primary text.
  The rest stay muted.
- The exit strip shows the same mark, "Exited" or "Exited with code N", and the Return and `⌘W` hints.
- Terminal padding grows to 8 points at the top and bottom and 12 at the left.
  The right needs none, since SwiftTerm keeps 17 points free for its scroller.
- The scroller shows only while the terminal is scrolled back into its scrollback.
- New ANSI palettes, one tuned for dark and one for light.
- In dark, the terminal sits a step darker than the chrome, so panes have an edge.

### Everything else

- The empty states (no repos, no row, no terminals, missing worktree) keep `ContentUnavailableView`, each with a button that does the next step.
- Toasts lead with a warning triangle, since every toast reports something that went wrong, and long messages wrap in a rounded box.
- Sheets, popovers, and alerts stay native.

### New state in CanopyCore

The running dot needs a per-pane busy flag that views can observe.
Today `Pane.isBusy` is computed on each read.
The app refreshes a stored `isRunningProgram` for every pane once a second while the window can be seen, shown or hidden, the way ports refresh every two seconds.

### Out of scope

- Settings, themes, and font choice.
- Collapsing repo groups.
- Diff stats or ahead and behind counts on rows.

### Carry-over

- Item 17, the first-row highlight, goes with `List`.
- Item 16, Locate for a missing repo, moves into its header.
- Item 15, identical display names for repos whose folder and parent names match, is fixed while the repo header is being redone.

## Global Constraints

- The deployment target stays macOS 15.
  Nothing newer than macOS 15 is used without `#available`.
- Swift 6 language mode with strict concurrency, and no warnings from `swift build`.
- `make lint` (`swift format lint --strict`) passes after every task.
- Every size, font, and fill comes from `Style`.
- Never block a Swift concurrency thread: the activity refresh reads each pane's foreground with `tcgetpgrp` and a process name lookup on the main actor, which takes microseconds.
- UI checks use `scripts/ui.swift` and `scripts/window-shot.swift` on the dev build with a throwaway `CANOPY_HOME`.
  Never take full-screen captures, and keep the machine's user and host names out of shots.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. **Clicks in the title bar row** must reach the tabs, the Split Pane and New Tab buttons, and the crumb while terminals are on screen, and empty space there must still move and zoom the window.
   Pinned by the UI check in Task 7, which clicks each and counts panes with `canopy term list`.
2. **Many tabs or a narrow window** must scroll the tab strip and keep both buttons in place, with no overflow menu.
   Pinned by the UI check in Task 7 with twelve tabs.
3. **A long sidebar**, such as a repo with 30 rows, must scroll under the traffic lights, stop at the ports panel, and bring a row picked by `⌘N` or the CLI into view.
   Pinned by the UI checks in Tasks 6 and 11.
4. **A stale running dot** after a program exits, or a dot that never shows for a row that is not on screen.
   Pinned by `aRunningProgramShowsOnceActivityRefreshes` and `aScriptRunsUntilItExitsWithoutWaitingForARefresh` in Task 3.
5. **Repo identity**: repos whose folder and parent names both match must get different names, and a repo's tile must keep its hue across launches.
   Pinned by `goesBackAsManyFoldersAsItTakesToTellReposApart` in Task 2 and `theHueComesFromAHashThatIsTheSameInEveryLaunch` in Task 4.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/ui.swift` | New. Posts keys, clicks, drags, and scrolls to a running app for UI checks. |
| `scripts/ui-fixture.sh` | New. Opens the dev build on a throwaway home with something in every part of the window. |
| `Sources/CanopyCore/Repos/RepoNaming.swift` | Display names that go back as many folders as it takes. |
| `Sources/CanopyCore/Repos/RepoMark.swift` | New. A repo tile's letter and lasting hue. |
| `Sources/CanopyCore/Terminal/Pane.swift`, `TerminalStore.swift` | The observable running flag and its refresh. |
| `Sources/CanopyCore/Layout/Layout.swift` | `LayoutShape`, for a tab's icon. |
| `Sources/CanopyApp/Style/Style.swift` | New. The scale, fills, tile hues, and the small shared views: `SectionLabel`, `IconButton`, `RunningDot`, `TagView`, `RepoTile`. |
| `Sources/CanopyApp/Sidebar/SidebarView.swift` | The sidebar's own rows, repo headers, disclosure, and warning. |
| `Sources/CanopyApp/Sidebar/BranchGlyph.swift` | The trunk mark and `RowMark`. |
| `Sources/CanopyApp/Sidebar/PortsPanel.swift` | The ports panel in the new style. |
| `Sources/CanopyApp/Terminal/TopBarView.swift` | New, replacing `TabBarView.swift`. The bar in the title bar row. |
| `Sources/CanopyApp/Terminal/PaneView.swift` | Pane headers, status marks, and the exit strip. |
| `Sources/CanopyApp/Terminal/SwiftTermEmulator.swift`, `TerminalSurface.swift` | Palettes, backgrounds, padding, and the scroller. |
| `Sources/CanopyApp/RootView.swift`, `CanopyApp.swift`, `AppModel.swift` | Window style, the top bar overlay, folder choosing, row stepping, the activity refresh, and the toast. |

### Task 1: The UI driver and fixture in `scripts/`

The PR 5 session built a small driver for unattended UI checks and kept it outside the repo.
It moves into `scripts/ui.swift`, next to `window-shot.swift`, with a usage header and a `scroll` command.
`scripts/ui-fixture.sh` opens the dev build on a throwaway home that looks like the mockup, which every later task's UI check uses.

**Files:**
- Create: `scripts/ui.swift`, `scripts/ui-fixture.sh`
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: `ui <command> <pid> ...` with `activate`, `frame`, `key`, `type`, `move`, `click`, `drag`, `scroll`; `scripts/ui-fixture.sh [dark|light|stop]`, which writes `build/ui-fixture.env` with `pid` and `work`.

- [ ] **Step 1: Write the driver**

```swift
// Drives a running Canopy for UI checks, alongside window-shot.swift. Build it once, since `swift` takes seconds to
// start: swiftc -O -o build/ui scripts/ui.swift
//
//   ui activate <pid>                       bring the app to the front
//   ui frame <pid>                          print the main window's frame in screen points
//   ui key <pid> <keycode> [cmd] [shift] [opt] [ctrl]
//   ui type <pid> <text>
//   ui move <pid> <x> <y>                   points from the window's top-left, as in a window shot divided by 2
//   ui click <pid> <x> <y> [count]
//   ui drag <pid> <x1> <y1> <x2> <y2>
//   ui scroll <pid> <x> <y> <lines>         positive lines scroll up, into the scrollback
//
// Keys and text go to the app alone. Pointer events go through the system, so they refuse to run unless the app is
// frontmost. The process running this needs Accessibility permission in System Settings.
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: ui <command> <pid> [arguments], see the top of ui.swift\n".utf8))
    exit(2)
}

func number(_ index: Int) -> Double {
    guard index < args.count, let value = Double(args[index]) else {
        FileHandle.standardError.write(Data("\(args[0]) needs a number at position \(index)\n".utf8))
        exit(2)
    }
    return value
}

/// The largest layer-0 window the app owns: a frontmost app's menu bar strip is one too.
func windowFrame() -> CGRect {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let frames = windows.compactMap { window -> CGRect? in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
            (window[kCGWindowLayer as String] as? Int) == 0,
            let bounds = window[kCGWindowBounds as String]
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }
    guard let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
        FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
        exit(1)
    }
    return frame
}

func windowPoint(_ xIndex: Int) -> CGPoint {
    let frame = windowFrame()
    return CGPoint(x: frame.minX + number(xIndex), y: frame.minY + number(xIndex + 1))
}

func requireFrontmost() {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        FileHandle.standardError.write(Data("refusing to \(args[0]): the app is not frontmost\n".utf8))
        exit(1)
    }
}

func post(_ event: CGEvent) {
    event.postToPid(pid)
    usleep(15_000)
}

func mouse(_ type: CGEventType, at point: CGPoint, clickCount: Int64 = 1) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    event.setIntegerValueField(.mouseEventClickState, value: clickCount)
    event.post(tap: .cghidEventTap)
    usleep(20_000)
}

func modifiers(_ names: ArraySlice<String>) -> CGEventFlags {
    var flags: CGEventFlags = []
    for name in names {
        switch name {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

switch args[0] {
case "activate":
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(300_000)
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? "front" : "not front")
case "frame":
    print(windowFrame())
case "key":
    let code = CGKeyCode(number(2))
    let flags = modifiers(args.dropFirst(3))
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        post(event)
    }
case "type":
    guard args.count > 2 else { exit(2) }
    for scalar in args[2].unicodeScalars {
        let units = Array(String(scalar).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(event)
        }
    }
case "move":
    requireFrontmost()
    mouse(.mouseMoved, at: windowPoint(2))
case "click":
    requireFrontmost()
    let point = windowPoint(2)
    let count = args.count > 4 ? Int(number(4)) : 1
    mouse(.mouseMoved, at: point)
    for click in 1...max(count, 1) {
        mouse(.leftMouseDown, at: point, clickCount: Int64(click))
        mouse(.leftMouseUp, at: point, clickCount: Int64(click))
    }
case "drag":
    requireFrontmost()
    let from = windowPoint(2)
    let to = windowPoint(4)
    mouse(.mouseMoved, at: from)
    mouse(.leftMouseDown, at: from)
    for step in 1...30 {
        let t = Double(step) / 30
        mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    }
    usleep(200_000)
    mouse(.leftMouseUp, at: to)
case "scroll":
    requireFrontmost()
    mouse(.mouseMoved, at: windowPoint(2))
    let lines = Int32(number(4))
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
    event.post(tap: .cghidEventTap)
default:
    FileHandle.standardError.write(Data("unknown command \(args[0]), see the top of ui.swift\n".utf8))
    exit(2)
}
```

- [ ] **Step 2: Write the fixture**

```bash
#!/usr/bin/env bash
# Opens the dev build on a throwaway home that has something in every part of the window, for UI checks and shots:
# three repos, rows with open, draft, merged, and closed PRs, other worktrees, running programs, listening ports,
# and a split tab. Nothing outside the throwaway folder is touched.
#
#   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
#   scripts/ui-fixture.sh stop           quit it and delete its folder
#
# PR badges come from a stand-in gh, which the app finds first on its login PATH through a fixture ZDOTDIR.
# Writing "logged-out" to $work/bin/gh-mode makes it answer like a gh with no login.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
state="$PWD/build/ui-fixture.env"

if [[ "${1:-}" == stop ]]; then
    [[ -f "$state" ]] || exit 0
    # shellcheck source=/dev/null
    source "$state"
    kill "$pid" 2>/dev/null || true
    [[ "$work" == "${TMPDIR:-/tmp}"*cnp.* ]] && rm -rf "$work"
    rm -f "$state"
    exit 0
fi

[[ -x "$cli" ]] || { echo "build it first: make app" >&2; exit 1; }
# The socket path must stay under 104 bytes, so the home goes in a short temporary folder.
work=$(mktemp -d -t cnp)
export CANOPY_HOME="$work/home"

mkdir -p "$work/bin" "$work/zdot"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/python3
import json, os, re, sys
mode = os.path.join(os.path.dirname(__file__), "gh-mode")
if os.path.exists(mode) and open(mode).read().strip() == "logged-out":
    sys.stderr.write("gh: To get started with GitHub CLI, please run:  gh auth login\n")
    sys.exit(4)
query = next(a[6:] for a in sys.argv if a.startswith("query="))
prs = {
    "feat/onboarding-flow": (142, "Onboarding in three steps", "OPEN", True),
    "fix/login-redirect": (139, "Keep the page after logging in", "MERGED", False),
    "feat/checkout-redesign": (145, "Split checkout into steps", "OPEN", False),
    "spike/new-parser": (131, "Try a new parser", "CLOSED", False),
}
repo = {}
for key, branch in re.findall(r'(b\d+): pullRequests\(headRefName: "([^"]*)"', query):
    nodes = []
    if branch in prs:
        number, title, state, draft = prs[branch]
        nodes.append({"number": number, "title": title, "url": f"https://github.com/acme/web-app/pull/{number}",
                      "state": state, "isDraft": draft, "updatedAt": "2026-09-28T01:00:00Z",
                      "isCrossRepository": False})
    repo[key] = {"nodes": nodes}
print(json.dumps({"data": {"repository": repo}}))
GH
chmod +x "$work/bin/gh"
cat > "$work/zdot/.zshrc" <<ZSHRC
export PATH="$work/bin:\$PATH"
ZSHRC

for repo in web-app api-server docs; do
    git init -q -b main "$work/$repo"
    git -C "$work/$repo" -c user.email=ui@example.com -c user.name=ui commit -q --allow-empty -m init
done

args=()
[[ "${1:-dark}" == light ]] && args=(-NSRequiresAquaSystemAppearance YES)
(ZDOTDIR="$work/zdot" SHELL=/bin/zsh exec "$app/Contents/MacOS/Canopy" ${args[@]+"${args[@]}"} \
    </dev/null >/dev/null 2>&1) &
for _ in $(seq 1 100); do
    [[ -S "$CANOPY_HOME/canopy.sock" ]] && break
    sleep 0.1
done

for repo in web-app api-server docs; do "$cli" repo add "$work/$repo" >/dev/null; done
"$cli" row new feat/onboarding-flow --repo web-app >/dev/null
"$cli" row new fix/login-redirect --repo web-app >/dev/null
"$cli" row new feat/checkout-redesign --repo web-app >/dev/null
"$cli" row new feat/rate-limits --repo api-server >/dev/null
git -C "$work/web-app" worktree add -q -b hotfix/cart-total "$work/elsewhere/cart-total"
git -C "$work/web-app" worktree add -q -b spike/new-parser "$work/elsewhere/new-parser"
# Remotes come after the rows, so creating the rows does not fetch. The stand-in gh answers for them.
git -C "$work/web-app" remote add origin https://github.com/acme/web-app.git
git -C "$work/api-server" remote add origin https://github.com/acme/api-server.git
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null
sleep 1

# A plain prompt keeps the machine's user and host names out of shots.
plain="PROMPT='%F{blue}%B%1~%b%f %# '; clear"
agent="$plain; "'printf "\n\033[36m●\033[0m Read \033[90msrc/checkout/\033[0mForm.tsx\n\033[36m●\033[0m Update \033[90msrc/checkout/\033[0mForm.tsx  \033[32m+48\033[0m \033[31m-21\033[0m\n\033[36m●\033[0m Bash \033[90mbun test checkout\033[0m\n  \033[32m✓\033[0m 18 passed\n\nThe form now has three steps.\n"; sleep 600'
row=(--repo web-app --row feat/checkout-redesign)
first=$("$cli" term list --all --json | /usr/bin/python3 -c \
    'import json, sys; print([t["pane"] for t in json.load(sys.stdin) if t["row"] == "feat/checkout-redesign"][0])')
"$cli" term send "$first" "$agent" --enter >/dev/null
"$cli" term new "${row[@]}" --run "$plain; python3 -m http.server 5173" >/dev/null
"$cli" term new "${row[@]}" --run "$plain; git status -sb" >/dev/null
"$cli" term new "${row[@]}" --tab agent --run "$plain; sleep 600" >/dev/null
"$cli" term new "${row[@]}" --tab "Terminal 2" --run "$plain" >/dev/null
"$cli" term new --repo web-app --row feat/onboarding-flow --run "$plain; sleep 600" >/dev/null
"$cli" term new --repo api-server --row feat/rate-limits --run "$plain; python3 -m http.server 8080" >/dev/null
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null

pid=$("$cli" status --json | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pid"])')
printf 'pid=%s\nwork=%s\n' "$pid" "$work" > "$state"
echo "pid $pid, CANOPY_HOME=$CANOPY_HOME"
```

- [ ] **Step 3: Point agents at them in `CLAUDE.md`**

```diff
@@ -9,6 +9,7 @@ The design lives in `docs/superpowers/specs/2026-09-27-canopy-design.md`.
 - `make app` builds `build/Canopy Dev.app` (data in `~/.canopy-dev`)
 - `make e2e` drives a dev build through the CLI against a temporary `CANOPY_HOME`
 - `make signing-cert` once per machine before `make app`
+- UI checks: `scripts/ui-fixture.sh` opens the dev build on a throwaway home with something in every part of the window, `scripts/ui.swift` posts keys and clicks to it, and `scripts/window-shot.swift` captures its window alone. Never take full-screen shots.
 
 Use `make test`, not bare `swift test`: Command Line Tools need extra search paths for Swift Testing.
 
```

- [ ] **Step 4: Check them**

Run: `swiftc -O -o build/ui scripts/ui.swift && build/ui`
Expected: it prints the usage line and exits 2.

Run: `make app && scripts/ui-fixture.sh dark`, then `source build/ui-fixture.env && build/ui activate $pid && swift scripts/window-shot.swift $pid /tmp/fixture.png`
Expected: three repos, PR badges #142, #139, and #145, a three-pane tab, and two ports.
Then `scripts/ui-fixture.sh stop`.

- [ ] **Step 5: Commit**

```bash
git add scripts/ui.swift scripts/ui-fixture.sh CLAUDE.md
git commit -m "chore: the UI driver moves into scripts"
```

### Task 2: Display names that go back as far as it takes (item 15)

Two repos at `/work/client/app` and `/personal/client/app` both show as `client/app` today, and a repo at `/app` shows as `//app`.

**Files:**
- Modify: `Sources/CanopyCore/Repos/RepoNaming.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`
- Test: `Tests/CanopyCoreTests/RowModelTests.swift`

**Interfaces:**
- Produces: `RepoNaming.displayNames(for:)` keeps its signature.

- [ ] **Step 1: Write the failing tests**

```diff
@@ -76,6 +76,20 @@ struct RepoNamingTests {
         )
     }
 
+    @Test func goesBackAsManyFoldersAsItTakesToTellReposApart() {
+        #expect(
+            RepoNaming.displayNames(for: ["/work/client/app", "/personal/client/app", "/other/app", "/web"])
+                == [
+                    "/work/client/app": "work/client/app", "/personal/client/app": "personal/client/app",
+                    "/other/app": "other/app", "/web": "web",
+                ]
+        )
+    }
+
+    @Test func aRepoAtTheTopOfItsDiskKeepsItsOneName() {
+        #expect(RepoNaming.displayNames(for: ["/app", "/x/app"]) == ["/app": "app", "/x/app": "x/app"])
+    }
+
     @Test func dirNameAvoidsTakenNames() {
         #expect(RepoNaming.dirName(for: "/x/app", taken: ["app", "app-2"]) == "app-3")
     }
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter RepoNamingTests`
Expected: FAIL, with `client/app` for both and `//app` for the repo at the top of the disk.

- [ ] **Step 3: Implement**

```diff
@@ -1,20 +1,18 @@
 import Foundation
 
 public enum RepoNaming {
-    /// Folder names, with the parent folder prepended when two repos share a folder name.
+    /// Folder names. Repos that share a folder name each get as many parent folders as it takes to tell them apart.
     public static func displayNames(for paths: [String]) -> [String: String] {
-        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
-        var counts: [String: Int] = [:]
-        for name in names {
-            counts[name, default: 0] += 1
-        }
+        let folders = paths.map { URL(fileURLWithPath: $0).pathComponents.filter { $0 != "/" } }
         var result: [String: String] = [:]
-        for (path, name) in zip(paths, names) {
-            if counts[name, default: 0] > 1 {
-                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
-                result[path] = "\(parent)/\(name)"
-            } else {
-                result[path] = name
+        for group in Dictionary(grouping: paths.indices, by: { folders[$0].last ?? "" }).values {
+            var depth = 1
+            func name(_ index: Int) -> String { folders[index].suffix(depth).joined(separator: "/") }
+            while Set(group.map(name)).count < group.count, group.contains(where: { folders[$0].count > depth }) {
+                depth += 1
+            }
+            for index in group {
+                result[paths[index]] = name(index)
             }
         }
         return result
```

- [ ] **Step 4: Run them to see them pass**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter RepoNamingTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Update the spec**

```diff
@@ -128,7 +128,7 @@ A dev build therefore never touches the instance the author is working in.
 A repo is added from the UI or with `canopy repo add <path>`.
 If the path is a linked worktree, Canopy resolves it to the main checkout.
 A repo's display name is its folder name.
-If two repos share a folder name, the parent folder name is added to tell them apart.
+If two repos share a folder name, each gets as many parent folder names as it takes to tell them apart, such as `work/client/app` and `personal/client/app`.
 Removing a repo only unregisters it and never touches files.
 
 ### Discovery
```

- [ ] **Step 6: Commit**

```bash
git add Sources/CanopyCore/Repos/RepoNaming.swift Tests/CanopyCoreTests/RowModelTests.swift docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "fix: tell apart repos whose folder and parent names both match"
```

### Task 3: An observable running flag on panes

`Pane.isBusy` reads the foreground process each time, so no view can watch it.
Panes get a stored `isRunningProgram` that `TerminalStore.refreshActivity()` updates, and the app calls it every second while the window can be seen, and at once when the window comes back into view.
Exiting clears the flag at once rather than at the next refresh.
The quit, close, and remove confirmations keep reading `isBusy`, which is exact at the moment they ask.

**Files:**
- Modify: `Sources/CanopyCore/Terminal/Pane.swift`, `Sources/CanopyCore/Terminal/TerminalStore.swift`, `Sources/CanopyApp/AppModel.swift`
- Test: `Tests/CanopyCoreTests/PaneTests.swift`

**Interfaces:**
- Produces: `Pane.isRunningProgram: Bool`, `Pane.refreshActivity()`, `TerminalTab.isRunningProgram: Bool`, `TerminalStore.refreshActivity()`, `TerminalStore.isRunningProgram(inRow:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```diff
@@ -73,6 +73,50 @@ struct PaneTests {
         #expect(pane.isBusy)
     }
 
+    @Test func aRunningProgramShowsOnceActivityRefreshes() async throws {
+        let dir = try TempDir()
+        let terminals = Fixture.terminals(dir)
+        defer { terminals.closeAll() }
+        let tab = terminals.openTab(for: Fixture.context(dir.path))
+        let pane = tab.focused
+        #expect(await eventually { pane.foreground?.name == "bash" })
+
+        terminals.refreshActivity()
+        #expect(!pane.isRunningProgram)
+        #expect(!tab.isRunningProgram)
+        #expect(!terminals.isRunningProgram(inRow: dir.path))
+
+        await pane.run("sleep 30")
+        #expect(
+            await eventually {
+                terminals.refreshActivity()
+                return pane.isRunningProgram
+            })
+        #expect(tab.isRunningProgram)
+        #expect(terminals.isRunningProgram(inRow: dir.path))
+
+        pane.type("\u{3}")
+        #expect(
+            await eventually {
+                terminals.refreshActivity()
+                return !pane.isRunningProgram
+            })
+        #expect(!terminals.isRunningProgram(inRow: dir.path))
+    }
+
+    @Test func aScriptRunsUntilItExitsWithoutWaitingForARefresh() async throws {
+        let dir = try TempDir()
+        let terminals = Fixture.terminals(dir)
+        defer { terminals.closeAll() }
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 0.5")).focused
+
+        terminals.refreshActivity()
+        #expect(pane.isRunningProgram)
+
+        _ = await pane.waitForExit()
+        #expect(!pane.isRunningProgram)
+    }
+
     @Test func closingEndsTheProcessAndWakesWaiters() async throws {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PaneTests`
Expected: the build fails: `value of type 'TerminalStore' has no member 'refreshActivity'`.

- [ ] **Step 3: Implement the flag and the refresh**

```diff
@@ -71,6 +71,17 @@ public final class Pane: Identifiable {
         return await withCheckedContinuation { exitWaiters.append($0) }
     }
 
+    /// `isBusy` as of the last `refreshActivity`, for views to observe. Exiting clears it at once.
+    public private(set) var isRunningProgram = false
+
+    /// Reads the foreground process again. The app calls it every second for every pane, shown or not.
+    public func refreshActivity() {
+        let busy = isBusy
+        if busy != isRunningProgram {
+            isRunningProgram = busy
+        }
+    }
+
     /// Types `command` and Return once the shell's line editor is ready, so the shell does not echo it twice.
     /// Shells without a line editor never report ready, so it types anyway after `timeout`.
     public func run(_ command: String, timeout: Duration = .seconds(10)) async {
@@ -201,6 +212,7 @@ public final class Pane: Identifiable {
         if isClosed, case .exited = status { return }
         process = nil
         status = .exited(code)
+        isRunningProgram = false
         record(ActivityType.termExited, ["code": .number(Double(code))])
         // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
         emulator.feed(Data("\u{1b}[?25l".utf8))
```

```diff
@@ -24,6 +24,11 @@ public final class TerminalTab: Identifiable {
         layout.leaves.compactMap { panes[$0] }
     }
 
+    /// Whether any of its panes was running a program at the last activity refresh.
+    public var isRunningProgram: Bool {
+        paneList.contains(where: \.isRunningProgram)
+    }
+
     /// The pane `⌘W` closes and typing goes to.
     public var focused: Pane {
         panes[focusedPaneID] ?? paneList[0]
@@ -95,6 +100,18 @@ public final class TerminalStore {
         tabs(inRow: path).flatMap(\.paneList).filter(\.isBusy)
     }
 
+    /// Updates every pane's `isRunningProgram`.
+    public func refreshActivity() {
+        for pane in panes {
+            pane.refreshActivity()
+        }
+    }
+
+    /// Whether any of the row's panes was running a program at the last activity refresh.
+    public func isRunningProgram(inRow path: String) -> Bool {
+        tabs(inRow: path).contains(where: \.isRunningProgram)
+    }
+
     // MARK: Tabs
 
     /// Opens a tab with one pane at the end of the row's tab bar and selects it.
```

- [ ] **Step 4: Run them to see them pass**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PaneTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Refresh from the app while the window can be seen**

Ports already refresh on a timer and when the window comes into view, so both refreshes share one function.

```diff
@@ -79,11 +79,12 @@ final class AppModel {
             }
         }
         await startControlServer()
-        startScanningPorts()
+        startRefreshingWhileVisible()
     }
 
     func shutdown() {
         portsTask?.cancel()
+        activityTask?.cancel()
         server?.stop()
         server = nil
         terminals.closeAll()
@@ -203,26 +204,36 @@ final class AppModel {
         let port: UInt16
     }
 
-    /// Scans every 2 seconds while any part of the window can be seen, and at once when it comes back into view.
-    private func startScanningPorts() {
-        portsTask = Task { [weak self] in
-            while !Task.isCancelled {
-                if NSApp.occlusionState.contains(.visible) {
-                    await self?.refreshPorts()
-                }
-                try? await Task.sleep(for: .seconds(2))
-            }
-        }
+    @ObservationIgnored private var activityTask: Task<Void, Never>?
+
+    /// Ports scan every 2 seconds and running dots refresh every second while any part of the window can be seen,
+    /// and both at once when it comes back into view.
+    private func startRefreshingWhileVisible() {
+        portsTask = repeating(every: .seconds(2)) { await $0.refreshPorts() }
+        activityTask = repeating(every: .seconds(1)) { $0.terminals.refreshActivity() }
         occlusionObserver = NotificationCenter.default.addObserver(
             forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
         ) { [weak self] _ in
             MainActor.assumeIsolated {
                 guard NSApp.occlusionState.contains(.visible) else { return }
+                self?.terminals.refreshActivity()
                 Task { await self?.refreshPorts() }
             }
         }
     }
 
+    /// Runs `work` every `interval` while any part of the window can be seen.
+    private func repeating(every interval: Duration, _ work: @escaping (AppModel) async -> Void) -> Task<Void, Never> {
+        Task { [weak self] in
+            while !Task.isCancelled {
+                if NSApp.occlusionState.contains(.visible), let self {
+                    await work(self)
+                }
+                try? await Task.sleep(for: interval)
+            }
+        }
+    }
+
     /// A scan that started before a stop can finish after the one that follows it, so only newer results are shown.
     func refreshPorts() async {
         portScansStarted += 1
```

Run: `swift build 2>&1 | grep -cE 'warning:|error:'`
Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CanopyCore/Terminal Sources/CanopyApp/AppModel.swift Tests/CanopyCoreTests/PaneTests.swift
git commit -m "feat: panes say whether a program is running, refreshed every second"
```

### Task 4: A repo's letter and lasting hue

The hue comes from 64-bit FNV-1a over the repo's path, because Swift's `Hasher` is seeded per process and would change every repo's color on relaunch.
The letter comes from the folder part of the display name, so `work/client/app` shows `A`.

**Files:**
- Create: `Sources/CanopyCore/Repos/RepoMark.swift`
- Test: `Tests/CanopyCoreTests/RepoMarkTests.swift`

**Interfaces:**
- Produces: `RepoMark(name:path:)` with `letter: String` and `hue: Int` in `0..<RepoMark.hueCount` (8); `RepoSnapshot.mark`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing

@testable import CanopyCore

struct RepoMarkTests {
    @Test func theLetterIsTheFolderNamesFirstLetterOrDigit() {
        #expect(RepoMark(name: "web-app", path: "/x/web-app").letter == "W")
        #expect(RepoMark(name: "work/client/app", path: "/work/client/app").letter == "A")
        #expect(RepoMark(name: ".dotfiles", path: "/x/.dotfiles").letter == "D")
        #expect(RepoMark(name: "2048", path: "/x/2048").letter == "2")
        #expect(RepoMark(name: "ärger", path: "/x/ärger").letter == "Ä")
        #expect(RepoMark(name: "straße", path: "/x/straße").letter == "S")
        #expect(RepoMark(name: "---", path: "/x/---").letter == "?")
    }

    @Test func theHueComesFromAHashThatIsTheSameInEveryLaunch() {
        // FNV-1a's published test values. Swift's Hasher is seeded per process, so it would change hues on relaunch.
        #expect(RepoMark.stableHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(RepoMark.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(RepoMark.stableHash("foobar") == 0x8594_4171_f739_67e8)

        let mark = RepoMark(name: "web", path: "/a/web")
        #expect(mark.hue == Int(RepoMark.stableHash("/a/web") % UInt64(RepoMark.hueCount)))
    }

    @Test func reposWithTheSameNameSpreadAcrossTheHues() {
        let hues = Set((0..<40).map { RepoMark(name: "app", path: "/p\($0)/app").hue })
        #expect(hues == Set(0..<RepoMark.hueCount))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter RepoMarkTests`
Expected: the build fails: `cannot find 'RepoMark' in scope`.

- [ ] **Step 3: Implement**

```swift
/// What a repo's tile in the sidebar shows: a letter, and one of `hueCount` hues that stays the same across launches.
public struct RepoMark: Equatable, Sendable {
    public static let hueCount = 8

    public let letter: String
    public let hue: Int

    /// `name` is the display name, which can carry parent folders, as in `work/client/app`.
    public init(name: String, path: String) {
        let folder = name.split(separator: "/").last ?? ""
        letter = folder.first(where: { $0.isLetter || $0.isNumber }).map { String($0.uppercased().prefix(1)) } ?? "?"
        hue = Int(Self.stableHash(path) % UInt64(Self.hueCount))
    }

    /// 64-bit FNV-1a over the UTF-8 bytes.
    static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }
}

extension RepoSnapshot {
    public var mark: RepoMark { RepoMark(name: name, path: path) }
}
```

- [ ] **Step 4: Run them to see them pass**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter RepoMarkTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Repos/RepoMark.swift Tests/CanopyCoreTests/RepoMarkTests.swift
git commit -m "feat: a letter and a lasting hue for each repo's tile"
```

### Task 5: The style file and the sidebar's own rows

This is the largest task.
It adds `Style.swift`, which every later task uses, and replaces the sidebar's `List` with Canopy's own rows.
Choosing a folder moves from the sidebar into `AppModel`, so the File menu and the empty states can add a repo too, and the file importer moves to `RootView`, which stays on screen while the sidebar is hidden.

**Files:**
- Create: `Sources/CanopyApp/Style/Style.swift`
- Modify: `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/Sidebar/BranchGlyph.swift`, `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/CanopyApp.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`

**Interfaces:**
- Consumes: `RepoSnapshot.mark` (Task 4), `TerminalStore.isRunningProgram(inRow:)` (Task 3).
- Produces: `Style` (fonts `label`, `meta`, `body`, `row`; heights; radii; `hoverFill`, `selectionFill`, `focusedSelectionFill`, `badgeFill`, `tileHues`), `SectionLabel`, `IconButton(title:systemImage:shortcut:size:imageSize:action:)`, `RunningDot(size:)`, `TagView`, `RepoTile`, `RowMark(row:size:)`, `NSAppearance.isDark`, `NSColor(hex:)`, `AppModel.chooseFolder(for:)`, `AppModel.folderChosen(_:)`, `AppModel.selectRow(offset:)`.

- [ ] **Step 1: Add the style file**

```swift
import AppKit
import CanopyCore
import SwiftUI

/// Canopy's one scale for type, sizes, and fills. Views take their numbers from here rather than picking their own.
enum Style {
    /// Uppercase section labels, such as Repos and Ports.
    static let label = Font.system(size: 10.5, weight: .semibold)
    static let labelTracking = 0.6
    /// PR numbers, ports, pane titles, shortcut hints, and tags.
    static let meta = Font.system(size: 11)
    /// Tabs, repo names, port groups, and other worktrees.
    static let body = Font.system(size: 12)
    /// Branch names.
    static let row = Font.system(size: 13)

    static let rowHeight = 26.0
    static let headerHeight = 28.0
    /// The window toolbar's height, so the tabs line up with the traffic lights.
    static let topBarHeight = 52.0
    static let tabHeight = 26.0
    static let paneHeaderHeight = 26.0

    static let cornerRadius = 6.0
    static let badgeRadius = 5.0
    static let tagRadius = 4.0

    static let hoverFill = Color.adaptive(
        light: .black.withAlphaComponent(0.045), dark: .white.withAlphaComponent(0.055))
    static let selectionFill = Color.adaptive(
        light: .black.withAlphaComponent(0.075), dark: .white.withAlphaComponent(0.1))
    /// The selection while its list has the keyboard, like Finder's, but tinted so PR colors stay readable.
    static let focusedSelectionFill = Color(
        nsColor: NSColor(name: nil) { appearance in
            NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.3 : 0.17)
        })
    static let badgeFill = Color.adaptive(
        light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.075))

    /// The hues a repo's tile can take, indexed by `RepoMark.hue`.
    static let tileHues: [Color] = [
        .adaptive(light: 0x5257D6, dark: 0x8B8FF8),
        .adaptive(light: 0x0E8A7B, dark: 0x40C8B4),
        .adaptive(light: 0xA86D00, dark: 0xE8B04A),
        .adaptive(light: 0xC43A62, dark: 0xF07A9A),
        .adaptive(light: 0x1F78C2, dark: 0x5CB3F0),
        .adaptive(light: 0x4D8A16, dark: 0x9CCC5A),
        .adaptive(light: 0x8A44C9, dark: 0xC38AF0),
        .adaptive(light: 0xC2512A, dark: 0xF08A60),
    ]
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        adaptive(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// An uppercase section label with its actions at the trailing end.
struct SectionLabel<Actions: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Style.label)
                .tracking(Style.labelTracking)
                .textCase(.uppercase)
            if let count {
                Text(verbatim: "\(count)")
                    .font(Style.label.weight(.medium))
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            actions
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
    }
}

/// A borderless icon button that shows a fill on hover.
struct IconButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var size = 22.0
    var imageSize = 12.0
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: imageSize, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: size > 22 ? 6 : 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}

/// The accent dot that marks a program running in a row, tab, or pane.
struct RunningDot: View {
    var size = 6.0

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.opacity(0.22)).padding(-2.5))
            .accessibilityLabel("A program is running")
    }
}

/// A small outlined label, such as "missing" or the tool that made a worktree.
struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Style.badgeFill, in: RoundedRectangle(cornerRadius: Style.tagRadius))
            .overlay(RoundedRectangle(cornerRadius: Style.tagRadius).strokeBorder(.separator))
    }
}

/// A repo's letter on a tile of its hue.
struct RepoTile: View {
    let mark: RepoMark
    var isDimmed = false

    var body: some View {
        let hue = Style.tileHues[mark.hue % Style.tileHues.count]
        Text(verbatim: mark.letter)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(hue)
            .frame(width: 16, height: 16)
            .background(hue.opacity(0.2), in: RoundedRectangle(cornerRadius: Style.tagRadius))
            .overlay(RoundedRectangle(cornerRadius: Style.tagRadius).strokeBorder(hue.opacity(0.35), lineWidth: 0.5))
            .opacity(isDimmed ? 0.5 : 1)
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Add the trunk mark and `RowMark`, and keep PR colors on a selected row**

`Color.adaptive` moves into `Style.swift`.

```diff
@@ -41,20 +41,37 @@ struct PullRequestGlyph: Shape {
     }
 }
 
-/// A row's mark: its PR in the PR's state color, or a muted branch when it has none.
-struct RowIcon: View {
+/// The main checkout's mark: the trunk, a line through a commit.
+struct TrunkGlyph: Shape {
+    func path(in rect: CGRect) -> Path {
+        let scale = min(rect.width, rect.height) / 24
+        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
+        var path = Path()
+        path.move(to: CGPoint(x: 12, y: 2.5))
+        path.addLine(to: CGPoint(x: 12, y: 8.5))
+        path.addEllipse(in: CGRect(x: 8.5, y: 8.5, width: 7, height: 7))
+        path.move(to: CGPoint(x: 12, y: 15.5))
+        path.addLine(to: CGPoint(x: 12, y: 21.5))
+        return path.applying(transform)
+    }
+}
+
+/// A row's mark: its PR in the PR's state color, the trunk for the main checkout, or a muted branch.
+struct RowMark: View {
     let row: Row
-    @Environment(\.backgroundProminence) private var prominence
+    var size = 14.0
 
     var body: some View {
         Group {
             if let pr = row.pullRequest {
-                PullRequestGlyph().stroke(pr.state.style(on: prominence), style: Self.stroke)
+                PullRequestGlyph().stroke(pr.state.color, style: Self.stroke)
+            } else if row.rowClass == .main {
+                TrunkGlyph().stroke(row.isMissing ? .tertiary : .secondary, style: Self.stroke)
             } else {
-                BranchGlyph().stroke(.secondary, style: Self.stroke)
+                BranchGlyph().stroke(row.isMissing ? .tertiary : .secondary, style: Self.stroke)
             }
         }
-        .frame(width: 14, height: 14)
+        .frame(width: size, height: size)
     }
 
     private static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
@@ -71,12 +88,6 @@ extension PRState {
         }
     }
 
-    /// On a selected row in a focused sidebar, state colors would clash with the accent color, so they turn white
-    /// like the rest of the row.
-    func style(on prominence: BackgroundProminence) -> AnyShapeStyle {
-        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
-    }
-
     var label: String {
         switch self {
         case .open: "Open"
@@ -86,15 +97,3 @@ extension PRState {
         }
     }
 }
-
-extension Color {
-    static func adaptive(light: UInt32, dark: UInt32) -> Color {
-        Color(
-            nsColor: NSColor(name: nil) { appearance in
-                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
-                return NSColor(
-                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
-                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
-            })
-    }
-}
```

- [ ] **Step 3: Move folder choosing and row stepping into the model**

```diff
@@ -119,6 +119,15 @@ final class AppModel {
         selectedRowPath = rows[number - 1].path
     }
 
+    /// ↑ and ↓ in the sidebar. From no selection, down picks the first row and up the last.
+    func selectRow(offset: Int) {
+        let rows = snapshot.visibleRows
+        guard !rows.isEmpty else { return }
+        let index =
+            rows.firstIndex { $0.path == selectedRowPath }.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
+        selectedRowPath = rows[min(max(index, 0), rows.count - 1)].path
+    }
+
     func menuTitle(forRow number: Int) -> String {
         let rows = snapshot.visibleRows
         return number <= rows.count ? rows[number - 1].displayName : "Row \(number)"
@@ -463,8 +472,27 @@ final class AppModel {
 
     // MARK: Repos
 
-    func addRepo(_ url: URL) {
-        perform { try await $0.addRepo(path: url.path) }
+    enum FolderRequest {
+        case addRepo
+        case locate(RepoSnapshot)
+    }
+
+    /// SwiftUI resets `isChoosingFolder` before calling the completion, so the request lives in its own property.
+    var isChoosingFolder = false
+    private(set) var folderRequest = FolderRequest.addRepo
+
+    /// The sidebar's +, File > Add Repo…, the empty states, and Locate… for a missing repo.
+    func chooseFolder(for request: FolderRequest) {
+        folderRequest = request
+        isChoosingFolder = true
+    }
+
+    func folderChosen(_ result: Result<URL, any Error>) {
+        switch (result, folderRequest) {
+        case (.success(let url), .addRepo): perform { try await $0.addRepo(path: url.path) }
+        case (.success(let url), .locate(let repo)): relocateRepo(repo, to: url)
+        case (.failure(let error), _): show(error)
+        }
     }
 
     /// A repo removal waiting for the user to confirm, because programs still run in its terminals.
```

```diff
@@ -1,11 +1,13 @@
 import AppKit
 import CanopyCore
 import SwiftUI
+import UniformTypeIdentifiers
 
 struct RootView: View {
     @Environment(AppModel.self) private var model
 
     var body: some View {
+        @Bindable var model = model
         NavigationSplitView {
             SidebarView()
                 .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
@@ -21,6 +23,7 @@ struct RootView: View {
             }
         }
         .animation(.snappy, value: model.toast)
+        .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) { model.folderChosen($0) }
         .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             model.refresh()
         }
@@ -61,11 +64,15 @@ struct RowDetailView: View {
                 .navigationTitle(row.displayName)
                 .navigationSubtitle(model.snapshot.repo(path: row.repoPath)?.name ?? "")
         } else {
-            ContentUnavailableView(
-                "No Row Selected",
-                systemImage: "sidebar.left",
-                description: Text("Pick a row in the sidebar, or add a repo to get started.")
-            )
+            ContentUnavailableView {
+                Label("No Row Selected", systemImage: "sidebar.left")
+            } description: {
+                Text("Pick a row in the sidebar, or add a repo to get started.")
+            } actions: {
+                if model.snapshot.repos.isEmpty {
+                    Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
+                }
+            }
         }
     }
 }
```

```diff
@@ -66,6 +66,9 @@ struct TerminalCommands: Commands {
 
     var body: some Commands {
         CommandGroup(after: .newItem) {
+            Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
+                .keyboardShortcut("o", modifiers: [.command, .shift])
+            Divider()
             Button("New Tab", action: model.newTab)
                 .keyboardShortcut("t")
                 .disabled(!model.canOpenTerminal)
```

- [ ] **Step 4: Replace the sidebar**

```swift
import CanopyCore
import SwiftUI

/// Repos and their rows, drawn by Canopy rather than a `List` so hover, selection, and density follow `Style`.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newRowRepo: RepoSnapshot?
    /// Repos whose other worktrees are shown.
    @State private var expanded: Set<String> = []
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.snapshot.repos.isEmpty {
                    SectionLabel(title: "Repos") {
                        IconButton(title: "Add Repo…", systemImage: "plus", shortcut: "⇧⌘O") {
                            model.chooseFolder(for: .addRepo)
                        }
                    }
                }
                ForEach(model.snapshot.repos) { repo in
                    RepoSection(
                        repo: repo,
                        isExpanded: Binding(
                            get: { expanded.contains(repo.path) },
                            set: { if $0 { expanded.insert(repo.path) } else { expanded.remove(repo.path) } }),
                        isFocused: isFocused,
                        onNewRow: { newRowRepo = repo }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            // Fills the column even with no repos, so the empty state gets the whole width.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            model.selectRow(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.selectRow(offset: 1)
            return .handled
        }
        .overlay {
            if model.snapshot.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repos", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository to see its worktrees.")
                } actions: {
                    Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                PortsPanel()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .sheet(item: $newRowRepo) { repo in
            NewRowSheet(repo: repo)
        }
    }
}

/// A repo's header, its PR warning, its rows, and its other worktrees.
struct RepoSection: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    @Binding var isExpanded: Bool
    let isFocused: Bool
    let onNewRow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RepoHeaderView(repo: repo, onNewRow: onNewRow)
            if let warning = repo.pullRequestWarning {
                RepoWarningView(text: warning)
            }
            ForEach(repo.rows) { row in
                RowLineView(
                    row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                    shortcut: model.shortcut(for: row), removable: row.rowClass != .main
                )
                .contextMenu {
                    if row.isMissing {
                        Button("Prune Missing Worktrees") { model.prune(repo) }
                    }
                }
            }
            if !repo.external.isEmpty {
                OtherWorktreesToggle(count: repo.external.count, isExpanded: $isExpanded)
                if isExpanded {
                    ForEach(repo.external) { row in
                        RowLineView(
                            row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                            shortcut: nil, removable: false)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RepoTile(mark: repo.mark, isDimmed: repo.isMissing)
            Text(repo.name)
                .font(Style.body.weight(.semibold))
                .foregroundStyle(repo.isMissing ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if repo.isMissing {
                TagView(text: "missing")
            }
            if let error = repo.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Style.meta)
                    .foregroundStyle(.orange)
                    .help(error)
            }
            Spacer(minLength: 4)
            if repo.isMissing {
                Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
                    .controlSize(.small)
                    .help("Find where \(repo.name) moved")
                RepoMenu(repo: repo, onNewRow: onNewRow)
            } else if isHovering {
                RepoMenu(repo: repo, onNewRow: onNewRow)
                IconButton(title: "New Row in \(repo.name)…", systemImage: "plus", action: onNewRow)
            } else {
                Text(verbatim: "\(repo.rows.count)")
                    .font(Style.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5)
                    .accessibilityLabel(repo.rows.count == 1 ? "1 row" : "\(repo.rows.count) rows")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { RepoMenuItems(repo: repo, onNewRow: onNewRow) }
    }
}

/// The repo's `…` button, holding what its context menu holds.
struct RepoMenu: View {
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    @State private var isHovering = false

    var body: some View {
        Menu {
            RepoMenuItems(repo: repo, onNewRow: onNewRow)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help("More for \(repo.name)")
        .accessibilityLabel("More for \(repo.name)")
    }
}

struct RepoMenuItems: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void

    var body: some View {
        if repo.isMissing {
            Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
        } else {
            Button("New Row…", action: onNewRow)
        }
        Divider()
        Button("Remove Repo from Canopy") { model.removeRepo(repo) }
    }
}

struct RowLineView: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let isSelected: Bool
    let isFocused: Bool
    let shortcut: Int?
    let removable: Bool
    @State private var isHovering = false
    @State private var isConfirmingRemove = false

    private var isRunning: Bool { model.terminals.isRunningProgram(inRow: row.path) }

    var body: some View {
        HStack(spacing: 8) {
            RowMark(row: row)
                .frame(width: 16)
            Text(row.displayName)
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isMissing ? .secondary : .primary)
            if let tag = row.externalTag {
                TagView(text: tag.label)
            }
            if row.isMissing {
                TagView(text: "missing")
            }
            Spacer(minLength: 4)
            if isRunning {
                RunningDot()
            }
            if let pr = row.pullRequest {
                PullRequestNumber(pr: pr)
            }
            if isHovering || isConfirmingRemove {
                if let shortcut {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(Style.meta)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if removable {
                    Button {
                        isConfirmingRemove = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(row.rowClass == .adopted ? "Hide from Canopy" : "Remove row")
                    .popover(isPresented: $isConfirmingRemove, arrowEdge: .trailing) {
                        RemoveRowPopover(row: row, isPresented: $isConfirmingRemove)
                    }
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: Style.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRowPath = row.path }
        .onHover { isHovering = $0 }
        // The PR number slides left as the shortcut and remove button come in.
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(row.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedRowPath = row.path }
    }

    private var fill: Color {
        if isSelected { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private var accessibilityLabel: String {
        var parts = [row.displayName]
        if let pr = row.pullRequest { parts.append("pull request \(pr.number), \(pr.state.label)") }
        if isRunning { parts.append("running a program") }
        if row.isMissing { parts.append("missing") }
        return parts.joined(separator: ", ")
    }
}

/// Opens the PR on GitHub. The rest of the row still selects it.
struct PullRequestNumber: View {
    let pr: PullRequest
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { openURL(url) }
        } label: {
            Text(verbatim: "#\(pr.number)")
                .font(Style.meta.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(pr.state.color)
        }
        .buttonStyle(.plain)
        .help("\(pr.state.label): \(pr.title)")
        .accessibilityLabel("Pull request \(pr.number), \(pr.state.label). Opens on GitHub.")
    }
}

/// Worktrees made by other tools, folded under their repo.
struct OtherWorktreesToggle: View {
    let count: Int
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text(count == 1 ? "1 other worktree" : "\(count) other worktrees")
                    .font(Style.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 7)
            .frame(height: 24)
            .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Why a repo shows no PR badges, with the fix. Long messages from gh stop at three lines, with the rest on hover.
struct RepoWarningView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Style.meta)
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .help(text)
    }
}
```

- [ ] **Step 5: Build and lint**

Run: `make format && swift build 2>&1 | grep -cE 'warning:|error:' && make lint`
Expected: `0`, and lint passes.

- [ ] **Step 6: Check it in the app**

Run: `make app && scripts/ui-fixture.sh dark`, then drive it with `build/ui` and shoot with `scripts/window-shot.swift`.
Expected:
- repo headers with tiles and counts, the trunk mark on each main row, running dots, and colored PR numbers, also on the selected row;
- clicking the first row under a repo highlights that row alone (item 17);
- hovering a repo header shows `…` and `+`, and hovering a row shows its `⌘N` and `×`;
- clicking the already selected row gives the sidebar the keyboard and the accent tint, and `↓` then moves the selection;
- `scripts/ui-fixture.sh stop`, then the same in light.

- [ ] **Step 7: Update the spec**

```diff
@@ -212,17 +212,29 @@ They get these environment variables:
 
 ## Sidebar rows
 
-A row line reads, left to right: icon, branch name, then a right-aligned PR number when a PR exists.
+A "Repos" label heads the sidebar, with a `+` that adds a repo.
+File > Add Repo… (`⇧⌘O`) and the empty sidebar's button add one too.
 
-- The icon is a branch glyph when the row has no PR, and a pull request glyph when it has one.
+Each repo group starts with a header: a tile with the repo's first letter, its name, and its row count.
+The tile takes one of eight hues, picked by a stable hash of the repo's path, so a repo keeps its color across launches.
+On hover, the count gives way to a `…` menu and a `+` that creates a row.
+
+A row line reads, left to right: icon, branch name, then a right-aligned running dot and PR number.
+
+- The icon is a pull request glyph when the row has a PR, a trunk glyph for the main checkout, and a branch glyph otherwise.
 - The PR glyph and number are colored by state:
   green for open, gray for draft, purple for merged, red for closed.
+  They keep their colors on the selected row.
+- The running dot shows while a program other than the shell runs in one of the row's terminals.
+  It is refreshed every second while the window can be seen.
 - Clicking the PR number opens the PR in the default browser.
   Clicking anywhere else on the row selects it.
 - On hover, the PR number slides left to make room for the row's shortcut hint (`⌘8`) and an `x`.
-- The selected row has a rounded highlight.
+- The selected row has a rounded highlight, tinted with the accent color while the sidebar has the keyboard.
+  `↑` and `↓` then move the selection.
 - `⌘1` to `⌘9` select the first nine visible rows across all repos, in sidebar order.
 - A detached HEAD shows the short commit hash in place of a branch name.
+- External worktrees fold into a "3 other worktrees" row under their repo's rows.
 
 ## Terminals
 
@@ -570,7 +582,7 @@ A command starting with a space is left out when the user has `hist_ignore_space
 
 - **Git and setup failures**: the UI shows git's message in a toast.
   The CLI exits non-zero, and with `--json` prints `{"error": {"code", "message"}}`.
-- **Missing repo folder**: the repo group shows "missing" with Locate and Remove.
+- **Missing repo folder**: the repo header shows "missing" and a Locate… button, and its `…` menu holds Remove.
 - **Missing worktree folder**: the row shows "missing" with Prune.
 - **`gh` unavailable**: covered under PR badges.
 - **Shell exits**: covered under Terminals.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/CanopyApp docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "feat: the sidebar's own rows, with repo tiles and running dots"
```

### Task 6: The ports panel in the sidebar's style

The panel moves from a bottom safe-area inset, which let rows scroll under it with nothing behind it, to a stack below the list.

**Files:**
- Modify: `Sources/CanopyApp/Sidebar/PortsPanel.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`

**Interfaces:**
- Consumes: `SectionLabel`, `RowMark`, `Style` (Task 5).

- [ ] **Step 1: Restyle the panel**

```diff
@@ -8,25 +8,16 @@ struct PortsPanel: View {
     private var count: Int { (model.ports ?? []).reduce(0) { $0 + $1.ports.count } }
 
     var body: some View {
-        VStack(alignment: .leading, spacing: 8) {
+        VStack(alignment: .leading, spacing: 0) {
             Button {
                 withAnimation(.easeOut(duration: 0.15)) { model.portsCollapsed.toggle() }
             } label: {
-                HStack(spacing: 5) {
+                SectionLabel(title: "Ports", count: count > 0 ? count : nil) {
                     Image(systemName: "chevron.right")
                         .font(.system(size: 9, weight: .bold))
                         .rotationEffect(.degrees(model.portsCollapsed ? 0 : 90))
-                    Text("Ports")
-                        .textCase(.uppercase)
-                    if model.portsCollapsed, count > 0 {
-                        Text(verbatim: "\(count)")
-                            .monospacedDigit()
-                            .foregroundStyle(.tertiary)
-                    }
-                    Spacer(minLength: 0)
+                        .frame(width: 22, height: 22)
                 }
-                .font(.caption.weight(.semibold))
-                .foregroundStyle(.secondary)
                 .contentShape(Rectangle())
             }
             .buttonStyle(.plain)
@@ -35,11 +26,13 @@ struct PortsPanel: View {
             if !model.portsCollapsed, let groups = model.ports {
                 if groups.isEmpty {
                     Text("Nothing is listening in your rows.")
-                        .font(.caption)
+                        .font(Style.meta)
                         .foregroundStyle(.tertiary)
+                        .padding(.leading, 8)
+                        .padding(.bottom, 4)
                 } else {
                     ScrollView {
-                        VStack(alignment: .leading, spacing: 10) {
+                        VStack(alignment: .leading, spacing: 2) {
                             ForEach(groups, id: \.rowPath) { group in
                                 PortGroupView(group: group)
                             }
@@ -58,37 +51,61 @@ struct PortsPanel: View {
 struct PortGroupView: View {
     @Environment(AppModel.self) private var model
     let group: PortGroup
+    @State private var isHovering = false
 
-    private var name: String { model.snapshot.row(path: group.rowPath)?.displayName ?? group.rowPath }
+    private var row: Row? { model.snapshot.row(path: group.rowPath) }
+    private var name: String { row?.displayName ?? group.rowPath }
 
     private var isStopping: Bool { group.ports.allSatisfy { model.isStopping($0, inRow: group.rowPath) } }
 
     var body: some View {
-        VStack(alignment: .leading, spacing: 5) {
-            HStack(spacing: 4) {
-                Button(name) { model.selectedRowPath = group.rowPath }
-                    .buttonStyle(.plain)
-                    .lineLimit(1)
-                    .truncationMode(.middle)
-                    .help("Show \(name)")
-                Spacer(minLength: 4)
+        VStack(alignment: .leading, spacing: 1) {
+            HStack(spacing: 8) {
                 Button {
-                    model.stop(group.ports, inRow: group.rowPath)
+                    model.selectedRowPath = group.rowPath
                 } label: {
-                    Image(systemName: "xmark")
-                        .font(.caption2.weight(.semibold))
+                    HStack(spacing: 8) {
+                        Group {
+                            if let row { RowMark(row: row, size: 12) }
+                        }
+                        .frame(width: 16)
+                        Text(name)
+                            .lineLimit(1)
+                            .truncationMode(.middle)
+                        Spacer(minLength: 4)
+                    }
+                    .contentShape(Rectangle())
+                }
+                .buttonStyle(.plain)
+                .help("Show \(name)")
+                if isHovering {
+                    Button {
+                        model.stop(group.ports, inRow: group.rowPath)
+                    } label: {
+                        Image(systemName: "xmark")
+                            .font(.system(size: 9, weight: .bold))
+                            .frame(width: 16, height: 16)
+                            .contentShape(Rectangle())
+                    }
+                    .buttonStyle(.plain)
+                    .disabled(isStopping)
+                    .help(group.ports.count == 1 ? "Stop what listens here" : "Stop everything listening here")
                 }
-                .buttonStyle(.borderless)
-                .foregroundStyle(.secondary)
-                .disabled(isStopping)
-                .help(group.ports.count == 1 ? "Stop what listens here" : "Stop everything listening here")
             }
-            .font(.callout)
+            .font(Style.body)
+            .foregroundStyle(.secondary)
+            .padding(.leading, 7)
+            .padding(.trailing, 5)
+            .frame(height: 24)
+            .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
+            .onHover { isHovering = $0 }
             FlowLayout(spacing: 4) {
                 ForEach(group.ports, id: \.port) { port in
                     PortBadge(port: port, rowPath: group.rowPath)
                 }
             }
+            .padding(.leading, 31)
+            .padding(.bottom, 6)
         }
     }
 }
@@ -98,36 +115,43 @@ struct PortBadge: View {
     @Environment(\.openURL) private var openURL
     let port: RowPort
     let rowPath: String
+    @State private var isHovering = false
 
     private var isStopping: Bool { model.isStopping(port, inRow: rowPath) }
 
     var body: some View {
-        HStack(spacing: 3) {
+        HStack(spacing: 2) {
             Button {
                 if let url = URL(string: "http://localhost:\(port.port)") { openURL(url) }
             } label: {
                 Text(verbatim: "\(port.port)")
-                    .monospacedDigit()
+                    .font(.system(size: 11, weight: .medium, design: .monospaced))
             }
             .buttonStyle(.plain)
             .help(openHelp)
-            Button {
-                model.stop([port], inRow: rowPath)
-            } label: {
-                Image(systemName: "xmark")
-                    .font(.system(size: 8, weight: .bold))
+            if isHovering, !isStopping {
+                Button {
+                    model.stop([port], inRow: rowPath)
+                } label: {
+                    Image(systemName: "xmark")
+                        .font(.system(size: 8, weight: .bold))
+                        .frame(width: 14, height: 14)
+                        .contentShape(Rectangle())
+                }
+                .buttonStyle(.plain)
+                .foregroundStyle(.secondary)
+                .help(stopHelp)
             }
-            .buttonStyle(.plain)
-            .foregroundStyle(.secondary)
-            .help(stopHelp)
         }
-        .font(.caption)
         .padding(.leading, 7)
-        .padding(.trailing, 6)
-        .padding(.vertical, 3)
-        .background(.quaternary, in: Capsule())
+        .padding(.trailing, isHovering && !isStopping ? 3 : 7)
+        .frame(height: 20)
+        .background(
+            isHovering ? Style.selectionFill : Style.badgeFill, in: RoundedRectangle(cornerRadius: Style.badgeRadius)
+        )
         .opacity(isStopping ? 0.4 : 1)
         .disabled(isStopping)
+        .onHover { isHovering = $0 }
     }
 
     // Tooltips are built as plain strings: in a string literal, SwiftUI would format the numbers, as in "3,000".
```

- [ ] **Step 2: Stack it below the list, and hide it with no repos**

```diff
@@ -10,6 +10,24 @@ struct SidebarView: View {
     @FocusState private var isFocused: Bool
 
     var body: some View {
+        // The ports panel sits below the list rather than over it, so rows never scroll under it.
+        VStack(spacing: 0) {
+            repoList
+            // With no repos there are no rows to listen, so the empty state stands alone.
+            if !model.snapshot.repos.isEmpty {
+                Divider()
+                PortsPanel()
+                    .padding(.horizontal, 8)
+                    .padding(.top, 4)
+                    .padding(.bottom, 8)
+            }
+        }
+        .sheet(item: $newRowRepo) { repo in
+            NewRowSheet(repo: repo)
+        }
+    }
+
+    private var repoList: some View {
         ScrollView {
             VStack(alignment: .leading, spacing: 0) {
                 if !model.snapshot.repos.isEmpty {
@@ -58,17 +76,6 @@ struct SidebarView: View {
                 }
             }
         }
-        .safeAreaInset(edge: .bottom, spacing: 0) {
-            VStack(spacing: 0) {
-                Divider()
-                PortsPanel()
-                    .padding(.horizontal, 12)
-                    .padding(.vertical, 8)
-            }
-        }
-        .sheet(item: $newRowRepo) { repo in
-            NewRowSheet(repo: repo)
-        }
     }
 }
 
```

- [ ] **Step 3: Check it in the app**

Run: `make app && scripts/ui-fixture.sh dark`.
Expected:
- "Ports 2" with a chevron, groups with their row's mark, `×` on a hovered badge and on a hovered group name;
- with 26 more rows added by `canopy row new feat/task-$i --repo docs`, the list scrolls and stops at the panel's hairline;
- a home with no repos shows only the "No Repos" empty state, at full width.

- [ ] **Step 4: Update the spec**

```diff
@@ -425,7 +425,8 @@ A row can own any number of ports.
 ### Panel
 
 The ports panel sits at the bottom of the sidebar and can collapse.
-It groups ports under their row's branch name, ordered like the sidebar, with ports sorted by number.
+Its "Ports" label shows how many ports are listening.
+It groups ports under their row's mark and branch name, ordered like the sidebar, with ports sorted by number.
 
 ```
 feat/new-feature                x
@@ -438,9 +439,9 @@ feat/new-feature-2              x
 - Clicking a branch heading selects that row.
 - Clicking a badge opens `http://localhost:<port>`.
 - Hovering a badge shows the process name and PID.
-- A badge's `x` stops the process listening on that port.
+- A badge's `x`, shown on hover, stops the process listening on that port.
   Its tooltip names the process, because stopping it also closes any other ports it holds.
-- A group's `x` stops every process holding a port in that row.
+- A group's `x`, shown while hovering its branch name, stops every process holding a port in that row.
 - Stopping sends SIGTERM, then SIGKILL if the port is still listening after 3 seconds.
 - Badges wrap onto new lines.
 
```

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyApp/Sidebar docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "feat: the ports panel in the sidebar's style"
```

### Task 7: Tabs in the title bar row

See "The title bar row" above for why the bar is a window-level overlay.
`TabBarView.swift` becomes `TopBarView.swift`.

**Files:**
- Create: `Sources/CanopyApp/Terminal/TopBarView.swift`
- Delete: `Sources/CanopyApp/Terminal/TabBarView.swift`
- Modify: `Sources/CanopyCore/Layout/Layout.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/CanopyApp.swift`, `Sources/CanopyApp/Terminal/RowTerminalsView.swift`, `Sources/CanopyApp/Style/Style.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`
- Test: `Tests/CanopyCoreTests/LayoutTests.swift`

**Interfaces:**
- Consumes: `IconButton`, `RunningDot`, `RepoTile`, `Style` (Task 5); `TerminalTab.isRunningProgram` (Task 3).
- Produces: `LayoutShape` (`single`, `columns(Int)`, `rows(Int)`, `grid`) and `Layout.shape`; `Style.chrome`; `TopBarView(row:isSidebarHidden:)`; `TitleBarArea`.

- [ ] **Step 1: Write the failing test for layout shapes**

```diff
@@ -30,6 +30,14 @@ struct LayoutTests {
                     .column, [.split(.row, ["A", "B", "C"].map(Grid.leaf), Grid.equal(3)), .leaf("D")], [0.5, 0.5]))
     }
 
+    @Test func shapeNamesTheArrangementForATabsIcon() {
+        #expect(Grid.leaf("A").shape == .single)
+        #expect(Grid.built(["A", "B"], perLine: 3).shape == .columns(2))
+        #expect(Grid.built(["A", "B", "C"], perLine: 3).shape == .columns(3))
+        #expect(Grid.built(["A", "B"], perLine: 1).shape == .rows(2))
+        #expect(Grid.built(["A", "B", "C"], perLine: 2).shape == .grid)
+    }
+
     @Test func narrowTabsWrapSooner() {
         let row = Grid.split(.row, [.leaf("A"), .leaf("B")], [0.5, 0.5])
         #expect(Grid.built(["A", "B", "C"], perLine: 2) == .split(.column, [row, .leaf("C")], [0.5, 0.5]))
```

- [ ] **Step 2: Run it to see it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter LayoutTests`
Expected: the build fails: `value of type 'Layout<String>' has no member 'shape'`.

- [ ] **Step 3: Implement layout shapes**

```diff
@@ -14,6 +14,17 @@ public enum Edge: Sendable, CaseIterable {
     var putsMovedFirst: Bool { self == .left || self == .top }
 }
 
+/// The overall arrangement of a layout, for a tab's icon.
+public enum LayoutShape: Equatable, Sendable {
+    case single
+    /// Panes side by side.
+    case columns(Int)
+    /// Panes stacked.
+    case rows(Int)
+    /// Anything with both.
+    case grid
+}
+
 /// A tab's arrangement of panes: a single pane, or a split whose children each take a share of its extent.
 /// Every operation returns a normalized layout: no split has one child, and no split sits directly inside a
 /// split of the same axis.
@@ -29,6 +40,18 @@ public indirect enum Layout<Leaf: Hashable & Sendable>: Hashable, Sendable {
         }
     }
 
+    public var shape: LayoutShape {
+        switch self {
+        case .leaf: .single
+        case .split(let axis, let children, _):
+            if children.allSatisfy({ if case .leaf = $0 { true } else { false } }) {
+                axis == .row ? .columns(children.count) : .rows(children.count)
+            } else {
+                .grid
+            }
+        }
+    }
+
     public func contains(_ leaf: Leaf) -> Bool {
         leaves.contains(leaf)
     }
```

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter LayoutTests`
Expected: PASS, 14 tests.

- [ ] **Step 4: Add the chrome color**

```diff
@@ -34,6 +34,10 @@ enum Style {
         nsColor: NSColor(name: nil) { appearance in
             NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.3 : 0.17)
         })
+    /// The top bar, pane headers, and exit strips: a step off the terminal's white in light, the window's own gray
+    /// in dark, where the terminal is the darker one.
+    static let chrome = Color(
+        nsColor: NSColor(name: nil) { $0.isDark ? .windowBackgroundColor : NSColor(hex: 0xF5F5F7) })
     static let badgeFill = Color.adaptive(
         light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.075))
 
```

- [ ] **Step 5: Write the top bar, replacing the tab bar**

```bash
git rm Sources/CanopyApp/Terminal/TabBarView.swift
```

```swift
import AppKit
import CanopyCore
import SwiftUI

/// The bar in the title bar row: a row's tabs, and the Split Pane and New Tab buttons. Its empty space moves the window
/// like a title bar. Double-click a tab to rename it.
struct TopBarView: View {
    @Environment(AppModel.self) private var model
    let row: Row
    /// While the sidebar is hidden, the bar names the row and leaves room for the traffic lights and sidebar toggle.
    let isSidebarHidden: Bool
    @State private var stripWidth = 0.0

    var body: some View {
        let tabs = model.terminals.tabs(inRow: row.path)
        let selected = model.terminals.selectedTab(inRow: row.path)?.id
        HStack(spacing: 2) {
            if isSidebarHidden {
                RowCrumb(row: row)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tab.id == selected,
                            onSelect: { model.terminals.selectTab(tab.id, inRow: row.path) },
                            onClose: { model.requestCloseTab(tab, inRow: row.path) },
                            onRename: { name in
                                model.terminals.renameTab(tab.id, inRow: row.path, to: name)
                                model.focusSelectedTerminal()
                            }
                        )
                    }
                }
                // Fills the strip, so the space after the last tab still moves the window.
                .frame(minWidth: stripWidth, maxHeight: .infinity, alignment: .leading)
                .background(TitleBarArea())
            }
            .onGeometryChange(for: Double.self) {
                $0.size.width
            } action: {
                stripWidth = $0
            }
            IconButton(
                title: "Split Pane", systemImage: "rectangle.split.2x1", shortcut: "⌘D", size: 26, imageSize: 13,
                action: model.splitPane)
            IconButton(
                title: "New Tab", systemImage: "plus", shortcut: "⌘T", size: 26, imageSize: 13, action: model.newTab)
        }
        .padding(.leading, isSidebarHidden ? Self.trafficLightsInset : 10)
        .padding(.trailing, 10)
        .frame(height: Style.topBarHeight)
        .background {
            TitleBarArea()
                .background(Style.chrome)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    /// Room for the traffic lights and the sidebar toggle, which sit over the bar's leading end.
    static let trafficLightsInset = 150.0
}

/// Empty title bar space: dragging it moves the window, and double-clicking it does what the system setting says.
struct TitleBarArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { Self.doubleClick(NSApp.keyWindow) })
    }

    static func doubleClick(_ window: NSWindow?) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }
}

/// The row's repo and branch, for when the sidebar is hidden.
struct RowCrumb: View {
    @Environment(AppModel.self) private var model
    let row: Row

    var body: some View {
        HStack(spacing: 6) {
            if let repo = model.snapshot.repo(path: row.repoPath) {
                RepoTile(mark: repo.mark)
                Text(repo.name)
                    .foregroundStyle(.secondary)
                Text(verbatim: "/")
                    .foregroundStyle(.tertiary)
            }
            Text(row.displayName)
                .fontWeight(.semibold)
        }
        .font(Style.body)
        .lineLimit(1)
        .fixedSize()
        .padding(.trailing, 6)
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 16)
            .padding(.trailing, 6)
    }
}

struct TabItemView: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.layout.shape.symbolName)
                .font(.system(size: 12))
                .frame(width: 14)
            if isRenaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .fixedSize()
                    .onAppear { isFieldFocused = true }
                    .onSubmit(finishRenaming)
                    .onExitCommand {
                        draft = tab.name
                        finishRenaming()
                    }
                    .onChange(of: isFieldFocused) {
                        if !isFieldFocused { finishRenaming() }
                    }
            } else {
                Text(tab.name)
                    .lineLimit(1)
            }
            // The close button and the running dot share a slot, so hovering does not shift the tab.
            ZStack {
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close Tab")
                } else if tab.isRunningProgram {
                    RunningDot(size: 5)
                }
            }
            .frame(width: 14, height: 14)
        }
        .font(Style.body.weight(isSelected ? .medium : .regular))
        .foregroundStyle(isSelected || isHovering ? .primary : .secondary)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: Style.tabHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                draft = tab.name
                isRenaming = true
            }
        )
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        onRename(draft)
    }
}

extension LayoutShape {
    var symbolName: String {
        switch self {
        case .single: "terminal"
        case .columns(let count): count > 2 ? "rectangle.split.3x1" : "rectangle.split.2x1"
        case .rows: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        }
    }
}
```

- [ ] **Step 6: Leave room for it in the detail column**

```diff
@@ -1,10 +1,11 @@
 import CanopyCore
 import SwiftUI
 
-/// The detail area for a row: its tab bar and the selected tab's terminal.
+/// The detail area for a row: the top bar with its tabs, and the selected tab's terminals.
 struct RowTerminalsView: View {
     @Environment(AppModel.self) private var model
     let row: Row
+    let isSidebarHidden: Bool
 
     var body: some View {
         if row.isMissing {
@@ -17,20 +18,25 @@ struct RowTerminalsView: View {
                     Button("Prune Missing Worktrees") { model.prune(repo) }
                 }
             }
-        } else if let tab = model.terminals.selectedTab(inRow: row.path) {
-            VStack(spacing: 0) {
-                TabBarView(row: row)
-                GridView(tab: tab)
-                    .id(tab.id)
-            }
         } else {
-            ContentUnavailableView {
-                Label("No Terminals", systemImage: "apple.terminal")
-            } description: {
-                Text("Press ⌘T to open one in \(row.displayName).")
-            } actions: {
-                Button("New Terminal") { model.newTab() }
+            VStack(spacing: 0) {
+                // RootView draws the top bar over this space.
+                Color.clear.frame(height: Style.topBarHeight)
+                if let tab = model.terminals.selectedTab(inRow: row.path) {
+                    GridView(tab: tab)
+                        .id(tab.id)
+                } else {
+                    ContentUnavailableView {
+                        Label("No Terminals", systemImage: "apple.terminal")
+                    } description: {
+                        Text("Press ⌘T to open one in \(row.displayName).")
+                    } actions: {
+                        Button("New Terminal") { model.newTab() }
+                    }
+                }
             }
+            // The top bar takes the title bar's row. The window's title bar is hidden, so clicks reach it.
+            .ignoresSafeArea(.container, edges: .top)
         }
     }
 }
```

- [ ] **Step 7: Hide the title bar and draw the bar over the detail column**

```diff
@@ -11,6 +11,8 @@ struct CanopyApp: App {
             RootView()
                 .environment(delegate.model)
         }
+        // The top bar draws the title bar's row itself, so its tabs and buttons get clicks.
+        .windowStyle(.hiddenTitleBar)
         .commands {
             TerminalCommands(model: delegate.model)
             RowCommands(model: delegate.model)
```

```diff
@@ -5,14 +5,29 @@ import UniformTypeIdentifiers
 
 struct RootView: View {
     @Environment(AppModel.self) private var model
+    @State private var columns = NavigationSplitViewVisibility.all
+    @State private var detailFrame = CGRect.zero
 
     var body: some View {
         @Bindable var model = model
-        NavigationSplitView {
+        NavigationSplitView(columnVisibility: $columns) {
             SidebarView()
                 .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
         } detail: {
-            RowDetailView()
+            RowDetailView(isSidebarHidden: columns == .detailOnly)
+                .onGeometryChange(for: CGRect.self) {
+                    $0.frame(in: .global)
+                } action: {
+                    detailFrame = $0
+                }
+        }
+        .overlay(alignment: .topLeading) {
+            if let row = model.selectedRow, !row.isMissing {
+                TopBarView(row: row, isSidebarHidden: columns == .detailOnly)
+                    .frame(width: detailFrame.width)
+                    .offset(x: detailFrame.minX)
+                    .ignoresSafeArea(.container, edges: .top)
+            }
         }
         .frame(minWidth: 900, minHeight: 560)
         .overlay(alignment: .bottom) {
@@ -57,12 +72,13 @@ struct RootView: View {
 
 struct RowDetailView: View {
     @Environment(AppModel.self) private var model
+    let isSidebarHidden: Bool
 
     var body: some View {
         if let row = model.selectedRow {
-            RowTerminalsView(row: row)
+            // The title bar is hidden, but the title still names the window in the Window menu and Mission Control.
+            RowTerminalsView(row: row, isSidebarHidden: isSidebarHidden)
                 .navigationTitle(row.displayName)
-                .navigationSubtitle(model.snapshot.repo(path: row.repoPath)?.name ?? "")
         } else {
             ContentUnavailableView {
                 Label("No Row Selected", systemImage: "sidebar.left")
```

- [ ] **Step 8: Check the clicks in the app**

Run: `make app && scripts/ui-fixture.sh dark && source build/ui-fixture.env && build/ui activate $pid`
Then, with `count` as `canopy term list --all --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'`:
- `build/ui click $pid <New Tab x> 26` raises the count by one, and the Split Pane button by one more;
- clicking the `agent` tab selects it;
- dragging from empty bar space moves the window, and double-clicking it zooms and then restores the window;
- double-clicking a tab starts renaming it, and Escape cancels;
- the sidebar toggle hides the sidebar, and the bar then starts with the repo tile, repo, and branch, clear of the toggle;
- twelve tabs made with `canopy term new --tab "Terminal $i"` scroll in the strip, with both buttons still at the trailing end;
- with another app in front, the bar still draws.

- [ ] **Step 9: Update the spec**

```diff
@@ -296,8 +296,12 @@ If any pane's foreground process is something other than its shell, quitting ask
 
 ### Tabs
 
-Each row has its own tab bar.
-Its right end has a split button, which adds a pane like `⌘D`, and a `+` button, which opens a tab like `⌘T`.
+Each row has its own tab bar, which sits in the window's title bar row beside the traffic lights.
+Each tab shows an icon for its layout: one pane, panes side by side, panes stacked, or both.
+A running dot follows the name while a program runs in one of the tab's panes, and gives way to the tab's `x` on hover.
+The bar's right end has a split button, which adds a pane like `⌘D`, and a `+` button, which opens a tab like `⌘T`.
+Its empty space moves the window, and double-clicking it zooms or minimizes the window as the system's title bar setting says.
+While the sidebar is hidden, the bar starts with the row's repo and branch.
 New tabs are named "Terminal", "Terminal 2", and so on, or take the name given with `--tab`.
 Double-clicking a tab renames it.
 Selecting a row that has no tabs opens one tab with one pane.
```

- [ ] **Step 10: Commit**

```bash
git add Sources docs/superpowers/specs/2026-09-27-canopy-design.md Tests/CanopyCoreTests/LayoutTests.swift
git commit -m "feat: tabs in the title bar row, with layout icons and running dots"
```

### Task 8: Pane headers and the exit strip

**Files:**
- Modify: `Sources/CanopyApp/Terminal/PaneView.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`

**Interfaces:**
- Consumes: `RunningDot`, `Style.chrome`, `Style.paneHeaderHeight` (Tasks 5 and 7); `Pane.isRunningProgram` (Task 3).
- Produces: `PaneHeader(pane:isFocused:onClose:)`, `PaneStatusMark(pane:size:)`, `ExitStrip(pane:code:)`.

- [ ] **Step 1: Restyle the header and the strip**

```diff
@@ -14,7 +14,7 @@ struct PaneView: View {
 
     var body: some View {
         VStack(spacing: 0) {
-            PaneHeader(title: pane.title, isFocused: isFocused, onClose: onClose)
+            PaneHeader(pane: pane, isFocused: isFocused, onClose: onClose)
                 // The header is the handle for dragging the pane onto another one.
                 .onDrag {
                     onDragStart()
@@ -30,7 +30,7 @@ struct PaneView: View {
                 onSizeChange: onSizeChange
             )
             if case .exited(let code) = pane.status {
-                ExitStrip(code: code)
+                ExitStrip(pane: pane, code: code)
             }
         }
         .task(id: pane.id) {
@@ -44,60 +44,95 @@ struct PaneView: View {
 }
 
 struct PaneHeader: View {
-    static let height = 24.0
+    static let height = Style.paneHeaderHeight
 
-    let title: String
+    let pane: Pane
     let isFocused: Bool
     let onClose: () -> Void
     @Environment(\.controlActiveState) private var activeState
+    @State private var isHovering = false
 
     private var isHighlighted: Bool { isFocused && activeState == .key }
 
     var body: some View {
-        HStack(spacing: 6) {
-            Text(title.isEmpty ? "Terminal" : title)
-                .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
+        HStack(spacing: 7) {
+            PaneStatusMark(pane: pane)
+                .frame(width: 12)
+            Text(pane.title.isEmpty ? "Terminal" : pane.title)
+                .font(Style.meta.weight(isHighlighted ? .semibold : .regular))
                 .foregroundStyle(isHighlighted ? .primary : .secondary)
                 .lineLimit(1)
                 .truncationMode(.middle)
             Spacer(minLength: 4)
-            Button(action: onClose) {
-                Image(systemName: "xmark")
-                    .font(.system(size: 9, weight: .bold))
-                    .frame(width: 16, height: 16)
-                    .contentShape(Rectangle())
+            if isHovering {
+                Button(action: onClose) {
+                    Image(systemName: "xmark")
+                        .font(.system(size: 9, weight: .bold))
+                        .frame(width: 18, height: 18)
+                        .contentShape(Rectangle())
+                }
+                .buttonStyle(.plain)
+                .foregroundStyle(.secondary)
+                .help("Close Terminal (⌘W)")
             }
-            .buttonStyle(.borderless)
-            .foregroundStyle(.secondary)
-            .help("Close Terminal (⌘W)")
         }
         .padding(.leading, 10)
-        .padding(.trailing, 6)
+        .padding(.trailing, 5)
         .frame(height: Self.height)
-        .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
+        .background {
+            Style.chrome
+                .overlay(isHighlighted ? Color.accentColor.opacity(0.14) : .clear)
+        }
         .overlay(alignment: .bottom) {
             Rectangle().fill(.separator).frame(height: 1)
         }
+        .contentShape(Rectangle())
+        .onHover { isHovering = $0 }
+        .accessibilityElement(children: .combine)
+        .accessibilityAction(named: "Close Terminal", onClose)
+    }
+}
+
+/// What a pane is doing: an idle shell, a running program, or an exit, with its code.
+struct PaneStatusMark: View {
+    let pane: Pane
+    var size = 11.0
+
+    var body: some View {
+        switch pane.status {
+        case .exited(let code):
+            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
+                .font(.system(size: size))
+                .foregroundStyle(code == 0 ? .green : .red)
+                .accessibilityLabel(code == 0 ? "Exited" : "Exited with code \(code)")
+        case .running where pane.isRunningProgram:
+            RunningDot()
+        case .running:
+            Image(systemName: "terminal")
+                .font(.system(size: size))
+                .foregroundStyle(.tertiary)
+                .accessibilityHidden(true)
+        }
     }
 }
 
 struct ExitStrip: View {
+    let pane: Pane
     let code: Int32
 
     var body: some View {
-        HStack(spacing: 10) {
-            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
-                .foregroundStyle(code == 0 ? .green : .red)
-            Text("exited (code \(code))")
-                .fontWeight(.medium)
-            Text("Return restarts the shell. ⌘W closes the terminal.")
+        HStack(spacing: 8) {
+            PaneStatusMark(pane: pane, size: 13)
+            Text(code == 0 ? "Exited" : "Exited with code \(code)")
+                .font(Style.body.weight(.semibold))
+            Text("Return restarts the shell. ⌘W closes it.")
+                .font(Style.meta)
                 .foregroundStyle(.secondary)
             Spacer()
         }
-        .font(.callout)
         .padding(.horizontal, 10)
-        .frame(height: 28)
-        .background(.bar)
+        .frame(height: 30)
+        .background(Style.chrome)
         .overlay(alignment: .top) {
             Rectangle().fill(.separator).frame(height: 1)
         }
```

- [ ] **Step 2: Check it in the app**

Run: `make app && scripts/ui-fixture.sh dark`, then `canopy term send p3 "exit 3" --enter`.
Expected: running dots on the `sleep` and `Python` headers, a red cross on `zsh`, the strip "Exited with code 3", and `×` only on the hovered header.

- [ ] **Step 3: Update the spec**

```diff
@@ -273,14 +273,15 @@ Scrollback holds 10,000 lines per pane.
 
 ### Pane chrome
 
-Each pane has a thin header with its title and a close button.
+Each pane has a thin header with a status mark, its title, and a close button that shows on hover.
+The mark is a terminal glyph while the shell is idle, a running dot while a program runs, and a green check or red cross after the shell exits.
 The title comes from the running program when it sets one, and falls back to the foreground process name.
 The header is the drag handle.
 The focused pane's header is highlighted.
 
 ### Process exit
 
-When a pane's shell exits, the pane shows "exited (code N)".
+When a pane's shell exits, a strip at the bottom of the pane says "Exited", or "Exited with code N" for a nonzero code.
 Enter restarts the shell in the same folder, and `⌘W` closes the pane.
 
 ### Hidden panes
```

- [ ] **Step 4: Commit**

```bash
git add Sources/CanopyApp/Terminal/PaneView.swift docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "feat: pane headers with status marks, and an exit strip to match"
```

### Task 9: The terminal's palettes, padding, and scroller

SwiftTerm keeps its scroller private and reserves its width at the right edge, 17 points for the overlay style.
The minimum pane width counted only the padding, so an 80-column minimum fit about 77 columns; it now counts the scroller too.

**Files:**
- Modify: `Sources/CanopyApp/Terminal/SwiftTermEmulator.swift`, `Sources/CanopyApp/Terminal/TerminalSurface.swift`, `Sources/CanopyApp/AppModel.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`

**Interfaces:**
- Consumes: `NSAppearance.isDark`, `NSColor(hex:)` (Task 5).
- Produces: `SwiftTermEmulator.scrollerWidth`, `TerminalContainerView.horizontalInset`.

- [ ] **Step 1: Palettes, backgrounds, and the scroller**

```diff
@@ -14,13 +14,24 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         return CGSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
     }()
 
-    /// Terminal.app's ANSI colors, which read well on light and dark backgrounds alike.
-    private static let palette: [SwiftTerm.Color] = [
-        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
-        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
-        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
-        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
-    ].map { (rgb: (UInt16, UInt16, UInt16)) in Color(red8: rgb.0, green8: rgb.1, blue8: rgb.2) }
+    /// The 16 ANSI colors, softened for a dark background.
+    private static let darkPalette = colors([
+        0x3A3A40, 0xF2736B, 0x7CCD80, 0xE3C46D, 0x72AAF6, 0xC895EA, 0x6DD0D9, 0xC9C9CE,
+        0x6A6A72, 0xFF8C85, 0x97DE99, 0xF0D48B, 0x8FBDFF, 0xD8AAF5, 0x90E1E8, 0xF3F3F6,
+    ])
+
+    /// The 16 ANSI colors, deepened so each still reads on white.
+    private static let lightPalette = colors([
+        0x1F1F24, 0xC4332C, 0x2B8A3E, 0x9A6A00, 0x1F5FD1, 0x8E3FB5, 0x0F7F8C, 0x8A8A92,
+        0x5E5E66, 0xE0453D, 0x37A34E, 0xB98200, 0x3B7BEF, 0xA955D6, 0x1597A6, 0xB8B8BE,
+    ])
+
+    private static func colors(_ hexes: [UInt32]) -> [SwiftTerm.Color] {
+        hexes.map { Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) }
+    }
+
+    /// The width SwiftTerm keeps free for its scroller at the right edge.
+    static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
 
     let view: NSView
     private let terminalView: TerminalView
@@ -38,7 +49,7 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         terminalView.terminalDelegate = self
         // Panes read the zsh shim's command reports from the output before it gets here.
         terminalView.getTerminal().registerOscHandler(code: ZshIntegration.reportCode) { _ in }
-        terminalView.installColors(Self.palette)
+        scroller?.alphaValue = 0
         applyAppearance(NSApp.effectiveAppearance)
     }
 
@@ -84,17 +95,19 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         terminalView.feed(byteArray: [UInt8](data)[...])
     }
 
-    /// Text and background follow the system's light or dark appearance.
+    /// Colors follow the system's light or dark appearance. In dark, the terminal sits a step below the window's
+    /// chrome, so panes have an edge.
     func applyAppearance(_ appearance: NSAppearance) {
-        var foreground = NSColor.black
-        var background = NSColor.white
-        appearance.performAsCurrentDrawingAppearance {
-            foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? foreground
-            background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? background
-        }
-        self.background = background
-        terminalView.nativeForegroundColor = foreground
+        let isDark = appearance.isDark
+        background = NSColor(hex: isDark ? 0x161618 : 0xFFFFFF)
+        terminalView.nativeForegroundColor = NSColor(hex: isDark ? 0xDCDCE1 : 0x1F1F24)
         terminalView.nativeBackgroundColor = background
+        terminalView.installColors(isDark ? Self.darkPalette : Self.lightPalette)
+    }
+
+    /// SwiftTerm keeps its scroller private, so it is found among the view's subviews.
+    private var scroller: NSScroller? {
+        terminalView.subviews.lazy.compactMap { $0 as? NSScroller }.first
     }
 
     // MARK: TerminalViewDelegate
@@ -113,7 +126,15 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
         onInput?(Data(data))
     }
 
-    func scrolled(source: TerminalView, position: Double) {}
+    /// The scroller shows only while the view is scrolled back from the bottom, into the scrollback.
+    func scrolled(source: TerminalView, position: Double) {
+        let isScrolledBack = position < 1
+        guard let scroller, (scroller.alphaValue > 0) != isScrolledBack else { return }
+        NSAnimationContext.runAnimationGroup { context in
+            context.duration = isScrolledBack ? 0.1 : 0.4
+            scroller.animator().alphaValue = isScrolledBack ? 1 : 0
+        }
+    }
 
     func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
 
```

- [ ] **Step 2: Padding, and the scroller in the width math**

```diff
@@ -27,7 +27,11 @@ struct TerminalSurface: NSViewRepresentable {
 }
 
 final class TerminalContainerView: NSView {
-    static let padding = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)
+    /// No right padding: SwiftTerm already keeps `SwiftTermEmulator.scrollerWidth` free at the right edge.
+    static let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 0)
+
+    /// All the width a pane spends on things other than its columns.
+    static let horizontalInset = padding.left + padding.right + SwiftTermEmulator.scrollerWidth
 
     private let emulator: SwiftTermEmulator
     var takesFocus = true
```

```diff
@@ -358,7 +358,7 @@ final class AppModel {
         let cell = SwiftTermEmulator.cellSize
         let padding = TerminalContainerView.padding
         return CGSize(
-            width: 20 * cell.width + padding.left + padding.right,
+            width: 20 * cell.width + TerminalContainerView.horizontalInset,
             height: 5 * cell.height + padding.top + padding.bottom + PaneHeader.height)
     }
 
@@ -372,9 +372,8 @@ final class AppModel {
 
     /// Whether a line of that many panes keeps each at least `minPaneColumns` wide in the current grid.
     private func addRuleFits() -> (Int) -> Bool {
-        let padding = TerminalContainerView.padding
         let minimumWidth =
-            Double(config.minPaneColumns) * SwiftTermEmulator.cellSize.width + padding.left + padding.right
+            Double(config.minPaneColumns) * SwiftTermEmulator.cellSize.width + TerminalContainerView.horizontalInset
         let width = gridSize.width
         return { width / Double($0) >= minimumWidth }
     }
```

- [ ] **Step 3: Check it in the app**

Run: `make app && scripts/ui-fixture.sh dark`, then print 120 colored lines in `p3` with `canopy term send`.
Expected: every ANSI color readable, the terminal a step darker than the chrome, no scroller at the bottom, a scroller after `build/ui scroll $pid <x> <y> 10`, and none again after scrolling back down.
Then the same in light.

- [ ] **Step 4: Update the spec**

```diff
@@ -268,7 +268,9 @@ The environment adds:
 Agents inside any Canopy terminal can therefore run `canopy` without arguments naming the repo or row.
 
 The font is the system monospaced font at 13 points.
-Colors follow the system light or dark appearance.
+Colors follow the system light or dark appearance, with Canopy's own 16 ANSI colors for each.
+In dark, the terminal's background sits a step below the window's chrome, so panes have an edge.
+The scroller shows only while the terminal is scrolled back into its scrollback.
 Scrollback holds 10,000 lines per pane.
 
 ### Pane chrome
@@ -327,7 +329,7 @@ The add rule fills the bottom line of panes to the right until panes would get t
    A last line that is not a `row` split becomes one, holding the old line and the new pane.
 5. Otherwise add the pane as a new line at the bottom of the root, wrapping the root in a `column` split if needed, and make the line heights equal.
 
-The minimum pane width is 80 columns in the current font plus pane padding.
+The minimum pane width is 80 columns in the current font plus pane padding and the room kept for the scroller.
 It is configurable as `minPaneColumns` in `config.json`.
 
 ```
```

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyApp docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "feat: terminal palettes for dark and light, more padding, and a scroller only while scrolled back"
```

### Task 10: The toast

**Files:**
- Modify: `Sources/CanopyApp/RootView.swift`

- [ ] **Step 1: Restyle it**

```diff
@@ -93,16 +93,24 @@ struct RowDetailView: View {
     }
 }
 
+/// Every toast reports something that went wrong, such as git's message for a failed command.
 struct ToastView: View {
     let message: String
 
     var body: some View {
-        Text(message)
-            .font(.callout)
-            .padding(.horizontal, 14)
-            .padding(.vertical, 9)
-            .background(.regularMaterial, in: Capsule())
-            .overlay(Capsule().strokeBorder(.separator))
-            .shadow(radius: 8, y: 2)
+        HStack(alignment: .firstTextBaseline, spacing: 8) {
+            Image(systemName: "exclamationmark.triangle.fill")
+                .foregroundStyle(.orange)
+            Text(message)
+                .fixedSize(horizontal: false, vertical: true)
+        }
+        .font(.callout)
+        .padding(.horizontal, 14)
+        .padding(.vertical, 9)
+        .frame(maxWidth: 560)
+        // A pill for one line, a rounded box once a long message wraps.
+        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
+        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.separator))
+        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
     }
 }
```

- [ ] **Step 2: Check it in the app**

Launch the dev build on a home whose `state.json` holds `{ "broken`.
Expected: the warning toast wraps its two lines in a rounded box, in dark and light.

- [ ] **Step 3: Commit**

```bash
git add Sources/CanopyApp/RootView.swift
git commit -m "feat: toasts lead with a warning icon and wrap long messages"
```

### Task 11: The selected row scrolls into view

`List` did not follow the selection either, but with custom rows and long repos it matters: `⌘9` or `canopy row select` could pick a row out of sight.

**Files:**
- Modify: `Sources/CanopyApp/Sidebar/SidebarView.swift`, `docs/superpowers/specs/2026-09-27-canopy-design.md`

- [ ] **Step 1: Scroll to it**

```diff
@@ -28,6 +28,17 @@ struct SidebarView: View {
     }
 
     private var repoList: some View {
+        ScrollViewReader { proxy in
+            repoScroll
+                // A row picked with ⌘1 to ⌘9 or `canopy row select` scrolls into view.
+                .onChange(of: model.selectedRowPath) {
+                    guard let path = model.selectedRowPath else { return }
+                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path) }
+                }
+        }
+    }
+
+    private var repoScroll: some View {
         ScrollView {
             VStack(alignment: .leading, spacing: 0) {
                 if !model.snapshot.repos.isEmpty {
@@ -98,6 +109,7 @@ struct RepoSection: View {
                     row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                     shortcut: model.shortcut(for: row), removable: row.rowClass != .main
                 )
+                .id(row.path)
                 .contextMenu {
                     if row.isMissing {
                         Button("Prune Missing Worktrees") { model.prune(repo) }
@@ -110,7 +122,9 @@ struct RepoSection: View {
                     ForEach(repo.external) { row in
                         RowLineView(
                             row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
-                            shortcut: nil, removable: false)
+                            shortcut: nil, removable: false
+                        )
+                        .id(row.path)
                     }
                 }
             }
```

- [ ] **Step 2: Check it in the app**

With 26 more rows in `docs`, `canopy row select feat/task-24-with-a-longer-branch-name --repo docs` scrolls the sidebar just far enough to show it.

- [ ] **Step 3: Update the spec**

```diff
@@ -233,6 +233,7 @@ A row line reads, left to right: icon, branch name, then a right-aligned running
 - The selected row has a rounded highlight, tinted with the accent color while the sidebar has the keyboard.
   `↑` and `↓` then move the selection.
 - `⌘1` to `⌘9` select the first nine visible rows across all repos, in sidebar order.
+- A row selected any other way than by clicking it, such as with `⌘1` or `canopy row select`, scrolls into view.
 - A detached HEAD shows the short commit hash in place of a branch name.
 - External worktrees fold into a "3 other worktrees" row under their repo's rows.
 
```

- [ ] **Step 4: Commit**

```bash
git add Sources/CanopyApp/Sidebar/SidebarView.swift docs/superpowers/specs/2026-09-27-canopy-design.md
git commit -m "feat: the sidebar scrolls a newly selected row into view"
```

## Decisions to review

- Custom sidebar rows in place of the native `List`.
- A fixed compact density that ignores the system's sidebar size.
- The running dot, the one behavior change in `CanopyCore`.
- Add Repo moves from the sidebar bottom to the Repos label, File > Add Repo… (`⇧⌘O`), and the empty states.
- The tabs share the title bar row, which drops the row's name from the top of the window while the sidebar is shown.
- The top bar is 52 points, not the 46 in the mockup, so the tabs line up with the native traffic lights.
- The top bar is a window-level overlay rather than part of the detail column, for the click problem described above.
- Two additions beyond the approved direction: the sidebar scrolls a newly selected row into view, and `scripts/ui-fixture.sh`.
- The ports panel hides when there are no repos.
