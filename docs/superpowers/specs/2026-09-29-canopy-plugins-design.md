# Canopy plugins and the Tickets plugin

Date: 2026-09-29
Status: design approved in conversation 2026-09-29, spec in review

## Summary

Canopy gains plugins: Swift modules built into the app that do nothing until `config.json` turns them on.
A plugin can own rows that are not git worktrees.
Each such row has its own folder, so it gets tabs, terminals, saved layouts, agent dots, and `canopy term` like any other row, plus a panel the plugin draws beside the terminals.
The first plugin, Tickets, brings Discord support tickets in from ticket-manager.
The author picks the tickets they are working on, and each becomes a row showing the conversation next to its terminals.
Everything the window does with plugins and tickets, an agent can do with `canopy plugin` and `canopy ticket`.

## Goals

1. A plugin that is off adds nothing: no sidebar section, no network calls, no timers.
2. A plugin row gets every terminal feature a worktree row has, and no terminal code needs to know about plugins.
3. Only tickets the author picks become rows, so the sidebar stays short and Canopy only watches those tickets.
4. A ticket row shows the Discord conversation, problems, and draft next to its terminals, and gives agents the ticket as a file.
5. A fix made for a ticket, in a normal worktree row, stays linked to the ticket.
6. An agent can list tickets, open ticket rows, read tickets, and start work in them without the window.

## Non-goals

- Plugins as separate programs, plugins loaded at run time, and plugins by other authors.
- Writing to ticket-manager: claiming a ticket, marking problems resolved, regenerating drafts, or adding handover notes.
  These stay in ticket-manager, one click away.
- Replying in Discord from Canopy, and reading Discord directly.
- Updates pushed from ticket-manager.
  Canopy polls.
- Refreshing expired attachment links, which needs a call to Discord.
- Groups inside plugin sections.
- Alerts when a customer replies.
- The browser plugin, which gets its own spike and spec.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Plugin model | Swift modules compiled into the app, each behind the `CanopyPlugin` interface | A future browser plugin needs native views, and out-of-process plugins would need a UI description format that is large to design and maintain for a personal tool. |
| Turning a plugin on | Its section in `config.json` | Off by default, and one file says what is on. |
| Plugin row identity | A folder under `CANOPY_HOME/plugins/<plugin>/`, keyed by path | Selection, layouts, terminals, and agent state are already keyed by row path, so they work unchanged. |
| Plugin row type | Its own `PluginRow`, not `Row` with a flag | Git discovery, PR lookups, setup, and teardown never see plugin rows, so none of that code needs a new case. |
| Removing a plugin row | Its folder goes to the Trash | Agents may have left notes there. |
| Ticket source | ticket-manager, through a new read-only HTTP endpoint | ticket-manager already copies Discord every minute and knows each ticket's owner, whether the customer is waiting, its problems, its draft, and its handover block. The Discord bot token's rate limit is shared with another agent, and Canopy spends none of it. |
| Endpoint auth | Personal bearer tokens, stored hashed, made with `npx convex run` | Signing in to Clerk from a native app would depend on the web app's internals. |
| Where ticket terminals start | The ticket row's own folder | Investigating needs no checkout, and parallel agents never share one. A fix goes in a normal worktree row linked to the ticket. |
| Writes to ticket-manager | None | The author's choice. |
| Panel placement | Fixed and resizable, between the sidebar and the terminals | The author's choice. It cannot be closed or buried by accident. |
| Polling | Only while the window is visible: the rows every 60 seconds, the selected ticket every 30 seconds | ticket-manager copies Discord once a minute, so faster polling finds nothing new. |
| Token storage | The Keychain, written and read only by the app | The CLI never touches the Keychain, and `config.json` never holds a secret. |
| A ticket that already has a row | `ticket new` fails and names the row | The same rule as `row new`: `--run` never types into a row the agent did not create. |

## Plugin base

### Modules

- `CanopyCore/Plugins`: the `CanopyPlugin` interface, `PluginRow`, `PluginHost`, plugin config, and the secret store.
- `CanopyTickets`: a new library target holding the Tickets plugin's logic, with no UI.
  It depends on `CanopyCore`, and `CanopyTicketsTests` tests it.
- `CanopyApp/Plugins/Tickets`: the Tickets panel's SwiftUI views.
- `CanopyCLI`: `canopy plugin` and `canopy ticket`.

The app and the CLI each list the built-in plugins in one place.
Nothing else imports a plugin's module.

### The interface

A plugin gives the base:

- its id, such as `tickets`, which names its config section, folder, control methods, and activity events
- its display name, such as "Tickets", and an SF Symbol for its section tile and rows
- `start` and `stop`, called when it turns on or off
- its picker's filters, and the items a search finds
- a new row's seed for an item: its title and folder name, or an error such as `ticket_not_found`
- how to fill a row's folder, such as writing `ticket.md`
- how to resolve a reference an agent typed, such as `853`, to an item
- its control methods, such as `tickets.list`, which get the CLI's target hint and the plugin row it points at, and which reach the plugin while it is off too, so `tickets.connect` can turn it on
- the picker footer's command for an item, when it has one of its own, such as `canopy ticket new 853 --select`

The base gives each plugin a `PluginContext` with:

- its config section and its folder
- its secrets
- the activity log
- its rows, which row is selected, and whether the window is visible, as a stream of changes
- a way to set each row's look: its title, a short label such as `#0853`, accessories, and whether it is missing
- a way to set a warning for its section, as markdown with the fix in it, as a repo's PR warning reads
- a way to turn itself on and off, create and remove its rows, and select a row, for its own commands

Accessories are a small fixed set the sidebar knows how to draw: a colored dot, a tag such as "closed", and initials on a colored circle.
The sidebar therefore stays in the base, and a plugin never draws into it.

The app keeps a table from plugin id to the panel view that plugin draws for a row.

### Plugin rows

`state.json` gains a top-level `plugins` object:

```json
"plugins": {
  "tickets": {
    "rows": [
      {
        "item": "k57a9x2m",
        "title": "0853-sameergoyal",
        "path": "/Users/me/.canopy/plugins/tickets/0853-sameergoyal"
      }
    ],
    "links": {
      "/Users/me/.canopy/worktrees/solis-v1/fix-shadowban-check": "k57a9x2m"
    },
    "panelWidth": 340
  }
}
```

The order of `rows` is the sidebar order.
A plugin's entry stays while the plugin is off, so turning it back on brings its rows back.
An older `state.json` without `plugins` loads as having none.

**Creating.** `PluginHost` asks the plugin for the seed first, so a ticket that does not exist creates nothing.
The folder is `CANOPY_HOME/plugins/<plugin>/<folder name>`, with `-2`, `-3`, and so on appended if it exists, and is created with mode 0700.
The host records the row, lets the plugin fill the folder, logs `plugin.row.created`, and then runs `--run` in a new pane, as `row new --run` does.
A fill that fails keeps the row, skips `--run`, and makes the command exit 1, as a failed setup does.
The folder name drops path separators, control characters, and leading dots, and never reuses the path of a row whose folder is gone.
The row is selected when it was created from the window or with `--select`.

**Removing.** The host closes the row's terminals, asking first if any runs a program, which `--force` skips.
It moves the folder to the Trash, forgets the row, and logs `plugin.row.removed`.
The result says where the folder went.
A dev build launched with `CANOPY_TRASH_FOLDER` moves it into that folder instead, so end-to-end runs and UI checks on a throwaway home leave the Trash alone.
Links to the item stay, so opening the same ticket again later shows its fix rows again.

**A missing folder.** A folder deleted outside Canopy is recreated and filled again at launch and before a terminal opens in it.
Its contents come from the plugin, so nothing but agents' own files is lost.

**Terminals.** Panes in a plugin row start in its folder and get the usual variables, with these differences:

| Variable | Value |
|---|---|
| `CANOPY_ROW` | the row's title |
| `CANOPY_ROW_PATH` | the row's folder |
| `CANOPY_PLUGIN` | the plugin's id |
| `CANOPY_ITEM` | the row's item |
| `CANOPY_REPO`, `CANOPY_ROOT_PATH` | not set |

Plugin rows have no setup or teardown commands.
Agent hooks report by pane, so agent dots and the finish sound work unchanged.

### Linked rows

A worktree row can be linked to a plugin item.
`row.new` takes an optional `link` of a plugin and a reference.
When it has none and the CLI runs in a plugin row, the CLI sends `CANOPY_PLUGIN` and `CANOPY_ITEM` as the link, so a fix row started from a ticket row's terminal is linked to that ticket.
The plugin resolves the reference, and a reference it cannot resolve fails the request before git runs.
The link is saved under the plugin's `links`, keyed by the worktree row's path, and is dropped when that row goes away.

While the item's plugin row exists, the linked worktree row shows the item's short label, such as `#0853`, before its PR badge.
Clicking the label selects the plugin row.
The plugin's panel lists the item's linked rows with their PR badges, and clicking one selects it.

### Sidebar

Each plugin that is on gets a section below the repos, in the order the built-in list gives.
The header is drawn like a repo's: a tile with the plugin's symbol, its name, and its row count, which gives way on hover to a `…` menu and a `+` that opens the picker.
A warning the plugin sets shows under the header with its fix, as a PR warning shows under a repo.

A plugin row's line reads: the plugin's symbol, the title, the plugin's accessories, then the running or agent dot.
On hover the right side shows the row's shortcut and an `x`.
Rows can be dragged to reorder them within their section, and never into another section or a repo.
`canopy row move <path> --before <path>` and `--after` do the same from the CLI.
The section's `…` menu holds New Row…, which opens the picker, and Turn Off, which does what `canopy plugin disable` does and asks first while programs run in its rows.
`⌘1` to `⌘9` and the arrow keys take plugin rows after every repo's rows, in section order.

### Detail

A plugin row shows the plugin's panel at the left of the detail area, then the tab bar and terminal grid.
The top bar starts at the panel's right edge, so the tabs stay above the terminals they switch.
Above the panel, level with the top bar, a strip names the plugin and the row, and moves the window like the title bar.
The panel is 340 points wide by default, can be dragged between 260 points and half the detail area, and its width is saved per plugin.
A plugin row with no tabs opens one tab with one pane when selected, like any row.

### Picker

The base draws one picker for every plugin, as a sheet like the New Row sheet.
It has a search field, the plugin's filter chips, and a list of items, each with a title, a subtitle, accessories, and a mark when the item already has a row.
Return or a click opens a row for the item and selects it, or selects the row the item already has.
The footer shows the `canopy` command that does the same, `canopy plugin new <plugin> <item> --select` unless the plugin has its own, `canopy row select <path>` for an item with a row, and `canopy plugin items <plugin>` before anything is picked.
The picker asks the plugin afresh when it opens and when a toggle changes, and otherwise lets the plugin narrow what it already fetched.
While items load the list shows a spinner, and a plugin's error shows in its place with the fix.

### Turning plugins on and off

At launch the host reads `plugins` from `config.json`.
Each built-in plugin whose section is present, and does not say `"enabled": false`, starts.
A plugin whose `start` fails still shows its section and rows, with the failure as the section's warning.

`plugin.enable` and `plugin.disable` turn a plugin on or off while the app runs.
Each writes the plugin's section of `config.json` through a temp file and an atomic rename, keeping every other key as it was.
The Tickets plugin's `connect` and `disconnect` go through them.
`plugin.enable` on a plugin that is on starts it again when its section changed.
`plugin.disable` refuses with `plugin_busy` while a program runs in one of its rows, unless `force`, and then closes its rows' terminals, whose layouts come back with the rows when it is on again.

### Secrets

Secrets are generic passwords in the login Keychain.
The service is `<bundle id>.plugins.<plugin id>`, and the account is the secret's name followed by `CANOPY_HOME`, such as `token@/Users/me/.canopy`.
A dev build and each temporary home in tests therefore have their own entries, and never read the author's.
The Keychain sits behind a `SecretStore` interface, with an in-memory store for unit tests.

### Control methods and CLI

| Command | Method | Effect |
|---|---|---|
| `canopy plugin list` | `plugin.list` | each built-in plugin, whether it is on, and its status line, such as "connected as hindie@… to https://….convex.site, updated 20 s ago", with its warning and filters |
| `canopy plugin enable <plugin>`, `canopy plugin disable <plugin> [--force]` | `plugin.enable`, `plugin.disable` | turn a plugin on or off; plugin commands such as `ticket connect` use them too |
| `canopy plugin items <plugin> [--query <text>] [--filter <id>]...` | `plugin.items` | what the picker lists, with each item's row |
| `canopy plugin new <plugin> <reference> [--run <cmd>] [--select]` | `plugin.new` | what picking an item without a row does; an item with a row fails with `item_has_row`, naming it |
| `canopy row list` | `row.list` | also lists plugin rows, under each plugin's name, with `plugin`, `item`, `title`, and `path` in `--json` |
| `canopy row select`, `canopy row rm`, `canopy row move --before\|--after` | `row.select`, `row.remove`, `row.move` | also take a plugin row's path; `row rm` refuses a running program without `--force` |
| `canopy row new … --no-link` | `row.new` | leaves out the link the CLI sends from a plugin row |
| `canopy row new … [--ticket <ticket>]` | `row.new` | `--ticket` sends a `link` to the Tickets plugin |
| `canopy term …` | `term.*` | resolve plugin rows from `CANOPY_ROW_PATH` or the current folder, like any row |

`plugin.list`, `plugin.items`, and each plugin's reading methods join the methods `cli.call` leaves out.
A `token` param, at any depth, is never written to the activity log.
`term list` and `ports` leave `repo` out for a plugin row's terminals and ports, and give `plugin` instead.

### Activity events

| Type | Recorded when | `data` |
|---|---|---|
| `plugin.enabled`, `plugin.disabled` | a plugin turns on or off | `plugin` |
| `plugin.row.created`, `plugin.row.removed` | a plugin row is created or removed | `plugin`, `item` |

Events about a plugin row, including `term.*`, leave `repo` out, set `row` to the row's title and `path` to its folder, and add `plugin` and `item` to `data`.
`row.created` gains `link` when the new row is linked.

## ticket-manager endpoint

One PR on ticket-manager adds read-only HTTP routes, served from the deployment's `.convex.site` URL, and changes nothing else there.

### Routes

All routes are `GET` under `/api/v1/`.
Times are milliseconds since the Unix epoch, as ticket-manager stores them.

| Route | Returns |
|---|---|
| `me` | `{"email": "…"}`, the token's engineer |
| `tickets?status=open\|closed\|archived` | `{"tickets": [summary]}` for that status, newest activity first, `open` by default |
| `tickets?ids=a,b,c` | `{"tickets": [summary]}` for those ids whatever their status, up to 50, leaving out ids it does not know |
| `tickets/<id>` | `{"ticket": summary, "messages": […], "problems": […], "draft": … or null, "handover": "…", "notes": […]}` |

A summary:

```json
{
  "id": "k57a9x2m",
  "name": "ticket-0853-sameergoyal",
  "number": "0853",
  "customer": "sameergoyal",
  "status": "open",
  "openedAt": 1790000000000,
  "lastActivityAt": 1790020000000,
  "owner": {"email": "hindie@…", "initials": "HI", "via": "action", "at": 1790010000000},
  "waiting": true,
  "staleHours": 7,
  "discordUrl": "https://discord.com/channels/<guild>/<channel>"
}
```

`owner` is null when nobody owns the ticket, and `staleHours` is null unless the ticket is stale.
Each message has its author's username, display name, avatar URL, and role (`staff` or `customer`), whether the author is a bot, its text, its mentions, its attachments with file name, URL, size, and content type, its time, and its thread's id and name when it was posted in a thread.
Each problem has its key, title, bullets, category, and status.
The draft has its text, status, sources used, and time.
`handover` is the markdown the web app's "Copy handover block" copies.

### Reuse

The routes call ticket-manager's own code, so Canopy and the web app always agree:

- `resolveOwner` gives the owner, and `staleHours` gives the stale hours.
- The rule for the sidebar's dot moves out of `TicketSidebar.tsx` into `convex/domain`, and both the sidebar and `waiting` use it.
- The body of the `handover.block` query moves into a helper that the query and the route share.

### Auth

Each request sends `Authorization: Bearer <token>`.
A new `apiTokens` table holds each token's SHA-256, its engineer's email, a label, when it was made, and when it was revoked.
Internal functions make, list, and revoke tokens, run with `npx convex run`, so only someone with deploy access can make one.
Making one checks that the email is on the staff list and prints the token once.
Every request checks the token again, and checks that its email is still on the staff list, so taking someone off staff also cuts off their tokens.
Nothing is written while answering a request, so the endpoint stays read-only.

Errors are JSON `{"error": {"code", "message"}}`:

| Status | Code | When |
|---|---|---|
| 400 | `bad_request` | an unknown status, more than 50 ids, or a malformed id |
| 401 | `unauthorized` | no token, or one that is unknown or revoked |
| 403 | `not_staff` | the token's email is no longer on the staff list |
| 404 | `not_found` | `tickets/<id>` for a ticket that does not exist |

### Tests

`convex-test`, already a dev dependency, calls the routes with `t.fetch`.
The tests cover each error case, the shape of each response, a ticket whose customer is waiting and one whose owner replied last, and that `handover` matches what the `handover.block` query returns.

## Tickets plugin

### Config

```json
"plugins": {
  "tickets": {
    "url": "https://<deployment>.convex.site",
    "run": "claude \"$(cat ticket.md)\""
  }
}
```

`url` is required.
`run` is optional, and is the command every new ticket row starts with unless `--run` gives another.
`web` is optional: ticket-manager's page for a ticket, with `{id}` where the ticket's id goes, which the panel's ticket-manager button opens.
The API gives no such address, so without `web` the button says how to set it.

### Connecting

`canopy ticket connect <url> [--web <template>]` asks for the token without echoing it when run in a terminal, and reads it from stdin otherwise.
The URL must be `https://`, or `http://` on this Mac alone, so a token never crosses the network in the clear, and requests never follow redirects.
The app checks it against `/api/v1/me`, saves the token in the Keychain, and turns the plugin on with `url` in its section.
A token the endpoint rejects saves nothing.
`canopy ticket disconnect [--force]` turns the plugin off, deletes the token, and keeps the rows for when it is connected again.
Like `plugin disable`, it refuses with `plugin_busy` while a program runs in a ticket row, unless `--force`, and then deletes nothing.

In the window, the sidebar's `+` menu holds "Connect Tickets…" while the plugin is off, and so do the File menu and the empty sidebar.
It opens a sheet with the URL and token fields and an optional ticket page, which sends the same `tickets.connect` as the CLI.
The section's `…` menu holds "Disconnect".

### Tickets and references

"Mine" means the ticket's owner is the email `/api/v1/me` gave.
A reference names a ticket as `853`, `0853`, `0853-sameergoyal`, `ticket-0853-sameergoyal`, `closed-0853-sameergoyal`, or a ticket-manager id.
A number is matched against the numbers in ticket names, looking at the rows' tickets and open tickets first, then closed and archived ones.
Inside a ticket row, a command that takes a reference uses the row's ticket when none is given.

### Picker

The picker lists open tickets, those whose customer is waiting first, then by latest activity.
Its filters are Mine, Unowned, and Anyone, starting on Anyone, plus a Closed toggle that lists closed and archived tickets instead.
Search matches the name and the customer.
Each item shows the ticket's title, the customer and how long ago it was active, the owner's initials, and the waiting dot.

### The row

A ticket row's title and folder are the ticket's name without `ticket-` or `closed-`, such as `0853-sameergoyal`, fixed when the row is created.
The row is tied to the ticket's id, so ticket-manager renaming the channel from `ticket-` to `closed-` does not break it.
Its short label is `#0853`.
Its accessories are an orange dot while the customer is waiting and a "closed" tag while the ticket is closed or archived.
A ticket that ticket-manager no longer has shows the row as missing, with Remove.

### Panel

From top to bottom:

- **Header**: the ticket's name, status, customer, owner's initials, "waiting 7h" while the customer waits, and buttons that open the ticket in Discord and in ticket-manager.
- **Messages**, in order, grouped as Discord groups them: one author's messages within seven minutes share one header with their avatar, name, and time.
  Text renders Discord's markdown: bold, italics, underline, strikethrough, inline code, code blocks, and links.
  User mentions show as `@` and the display name, channel mentions as `#` and the name, and custom emoji as `:name:`.
  Messages posted in a thread show the thread's name.
  Image attachments show inline, up to 240 points tall, and other attachments as a link with the file name and size.
  An attachment whose link has expired shows its file name, and clicking it opens the message in Discord.
- **Problems**, each with its title, status, and bullets.
- **Draft**, with a Copy button.
- **Notes**, the ticket's handover notes, when it has any.
- **Fix rows**, the worktree rows linked to the ticket.
- **Footer**: when the ticket was last fetched, and a refresh button.

The panel opens at the end of the conversation, keeps its place when new messages arrive, and follows them only while that end is in view.
The API names no channels, so a channel mention shows the ticket's own name or a named thread's, and `#channel` otherwise.
A fetch that fails keeps what the panel shows, and a banner says what went wrong and when the panel was last updated.

### Files in the row's folder

- `ticket.md` is the ticket's handover block, followed by a line saying Canopy rewrites the file when the ticket changes and `canopy ticket show --md` prints the latest.
  It is rewritten only when its contents change.
- `ticket.json` is the last response for the ticket, so the panel shows at once after a relaunch and while ticket-manager cannot be reached.

### Refreshing

Canopy asks ticket-manager for anything only while its window can be seen, or when a command asks.

- The rows' tickets, through `tickets?ids=`, every 60 seconds, to update their accessories.
- The selected ticket, through `tickets/<id>`, every 30 seconds, and when it is selected or the window comes to the front, at most once every 15 seconds.
- The picker fetches when it opens and when the Closed toggle changes, and filters and searches what it fetched.
- `canopy ticket list` and `canopy ticket show --refresh` fetch at once.

- A row's ticket whose summary changed since its copy was fetched is fetched once, so `ticket.md` stays current in rows that are not selected.
- `canopy ticket show` uses a copy under 30 seconds old unless `--refresh`.

After a failure the plugin waits twice as long each time, up to five minutes, and returns to the usual pace after a success.
A batch of ids that ticket-manager answers 400 for is split until the malformed id is alone; that row shows as missing and is left out of later refreshes, so it never stops the others.

### Commands

`<ticket>` is a reference as above.

| Command | Method | Effect |
|---|---|---|
| `canopy ticket connect <url>` | `tickets.connect` | check the token, save it, and turn the plugin on |
| `canopy ticket disconnect` | `tickets.disconnect` | turn the plugin off and delete the token |
| `canopy ticket list [--mine \| --unowned] [--waiting] [--query <text>] [--closed]` | `tickets.list` | list tickets, sorted as the picker sorts them, with each one's row |
| `canopy ticket new <ticket> [--run <cmd>] [--select]` | `tickets.new` | open a row for the ticket, and fail with `ticket_has_row` naming the row if it has one |
| `canopy ticket show [<ticket>] [--refresh] [--md]` | `tickets.show` | print the ticket and its messages, problems, draft, and fix rows, or with `--md` the latest handover markdown |
| `canopy ticket select [<ticket>]` | `tickets.select` | select the ticket's row |
| `canopy ticket rm [<ticket>] [--force]` | `tickets.remove` | remove the ticket's row, through the same path as `row.remove` |

`canopy ticket list` prints one line per ticket:

```
0853-sameergoyal   waiting 7h   HI   ~/.canopy/plugins/tickets/0853-sameergoyal
0849-babamachine   2h ago       AN
0848-shathrem      7h ago
```

### Agent guide

`canopy agent-guide` gains a Tickets section, printed only while the plugin is on.
It explains ticket rows, `ticket.md`, references, and linked fix rows, with worked examples:

```
canopy ticket list --mine --waiting
canopy ticket new 853 --run 'claude "$(cat ticket.md)"'
canopy row new fix/shadowban-check --repo solis-v1 --run 'claude "fix the shadowban check, see #0853"'
```

## Error handling

| Case | Canopy |
|---|---|
| A `ticket` command while the plugin is off | Fails with `plugin_off` and the fix, `canopy ticket connect <url>`. |
| The token is rejected (401) or its email is off the staff list (403) | The section's warning says so with the fix, `canopy ticket connect <url>` with a new token. Rows and panels keep their cached tickets. Commands fail with `token_rejected` or `not_staff`. |
| ticket-manager cannot be reached, times out after 15 seconds, or answers 5xx | The panel's banner and `canopy plugin list` say so and when the last fetch succeeded. Commands fail with `tickets_unreachable`, except `ticket show`, which prints the cached ticket with a note saying how old it is. |
| A reference matches nothing | `ticket_not_found`. |
| A number matches more than one ticket | `ticket_ambiguous`, naming each match. |
| The Keychain refuses a read or a write | The plugin cannot start, and the warning names the Keychain's error. Commands that need it fail with `keychain_failed`. |
| The plugin is on but could not start, such as without a token | The warning says why, and commands fail with `plugin_not_started` and the fix. |
| An address that is not `https://`, or `http://` off this Mac, or a `web` without `{id}` | `invalid_url`, and nothing is saved. |
| ticket-manager answers something that is not its API, such as HTML, a redirect, or a 404 for `me` | `bad_response`, saying to check it is the `.convex.site` address. |
| `ticket select` or `ticket rm` for a ticket without a row | `ticket_has_no_row`, with the `ticket new` command. |
| `config.json` cannot be written | `plugin.enable` fails with the file system's message, and nothing changes. |

## Testing

- **CanopyCore unit tests** cover plugin config parsing, creating, ordering, and removing plugin rows, moving folders to the Trash, recreating missing folders, target resolution and pane variables for plugin rows, `⌘1` to `⌘9` order, links being kept and dropped, and loading a `state.json` without `plugins`.
  A fixture plugin in the test target drives the host without the Tickets plugin.
- **CanopyTickets unit tests** cover decoding the endpoint's responses from fixture files, references, the picker's filters and sort, each row's look, `ticket.md`, the refresh schedule on a test clock, backoff, and how each error maps to a code and a warning.
  HTTP goes through a transport interface, with a fake transport in tests, and secrets go through the in-memory store.
- **End-to-end tests** start a stub ticket-manager, a small script in `scripts/` that serves fixture responses and checks the bearer token, then drive a dev build on a temporary home through `canopy ticket connect`, `list`, `new`, `show`, `select`, and `rm`, `canopy row new --ticket`, `canopy plugin list`, and `canopy row list`.
  They end with `canopy ticket disconnect`, which deletes the temporary home's Keychain entry.
- **The plugin base** is checked end to end with the fixture plugin in `scripts/e2e.sh`, including one case that writes and deletes a Keychain entry for its temporary home.
- **UI checks** use `scripts/ui-fixture.sh`, which gains the fixture plugin's section in the plugin base's PR and ticket rows backed by the stub in the Tickets PR, and window shots of the section, the picker, and the panel in light and dark, with long messages, images, an expired attachment, a closed ticket, and an error banner.
- **ticket-manager** tests run with vitest and `convex-test`.
- Nothing in development talks to a real ticket-manager deployment.
  The fixture responses are copied from the endpoint's tests, so the stub and the endpoint cannot drift apart without a test noticing.
  The author connects the release app to production once the endpoint is deployed.

## Delivery

Each item has its own plan and PR.

1. **ticket-manager**: the endpoint.
   Built in a fresh clone in a scratch folder, never in the checkout at `~/.superset/projects/ticket-manager`.
   The author or another ticket-manager maintainer reviews and merges it, and merging deploys it.
2. **Canopy `feat/plugin-base`**: this spec, the plugin base, linked rows, `canopy plugin list`, and plugin rows in `row` and `term` commands.
   Its UI checks use the fixture plugin, which a dev build turns on only when launched with `CANOPY_FIXTURE_PLUGIN=1`.
3. **Canopy `feat/tickets-plugin`**: the Tickets plugin, its panel and commands, the agent guide section, the stub, and the end-to-end tests.

Items 1 and 2 can go in parallel.
Item 3 needs item 2, but not item 1, since it runs against the stub.

## Decisions to review

- The picker starts on Anyone, with waiting tickets first, rather than on Mine.
- A removed plugin row's folder goes to the Trash, and a folder deleted outside Canopy is recreated.
- Links stay after a ticket's row is removed, so reopening the ticket shows its fix rows again.
- Plugin rows take `⌘1` to `⌘9` after all repo rows.
- The top bar starts at the panel's right edge rather than spanning the panel.
- Keychain entries are per `CANOPY_HOME`, so dev builds and tests never see the release app's token.
- The base's UI is checked with a fixture plugin that only a dev build started with `CANOPY_FIXTURE_PLUGIN=1` turns on.
- `ticket.md` holds the handover block only, and handover notes show in the panel but not in the file.
- Tokens are made with `npx convex run`, and ticket-manager gets no screen for them.
- Settled while building the Tickets plugin: the `web` template and `--web`; `http://` only on this Mac; no redirects; `ticket disconnect --force`; `plugin_off` naming each plugin's own command, such as `canopy ticket connect <url>`; the `bad_response`, `plugin_not_started`, `invalid_url`, `keychain_failed`, and `ticket_has_no_row` codes; malformed ids shown as missing; rows' changed tickets fetched for their files; `ticket show`'s 30 seconds; the panel opening at the conversation's end; and "Connect Tickets…" in the File menu and the empty sidebar too.
- Settled while building the plugin base: `canopy plugin enable`, `disable`, `items`, and `new`, so every picker action and the section's Turn Off have a command; `--no-link`; `row move` for plugin rows; `plugin_busy` and `row_busy` in place of asking from the CLI; a failed fill behaving like a failed setup; a dev build's `CANOPY_TRASH_FOLDER`; and the panel's title strip.
