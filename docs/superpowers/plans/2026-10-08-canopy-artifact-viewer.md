# Canopy Artifact Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** claude.ai artifacts, and any page an agent opens with `canopy web open`, show inside Canopy in the row they belong to, in a right-hand panel or a tab of their own.

**Architecture:** CanopyCore models web pages beside terminals: a `TerminalTab` holds either a `TerminalGrid` or one `WebPage`, and each row may hold one panel page.
The store applies the opening, moving, and closing rules, saves pages in `state.json`, logs `web.opened` and `web.closed`, and routes ⌘-clicked terminal links.
The app keeps one `WKWebView` per page in `WebViews`, made the first time the page shows, and draws the panel, its header in the title bar row, web tabs, and the sign-in pop-up sheet.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI and AppKit, WebKit (`WKWebView`, `WKWebsiteDataStore.default()`), SwiftTerm 1.20, swift-argument-parser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-08-canopy-artifact-viewer-design.md`

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings from `swift build`.
- `make lint` (swift format, strict) passes.
- Logic lives in CanopyCore, and views in CanopyApp stay thin.
- Artifact links are `https://claude.ai/artifact/<id>` and `https://claude.ai/code/artifact/<uuid>`, with an optional trailing slash, query, and fragment, and `www.claude.ai`.
- Page IDs are `w<number>`, from a counter saved like the pane counter.
- The panel is 480 points wide by default, at least 320, at most two thirds of the detail area, one width for every row, saved as `webPanelWidth`.
- `webPlacement` is `panel` or `tab`, `panel` when absent.
- An older `state.json` loads as having no web pages.
- CLI errors: `invalid_url`, `row_not_found`, `page_not_found`.
- WebKit names a type `WebPage` too, so app files that import WebKit write `CanopyCore.WebPage`.
- Markdown: one sentence per line, no em dashes. Code comments only for why. Commits carry no attribution trailers.
- Never quit or kill the release Canopy, and never run `make install`. Dev builds are stopped by pid.

## Review Focus

1. An artifact ⌘-clicked again after its page moved on, as to claude.ai's sign-in: the page already open shows, and no second page opens. Pinned in Task 3 by `aPageThatMovedOnIsStillFoundByTheLinkItOpenedWith`.
2. `canopy web open` from a plugin row's terminal, which knows its row only by `CANOPY_ROW_PATH`: the page opens in that row, `web list` names the plugin and no repo, and removing the row takes its pages with it. Pinned in Task 5 by `aPluginRowShowsPagesAndTheyGoWithIt`.
3. `canopy web open` in a row whose worktree folder is gone: `path_not_found`, as `term new` says. Pinned in Task 5 by `webOpenRefusesARowWhoseFolderIsGoneAndAPlacementItDoesNotKnow`.
4. A script sending a placement Canopy does not know, such as `"window"`: `bad_params`, not an internal error. Pinned in Task 5 by the same test.
5. A saved page whose address is no longer http or https, as after a hand edit: it is dropped and the rest of the row restores. Pinned in Task 4 by `pagesThatAreNotWebAddressesAreDropped`.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/CanopyCore/Web/WebLinks.swift` | `ArtifactLink`, `WebAddress`, and `TerminalLink`, which says where a ⌘-clicked link goes |
| `Sources/CanopyCore/Web/WebPage.swift` | `WebPageID`, `WebPlacement`, `WebPage`, `WebPanel`, `OpenedPage` |
| `Sources/CanopyCore/Web/WebNavigation.swift` | which navigations stay in a page, Safari's user agent, and the panel's width limits |
| `Sources/CanopyCore/Terminal/TerminalStore.swift` | `TerminalGrid`, `TerminalTab.Content`, panels, saving and restoring pages |
| `Sources/CanopyCore/Terminal/TerminalStore+Web.swift` | opening, moving, hiding, closing, and finding pages, and following terminal links |
| `Sources/CanopyCore/State/SavedTerminals.swift`, `AppState.swift`, `Workspace.swift` | `SavedWebPage`, `SavedWebPanel`, `webPlacement`, `webPanelWidth`, `nextWebPage` |
| `Sources/CanopyCore/Control/WebMethods.swift`, `Rows/RowLifecycle+Web.swift` | `web.open`, `web.list`, `web.close` |
| `Sources/CanopyCLI/WebCommand.swift`, `AgentGuide.swift` | `canopy web` and the agent guide's Web Pages section |
| `Sources/CanopyApp/Web/WebViews.swift` | one `WKWebView` per page, navigation policy, pop-ups, ⌘R and ⌘[ ⌘] |
| `Sources/CanopyApp/Web/WebPageViews.swift` | the page view, its header, the panel, a web tab, and the pop-up sheet |
| `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `scripts/ui.swift` | end-to-end steps, a fixture with pages, and ⌘-clicks for UI checks |

Run tests with the package's flags, since Command Line Tools need extra search paths:

```bash
swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter <Suite>
```

---


### Task 1: Links: artifacts, web addresses, and terminal links

`ArtifactLink` recognises the two claude.ai artifact URL shapes and nothing else.
`WebAddress` accepts only http or https URLs with a host, which is all Canopy shows or hands to the browser.
`TerminalLink` says where a link ⌘-clicked in a terminal goes: an artifact into its row, a web link to the browser, a file path SwiftTerm found to its app as before, and any other scheme nowhere.

**Files:**
- Create: `Sources/CanopyCore/Web/WebLinks.swift`
- Create: `Tests/CanopyCoreTests/WebLinkTests.swift`

**Interfaces:**
- Consumes: Nothing new.
- Produces: `ArtifactLink(_ text: String)`, `ArtifactLink(_ url: URL)`, `.url`; `WebAddress.parse(_ text: String) -> URL?`, `WebAddress.isWeb(_ url: URL) -> Bool`; `TerminalLink(_ link: String)` with cases `.artifact(URL)`, `.browser(URL)`, `.path(String)`, `.refused`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WebLinkTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct WebLinkTests {
    @Test func readsArtifactLinks() {
        for text in [
            "https://claude.ai/artifact/a1B2-c3_d4", "https://claude.ai/artifact/a1B2-c3_d4/",
            "https://claude.ai/artifact/a1B2?ref=x", "https://claude.ai/artifact/a1B2#top",
            "https://www.claude.ai/artifact/a1B2", "HTTPS://Claude.AI/artifact/a1B2",
            " https://claude.ai/artifact/a1B2 ",
            "https://claude.ai/code/artifact/0b7f3a52-3c1e-4d0a-9a43-2f1e5b6c7d8e",
            "https://claude.ai/code/artifact/0B7F3A52-3C1E-4D0A-9A43-2F1E5B6C7D8E/?tab=1",
        ] {
            #expect(ArtifactLink(text) != nil, "\(text)")
        }
    }

    @Test func keepsTheLinkAsGiven() throws {
        let link = try #require(ArtifactLink("https://claude.ai/artifact/a1B2?ref=x#top"))
        #expect(link.url.absoluteString == "https://claude.ai/artifact/a1B2?ref=x#top")
    }

    @Test func refusesEverythingElse() {
        for text in [
            "", "claude.ai/artifact/a1B2", "http://claude.ai/artifact/a1B2", "https://claude.ai/artifact/",
            "https://claude.ai/artifact", "https://claude.ai/artifacts/a1B2", "https://claude.ai/artifact/a1B2/more",
            "https://claude.ai//artifact/a1B2", "https://claude.ai/artifact/a%20b", "https://claude.ai/chat/a1B2",
            "https://claude.ai/code/artifact/not-a-uuid", "https://claude.ai/code/artifact/a1B2",
            "https://evil.com/artifact/a1B2", "https://claude.ai.evil.com/artifact/a1B2",
            "https://api.claude.ai/artifact/a1B2", "https://user@claude.ai/artifact/a1B2",
            "https://claude.ai:8443/artifact/a1B2", "ftp://claude.ai/artifact/a1B2",
        ] {
            #expect(ArtifactLink(text) == nil, "\(text)")
        }
    }

    @Test func webAddressesAreHTTPOrHTTPSWithAHost() {
        #expect(WebAddress.parse("http://localhost:5173/x")?.absoluteString == "http://localhost:5173/x")
        #expect(WebAddress.parse(" https://example.com ")?.absoluteString == "https://example.com")
        for text in [
            "", "example.com", "file:///etc/hosts", "javascript:alert(1)", "https://", "http:///x", "mailto:a@b.c",
        ] {
            #expect(WebAddress.parse(text) == nil, "\(text)")
        }
    }

    @Test func terminalLinksRouteByKind() {
        #expect(
            TerminalLink("https://claude.ai/artifact/a1B2")
                == .artifact(URL(string: "https://claude.ai/artifact/a1B2")!))
        #expect(
            TerminalLink("https://github.com/acme/app/pull/7")
                == .browser(URL(string: "https://github.com/acme/app/pull/7")!))
        #expect(TerminalLink("http://localhost:3000") == .browser(URL(string: "http://localhost:3000")!))
        // SwiftTerm hands over paths it found in the text, which open with their app as before.
        #expect(TerminalLink("Sources/App.swift:12") == .path("Sources/App.swift:12"))
        #expect(TerminalLink("~/notes.md") == .path("~/notes.md"))
        for text in ["file:///etc/hosts", "javascript:alert(1)", "x-apple-reminder://a", "ssh://host", ""] {
            #expect(TerminalLink(text) == .refused, "\(text)")
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: cannot find 'ArtifactLink' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Web/WebLinks.swift`, new:

```swift
import Foundation

/// A claude.ai artifact's link, which opens inside Canopy instead of in the browser: `https://claude.ai/artifact/<id>`
/// or `https://claude.ai/code/artifact/<uuid>`, with an optional trailing slash, query, and fragment.
public struct ArtifactLink: Sendable, Equatable {
    public let url: URL

    static let hosts: Set<String> = ["claude.ai", "www.claude.ai"]

    public init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url)
    }

    public init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil, parts.port == nil,
            let host = parts.host?.lowercased(), Self.hosts.contains(host)
        else { return nil }
        var path = parts.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.count == 3, segments[1] == "artifact", Self.isID(segments[2]) {
            self.url = url
        } else if segments.count == 4, segments[1] == "code", segments[2] == "artifact",
            UUID(uuidString: segments[3]) != nil
        {
            self.url = url
        } else {
            return nil
        }
    }

    private static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// An http or https URL with a host, the only kind of page Canopy shows or hands to the browser.
public enum WebAddress {
    public static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), isWeb(url) else {
            return nil
        }
        return url
    }

    public static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host() ?? "").isEmpty
    }
}

/// Where a link ⌘-clicked in a terminal goes.
public enum TerminalLink: Equatable, Sendable {
    /// Into the terminal's row.
    case artifact(URL)
    case browser(URL)
    /// A file path SwiftTerm found in the text, which opens with its app as it always has.
    case path(String)
    /// Any other scheme, since text a program prints could hold links of any kind.
    case refused

    public init(_ link: String) {
        if let artifact = ArtifactLink(link) {
            self = .artifact(artifact.url)
        } else if let url = WebAddress.parse(link) {
            self = .browser(url)
        } else if !link.isEmpty, !Self.namesScheme(link) {
            self = .path(link)
        } else {
            self = .refused
        }
    }

    /// Whether the text starts with a scheme, such as `mailto:`. `App.swift:12` is a path and a line, not a scheme.
    private static func namesScheme(_ text: String) -> Bool {
        guard let match = text.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.\-]*:(.*)$/) else { return false }
        return match.1.wholeMatch(of: /\d+(:\d+)?/) == nil
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "WebLinkTests"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: recognise artifact links and route terminal links"
```

### Task 2: Web pages in rows: tabs hold terminals or a page, and pages open by the rules

A tab is either terminals or one web page, so `TerminalTab` gains `content`, and its layout, panes, and focus move into `TerminalGrid`.
`openTab` now returns the tab and its pane, since a tab no longer always has a focused pane.
A row also holds at most one panel page, and `openPage` applies the spec's three opening rules, logging `web.opened`.
Split Pane does nothing in a web tab, `term new` opens a terminal tab beside a selected web tab, and `--tab` names only terminal tabs.
The existing tests change mechanically: `openTab(...).focused` becomes `.pane`, a tab from `openTab` is `.tab`, and grid properties are read through `tab.grid`.

**Files:**
- Modify: `Sources/CanopyApp/AppModel.swift`
- Modify: `Sources/CanopyApp/Terminal/GridView.swift`
- Modify: `Sources/CanopyApp/Terminal/RowTerminalsView.swift`
- Modify: `Sources/CanopyApp/Terminal/TopBarView.swift`
- Modify: `Sources/CanopyCore/Activity/ActivityEvent.swift`
- Modify: `Sources/CanopyCore/Activity/ActivityReader.swift`
- Modify: `Sources/CanopyCore/Plugins/PluginHost.swift`
- Modify: `Sources/CanopyCore/Rows/RowLifecycle.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`
- Create: `Sources/CanopyCore/Terminal/TerminalStore+Web.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore.swift`
- Create: `Sources/CanopyCore/Web/WebPage.swift`
- Modify: `Tests/CanopyCoreTests/ActivityReaderTests.swift`
- Modify: `Tests/CanopyCoreTests/CommandLoggingTests.swift`
- Modify: `Tests/CanopyCoreTests/GridStoreTests.swift`
- Modify: `Tests/CanopyCoreTests/PaneAgentStateTests.swift`
- Modify: `Tests/CanopyCoreTests/PaneTests.swift`
- Modify: `Tests/CanopyCoreTests/PluginTerminalTests.swift`
- Modify: `Tests/CanopyCoreTests/RowSetupTests.swift`
- Modify: `Tests/CanopyCoreTests/TermSendTests.swift`
- Modify: `Tests/CanopyCoreTests/TerminalActivityTests.swift`
- Modify: `Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`
- Modify: `Tests/CanopyCoreTests/TerminalStoreTests.swift`
- Create: `Tests/CanopyCoreTests/WebPageOpenTests.swift`
- Modify: `Tests/CanopyTicketsTests/Support/TicketsHarness.swift`

**Interfaces:**
- Consumes: `WebAddress` from Task 1 (later tasks).
- Produces: `TerminalGrid` (`layout`, `panes`, `focusedPaneID`, `paneList`, `focused`); `TerminalTab.content: .terminals(TerminalGrid) | .web(WebPage)`, `.grid`, `.page`, `.paneList`, `.focused: Pane?`, `.name`; `TerminalStore.openTab(...) -> (tab: TerminalTab, pane: Pane)`, `addPane(...) -> Pane?`, `resize(_ grid: TerminalGrid, ...)`, `panelsByRow`, `webPlacement`, `onPageClosed: (WebPageID) -> Void`, `openPage(_ url: URL, for: PaneContext, placement: WebPlacement? = nil) -> OpenedPage`, `panel(inRow:) -> WebPanel?`, `shownPanel(inRow:) -> WebPage?`, `setPanelHidden(_:inRow:)`, `nextWebPageNumber`, `continueWebNumbering(from:)`; `WebPageID`, `WebPlacement`, `WebPage` (`id`, `url`, `title`, `context`, `displayTitle`), `WebPanel`, `OpenedPage`; `ActivityType.webOpened`, `.webClosed`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ActivityReaderTests.swift`, changed:

```diff
@@ -132,6 +132,12 @@ struct ActivityReaderTests {
         #expect(summary("pr.state_changed", ["number": 12, "from": "open", "to": "merged"]) == "#12 open -> merged")
         #expect(summary("term.opened", ["pane": "p3"]) == "p3")
         #expect(summary("term.exited", ["pane": "p3", "code": 129]) == "p3 exit 129")
+        #expect(
+            summary("web.opened", ["page": "w2", "placement": "panel", "url": "https://claude.ai/artifact/a"])
+                == "w2 panel: https://claude.ai/artifact/a")
+        #expect(
+            summary("web.closed", ["page": "w2", "url": "https://claude.ai/artifact/a"])
+                == "w2: https://claude.ai/artifact/a")
         #expect(
             summary("term.command", ["pane": "p3", "cmd": "make\nmake test", "exit": 2, "durationMs": 83_250])
                 == "p3 exit 2 in 1m23s: make \u{21b5} make test")
```

`Tests/CanopyCoreTests/CommandLoggingTests.swift`, changed:

```diff
@@ -116,7 +116,7 @@ struct ZshCommandLoggingTests {
         try FileManager.default.createDirectory(atPath: dir.sub("sub"), withIntermediateDirectories: true)
         let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "alias hello='echo hi-from-alias'"])
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         #expect(await run(pane, "hello", until: "hi-from-alias"))
         await pane.run("(exit 3)")
@@ -140,7 +140,7 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         let loaded = " .zshenv .zprofile .zshrc .zlogin"
         let home = dir.sub("user-home")
@@ -153,7 +153,7 @@ struct ZshCommandLoggingTests {
         files[".zshenv", default: ""] += "\nexport ZDOTDIR=$HOME/.config/zsh"
         let terminals = try Fixture.zshTerminals(dir, files: files)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         let loaded = " .zshenv .config/zsh/.zprofile .config/zsh/.zshrc .config/zsh/.zlogin"
         let config = dir.sub("user-home/.config/zsh")
@@ -172,7 +172,7 @@ struct ZshCommandLoggingTests {
             dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, logsCommands: logsCommands,
             zdotdir: zdot)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
         #expect(
@@ -188,7 +188,7 @@ struct ZshCommandLoggingTests {
         let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
         defer { terminals.closeAll() }
         chmod(dir.sub("user-home/.zshenv"), 0)
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         let home = dir.sub("user-home")
         #expect(
@@ -202,7 +202,7 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""), zdotdir: "")
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         #expect(
             await run(pane, Self.check, until: "check:::scalar-export::none:none:\(dir.sub("user-home"))/.zsh_history"))
@@ -216,7 +216,7 @@ struct ZshCommandLoggingTests {
         defer { terminals.closeAll() }
         // To a file, not the screen, so the check waits for the script to end rather than for its output to arrive.
         let script = #"print -r -- "$LOADED:${ZDOTDIR-unset}" > "$HOME/check""#
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(script)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(script)).pane
 
         #expect(await pane.waitForExit() == 0)
         let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
@@ -233,7 +233,7 @@ struct ZshCommandLoggingTests {
             """
         let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": zshrc])
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         await pane.run("echo one")
         #expect(await barrier(pane, terminals))
@@ -248,7 +248,7 @@ struct ZshCommandLoggingTests {
             let dir = try TempDir()
             let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "user_hook() { :; }\n" + reset])
             defer { terminals.closeAll() }
-            let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+            let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
             await pane.run("echo one")
             #expect(await barrier(pane, terminals), "\(reset)")
@@ -260,11 +260,11 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "alias hello='echo hi-from-alias'"])
         defer { terminals.closeAll() }
-        let first = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let first = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await run(first, "echo first-$((40 + 2))", until: "first-42"))
         try FileManager.default.removeItem(at: terminals.settings.home.zshShimFolder)
 
-        let pane = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })
+        let pane = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })!
         #expect(await run(pane, "hello", until: "hi-from-alias"))
         #expect(await eventually { await commands(terminals).last?.data["cmd"] == "hello" })
     }
@@ -273,7 +273,7 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "HISTORY_IGNORE='(*secret*|ls)'"])
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         await pane.run("echo my-secret-one")
         await pane.run("ls")
@@ -287,7 +287,7 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "setopt hist_ignore_space"])
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         await pane.run(" echo secret-one")
         await pane.run("echo public-two")
@@ -300,7 +300,7 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         let forge = #"printf '\e]6973;command;forged;0;1;fake;/\a'"#
         await pane.run(forge)
@@ -313,7 +313,7 @@ struct ZshCommandLoggingTests {
         let dir = try TempDir()
         let terminals = try Fixture.zshTerminals(dir, logsCommands: false)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         #expect(await run(pane, #"print -r -- "zd:${ZDOTDIR-unset}""#, until: "zd:unset"))
         #expect(await run(pane, Self.barrier, until: "done-42"))
```

`Tests/CanopyCoreTests/GridStoreTests.swift`, changed:

```diff
@@ -13,15 +13,15 @@ struct GridStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tab = terminals.openTab(for: context)
+        let tab = terminals.openTab(for: context).tab
 
-        let second = terminals.addPane(for: context, fits: { $0 <= 2 })
-        let third = terminals.addPane(for: context, fits: { $0 <= 2 })
+        let second = terminals.addPane(for: context, fits: { $0 <= 2 })!
+        let third = terminals.addPane(for: context, fits: { $0 <= 2 })!
 
         #expect(tab.paneList.count == 3)
-        #expect(tab.focusedPaneID == third.id)
+        #expect(tab.grid?.focusedPaneID == third.id)
         #expect(
-            tab.layout
+            tab.grid?.layout
                 == .split(
                     .column,
                     [.split(.row, [.leaf(tab.paneList[0].id), .leaf(second.id)], [0.5, 0.5]), .leaf(third.id)],
@@ -33,13 +33,13 @@ struct GridStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tab = terminals.openTab(for: context)
-        let first = tab.focused
-        let second = terminals.addPane(for: context, fits: { _ in true })
+        let tab = terminals.openTab(for: context).tab
+        let first = try #require(tab.focused)
+        let second = terminals.addPane(for: context, fits: { _ in true })!
 
         terminals.closePane(second.id)
-        #expect(tab.focusedPaneID == first.id)
-        #expect(tab.layout == .leaf(first.id))
+        #expect(tab.grid?.focusedPaneID == first.id)
+        #expect(tab.grid?.layout == .leaf(first.id))
         #expect(second.status == .exited(Pane.closedExitCode))
 
         terminals.closePane(first.id)
@@ -51,18 +51,18 @@ struct GridStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tab = terminals.openTab(for: context)
-        let a = tab.focused.id
-        let b = terminals.addPane(for: context, fits: { _ in true }).id
+        let tab = terminals.openTab(for: context).tab
+        let a = try #require(tab.focused).id
+        let b = terminals.addPane(for: context, fits: { _ in true })!.id
 
         terminals.movePane(a, to: .edge(.bottom), of: b)
-        #expect(tab.layout == .split(.column, [.leaf(b), .leaf(a)], [0.5, 0.5]))
+        #expect(tab.grid?.layout == .split(.column, [.leaf(b), .leaf(a)], [0.5, 0.5]))
         terminals.movePane(a, to: .center, of: b)
-        #expect(tab.layout == .split(.column, [.leaf(a), .leaf(b)], [0.5, 0.5]))
+        #expect(tab.grid?.layout == .split(.column, [.leaf(a), .leaf(b)], [0.5, 0.5]))
 
         terminals.focus(a)
         #expect(terminals.focusNeighbor(inRow: dir.path, toward: .down, in: rect)?.id == b)
-        #expect(tab.focusedPaneID == b)
+        #expect(tab.grid?.focusedPaneID == b)
         #expect(terminals.focusNeighbor(inRow: dir.path, toward: .down, in: rect) == nil)
     }
 
@@ -71,13 +71,14 @@ struct GridStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tab = terminals.openTab(for: context)
+        let tab = terminals.openTab(for: context).tab
         terminals.addPane(for: context, fits: { _ in true })
 
         terminals.resize(
-            tab, divider: DividerID(path: [], index: 0), to: 10, in: rect, minimum: CGSize(width: 300, height: 100))
+            try #require(tab.grid), divider: DividerID(path: [], index: 0), to: 10, in: rect,
+            minimum: CGSize(width: 300, height: 100))
 
-        #expect(tab.layout.frames(in: rect)[tab.paneList[0].id]?.width == 300)
+        #expect(tab.grid?.layout.frames(in: rect)[tab.paneList[0].id]?.width == 300)
     }
 
     @Test func savedTabsRestoreWithFreshShellsInTheirFolders() async throws {
@@ -87,9 +88,9 @@ struct GridStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let server = terminals.openTab(for: context)
+        let server = terminals.openTab(for: context).tab
         terminals.renameTab(server.id, inRow: dir.path, to: "Server")
-        let moved = terminals.addPane(for: context, fits: { _ in true })
+        let moved = terminals.addPane(for: context, fits: { _ in true })!
         terminals.openTab(for: context)
         terminals.selectTab(server.id, inRow: dir.path)
         await moved.run("cd sub")
@@ -106,7 +107,7 @@ struct GridStoreTests {
         #expect(restored.selectedTab(inRow: dir.path)?.name == "Server")
         let panes = tabs[0].paneList
         #expect(panes.count == 2)
-        #expect(tabs[0].focusedPaneID == panes[1].id)
+        #expect(tabs[0].grid?.focusedPaneID == panes[1].id)
         #expect(await eventually { panes[1].currentDirectory == sub })
         #expect(await eventually { panes[0].currentDirectory == dir.path })
     }
@@ -131,7 +132,7 @@ struct GridStoreTests {
         defer { terminals.closeAll() }
         terminals.continueNumbering(from: 40)
 
-        #expect(terminals.openTab(for: Fixture.context(dir.path)).focused.id == PaneID(40))
+        #expect(terminals.openTab(for: Fixture.context(dir.path)).pane.id == PaneID(40))
         #expect(terminals.nextPaneNumber == 41)
         terminals.continueNumbering(from: 5)
         #expect(terminals.nextPaneNumber == 41)
@@ -144,7 +145,7 @@ struct GridStoreTests {
         var changes = 0
         terminals.onChange = { changes += 1 }
 
-        let tab = terminals.openTab(for: Fixture.context(dir.path))
+        let tab = terminals.openTab(for: Fixture.context(dir.path)).tab
         terminals.renameTab(tab.id, inRow: dir.path, to: "Build")
         terminals.closeTab(tab.id, inRow: dir.path)
 
```

`Tests/CanopyCoreTests/PaneAgentStateTests.swift`, changed:

```diff
@@ -9,7 +9,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         var changes: [AgentChange] = []
         pane.onAgentChange = { _, change in changes.append(change) }
@@ -35,7 +35,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         _ = pane.report(AgentReport(state: .working))
@@ -56,7 +56,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         // `canopy term send <pane> 1 --enter` picks an option: the text alone leaves the prompt, and Return answers it.
@@ -76,7 +76,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         // cat runs until Control-D, so the test decides when the program exits.
@@ -103,7 +103,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         pane.report(AgentReport(state: .done))
 
         pane.screen.type("\u{1b}[I")
@@ -117,7 +117,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         // The window is hidden, so nothing refreshes while the program runs.
@@ -135,7 +135,7 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         _ = pane.report(AgentReport(state: .waiting))
@@ -147,12 +147,12 @@ struct PaneAgentStateTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let exiting = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let exiting = terminals.openTab(for: Fixture.context(dir.path)).pane
         _ = exiting.report(AgentReport(state: .done))
         await exiting.run("exit 0")
         #expect(await eventually { exiting.agent.state == .none })
 
-        let closing = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })
+        let closing = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })!
         _ = closing.report(AgentReport(state: .working))
         var order: [String] = []
         closing.onClose = { _ in order.append("closed") }
```

`Tests/CanopyCoreTests/PaneTests.swift`, changed:

```diff
@@ -12,7 +12,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(row)).focused
+        let pane = terminals.openTab(for: Fixture.context(row)).pane
         await pane.run(#"printf 'ready:%s:%s:%s\n' "$CANOPY_PANE" "$CANOPY_ROW" "$(pwd -P)""#)
 
         #expect(await eventually { pane.screen.text.contains("ready:p1:feat/x:\(row)") })
@@ -23,7 +23,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         await pane.run(#"printf '%s|%s\n' "it's" "héllo ✓ $CANOPY_ROW""#)
 
         #expect(await eventually { pane.screen.text.contains("it's|héllo ✓ feat/x") })
@@ -33,7 +33,7 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         let firstShell = try #require(pane.pid)
 
         #expect(await eventually { pane.foreground?.name == "bash" })
@@ -57,7 +57,7 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         pane.screen.onTitle?("my title")
@@ -77,7 +77,7 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         terminals.refreshActivity()
@@ -102,7 +102,7 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 0.5")).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 0.5")).pane
 
         terminals.refreshActivity()
         #expect(pane.isRunningProgram)
@@ -114,7 +114,7 @@ struct PaneTests {
     @Test func closingEndsTheProcessAndWakesWaiters() async throws {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 30")).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 30")).pane
         let group = try #require(pane.pid)
         let waiter = Task { await pane.waitForExit() }
         try await Task.sleep(for: .milliseconds(100))
@@ -130,7 +130,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("echo working; exit 4")).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("echo working; exit 4")).pane
 
         #expect(await pane.waitForExit() == 4)
         #expect(pane.screen.text.contains("working"))
@@ -142,7 +142,7 @@ struct PaneTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.sub("gone"))).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.sub("gone"))).pane
         await pane.run(#"echo "at:$(pwd -P)""#)
 
         #expect(await eventually { pane.screen.text.contains("at:\(dir.sub("user-home"))") })
```

`Tests/CanopyCoreTests/PluginTerminalTests.swift`, changed:

```diff
@@ -18,7 +18,7 @@ struct PluginTerminalTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).focused
+        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).pane
         await pane.run(
             #"printf 'ready:%s:%s:%s:%s\n' "$CANOPY_PLUGIN" "$CANOPY_ITEM" "${CANOPY_REPO-unset}" "$(pwd -P)""#)
 
@@ -31,7 +31,7 @@ struct PluginTerminalTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).focused
+        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).pane
         pane.report(AgentReport(state: .working))
         terminals.closePane(pane.id)
 
```

`Tests/CanopyCoreTests/RowSetupTests.swift`, changed:

```diff
@@ -60,7 +60,7 @@ struct RowSetupTests {
         let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/split").row
         let task = rows.prepare(row, repoName: "demo", setup: true, run: nil)
 
-        let extra = rows.terminals.addPane(for: PaneContext(row: row, repoName: "demo"), fits: { _ in true })
+        let extra = rows.terminals.addPane(for: PaneContext(row: row, repoName: "demo"), fits: { _ in true })!
         #expect(await task.value.setup.status == .succeeded)
 
         #expect(extra.status == .running)
@@ -97,7 +97,7 @@ struct RowSetupTests {
 
         let pane = try #require(ready.pane)
         #expect(await eventually { read(dir.sub("ran")) == "\(pane)\n" })
-        #expect(rows.terminals.tabs(inRow: row.path).map(\.focused.id) == [pane])
+        #expect(rows.terminals.tabs(inRow: row.path).map(\.focused?.id) == [pane])
     }
 
     @Test func runStartsAtOnceWithoutSetupCommands() async throws {
@@ -111,7 +111,7 @@ struct RowSetupTests {
         #expect(rows.terminals.tabs(inRow: row.path).count == 1)
         let ready = await task.value
         #expect(ready.setup.status == .none)
-        #expect(ready.pane == rows.terminals.tabs(inRow: row.path).first?.focused.id)
+        #expect(ready.pane == rows.terminals.tabs(inRow: row.path).first?.focused?.id)
     }
 
     @Test func setupCanBeSkipped() async throws {
@@ -187,7 +187,7 @@ struct RowSetupTests {
         let config = #"{"teardown": ["echo \"$CANOPY_ROW\" > \"$CANOPY_ROOT_PATH/../teardown.out\""]}"#
         let (repo, rows) = try await setUp(dir, config: config)
         let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/done").row
-        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).focused.pid)
+        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).pane.pid)
 
         try await rows.remove(row, repoName: "demo", force: false, deleteBranch: false)
 
@@ -247,7 +247,7 @@ struct RowSetupTests {
         let dir = try TempDir()
         let (repo, rows) = try await setUp(dir, config: nil)
         let row = try await rows.workspace.createRow(repoPath: repo, branch: "feat/x").row
-        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).focused.pid)
+        let shell = try #require(rows.terminals.openTab(for: PaneContext(row: row, repoName: "demo")).pane.pid)
 
         try await rows.removeRepo(path: repo)
 
@@ -261,13 +261,13 @@ struct RowSetupTests {
         let (repo, rows) = try await setUp(dir, config: nil)
         defer { rows.terminals.closeAll() }
         let main = try #require(await rows.workspace.snapshot.repos.first?.rows.first)
-        let pane = rows.terminals.openTab(for: PaneContext(row: main, repoName: "demo")).focused
+        let pane = rows.terminals.openTab(for: PaneContext(row: main, repoName: "demo")).pane
         #expect(await eventually { pane.foreground?.name == "bash" })
         try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
 
         try await rows.relocateRepo(path: repo, to: dir.sub("moved"))
 
-        #expect(rows.terminals.tabs(inRow: dir.sub("moved")).map(\.focused.id) == [pane.id])
+        #expect(rows.terminals.tabs(inRow: dir.sub("moved")).map(\.focused?.id) == [pane.id])
         #expect(pane.context.rowPath == dir.sub("moved"))
         #expect(pane.status == .running)
     }
```

`Tests/CanopyCoreTests/TermSendTests.swift`, changed:

```diff
@@ -31,7 +31,7 @@ struct TermSendTests {
         let rows = RowLifecycle(
             workspace: Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git), terminals: terminals)
         let command = ReadRecorder.command(try ReadRecorder.install(in: dir), paste: paste)
-        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(command)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(command)).pane
         // A loaded machine can take seconds to schedule the recorder, and Return must still wait for it.
         pane.returnPatience = .seconds(60)
         #expect(await eventually { pane.screen.text.contains("ready") })
```

`Tests/CanopyCoreTests/TerminalActivityTests.swift`, changed:

```diff
@@ -16,7 +16,7 @@ struct TerminalActivityTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         await pane.run("exit 3")
         #expect(await eventually { pane.status == .exited(3) })
 
@@ -32,7 +32,7 @@ struct TerminalActivityTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = ActivitySource.$current.withValue(.cli) { terminals.openTab(for: Fixture.context(dir.path)).focused }
+        let pane = ActivitySource.$current.withValue(.cli) { terminals.openTab(for: Fixture.context(dir.path)).pane }
         ActivitySource.$current.withValue(.cli) { terminals.closePane(pane.id) }
 
         let events = await logged(terminals, "term")
@@ -46,7 +46,7 @@ struct TerminalActivityTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
         await pane.run("exit 0")
         #expect(await eventually { pane.status == .exited(0) })
         pane.screen.type("\r")
@@ -58,7 +58,7 @@ struct TerminalActivityTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         // The row's checkout moved to another branch, and a second repo with the same folder name was added.
         let row = Row(repoPath: "/r/demo", path: dir.path, branch: "feat/y", head: nil, rowClass: .canopy)
```

`Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`, changed:

```diff
@@ -24,12 +24,12 @@ struct TerminalStoreAgentTests {
                 try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
             }
             terminals = Fixture.terminals(dir)
-            firstTab = terminals.openTab(for: Fixture.context(a))
-            beside = terminals.addPane(for: Fixture.context(a), fits: { _ in true })
+            firstTab = terminals.openTab(for: Fixture.context(a)).tab
+            beside = terminals.addPane(for: Fixture.context(a), fits: { _ in true })!
             focused = firstTab.paneList[0]
             terminals.focus(focused.id)
-            otherTab = terminals.openTab(for: Fixture.context(a), select: false).focused
-            otherRow = terminals.openTab(for: Fixture.context(b)).focused
+            otherTab = terminals.openTab(for: Fixture.context(a), select: false).pane
+            otherRow = terminals.openTab(for: Fixture.context(b)).pane
         }
     }
 
```

`Tests/CanopyCoreTests/TerminalStoreTests.swift`, changed:

```diff
@@ -32,13 +32,13 @@ struct TerminalStoreTests {
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
 
-        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }
+        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }
         terminals.closeTab(tabs[0].id, inRow: dir.path)
         terminals.openTab(for: context)
 
         #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal 2", "Terminal 3", "Terminal"])
         #expect(Set(terminals.panes.map(\.id)).count == 3)
-        #expect(terminals.pane(tabs[1].focused.id) === tabs[1].focused)
+        #expect(terminals.pane(try #require(tabs[1].focused).id) === tabs[1].focused)
     }
 
     @Test func closingTheSelectedTabSelectsItsRightNeighbor() throws {
@@ -46,7 +46,7 @@ struct TerminalStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }
+        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }
 
         terminals.selectTab(tabs[1].id, inRow: dir.path)
         terminals.closeTab(tabs[1].id, inRow: dir.path)
@@ -55,7 +55,7 @@ struct TerminalStoreTests {
         terminals.closeTab(tabs[2].id, inRow: dir.path)
         #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)
 
-        terminals.closePane(tabs[0].focused.id)
+        terminals.closePane(try #require(tabs[0].focused).id)
         #expect(terminals.tabs(inRow: dir.path).isEmpty)
         #expect(terminals.selectedTab(inRow: dir.path) == nil)
     }
@@ -65,7 +65,7 @@ struct TerminalStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }
+        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }
 
         terminals.selectTab(tabs[2].id, inRow: dir.path)
         terminals.closeTab(tabs[0].id, inRow: dir.path)
@@ -78,7 +78,7 @@ struct TerminalStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let context = Fixture.context(dir.path)
-        let tabs = (0..<3).map { _ in terminals.openTab(for: context) }
+        let tabs = (0..<3).map { _ in terminals.openTab(for: context).tab }
 
         terminals.selectTab(offset: 1, inRow: dir.path)
         #expect(terminals.selectedTab(inRow: dir.path)?.id == tabs[0].id)
@@ -90,7 +90,7 @@ struct TerminalStoreTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let tab = terminals.openTab(for: Fixture.context(dir.path))
+        let tab = terminals.openTab(for: Fixture.context(dir.path)).tab
 
         terminals.renameTab(tab.id, inRow: dir.path, to: "  Server ")
         terminals.renameTab(tab.id, inRow: dir.path, to: "   ")
@@ -105,10 +105,10 @@ struct TerminalStoreTests {
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
         let groups = [
-            terminals.openTab(for: Fixture.context(dir.path)).focused.pid,
-            terminals.openTab(for: Fixture.context(dir.path)).focused.pid,
+            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
+            terminals.openTab(for: Fixture.context(dir.path)).pane.pid,
         ].compactMap { $0 }
-        let kept = terminals.openTab(for: Fixture.context(other)).focused
+        let kept = terminals.openTab(for: Fixture.context(other)).pane
 
         terminals.closeRow(path: dir.path)
 
@@ -121,8 +121,8 @@ struct TerminalStoreTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let idle = terminals.openTab(for: Fixture.context(dir.path)).focused
-        let busy = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let idle = terminals.openTab(for: Fixture.context(dir.path)).pane
+        let busy = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         await busy.run("sleep 30")
 
@@ -162,12 +162,12 @@ struct TerminalStoreTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let main = terminals.openTab(for: Fixture.context("/old/demo", repoPath: "/old/demo")).focused
-        let elsewhere = terminals.openTab(for: Fixture.context(dir.sub("wt"), repoPath: "/old/demo")).focused
+        let main = terminals.openTab(for: Fixture.context("/old/demo", repoPath: "/old/demo")).pane
+        let elsewhere = terminals.openTab(for: Fixture.context(dir.sub("wt"), repoPath: "/old/demo")).pane
 
         terminals.moveRows(ofRepo: "/old/demo", to: "/new/demo")
 
-        #expect(terminals.tabs(inRow: "/new/demo").map(\.focused.id) == [main.id])
+        #expect(terminals.tabs(inRow: "/new/demo").map(\.focused?.id) == [main.id])
         #expect(terminals.tabs(inRow: "/old/demo").isEmpty)
         #expect(main.context.rowPath == "/new/demo")
         #expect(elsewhere.context.rowPath == dir.sub("wt"))
@@ -183,7 +183,7 @@ struct TerminalStoreTests {
         defer { terminals.closeAll() }
         terminals.preferredSize = TerminalSize(columns: 150, rows: 45)
 
-        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
 
         #expect(pane.emulator.size == TerminalSize(columns: 150, rows: 45))
     }
```

`Tests/CanopyCoreTests/WebPageOpenTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct WebPageOpenTests {
    let artifact = URL(string: "https://claude.ai/artifact/a1")!
    let other = URL(string: "http://localhost:5173/")!

    @Test func aNewPageOpensInThePanelAtFirst() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let tab = terminals.openTab(for: Fixture.context(dir.path)).tab

        let opened = terminals.openPage(artifact, for: Fixture.context(dir.path))

        #expect(opened.placement == .panel && opened.isNew)
        #expect(opened.page.id.description == "w1")
        #expect(terminals.shownPanel(inRow: dir.path) === opened.page)
        #expect(terminals.tabs(inRow: dir.path).map(\.id) == [tab.id])
    }

    @Test func aNewPageReplacesThePanelsPage() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        var closed: [WebPageID] = []
        terminals.onPageClosed = { closed.append($0) }

        let first = terminals.openPage(artifact, for: Fixture.context(dir.path)).page
        let second = terminals.openPage(other, for: Fixture.context(dir.path)).page

        #expect(terminals.shownPanel(inRow: dir.path) === second)
        #expect(closed == [first.id])
    }

    @Test func tabPlacementOpensAWebTabAfterTheSelectedOne() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let tabs = (0..<2).map { _ in terminals.openTab(for: context).tab }
        terminals.selectTab(tabs[0].id, inRow: dir.path)
        terminals.webPlacement = .tab

        let opened = terminals.openPage(artifact, for: context)

        let row = terminals.tabs(inRow: dir.path)
        #expect(opened.placement == .tab)
        #expect(row.map(\.id) == [tabs[0].id, row[1].id, tabs[1].id])
        #expect(row[1].page === opened.page)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == row[1].id)
        #expect(terminals.panel(inRow: dir.path) == nil)
    }

    @Test func aPlacementAskedForDoesNotChangeTheRememberedOne() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)

        let opened = terminals.openPage(artifact, for: Fixture.context(dir.path), placement: .tab)

        #expect(opened.placement == .tab)
        #expect(terminals.webPlacement == .panel)
        #expect(terminals.openPage(other, for: Fixture.context(dir.path)).placement == .panel)
    }

    @Test func aPageTheRowShowsAlreadyIsShownWhereItIs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        let terminal = terminals.openTab(for: context).tab
        terminals.setPanelHidden(true, inRow: dir.path)

        let again = terminals.openPage(artifact, for: context, placement: .tab)
        #expect(again.page === inPanel && again.placement == .panel && !again.isNew)
        #expect(terminals.shownPanel(inRow: dir.path) === inPanel)

        #expect(terminals.selectedTab(inRow: dir.path)?.id == terminal.id)
        let tabAgain = terminals.openPage(other, for: context)
        #expect(tabAgain.page === inTab && tabAgain.placement == .tab && !tabAgain.isNew)
        #expect(terminals.selectedTab(inRow: dir.path)?.page === inTab)
        #expect(terminals.tabs(inRow: dir.path).count == 2)
    }

    @Test func pagesInOtherRowsAreTheirOwn() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)

        let here = terminals.openPage(artifact, for: Fixture.context(dir.sub("a"))).page
        let there = terminals.openPage(artifact, for: Fixture.context(dir.sub("b"))).page

        #expect(here !== there)
        #expect(there.id.description == "w2")
    }

    @Test func pageNumbersContinueFromWhereTheyLeftOff() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)

        terminals.continueWebNumbering(from: 7)
        terminals.continueWebNumbering(from: 3)

        #expect(terminals.openPage(artifact, for: Fixture.context(dir.path)).page.id == WebPageID(7))
        #expect(terminals.nextWebPageNumber == 8)
        #expect(WebPageID("w7") == WebPageID(7))
        #expect(WebPageID("p7") == nil && WebPageID("w0") == nil)
    }

    @Test func aWebTabIsNamedAfterItsPageAndKeepsItsName() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path), placement: .tab).page
        let tab = try #require(terminals.selectedTab(inRow: dir.path))

        #expect(tab.name == "claude.ai")
        page.title = "Launch plan"
        terminals.renameTab(tab.id, inRow: dir.path, to: "Mine")
        #expect(tab.name == "Launch plan")
        #expect(tab.paneList.isEmpty && tab.focused == nil)
    }

    @Test func terminalsNeverJoinAWebTab() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        terminals.openTab(for: context)
        let web = terminals.openPage(artifact, for: context, placement: .tab).page

        #expect(terminals.addPane(for: context, fits: { _ in true }) == nil)
        let (tab, _) = terminals.openTerminal(for: context, tabNamed: nil, newTab: false)

        #expect(tab.grid != nil)
        #expect(terminals.tabs(inRow: dir.path).map(\.name) == ["Terminal", "claude.ai", "Terminal 2"])
        #expect(terminals.selectedTab(inRow: dir.path)?.page === web)
    }

    @Test func openingIsLoggedWithWhereItOpened() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)

        ActivitySource.$current.withValue(.cli) {
            _ = terminals.openPage(artifact, for: Fixture.context(dir.path))
        }
        terminals.openPage(other, for: Fixture.context(dir.path), placement: .tab)
        terminals.openPage(other, for: Fixture.context(dir.path))

        let events = await logged(terminals, "web")
        #expect(events.map(\.type) == ["web.opened", "web.opened"])
        #expect(
            events.map(\.data) == [
                ["page": "w1", "placement": "panel", "url": "https://claude.ai/artifact/a1"],
                ["page": "w2", "placement": "tab", "url": "http://localhost:5173/"],
            ])
        #expect(events.map(\.source) == [.cli, .ui])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.row == "feat/x" && $0.path == dir.path })
    }
}
```

`Tests/CanopyTicketsTests/Support/TicketsHarness.swift`, changed:

```diff
@@ -143,7 +143,7 @@ final class TicketsHarness {
 
     /// Runs `sleep 30` in a new tab of the row, and returns once the pane counts as busy.
     func runBusyProgram(in row: PluginRow) async {
-        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).focused
+        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).pane
         await pane.run("sleep 30")
         _ = await eventually { pane.isBusy }
     }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: cannot find 'WebPageID' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyApp/AppModel.swift`, changed:

```diff
@@ -806,8 +806,8 @@ final class AppModel {
         }
     }
 
-    func resize(_ tab: TerminalTab, divider: DividerID, to position: Double, in rect: CGRect) {
-        terminals.resize(tab, divider: divider, to: position, in: rect, minimum: minimumPaneSize)
+    func resize(_ grid: TerminalGrid, divider: DividerID, to position: Double, in rect: CGRect) {
+        terminals.resize(grid, divider: divider, to: position, in: rect, minimum: minimumPaneSize)
     }
 
     /// The pane being dragged by its header, so drops only react to Canopy's own pane drags.
@@ -891,7 +891,7 @@ final class AppModel {
 
     /// Hands the keyboard back to the terminal on screen, as after renaming a tab.
     func focusSelectedTerminal() {
-        (selectedTab?.focused.emulator as? SwiftTermEmulator)?.focus()
+        (selectedTab?.focused?.emulator as? SwiftTermEmulator)?.focus()
     }
 
     func selectTab(offset: Int) {
```

`Sources/CanopyApp/Terminal/GridView.swift`, changed:

```diff
@@ -2,23 +2,23 @@ import CanopyCore
 import SwiftUI
 import UniformTypeIdentifiers
 
-/// A tab's panes, placed by its layout. Dividers resize, and a pane's header drags it onto another pane.
+/// A terminal tab's panes, placed by its layout. Dividers resize, and a pane's header drags it onto another pane.
 struct GridView: View {
     @Environment(AppModel.self) private var model
-    let tab: TerminalTab
+    let grid: TerminalGrid
     @State private var hover: DropHover?
 
     var body: some View {
         GeometryReader { geometry in
             let rect = CGRect(origin: .zero, size: geometry.size)
-            let frames = tab.layout.frames(in: rect)
+            let frames = grid.layout.frames(in: rect)
             ZStack(alignment: .topLeading) {
                 // Keyed by pane, so a terminal is never rebuilt when the layout around it changes.
-                ForEach(tab.layout.leaves, id: \.self) { id in
-                    if let pane = tab.panes[id], let frame = frames[id] {
+                ForEach(grid.layout.leaves, id: \.self) { id in
+                    if let pane = grid.panes[id], let frame = frames[id] {
                         PaneView(
                             pane: pane,
-                            isFocusedPane: tab.focusedPaneID == id && !model.sidebarKeepsKeyboard,
+                            isFocusedPane: grid.focusedPaneID == id && !model.sidebarKeepsKeyboard,
                             onClose: { model.requestClose(pane) },
                             onFocus: { model.terminals.focus(id) },
                             onDragStart: { model.draggedPane = id },
@@ -33,9 +33,9 @@ struct GridView: View {
                         .offset(x: frame.minX, y: frame.minY)
                     }
                 }
-                ForEach(tab.layout.dividers(in: rect), id: \.id) { divider in
+                ForEach(grid.layout.dividers(in: rect), id: \.id) { divider in
                     DividerHandle(divider: divider) { position in
-                        model.resize(tab, divider: divider.id, to: position, in: rect)
+                        model.resize(grid, divider: divider.id, to: position, in: rect)
                     }
                 }
             }
```

`Sources/CanopyApp/Terminal/RowTerminalsView.swift`, changed:

```diff
@@ -36,8 +36,12 @@ struct TerminalArea: View {
         VStack(spacing: 0) {
             Color.clear.frame(height: Style.topBarHeight)
             if let tab = model.terminals.selectedTab(inRow: path) {
-                GridView(tab: tab)
-                    .id(tab.id)
+                if let grid = tab.grid {
+                    GridView(grid: grid)
+                        .id(tab.id)
+                } else {
+                    Spacer()
+                }
             } else {
                 ContentUnavailableView {
                     Label("No Terminals", systemImage: "apple.terminal")
```

`Sources/CanopyApp/Terminal/TopBarView.swift`, changed:

```diff
@@ -129,7 +129,7 @@ struct TabItemView: View {
 
     var body: some View {
         HStack(spacing: 6) {
-            Image(systemName: tab.layout.shape.symbolName)
+            Image(systemName: tab.grid?.layout.shape.symbolName ?? "globe")
                 .font(.system(size: 12))
                 .frame(width: 14)
             if isRenaming {
```

`Sources/CanopyCore/Activity/ActivityEvent.swift`, changed:

```diff
@@ -30,6 +30,8 @@ public enum ActivityType {
     public static let termExited = "term.exited"
     public static let termCommand = "term.command"
     public static let cliCall = "cli.call"
+    public static let webOpened = "web.opened"
+    public static let webClosed = "web.closed"
     public static let pluginEnabled = "plugin.enabled"
     public static let pluginDisabled = "plugin.disabled"
     public static let pluginRowCreated = "plugin.row.created"
```

`Sources/CanopyCore/Activity/ActivityReader.swift`, changed:

```diff
@@ -165,6 +165,10 @@ extension ActivityEvent {
             let took = number("durationMs").map { " in \(Self.duration(milliseconds: $0))" } ?? ""
             let command = (text("cmd") ?? "").replacingOccurrences(of: "\n", with: " \u{21b5} ")
             return "\(pane) exit \(number("exit") ?? 0)\(took): \(command)"
+        case ActivityType.webOpened:
+            return "\(text("page") ?? "") \(text("placement") ?? ""): \(text("url") ?? "")"
+        case ActivityType.webClosed:
+            return "\(text("page") ?? ""): \(text("url") ?? "")"
         case ActivityType.cliCall:
             var params = data["params"]
             if case .object(var fields) = params {
```

`Sources/CanopyCore/Plugins/PluginHost.swift`, changed:

```diff
@@ -320,7 +320,7 @@ public final class PluginHost {
         // The terminal opens first, so selecting the row does not also give it a blank one. A plugin turned off while
         // the row was made gets no terminal in it.
         let pane = run.flatMap { _ in
-            fillError == nil && on.contains(id) ? terminals.openTab(for: PaneContext(pluginRow: row)).focused : nil
+            fillError == nil && on.contains(id) ? terminals.openTab(for: PaneContext(pluginRow: row)).pane : nil
         }
         if select {
             await self.select(row.path)
```

`Sources/CanopyCore/Rows/RowLifecycle.swift`, changed:

```diff
@@ -59,7 +59,7 @@ public final class RowLifecycle {
         }
 
         guard !commands.isEmpty else {
-            let pane = run.map { _ in terminals.openTab(for: context).focused }
+            let pane = run.map { _ in terminals.openTab(for: context).pane }
             let report = SetupReport(status: setup ? .none : .skipped)
             return Task {
                 if let pane, let run { await pane.run(run) }
@@ -69,7 +69,7 @@ public final class RowLifecycle {
 
         let script = SetupScript.render(commands, label: "Setup")
         // The setup pane, not its tab: the user may split the Setup tab while setup runs.
-        let setupPane = terminals.openTab(for: context, name: "Setup", command: .script(script)).focused
+        let setupPane = terminals.openTab(for: context, name: "Setup", command: .script(script)).pane
         return Task {
             let code = await setupPane.waitForExit()
             guard code == 0 else {
@@ -82,7 +82,7 @@ public final class RowLifecycle {
             }
             var pane: Pane?
             if run != nil {
-                pane = terminals.openTab(for: context).focused
+                pane = terminals.openTab(for: context).pane
             } else if terminals.tabs(inRow: row.path).count == 1,
                 terminals.tab(containing: setupPane.id)?.1.paneList.count == 1
             {
@@ -149,7 +149,7 @@ public final class RowLifecycle {
         let script = SetupScript.render(commands, label: "Teardown")
         let teardownPane = terminals.openTab(
             for: PaneContext(row: row, repoName: repoName), name: "Teardown", command: .script(script)
-        ).focused
+        ).pane
         let code = await teardownPane.waitForExit()
         guard code != 0, !force else { return }
         let closed = terminals.tab(containing: teardownPane.id) == nil
```

`Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`, changed:

```diff
@@ -67,7 +67,7 @@ extension TerminalStore {
 
     /// Whether the pane on screen is the one the author is focused on.
     public func isFocused(_ pane: Pane) -> Bool {
-        isOnScreen(pane) && tab(containing: pane.id)?.1.focusedPaneID == pane.id
+        isOnScreen(pane) && tab(containing: pane.id)?.1.grid?.focusedPaneID == pane.id
     }
 
     /// Clears the green of every pane the author now sees.
```

`Sources/CanopyCore/Terminal/TerminalStore+Web.swift`, new:

```swift
import Foundation

/// Web pages in rows: one in each row's panel, and any number in tabs of their own.
extension TerminalStore {
    /// The number the next page gets, saved so IDs keep counting up across launches.
    public var nextWebPageNumber: Int { nextWebPage }

    public func continueWebNumbering(from number: Int) {
        nextWebPage = max(nextWebPage, number)
    }

    public func panel(inRow path: String) -> WebPanel? {
        panelsByRow[path]
    }

    /// The row's panel page while the panel shows.
    public func shownPanel(inRow path: String) -> WebPage? {
        panelsByRow[path].flatMap { $0.isHidden ? nil : $0.page }
    }

    /// Shows `url` in the row. A page the row already shows is shown where it is. Otherwise it opens in the panel,
    /// replacing the panel's page, or in a new tab after the selected one, by `placement` or else where the author
    /// last moved a page. Either way the row's panel shows, or the page's tab is selected.
    @discardableResult
    public func openPage(_ url: URL, for context: PaneContext, placement: WebPlacement? = nil) -> OpenedPage {
        let path = context.rowPath
        if let panel = panelsByRow[path], panel.page.url == url {
            setPanelHidden(false, inRow: path)
            return OpenedPage(page: panel.page, placement: .panel, isNew: false)
        }
        if let tab = tabs(inRow: path).first(where: { $0.page?.url == url }), let page = tab.page {
            selectTab(tab.id, inRow: path)
            return OpenedPage(page: page, placement: .tab, isNew: false)
        }
        let page = WebPage(id: WebPageID(nextWebPage), url: url, title: "", context: context)
        nextWebPage += 1
        let placement = placement ?? webPlacement
        switch placement {
        case .panel:
            let replaced = panelsByRow[path]?.page
            panelsByRow[path] = WebPanel(page: page, isHidden: false)
            replaced.map(retire)
        case .tab:
            insertTab(for: page, inRow: path)
        }
        record(ActivityType.webOpened, page, ["placement": .string(placement.rawValue)])
        onChange()
        return OpenedPage(page: page, placement: placement, isNew: true)
    }

    public func setPanelHidden(_ hidden: Bool, inRow path: String) {
        guard panelsByRow[path] != nil, panelsByRow[path]?.isHidden != hidden else { return }
        panelsByRow[path]?.isHidden = hidden
        onChange()
    }

    /// A new web tab after the row's selected tab, selected.
    func insertTab(for page: WebPage, inRow path: String, at index: Int? = nil) {
        var tabs = tabs(inRow: path)
        let selected = selectedTab(inRow: path).flatMap { selected in tabs.firstIndex { $0.id == selected.id } }
        let tab = TerminalTab(id: TabID(nextTab), page: page)
        nextTab += 1
        tabs.insert(tab, at: min(index ?? selected.map { $0 + 1 } ?? tabs.count, tabs.count))
        tabsByRow[path] = tabs
        selectedTabByRow[path] = tab.id
        markSeenOnScreen()
    }

    /// Logs a page that closed and lets the app drop its web view.
    func retire(_ page: WebPage) {
        record(ActivityType.webClosed, page)
        onPageClosed(page.id)
    }

    func record(_ type: String, _ page: WebPage, _ data: [String: JSONValue] = [:]) {
        var data = data.merging(["url": .string(page.url.absoluteString), "page": .string(page.id.description)]) {
            value, _ in value
        }
        if case .plugin(let plugin, let item) = page.context.owner {
            data["plugin"] = .string(plugin)
            data["item"] = .string(item)
        }
        activity.record(
            type, repo: page.context.repoName, row: page.context.rowName, path: page.context.rowPath, data: data)
    }
}
```

`Sources/CanopyCore/Terminal/TerminalStore.swift`, changed:

```diff
@@ -2,21 +2,22 @@ import CoreGraphics
 import Foundation
 import Observation
 
+/// A terminal tab's panes: their layout, and the one with focus.
 @MainActor
 @Observable
-public final class TerminalTab: Identifiable {
-    public let id: TabID
-    public internal(set) var name: String
+public final class TerminalGrid {
     public internal(set) var layout: Layout<PaneID>
     public internal(set) var panes: [PaneID: Pane]
     public internal(set) var focusedPaneID: PaneID
 
-    init(id: TabID, name: String, pane: Pane) {
-        self.id = id
-        self.name = name
-        self.layout = .leaf(pane.id)
-        self.panes = [pane.id: pane]
-        self.focusedPaneID = pane.id
+    init(layout: Layout<PaneID>, panes: [Pane], focusedPaneID: PaneID) {
+        self.layout = layout
+        self.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
+        self.focusedPaneID = focusedPaneID
+    }
+
+    convenience init(pane: Pane) {
+        self.init(layout: .leaf(pane.id), panes: [pane], focusedPaneID: pane.id)
     }
 
     /// Panes in layout order: left to right, then top to bottom.
@@ -28,10 +29,58 @@ public final class TerminalTab: Identifiable {
     public var focused: Pane {
         panes[focusedPaneID] ?? paneList[0]
     }
+}
+
+/// A tab in a row's tab bar: terminals, or one web page.
+@MainActor
+@Observable
+public final class TerminalTab: Identifiable {
+    public enum Content {
+        case terminals(TerminalGrid)
+        case web(WebPage)
+    }
+
+    public let id: TabID
+    public let content: Content
+    /// A terminal tab's name. A web tab is named after its page.
+    var terminalName: String
+
+    init(id: TabID, name: String, grid: TerminalGrid) {
+        self.id = id
+        self.terminalName = name
+        self.content = .terminals(grid)
+    }
+
+    init(id: TabID, page: WebPage) {
+        self.id = id
+        self.terminalName = ""
+        self.content = .web(page)
+    }
+
+    public var name: String {
+        page?.displayTitle ?? terminalName
+    }
+
+    public var grid: TerminalGrid? {
+        if case .terminals(let grid) = content { grid } else { nil }
+    }
+
+    public var page: WebPage? {
+        if case .web(let page) = content { page } else { nil }
+    }
+
+    /// Panes in layout order, none for a web tab.
+    public var paneList: [Pane] {
+        grid?.paneList ?? []
+    }
+
+    public var focused: Pane? {
+        grid?.focused
+    }
 
     /// Nil for a plugin row's tab.
     var repoPath: String? {
-        paneList.first?.context.repoPath
+        paneList.first?.context.repoPath ?? page?.context.repoPath
     }
 }
 
@@ -40,8 +89,16 @@ public final class TerminalTab: Identifiable {
 @Observable
 public final class TerminalStore {
     /// Each row's tabs in tab bar order, keyed by row path.
-    public private(set) var tabsByRow: [String: [TerminalTab]] = [:]
-    private var selectedTabByRow: [String: TabID] = [:]
+    public internal(set) var tabsByRow: [String: [TerminalTab]] = [:]
+    var selectedTabByRow: [String: TabID] = [:]
+    /// Each row's panel page, keyed by row path.
+    public internal(set) var panelsByRow: [String: WebPanel] = [:]
+    /// Where a new page opens: where the author last moved one.
+    public var webPlacement = WebPlacement.panel {
+        didSet {
+            if webPlacement != oldValue { onChange() }
+        }
+    }
     /// The size new terminals start at, so one opened in the background already fits the window.
     public var preferredSize = TerminalSize.standard
     /// Called after any change worth saving: tabs, names, layouts, focus, or selection.
@@ -53,7 +110,8 @@ public final class TerminalStore {
     @ObservationIgnored public let activity: ActivityLog
     @ObservationIgnored private let engine: any TerminalEngine
     @ObservationIgnored private var nextPane = 1
-    @ObservationIgnored private var nextTab = 1
+    @ObservationIgnored var nextTab = 1
+    @ObservationIgnored var nextWebPage = 1
     /// Rows seen in a snapshot while they had terminals, so a row created a moment ago is not mistaken for one
     /// that went away.
     @ObservationIgnored private var seenRows: Set<String> = []
@@ -63,6 +121,8 @@ public final class TerminalStore {
     }
     /// Called when a pane's agent finishes or needs the author, unless the author is focused on that pane.
     @ObservationIgnored public var onAgentAlert: (Pane, AgentState) -> Void = { _, _ in }
+    /// Called when a page leaves its row, so the app can drop its web view.
+    @ObservationIgnored public var onPageClosed: (WebPageID) -> Void = { _ in }
     @ObservationIgnored private var agentObservers: [UUID: (AgentEvent) -> Void] = [:]
 
     public init(engine: any TerminalEngine, settings: ShellSettings, activity: ActivityLog? = nil) {
@@ -117,11 +177,12 @@ public final class TerminalStore {
     public func openTab(
         for context: PaneContext, name: String? = nil, command: PaneCommand = .shell, directory: String? = nil,
         select: Bool = true
-    ) -> TerminalTab {
+    ) -> (tab: TerminalTab, pane: Pane) {
         let tabs = tabs(inRow: context.rowPath)
+        let pane = makePane(context, command: command, directory: directory)
         let tab = TerminalTab(
-            id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.map(\.name)),
-            pane: makePane(context, command: command, directory: directory))
+            id: TabID(nextTab), name: name ?? TabNaming.next(after: tabs.filter { $0.grid != nil }.map(\.name)),
+            grid: TerminalGrid(pane: pane))
         nextTab += 1
         tabsByRow[context.rowPath] = tabs + [tab]
         if select || selectedTabByRow[context.rowPath] == nil {
@@ -129,7 +190,7 @@ public final class TerminalStore {
         }
         markSeenOnScreen()
         onChange()
-        return tab
+        return (tab, pane)
     }
 
     /// A row on screen with no tabs gets one. A row whose folder is gone gets none, not a shell somewhere else.
@@ -158,8 +219,10 @@ public final class TerminalStore {
 
     public func renameTab(_ id: TabID, inRow path: String, to name: String) {
         let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
-        guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }) else { return }
-        tab.name = trimmed
+        guard !trimmed.isEmpty, let tab = tabs(inRow: path).first(where: { $0.id == id }), tab.grid != nil else {
+            return
+        }
+        tab.terminalName = trimmed
         onChange()
     }
 
@@ -184,96 +247,97 @@ public final class TerminalStore {
     // MARK: Panes
 
     /// Adds a pane to the row's selected tab by the add rule, where `fits` says whether a line of that many panes
-    /// keeps each one wide enough, and focuses it. Opens a tab if the row has none.
+    /// keeps each one wide enough, and focuses it. Opens a tab if the row has none, and does nothing in a web tab.
     @discardableResult
-    public func addPane(for context: PaneContext, fits: (Int) -> Bool) -> Pane {
+    public func addPane(for context: PaneContext, fits: (Int) -> Bool) -> Pane? {
         guard let tab = selectedTab(inRow: context.rowPath) else {
-            return openTab(for: context).focused
+            return openTab(for: context).pane
         }
-        return addPane(to: tab, for: context, fits: fits)
+        guard let grid = tab.grid else { return nil }
+        return addPane(to: grid, for: context, fits: fits)
     }
 
-    /// Opens a terminal where `canopy term new` asks: in a new tab, in the tab with `name` (opening it if the row
-    /// has none by that name), or in the row's selected tab. It never changes which tab or pane the user is on.
+    /// Opens a terminal where `canopy term new` asks: in a new tab, in the terminal tab with `name` (opening it if
+    /// the row has none by that name), or in the row's selected tab. A web tab selected gets a new tab beside it.
+    /// It never changes which tab or pane the user is on.
     public func openTerminal(for context: PaneContext, tabNamed name: String?, newTab: Bool) -> (TerminalTab, Pane) {
-        let named = name.flatMap { name in tabs(inRow: context.rowPath).first { $0.name == name } }
-        if newTab || (name != nil && named == nil) || selectedTab(inRow: context.rowPath) == nil {
-            let tab = openTab(for: context, name: name, select: false)
-            return (tab, tab.focused)
+        let named = name.flatMap { name in tabs(inRow: context.rowPath).first { $0.grid != nil && $0.name == name } }
+        guard !newTab, name == nil || named != nil, let tab = named ?? selectedTab(inRow: context.rowPath),
+            let grid = tab.grid
+        else {
+            return openTab(for: context, name: name, select: false)
         }
-        let tab = named ?? selectedTab(inRow: context.rowPath)!
-        return (tab, addPane(to: tab, for: context, fits: fits, focus: false))
+        return (tab, addPane(to: grid, for: context, fits: fits, focus: false))
     }
 
     private func addPane(
-        to tab: TerminalTab, for context: PaneContext, fits: (Int) -> Bool, focus: Bool = true
+        to grid: TerminalGrid, for context: PaneContext, fits: (Int) -> Bool, focus: Bool = true
     ) -> Pane {
         let pane = makePane(context, command: .shell, directory: nil)
-        tab.panes[pane.id] = pane
-        tab.layout = tab.layout.adding(pane.id, fits: fits)
-        if focus { tab.focusedPaneID = pane.id }
+        grid.panes[pane.id] = pane
+        grid.layout = grid.layout.adding(pane.id, fits: fits)
+        if focus { grid.focusedPaneID = pane.id }
         onChange()
         return pane
     }
 
     /// Closes a pane and hands its space to its neighbors. Closing a tab's last pane closes the tab.
     public func closePane(_ id: PaneID) {
-        guard let found = tab(containing: id) else { return }
-        let (path, tab) = found
-        guard let layout = tab.layout.removing(id) else {
+        guard let (path, tab) = tab(containing: id), let grid = tab.grid else { return }
+        guard let layout = grid.layout.removing(id) else {
             closeTab(tab.id, inRow: path)
             return
         }
-        if tab.focusedPaneID == id {
+        if grid.focusedPaneID == id {
             // Focus moves to the pane that came before it in layout order, or else the one after.
-            let order = tab.layout.leaves
+            let order = grid.layout.leaves
             let index = order.firstIndex(of: id) ?? 0
-            tab.focusedPaneID = index > 0 ? order[index - 1] : order[index + 1]
+            grid.focusedPaneID = index > 0 ? order[index - 1] : order[index + 1]
         }
-        tab.panes.removeValue(forKey: id)?.close()
-        tab.layout = layout
+        grid.panes.removeValue(forKey: id)?.close()
+        grid.layout = layout
         onChange()
     }
 
     public func focus(_ id: PaneID) {
-        guard let tab = tab(containing: id)?.1, tab.focusedPaneID != id else { return }
-        tab.focusedPaneID = id
+        guard let grid = tab(containing: id)?.1.grid, grid.focusedPaneID != id else { return }
+        grid.focusedPaneID = id
         onChange()
     }
 
     /// Focuses the pane next to the focused one in `direction`, laid out in `rect`. Returns it, if there is one.
     @discardableResult
     public func focusNeighbor(inRow path: String, toward direction: Direction, in rect: CGRect) -> Pane? {
-        guard let tab = selectedTab(inRow: path),
-            let neighbor = tab.layout.neighbor(of: tab.focusedPaneID, toward: direction, in: rect)
+        guard let grid = selectedTab(inRow: path)?.grid,
+            let neighbor = grid.layout.neighbor(of: grid.focusedPaneID, toward: direction, in: rect)
         else { return nil }
         focus(neighbor)
-        return tab.panes[neighbor]
+        return grid.panes[neighbor]
     }
 
     /// Drops `moved` on `target`: on an edge it splits the target 50/50, and in the middle the two swap.
     /// Both must be in the same tab.
     public func movePane(_ moved: PaneID, to zone: DropZone, of target: PaneID) {
-        guard moved != target, let tab = tab(containing: moved)?.1, tab.panes[target] != nil else { return }
+        guard moved != target, let grid = tab(containing: moved)?.1.grid, grid.panes[target] != nil else { return }
         switch zone {
-        case .center: tab.layout = tab.layout.swapping(moved, target)
-        case .edge(let edge): tab.layout = tab.layout.moving(moved, to: edge, of: target)
+        case .center: grid.layout = grid.layout.swapping(moved, target)
+        case .edge(let edge): grid.layout = grid.layout.moving(moved, to: edge, of: target)
         }
         onChange()
     }
 
     public func resize(
-        _ tab: TerminalTab, divider: DividerID, to position: Double, in rect: CGRect, minimum: CGSize
+        _ grid: TerminalGrid, divider: DividerID, to position: Double, in rect: CGRect, minimum: CGSize
     ) {
-        let layout = tab.layout.resizing(divider, to: position, in: rect, minimum: minimum)
-        guard layout != tab.layout else { return }
-        tab.layout = layout
+        let layout = grid.layout.resizing(divider, to: position, in: rect, minimum: minimum)
+        guard layout != grid.layout else { return }
+        grid.layout = layout
         onChange()
     }
 
     public func tab(containing id: PaneID) -> (String, TerminalTab)? {
         for (path, tabs) in tabsByRow {
-            if let tab = tabs.first(where: { $0.panes[id] != nil }) {
+            if let tab = tabs.first(where: { $0.grid?.panes[id] != nil }) {
                 return (path, tab)
             }
         }
@@ -288,6 +352,7 @@ public final class TerminalStore {
         }
         tabsByRow[path] = nil
         selectedTabByRow[path] = nil
+        panelsByRow[path] = nil
         seenRows.remove(path)
         onChange()
     }
@@ -362,18 +427,22 @@ public final class TerminalStore {
     public func saved() -> [String: SavedRowTerminals] {
         var saved: [String: SavedRowTerminals] = [:]
         for (path, tabs) in tabsByRow {
+            let terminalTabs = tabs.filter { $0.grid != nil }
+            guard !terminalTabs.isEmpty else { continue }
             saved[path] = SavedRowTerminals(
-                tabs: tabs.map { tab in
-                    SavedTab(
-                        name: tab.name,
-                        layout: tab.layout.map { id in
-                            let pane = tab.panes[id]
-                            return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
-                        },
-                        focused: tab.layout.leaves.firstIndex(of: tab.focusedPaneID)
-                    )
+                tabs: terminalTabs.compactMap { tab in
+                    tab.grid.map { grid in
+                        SavedTab(
+                            name: tab.name,
+                            layout: grid.layout.map { id in
+                                let pane = grid.panes[id]
+                                return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
+                            },
+                            focused: grid.layout.leaves.firstIndex(of: grid.focusedPaneID)
+                        )
+                    }
                 },
-                selectedTab: tabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0
+                selectedTab: terminalTabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0
             )
         }
         return saved
@@ -384,19 +453,17 @@ public final class TerminalStore {
     public func restore(_ saved: SavedRowTerminals, for context: PaneContext) {
         guard tabs(inRow: context.rowPath).isEmpty, !saved.tabs.isEmpty else { return }
         let tabs = saved.tabs.map { savedTab in
-            let leaves = savedTab.layout.leaves
-            let panes = leaves.map { makePane(context, command: .shell, directory: $0.folder) }
+            let panes = savedTab.layout.leaves.map { makePane(context, command: .shell, directory: $0.folder) }
             var index = 0
             let layout: Layout<PaneID> = savedTab.layout.map { _ in
                 defer { index += 1 }
                 return panes[index].id
             }
-            let tab = TerminalTab(id: TabID(nextTab), name: savedTab.name, pane: panes[0])
+            let focused = savedTab.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
+            let tab = TerminalTab(
+                id: TabID(nextTab), name: savedTab.name,
+                grid: TerminalGrid(layout: layout, panes: panes, focusedPaneID: focused))
             nextTab += 1
-            tab.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
-            tab.layout = layout
-            tab.focusedPaneID =
-                savedTab.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
             return tab
         }
         tabsByRow[context.rowPath] = tabs
```

`Sources/CanopyCore/Web/WebPage.swift`, new:

```swift
import Foundation
import Observation

/// A web page's ID, such as `w3`. `canopy web` names pages by it.
public struct WebPageID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "w\(number)" }

    public init?(_ text: String) {
        guard text.hasPrefix("w"), let number = Int(text.dropFirst()), number > 0 else { return nil }
        self.number = number
    }
}

/// Where a row shows a web page: its panel on the right of the terminals, or a tab of its own.
public enum WebPlacement: String, Codable, Sendable {
    case panel
    case tab
}

/// A web page in a row. The app keeps its web view, which outlives moves between the panel and a tab.
@MainActor
@Observable
public final class WebPage: Identifiable {
    public let id: WebPageID
    /// Where the page is now, which changes as the author follows links within it.
    public internal(set) var url: URL
    /// The page's last title, shown before it has loaded.
    public internal(set) var title: String
    /// The row it belongs to, for the activity log.
    public internal(set) var context: PaneContext

    init(id: WebPageID, url: URL, title: String, context: PaneContext) {
        self.id = id
        self.url = url
        self.title = title
        self.context = context
    }

    /// The title, or the host until the page has one.
    public var displayTitle: String {
        title.isEmpty ? (url.host() ?? url.absoluteString) : title
    }
}

/// A row's panel: one page, shown or hidden.
public struct WebPanel {
    public let page: WebPage
    public var isHidden: Bool
}

/// A page `openPage` showed, and whether it opened just now or was already there.
public struct OpenedPage {
    public let page: WebPage
    public let placement: WebPlacement
    public let isNew: Bool
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "WebPageOpenTests|GridStoreTests|TerminalStoreTests|ActivityReaderTests"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: rows open web pages in their panel or a tab"
```

### Task 3: Moving, hiding, closing, and finding pages

Move to Tab puts the panel's page in a new tab after the selected one, and Move to Panel takes a web tab's page into the panel, turning a page the panel held into a tab in its place.
Each move remembers the placement, so new pages open where the author last moved one.
Closing a panel or a web tab logs `web.closed` and tells the app to drop the web view.
A row that closes, as when it is removed or Canopy quits, drops its pages without logging them, and pages follow their row when its repo moves or its branch changes.
A page also keeps the address it opened with, so ⌘-clicking an artifact again after claude.ai sent the page to its sign-in shows that page rather than a second one.

**Files:**
- Modify: `Sources/CanopyCore/Terminal/TerminalStore+Web.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore.swift`
- Modify: `Sources/CanopyCore/Web/WebPage.swift`
- Create: `Tests/CanopyCoreTests/WebPageMoveTests.swift`
- Modify: `Tests/CanopyCoreTests/WebPageOpenTests.swift`

**Interfaces:**
- Consumes: Task 2's store and page types.
- Produces: `movePanelPageToTab(inRow:)`, `moveTabToPanel(_ id: TabID, inRow:)`, `closePanel(inRow:)`, `closePage(_ id: WebPageID) -> Bool`, `page(_ id:) -> (page, path, placement)?`, `pages(inRow:) -> [(page: WebPage, placement: WebPlacement)]`, `pageNavigated(_ id:url:title:)`; `TerminalStore.rowPaths`, `repoPath(ofRow:)`; `WebPage.openedURL`, `shows(_:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WebPageMoveTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct WebPageMoveTests {
    let artifact = URL(string: "https://claude.ai/artifact/a1")!
    let other = URL(string: "http://localhost:5173/")!

    @Test func movingThePanelsPageToATabKeepsThePageAndRemembersTabs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let terminal = terminals.openTab(for: context).tab
        let page = terminals.openPage(artifact, for: context).page

        terminals.movePanelPageToTab(inRow: dir.path)

        #expect(terminals.panel(inRow: dir.path) == nil)
        #expect(terminals.tabs(inRow: dir.path).map(\.id).first == terminal.id)
        #expect(terminals.selectedTab(inRow: dir.path)?.page === page)
        #expect(terminals.webPlacement == .tab)
        #expect(terminals.openPage(other, for: context).placement == .tab)
    }

    @Test func movingATabToThePanelSelectsItsNeighborAndRemembersThePanel() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let left = terminals.openTab(for: context).tab
        let page = terminals.openPage(artifact, for: context, placement: .tab).page
        let right = terminals.openTab(for: context).tab
        let web = try #require(terminals.tabs(inRow: dir.path).first { $0.page === page })
        terminals.selectTab(web.id, inRow: dir.path)
        terminals.webPlacement = .tab

        terminals.moveTabToPanel(web.id, inRow: dir.path)

        #expect(terminals.shownPanel(inRow: dir.path) === page)
        #expect(terminals.tabs(inRow: dir.path).map(\.id) == [left.id, right.id])
        #expect(terminals.selectedTab(inRow: dir.path)?.id == right.id)
        #expect(terminals.webPlacement == .panel)
    }

    @Test func movingToAPanelHoldingAnotherPageTurnsThatPageIntoATab() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let left = terminals.openTab(for: context).tab
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        let right = terminals.openTab(for: context).tab
        let web = try #require(terminals.tabs(inRow: dir.path).first { $0.page === inTab })
        var closed: [WebPageID] = []
        terminals.onPageClosed = { closed.append($0) }

        terminals.moveTabToPanel(web.id, inRow: dir.path)

        let tabs = terminals.tabs(inRow: dir.path)
        #expect(terminals.shownPanel(inRow: dir.path) === inTab)
        #expect(tabs.count == 3 && tabs[0].id == left.id && tabs[1].page === inPanel && tabs[2].id == right.id)
        #expect(terminals.selectedTab(inRow: dir.path)?.id == right.id)
        #expect(closed.isEmpty)
    }

    @Test func closingPagesLogsThemAndLetsTheAppDropTheirViews() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        var closed: [WebPageID] = []
        terminals.onPageClosed = { closed.append($0) }

        terminals.closePanel(inRow: dir.path)
        let tab = try #require(terminals.selectedTab(inRow: dir.path))
        terminals.closeTab(tab.id, inRow: dir.path)

        #expect(terminals.panel(inRow: dir.path) == nil)
        #expect(terminals.tabs(inRow: dir.path).isEmpty)
        #expect(closed == [inPanel.id, inTab.id])
        let events = await logged(terminals, "web").filter { $0.type == "web.closed" }
        #expect(
            events.map(\.data) == [
                ["page": "w1", "url": "https://claude.ai/artifact/a1"],
                ["page": "w2", "url": "http://localhost:5173/"],
            ])
    }

    @Test func closingAPageByItsIDFindsItInEitherPlace() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let inPanel = terminals.openPage(artifact, for: Fixture.context(dir.sub("a"))).page
        let inTab = terminals.openPage(other, for: Fixture.context(dir.sub("b")), placement: .tab).page

        #expect(terminals.page(inTab.id)?.placement == .tab)
        #expect(terminals.page(inPanel.id)?.path == dir.sub("a"))
        #expect(terminals.closePage(inTab.id))
        #expect(terminals.closePage(inPanel.id))
        #expect(!terminals.closePage(inPanel.id))
        #expect(terminals.page(inPanel.id) == nil)
    }

    @Test func aRowListsItsPanelPageThenItsTabs() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        let first = terminals.openPage(other, for: context, placement: .tab).page
        terminals.openTab(for: context)
        let panel = terminals.openPage(artifact, for: context).page

        #expect(terminals.pages(inRow: dir.path).map(\.page.id) == [panel.id, first.id])
        #expect(terminals.pages(inRow: dir.path).map(\.placement) == [.panel, .tab])
        #expect(terminals.pages(inRow: dir.sub("none")).isEmpty)
    }

    @Test func hidingThePanelKeepsItsPage() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path)).page

        terminals.setPanelHidden(true, inRow: dir.path)
        #expect(terminals.shownPanel(inRow: dir.path) == nil)
        #expect(terminals.panel(inRow: dir.path)?.page === page)
        terminals.setPanelHidden(false, inRow: dir.path)
        #expect(terminals.shownPanel(inRow: dir.path) === page)
    }

    @Test func navigatingUpdatesThePagesAddressAndTitle() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path)).page
        var changes = 0
        terminals.onChange = { changes += 1 }

        terminals.pageNavigated(page.id, url: URL(string: "https://claude.ai/login")!, title: "Sign in")
        terminals.pageNavigated(page.id, url: nil, title: "Sign in")

        #expect(page.url.absoluteString == "https://claude.ai/login")
        #expect(page.displayTitle == "Sign in")
        #expect(changes == 1)
    }

    @Test func closingARowDropsItsPagesWithoutLoggingThem() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        let inPanel = terminals.openPage(artifact, for: context).page
        let inTab = terminals.openPage(other, for: context, placement: .tab).page
        var closed: Set<WebPageID> = []
        terminals.onPageClosed = { closed.insert($0) }

        terminals.closeRow(path: dir.path)

        #expect(closed == [inPanel.id, inTab.id])
        #expect(terminals.panel(inRow: dir.path) == nil)
        #expect(await logged(terminals, "web").map(\.type) == ["web.opened", "web.opened"])
    }

    @Test func pagesFollowTheirRowWhenItsRepoMoves() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let old = Fixture.context("/old/demo", repoPath: "/old/demo")
        let page = terminals.openPage(artifact, for: old).page

        terminals.moveRows(ofRepo: "/old/demo", to: "/new/demo")

        #expect(terminals.panel(inRow: "/old/demo") == nil)
        #expect(terminals.shownPanel(inRow: "/new/demo") === page)
        #expect(page.context.rowPath == "/new/demo" && page.context.repoPath == "/new/demo")
    }

    @Test func aRowGoneFromItsRepoLosesItsPagesToo() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let (kept, gone) = (dir.sub("kept"), dir.sub("gone"))
        for path in [kept, gone] {
            terminals.openPage(artifact, for: Fixture.context(path, repoPath: "/r/demo"))
        }
        terminals.openPage(other, for: Fixture.context(gone, repoPath: "/r/demo"), placement: .tab)
        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept, gone]))

        terminals.closeRowsGone(from: snapshot(repo: "/r/demo", rows: [kept]))

        #expect(terminals.panel(inRow: kept) != nil)
        #expect(terminals.panel(inRow: gone) == nil)
        #expect(terminals.tabs(inRow: gone).isEmpty)
    }

    @Test func pagesNameTheirRowAsItIsNow() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let page = terminals.openPage(artifact, for: Fixture.context(dir.path, branch: "feat/old")).page
        let row = Row(repoPath: "/r/demo", path: dir.path, branch: "feat/new", head: nil, rowClass: .canopy)

        terminals.followRowNames(
            in: WorkspaceSnapshot(repos: [RepoSnapshot(path: "/r/demo", name: "renamed", rows: [row])]))

        #expect(page.context.rowName == "feat/new")
        #expect(page.context.repoName == "renamed")
    }

    func snapshot(repo: String, rows: [String]) -> WorkspaceSnapshot {
        let rows = rows.map { Row(repoPath: repo, path: $0, branch: "b", head: nil, rowClass: .canopy) }
        return WorkspaceSnapshot(repos: [RepoSnapshot(path: repo, name: "demo", rows: rows)])
    }
}
```

`Tests/CanopyCoreTests/WebPageOpenTests.swift`, changed:

```diff
@@ -160,3 +160,22 @@ struct WebPageOpenTests {
         #expect(events.allSatisfy { $0.repo == "demo" && $0.row == "feat/x" && $0.path == dir.path })
     }
 }
+
+@MainActor
+struct WebPageMovedOnTests {
+    @Test func aPageThatMovedOnIsStillFoundByTheLinkItOpenedWith() throws {
+        let dir = try TempDir()
+        let terminals = Fixture.terminals(dir)
+        let artifact = URL(string: "https://claude.ai/artifact/a1")!
+        let page = terminals.openPage(artifact, for: Fixture.context(dir.path)).page
+        // claude.ai sends a signed-out author to its sign-in.
+        terminals.pageNavigated(
+            page.id, url: URL(string: "https://claude.ai/login?returnTo=%2Fartifact%2Fa1")!, title: nil)
+        terminals.setPanelHidden(true, inRow: dir.path)
+
+        let again = terminals.openPage(artifact, for: Fixture.context(dir.path))
+
+        #expect(again.page === page && !again.isNew)
+        #expect(terminals.shownPanel(inRow: dir.path) === page)
+    }
+}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: value of type 'TerminalStore' has no member 'movePanelPageToTab'`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Terminal/TerminalStore+Web.swift`, changed:

```diff
@@ -24,11 +24,11 @@ extension TerminalStore {
     @discardableResult
     public func openPage(_ url: URL, for context: PaneContext, placement: WebPlacement? = nil) -> OpenedPage {
         let path = context.rowPath
-        if let panel = panelsByRow[path], panel.page.url == url {
+        if let panel = panelsByRow[path], panel.page.shows(url) {
             setPanelHidden(false, inRow: path)
             return OpenedPage(page: panel.page, placement: .panel, isNew: false)
         }
-        if let tab = tabs(inRow: path).first(where: { $0.page?.url == url }), let page = tab.page {
+        if let tab = tabs(inRow: path).first(where: { $0.page?.shows(url) == true }), let page = tab.page {
             selectTab(tab.id, inRow: path)
             return OpenedPage(page: page, placement: .tab, isNew: false)
         }
@@ -48,6 +48,90 @@ extension TerminalStore {
         return OpenedPage(page: page, placement: placement, isNew: true)
     }
 
+    /// The panel's page, into a new tab after the selected one. New pages open in tabs from now on.
+    public func movePanelPageToTab(inRow path: String) {
+        guard let page = panelsByRow.removeValue(forKey: path)?.page else { return }
+        insertTab(for: page, inRow: path)
+        webPlacement = .tab
+        onChange()
+    }
+
+    /// A web tab's page, into the row's panel. A page the panel held already takes the tab's place, so nothing is lost.
+    /// New pages open in the panel from now on.
+    public func moveTabToPanel(_ id: TabID, inRow path: String) {
+        var tabs = tabs(inRow: path)
+        guard let index = tabs.firstIndex(where: { $0.id == id }), let page = tabs[index].page else { return }
+        let wasSelected = selectedTab(inRow: path)?.id == id
+        tabs.remove(at: index)
+        tabsByRow[path] = tabs.isEmpty ? nil : tabs
+        if tabs.isEmpty {
+            selectedTabByRow[path] = nil
+        } else if wasSelected {
+            selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
+        }
+        let selected = selectedTabByRow[path]
+        if let replaced = panelsByRow[path]?.page {
+            insertTab(for: replaced, inRow: path, at: index)
+            if let selected { selectedTabByRow[path] = selected }
+        }
+        panelsByRow[path] = WebPanel(page: page, isHidden: false)
+        webPlacement = .panel
+        markSeenOnScreen()
+        onChange()
+    }
+
+    /// The panel's close button: the page closes, and the panel with it.
+    public func closePanel(inRow path: String) {
+        guard let page = panelsByRow.removeValue(forKey: path)?.page else { return }
+        retire(page)
+        onChange()
+    }
+
+    /// Closes a page wherever it is. Returns false when no row has it.
+    @discardableResult
+    public func closePage(_ id: WebPageID) -> Bool {
+        guard let found = page(id) else { return false }
+        switch found.placement {
+        case .panel: closePanel(inRow: found.path)
+        case .tab:
+            if let tab = tabs(inRow: found.path).first(where: { $0.page?.id == id }) {
+                closeTab(tab.id, inRow: found.path)
+            }
+        }
+        return true
+    }
+
+    /// The page with this ID, the row it is in, and where.
+    public func page(_ id: WebPageID) -> (page: WebPage, path: String, placement: WebPlacement)? {
+        for path in rowPaths {
+            if let found = pages(inRow: path).first(where: { $0.page.id == id }) {
+                return (found.page, path, found.placement)
+            }
+        }
+        return nil
+    }
+
+    /// The row's panel page, then its web tabs in tab bar order.
+    public func pages(inRow path: String) -> [(page: WebPage, placement: WebPlacement)] {
+        let panel = panelsByRow[path].map { [($0.page, WebPlacement.panel)] } ?? []
+        return panel + tabs(inRow: path).compactMap { tab in tab.page.map { ($0, .tab) } }
+    }
+
+    /// Where the page's web view went and what it is called now.
+    public func pageNavigated(_ id: WebPageID, url: URL?, title: String?) {
+        guard let page = page(id)?.page else { return }
+        var changed = false
+        if let url, page.url != url {
+            page.url = url
+            changed = true
+        }
+        if let title, page.title != title {
+            page.title = title
+            changed = true
+        }
+        if changed { onChange() }
+    }
+
     public func setPanelHidden(_ hidden: Bool, inRow path: String) {
         guard panelsByRow[path] != nil, panelsByRow[path]?.isHidden != hidden else { return }
         panelsByRow[path]?.isHidden = hidden
```

`Sources/CanopyCore/Terminal/TerminalStore.swift`, changed:

```diff
@@ -231,9 +231,11 @@ public final class TerminalStore {
         var tabs = tabs(inRow: path)
         guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
         let wasSelected = selectedTab(inRow: path)?.id == id
-        for pane in tabs.remove(at: index).paneList {
+        let removed = tabs.remove(at: index)
+        for pane in removed.paneList {
             pane.close()
         }
+        removed.page.map(retire)
         tabsByRow[path] = tabs.isEmpty ? nil : tabs
         if tabs.isEmpty {
             selectedTabByRow[path] = nil
@@ -346,10 +348,15 @@ public final class TerminalStore {
 
     // MARK: Rows
 
+    /// Closes a row's terminals and drops its pages. The pages are not logged as closed, since a row's pages also close
+    /// this way when Canopy quits, and come back when it starts.
     public func closeRow(path: String) {
         for pane in tabs(inRow: path).flatMap(\.paneList) {
             pane.close()
         }
+        for page in pages(inRow: path).map(\.page) {
+            onPageClosed(page.id)
+        }
         tabsByRow[path] = nil
         selectedTabByRow[path] = nil
         panelsByRow[path] = nil
@@ -361,8 +368,8 @@ public final class TerminalStore {
     /// plain git, so they neither keep running out of reach nor come back when a new row reuses the folder.
     /// Repos that are missing or failed to refresh keep their terminals.
     public func closeRowsGone(from snapshot: WorkspaceSnapshot) {
-        for (path, tabs) in tabsByRow {
-            guard let repoPath = tabs.first?.repoPath,
+        for path in rowPaths {
+            guard let repoPath = repoPath(ofRow: path),
                 let repo = snapshot.repo(path: repoPath), !repo.isMissing, repo.error == nil
             else { continue }
             if repo.allRows.contains(where: { $0.path == path }) {
@@ -384,27 +391,53 @@ public final class TerminalStore {
             if pane.context.rowName != row.displayName { pane.context.rowName = row.displayName }
             if name != repo.name { pane.context.owner = .repo(name: repo.name, path: path) }
         }
+        for page in rowPaths.flatMap({ pages(inRow: $0).map(\.page) }) {
+            guard case .repo(let name, let path) = page.context.owner,
+                let row = snapshot.row(path: page.context.rowPath),
+                let repo = snapshot.repo(path: row.repoPath)
+            else { continue }
+            if page.context.rowName != row.displayName { page.context.rowName = row.displayName }
+            if name != repo.name { page.context.owner = .repo(name: repo.name, path: path) }
+        }
     }
 
-    /// Closes every terminal in a repo's rows, for when the repo is unregistered.
+    /// Closes every terminal and page in a repo's rows, for when the repo is unregistered.
     public func closeRows(ofRepo repoPath: String) {
-        for (path, tabs) in tabsByRow where tabs.first?.repoPath == repoPath {
+        for path in rowPaths where self.repoPath(ofRow: path) == repoPath {
             closeRow(path: path)
         }
     }
 
+    /// Rows with tabs or a panel.
+    var rowPaths: Set<String> {
+        Set(tabsByRow.keys).union(panelsByRow.keys)
+    }
+
+    /// Nil for a plugin's row.
+    func repoPath(ofRow path: String) -> String? {
+        tabs(inRow: path).lazy.compactMap(\.repoPath).first ?? panelsByRow[path]?.page.context.repoPath
+    }
+
     /// Follows a repo that moved: rows inside its old folder move with it, and every pane learns its new paths.
     public func moveRows(ofRepo oldRepoPath: String, to newRepoPath: String) {
-        for (path, tabs) in tabsByRow where tabs.first?.repoPath == oldRepoPath {
+        for path in rowPaths where repoPath(ofRow: path) == oldRepoPath {
             let newPath = Paths.isInside(path, oldRepoPath) ? newRepoPath + path.dropFirst(oldRepoPath.count) : path
-            for pane in tabs.flatMap(\.paneList) {
+            for pane in tabs(inRow: path).flatMap(\.paneList) {
                 if case .repo(let name, _) = pane.context.owner {
                     pane.context.owner = .repo(name: name, path: newRepoPath)
                 }
                 pane.context.rowPath = newPath
             }
-            tabsByRow[path] = nil
+            for page in pages(inRow: path).map(\.page) {
+                if case .repo(let name, _) = page.context.owner {
+                    page.context.owner = .repo(name: name, path: newRepoPath)
+                }
+                page.context.rowPath = newPath
+            }
+            let tabs = tabsByRow.removeValue(forKey: path)
             tabsByRow[newPath] = tabs
+            let panel = panelsByRow.removeValue(forKey: path)
+            panelsByRow[newPath] = panel
             if let selected = selectedTabByRow.removeValue(forKey: path) {
                 selectedTabByRow[newPath] = selected
             }
```

`Sources/CanopyCore/Web/WebPage.swift`, changed:

```diff
@@ -34,12 +34,20 @@ public final class WebPage: Identifiable {
     public internal(set) var title: String
     /// The row it belongs to, for the activity log.
     public internal(set) var context: PaneContext
+    /// The address it opened with, which still finds it after it moves on, as to claude.ai's sign-in.
+    public let openedURL: URL
 
     init(id: WebPageID, url: URL, title: String, context: PaneContext) {
         self.id = id
         self.url = url
         self.title = title
         self.context = context
+        self.openedURL = url
+    }
+
+    /// Whether the page is at `url`, or opened with it.
+    func shows(_ url: URL) -> Bool {
+        self.url == url || openedURL == url
     }
 
     /// The title, or the host until the page has one.
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "WebPageMoveTests|WebPageMovedOnTests"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: move, close, and hide web pages"
```

### Task 4: Saved pages and web settings

`SavedTab` gains `web`, and its `layout` becomes optional; a tab with neither does not decode.
`SavedRowTerminals` gains `panel`, and `AppState` gains `webPlacement`, `webPanelWidth`, and `nextWebPage`, each falling back to its default on its own when it cannot be read.
Restoring makes pages that load only once they show, drops pages that are not web addresses, and keeps a row's existing tabs and panel.
The app saves the page counter and placement with the layouts and restores them at launch.

**Files:**
- Modify: `Sources/CanopyApp/AppModel.swift`
- Modify: `Sources/CanopyCore/State/AppState.swift`
- Modify: `Sources/CanopyCore/State/SavedTerminals.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace.swift`
- Create: `Tests/CanopyCoreTests/SavedWebTests.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `SavedWebPage { url, title }`, `SavedWebPanel { page, hidden }`, `SavedTab(name:web:)`, `SavedRowTerminals(tabs:selectedTab:panel:)`; `Workspace.savedNextWebPage`, `savedWebPlacement`, `webPanelWidth`, `setWebPanelWidth(_:)`, `setSavedTerminals(_:nextPane:nextWebPage:webPlacement:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/SavedWebTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct SavedWebTests {
    let artifact = URL(string: "https://claude.ai/artifact/a1")!
    let other = URL(string: "http://localhost:5173/")!

    @Test func webTabsAndPanelsComeBackWhereTheyWere() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let context = Fixture.context(dir.path)
        terminals.openTab(for: context)
        let tabPage = terminals.openPage(other, for: context, placement: .tab).page
        terminals.pageNavigated(tabPage.id, url: nil, title: "Dev server")
        terminals.openTab(for: context, select: false)
        let panelPage = terminals.openPage(artifact, for: context).page
        terminals.pageNavigated(panelPage.id, url: nil, title: "Launch plan")
        terminals.setPanelHidden(true, inRow: dir.path)

        let saved = try #require(terminals.saved()[dir.path])
        #expect(saved.tabs.map(\.web) == [nil, SavedWebPage(url: other.absoluteString, title: "Dev server"), nil])
        #expect(saved.tabs[1].layout == nil)
        #expect(saved.selectedTab == 1)
        #expect(
            saved.panel
                == SavedWebPanel(page: SavedWebPage(url: artifact.absoluteString, title: "Launch plan"), hidden: true))

        let restored = Fixture.terminals(dir)
        defer { restored.closeAll() }
        restored.continueWebNumbering(from: terminals.nextWebPageNumber)
        restored.restore(saved, for: context)

        let tabs = restored.tabs(inRow: dir.path)
        #expect(tabs.map(\.name) == ["Terminal", "Dev server", "Terminal 2"])
        #expect(tabs[1].page?.url == other)
        #expect(tabs[1].page?.id == WebPageID(3))
        #expect(restored.selectedTab(inRow: dir.path)?.id == tabs[1].id)
        #expect(restored.panel(inRow: dir.path)?.page.url == artifact)
        #expect(restored.panel(inRow: dir.path)?.page.displayTitle == "Launch plan")
        #expect(restored.panel(inRow: dir.path)?.isHidden == true)
    }

    @Test func aRowWithOnlyPagesRestoresThemAndNoTerminal() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let context = Fixture.context(dir.path)
        terminals.openPage(other, for: context, placement: .tab)
        terminals.openPage(artifact, for: context)
        let saved = try #require(terminals.saved()[dir.path])

        let restored = Fixture.terminals(dir)
        restored.restore(saved, for: context)

        #expect(restored.tabs(inRow: dir.path).map { $0.page?.url } == [other])
        #expect(restored.panes.isEmpty)
        #expect(restored.shownPanel(inRow: dir.path)?.url == artifact)
    }

    @Test func aPanelAloneIsSavedForItsRow() throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        terminals.openPage(artifact, for: Fixture.context(dir.path))

        let saved = try #require(terminals.saved()[dir.path])
        #expect(saved.tabs.isEmpty && saved.panel?.page.url == artifact.absoluteString)

        let restored = Fixture.terminals(dir)
        restored.restore(saved, for: Fixture.context(dir.path))
        #expect(restored.shownPanel(inRow: dir.path)?.url == artifact)
    }

    @Test func pagesThatAreNotWebAddressesAreDropped() throws {
        let dir = try TempDir()
        let saved = SavedRowTerminals(
            tabs: [
                SavedTab(name: "x", web: SavedWebPage(url: "file:///etc/hosts", title: "x")),
                SavedTab(name: "y", web: SavedWebPage(url: other.absoluteString, title: "")),
            ],
            selectedTab: 1,
            panel: SavedWebPanel(page: SavedWebPage(url: "javascript:alert(1)", title: ""), hidden: false))
        let terminals = Fixture.terminals(dir)

        terminals.restore(saved, for: Fixture.context(dir.path))

        #expect(terminals.tabs(inRow: dir.path).map { $0.page?.url } == [other])
        #expect(terminals.panel(inRow: dir.path) == nil)
    }

    @Test func savedTabsReadAsJSON() throws {
        let json = """
            {"tabs": [
                {"name": "Terminal", "layout": {"pane": {"folder": "/r"}}, "focused": 0},
                {"name": "Plan", "web": {"url": "https://claude.ai/artifact/a1", "title": "Plan"}}
            ], "selectedTab": 1, "panel": {"page": {"url": "http://localhost:5173/", "title": ""}, "hidden": false}}
            """

        let row = try JSONDecoder().decode(SavedRowTerminals.self, from: Data(json.utf8))

        #expect(row.tabs.map(\.web?.title) == [nil, "Plan"])
        #expect(row.tabs[0].layout == .leaf(SavedPane(folder: "/r")))
        #expect(row.panel?.page.url == "http://localhost:5173/")
        #expect(try JSONDecoder().decode(SavedRowTerminals.self, from: try JSONEncoder().encode(row)) == row)
        let tabWithNothing = #"{"tabs": [{"name": "x"}], "selectedTab": 0}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SavedRowTerminals.self, from: Data(tabWithNothing.utf8))
        }
    }

    @Test func anOlderStateFileHasNoPages() throws {
        let json = """
            {"version": 1, "repos": [], "terminals": {"/r": {"tabs": [
                {"name": "Terminal", "layout": {"pane": {"folder": "/r"}}, "focused": 0}
            ], "selectedTab": 0}}}
            """

        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))

        #expect(state.terminals["/r"]?.tabs.count == 1)
        #expect(state.terminals["/r"]?.panel == nil)
        #expect(state.webPlacement == .panel)
        #expect(state.webPanelWidth == nil)
        #expect(state.nextWebPage == 1)
    }

    @Test func webSettingsRoundTripAndAnUnknownPlacementFallsBack() throws {
        var state = AppState()
        state.webPlacement = .tab
        state.webPanelWidth = 612
        state.nextWebPage = 9
        #expect(try JSONDecoder().decode(AppState.self, from: try JSONEncoder().encode(state)) == state)

        let odd = #"{"version": 1, "webPlacement": "window", "webPanelWidth": "wide", "nextWebPage": 4}"#
        let decoded = try JSONDecoder().decode(AppState.self, from: Data(odd.utf8))
        #expect(decoded.webPlacement == .panel && decoded.webPanelWidth == nil && decoded.nextWebPage == 4)
    }

    @Test func theWorkspaceKeepsWebSettings() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home)
        try await workspace.start()

        try await workspace.setSavedTerminals([:], nextPane: 4, nextWebPage: 6, webPlacement: .tab)
        try await workspace.setWebPanelWidth(555)
        await workspace.stop()

        let reloaded = Workspace(home: home)
        try await reloaded.start()
        #expect(await reloaded.savedNextWebPage == 6)
        #expect(await reloaded.savedWebPlacement == .tab)
        #expect(await reloaded.webPanelWidth == 555)
        await reloaded.stop()
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: cannot find 'SavedWebPage' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyApp/AppModel.swift`, changed:

```diff
@@ -100,6 +100,8 @@ final class AppModel {
         await plugins.start()
         let saved = await workspace.savedTerminals
         terminals.continueNumbering(from: await workspace.savedNextPane)
+        terminals.continueWebNumbering(from: await workspace.savedNextWebPage)
+        terminals.webPlacement = await workspace.savedWebPlacement
         snapshot = await workspace.snapshot
         restoreTerminals(saved)
         let updates = await workspace.updates()
@@ -875,7 +877,8 @@ final class AppModel {
         guard terminalsRestored else { return }
         do {
             try await workspace.setSavedTerminals(
-                terminals.saved().merging(deferredTerminals) { live, _ in live }, nextPane: terminals.nextPaneNumber)
+                terminals.saved().merging(deferredTerminals) { live, _ in live }, nextPane: terminals.nextPaneNumber,
+                nextWebPage: terminals.nextWebPageNumber, webPlacement: terminals.webPlacement)
         } catch {
             show(error)
         }
```

`Sources/CanopyCore/State/AppState.swift`, changed:

```diff
@@ -78,6 +78,12 @@ public struct AppState: Codable, Sendable, Equatable {
     public var agentHooksOffered = false
     /// Each plugin's rows and links, keyed by the plugin's id, including plugins this build does not have.
     public var plugins: [String: PluginEntry] = [:]
+    /// Where new web pages open: where the author last moved one.
+    public var webPlacement = WebPlacement.panel
+    /// The web panel's width, the same for every row. Nil until the author drags it.
+    public var webPanelWidth: Double?
+    /// The next web page number, so `canopy web close` never closes a different page after a relaunch.
+    public var nextWebPage = 1
 
     public init(
         version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil,
@@ -102,5 +108,9 @@ public struct AppState: Codable, Sendable, Equatable {
         // A plugin's entry that cannot be read is dropped on its own, so repos and other plugins still load.
         let plugins = try? container.decodeIfPresent([String: Lenient<PluginEntry>].self, forKey: .plugins)
         self.plugins = plugins?.compactMapValues(\.value) ?? [:]
+        // Web settings that cannot be read fall back to their defaults on their own.
+        webPlacement = (try? container.decodeIfPresent(WebPlacement.self, forKey: .webPlacement)) ?? .panel
+        webPanelWidth = try? container.decodeIfPresent(Double.self, forKey: .webPanelWidth)
+        nextWebPage = (try? container.decodeIfPresent(Int.self, forKey: .nextWebPage)) ?? 1
     }
 }
```

`Sources/CanopyCore/State/SavedTerminals.swift`, changed:

```diff
@@ -7,26 +7,70 @@ public struct SavedPane: Codable, Hashable, Sendable {
     }
 }
 
+/// A web page as saved: where it was and what it was called. Restoring loads it only once it shows.
+public struct SavedWebPage: Codable, Hashable, Sendable {
+    public var url: String
+    public var title: String
+
+    public init(url: String, title: String) {
+        self.url = url
+        self.title = title
+    }
+}
+
+/// A terminal tab, with its layout, or a web tab, with its page.
 public struct SavedTab: Codable, Equatable, Sendable {
     public var name: String
-    public var layout: Layout<SavedPane>
+    /// Nil for a web tab.
+    public var layout: Layout<SavedPane>?
     /// The focused pane's position in layout order.
     public var focused: Int?
+    public var web: SavedWebPage?
 
     public init(name: String, layout: Layout<SavedPane>, focused: Int?) {
         self.name = name
         self.layout = layout
         self.focused = focused
     }
+
+    public init(name: String, web: SavedWebPage) {
+        self.name = name
+        self.web = web
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        name = try container.decode(String.self, forKey: .name)
+        layout = try container.decodeIfPresent(Layout<SavedPane>.self, forKey: .layout)
+        focused = try container.decodeIfPresent(Int.self, forKey: .focused)
+        web = try container.decodeIfPresent(SavedWebPage.self, forKey: .web)
+        guard layout != nil || web != nil else {
+            throw DecodingError.dataCorruptedError(
+                forKey: .layout, in: container, debugDescription: "A tab needs a layout or a web page.")
+        }
+    }
+}
+
+/// A row's panel as saved: its page, and whether the author hid it.
+public struct SavedWebPanel: Codable, Equatable, Sendable {
+    public var page: SavedWebPage
+    public var hidden: Bool
+
+    public init(page: SavedWebPage, hidden: Bool) {
+        self.page = page
+        self.hidden = hidden
+    }
 }
 
-/// A row's tabs as saved in state.json.
+/// A row's tabs and panel as saved in state.json.
 public struct SavedRowTerminals: Codable, Equatable, Sendable {
     public var tabs: [SavedTab]
     public var selectedTab: Int
+    public var panel: SavedWebPanel?
 
-    public init(tabs: [SavedTab], selectedTab: Int) {
+    public init(tabs: [SavedTab], selectedTab: Int, panel: SavedWebPanel? = nil) {
         self.tabs = tabs
         self.selectedTab = selectedTab
+        self.panel = panel
     }
 }
```

`Sources/CanopyCore/Terminal/TerminalStore.swift`, changed:

```diff
@@ -456,51 +456,82 @@ public final class TerminalStore {
 
     // MARK: Saving and restoring
 
-    /// Every row's tabs as they would be restored: names, layouts, and each pane's current folder.
+    /// Every row's tabs and panel as they would be restored: names, layouts, each pane's current folder, and each
+    /// page's address and title.
     public func saved() -> [String: SavedRowTerminals] {
         var saved: [String: SavedRowTerminals] = [:]
-        for (path, tabs) in tabsByRow {
-            let terminalTabs = tabs.filter { $0.grid != nil }
-            guard !terminalTabs.isEmpty else { continue }
+        for path in rowPaths {
+            let tabs = tabs(inRow: path)
             saved[path] = SavedRowTerminals(
-                tabs: terminalTabs.compactMap { tab in
-                    tab.grid.map { grid in
-                        SavedTab(
-                            name: tab.name,
-                            layout: grid.layout.map { id in
-                                let pane = grid.panes[id]
-                                return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
-                            },
-                            focused: grid.layout.leaves.firstIndex(of: grid.focusedPaneID)
-                        )
-                    }
-                },
-                selectedTab: terminalTabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0
-            )
+                tabs: tabs.map { savedTab($0, inRow: path) },
+                selectedTab: tabs.firstIndex { $0.id == selectedTabByRow[path] } ?? 0,
+                panel: panelsByRow[path].map { SavedWebPanel(page: savedPage($0.page), hidden: $0.isHidden) })
         }
         return saved
     }
 
-    /// Rebuilds a row's saved tabs with fresh shells in the saved folders. Folders that are gone fall back to the
-    /// row's own. Replaces nothing: a row that already has tabs keeps them.
+    private func savedTab(_ tab: TerminalTab, inRow path: String) -> SavedTab {
+        switch tab.content {
+        case .web(let page):
+            return SavedTab(name: tab.name, web: savedPage(page))
+        case .terminals(let grid):
+            return SavedTab(
+                name: tab.name,
+                layout: grid.layout.map { id in
+                    let pane = grid.panes[id]
+                    return SavedPane(folder: pane?.currentDirectory ?? pane?.startDirectory ?? path)
+                },
+                focused: grid.layout.leaves.firstIndex(of: grid.focusedPaneID))
+        }
+    }
+
+    private func savedPage(_ page: WebPage) -> SavedWebPage {
+        SavedWebPage(url: page.url.absoluteString, title: page.title)
+    }
+
+    /// Rebuilds a row's saved tabs with fresh shells in the saved folders, and its pages, which load once they show.
+    /// Folders that are gone fall back to the row's own, and pages that are not web addresses are dropped. Replaces
+    /// nothing: a row that already has tabs keeps them, and one that has a panel keeps it.
     public func restore(_ saved: SavedRowTerminals, for context: PaneContext) {
-        guard tabs(inRow: context.rowPath).isEmpty, !saved.tabs.isEmpty else { return }
-        let tabs = saved.tabs.map { savedTab in
-            let panes = savedTab.layout.leaves.map { makePane(context, command: .shell, directory: $0.folder) }
-            var index = 0
-            let layout: Layout<PaneID> = savedTab.layout.map { _ in
-                defer { index += 1 }
-                return panes[index].id
+        let path = context.rowPath
+        if tabs(inRow: path).isEmpty {
+            let restored = saved.tabs.enumerated().compactMap { index, savedTab in
+                restoredTab(savedTab, for: context).map { (index, $0) }
             }
-            let focused = savedTab.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
-            let tab = TerminalTab(
-                id: TabID(nextTab), name: savedTab.name,
-                grid: TerminalGrid(layout: layout, panes: panes, focusedPaneID: focused))
-            nextTab += 1
-            return tab
+            if let first = restored.first {
+                tabsByRow[path] = restored.map(\.1)
+                selectedTabByRow[path] = (restored.last { $0.0 <= saved.selectedTab } ?? first).1.id
+            }
+        }
+        if panelsByRow[path] == nil, let panel = saved.panel, let page = restoredPage(panel.page, for: context) {
+            panelsByRow[path] = WebPanel(page: page, isHidden: panel.hidden)
+        }
+    }
+
+    private func restoredTab(_ saved: SavedTab, for context: PaneContext) -> TerminalTab? {
+        if let web = saved.web {
+            guard let page = restoredPage(web, for: context) else { return nil }
+            defer { nextTab += 1 }
+            return TerminalTab(id: TabID(nextTab), page: page)
+        }
+        guard let savedLayout = saved.layout else { return nil }
+        let panes = savedLayout.leaves.map { makePane(context, command: .shell, directory: $0.folder) }
+        var index = 0
+        let layout: Layout<PaneID> = savedLayout.map { _ in
+            defer { index += 1 }
+            return panes[index].id
         }
-        tabsByRow[context.rowPath] = tabs
-        selectedTabByRow[context.rowPath] = tabs[min(max(saved.selectedTab, 0), tabs.count - 1)].id
+        let focused = saved.focused.flatMap { panes.indices.contains($0) ? panes[$0].id : nil } ?? panes[0].id
+        defer { nextTab += 1 }
+        return TerminalTab(
+            id: TabID(nextTab), name: saved.name,
+            grid: TerminalGrid(layout: layout, panes: panes, focusedPaneID: focused))
+    }
+
+    private func restoredPage(_ saved: SavedWebPage, for context: PaneContext) -> WebPage? {
+        guard let url = WebAddress.parse(saved.url) else { return nil }
+        defer { nextWebPage += 1 }
+        return WebPage(id: WebPageID(nextWebPage), url: url, title: saved.title, context: context)
     }
 
     private func makePane(_ context: PaneContext, command: PaneCommand, directory: String?) -> Pane {
```

`Sources/CanopyCore/Workspace/Workspace.swift`, changed:

```diff
@@ -258,11 +258,39 @@ public actor Workspace {
         state.nextPane
     }
 
-    public func setSavedTerminals(_ terminals: [String: SavedRowTerminals], nextPane: Int? = nil) throws {
+    public var savedNextWebPage: Int {
+        state.nextWebPage
+    }
+
+    public var savedWebPlacement: WebPlacement {
+        state.webPlacement
+    }
+
+    public func setSavedTerminals(
+        _ terminals: [String: SavedRowTerminals], nextPane: Int? = nil, nextWebPage: Int? = nil,
+        webPlacement: WebPlacement? = nil
+    ) throws {
         let nextPane = max(nextPane ?? state.nextPane, state.nextPane)
-        guard state.terminals != terminals || state.nextPane != nextPane else { return }
+        let nextWebPage = max(nextWebPage ?? state.nextWebPage, state.nextWebPage)
+        let webPlacement = webPlacement ?? state.webPlacement
+        guard
+            state.terminals != terminals || state.nextPane != nextPane || state.nextWebPage != nextWebPage
+                || state.webPlacement != webPlacement
+        else { return }
         state.terminals = terminals
         state.nextPane = nextPane
+        state.nextWebPage = nextWebPage
+        state.webPlacement = webPlacement
+        try save()
+    }
+
+    public var webPanelWidth: Double? {
+        state.webPanelWidth
+    }
+
+    public func setWebPanelWidth(_ width: Double) throws {
+        guard state.webPanelWidth != width else { return }
+        state.webPanelWidth = width
         try save()
     }
 
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "SavedWebTests"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: web pages and the panel survive relaunches"
```

### Task 5: web.open, web.list, and web.close

The control API opens a page in the row the target resolves to, by the opening rules, and never changes the selected row.
`web.open` checks the URL before the row, so a bad URL is `invalid_url` wherever it was sent from, and a worktree row whose folder is gone is `path_not_found`, as for `term new`.
`web.list` is read-only and stays out of the activity log, like `term.list`.

**Files:**
- Modify: `Sources/CanopyCore/Control/ControlMethods.swift`
- Create: `Sources/CanopyCore/Control/WebMethods.swift`
- Modify: `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`
- Create: `Sources/CanopyCore/Rows/RowLifecycle+Web.swift`
- Modify: `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Create: `Tests/CanopyCoreTests/WebControlTests.swift`

**Interfaces:**
- Consumes: Tasks 2 to 4.
- Produces: `WebMethod.open`, `.list`, `.close`; `WebOpenParams(target:url:placement:)`, `WebOpenResult { page, placement, row }`, `WebListParams(target:all:)`, `WebPageInfo`, `WebCloseParams(page:)`; `WorkspaceError.invalidURL`, `.pageNotFound`; `RowLifecycle.openPage`, `pageInfo(rowPath:repoNames:)`, `closePage(_:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WebControlTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

extension ControlServerTests {
    @Test func webPagesOpenListAndCloseOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, ui) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")
        let page = "http://127.0.0.1:9/page"

        let opened = try await call(
            client, WebMethod.open, WebOpenParams(target: target, url: page), as: WebOpenResult.self)
        #expect(opened == WebOpenResult(page: "w1", placement: .panel, row: "main"))
        let again = try await call(
            client, WebMethod.open, WebOpenParams(target: target, url: page, placement: .tab), as: WebOpenResult.self)
        #expect(again == opened)
        let tab = try await call(
            client, WebMethod.open, WebOpenParams(target: target, url: page + "2", placement: .tab),
            as: WebOpenResult.self)
        #expect(tab.placement == .tab && tab.page == "w2")

        let listed = try await call(client, WebMethod.list, WebListParams(target: target), as: [WebPageInfo].self)
        #expect(listed.map(\.page) == ["w1", "w2"])
        #expect(listed.map(\.placement) == [.panel, .tab])
        #expect(listed.first?.url == page)
        #expect(listed.first?.title == "127.0.0.1")
        #expect(listed.first?.repo == "demo" && listed.first?.row == "main" && listed.first?.rowPath == repo)
        #expect(try await call(client, WebMethod.list, WebListParams(all: true), as: [WebPageInfo].self).count == 2)

        _ = try await call(client, WebMethod.close, WebCloseParams(page: "w1"), as: JSONValue.self)
        let left = try await call(client, WebMethod.list, WebListParams(target: target), as: [WebPageInfo].self)
        #expect(left.map(\.page) == ["w2"])
        // The CLI never changes which row is selected.
        #expect(ui.selected.withLock { $0 }.isEmpty)

        let opens = await logged(workspace, "cli").filter { $0.data["method"] == .string(WebMethod.open) }
        #expect(opens.count == 3)
        #expect(await logged(workspace, "cli").allSatisfy { $0.data["method"] != .string(WebMethod.list) })
    }

    @Test func webMethodsSayWhatIsWrong() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")

        for url in ["file:///etc/hosts", "javascript:alert(1)", "example.com", ""] {
            #expect(
                try await error(client, WebMethod.open, try .from(WebOpenParams(target: target, url: url)))
                    == "invalid_url", "\(url)")
        }
        #expect(
            try await error(
                client, WebMethod.open,
                try .from(WebOpenParams(target: TargetHint(repo: "demo", row: "nope"), url: "https://x.dev")))
                == "row_not_found")
        #expect(try await error(client, WebMethod.close, try .from(WebCloseParams(page: "w7"))) == "page_not_found")
        #expect(try await error(client, WebMethod.close, try .from(WebCloseParams(page: "p7"))) == "page_not_found")
    }
}

extension ControlServerTests {
    @Test func webOpenRefusesARowWhoseFolderIsGoneAndAPlacementItDoesNotKnow() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let feature = dir.sub("feature")
        try await Fixture.worktree(repo: repo, branch: "feat/gone", at: feature)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        _ = try await workspace.adopt(path: Paths.canonical(feature))
        try FileManager.default.removeItem(atPath: feature)
        await workspace.refreshAll()

        #expect(
            try await error(
                client, WebMethod.open,
                try .from(WebOpenParams(target: TargetHint(repo: "demo", row: "feat/gone"), url: "https://x.dev")))
                == "path_not_found")
        let window: JSONValue = .object([
            "url": "https://x.dev", "placement": "window", "target": try .from(TargetHint(repo: "demo", row: "main")),
        ])
        #expect(try await error(client, WebMethod.open, window) == "bad_params")
    }
}

extension PluginControlTests {
    @Test func aPluginRowShowsPagesAndTheyGoWithIt() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")

        // From a terminal in the plugin row, which knows its row only by CANOPY_ROW_PATH.
        let opened = try await call(
            setup, WebMethod.open, WebOpenParams(target: TargetHint(envRowPath: row.path), url: "https://x.dev/a"),
            as: WebOpenResult.self)
        #expect(opened.row == row.displayName)
        let listed = try await call(setup, WebMethod.list, WebListParams(all: true), as: [WebPageInfo].self)
        #expect(listed.map(\.plugin) == ["t"] && listed.map(\.repo) == [nil] && listed.map(\.rowPath) == [row.path])

        _ = try await call(
            setup, ControlMethod.rowRemove, RowRemoveParams(target: TargetHint(row: row.path)), as: RowRemoveResult.self
        )
        #expect(try await call(setup, WebMethod.list, WebListParams(all: true), as: [WebPageInfo].self).isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: cannot find 'WebMethod' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Control/ControlMethods.swift`, changed:

```diff
@@ -21,7 +21,7 @@ public enum ControlMethod {
     /// Methods that only read, which the activity log leaves out: agents poll some of them every few seconds.
     public static let readOnly: Set<String> = [
         status, repoList, rowList, prShow, prList, branchList, TermMethod.list, TermMethod.read, TermMethod.wait,
-        PortMethod.list, GroupMethod.list, PluginMethod.list, PluginMethod.items,
+        PortMethod.list, GroupMethod.list, PluginMethod.list, PluginMethod.items, WebMethod.list,
     ]
 
     /// Methods left out of `cli.call`: the read-only ones, and `term.state`, which hooks send on every tool call and
```

`Sources/CanopyCore/Control/WebMethods.swift`, new:

```swift
import Foundation

public enum WebMethod {
    public static let open = "web.open"
    public static let list = "web.list"
    public static let close = "web.close"
}

public struct WebOpenParams: Codable, Sendable {
    public var target: TargetHint
    public var url: String
    /// The panel or a tab for this page alone. Nil opens it where the author last moved a page.
    public var placement: WebPlacement?

    public init(target: TargetHint = TargetHint(), url: String, placement: WebPlacement? = nil) {
        self.target = target
        self.url = url
        self.placement = placement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        url = try container.decode(String.self, forKey: .url)
        placement = try container.decodeIfPresent(WebPlacement.self, forKey: .placement)
    }
}

public struct WebOpenResult: Codable, Sendable, Equatable {
    public var page: String
    public var placement: WebPlacement
    public var row: String
}

/// One page as `canopy web list` shows it.
public struct WebPageInfo: Codable, Sendable, Equatable {
    public var page: String
    public var url: String
    /// The page's title, or its host before it has loaded.
    public var title: String
    public var placement: WebPlacement
    /// Left out for a plugin's row, which names its plugin instead.
    public var repo: String?
    public var plugin: String?
    public var row: String
    public var rowPath: String
}

public struct WebListParams: Codable, Sendable {
    public var target: TargetHint
    /// Every row's pages, as when no row resolves.
    public var all: Bool

    public init(target: TargetHint = TargetHint(), all: Bool = false) {
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct WebCloseParams: Codable, Sendable {
    public var page: String

    public init(page: String) {
        self.page = page
    }
}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, changed:

```diff
@@ -326,6 +326,28 @@ public struct WorkspaceControlHandler: Sendable {
         case TermMethod.wait:
             return try .from(try await rows.waitForAgents(request.decodeParams(TermWaitParams.self)))
 
+        case WebMethod.open:
+            let params = try request.decodeParams(WebOpenParams.self)
+            guard let url = WebAddress.parse(params.url) else { throw WorkspaceError.invalidURL(params.url) }
+            let snapshot = await workspace.snapshot
+            let row = try TargetResolver.sidebarRow(for: params.target, in: snapshot)
+            if let worktree = row.worktree, worktree.isMissing { throw WorkspaceError.pathNotFound(worktree.path) }
+            let repoName = row.worktree.flatMap { snapshot.repo(path: $0.repoPath)?.name } ?? ""
+            return try .from(
+                await rows.openPage(url, for: PaneContext(row, repoName: repoName), placement: params.placement))
+
+        case WebMethod.list:
+            let params = try request.decodeParams(WebListParams.self)
+            let snapshot = await workspace.snapshot
+            let row = try await rowUnlessAll(params.target, all: params.all)
+            let names = Dictionary(snapshot.repos.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
+            return try .from(await rows.pageInfo(rowPath: row?.path, repoNames: names))
+
+        case WebMethod.close:
+            let params = try request.decodeParams(WebCloseParams.self)
+            try await rows.closePage(params.page)
+            return .object(["page": .string(params.page)])
+
         case PluginMethod.list:
             return try .from(await plugins.list())
 
```

`Sources/CanopyCore/Rows/RowLifecycle+Web.swift`, new:

```swift
import Foundation

/// What `canopy web` does, on the main actor where pages live.
extension RowLifecycle {
    /// Opens the page by the rules of `TerminalStore.openPage`. The row's selection in the sidebar never changes.
    public func openPage(_ url: URL, for context: PaneContext, placement: WebPlacement?) -> WebOpenResult {
        let opened = terminals.openPage(url, for: context, placement: placement)
        return WebOpenResult(page: opened.page.id.description, placement: opened.placement, row: context.rowName)
    }

    /// Pages in one row, or in every row when `rowPath` is nil.
    public func pageInfo(rowPath: String?, repoNames: [String: String]) -> [WebPageInfo] {
        let paths = rowPath.map { [$0] } ?? terminals.rowPaths.sorted()
        return paths.flatMap { path in
            terminals.pages(inRow: path).map { page, placement in
                let context = page.context
                var plugin: String?
                if case .plugin(let id, _) = context.owner { plugin = id }
                return WebPageInfo(
                    page: page.id.description, url: page.url.absoluteString, title: page.displayTitle,
                    placement: placement, repo: context.repoPath.flatMap { repoNames[$0] } ?? context.repoName,
                    plugin: plugin, row: context.rowName, rowPath: path)
            }
        }
    }

    public func closePage(_ id: String) throws {
        guard let pageID = WebPageID(id), terminals.closePage(pageID) else { throw WorkspaceError.pageNotFound(id) }
    }
}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`, changed:

```diff
@@ -32,6 +32,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case waitTimeout([String], String)
     case paneClosed(String)
     case agentStopped(String)
+    case invalidURL(String)
+    case pageNotFound(String)
     case settingsInvalid(String, reason: String)
     case settingsWriteFailed(String, reason: String)
     case configInvalid(String, reason: String)
@@ -98,6 +100,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .waitTimeout: "wait_timeout"
         case .paneClosed: "pane_closed"
         case .agentStopped: "agent_stopped"
+        case .invalidURL: "invalid_url"
+        case .pageNotFound: "page_not_found"
         case .settingsInvalid: "settings_invalid"
         case .settingsWriteFailed: "settings_write_failed"
         case .configInvalid: "config_invalid"
@@ -182,6 +186,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .waitTimeout(let ids, let target):
             "\(ids.joined(separator: ", ")) did not become \(target) before the timeout."
         case .paneClosed(let id): "\(id) closed during the wait."
+        case .invalidURL(let url): "\"\(url)\" is not an http or https URL."
+        case .pageNotFound(let id): "No page \(id). Run `canopy web list --all`."
         case .agentStopped(let id):
             "The agent in \(id) stopped without finishing: it exited, was interrupted, or was set to none."
         case .settingsInvalid(let path, let reason):
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "webPages|webMethods|webOpenRefuses|aPluginRowShowsPages"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: web.open, web.list, and web.close"
```

### Task 6: canopy web and the agent guide

`canopy web open | list | close` speaks the Task 5 methods, with `--tab` and `--panel` for one page, `--repo` and `--row` like `term`, and `--json`.
The agent guide gains a Web Pages section that tells agents to run `canopy web open` after publishing an artifact, and its Activity section names the web events.
The CLI is covered end to end: `make e2e` serves pages from a local server and checks both placements, the same URL twice, every error, the log, and pages coming back after a relaunch.

**Files:**
- Modify: `Sources/CanopyCLI/AgentGuide.swift`
- Modify: `Sources/CanopyCLI/CanopyCLI.swift`
- Create: `Sources/CanopyCLI/WebCommand.swift`
- Modify: `scripts/e2e.sh`

**Interfaces:**
- Consumes: Task 5's methods and types.
- Produces: `WebCommand` with `Open`, `List`, `Close`.

- [ ] **Step 1: Make the change**

`Sources/CanopyCLI/AgentGuide.swift`, changed:

```diff
@@ -118,6 +118,19 @@ struct AgentGuide: ParsableCommand {
         Send to a program you just started once its prompt shows in `term read`: until it reads keys itself, the
         terminal hands it typed-ahead lines together with their Return.
 
+        ## Web pages
+
+            canopy web open <url> [--tab | --panel]       show a page in your row
+            canopy web list [--all]                       ID, where it is, row, title, and URL
+            canopy web close <id>                         close a page, such as w3
+
+        After you publish a claude.ai artifact, run `canopy web open <its url>` so the author sees it in Canopy, next
+        to you, instead of in a browser. `web open` also takes any http or https URL, such as your dev server's.
+        A row shows a page in its panel on the right of the terminals or in a tab of its own, and opens new pages where
+        the author last moved one; `--tab` or `--panel` picks for this page alone. A page the row shows already is shown
+        where it is, so opening it again is safe. `web open` never changes which row the author has selected. A URL that
+        is not http or https fails with invalid_url, and `web close` of a page no row has with page_not_found.
+
         ## Agent state
 
             canopy term state [<id>] <working|waiting|done|none>   report an agent's state, your terminal's by default
@@ -169,7 +182,7 @@ struct AgentGuide: ParsableCommand {
             canopy log [--since <when>] [--until <when>] [--type <t>]   what happened, oldest first
 
         Canopy logs repos and rows coming and going, plugins turning on and off, rows switching branch, PRs opening and
-        changing state, terminals opening and exiting, each command that finishes in a zsh terminal with its exit code
+        changing state, terminals opening and exiting, web pages opening and closing, each command that finishes in a zsh terminal with its exit code
         and duration, and each canopy call that changes something. Each event's source says whether it came from the Canopy window (ui), a
         canopy command (cli), or outside Canopy (git). `--since` defaults to 24 hours ago and takes 30m, 2h, 3d, today,
         yesterday, 2026-09-27, or 2026-09-27T14:30. `--type row` matches every row event, `--type term.command` one.
```

`Sources/CanopyCLI/CanopyCLI.swift`, changed:

```diff
@@ -9,7 +9,8 @@ struct CanopyCLI: AsyncParsableCommand {
         abstract: "Drive Canopy from the command line.",
         version: CanopyVersion.current,
         subcommands: [
-            Status.self, RepoCommand.self, RowCommand.self, GroupCommand.self, TermCommand.self, PortsCommand.self,
+            Status.self, RepoCommand.self, RowCommand.self, GroupCommand.self, TermCommand.self, WebCommand.self,
+            PortsCommand.self,
             PRCommand.self, BranchCommand.self, PluginCommand.self, TicketCommand.self, LogCommand.self,
             HooksCommand.self,
             AgentGuide.self, AgentHookCommand.self,
```

`Sources/CanopyCLI/WebCommand.swift`, new:

```swift
import ArgumentParser
import CanopyCore

struct WebCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "web",
        abstract: "Show web pages, such as claude.ai artifacts, in a row.",
        discussion: """
            A row shows a page in its panel on the right of the terminals, or in a tab of its own. The author moves pages \
            between the two, and new pages open where the author last moved one.
            """,
        subcommands: [Open.self, List.self, Close.self]
    )

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a page in the row you are in.",
            discussion: """
                A page the row shows already is shown where it is. A new page replaces the panel's page, or opens in a \
                new tab. The row stays as it is in the sidebar, so this never takes the author away from another row.
                """
        )

        @Argument(help: "An http or https URL.")
        var url: String
        @Flag(help: "Open it in a tab, whatever the author last chose.")
        var tab = false
        @Flag(help: "Open it in the panel, whatever the author last chose.")
        var panel = false
        @OptionGroup var rowOptions: TermCommand.RowOptions
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if tab && panel { throw ValidationError("Pass --tab or --panel, not both.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let placement: WebPlacement? = tab ? .tab : panel ? .panel : nil
            let result = client.call(
                WebMethod.open, WebOpenParams(target: rowOptions.hint, url: url, placement: placement))
            try client.print(result) {
                let opened = try result.decode(WebOpenResult.self)
                let place = opened.placement == .panel ? "the panel" : "a tab"
                return "Showing \(opened.page) in \(place) of \(opened.row)."
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the pages in the row you are in, or in every row.")

        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Flag(help: "List pages in every row.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(WebMethod.list, WebListParams(target: rowOptions.hint, all: all))
            try client.print(result) {
                let pages = try result.decode([WebPageInfo].self)
                guard !pages.isEmpty else { return "No pages." }
                return Table.render(
                    ["ID", "WHERE", "ROW", "TITLE", "URL"],
                    pages.map { [$0.page, $0.placement.rawValue, $0.row, $0.title, $0.url] })
            }
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a page.")

        @Argument(help: "Page ID, such as w3.")
        var id: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(WebMethod.close, WebCloseParams(page: id), launchIfNeeded: false)
            try client.print(result) { "Closed \(id)." }
        }
    }
}
```

`scripts/e2e.sh`, changed:

```diff
@@ -309,6 +309,61 @@ if "$cli" ports --all --json | grep -q "\"port\" : $port,"; then fail "port $por
 "$cli" term close "$server" >/dev/null
 "$cli" agent-guide | grep -q "canopy ports stop" || fail "agent-guide is missing ports"
 
+step "canopy web opens, lists, and closes pages, in the panel or a tab"
+mkdir -p "$work/site"
+printf '<title>E2E page</title><h1>Hello from e2e</h1>' > "$work/site/index.html"
+printf '<title>Second page</title><p>Two</p>' > "$work/site/two.html"
+# A local server for the pages, which ends by itself after ten minutes.
+(exec /usr/bin/python3 -c '
+import functools, http.server, sys, threading, time
+handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
+server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
+open(sys.argv[2], "w").write(str(server.server_port))
+threading.Thread(target=server.serve_forever, daemon=True).start()
+time.sleep(600)
+' "$work/site" "$work/site-port" </dev/null >/dev/null 2>&1) &
+site_pid=$!
+for _ in $(seq 1 100); do [[ -s "$work/site-port" ]] && break; sleep 0.1; done
+site="http://127.0.0.1:$(cat "$work/site-port")"
+curl -fs "$site/index.html" | grep -q "Hello from e2e" || fail "the test page is not served"
+web_row=(--repo demo --row feat/term)
+"$cli" web open "$site/index.html" "${web_row[@]}" | grep -qx "Showing w1 in the panel of feat/term." ||
+    fail "web open did not open w1 in the panel"
+"$cli" web open "$site/index.html" --tab "${web_row[@]}" | grep -qx "Showing w1 in the panel of feat/term." ||
+    fail "the same URL opened twice did not show the first page"
+"$cli" web open "$site/two.html" --tab "${web_row[@]}" --json > "$work/web-tab.json"
+/usr/bin/python3 -c '
+import json, sys
+assert json.load(open(sys.argv[1])) == {"page": "w2", "placement": "tab", "row": "feat/term"}
+' "$work/web-tab.json" || fail "web open --tab --json said something else"
+"$cli" web list "${web_row[@]}" --json | /usr/bin/python3 -c '
+import json, sys
+pages = json.load(sys.stdin)
+assert [(p["page"], p["placement"], p["url"].rsplit("/", 1)[1]) for p in pages] == [
+    ("w1", "panel", "index.html"), ("w2", "tab", "two.html")], pages
+assert all(p["repo"] == "demo" and p["row"] == "feat/term" for p in pages), pages
+' || fail "web list has the wrong pages"
+"$cli" web list --all | grep -q "^w2 .*tab" || fail "web list --all is missing w2"
+if "$cli" web open "file:///etc/hosts" "${web_row[@]}" --json > "$work/web-bad.json" 2>/dev/null; then
+    fail "expected failure"
+fi
+grep -q '"invalid_url"' "$work/web-bad.json" || fail "a file URL was not invalid_url"
+if "$cli" web open "$site/index.html" --repo demo --row nope --json > "$work/web-row.json" 2>/dev/null; then
+    fail "expected failure"
+fi
+grep -q '"row_not_found"' "$work/web-row.json" || fail "an unknown row was not row_not_found"
+if "$cli" web close w99 --json > "$work/web-gone.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"page_not_found"' "$work/web-gone.json" || fail "an unknown page was not page_not_found"
+"$cli" web close w1 | grep -qx "Closed w1." || fail "web close said something else"
+[[ "$("$cli" web list "${web_row[@]}" --json | /usr/bin/python3 -c 'import json, sys; print([p["page"] for p in json.load(sys.stdin)])')" == "['w2']" ]] ||
+    fail "w1 is still listed"
+"$cli" log --type web --json | /usr/bin/python3 -c '
+import json, sys
+events = [(e["type"], e["data"]["page"], e["source"]) for e in json.load(sys.stdin)]
+assert events == [("web.opened", "w1", "cli"), ("web.opened", "w2", "cli"), ("web.closed", "w1", "cli")], events
+' || fail "canopy log is missing web events"
+"$cli" agent-guide | grep -q "canopy web open <url>" || fail "agent-guide is missing web pages"
+
 step "Claude Code's hooks report into a pane, and agents wait on it"
 agent=$("$cli" term new --repo demo --row feat/term --json |
     /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
@@ -455,10 +510,19 @@ stop_app() {
     [[ -z "$(app_pid)" ]] || fail "the app did not quit"
 }
 
-step "groups and folds come back after a relaunch"
+step "groups, folds, and web pages come back after a relaunch"
 "$cli" group collapse Kept --repo demo >/dev/null
 "$cli" repo collapse demo >/dev/null
+# Layouts save a second after the last change.
+sleep 2
 stop_app
+"$cli" web list --repo demo --row feat/term --json | /usr/bin/python3 -c '
+import json, sys
+pages = json.load(sys.stdin)
+assert [(p["placement"], p["url"].rsplit("/", 1)[1]) for p in pages] == [("tab", "two.html")], pages
+assert pages[0]["page"] != "w2", "a restored page kept an ID a page had before"
+' || fail "web pages did not survive a relaunch"
+kill "$site_pid" 2>/dev/null || true
 "$cli" group list --repo demo --json | /usr/bin/python3 -c '
 import json, sys
 groups = json.load(sys.stdin)
```

- [ ] **Step 2: Run the end-to-end steps**

Run: `make e2e`
Expected: `e2e passed`, including the step "canopy web opens, lists, and closes pages, in the panel or a tab" and the relaunch step.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: canopy web, and the agent guide tells agents to show their artifacts"
```

### Task 7: Navigation rules, Safari's user agent, and the panel's width

A page stays on the site it opened on: navigations there stay, links the author clicks to other sites open in the browser, and redirects and scripts to other sites stay so sign-in works.
A window a script asks for, as Google's sign-in does, becomes a pop-up, and a link the author clicks with a target of its own loads in the page or the browser by its site.
Other schemes are refused, and `about:blank` is allowed, since pop-ups start there.
The user agent is Safari's, from the installed Safari's version, and the panel width keeps between 320 points and two thirds of its room.

**Files:**
- Create: `Sources/CanopyCore/Web/WebNavigation.swift`
- Modify: `Sources/CanopyCore/Web/WebPage.swift`
- Create: `Tests/CanopyCoreTests/WebNavigationTests.swift`
- Modify: `Tests/CanopyCoreTests/WebPageOpenTests.swift`

**Interfaces:**
- Consumes: `WebAddress` from Task 1.
- Produces: `WebNavigation.site(of:)`, `decide(_:site:isLinkClick:) -> .allow | .openInBrowser | .refuse`, `decideNewWindow(_:site:isLinkClick:) -> .popUp | .loadInPage | .openInBrowser | .refuse`; `SafariUserAgent.applicationName(safariVersion:)`; `WebPanelWidth.standard`, `.minimum`, `.clamp(_:available:)`; `WebPage.site`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WebNavigationTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct WebNavigationTests {
    func url(_ text: String) -> URL { URL(string: text)! }

    @Test func aPagesSiteIsItsHostWithoutWWW() {
        #expect(WebNavigation.site(of: url("https://www.claude.ai/artifact/a")) == "claude.ai")
        #expect(WebNavigation.site(of: url("https://Claude.AI/artifact/a")) == "claude.ai")
        #expect(WebNavigation.site(of: url("http://localhost:5173/")) == "localhost")
    }

    @Test func navigationsWithinTheSiteStay() {
        for link in [
            "https://claude.ai/login", "https://www.claude.ai/artifact/b", "https://api.claude.ai/x",
            "http://claude.ai/redirect",
        ] {
            #expect(WebNavigation.decide(url(link), site: "claude.ai", isLinkClick: true) == .allow, "\(link)")
        }
    }

    @Test func linksTheAuthorClicksToOtherSitesGoToTheBrowser() {
        #expect(
            WebNavigation.decide(url("https://github.com/acme"), site: "claude.ai", isLinkClick: true) == .openInBrowser
        )
        #expect(
            WebNavigation.decide(url("https://notclaude.ai/x"), site: "claude.ai", isLinkClick: true) == .openInBrowser)
    }

    @Test func redirectsAndScriptsToOtherSitesStaySoSignInWorks() {
        #expect(
            WebNavigation.decide(url("https://accounts.google.com/o/oauth2"), site: "claude.ai", isLinkClick: false)
                == .allow)
    }

    @Test func otherSchemesAreRefused() {
        for link in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi", "mailto:a@b.c", "x-app://open"] {
            #expect(WebNavigation.decide(url(link), site: "claude.ai", isLinkClick: true) == .refuse, "\(link)")
            #expect(WebNavigation.decide(url(link), site: "claude.ai", isLinkClick: false) == .refuse, "\(link)")
        }
        #expect(WebNavigation.decide(url("about:blank"), site: "claude.ai", isLinkClick: false) == .allow)
    }

    @Test func newWindowsFromScriptsArePopUpsAndFromClicksAreLinks() {
        // Google sign-in opens its window from a script.
        #expect(
            WebNavigation.decideNewWindow(
                url("https://accounts.google.com/o/oauth2"), site: "claude.ai", isLinkClick: false) == .popUp)
        #expect(WebNavigation.decideNewWindow(nil, site: "claude.ai", isLinkClick: false) == .popUp)
        #expect(
            WebNavigation.decideNewWindow(url("https://claude.ai/artifact/b"), site: "claude.ai", isLinkClick: true)
                == .loadInPage)
        #expect(
            WebNavigation.decideNewWindow(url("https://example.com"), site: "claude.ai", isLinkClick: true)
                == .openInBrowser)
        #expect(
            WebNavigation.decideNewWindow(url("file:///etc/hosts"), site: "claude.ai", isLinkClick: true) == .refuse)
    }

    @Test func theUserAgentIsSafarisOwn() {
        #expect(SafariUserAgent.applicationName(safariVersion: "26.6.2") == "Version/26.6.2 Safari/605.1.15")
        #expect(SafariUserAgent.applicationName(safariVersion: nil) == "Version/26.0 Safari/605.1.15")
        #expect(SafariUserAgent.applicationName(safariVersion: "26 beta; x") == "Version/26.0 Safari/605.1.15")
    }

    @Test func thePanelKeepsBetweenItsLimits() {
        #expect(WebPanelWidth.standard == 480)
        #expect(WebPanelWidth.clamp(480, available: 1200) == 480)
        #expect(WebPanelWidth.clamp(100, available: 1200) == 320)
        #expect(WebPanelWidth.clamp(1100, available: 1200) == 800)
        // A narrow window still gets the least width, so the page stays usable.
        #expect(WebPanelWidth.clamp(480, available: 400) == 320)
    }
}
```

`Tests/CanopyCoreTests/WebPageOpenTests.swift`, changed:

```diff
@@ -18,6 +18,7 @@ struct WebPageOpenTests {
 
         #expect(opened.placement == .panel && opened.isNew)
         #expect(opened.page.id.description == "w1")
+        #expect(opened.page.site == "claude.ai")
         #expect(terminals.shownPanel(inRow: dir.path) === opened.page)
         #expect(terminals.tabs(inRow: dir.path).map(\.id) == [tab.id])
     }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: cannot find 'WebNavigation' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Web/WebNavigation.swift`, new:

```swift
import Foundation

/// Where a page's navigations go. A page stays on its own site, and links the author clicks to other sites open in
/// the browser.
public enum WebNavigation {
    public enum Decision: Equatable, Sendable {
        case allow
        case openInBrowser
        case refuse
    }

    public enum WindowDecision: Equatable, Sendable {
        /// A small sheet, as for Google's sign-in, which closes when the page closes it.
        case popUp
        /// A link with a target of its own, on the page's site, loads in the page itself.
        case loadInPage
        case openInBrowser
        case refuse
    }

    /// The host a page opened on, without `www.`, so claude.ai and www.claude.ai are one site.
    public static func site(of url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A navigation of the page's main frame. Navigations to other sites that the author did not click, such as
    /// sign-in redirects, stay in the page.
    public static func decide(_ url: URL, site: String, isLinkClick: Bool) -> Decision {
        if url.absoluteString == "about:blank" { return .allow }
        guard WebAddress.isWeb(url) else { return .refuse }
        return isLinkClick && !isWithin(url, site: site) ? .openInBrowser : .allow
    }

    /// A page asking for a new window, with the URL it names, if any.
    public static func decideNewWindow(_ url: URL?, site: String, isLinkClick: Bool) -> WindowDecision {
        if let url, url.absoluteString != "about:blank", !WebAddress.isWeb(url) { return .refuse }
        guard isLinkClick, let url else { return .popUp }
        return isWithin(url, site: site) ? .loadInPage : .openInBrowser
    }

    static func isWithin(_ url: URL, site: String) -> Bool {
        let host = Self.site(of: url)
        return host == site || host.hasSuffix("." + site)
    }
}

/// Safari's user agent, which Google's sign-in accepts where it refuses ones it reads as embedded web views.
public enum SafariUserAgent {
    /// What WebKit puts after its own part of the user agent, from the installed Safari's version.
    public static func applicationName(safariVersion: String?) -> String {
        let version = safariVersion.flatMap { $0.wholeMatch(of: /\d+(\.\d+)*/) != nil ? $0 : nil } ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }
}

/// The web panel's width, which is the same for every row.
public enum WebPanelWidth {
    public static let standard = 480.0
    public static let minimum = 320.0

    /// At least the minimum, and at most two thirds of the width beside the row's plugin panel, if any.
    public static func clamp(_ width: Double, available: Double) -> Double {
        min(max(width, minimum), max(minimum, available * 2 / 3))
    }
}
```

`Sources/CanopyCore/Web/WebPage.swift`, changed:

```diff
@@ -36,6 +36,8 @@ public final class WebPage: Identifiable {
     public internal(set) var context: PaneContext
     /// The address it opened with, which still finds it after it moves on, as to claude.ai's sign-in.
     public let openedURL: URL
+    /// The site it opened on, which it stays on. Links the author clicks to other sites open in the browser.
+    public let site: String
 
     init(id: WebPageID, url: URL, title: String, context: PaneContext) {
         self.id = id
@@ -43,6 +45,7 @@ public final class WebPage: Identifiable {
         self.title = title
         self.context = context
         self.openedURL = url
+        self.site = WebNavigation.site(of: url)
     }
 
     /// Whether the page is at `url`, or opened with it.
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "WebNavigationTests|WebPageOpenTests"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: pages stay on their site, as Safari, in a panel of bounded width"
```

### Task 8: ⌘-clicked terminal links

`TerminalEmulator` gains `onOpenLink`, which `SwiftTermEmulator` calls from SwiftTerm's `requestOpenLink` instead of SwiftTerm's own opening.
The pane passes the link to the store, which opens an artifact in the pane's row and tells the app where anything else goes.
The app selects the row for an artifact, hands web links to `openInBrowser`, which `CANOPY_OPENED_URLS` captures in debug builds, and opens file paths as SwiftTerm did.

**Files:**
- Modify: `Sources/CanopyApp/AppModel.swift`
- Modify: `Sources/CanopyApp/Terminal/SwiftTermEmulator.swift`
- Modify: `Sources/CanopyCore/Terminal/Pane.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalEmulator.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore+Web.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore.swift`
- Modify: `Tests/CanopyCoreTests/Support/FakeTerminal.swift`
- Modify: `Tests/CanopyCoreTests/WebPageOpenTests.swift`
- Modify: `Tests/CanopyTicketsTests/Support/TicketsHarness.swift`

**Interfaces:**
- Consumes: `TerminalLink` from Task 1 and `openPage` from Task 2.
- Produces: `TerminalEmulator.onOpenLink`, `Pane.onOpenLink`, `TerminalStore.onFollowLink: (Pane, TerminalLink) -> Void`, `followLink(_:from:) -> TerminalLink`; `AppModel.openInBrowser(_:)`, `SwiftTermEmulator.openPath(_:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/Support/FakeTerminal.swift`, changed:

```diff
@@ -9,6 +9,7 @@ final class FakeEmulator: TerminalEmulator {
     var onInput: ((Data) -> Void)?
     var onResize: ((TerminalSize) -> Void)?
     var onTitle: ((String) -> Void)?
+    var onOpenLink: ((String) -> Void)?
     private(set) var shown = Data()
 
     var text: String { String(decoding: shown, as: UTF8.self) }
@@ -35,6 +36,11 @@ final class FakeEmulator: TerminalEmulator {
     func type(_ text: String) {
         onInput?(Data(text.utf8))
     }
+
+    /// The author ⌘-clicking a link in the terminal.
+    func click(link: String) {
+        onOpenLink?(link)
+    }
 }
 
 struct FakeEngine: TerminalEngine {
```

`Tests/CanopyCoreTests/WebPageOpenTests.swift`, changed:

```diff
@@ -180,3 +180,30 @@ struct WebPageMovedOnTests {
         #expect(terminals.shownPanel(inRow: dir.path) === page)
     }
 }
+
+@MainActor
+struct TerminalLinkClickTests {
+    @Test func anArtifactClickedInATerminalOpensInItsRow() throws {
+        let dir = try TempDir()
+        let terminals = Fixture.terminals(dir)
+        defer { terminals.closeAll() }
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
+        var followed: [TerminalLink] = []
+        terminals.onFollowLink = { from, route in
+            #expect(from === pane)
+            followed.append(route)
+        }
+
+        pane.screen.click(link: "https://claude.ai/artifact/a1")
+        pane.screen.click(link: "https://github.com/acme/app/pull/7")
+        pane.screen.click(link: "file:///etc/hosts")
+
+        #expect(terminals.shownPanel(inRow: dir.path)?.url.absoluteString == "https://claude.ai/artifact/a1")
+        #expect(terminals.pages(inRow: dir.path).count == 1)
+        #expect(
+            followed == [
+                .artifact(URL(string: "https://claude.ai/artifact/a1")!),
+                .browser(URL(string: "https://github.com/acme/app/pull/7")!), .refused,
+            ])
+    }
+}
```

`Tests/CanopyTicketsTests/Support/TicketsHarness.swift`, changed:

```diff
@@ -31,6 +31,7 @@ final class QuietEmulator: TerminalEmulator {
     var onInput: ((Data) -> Void)?
     var onResize: ((TerminalSize) -> Void)?
     var onTitle: ((String) -> Void)?
+    var onOpenLink: ((String) -> Void)?
     func feed(_ data: Data) {}
     func screenText() -> String { "" }
     func recentText(lines: Int) -> String { "" }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests $(scripts/test-flags.sh)`
Expected: the build fails with `error: value of type 'FakeEmulator' has no member 'click'`.

- [ ] **Step 3: Implement it**

`Sources/CanopyApp/AppModel.swift`, changed:

```diff
@@ -95,6 +95,7 @@ final class AppModel {
         plugins.ui = bridge
         plugins.onNotice = { [weak self] in self?.show($0) }
         plugins.onClosingRows = { [weak self] in self?.setAside($0) }
+        terminals.onFollowLink = { [weak self] pane, route in self?.followed(route, from: pane) }
         updateViewing()
         // Before layouts are restored, so a plugin row's folder deleted outside Canopy is back for its shells.
         await plugins.start()
@@ -493,8 +494,35 @@ final class AppModel {
 
     /// Only web links open: text a server sends, such as an error, could hold links of any kind.
     func open(_ url: URL) -> OpenURLAction.Result {
-        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
-        guard let openedURLsFile else { return .systemAction }
+        guard WebAddress.isWeb(url) else { return .discarded }
+        guard openedURLsFile != nil else { return .systemAction }
+        recordOpened(url)
+        return .handled
+    }
+
+    /// Opens a web link in the default browser, as `open` does for SwiftUI's links.
+    func openInBrowser(_ url: URL) {
+        guard WebAddress.isWeb(url) else { return }
+        if openedURLsFile != nil {
+            recordOpened(url)
+        } else {
+            NSWorkspace.shared.open(url)
+        }
+    }
+
+    /// A link ⌘-clicked in a terminal, after the terminals opened an artifact in the pane's row.
+    private func followed(_ route: TerminalLink, from pane: Pane) {
+        switch route {
+        case .artifact:
+            if selectedRowPath != pane.context.rowPath { reveal(pane.context.rowPath) }
+        case .browser(let url): openInBrowser(url)
+        case .path(let path): SwiftTermEmulator.openPath(path)
+        case .refused: break
+        }
+    }
+
+    private func recordOpened(_ url: URL) {
+        guard let openedURLsFile else { return }
         let line = Data((url.absoluteString + "\n").utf8)
         if let handle = FileHandle(forWritingAtPath: openedURLsFile) {
             handle.seekToEndOfFile()
@@ -503,7 +531,6 @@ final class AppModel {
         } else {
             FileManager.default.createFile(atPath: openedURLsFile, contents: line)
         }
-        return .handled
     }
 
     /// Panel widths as dragged in this session, which the saved ones catch up with.
```

`Sources/CanopyApp/Terminal/SwiftTermEmulator.swift`, changed:

```diff
@@ -39,6 +39,7 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
     var onInput: ((Data) -> Void)?
     var onResize: ((TerminalSize) -> Void)?
     var onTitle: ((String) -> Void)?
+    var onOpenLink: ((String) -> Void)?
 
     init(size: TerminalSize) {
         terminalView = TerminalView(
@@ -139,6 +140,16 @@ final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency Termi
 
     func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
 
+    /// A file path ⌘-clicked in a terminal opens with its app, as SwiftTerm opens it.
+    static func openPath(_ path: String) {
+        TerminalView.openDefaultLink(path)
+    }
+
+    /// ⌘-click. The pane's row decides where the link goes.
+    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
+        onOpenLink?(link)
+    }
+
     /// OSC 52, which editors and tmux use to copy.
     func clipboardCopy(source: TerminalView, content: Data) {
         guard let text = String(data: content, encoding: .utf8) else { return }
```

`Sources/CanopyCore/Terminal/Pane.swift`, changed:

```diff
@@ -39,6 +39,8 @@ public final class Pane: Identifiable {
     @ObservationIgnored public var onAgentChange: ((Pane, AgentChange) -> Void)?
     /// Called when the pane closes for good, before its agent state clears.
     @ObservationIgnored public var onClose: ((Pane) -> Void)?
+    /// Called with a link the author ⌘-clicked in the terminal.
+    @ObservationIgnored public var onOpenLink: ((Pane, String) -> Void)?
     /// When a key was last typed or text sent. Kept out of observation, so typing redraws no dot.
     @ObservationIgnored public private(set) var lastInput = Date.distantPast
 
@@ -63,6 +65,10 @@ public final class Pane: Identifiable {
         emulator.onInput = { [weak self] in self?.input($0) }
         emulator.onResize = { [weak self] in self?.process?.resize($0) }
         emulator.onTitle = { [weak self] in self?.setProgramTitle($0) }
+        emulator.onOpenLink = { [weak self] link in
+            guard let self else { return }
+            self.onOpenLink?(self, link)
+        }
         start(command)
     }
 
```

`Sources/CanopyCore/Terminal/TerminalEmulator.swift`, changed:

```diff
@@ -12,6 +12,8 @@ public protocol TerminalEmulator: AnyObject {
     var onResize: ((TerminalSize) -> Void)? { get set }
     /// Called when the running program sets the title.
     var onTitle: ((String) -> Void)? { get set }
+    /// Called with a link the author ⌘-clicked: a URL, or a path the emulator found in the text.
+    var onOpenLink: ((String) -> Void)? { get set }
     /// Shows what the process wrote.
     func feed(_ data: Data)
     /// The visible screen as plain text, one line per row, without trailing blank lines.
```

`Sources/CanopyCore/Terminal/TerminalStore+Web.swift`, changed:

```diff
@@ -132,6 +132,16 @@ extension TerminalStore {
         if changed { onChange() }
     }
 
+    /// Opens an artifact link ⌘-clicked in a pane in the pane's row. Returns where the link goes.
+    @discardableResult
+    public func followLink(_ link: String, from pane: Pane) -> TerminalLink {
+        let route = TerminalLink(link)
+        if case .artifact(let url) = route {
+            openPage(url, for: pane.context)
+        }
+        return route
+    }
+
     public func setPanelHidden(_ hidden: Bool, inRow path: String) {
         guard panelsByRow[path] != nil, panelsByRow[path]?.isHidden != hidden else { return }
         panelsByRow[path]?.isHidden = hidden
```

`Sources/CanopyCore/Terminal/TerminalStore.swift`, changed:

```diff
@@ -121,6 +121,9 @@ public final class TerminalStore {
     }
     /// Called when a pane's agent finishes or needs the author, unless the author is focused on that pane.
     @ObservationIgnored public var onAgentAlert: (Pane, AgentState) -> Void = { _, _ in }
+    /// Called after a link ⌘-clicked in a pane was followed, with where it went. An artifact is open in the pane's row
+    /// by then, and the app hands anything else to the browser or the file's app.
+    @ObservationIgnored public var onFollowLink: (Pane, TerminalLink) -> Void = { _, _ in }
     /// Called when a page leaves its row, so the app can drop its web view.
     @ObservationIgnored public var onPageClosed: (WebPageID) -> Void = { _ in }
     @ObservationIgnored private var agentObservers: [UUID: (AgentEvent) -> Void] = [:]
@@ -541,6 +544,10 @@ public final class TerminalStore {
             emulator: engine.makeEmulator(size: preferredSize), activity: activity, directory: directory)
         pane.onAgentChange = { [weak self] in self?.agentChanged($0, $1) }
         pane.onClose = { [weak self] in self?.notifyAgentObservers(.closed($0)) }
+        pane.onOpenLink = { [weak self] pane, link in
+            guard let self else { return }
+            self.onFollowLink(pane, self.followLink(link, from: pane))
+        }
         return pane
     }
 
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift build --build-tests $(scripts/test-flags.sh) && swift test $(scripts/test-flags.sh) --skip-build --filter "TerminalLinkClickTests"`
Expected: every test passes, and `make lint` and `swift build` report nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: ⌘-clicking an artifact link opens it in the terminal's row"
```

### Task 9: The panel and web tabs in the window

`WebViews` keeps one `WKWebView` per page, made from one configuration with the persistent default data store and Safari's user agent, and drops it when the page closes.
Its controller applies Task 7's rules, refuses downloads, shows WebKit's error with Reload, opens pop-ups in a sheet that closes when the page closes it, and reports each page's title and address to the store.
The panel sits right of the terminals in worktree and plugin rows, with a divider that drags its width and stays above its neighbours so both halves of the grip take the drag.
Its header is drawn in the title bar row beside the top bar, at the top bar's height, and a web tab shows the same header, at 30 points, under the top bar.
A web tab's item shows a globe and cannot be renamed, Split Pane dims in a web tab, ⌘W closes a web tab's page, and View > Show or Hide Web Panel is ⌥⌘0.
There is no unit test for views; Task 10's fixture and window shots check them.

**Files:**
- Modify: `Sources/CanopyApp/AppModel.swift`
- Modify: `Sources/CanopyApp/CanopyApp.swift`
- Modify: `Sources/CanopyApp/Plugins/PluginDetailView.swift`
- Modify: `Sources/CanopyApp/RootView.swift`
- Modify: `Sources/CanopyApp/Style/Style.swift`
- Modify: `Sources/CanopyApp/Terminal/RowTerminalsView.swift`
- Modify: `Sources/CanopyApp/Terminal/TopBarView.swift`
- Create: `Sources/CanopyApp/Web/WebPageViews.swift`
- Create: `Sources/CanopyApp/Web/WebViews.swift`

**Interfaces:**
- Consumes: Tasks 2 to 8.
- Produces: `WebViews`, `WebPageController`, `CanopyWebView`; `WebPageView`, `WebHeader`, `WebTabView`, `WebPanelHeader`, `WebPanelSplit`, `WebPopUpSheet`, `WebPopUp`; `PanelDivider(width:side:onDrag:onEnd:)`; `AppModel.webViews`, `webPopUp`, `canSplit`, `webPanelWidth(available:)`, `dragWebPanel(to:)`, `endWebPanelDrag(available:)`, `selectedPanel`, `toggleWebPanel()`, `dismissPopUp(_:)`; `Style.webTabHeaderHeight`.

- [ ] **Step 1: Make the change**

`Sources/CanopyApp/AppModel.swift`, changed:

```diff
@@ -3,6 +3,7 @@ import CanopyCore
 import Foundation
 import Observation
 import SwiftUI
+import WebKit
 
 @MainActor
 @Observable
@@ -15,6 +16,8 @@ final class AppModel {
     /// The app's one list of built-in plugins, with the panel each draws.
     let builtInPlugins: [BuiltInPlugin]
     let activity: ActivityLog
+    /// Every web page's web view, kept while the page is in its row.
+    let webViews = WebViews()
     private(set) var snapshot = WorkspaceSnapshot()
     private(set) var toast: String?
     var selectedRowPath: String? {
@@ -54,6 +57,7 @@ final class AppModel {
             workspace: workspace, terminals: terminals, plugins: builtInPlugins.map(\.plugin),
             secrets: KeychainSecretStore(), bundleID: Bundle.main.bundleIdentifier ?? "com.ne1nn.Canopy",
             trash: BuiltInPlugins.trash(environment: environment))
+        connectWebViews()
     }
 
     /// The bundle's folder holding `canopy`, which terminals get on their PATH.
@@ -103,6 +107,7 @@ final class AppModel {
         terminals.continueNumbering(from: await workspace.savedNextPane)
         terminals.continueWebNumbering(from: await workspace.savedNextWebPage)
         terminals.webPlacement = await workspace.savedWebPlacement
+        savedWebPanelWidth = await workspace.webPanelWidth
         snapshot = await workspace.snapshot
         restoreTerminals(saved)
         let updates = await workspace.updates()
@@ -807,10 +812,15 @@ final class AppModel {
             height: 5 * cell.height + padding.top + padding.bottom + PaneHeader.height)
     }
 
+    /// Split Pane does nothing in a web tab.
+    var canSplit: Bool {
+        canOpenTerminal && selectedTab?.page == nil
+    }
+
     /// ⌘D and the tab bar's split button.
     /// Adds a pane by the add rule, keeping panes at least `minPaneColumns` wide on a line.
     func splitPane() {
-        guard canOpenTerminal, let row = selection else { return }
+        guard canSplit, let row = selection else { return }
         withFolder(of: row) {
             self.terminals.addPane(for: self.context(for: row), fits: self.addRuleFits())
             self.focusSelectedTerminal()
@@ -911,17 +921,28 @@ final class AppModel {
         }
     }
 
-    /// ⌘W. Only for the main window itself, so it never closes a terminal behind a sheet or a closed window.
+    /// ⌘W: the focused terminal, or the page of a web tab. Only for the main window itself, so it never closes
+    /// anything behind a sheet or a closed window.
     func closeFocusedPane() {
         guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
-            let pane = selectedTab?.focused
+            let row = selection, let tab = selectedTab
         else { return }
-        requestClose(pane)
+        if let pane = tab.focused {
+            requestClose(pane)
+        } else {
+            terminals.closeTab(tab.id, inRow: row.path)
+            focusSelectedTerminal()
+        }
     }
 
-    /// Hands the keyboard back to the terminal on screen, as after renaming a tab.
+    /// Hands the keyboard back to the terminal or page on screen, as after renaming a tab.
     func focusSelectedTerminal() {
-        (selectedTab?.focused?.emulator as? SwiftTermEmulator)?.focus()
+        if let page = selectedTab?.page {
+            let webView = webViews.existing(page.id)?.webView
+            webView?.window?.makeFirstResponder(webView)
+        } else {
+            (selectedTab?.focused?.emulator as? SwiftTermEmulator)?.focus()
+        }
     }
 
     func selectTab(offset: Int) {
@@ -929,6 +950,57 @@ final class AppModel {
         terminals.selectTab(offset: offset, inRow: row.path)
     }
 
+    // MARK: Web pages
+
+    /// A page's window of its own showing in a sheet, such as Google's sign-in.
+    var webPopUp: WebPopUp?
+    private(set) var draggedWebPanelWidth: Double?
+    private var savedWebPanelWidth: Double?
+
+    private func connectWebViews() {
+        webViews.onNavigated = { [weak self] id, url, title in self?.terminals.pageNavigated(id, url: url, title: title)
+        }
+        webViews.openInBrowser = { [weak self] in self?.openInBrowser($0) }
+        webViews.presentPopUp = { [weak self] webView, owner in
+            self?.webPopUp = WebPopUp(webView: webView, owner: owner)
+        }
+        webViews.dismissPopUp = { [weak self] in self?.dismissPopUp($0) }
+        terminals.onPageClosed = { [weak self] in self?.webViews.drop($0) }
+    }
+
+    func dismissPopUp(_ webView: WKWebView) {
+        guard webPopUp?.webView === webView else { return }
+        webPopUp = nil
+    }
+
+    /// The panel's width, which every row shares: as dragged, else as saved, else the standard, within its limits for
+    /// the room beside the row's plugin panel, if any.
+    func webPanelWidth(available: Double) -> Double {
+        WebPanelWidth.clamp(draggedWebPanelWidth ?? savedWebPanelWidth ?? WebPanelWidth.standard, available: available)
+    }
+
+    func dragWebPanel(to width: Double) {
+        draggedWebPanelWidth = width
+    }
+
+    /// Saves the width the drag ended at, as it was shown.
+    func endWebPanelDrag(available: Double) {
+        let width = webPanelWidth(available: available)
+        draggedWebPanelWidth = width
+        savedWebPanelWidth = width
+        perform { try await $0.setWebPanelWidth(width) }
+    }
+
+    /// The selected row's panel, for View > Show or Hide Web Panel.
+    var selectedPanel: WebPanel? {
+        selection.flatMap { terminals.panel(inRow: $0.path) }
+    }
+
+    func toggleWebPanel() {
+        guard let row = selection, let panel = terminals.panel(inRow: row.path) else { return }
+        terminals.setPanelHidden(!panel.isHidden, inRow: row.path)
+    }
+
     // MARK: Repos
 
     enum FolderRequest {
```

`Sources/CanopyApp/CanopyApp.swift`, changed:

```diff
@@ -81,14 +81,21 @@ struct TerminalCommands: Commands {
                 .disabled(!model.canOpenTerminal)
             Button("Split Pane", action: model.splitPane)
                 .keyboardShortcut("d")
-                .disabled(!model.canOpenTerminal)
+                .disabled(!model.canSplit)
         }
         // Replacing the save group also drops File > Close, so ⌘W closes a terminal rather than the window.
         CommandGroup(replacing: .saveItem) {
-            Button("Close Terminal", action: model.closeFocusedPane)
+            Button(model.selectedTab?.page == nil ? "Close Terminal" : "Close Page", action: model.closeFocusedPane)
                 .keyboardShortcut("w")
                 .disabled(model.selectedTab == nil)
         }
+        CommandGroup(after: .sidebar) {
+            Button(model.selectedPanel?.isHidden == false ? "Hide Web Panel" : "Show Web Panel") {
+                model.toggleWebPanel()
+            }
+            .keyboardShortcut("0", modifiers: [.command, .option])
+            .disabled(model.selectedPanel == nil)
+        }
         CommandGroup(before: .windowArrangement) {
             // ⌘⇧[ reaches the menu as "{", so the shortcuts are declared by the character the keys type.
             Button("Show Previous Tab") { model.selectTab(offset: -1) }
```

`Sources/CanopyApp/Plugins/PluginDetailView.swift`, changed:

```diff
@@ -17,12 +17,14 @@ struct PluginDetailView: View {
             HStack(spacing: 0) {
                 PluginPanelColumn(row: row)
                     .frame(width: width)
-                PanelDivider(width: width) {
+                PanelDivider(width: width, side: .leading) {
                     model.dragPanel(row.plugin, to: $0)
                 } onEnd: {
                     model.endPanelDrag(row.plugin, detailWidth: geometry.size.width)
                 }
-                TerminalArea(path: row.path, name: row.displayName)
+                WebPanelSplit(path: row.path) {
+                    TerminalArea(path: row.path, name: row.displayName)
+                }
             }
         }
         // In a window the panel and the top bar take the title bar's row.
@@ -91,9 +93,15 @@ struct PanelTitleStrip: View {
     }
 }
 
-/// The line between the panel and the terminals, with a wider grip that drags the panel's width.
-private struct PanelDivider: View {
+/// The line between a panel and the terminals, with a wider grip that drags the panel's width. A panel on the trailing
+/// side grows as the line moves left.
+struct PanelDivider: View {
+    enum Side {
+        case leading, trailing
+    }
+
     let width: Double
+    let side: Side
     let onDrag: (Double) -> Void
     let onEnd: () -> Void
     @State private var startWidth: Double?
@@ -112,7 +120,7 @@ private struct PanelDivider: View {
                             .onChanged { value in
                                 let start = startWidth ?? width
                                 startWidth = start
-                                onDrag(start + value.translation.width)
+                                onDrag(start + (side == .leading ? 1 : -1) * value.translation.width)
                             }
                             .onEnded { _ in
                                 startWidth = nil
@@ -120,6 +128,8 @@ private struct PanelDivider: View {
                             }
                     )
             }
+            // Above its neighbors, so the half of the grip over a terminal or a page still takes the drag.
+            .zIndex(1)
             .accessibilityHidden(true)
     }
 }
```

`Sources/CanopyApp/RootView.swift`, changed:

```diff
@@ -56,6 +56,9 @@ struct RootView: View {
         .sheet(item: $model.setupSheet) { request in
             request.setup.sheet()
         }
+        .sheet(item: $model.webPopUp) { popUp in
+            WebPopUpSheet(popUp: popUp)
+        }
         .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             model.refresh()
         }
@@ -143,8 +146,20 @@ struct TitleBarRow: View {
             TopBarView(
                 row: row, isSidebarHidden: isSidebarHidden,
                 windowControlsOverBar: placement.windowControlsOverBar && row.pluginRow == nil)
+            if let page = model.terminals.shownPanel(inRow: row.path) {
+                Rectangle().fill(.separator).frame(width: PluginDetailView.dividerWidth, height: Style.topBarHeight)
+                WebPanelHeader(page: page, path: row.path)
+                    .frame(width: model.webPanelWidth(available: webPanelRoom))
+            }
         }
     }
+
+    /// The width beside a plugin row's panel, where the terminals and the web panel share the room.
+    private var webPanelRoom: Double {
+        guard let pluginRow = row.pluginRow else { return detailWidth }
+        return detailWidth - model.panelWidth(for: pluginRow.plugin, detailWidth: detailWidth)
+            - PluginDetailView.dividerWidth
+    }
 }
 
 struct RowDetailView: View {
```

`Sources/CanopyApp/Style/Style.swift`, changed:

```diff
@@ -23,6 +23,7 @@ enum Style {
     static let windowControlsWidth = 150.0
     static let tabHeight = 26.0
     static let paneHeaderHeight = 26.0
+    static let webTabHeaderHeight = 30.0
 
     /// One step of the sidebar's tree: a mark's width and its gap, so a line's mark sits under its header's name.
     private static let indentStep = 24.0
```

`Sources/CanopyApp/Terminal/RowTerminalsView.swift`, changed:

```diff
@@ -19,9 +19,11 @@ struct RowTerminalsView: View {
                 }
             }
         } else {
-            TerminalArea(path: row.path, name: row.displayName)
-                // In a window the top bar takes the title bar's row. The title bar is hidden, so clicks reach it.
-                .ignoresSafeArea(.container, edges: topBarFillsTitleBar ? .top : [])
+            WebPanelSplit(path: row.path) {
+                TerminalArea(path: row.path, name: row.displayName)
+            }
+            // In a window the top bar takes the title bar's row. The title bar is hidden, so clicks reach it.
+            .ignoresSafeArea(.container, edges: topBarFillsTitleBar ? .top : [])
         }
     }
 }
@@ -36,11 +38,12 @@ struct TerminalArea: View {
         VStack(spacing: 0) {
             Color.clear.frame(height: Style.topBarHeight)
             if let tab = model.terminals.selectedTab(inRow: path) {
-                if let grid = tab.grid {
+                switch tab.content {
+                case .terminals(let grid):
                     GridView(grid: grid)
                         .id(tab.id)
-                } else {
-                    Spacer()
+                case .web(let page):
+                    WebTabView(tab: tab, page: page, path: path)
                 }
             } else {
                 ContentUnavailableView {
```

`Sources/CanopyApp/Terminal/TopBarView.swift`, changed:

```diff
@@ -47,7 +47,9 @@ struct TopBarView: View {
             }
             IconButton(
                 title: "Split Pane", systemImage: "rectangle.split.2x1", shortcut: "⌘D", size: 26, imageSize: 13,
-                action: model.splitPane)
+                action: model.splitPane
+            )
+            .disabled(!model.canSplit)
             IconButton(
                 title: "New Tab", systemImage: "plus", shortcut: "⌘T", size: 26, imageSize: 13, action: model.newTab)
         }
@@ -178,6 +180,8 @@ struct TabItemView: View {
         .onHover { isHovering = $0 }
         .gesture(
             TapGesture(count: 2).onEnded {
+                // A web tab is named after its page.
+                guard tab.grid != nil else { return }
                 draft = tab.name
                 isRenaming = true
             }
```

`Sources/CanopyApp/Web/WebPageViews.swift`, new:

```swift
import AppKit
import CanopyCore
import SwiftUI
import WebKit

/// A page's web view, with WebKit's error and Reload over it when the page failed to load. The web view belongs to the
/// page, so it keeps its state while the page moves or is out of view.
struct WebPageView: View {
    @Environment(AppModel.self) private var model
    let page: CanopyCore.WebPage

    var body: some View {
        let controller = model.webViews.controller(for: page)
        WebViewHost(webView: controller.webView)
            .overlay {
                if let error = controller.error {
                    ContentUnavailableView {
                        Label("Page Did Not Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Reload", action: controller.reload)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Style.panelBackground)
                }
            }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewContainer {
        WebViewContainer(webView: webView)
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.adopt(webView)
    }

    static func dismantleNSView(_ container: WebViewContainer, coordinator: ()) {
        container.release()
    }
}

/// Holds a web view that may move to another container, as when its page moves between the panel and a tab.
final class WebViewContainer: NSView {
    private var webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        adopt(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func adopt(_ webView: WKWebView) {
        if self.webView !== webView { release() }
        self.webView = webView
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    func release() {
        if webView.superview === self { webView.removeFromSuperview() }
    }
}

/// What sits above a page, in the panel and in a web tab: its title, Reload, Open in Browser, the move, and Close.
struct WebHeader: View {
    @Environment(AppModel.self) private var model
    let page: CanopyCore.WebPage
    let placement: WebPlacement
    let onMove: () -> Void
    let onClose: () -> Void

    var body: some View {
        let controller = model.webViews.controller(for: page)
        let isLoading = controller.isLoading
        HStack(spacing: 2) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.trailing, 4)
            Text(isLoading ? (page.url.host() ?? page.displayTitle) : page.displayTitle)
                .font(Style.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(page.url.absoluteString)
            Spacer(minLength: 8)
            IconButton(title: "Reload", systemImage: "arrow.clockwise", shortcut: "⌘R", action: controller.reload)
            IconButton(title: "Open in Browser", systemImage: "safari") {
                model.openInBrowser(controller.webView.url ?? page.url)
            }
            IconButton(
                title: placement == .panel ? "Move to Tab" : "Move to Panel",
                systemImage: placement == .panel ? "menubar.rectangle" : "sidebar.right", action: onMove)
            IconButton(title: placement == .panel ? "Close Panel" : "Close Page", systemImage: "xmark", action: onClose)
        }
        .padding(.leading, placement == .panel ? 14 : 10)
        .padding(.trailing, placement == .panel ? Style.topBarInset : 5)
    }
}

/// A web tab's page under its header.
struct WebTabView: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab
    let page: CanopyCore.WebPage
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            WebHeader(
                page: page, placement: .tab,
                onMove: { model.terminals.moveTabToPanel(tab.id, inRow: path) },
                onClose: { model.terminals.closeTab(tab.id, inRow: path) }
            )
            .frame(height: Style.webTabHeaderHeight)
            .background(Style.chrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 1)
            }
            WebPageView(page: page)
        }
    }
}

/// The panel's header, level with the top bar in the title bar's row, which RootView draws over the window. Its empty
/// space moves the window like a title bar.
struct WebPanelHeader: View {
    @Environment(AppModel.self) private var model
    let page: CanopyCore.WebPage
    let path: String

    var body: some View {
        WebHeader(
            page: page, placement: .panel,
            onMove: { model.terminals.movePanelPageToTab(inRow: path) },
            onClose: { model.terminals.closePanel(inRow: path) }
        )
        .frame(height: Style.topBarHeight)
        .background {
            TitleBarArea()
                .background(Style.chrome)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

/// The row's terminals, with its panel page on the right while the panel shows.
struct WebPanelSplit<Content: View>: View {
    @Environment(AppModel.self) private var model
    let path: String
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content
                if let page = model.terminals.shownPanel(inRow: path) {
                    let width = model.webPanelWidth(available: geometry.size.width)
                    PanelDivider(width: width, side: .trailing) {
                        model.dragWebPanel(to: $0)
                    } onEnd: {
                        model.endWebPanelDrag(available: geometry.size.width)
                    }
                    VStack(spacing: 0) {
                        // Room for the panel's header, which RootView draws beside the top bar.
                        Color.clear.frame(height: Style.topBarHeight)
                        WebPageView(page: page)
                    }
                    .frame(width: width)
                    .background(Style.panelBackground)
                }
            }
        }
    }
}

/// A page's window of its own, such as Google's sign-in, in a sheet that closes when the page closes it.
struct WebPopUpSheet: View {
    @Environment(AppModel.self) private var model
    let popUp: WebPopUp

    var body: some View {
        VStack(spacing: 0) {
            WebViewHost(webView: popUp.webView)
                .frame(minWidth: 480, idealWidth: 500, minHeight: 560, idealHeight: 640)
            Divider()
            HStack {
                Text(popUp.webView.url?.host() ?? "")
                    .font(Style.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { model.dismissPopUp(popUp.webView) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onDisappear { popUp.owner.popUpDismissed(popUp.webView) }
    }
}

struct WebPopUp: Identifiable {
    let id = UUID()
    let webView: WKWebView
    /// The page that asked for it.
    let owner: WebPageController
}
```

`Sources/CanopyApp/Web/WebViews.swift`, new:

```swift
import AppKit
import CanopyCore
import Observation
import WebKit

/// Every page's web view, made the first time the page shows and kept until it closes, so moving a page between the
/// panel and a tab, or switching away and back, keeps its scroll position and state. WebKit names a type `WebPage` too,
/// so this file says `CanopyCore.WebPage` for Canopy's.
@MainActor
final class WebViews {
    private var controllers: [WebPageID: WebPageController] = [:]
    /// One configuration for every page, so they share the persistent website data, and a sign-in with them.
    private let configuration: WKWebViewConfiguration
    /// Where a page's web view went and what it is called now.
    var onNavigated: (WebPageID, URL?, String?) -> Void = { _, _, _ in }
    var openInBrowser: (URL) -> Void = { _ in }
    /// A page asked for a window of its own, such as Google's sign-in.
    var presentPopUp: (WKWebView, WebPageController) -> Void = { _, _ in }
    var dismissPopUp: (WKWebView) -> Void = { _ in }

    init() {
        configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let safari = Bundle(path: "/Applications/Safari.app")?.object(
            forInfoDictionaryKey: "CFBundleShortVersionString")
        configuration.applicationNameForUserAgent = SafariUserAgent.applicationName(safariVersion: safari as? String)
    }

    /// The page's controller, made and loaded on first use.
    func controller(for page: CanopyCore.WebPage) -> WebPageController {
        if let controller = controllers[page.id] { return controller }
        let controller = WebPageController(page: page, configuration: configuration, owner: self)
        controllers[page.id] = controller
        return controller
    }

    /// The controller of a page that has shown, without making one.
    func existing(_ id: WebPageID) -> WebPageController? {
        controllers[id]
    }

    func drop(_ id: WebPageID) {
        controllers.removeValue(forKey: id)?.close()
    }
}

/// One page's web view and what the header shows about it.
@MainActor
@Observable
final class WebPageController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let pageID: WebPageID
    private let site: String
    @ObservationIgnored let webView: CanopyWebView
    private(set) var isLoading = false
    /// WebKit's description of why the page failed to load, until it loads again.
    private(set) var error: String?
    @ObservationIgnored private weak var owner: WebViews?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var popUps: [WKWebView] = []

    init(page: CanopyCore.WebPage, configuration: WKWebViewConfiguration, owner: WebViews) {
        pageID = page.id
        site = page.site
        self.owner = owner
        webView = CanopyWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.navigated(url: nil, title: webView.title) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.navigated(url: webView.url, title: nil) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
        ]
        webView.load(URLRequest(url: page.url))
    }

    func reload() {
        error = nil
        if webView.url == nil, let url = webView.backForwardList.currentItem?.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    fileprivate func close() {
        observations = []
        for popUp in popUps {
            owner?.dismissPopUp(popUp)
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func navigated(url: URL?, title: String?) {
        // Pages that are not web addresses, such as about:blank, never replace the page's own.
        let url = url.flatMap { WebAddress.isWeb($0) ? $0 : nil }
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        guard url != nil || title != nil else { return }
        owner?.onNavigated(pageID, url, title)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        // Frames inside the page, such as an artifact's sandbox, are the page's own business.
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
            return .allow
        }
        let isLinkClick = navigationAction.navigationType == .linkActivated
        let site = webView === self.webView ? site : WebNavigation.site(of: url)
        switch WebNavigation.decide(url, site: site, isLinkClick: isLinkClick) {
        case .allow: return .allow
        case .openInBrowser:
            owner?.openInBrowser(url)
            return .cancel
        case .refuse: return .cancel
        }
    }

    /// Downloads are not something a page here can do.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { error = nil }
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: any Error) {
        let error = error as NSError
        // A navigation stopped by a newer one, or refused above, is not a failure to show.
        let ignored =
            (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == WKErrorDomain && error.code == 102)
        guard webView === self.webView, !ignored else { return }
        self.error = error.localizedDescription
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        let isLinkClick = navigationAction.navigationType == .linkActivated
        switch WebNavigation.decideNewWindow(url, site: site, isLinkClick: isLinkClick) {
        case .popUp:
            let popUp = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 600), configuration: configuration)
            popUp.navigationDelegate = self
            popUp.uiDelegate = self
            popUps.append(popUp)
            owner?.presentPopUp(popUp, self)
            return popUp
        case .loadInPage:
            if let url { self.webView.load(URLRequest(url: url)) }
            return nil
        case .openInBrowser:
            if let url { owner?.openInBrowser(url) }
            return nil
        case .refuse:
            return nil
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = popUps.firstIndex(where: { $0 === webView }) else { return }
        popUps.remove(at: index)
        owner?.dismissPopUp(webView)
    }

    /// The author closed the pop-up's sheet before the page did.
    func popUpDismissed(_ popUp: WKWebView) {
        popUps.removeAll { $0 === popUp }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { reload() }
    }
}

/// A page's web view, with the keys a browser gives it while it has focus.
final class CanopyWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isFocused = window?.firstResponder.flatMap { ($0 as? NSView)?.isDescendant(of: self) } ?? false
        guard isFocused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "r": reload()
        case "[": goBack()
        case "]": goForward()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
```

- [ ] **Step 2: Build and look**

Run: `make app && scripts/ui-fixture.sh light`, then `swift scripts/window-shot.swift <pid> panel.png`.
Expected: the selected row shows the plan page in the panel, its header level with the top bar, and `swift build` reports no warnings.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: the web panel and web tabs in the window"
```

### Task 10: UI fixture with pages, and ⌘-clicks for UI checks

`scripts/ui-fixture.sh` serves two local pages on a free port, opens one in the selected row's panel and one in another row's tab, and prints an artifact link in the agent pane.
The page server stops with `stop`, or by itself after four hours.
`scripts/ui.swift click` takes modifiers, so a UI check can ⌘-click a link.

**Files:**
- Modify: `scripts/ui-fixture.sh`
- Modify: `scripts/ui.swift`

**Interfaces:**
- Consumes: Tasks 6 and 9.
- Produces: Nothing new.

- [ ] **Step 1: Make the change**

`scripts/ui-fixture.sh`, changed:

```diff
@@ -4,9 +4,9 @@
 # running programs, listening ports, a split tab, agents in every state, and the fixture plugin's section with its
 # warning, rows with every kind of accessory, a missing item, and a worktree row linked to one of them, and the Tickets
 # section with rows backed by a stand-in ticket-manager: a waiting ticket, a long conversation with every kind of
-# message, and a closed ticket, with a fix row linked to one. Nothing outside the throwaway folder is touched, and
-# nothing reaches ticket-manager or Discord. Links the window opens are written to $work/opened-urls instead of opening
-# a browser.
+# message, and a closed ticket, with a fix row linked to one, a web panel and a web tab on local pages, and an artifact
+# link printed in a pane. Nothing outside the throwaway folder is touched, and nothing reaches ticket-manager or Discord.
+# Links the window opens are written to $work/opened-urls instead of opening a browser.
 #
 #   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
 #   scripts/ui-fixture.sh stop           quit it and delete its folder
@@ -39,6 +39,9 @@ if [[ "${1:-}" == stop ]]; then
     if [[ -n "${tm_pid:-}" && "$(ps -p "$tm_pid" -o command= 2>/dev/null)" == *ticket-manager-stand-in.py* ]]; then
         kill "$tm_pid" 2>/dev/null || true
     fi
+    if [[ -n "${site_pid:-}" && "$(ps -p "$site_pid" -o command= 2>/dev/null)" == *fixture-site* ]]; then
+        kill "$site_pid" 2>/dev/null || true
+    fi
     # Only a folder this script made: named by mktemp -t cnp, and holding the stand-in gh and the fixture ZDOTDIR.
     if [[ "$(basename "$work")" != cnp.* || ! -x "$work/bin/gh" || ! -d "$work/zdot" ]]; then
         echo "not deleting $work: it does not look like a fixture folder" >&2
@@ -184,6 +187,39 @@ for _ in $(seq 1 100); do
 done
 tm_url="http://127.0.0.1:$(cat "$work/tm/port")"
 
+# Pages for the web panel and a web tab, served on a free port so they never collide with another fixture's. The server
+# stops after four hours if `stop` never runs.
+mkdir -p "$work/site"
+cat > "$work/site/plan.html" <<'PAGE'
+<!doctype html><meta charset="utf-8"><title>Checkout redesign plan</title>
+<meta name="color-scheme" content="light dark">
+<style>body{font:15px/1.5 -apple-system,sans-serif;max-width:640px;margin:32px auto;padding:0 24px}
+h1{font-size:24px}code{font:13px ui-monospace,monospace}</style>
+<h1>Checkout redesign</h1><p>Three steps instead of one long form: address, delivery, and payment.</p>
+<h2>Steps</h2><ol><li>Address, with saved addresses first</li><li>Delivery, with dates</li><li>Payment</li></ol>
+<p>Each step keeps what was typed when the shopper goes back. See <code>src/checkout/Form.tsx</code>.</p>
+PAGE
+cat > "$work/site/notes.html" <<'PAGE'
+<!doctype html><meta charset="utf-8"><title>Onboarding notes</title>
+<meta name="color-scheme" content="light dark">
+<style>body{font:15px/1.5 -apple-system,sans-serif;max-width:640px;margin:32px auto;padding:0 24px}</style>
+<h1>Onboarding notes</h1><p>Welcome, workspace, and invite: three screens, each skippable.</p>
+PAGE
+(exec -a fixture-site /usr/bin/python3 -c '
+import functools, http.server, sys, threading, time
+handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
+server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
+open(sys.argv[2], "w").write(str(server.server_port))
+threading.Thread(target=server.serve_forever, daemon=True).start()
+time.sleep(14400)
+' "$work/site" "$work/site-port" </dev/null >/dev/null 2>&1) &
+site_pid=$!
+for _ in $(seq 1 100); do
+    [[ -s "$work/site-port" ]] && break
+    sleep 0.1
+done
+site="http://127.0.0.1:$(cat "$work/site-port")"
+
 # The fixture plugin is on, with a warning under its header and one item it pretends is gone.
 mkdir -p "$CANOPY_HOME"
 cat > "$CANOPY_HOME/config.json" <<'CONFIG'
@@ -206,7 +242,7 @@ if [[ "${1:-dark}" == light ]]; then args=(-NSRequiresAquaSystemAppearance YES);
     GIT_CONFIG_KEY_0="url.$work/remotes/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ \
     exec "$app/Contents/MacOS/Canopy" "${args[@]}" </dev/null >/dev/null 2>&1) &
 # Written at once, so `stop` can clean up even if a later step fails. The subshell execs, so $! is the app.
-printf 'pid=%s\nwork=%s\ntm_pid=%s\n' "$!" "$work" "$tm_pid" > "$state"
+printf 'pid=%s\nwork=%s\ntm_pid=%s\nsite_pid=%s\n' "$!" "$work" "$tm_pid" "$site_pid" > "$state"
 for _ in $(seq 1 100); do
     [[ -S "$CANOPY_HOME/canopy.sock" ]] && break
     sleep 0.1
@@ -280,7 +316,7 @@ sleep 1
 
 # A plain prompt keeps the machine's user and host names out of shots.
 plain="PROMPT='%F{blue}%B%1~%b%f %# '; clear"
-agent="$plain; "'printf "\n\033[36m●\033[0m Read \033[90msrc/checkout/\033[0mForm.tsx\n\033[36m●\033[0m Update \033[90msrc/checkout/\033[0mForm.tsx  \033[32m+48\033[0m \033[31m-21\033[0m\n\033[36m●\033[0m Bash \033[90mbun test checkout\033[0m\n  \033[32m✓\033[0m 18 passed\n\nThe form now has three steps.\n"; sleep 600'
+agent="$plain; "'printf "\n\033[36m●\033[0m Read \033[90msrc/checkout/\033[0mForm.tsx\n\033[36m●\033[0m Update \033[90msrc/checkout/\033[0mForm.tsx  \033[32m+48\033[0m \033[31m-21\033[0m\n\033[36m●\033[0m Bash \033[90mbun test checkout\033[0m\n  \033[32m✓\033[0m 18 passed\n\nThe form now has three steps. The plan: https://claude.ai/artifact/9f2c1e7a-checkout\n"; sleep 600'
 row=(--repo web-app --row feat/checkout-redesign)
 first=$("$cli" term list --all --json | /usr/bin/python3 -c \
     'import json, sys; print([t["pane"] for t in json.load(sys.stdin) if t["row"] == "feat/checkout-redesign"][0])')
@@ -293,6 +329,8 @@ first=$("$cli" term list --all --json | /usr/bin/python3 -c \
 "$cli" term new --repo api-server --row feat/rate-limits --run "$plain; python3 -m http.server 8080" >/dev/null
 "$cli" term new --repo web-app --row fix/login-redirect --run "$plain" >/dev/null
 "$cli" term new --repo web-app --row chore/bump-deps --run "$plain" >/dev/null
+"$cli" web open "$site/plan.html" "${row[@]}" --panel >/dev/null
+"$cli" web open "$site/notes.html" --repo web-app --row feat/onboarding-flow --tab >/dev/null
 "$cli" row select feat/checkout-redesign --repo web-app >/dev/null
 
 fixture_row() {
```

`scripts/ui.swift`, changed:

```diff
@@ -7,7 +7,7 @@
 //   ui key <pid> <keycode> [cmd] [shift] [opt] [ctrl]
 //   ui type <pid> <text>
 //   ui move <pid> <x> <y>                   points from the window's top-left, as in a window shot divided by 2
-//   ui click <pid> <x> <y> [count]
+//   ui click <pid> <x> <y> [count] [cmd] [shift] [opt] [ctrl]
 //   ui rightclick <pid> <x> <y>             opens a context menu
 //   ui drag <pid> <x1> <y1> <x2> <y2>
 //   ui down <pid> <x> <y>                   press the button and keep it held, for a shot in the middle of a drag
@@ -81,9 +81,12 @@ func post(_ event: CGEvent) {
     usleep(15_000)
 }
 
-func mouse(_ type: CGEventType, at point: CGPoint, clickCount: Int64 = 1, button: CGMouseButton = .left) {
+func mouse(
+    _ type: CGEventType, at point: CGPoint, clickCount: Int64 = 1, button: CGMouseButton = .left, flags: CGEventFlags = []
+) {
     let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
     event.setIntegerValueField(.mouseEventClickState, value: clickCount)
+    event.flags = flags
     event.post(tap: .cghidEventTap)
     usleep(20_000)
 }
@@ -145,11 +148,12 @@ case "move":
 case "click":
     requireFrontmost()
     let point = windowPoint(2)
-    let count = args.count > 4 ? Int(number(4)) : 1
-    mouse(.mouseMoved, at: point)
+    let count = args.count > 4 ? Int(args[4]) ?? 1 : 1
+    let flags = modifiers(args.dropFirst(4))
+    mouse(.mouseMoved, at: point, flags: flags)
     for click in 1...max(count, 1) {
-        mouse(.leftMouseDown, at: point, clickCount: Int64(click))
-        mouse(.leftMouseUp, at: point, clickCount: Int64(click))
+        mouse(.leftMouseDown, at: point, clickCount: Int64(click), flags: flags)
+        mouse(.leftMouseUp, at: point, clickCount: Int64(click), flags: flags)
     }
 case "rightclick":
     requireFrontmost()
```

- [ ] **Step 2: Check it**

Run: `swiftc -O -o build/ui scripts/ui.swift && make app && scripts/ui-fixture.sh dark`, then `scripts/ui-fixture.sh stop`.
Expected: the fixture prints its pid, `canopy web list --all` shows w1 in the panel of feat/checkout-redesign and w2 in a tab of feat/onboarding-flow, and `stop` ends the page server.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test: the UI fixture shows a web panel, a web tab, and an artifact link, and ui clicks with modifiers"
```

## Decisions the spec did not make

- Links ⌘-clicked in a terminal with a scheme other than http or https are dropped, as the spec says, but file paths SwiftTerm finds in the text, which have no scheme, still open with their app as before, keeping Goal 6.
- The panel's Close closes its page. Hiding the panel, which the saved state carries, is View > Hide Web Panel and Show Web Panel, on ⌥⌘0 as Xcode's inspector.
- ⌘W closes a web tab's page, and the File menu item reads Close Page then.
- A web tab is named after its page and cannot be renamed.
- A page is found by the address it opened with as well as where it is now, so an artifact sent to claude.ai's sign-in is not opened twice.
- Navigations to other sites that the author did not click, such as sign-in redirects, stay in the page. Only clicked links leave for the browser.
- A link with a target of its own on the page's site loads in the page itself rather than a pop-up.
- A row that closes, when it is removed or Canopy quits, logs no `web.closed` for its pages, since quitting is not the author closing them.
- The sign-in pop-up's sheet has a Cancel button, so a pop-up the page never closes cannot trap the window.
- In a plugin row the web panel's two-thirds limit is of the room beside the plugin's panel.
- The spec's check that a non-artifact terminal link still goes to the browser needs a ⌘-click, so it is a UI check with the fixture's `CANOPY_OPENED_URLS`, not a `make e2e` step.
- `web list` gives a page's host as its title until the page has loaded one.
- Downloads are cancelled and JavaScript alerts are not shown.
- WebKit blocks some ports, such as 9, without telling its delegate, so a page there stays blank with no error.

## After Review

An independent reviewer (opus) read `git diff main...HEAD` with the spec and this plan.
It found no high-severity bugs, and these eleven others, all fixed in `fix: what the review found in the artifact viewer` with tests where the logic is in CanopyCore.

1. ⌘W closed the selected tab's terminal while the author was reading the panel.
   The page's web view now reports keyboard focus to `AppModel.focusedPage`, ⌘W closes the panel's page while it has the keyboard, and the menu item reads Close Page then.
   Checked in the dev build: ⌘W with the panel focused closed only the panel's page.
2. `tel:5551234` and other `scheme:digits` links read as paths and reached `NSWorkspace` through SwiftTerm, which opened FaceTime.
   `TerminalLink.file(_:in:)` now resolves a path against the pane's folder, opens only a file or folder that exists, and never one that runs something (`.app`, `.command`, and the like); `TerminalFileLinkTests` pins it.
3. A page could open pop-up sheets from a timer, from any row.
   `javaScriptCanOpenWindowsAutomatically` is off, a pop-up shows only for a page on screen while Canopy is in front, and a second pop-up never replaces one showing.
4. The address a page opened with was not saved, so after a relaunch an artifact sent to sign-in could open twice, and a page left on another site took that site as its own.
   `SavedWebPage.opened` keeps it, and `aPageKeepsTheAddressItOpenedWithAcrossARelaunch` pins it.
5. One unreadable saved tab or panel dropped every row's layouts.
   Rows, tabs, and panels now decode leniently on their own, a page's title and a panel's `hidden` default when absent, and `aBrokenPageOrTabCostsOnlyItself` pins it.
6. A script's `a.click()` in a background row could open browser tabs.
   A page opens the browser only while it is on screen and Canopy is in front.
7. App Transport Security would block plain http pages on public hosts.
   `Info.plist` allows arbitrary loads in web content, and `http://example.com/` loaded in the dev build.
8. Page titles reached `canopy web list` with control characters, so a title could write escape sequences into an agent's terminal.
   `pageNavigated` turns control characters into spaces, and `titlesLoseControlCharacters` pins it.
9. A view drawn just after its page closed could make a web view nothing would drop.
   `WebViews.controller(for:)` returns nil for a page no row has.
10. `closeAll` missed rows with only a panel.
    It now walks every row with tabs or a panel, and `closingEverythingClosesRowsThatHaveOnlyAPanel` pins it.
11. A page whose web process kept crashing reloaded forever.
    It reloads once, then shows the error with Reload, until a load finishes.

The reviewer also asked for a test of moving a tab that is not selected into a panel that holds a page; `movingATabThatIsNotSelectedKeepsTheAuthorsTab` covers it.

One more fix came from the per-commit runs.
`cancellingStopsTheCloneAndDeletesWhatItWrote` failed once under load: its stand-in wrote its pid with `echo $! > file`, which creates the file before the pid is in it, and the test read the empty file the moment it appeared.
That stand-in, its sibling, and `aHandleStopsGitAndEverythingItStarted` now write to a temporary name and rename it into place.

### CI on PR 35

`refreshesOnATimer`, a test this PR does not touch, failed on GitHub's 3-CPU runner with 2 timer lookups where it waited for 3.
The full suite run in the background with six `yes` hogs reproduced it, also with 2, and a trace of the timer showed why.
On a saturated runner one cycle of the 150 ms timer took 7 to 17 seconds:
- Its sleep took 2.5 to 4.6 seconds to resume, waiting for a thread of the cooperative pool.
- The hop onto the workspace and the start of the queued lookup took 1 to 4 seconds more.
- The lookup's two processes, git for origin and then `gh`, took 2 to 7 seconds.
- One tick also waited out a lookup the test itself had queued, which ran for 9.5 seconds.

So three cycles needed 25 to 50 seconds, against a 20-second wait that started while the test's own lookup was still running.
The test now counts only the timer's lookups, from when the lookups already queued are done, and asks for two, which is enough to show the timer repeats.
It also allows 60 seconds, about three cycles at the slowest measured.
With that change it passed three full-suite runs under the same load.
