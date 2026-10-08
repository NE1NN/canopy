# Canopy artifact viewer design

Date: 2026-10-08
Status: draft for review.
The author approved the design in conversation on 2026-10-08, and this spec writes it down.

## Summary

A claude.ai artifact opens inside Canopy, so the author reads it next to the agent that made it instead of in a browser.
⌘-clicking an artifact link in a terminal opens it in the row that terminal belongs to.
It shows in a panel on the right of the row's terminals, and can be moved into a tab beside the terminal tabs, and back.
Agents open pages themselves with `canopy web open <url>`, and the agent guide tells them to do it after publishing an artifact.
The author signs in to claude.ai once inside Canopy, and Canopy remembers it.
Remote rows, which are in progress on `feat/ssh-rows`, get the same behavior through the pieces listed under Remote rows.

## Goals

1. ⌘-clicking a claude.ai artifact link in any terminal shows the artifact in Canopy, in that terminal's row.
2. A row shows a web page either in a right-hand panel or in a tab, and the author moves it between the two.
3. Agents open a page in their own row with `canopy web open`, and see what is open with `canopy web list`.
4. Signing in to claude.ai happens once and survives relaunches.
5. Web tabs and panels survive relaunches.
6. Nothing changes for links that are not artifacts.

## Non-goals

- A general browser: no address bar, history list, or bookmarks.
  Back and forward work through the trackpad swipe and ⌘[ and ⌘].
- Opening every web link in Canopy.
  PR badges, ports, ticket links, and other terminal links keep opening the default browser.
- Catching Claude Code's own browser opening on the Mac.
  That would mean shadowing `/usr/bin/open` on every pane's PATH, and the agent guide covers the case.
- Web pages inside a tab's split grid, next to terminal panes.
  A web tab holds one page.
- Downloads, file pickers, and printing from a web page.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Where a page shows | A right-hand panel or a tab, movable between the two | The author asked for both. The panel keeps the agent visible beside the page, and a tab gives the page the whole width. |
| Where a new page opens | Where the author last moved a page to, the panel at first | One remembered choice, with no setting to find. |
| Pages per panel | One per row | A new page replaces the panel's page. Tabs hold as many as the author wants. |
| Which clicked links open in Canopy | claude.ai artifact links only | The author's choice. Other links keep their current behavior. |
| What `canopy web open` takes | Any http or https URL | An agent can show the author a page on purpose, such as its dev server. |
| Signing in | claude.ai's own sign-in, in Canopy's persistent web data | The spike on 2026-10-08 showed claude.ai loads in a WKWebView and an artifact link shows "Sign in to view this page" when signed out. |
| User agent | Safari's | Google refuses sign-in from user agents it reads as embedded web views. |
| Links that leave claude.ai | The default browser | An artifact's outbound links are not artifacts. |
| Where the shape lives | CanopyCore models web pages and their placement, the app draws them | As for terminals: logic in the core, views in the app. |

## Artifact links

`ArtifactLink` in CanopyCore recognises:

- `https://claude.ai/artifact/<id>`
- `https://claude.ai/code/artifact/<uuid>`

with an optional trailing slash, query, and fragment, and `www.claude.ai`.
Anything else, including `http://`, other hosts, and other paths, is not an artifact link.

## Web pages

A web page is `WebPage { id, url, title }`.
Its id is `w<number>`, from a counter saved like the pane counter.
`title` is the page's last title, used before the page has loaded.

A row can hold:

- at most one panel page, with the panel shown or hidden;
- any number of web tabs, each holding one page.

### Tabs

A tab is either terminals, as now, or one web page.
`TerminalTab` gains `content`, either `.terminals` with today's layout, panes, and focus, or `.web(WebPage)`.
A web tab is named after its page's title, and its tab bar item shows a globe.
Split Pane does nothing in a web tab.
⌘T and `+` still open a terminal tab.
Closing a web tab never asks.

### The panel

The panel sits on the right of the row's terminal area, with a draggable divider.
Its width is one value for every row, 480 points by default and at least 320, at most two thirds of the detail area, saved in `state.json` as `webPanelWidth`.
It shows for the selected row whenever that row has a panel page and the panel is not hidden.
Plugin rows get it too, to the right of their terminals, with the plugin's own panel still on the left.

### The header

The panel and a web tab share a header above the page:

| Item | Does |
|---|---|
| Title | The page's title, or its host while loading, with a spinner while loading |
| Reload | Reloads, ⌘R while the page has focus |
| Open in Browser | Opens the page's current URL in the default browser |
| Move to Tab, or Move to Panel | Moves the page, keeping its URL and its loaded web view |
| Close | Closes the panel or the tab |

Moving a page sets the remembered placement.
Moving to the panel when the row's panel holds another page turns that page into a tab, so nothing is lost.

### Opening a page

Opening a page in a row:

1. When the row already shows the same URL, in the panel or a tab, that place is shown and nothing new opens.
2. Otherwise, with placement `panel`, the page goes into the row's panel, replacing its page, and the panel is shown.
3. With placement `tab`, a new web tab opens after the selected tab.

A page opened from a click selects its row's panel or tab.
A page opened by the CLI never changes which row is selected, as `term new` does not, but it does select its tab within the row and show the row's panel.

### Loading

A web view is made the first time its page is shown and kept while its row lives, so moving or switching tabs keeps its scroll position and state.
Restored pages load only when first shown.
All web views share one persistent `WKWebsiteDataStore.default()`, so a sign-in is shared and remembered.
The dev build and the release app have different bundle ids, so each keeps its own sign-in.

### Navigation inside a page

- Navigations within the page's own site, `claude.ai` for artifacts, stay in the web view, including claude.ai's sign-in and its redirects.
- A page asking for a new window, as Google sign-in does, gets a small sheet holding a web view made from the page's configuration, which closes when the page closes it.
- Any other link the author clicks opens in the default browser.
- Schemes other than http and https are refused, as `AppModel.open` refuses them now.

## Terminal links

`SwiftTermEmulator` implements `requestOpenLink` and passes the link to the app through its pane.
The app opens an artifact link in the pane's row, as above.
Any other http or https link goes through `AppModel.open`, as SwiftUI links do, which also puts terminal links under the debug `CANOPY_OPENED_URLS` capture.
Other schemes are dropped, matching `AppModel.open`.

## Saved state

`SavedTab` gains an optional `web: SavedWebPage`, `{ url, title }`.
A tab with `web` is a web tab, and its `layout` is absent.
`SavedRowTerminals` gains an optional `panel: SavedWebPanel`, `{ page: SavedWebPage, hidden: Bool }`.
`AppState` gains `webPlacement` (`panel` or `tab`, `panel` when absent), `webPanelWidth`, and `nextWebPage`.
An older `state.json` loads as having no web pages.
A row whose tabs are all web tabs restores them and opens no terminal, as a row with no tabs opens none.

## CLI

| Command | Method | Effect |
|---|---|---|
| `canopy web open <url> [--tab \| --panel] [--repo <repo>] [--row <row>] [--json]` | `web.open` | open a page in the row, by the rules under Opening a page |
| `canopy web list [--repo <repo>] [--row <row>] [--all] [--json]` | `web.list` | the row's pages: id, URL, title, and `panel` or `tab` |
| `canopy web close <id>` | `web.close` | close a page |

`--tab` and `--panel` choose the place for this page without changing the remembered placement.
`web open` prints the page's id and where it opened, and with `--json`, `{ page, placement, row }`.
A URL that is not http or https fails with `invalid_url`.
`web.list` is read-only, as `term.list` is.

`canopy agent-guide` gains a Web Pages section:
after publishing a claude.ai artifact, run `canopy web open <url>` so the author sees it in Canopy, and `web list` and `web close` for the rest.

## Activity log

| Type | Recorded when | `data` |
|---|---|---|
| `web.opened` | a page opens | `url`, `page`, `placement` |
| `web.closed` | a page closes | `url`, `page` |

Moving a page records nothing.

## Remote rows

Remote rows are in progress on `feat/ssh-rows`, and that branch is not changed by this work.
Once they land:

- ⌘-clicking an artifact link in a remote pane works with no further change, since a remote pane is a local terminal running `ssh`.
- `canopy web open` on the host works through the relay, from that spec's milestone 2, like every other command, and opens in the remote row.
- That milestone also installs `~/.canopy/<home id>/bin/xdg-open` on the host, first on the remote panes' PATH.
  It runs `canopy web open` for artifact links and hands everything else to the host's own `xdg-open` when there is one.
  Claude Code on Linux opens links with `xdg-open`, so its own "open this artifact" on the host then shows the artifact in Canopy.
  This goes into the remote rows spec as an addition when its milestone 2 is planned.

## Error handling

| Case | Canopy |
|---|---|
| `web open` gets a URL that is not http or https | `invalid_url`, naming it |
| `web open` cannot find the row | `row_not_found`, as `term new` |
| `web close` names no page | `page_not_found` |
| A page fails to load | The web view shows WebKit's error in the page area, with Reload |
| claude.ai shows its sign-in | Nothing special: the author signs in there |

## Testing

- **CanopyCore unit tests** cover `ArtifactLink`, opening by the rules above with both placements, moving a page both ways including the panel holding another page, closing, `SavedTab` and `SavedRowTerminals` round trips with and without web pages, an older `state.json`, and the `web.*` handler methods with their errors.
- **`make e2e`** serves a test page from a local HTTP server and runs `web open`, `web list`, `web close`, both placements, the same URL opened twice, and `invalid_url`.
  A debug `CANOPY_OPENED_URLS` run checks that a non-artifact terminal link still goes to the browser.
- **UI checks** with `scripts/ui-fixture.sh`, which gains a web panel on one row and a web tab on another, both on a local page: window shots of the panel, the tab with its globe, the header, and the divider drag, in light and dark, plus ⌘-clicking an artifact link printed in a pane.
- **By hand**, the author signs in to claude.ai in a dev build, including with Google, and opens a real artifact.

## Delivery

One milestone, one PR, on `feat/artifact-viewer`.
The `xdg-open` stand-in on hosts is delivered with remote rows' milestone 2.

## Risks

- Google may still refuse sign-in in a web view with Safari's user agent.
  claude.ai's email code sign-in works in any web view, so the author can always sign in.
- claude.ai may change its artifact URLs.
  `ArtifactLink` is one small parser, and `web open` takes any URL regardless.

## Decisions to review

- New pages open where the author last moved one, the panel at first.
- One panel width for every row.
- A panel holds one page, and a new one replaces it.
- `web open` from the CLI shows the page within its row but never changes the selected row.
- Links leaving claude.ai open in the default browser.
- Claude Code's own browser opening on the Mac is left alone.
