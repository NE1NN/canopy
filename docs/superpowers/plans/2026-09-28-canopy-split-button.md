# Canopy Split Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a button that splits a pane, so adding a pane no longer needs `⌘D`.

**Architecture:** The tab bar gets a split button left of its `+` button.
It calls `AppModel.splitPane`, the same action as `⌘D`, so both place the new pane by the add rule and focus it.
Both buttons share one `TabBarButton` view so they look the same.

**Tech Stack:** Swift 6.2, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Tabs" and "Adding a pane".

## Global Constraints

- The button does exactly what `⌘D` does, with no new layout logic.
- Its tooltip names the shortcut, like the `+` button's "New Tab (⌘T)".
- It matches the `+` button's size, weight, and color.
- VoiceOver reads each icon button by its name, "Split Pane" or "New Tab".

## Decisions to Review

1. **The button sits in the tab bar, not in each pane header.**
   The add rule adds a pane to the whole tab, filling the bottom line to the right, so it does not split the pane it would sit on.
   A per-pane button would suggest "split this pane", which Canopy does not do.
2. **The icon is `rectangle.split.2x1`,** two panes side by side.
   The add rule sometimes starts a new line below instead, but the icon reads as "split" either way.

---

## Task 1: The split button

**Files:** Modify `Sources/CanopyApp/Terminal/TabBarView.swift`, the `splitPane` comment in `Sources/CanopyApp/AppModel.swift`, and "Tabs" in the spec.

- [ ] **Step 1: Pull the `+` button's look into `TabBarButton`, and add the split button next to it**

```diff
-            Button(action: model.newTab) {
-                Image(systemName: "plus")
-                    .font(.system(size: 12, weight: .medium))
-                    .frame(width: 24, height: 24)
-                    .contentShape(Rectangle())
+            HStack(spacing: 2) {
+                TabBarButton(
+                    title: "Split Pane", systemImage: "rectangle.split.2x1", shortcut: "⌘D", action: model.splitPane)
+                TabBarButton(title: "New Tab", systemImage: "plus", shortcut: "⌘T", action: model.newTab)
             }
-            .buttonStyle(.borderless)
-            .foregroundStyle(.secondary)
-            .help("New Tab (⌘T)")
             .padding(.trailing, 6)
```

```swift
struct TabBarButton: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
    }
}
```

- [ ] **Step 2: Say in the spec's "Tabs" section what the tab bar's buttons do**

```markdown
Its right end has a split button, which adds a pane like `⌘D`, and a `+` button, which opens a tab like `⌘T`.
```

- [ ] **Step 3: Check it in the dev app, in dark and light**

Run `make app`, open a row in a throwaway `CANOPY_HOME`, click the split button, and take a window shot.
Expected: a second pane appears where `⌘D` would put it, and it has focus.

- [ ] **Step 4: Run the checks**

Run `make lint`, `make build`, `make test` three times, and `make e2e`.
Expected: no warnings, and every run passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyApp docs/superpowers/specs
git commit -m "feat: a split button in the tab bar"
```

## After Review

An independent reviewer read `git diff main...feat/split-pane-button` against the spec and this plan.

1. **Minor: the icon buttons had no spoken name.**
   `.help` sets only the tooltip, so VoiceOver read the split button by its symbol name.
   `TabBarButton` now takes a title, uses it as the accessibility label, and builds the tooltip from the title and shortcut.
   This also names the `+` button, which had the same gap before this PR.

The reviewer confirmed the button runs the same code as `⌘D`, focuses the new pane the same way, and cannot appear when `splitPane` would do nothing, so it needs no disabled state.
