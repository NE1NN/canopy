# Canopy Tickets Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Tickets plugin: Discord support tickets from ticket-manager become rows the author picks, each with the conversation, problems, and draft in a panel beside its terminals, `ticket.md` for agents, and `canopy ticket` commands that do everything the window does.

**Architecture:** `CanopyTickets` is a new library target built only on CanopyCore's public API, as `CanopyFixturePlugin` is.
Pure pieces (models, the API client behind a transport interface, references, listing, looks, files, the refresh schedule, Discord markdown, message groups, and plain-text output) each live in a file of their own with unit tests.
`TicketsPlugin` is an actor that ties them together: it conforms to `CanopyPlugin`, answers the `tickets.*` control methods, runs the refresh loop from the base's `PluginState` stream on an injected clock, writes each row's files, and publishes what the panel shows through a main-actor `TicketStore`.
The app draws the panel in `CanopyApp/Plugins/Tickets` from that store, and the CLI's `canopy ticket` sends the `tickets.*` methods, whose params and results live in `CanopyTickets` so both sides share them.

**Tech Stack:** Swift 6.2 in Swift 6 language mode, SwiftUI and AppKit on macOS 15, Swift Testing, URLSession, swift-argument-parser, Python 3.9 for the stand-in ticket-manager.

**Spec:** `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md` ("Tickets plugin", "Error handling", "Testing", "Decisions", and "Delivery" item 3), with the plugin base plan `docs/superpowers/plans/2026-09-29-canopy-plugin-base.md` for the interface it builds on.
Where the spec and ticket-manager PR 22 differ, the API wins: `thread.name` is null for now, `tickets?ids=` answers 400 for a malformed id, a 401 carries `WWW-Authenticate: Bearer`, and every non-GET method answers a JSON 404.

## Global Constraints

- Nothing in development, tests, e2e runs, or UI checks contacts a real ticket-manager deployment or Discord, including Discord's CDN for images and avatars.
- The API's response fixtures live in `Tests/CanopyTicketsTests/Fixtures/canopy-api/`, copied from ticket-manager commit `7a4955a`, named in `SOURCE_COMMIT` beside them, and decoded in tests.
- Config: `plugins.tickets.url` is required, `run` is the default `--run` for new ticket rows, and `web` (added here) is the ticket-manager page for a ticket, with `{id}` where the ticket's id goes.
- The token lives only in the Keychain, through the base's `PluginSecrets` under the name `token`; the CLI never touches the Keychain, and `config.json` never holds it.
- A token the endpoint rejects saves nothing.
- Only `http://` URLs on this Mac (`127.0.0.1`, `::1`, `localhost`) are allowed besides `https://`, so a token never crosses the network in the clear.
- Requests time out after 15 seconds, never follow redirects, and send no cookies.
- Canopy asks ticket-manager for anything only while its window can be seen, or when a command or the refresh button asks.
- Rows' tickets through `tickets?ids=` every 60 seconds; the selected ticket through `tickets/<id>` every 30 seconds, and when it is selected or the window comes to the front, at most once every 15 seconds.
- After a failure a job waits twice as long each time, up to five minutes, and returns to the usual pace after a success.
- A row's title and folder are the ticket's name without `ticket-` or `closed-`, such as `0853-sameergoyal`; its label is `#0853`; its accessories are an orange dot while the customer waits and a "closed" tag while the ticket is closed or archived.
- `ticket.md` is the handover block followed by one line saying Canopy rewrites it; it and `ticket.json` are rewritten only when their contents change.
- Error codes: `plugin_off`, `plugin_not_started`, `token_rejected`, `not_staff`, `tickets_unreachable`, `bad_response`, `ticket_not_found`, `ticket_ambiguous`, `ticket_has_row`, `ticket_has_no_row`, `keychain_failed`, `invalid_url`, `bad_request`, and the base's `plugin_busy`.
- Removing ticket rows in dev builds uses `CANOPY_TRASH_FOLDER`, never the author's Trash.
- Any stand-in that waits on something gives up after a time limit.
- Swift 6 strict concurrency with no warnings, `swift format lint --strict` clean, `Text(verbatim:)` for numbers, ids, and paths.
- Keep logic in `CanopyTickets` and `CanopyCore` with tests, and keep views thin.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. A row whose ticket id came from another deployment, so `tickets?ids=` answers 400 for the whole batch: every other row still refreshes, and that row shows as missing without being asked about again every minute.
   `aMalformedIdShowsItsRowMissingAndTheOthersStillRefresh` in Task 12.
2. Connecting again with a new token while the plugin runs with the same URL, so `plugin.enable` finds the section unchanged and does not restart it: the new token is used at once, and the old "token rejected" warning clears.
   `connectingAgainWithTheSameURLUsesTheNewTokenAtOnce` in Task 10.
3. The window hidden for an hour, then shown: nothing was fetched meanwhile, and on showing, the overdue rows and selected ticket are fetched once each, not once per missed interval.
   `nothingIsFetchedWhileTheWindowIsHiddenAndOnceWhenItShows` in Task 12.
4. ticket-manager down while an agent runs `canopy ticket show`: it prints the cached ticket with how old it is, `ticket list` fails with `tickets_unreachable`, and a later success clears the banner.
   `showFallsBackToTheCachedCopyWithItsAge` in Task 11.
5. Disconnecting while an agent runs in a ticket row: it refuses with `plugin_busy` and deletes nothing; with `force` the terminals close, the token is deleted, and the rows come back on the next connect.
   `disconnectRefusesWhileProgramsRunAndDeletesNothing` in Task 10.

## File Structure

- Modify `Package.swift`: the `CanopyTickets` target, used by `CanopyApp` and `CanopyCLI`, and the `CanopyTicketsTests` target with its `Fixtures` resources.
- Create `Sources/CanopyTickets/Model/TicketSummary.swift`: `TicketSummary`, `TicketOwner`, `TicketStatus`.
- Create `Sources/CanopyTickets/Model/TicketDetail.swift`: `TicketDetail`, `TicketMessage`, `MessageAuthor`, `MessageMention`, `MessageAttachment`, `MessageThread`, `TicketProblem`, `TicketDraft`, `TicketNote`.
- Create `Sources/CanopyTickets/API/TicketTransport.swift`: `HTTPReply`, `TicketTransport`, `URLSessionTicketTransport`.
- Create `Sources/CanopyTickets/API/TicketAPI.swift`: `TicketAPI`, the four routes, and status mapping.
- Create `Sources/CanopyTickets/API/TicketError.swift`: `TicketError`, its codes, messages, warnings, and whether it backs off.
- Create `Sources/CanopyTickets/Tickets/TicketName.swift`: `TicketName`, `TicketReference`, `TicketResolution`.
- Create `Sources/CanopyTickets/Tickets/TicketListing.swift`: `TicketOwnerFilter`, `TicketListQuery`, filtering, sorting, `TicketAge`, picker items.
- Create `Sources/CanopyTickets/Tickets/TicketLook.swift`: labels, accessories, owner colors, row looks.
- Create `Sources/CanopyTickets/Tickets/TicketFiles.swift`: `ticket.md` and `ticket.json`.
- Create `Sources/CanopyTickets/Tickets/TicketText.swift`: `canopy ticket list` lines and `canopy ticket show` text.
- Create `Sources/CanopyTickets/Refresh/RefreshSchedule.swift` and `Sources/CanopyTickets/Refresh/TicketClock.swift`.
- Create `Sources/CanopyTickets/Discord/DiscordMarkdown.swift`: blocks and spans from a message's text.
- Create `Sources/CanopyTickets/Discord/MessageGroups.swift`: groups, message times, attachment kinds and expiry, plain text.
- Create `Sources/CanopyTickets/Plugin/TicketSettings.swift`: the config section, URL rules, and the `web` template.
- Create `Sources/CanopyTickets/Plugin/TicketMethods.swift`: `tickets.*` names, params, and results.
- Create `Sources/CanopyTickets/Plugin/TicketStore.swift`: what the panel shows.
- Create `Sources/CanopyTickets/Plugin/TicketsPlugin.swift`, `TicketsPlugin+Fetching.swift`, `TicketsPlugin+Refresh.swift`, `TicketsPlugin+Methods.swift`.
- Modify `Sources/CanopyCore/Plugins/CanopyPlugin.swift`, `PluginHost.swift`, `Workspace/WorkspaceError.swift`: `turnOnCommand(config:)` for `plugin_off`.
- Create `Sources/CanopyCLI/TicketCommand.swift`, `Sources/CanopyCLI/SecretPrompt.swift`; modify `CanopyCLI.swift`, `RowCommand.swift`, `AgentGuide.swift`, `Client.swift`.
- Modify `Sources/CanopyApp/Plugins/BuiltInPlugins.swift`, `PluginSectionView.swift`, `LinkedRowsView.swift`, `Sidebar/SidebarView.swift`, `CanopyApp.swift`, `RootView.swift`, `AppModel.swift`.
- Create `Sources/CanopyApp/Plugins/Tickets/TicketPanel.swift`, `TicketHeader.swift`, `TicketMessagesView.swift`, `DiscordTextView.swift`, `AttachmentViews.swift`, `RemoteImage.swift`, `TicketSectionsView.swift`, `ConnectTicketsSheet.swift`.
- Modify `Resources/Info.plist.in` only if App Transport Security refuses the stand-in's loopback URL (Task 16 checks).
- Create `scripts/ticket-manager-stand-in.py`; modify `scripts/e2e.sh`, `scripts/ui-fixture.sh`.
- Modify `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md` with what building settled.
- Tests in `Tests/CanopyTicketsTests`: `Support/TicketTestSupport.swift`, `Support/ManualClock.swift`, `Support/FakeTransport.swift`, `Support/TicketsHarness.swift`, `TicketModelTests`, `TicketAPITests`, `TicketReferenceTests`, `TicketListingTests`, `TicketLookTests`, `TicketFilesTests`, `RefreshScheduleTests`, `ManualClockTests`, `DiscordMarkdownTests`, `MessageGroupTests`, `TicketTextTests`, `TicketsConnectTests`, `TicketsCommandTests`, `TicketsRefreshTests`; `Tests/CanopyCoreTests/PluginHostTests` gains a case.

---

## Task 1: The module, the fixtures, and the models

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CanopyTickets/Model/TicketSummary.swift`, `Sources/CanopyTickets/Model/TicketDetail.swift`
- Create: `Tests/CanopyTicketsTests/Fixtures/canopy-api/*.json`, `Tests/CanopyTicketsTests/Fixtures/canopy-api/SOURCE_COMMIT`, `Tests/CanopyTicketsTests/Fixtures/canopy-api/README.md`
- Create: `Tests/CanopyTicketsTests/Support/TicketTestSupport.swift`
- Test: `Tests/CanopyTicketsTests/TicketModelTests.swift`

**Interfaces:**
- Produces, all `Sendable`, `Equatable`, and `Codable` with the API's own keys, so encoding one gives back the API's JSON:

```swift
public enum TicketStatus: Sendable, Equatable, Codable, Hashable {
    case open, closed, archived
    /// A status this build does not know, kept as sent.
    case other(String)
    public var isClosed: Bool { get }  // closed or archived
}

public struct TicketOwner: Sendable, Equatable, Codable {
    public var email: String
    public var initials: String
    /// How ticket-manager decided the owner, such as "action" or "reply".
    public var via: String?
    /// Milliseconds since the epoch.
    public var at: Int64?
}

public struct TicketSummary: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// The Discord channel's name, such as `ticket-0853-sameergoyal`.
    public var name: String
    public var number: String
    public var customer: String
    public var status: TicketStatus
    public var openedAt: Int64
    public var lastActivityAt: Int64
    public var owner: TicketOwner?
    /// The customer spoke last and staff have not answered.
    public var waiting: Bool
    public var staleHours: Int?
    public var discordUrl: String
    public var lastActivity: Date { get }
    public var opened: Date { get }
}

public struct MessageAuthor: Sendable, Equatable, Codable {
    public enum Role: Sendable, Equatable, Codable { case staff, customer, other(String) }
    public var username: String
    public var displayName: String?
    public var avatarUrl: String?
    public var role: Role
    public var isBot: Bool
    /// The display name, or the username when there is none.
    public var shownName: String { get }
}

public struct MessageMention: Sendable, Equatable, Codable {
    public var id: String
    public var username: String
    public var displayName: String?
}

public struct MessageAttachment: Sendable, Equatable, Codable {
    public var filename: String
    public var url: String
    public var size: Int64
    public var contentType: String?
}

public struct MessageThread: Sendable, Equatable, Codable {
    public var id: String
    /// Null for every thread today: ticket-manager does not store thread names yet.
    public var name: String?
}

public struct TicketMessage: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var discordUrl: String?
    public var author: MessageAuthor
    public var text: String
    public var mentions: [MessageMention]
    public var attachments: [MessageAttachment]
    public var postedAt: Int64
    public var thread: MessageThread?
    public var posted: Date { get }
}

public struct TicketProblem: Sendable, Equatable, Codable, Identifiable {
    public var key: String
    public var title: String
    public var bullets: [String]
    public var category: String?
    /// "open" or "resolved".
    public var status: String
    public var id: String { key }
    public var isOpen: Bool { get }
}

public struct TicketDraft: Sendable, Equatable, Codable {
    public var text: String
    public var status: String
    public var sourcesUsed: [String]
    public var generatedAt: Int64?
    public var error: String?
}

public struct TicketNote: Sendable, Equatable, Codable {
    public var text: String
    public var authorEmail: String?
    public var createdAt: Int64
}

public struct TicketDetail: Sendable, Equatable, Codable {
    public var ticket: TicketSummary
    public var messages: [TicketMessage]
    public var problems: [TicketProblem]
    public var draft: TicketDraft?
    public var handover: String
    public var notes: [TicketNote]
}

/// `{"tickets": [...]}`, `{"email": ...}`, and `{"error": {"code", "message"}}`.
public struct TicketList: Sendable, Equatable, Codable { public var tickets: [TicketSummary] }
public struct TicketMe: Sendable, Equatable, Codable { public var email: String }
public struct TicketAPIErrorBody: Sendable, Equatable, Codable {
    public struct Detail: Sendable, Equatable, Codable { public var code: String; public var message: String }
    public var error: Detail
}
```

- Decoding is lenient where the API may grow: missing optional fields are nil, missing arrays are empty, and unknown statuses and roles are kept as `.other`.
- `Package.swift` gains:

```swift
.target(name: "CanopyTickets", dependencies: ["CanopyCore"]),
// CanopyApp: "CanopyTickets" beside "CanopyFixturePlugin"
// CanopyCLI: "CanopyTickets", for `canopy ticket`'s params and output
.testTarget(name: "CanopyTicketsTests", dependencies: ["CanopyCore", "CanopyTickets"], resources: [.copy("Fixtures")]),
```

- `TicketTestSupport.swift` holds `TempDir`, `eventually`, and `enum APIFixture { static func data(_ name: String) throws -> Data; static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T }`, reading `Bundle.module`'s `Fixtures/canopy-api/<name>.json`.

- [ ] **Step 1: Copy the fixtures and note where they came from**

```bash
mkdir -p Tests/CanopyTicketsTests/Fixtures/canopy-api
cp /private/tmp/claude-501/-Users-hindiesuputra-Projects-canopy/6a072daa-6a55-46ba-b185-016cfa1a957e/scratchpad/fixtures/canopy-api/{*.json,SOURCE_COMMIT} Tests/CanopyTicketsTests/Fixtures/canopy-api/
```

`README.md` beside them says they are ticket-manager's `convex/__tests__/fixtures/canopy-api/` at the commit in `SOURCE_COMMIT`, from PR 22, that the stand-in serves them, and to copy them again when the API changes.

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyTickets

struct TicketModelTests {
    @Test func decodesTheOpenList() throws {
        let list = try APIFixture.decode(TicketList.self, "tickets-open")
        #expect(list.tickets.map(\.name) == [
            "ticket-0850-quietcustomer", "ticket-0849-babamachine", "ticket-0853-sameergoyal",
        ])
        let waiting = list.tickets[2]
        #expect(waiting.waiting && waiting.staleHours == 7 && waiting.status == .open)
        #expect(waiting.owner == TicketOwner(email: "hindie@example.com", initials: "HI", via: "action", at: 1_790_001_200_000))
        #expect(list.tickets[0].owner == nil)
    }

    @Test func decodesClosedArchivedAndIdLists() throws {
        #expect(try APIFixture.decode(TicketList.self, "tickets-closed").tickets.map(\.status) == [.closed])
        #expect(try APIFixture.decode(TicketList.self, "tickets-archived").tickets.map(\.status) == [.archived])
        #expect(try APIFixture.decode(TicketList.self, "tickets-ids").tickets.map(\.number) == ["0848", "0853", "0801"])
    }

    @Test func decodesTheDetail() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        #expect(detail.messages.count == 6)
        #expect(detail.messages[0].author.isBot && detail.messages[0].author.shownName == "Ticket Tool")
        #expect(detail.messages[1].attachments.first?.contentType == "image/png")
        #expect(detail.messages[3].thread == MessageThread(id: "1400000000000000002", name: nil))
        #expect(detail.messages[4].thread?.name == "Shadowban check")
        #expect(detail.problems.map(\.isOpen) == [true, false])
        #expect(detail.draft?.sourcesUsed == ["conversation", "solisDb"])
        #expect(detail.notes.first?.authorEmail == "hindie@example.com")
        #expect(detail.handover.hasPrefix("# Handover: ticket-0853-sameergoyal\n"))
    }

    @Test func decodesMeAndErrors() throws {
        #expect(try APIFixture.decode(TicketMe.self, "me").email == "hindie@example.com")
        for (name, code) in [
            ("error-bad-request", "bad_request"), ("error-not-found", "not_found"),
            ("error-not-staff", "not_staff"), ("error-unauthorized", "unauthorized"),
        ] {
            #expect(try APIFixture.decode(TicketAPIErrorBody.self, name).error.code == code)
        }
    }

    @Test func unknownValuesAndMissingFieldsStillDecode() throws {
        let json = #"{"id": "x", "name": "ticket-0001-a", "number": "0001", "customer": "a", "status": "snoozed", "openedAt": 1, "lastActivityAt": 2, "owner": null, "waiting": false, "discordUrl": "u", "extra": 1}"#
        let summary = try JSONDecoder().decode(TicketSummary.self, from: Data(json.utf8))
        #expect(summary.status == .other("snoozed") && summary.staleHours == nil)
        #expect(!summary.status.isClosed)
    }

    @Test func encodingGivesBackTheAPIsKeys() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let again = try JSONDecoder().decode(TicketDetail.self, from: JSONEncoder().encode(detail))
        #expect(again == detail)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail.ticket)) as? [String: Any]
        #expect(raw?["status"] as? String == "open" && raw?["discordUrl"] as? String != nil)
    }
}
```

- [ ] **Step 2b: Run them to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketModelTests`
Expected: FAIL, no module `CanopyTickets`.

- [ ] **Step 3: Write the models and the targets**

`TicketStatus` and `MessageAuthor.Role` decode from a single string, and encode back to it.
`TicketDetail` and the list types decode arrays with `decodeIfPresent(...) ?? []`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter TicketModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CanopyTickets Tests/CanopyTicketsTests
git commit -m "feat: the Tickets plugin's module and ticket-manager's models"
```

## Task 2: The API client behind a transport

**Files:**
- Create: `Sources/CanopyTickets/API/TicketTransport.swift`, `Sources/CanopyTickets/API/TicketAPI.swift`, `Sources/CanopyTickets/API/TicketError.swift`
- Create: `Tests/CanopyTicketsTests/Support/FakeTransport.swift`
- Test: `Tests/CanopyTicketsTests/TicketAPITests.swift`

**Interfaces:**

```swift
public struct HTTPReply: Sendable, Equatable {
    public var status: Int
    /// Keys lowercased.
    public var headers: [String: String]
    public var body: Data
}

public protocol TicketTransport: Sendable {
    /// GETs `url` with `Authorization: Bearer <token>` and `Accept: application/json`. Throws `URLError` when no reply
    /// comes. A redirect comes back as the 3xx reply itself.
    func get(_ url: URL, token: String) async throws -> HTTPReply
}

/// URLSession with an ephemeral configuration: no cookies, no cache, no stored credentials, 15 second timeouts, and a
/// delegate that refuses every redirect, so the token never follows one.
public final class URLSessionTicketTransport: TicketTransport { public init() }

public enum TicketRoute: Sendable, Equatable { case me, list, ticket }

public struct TicketAPI: Sendable {
    public let base: URL
    public init(base: URL, token: String, transport: any TicketTransport)
    public func me() async throws -> String
    public func tickets(status: TicketStatus) async throws -> [TicketSummary]
    /// Up to 50 ids, in the order asked, leaving out ids ticket-manager does not know. A malformed id fails the whole
    /// request with `TicketError.badRequest`.
    public func tickets(ids: [String]) async throws -> [TicketSummary]
    /// The detail, and the response's bytes for ticket.json.
    public func ticket(id: String) async throws -> (detail: TicketDetail, data: Data)
    public static let maximumIDs = 50
}

public enum TicketError: Error, Sendable, Equatable {
    case off(url: String?)
    case notStarted(String)
    case invalidURL(String)
    case tokenRejected(url: String)
    case notStaff(String, url: String)
    case unreachable(String, url: String)
    case badResponse(String, url: String)
    case badRequest(String)
    case notFound(String)
    case ambiguous(String, [String])
    case hasRow(String, path: String)
    case hasNoRow(String)
    case keychain(String)

    public var code: String { get }
    /// What went wrong and how to fix it, in markdown.
    public var message: String { get }
    /// The section's warning for an error only connecting again or ticket-manager's admins fix, else nil.
    public var warning: String? { get }
    /// Errors that say ticket-manager is not answering as it should, which the refresh schedule backs off after.
    public var backsOff: Bool { get }
    public var controlError: ControlError { get }
    /// `error` as a TicketError, or as `.unreachable` with its description for anything else.
    public static func from(_ error: any Error, url: String) -> TicketError
}
```

- Codes: `plugin_off`, `plugin_not_started`, `invalid_url`, `token_rejected`, `not_staff`, `tickets_unreachable`, `bad_response`, `bad_request`, `ticket_not_found`, `ticket_ambiguous`, `ticket_has_row`, `ticket_has_no_row`, `keychain_failed`.
- Status mapping in `TicketAPI`: 200 decodes, and a body that does not decode is `.badResponse`; 400 is `.badRequest` with the server's message; 401 is `.tokenRejected`; 403 is `.notStaff` with the server's message; 404 is `.notFound(id)` on `.ticket` and `.badResponse("no ticket-manager API here (HTTP 404)")` on the other routes; 3xx is `.badResponse("it redirected to <Location>")`; 5xx is `.unreachable("it answered HTTP 502")`; anything else is `.badResponse("it answered HTTP <n>")`.
- Transport failures: `URLError.timedOut` becomes `.unreachable("no answer within 15 seconds")`, any other `URLError` its `localizedDescription`.
- Messages, each with its fix:
  - `.off(url)`: "Tickets is off. Run \`canopy ticket connect <url>\` to connect it."
  - `.tokenRejected(url)`: "ticket-manager at <url> rejected the token. Make a new one and run \`canopy ticket connect <url>\` with it."
  - `.notStaff(message, url)`: "<message>. Canopy picks it up by itself once the email is on ticket-manager's staff list again, or run \`canopy ticket connect <url>\` with another engineer's token."
  - `.unreachable(reason, url)`: "Could not reach ticket-manager at <url>: <reason>."
  - `.badResponse(reason, url)`: "<url> did not answer like ticket-manager: <reason>. Check that it is the deployment's .convex.site address."
  - `.notFound(reference)`: "No ticket matches \"<reference>\". Run \`canopy ticket list\`, with --closed for closed ones."
  - `.ambiguous(reference, names)`: "\"<reference>\" matches <a> and <b>. Pass one of those."
  - `.hasRow(name, path)`: "<name> already has a row at <path>. Run \`canopy ticket select <name>\` to show it."
  - `.hasNoRow(name)`: "<name> has no row. Run \`canopy ticket new <name>\` to open one."
  - `.keychain(description)`: "The Keychain refused: <description>"
- `warning` is the message for `.tokenRejected` and `.notStaff`, and nil for the rest.
- `backsOff` is true for `.tokenRejected`, `.notStaff`, `.unreachable`, and `.badResponse`.
- `FakeTransport` is an actor holding routes by path and query, such as `"/api/v1/tickets?ids=a,b"`, each a reply or a `URLError`, a default of the fixture files for the four routes, a `token` it checks (a wrong one gets the 401 fixture with `WWW-Authenticate: Bearer`), `requests: [URL]`, and `stall(path)` / `release(path)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyTickets

struct TicketAPITests {
    let base = URL(string: "https://tm.example.convex.site")!

    @Test func sendsTheTokenToEachRoute() async throws {
        let transport = FakeTransport(token: "t0k")
        let api = TicketAPI(base: base, token: "t0k", transport: transport)

        #expect(try await api.me() == "hindie@example.com")
        #expect(try await api.tickets(status: .closed).map(\.number) == ["0848"])
        #expect(try await api.tickets(ids: ["a", "b"]).isEmpty == false)
        let (detail, data) = try await api.ticket(id: "0000000000000000000010001tickets")
        #expect(detail.ticket.number == "0853" && data == (try APIFixture.data("ticket-detail")))

        #expect(await transport.requests.map { $0.absoluteString } == [
            "https://tm.example.convex.site/api/v1/me",
            "https://tm.example.convex.site/api/v1/tickets?status=closed",
            "https://tm.example.convex.site/api/v1/tickets?ids=a,b",
            "https://tm.example.convex.site/api/v1/tickets/0000000000000000000010001tickets",
        ])
        #expect(await transport.tokens == ["t0k", "t0k", "t0k", "t0k"])
    }

    @Test func eachStatusBecomesItsError() async throws {
        let transport = FakeTransport(token: "t")
        let api = TicketAPI(base: base, token: "t", transport: transport)
        let url = base.absoluteString
        let cases: [(HTTPReply, TicketError)] = [
            (try .fixture(401, "error-unauthorized"), .tokenRejected(url: url)),
            (try .fixture(403, "error-not-staff"), .notStaff("gone@example.com is not on the staff list", url: url)),
            (try .fixture(400, "error-bad-request"), .badRequest("status must be open, closed, or archived")),
            (.init(status: 502, headers: [:], body: Data()), .unreachable("it answered HTTP 502", url: url)),
            (.init(status: 200, headers: [:], body: Data("<html>".utf8)), .badResponse("its answer was not the JSON Canopy expects", url: url)),
            (.init(status: 302, headers: ["location": "https://elsewhere"], body: Data()), .badResponse("it redirected to https://elsewhere", url: url)),
            (try .fixture(404, "error-not-found"), .badResponse("no ticket-manager API here (HTTP 404)", url: url)),
        ]
        for (reply, error) in cases {
            await transport.set("/api/v1/me", reply)
            await #expect(throws: error) { try await api.me() }
        }
    }

    @Test func aTicketThatIsGoneIsNotFound() async throws {
        let transport = FakeTransport(token: "t")
        await transport.set("/api/v1/tickets/zz", try .fixture(404, "error-not-found"))
        await #expect(throws: TicketError.notFound("zz")) {
            try await TicketAPI(base: base, token: "t", transport: transport).ticket(id: "zz")
        }
    }

    @Test func noAnswerIsUnreachable() async throws {
        let transport = FakeTransport(token: "t")
        await transport.fail("/api/v1/me", URLError(.timedOut))
        await #expect(throws: TicketError.unreachable("no answer within 15 seconds", url: base.absoluteString)) {
            try await TicketAPI(base: base, token: "t", transport: transport).me()
        }
    }

    @Test func errorsMapToCodesWarningsAndBackoff() {
        let url = "https://tm.example.convex.site"
        #expect(TicketError.tokenRejected(url: url).code == "token_rejected")
        #expect(TicketError.tokenRejected(url: url).warning?.contains("canopy ticket connect \(url)") == true)
        #expect(TicketError.notStaff("x", url: url).code == "not_staff")
        #expect(TicketError.unreachable("r", url: url).code == "tickets_unreachable")
        #expect(TicketError.unreachable("r", url: url).warning == nil)
        #expect(TicketError.off(url: nil).message.contains("canopy ticket connect <url>"))
        #expect(TicketError.ambiguous("853", ["0853-a", "0853-b"]).message == "\"853\" matches 0853-a and 0853-b. Pass one of those.")
        #expect([TicketError.unreachable("r", url: url), .badResponse("r", url: url), .tokenRejected(url: url)].allSatisfy(\.backsOff))
        #expect(![TicketError.notFound("1"), .badRequest("b")].contains(where: \.backsOff))
        #expect(TicketError.from(ControlError(code: "x", message: "y"), url: url) == .unreachable("y", url: url))
    }
}
```

`HTTPReply.fixture(_:_:)` in `FakeTransport.swift` makes a reply of that status with the fixture's bytes, and `WWW-Authenticate: Bearer` for 401.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketAPITests`
Expected: FAIL, `TicketAPI` is not defined.

- [ ] **Step 3: Write the transport, the client, and the errors**

URLs are built with `URLComponents`: the base's path with a trailing `/` dropped, then `/api/v1/...`, with each id percent-encoded and the ids joined by commas.
The session's delegate implements `urlSession(_:task:willPerformHTTPRedirection:newRequest:) async -> URLRequest?` returning nil.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter TicketAPITests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets/API Tests/CanopyTicketsTests
git commit -m "feat: a ticket-manager client behind a transport, and its errors"
```

## Task 3: Ticket names and references

**Files:**
- Create: `Sources/CanopyTickets/Tickets/TicketName.swift`
- Test: `Tests/CanopyTicketsTests/TicketReferenceTests.swift`

**Interfaces:**

```swift
/// A ticket's channel name, or a row's title, taken apart: `ticket-0853-sameergoyal`, `closed-0853-sameergoyal`, and
/// `0853-sameergoyal` all have the number 853 and the customer `sameergoyal`.
public struct TicketName: Sendable, Equatable {
    public var number: Int?
    /// As written, such as "0853", for labels.
    public var digits: String?
    public var customer: String?
    public init(_ name: String)
    /// A row's title and folder name: the name without `ticket-` or `closed-`.
    public static func rowTitle(for name: String) -> String
    /// `#0853`, or nil for a name without a number.
    public static func label(for name: String) -> String?
}

/// What an agent typed to name a ticket.
public enum TicketReference: Sendable, Equatable {
    /// `853`, `0853`, `#0853`, `0853-sameergoyal`, `ticket-0853-sameergoyal`, or `closed-0853-sameergoyal`.
    case number(Int, customer: String?)
    /// Anything else is taken as a ticket-manager id.
    case id(String)
    /// Nil for blank text.
    public init?(_ text: String)
    public func matches(_ name: String) -> Bool
}

/// Picks the one ticket a reference names from what the plugin found, looking at the rows' tickets and open tickets
/// first, then closed and archived ones.
public enum TicketResolution {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        /// The channel name, or a row's title.
        public var name: String
    }
    public enum Outcome: Sendable, Equatable {
        case found(String)
        /// Nothing in this stage: look in the next one.
        case none
    }
    /// The ids the reference matches among `candidates`, each once. Throws `.ambiguous` for more than one ticket.
    public static func pick(_ reference: TicketReference, text: String, among candidates: [Candidate]) throws -> Outcome
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing

@testable import CanopyTickets

struct TicketReferenceTests {
    @Test func namesComeApart() {
        #expect(TicketName("ticket-0853-sameergoyal") == TicketName(number: 853, digits: "0853", customer: "sameergoyal"))
        #expect(TicketName("closed-0848-shathrem").number == 848)
        #expect(TicketName("0853-sameer-goyal").customer == "sameer-goyal")
        #expect(TicketName("general").number == nil)
        #expect(TicketName.rowTitle(for: "ticket-0853-sameergoyal") == "0853-sameergoyal")
        #expect(TicketName.rowTitle(for: "closed-0848-shathrem") == "0848-shathrem")
        #expect(TicketName.rowTitle(for: "general") == "general")
        #expect(TicketName.label(for: "0853-sameergoyal") == "#0853")
    }

    @Test func everySpecFormParses() {
        for text in ["853", "0853", " 0853 ", "#0853"] {
            #expect(TicketReference(text) == .number(853, customer: nil), "\(text)")
        }
        for text in ["0853-sameergoyal", "ticket-0853-sameergoyal", "closed-0853-SameerGoyal"] {
            #expect(TicketReference(text) == .number(853, customer: text.hasSuffix("SameerGoyal") ? "SameerGoyal" : "sameergoyal"))
        }
        #expect(TicketReference("0000000000000000000010001tickets") == .id("0000000000000000000010001tickets"))
        #expect(TicketReference("   ") == nil)
    }

    @Test func numbersMatchIgnoringZerosAndCustomersIgnoringCase() {
        #expect(TicketReference("853")!.matches("ticket-0853-sameergoyal"))
        #expect(TicketReference("0853-SAMEERGOYAL")!.matches("closed-0853-sameergoyal"))
        #expect(!TicketReference("0853-other")!.matches("ticket-0853-sameergoyal"))
        #expect(!TicketReference("85")!.matches("ticket-0853-sameergoyal"))
    }

    @Test func pickingFindsOneRefusesTwoAndFallsThrough() throws {
        let a = TicketResolution.Candidate(id: "a", name: "ticket-0853-sameergoyal")
        let row = TicketResolution.Candidate(id: "a", name: "0853-sameergoyal")
        let b = TicketResolution.Candidate(id: "b", name: "closed-0853-other")
        #expect(try TicketResolution.pick(.number(853, customer: nil), text: "853", among: [row, a]) == .found("a"))
        #expect(try TicketResolution.pick(.number(900, customer: nil), text: "900", among: [a]) == .none)
        #expect(throws: TicketError.ambiguous("853", ["0853-other", "0853-sameergoyal"])) {
            try TicketResolution.pick(.number(853, customer: nil), text: "853", among: [a, b])
        }
        #expect(try TicketResolution.pick(.number(853, customer: "other"), text: "0853-other", among: [a, b]) == .found("b"))
        #expect(try TicketResolution.pick(.id("b"), text: "b", among: [a, b]) == .found("b"))
    }
}
```

`TicketName` gets a memberwise `init(number:digits:customer:)` for tests, internal.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketReferenceTests`
Expected: FAIL, `TicketName` is not defined.

- [ ] **Step 3: Write the names and references**

`TicketName` drops a `ticket-` or `closed-` prefix, then reads leading digits and, after a `-`, the rest as the customer.
`TicketReference` drops a leading `#`, and is `.number` when what is left is digits, or a name of that form; otherwise `.id`.
Ambiguity lists each match by its row title, sorted, since each is itself a reference that names one ticket.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter TicketReferenceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets/Tickets/TicketName.swift Tests/CanopyTicketsTests/TicketReferenceTests.swift
git commit -m "feat: ticket names and the references agents type"
```

## Task 4: Listing, the picker's filters and sort, and row looks

**Files:**
- Create: `Sources/CanopyTickets/Tickets/TicketListing.swift`, `Sources/CanopyTickets/Tickets/TicketLook.swift`
- Test: `Tests/CanopyTicketsTests/TicketListingTests.swift`, `Tests/CanopyTicketsTests/TicketLookTests.swift`

**Interfaces:**

```swift
public enum TicketOwnerFilter: String, Sendable, Codable, CaseIterable {
    case mine, unowned, anyone
}

public struct TicketListQuery: Sendable, Equatable {
    public var owner: TicketOwnerFilter
    public var waitingOnly: Bool
    public var text: String
    public init(owner: TicketOwnerFilter = .anyone, waitingOnly: Bool = false, text: String = "")
}

public enum TicketListing {
    /// The picker's chips: Mine, Unowned, and Anyone, starting on Anyone, and a Closed toggle.
    public static let filters: PluginFilters
    /// Keeps the tickets the query asks for, searching the name and the customer, then sorts them as the picker does:
    /// waiting customers first, then latest activity. `me` is the connected engineer's email, for Mine.
    public static func list(_ tickets: [TicketSummary], _ query: TicketListQuery, me: String?) -> [TicketSummary]
    /// The picker's line: the row title, "<customer> · <age>", the waiting dot, the owner's initials, and "closed" or
    /// "archived" for a ticket that is.
    public static func item(_ ticket: TicketSummary, now: Date) -> PluginItem
}

public enum TicketAge {
    /// "now", "12m", "7h", "3d", "2w", "5mo", "1y".
    public static func span(from start: Date, to end: Date) -> String
    /// "just now", "20 s ago", "3 min ago", "2 h ago", "4 d ago", for status lines, the footer, and the banner.
    public static func ago(_ date: Date, now: Date) -> String
}

public enum TicketLook {
    /// The row's look: label `#0853`, an orange dot while the customer waits, "closed" while closed or archived, and
    /// missing when ticket-manager no longer has the ticket. Without a summary, only the label from the title.
    public static func look(title: String, summary: TicketSummary?, isMissing: Bool) -> PluginRowLook
    public static func accessories(_ ticket: TicketSummary, withOwner: Bool) -> [PluginAccessory]
    /// The same color for an engineer everywhere, from their email.
    public static func ownerColor(_ email: String) -> PluginColor
}
```

- Mine compares the owner's email to `me` ignoring case; Mine with `me` nil lists nothing.
- The waiting dot is `.dot(.orange, help: "Customer waiting")`, the tag `.tag("closed", help: "Closed")` or `.tag("archived", help: "Archived")` in the picker, and always `"closed"` on a row, as the spec says.
- Owner initials are `.initials(owner.initials, color: ownerColor(owner.email), help: "Owned by <email>")`, in the picker only.
- `ownerColor` picks from blue, green, purple, red, and accent by an FNV-1a hash of the lowercased email, never orange, which means waiting.

- [ ] **Step 1: Write the failing tests**

```swift
import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

struct TicketListingTests {
    let open = try! APIFixture.decode(TicketList.self, "tickets-open").tickets
    let closed = try! APIFixture.decode(TicketList.self, "tickets-closed").tickets
        + APIFixture.decode(TicketList.self, "tickets-archived").tickets

    func names(_ query: TicketListQuery, _ tickets: [TicketSummary]? = nil, me: String? = "hindie@example.com") -> [String] {
        TicketListing.list(tickets ?? open, query, me: me).map(\.number)
    }

    @Test func waitingFirstThenLatestActivity() {
        #expect(names(TicketListQuery()) == ["0853", "0850", "0849"])
        #expect(names(TicketListQuery(), closed) == ["0848", "0801"])
    }

    @Test func mineUnownedAnyoneAndWaiting() {
        #expect(names(TicketListQuery(owner: .mine)) == ["0853"])
        #expect(names(TicketListQuery(owner: .mine), me: "HINDIE@example.com") == ["0853"])
        #expect(names(TicketListQuery(owner: .mine), me: nil).isEmpty)
        #expect(names(TicketListQuery(owner: .unowned)) == ["0850"])
        #expect(names(TicketListQuery(waitingOnly: true)) == ["0853"])
    }

    @Test func searchMatchesNameAndCustomer() {
        #expect(names(TicketListQuery(text: "baba")) == ["0849"])
        #expect(names(TicketListQuery(text: "0850")) == ["0850"])
        #expect(names(TicketListQuery(text: "ticket quiet")) == ["0850"])
    }

    @Test func thePickersFilters() {
        #expect(TicketListing.filters.choices.map(\.id) == ["mine", "unowned", "anyone"])
        #expect(TicketListing.filters.defaultChoice == "anyone")
        #expect(TicketListing.filters.toggles.map(\.id) == ["closed"])
    }

    @Test func pickerItems() {
        let now = Date(timeIntervalSince1970: 1_790_030_000)
        let item = TicketListing.item(open[2], now: now)
        #expect(item.id == "0000000000000000000010001tickets")
        #expect(item.title == "0853-sameergoyal")
        #expect(item.subtitle == "sameergoyal · 7h ago")
        #expect(item.accessories.map(\.kind) == [.dot, .initials])
        #expect(TicketListing.item(closed[1], now: now).accessories.map(\.text) == ["archived"])
    }

    @Test func ages() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(TicketAge.span(from: now.addingTimeInterval(-25_200), to: now) == "7h")
        #expect(TicketAge.span(from: now.addingTimeInterval(-30), to: now) == "now")
        #expect(TicketAge.ago(now.addingTimeInterval(-20), now: now) == "20 s ago")
        #expect(TicketAge.ago(now.addingTimeInterval(-180), now: now) == "3 min ago")
        #expect(TicketAge.ago(now.addingTimeInterval(-2), now: now) == "just now")
    }
}
```

```swift
struct TicketLookTests {
    @Test func aWaitingOpenTicket() throws {
        let ticket = try APIFixture.decode(TicketList.self, "tickets-open").tickets[2]
        let look = TicketLook.look(title: "0853-sameergoyal", summary: ticket, isMissing: false)
        #expect(look == PluginRowLook(label: "#0853", accessories: [.dot(.orange, help: "Customer waiting")]))
    }

    @Test func closedAndArchivedTicketsAreTaggedClosed() throws {
        for fixture in ["tickets-closed", "tickets-archived"] {
            let ticket = try APIFixture.decode(TicketList.self, fixture).tickets[0]
            let look = TicketLook.look(title: TicketName.rowTitle(for: ticket.name), summary: ticket, isMissing: false)
            #expect(look.accessories == [.tag("closed", help: ticket.status == .closed ? "Closed" : "Archived")])
        }
    }

    @Test func withoutASummaryOnlyTheLabel() {
        #expect(TicketLook.look(title: "0853-sameergoyal", summary: nil, isMissing: false) == PluginRowLook(label: "#0853"))
        #expect(TicketLook.look(title: "0853-sameergoyal", summary: nil, isMissing: true).isMissing)
    }

    @Test func ownersKeepTheirColorAndNeverTakeOrange() {
        #expect(TicketLook.ownerColor("hindie@example.com") == TicketLook.ownerColor("HINDIE@example.com"))
        let colors = Set((0..<200).map { TicketLook.ownerColor("user\($0)@example.com") })
        #expect(!colors.contains(.orange) && colors.count > 2)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'TicketListingTests|TicketLookTests'`
Expected: FAIL, `TicketListing` is not defined.

- [ ] **Step 3: Write the listing, ages, and looks**

Search uses CanopyCore's `SearchText` over `[name, customer]`.
The sort is `(waiting ? 0 : 1, -lastActivityAt, number)`, so equal times keep a fixed order.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'TicketListingTests|TicketLookTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets/Tickets Tests/CanopyTicketsTests
git commit -m "feat: the tickets picker's filters and sort, and ticket rows' looks"
```

## Task 5: `ticket.md` and `ticket.json`

**Files:**
- Create: `Sources/CanopyTickets/Tickets/TicketFiles.swift`
- Test: `Tests/CanopyTicketsTests/TicketFilesTests.swift`

**Interfaces:**

```swift
public enum TicketFiles {
    public static let markdownName = "ticket.md"
    public static let jsonName = "ticket.json"
    /// The handover block, then a line saying Canopy rewrites the file and how to get the latest.
    public static func markdown(handover: String) -> String
    /// Writes both files into `folder` from a response's bytes, each only when its contents change. `ticket.json`'s
    /// modification date is set to `fetchedAt` either way, so it says when the ticket was last fetched. Returns whether
    /// either file changed. A folder that is not there is left alone.
    @discardableResult
    public static func write(detail: TicketDetail, data: Data, fetchedAt: Date, into folder: String) throws -> Bool
    /// The last response saved in `folder`, and when it was fetched, or nil when there is none or it does not decode.
    public static func read(from folder: String) -> CachedTicket?
}

public struct CachedTicket: Sendable, Equatable {
    public var detail: TicketDetail
    public var data: Data
    public var fetchedAt: Date
}
```

- The line after the handover is: `_Canopy rewrites this file when it fetches a newer copy of the ticket. Run \`canopy ticket show --md\` for the latest._`, after a blank line, with a trailing newline.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyTickets

struct TicketFilesTests {
    @Test func writesTheHandoverAndTheResponse() throws {
        let dir = try TempDir()
        let data = try APIFixture.data("ticket-detail")
        let detail = try JSONDecoder().decode(TicketDetail.self, from: data)
        let fetched = Date(timeIntervalSince1970: 1_790_000_000)

        #expect(try TicketFiles.write(detail: detail, data: data, fetchedAt: fetched, into: dir.path))

        let markdown = try String(contentsOfFile: dir.sub("ticket.md"), encoding: .utf8)
        #expect(markdown.hasPrefix(detail.handover + "\n\n_Canopy rewrites this file"))
        #expect(markdown.hasSuffix("for the latest._\n"))
        #expect(TicketFiles.read(from: dir.path) == CachedTicket(detail: detail, data: data, fetchedAt: fetched))
    }

    @Test func rewritesOnlyWhatChanged() throws {
        let dir = try TempDir()
        let data = try APIFixture.data("ticket-detail")
        var detail = try JSONDecoder().decode(TicketDetail.self, from: data)
        try TicketFiles.write(detail: detail, data: data, fetchedAt: .now, into: dir.path)
        let inode = try FileManager.default.attributesOfItem(atPath: dir.sub("ticket.md"))[.systemFileNumber] as? Int

        let later = Date().addingTimeInterval(60)
        #expect(try !TicketFiles.write(detail: detail, data: data, fetchedAt: later, into: dir.path))
        #expect(try FileManager.default.attributesOfItem(atPath: dir.sub("ticket.md"))[.systemFileNumber] as? Int == inode)
        #expect(TicketFiles.read(from: dir.path)?.fetchedAt.timeIntervalSince1970.rounded() == later.timeIntervalSince1970.rounded())

        detail.handover += "\nMore."
        #expect(try TicketFiles.write(detail: detail, data: try JSONEncoder().encode(detail), fetchedAt: later, into: dir.path))
    }

    @Test func aMissingFolderIsLeftAloneAndABadFileReadsAsNone() throws {
        let dir = try TempDir()
        let data = try APIFixture.data("ticket-detail")
        let detail = try JSONDecoder().decode(TicketDetail.self, from: data)
        #expect(try !TicketFiles.write(detail: detail, data: data, fetchedAt: .now, into: dir.sub("gone")))
        #expect(!FileManager.default.fileExists(atPath: dir.sub("gone")))
        try "{".write(toFile: dir.sub("ticket.json"), atomically: true, encoding: .utf8)
        #expect(TicketFiles.read(from: dir.path) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketFilesTests`
Expected: FAIL.

- [ ] **Step 3: Write the files**

Each write is `Data.write(to:options: .atomic)` after comparing with the bytes already there.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter TicketFilesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets/Tickets/TicketFiles.swift Tests/CanopyTicketsTests/TicketFilesTests.swift
git commit -m "feat: ticket.md and ticket.json in each ticket row's folder"
```

## Task 6: The refresh schedule and its clock

**Files:**
- Create: `Sources/CanopyTickets/Refresh/RefreshSchedule.swift`, `Sources/CanopyTickets/Refresh/TicketClock.swift`
- Create: `Tests/CanopyTicketsTests/Support/ManualClock.swift`
- Test: `Tests/CanopyTicketsTests/RefreshScheduleTests.swift`, `Tests/CanopyTicketsTests/ManualClockTests.swift`

**Interfaces:**

```swift
/// Time for the refresh loop, which tests move by hand.
public protocol TicketClock: Sendable {
    var now: ContinuousClock.Instant { get }
    /// The wall-clock time, for "updated 20 s ago".
    var date: Date { get }
    /// Returns at `deadline`, or at once when the calling task is cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async
}

public struct SystemTicketClock: TicketClock { public init() }

/// When the plugin asks ticket-manager for what: pure, so tests step it through time.
public struct RefreshSchedule: Sendable, Equatable {
    public enum Job: Sendable, Hashable {
        /// Every row's ticket, through `tickets?ids=`.
        case rows
        /// One ticket's detail, through `tickets/<id>`.
        case ticket(String)
    }

    /// What the plugin watches.
    public struct Watch: Sendable, Equatable {
        public var isVisible: Bool
        public var hasRows: Bool
        /// The selected row's ticket.
        public var selected: String?
    }

    public static let rowsEvery: Duration = .seconds(60)
    public static let selectedEvery: Duration = .seconds(30)
    public static let nudgeGap: Duration = .seconds(15)
    public static let longestWait: Duration = .seconds(300)

    public init()
    /// Jobs due now, while the window can be seen: the rows, the selected ticket, and tickets nudged or queued.
    public func due(at now: ContinuousClock.Instant, _ watch: Watch) -> [Job]
    /// When the next job falls due, or nil while the window cannot be seen or nothing is scheduled.
    public func nextDue(after now: ContinuousClock.Instant, _ watch: Watch) -> ContinuousClock.Instant?
    /// The ticket was just selected, or the window came to the front: due at once, unless tried in the last 15 seconds.
    public mutating func nudge(_ ticket: String)
    /// A row's ticket changed on ticket-manager: fetch its detail once at the next chance, 15 seconds after the last try.
    public mutating func queue(_ ticket: String)
    public mutating func started(_ job: Job, at now: ContinuousClock.Instant)
    /// A failure doubles the job's wait, up to five minutes. A success returns it, and every other job, to the usual pace.
    public mutating func finished(_ job: Job, at now: ContinuousClock.Instant, succeeded: Bool)
    /// Forgets a ticket that no longer has a row and is not selected.
    public mutating func forget(_ ticket: String)
}
```

- A job in flight is never due.
- The rows are due when there are rows and they were never tried, or `rowsEvery << failures` has passed since the last try, capped at `longestWait`.
- The selected ticket is due when never tried, or `selectedEvery << failures` has passed, capped at `longestWait`.
- A nudged or queued ticket is due once `nudgeGap` has passed since its last try, and the mark clears when it starts.
- `ManualClock` holds a virtual instant and date, `advance(by:)`, and `sleepers`, the number of tasks sleeping on it, so a test can wait for the loop to settle before moving time.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyTickets

struct RefreshScheduleTests {
    let t0 = ContinuousClock.now
    let seen = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: "a")

    func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    @Test func rowsEveryMinuteAndTheSelectedTicketEveryHalfMinute() {
        var schedule = RefreshSchedule()
        #expect(Set(schedule.due(at: at(0), seen)) == [.rows, .ticket("a")])
        schedule.started(.rows, at: at(0)); schedule.finished(.rows, at: at(1), succeeded: true)
        schedule.started(.ticket("a"), at: at(0)); schedule.finished(.ticket("a"), at: at(1), succeeded: true)

        #expect(schedule.due(at: at(29), seen).isEmpty)
        #expect(schedule.nextDue(after: at(1), seen) == at(30))
        #expect(schedule.due(at: at(30), seen) == [.ticket("a")])
        #expect(Set(schedule.due(at: at(60), seen)) == [.rows, .ticket("a")])
    }

    @Test func nothingWhileTheWindowIsHidden() {
        let schedule = RefreshSchedule()
        let hidden = RefreshSchedule.Watch(isVisible: false, hasRows: true, selected: "a")
        #expect(schedule.due(at: at(0), hidden).isEmpty)
        #expect(schedule.nextDue(after: at(0), hidden) == nil)
    }

    @Test func noRowsNoRowsJob() {
        let schedule = RefreshSchedule()
        #expect(schedule.due(at: at(0), RefreshSchedule.Watch(isVisible: true, hasRows: false, selected: nil)).isEmpty)
    }

    @Test func failuresDoubleTheWaitUpToFiveMinutesAndASuccessResetsIt() {
        var schedule = RefreshSchedule()
        let watch = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: nil)
        var now = 0
        var waits: [Int] = []
        for _ in 0..<6 {
            schedule.started(.rows, at: at(now)); schedule.finished(.rows, at: at(now), succeeded: false)
            let next = schedule.nextDue(after: at(now), watch)!
            waits.append(Int((next - at(now)).components.seconds))
            now += waits.last!
        }
        #expect(waits == [120, 240, 300, 300, 300, 300])
        schedule.started(.rows, at: at(now)); schedule.finished(.rows, at: at(now), succeeded: true)
        #expect(schedule.nextDue(after: at(now), watch) == at(now + 60))
    }

    @Test func aNudgeFetchesAtOnceButNotTwiceInFifteenSeconds() {
        var schedule = RefreshSchedule()
        schedule.started(.ticket("a"), at: at(0)); schedule.finished(.ticket("a"), at: at(0), succeeded: true)
        schedule.started(.rows, at: at(0)); schedule.finished(.rows, at: at(0), succeeded: true)
        schedule.nudge("a")
        #expect(schedule.due(at: at(10), seen).isEmpty)
        #expect(schedule.nextDue(after: at(10), seen) == at(15))
        #expect(schedule.due(at: at(15), seen) == [.ticket("a")])
        schedule.started(.ticket("a"), at: at(15))
        #expect(schedule.due(at: at(16), seen).isEmpty)
    }

    @Test func aQueuedTicketIsFetchedOnceEvenWhenNotSelected() {
        var schedule = RefreshSchedule()
        let watch = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: nil)
        schedule.started(.rows, at: at(0)); schedule.finished(.rows, at: at(0), succeeded: true)
        schedule.queue("b")
        #expect(schedule.due(at: at(1), watch) == [.ticket("b")])
        schedule.started(.ticket("b"), at: at(1)); schedule.finished(.ticket("b"), at: at(2), succeeded: true)
        #expect(schedule.due(at: at(59), watch).isEmpty)
    }

    @Test func aJobInFlightIsNeverDue() {
        var schedule = RefreshSchedule()
        schedule.started(.rows, at: at(0))
        #expect(!schedule.due(at: at(600), seen).contains(.rows))
    }
}
```

```swift
struct ManualClockTests {
    @Test func sleepersWakeWhenTimePassesTheirDeadline() async {
        let clock = ManualClock()
        let woke = Task { await clock.sleep(until: clock.now + .seconds(30)); return clock.now }
        #expect(await eventually { clock.sleepers == 1 })
        clock.advance(by: .seconds(29))
        #expect(clock.sleepers == 1)
        clock.advance(by: .seconds(1))
        #expect(await woke.value == clock.now)
    }

    @Test func cancellingWakesASleeper() async {
        let clock = ManualClock()
        let sleeping = Task { await clock.sleep(until: clock.now + .seconds(3600)) }
        #expect(await eventually { clock.sleepers == 1 })
        sleeping.cancel()
        await sleeping.value
        #expect(clock.sleepers == 0)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'RefreshScheduleTests|ManualClockTests'`
Expected: FAIL.

- [ ] **Step 3: Write the schedule and the clocks**

`ManualClock` keeps its sleepers in a `Mutex<[UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Never>)]>` and resumes each once, from `advance` or from `withTaskCancellationHandler`'s `onCancel`, whichever takes it out of the dictionary first.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'RefreshScheduleTests|ManualClockTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets/Refresh Tests/CanopyTicketsTests
git commit -m "feat: the tickets refresh schedule, with backoff, on a clock tests control"
```

## Task 7: Discord's markdown

**Files:**
- Create: `Sources/CanopyTickets/Discord/DiscordMarkdown.swift`
- Test: `Tests/CanopyTicketsTests/DiscordMarkdownTests.swift`

**Interfaces:**

```swift
public struct DiscordStyle: OptionSet, Sendable, Hashable {
    public static let bold, italic, underline, strikethrough, code, spoiler: DiscordStyle
}

/// A run of text with one style: plain text, a link, a mention, or a custom emoji.
public struct DiscordSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case link(URL)
        /// `@Sameer Goyal`, `#ticket-0853-sameergoyal`, or `@role`, drawn as a mention.
        case mention
        /// `:name:` for a custom emoji.
        case emoji
    }
    public var text: String
    public var style: DiscordStyle
    public var kind: Kind
}

public enum DiscordBlock: Sendable, Equatable {
    case paragraph([DiscordSpan])
    case code(language: String?, text: String)
    case quote([DiscordBlock])
}

/// What mentions in a message's text name: its mentions list for users, and the ticket's channel and threads for
/// channels, since the API names no other channels.
public struct DiscordNames: Sendable, Equatable {
    public var users: [String: String]
    public var channels: [String: String]
    public init(message: TicketMessage, ticket: TicketSummary, threads: [MessageThread])
}

public enum DiscordMarkdown {
    public static func parse(_ text: String, names: DiscordNames) -> [DiscordBlock]
    /// The text as a person reads it, with mentions and emoji written out and markup dropped, for `canopy ticket show`.
    public static func plain(_ text: String, names: DiscordNames) -> String
}
```

- Blocks: fenced code blocks (```` ```lang ```` on the opening line, taken as the language only when it is one word and more lines follow), `> ` quote lines, and `>>> ` quoting the rest of the message; everything else is paragraphs split at blank lines, keeping single newlines as text.
- Inline, in this order at each position: a backslash escape, inline code (one or two backticks), `<@id>` and `<@!id>` as `@name` (or `@unknown-user`), `<@&id>` as `@role`, `<#id>` as `#name` (or `#channel`), `<:name:id>` and `<a:name:id>` as `:name:`, `<t:seconds>` and `<t:seconds:style>` as a local date and time, `<https://…>` as a link, `[text](https://…)` as a link, bare `http://` and `https://` URLs as links (trailing `.,:;!?)` left out), then `***`, `**`, `__`, `~~`, `||`, `*`, and `_` pairs.
- A delimiter with no closing partner, or with nothing between, is plain text.
- `_` opens only after start or a character that is not a letter or digit, and closes only before end or one, so `snake_case_names` stays plain.
- The ticket's own channel id comes from the last path part of `ticket.discordUrl`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyTickets

struct DiscordMarkdownTests {
    let names = DiscordNames(users: ["111": "Sameer Goyal"], channels: ["1300000000000000853": "ticket-0853-sameergoyal"])

    func spans(_ text: String) -> [DiscordSpan] {
        guard case .paragraph(let spans) = DiscordMarkdown.parse(text, names: names).first else { return [] }
        return spans
    }

    func span(_ text: String, _ style: DiscordStyle = [], _ kind: DiscordSpan.Kind = .text) -> DiscordSpan {
        DiscordSpan(text: text, style: style, kind: kind)
    }

    @Test func emphasis() {
        #expect(spans("Checked the **shadowban** flag") == [span("Checked the "), span("shadowban", .bold), span(" flag")])
        #expect(spans("*a* _b_ __c__ ~~d~~ ***e***") == [
            span("a", .italic), span(" "), span("b", .italic), span(" "), span("c", .underline), span(" "),
            span("d", .strikethrough), span(" "), span("e", [.bold, .italic]),
        ])
        #expect(spans("**bold with *italic* inside**") == [
            span("bold with ", .bold), span("italic", [.bold, .italic]), span(" inside", .bold),
        ])
        #expect(spans("||secret||") == [span("secret", .spoiler)])
    }

    @Test func unbalancedAndIntrawordMarkersStayText() {
        #expect(spans("2 ** 3 and a*") == [span("2 ** 3 and a*")])
        #expect(spans("snake_case_names") == [span("snake_case_names")])
        #expect(spans("\\*not italic\\*") == [span("*not italic*")])
        #expect(spans("****") == [span("****")])
    }

    @Test func inlineCodeKeepsMarkupAsIs() {
        #expect(spans("run `a **b** c` now") == [span("run "), span("a **b** c", .code), span(" now")])
        #expect(spans("``has ` inside``") == [span("has ` inside", .code)])
    }

    @Test func codeBlocksWithAndWithoutALanguage() {
        let blocks = DiscordMarkdown.parse("Before\n```swift\nlet a = 1\n**not bold**\n```\nAfter", names: names)
        #expect(blocks == [
            .paragraph([span("Before")]), .code(language: "swift", text: "let a = 1\n**not bold**"),
            .paragraph([span("After")]),
        ])
        #expect(DiscordMarkdown.parse("```\nplain\n```", names: names) == [.code(language: nil, text: "plain")])
        #expect(DiscordMarkdown.parse("```one line```", names: names) == [.code(language: nil, text: "one line")])
    }

    @Test func linksMentionsChannelsAndEmoji() {
        let url = URL(string: "https://solis.app/help")!
        #expect(spans("See https://solis.app/help.") == [span("See "), span("https://solis.app/help", [], .link(url)), span(".")])
        #expect(spans("[the docs](https://solis.app/help)") == [span("the docs", [], .link(url))])
        #expect(spans("<https://solis.app/help>") == [span("https://solis.app/help", [], .link(url))])
        #expect(spans("Welcome <@111>!") == [span("Welcome "), span("@Sameer Goyal", [], .mention), span("!")])
        #expect(spans("<@!999>") == [span("@unknown-user", [], .mention)])
        #expect(spans("<#1300000000000000853> <#42>") == [
            span("#ticket-0853-sameergoyal", [], .mention), span(" "), span("#channel", [], .mention),
        ])
        #expect(spans("<@&7>") == [span("@role", [], .mention)])
        #expect(spans("ok <:pepe_ok:123> <a:party:456>") == [
            span("ok "), span(":pepe_ok:", [], .emoji), span(" "), span(":party:", [], .emoji),
        ])
    }

    @Test func quotes() {
        #expect(DiscordMarkdown.parse("> quoted\nnot", names: names) == [
            .quote([.paragraph([span("quoted")])]), .paragraph([span("not")]),
        ])
        #expect(DiscordMarkdown.parse(">>> all\nof this", names: names) == [.quote([.paragraph([span("all\nof this")])])])
    }

    @Test func plainTextForTheCLI() {
        #expect(DiscordMarkdown.plain("Thanks <@111>, **looking** into `it`.", names: names) == "Thanks @Sameer Goyal, looking into it.")
        #expect(DiscordMarkdown.plain("```\ncode\n```", names: names) == "```\ncode\n```")
    }

    @Test func namesComeFromTheMessageAndTheTicket() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let names = DiscordNames(
            message: detail.messages[0], ticket: detail.ticket, threads: detail.messages.compactMap(\.thread))
        #expect(names.users["111"] == "Sameer Goyal")
        #expect(names.channels["1300000000000000853"] == "ticket-0853-sameergoyal")
        #expect(names.channels["1400000000000000001"] == "Shadowban check")
        #expect(names.channels["1400000000000000002"] == nil)
    }
}
```

`DiscordNames` also gets a memberwise `init(users:channels:)`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter DiscordMarkdownTests`
Expected: FAIL.

- [ ] **Step 3: Write the parser**

A recursive descent over the text's characters: `parseInline(_ text: Substring, style: DiscordStyle) -> [DiscordSpan]` tries each rule at each position, finds a closing delimiter with `range(of:)` from the opening one's end, parses the inside with the style added, and merges neighbouring spans of the same style and kind.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter DiscordMarkdownTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets/Discord/DiscordMarkdown.swift Tests/CanopyTicketsTests/DiscordMarkdownTests.swift
git commit -m "feat: Discord markdown, mentions, and custom emoji for ticket messages"
```

## Task 8: Message groups, attachments, and plain-text output

**Files:**
- Create: `Sources/CanopyTickets/Discord/MessageGroups.swift`, `Sources/CanopyTickets/Tickets/TicketText.swift`
- Test: `Tests/CanopyTicketsTests/MessageGroupTests.swift`, `Tests/CanopyTicketsTests/TicketTextTests.swift`

**Interfaces:**

```swift
/// Messages that share one header, as Discord groups them: one author's messages in one place, each within seven
/// minutes of the one before.
public struct MessageGroup: Sendable, Equatable, Identifiable {
    public var messages: [TicketMessage]
    /// The first message's id.
    public var id: String
    public var author: MessageAuthor
    public var posted: Date
    /// "in thread Shadowban check", or "in a thread" when the API has no name for it, or nil outside threads.
    public var threadLabel: String?
    public static let window: TimeInterval = 420
    public static func groups(_ messages: [TicketMessage]) -> [MessageGroup]
}

public enum MessageTime {
    /// "Today at 15:04", "Yesterday at 09:10", or the date and time, in the locale's short forms.
    public static func text(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String
}

public extension MessageAttachment {
    enum Kind: Sendable, Equatable { case image, file }
    var kind: Kind { get }  // image/* content types, or png, jpg, jpeg, gif, webp, heic file names
    /// Discord's signed links stop working at their `ex` time, a hex count of seconds.
    func isExpired(now: Date) -> Bool
    /// "47 KB", "1 KB", "3.2 MB".
    var sizeText: String { get }
}

public enum TicketText {
    /// `canopy ticket list`'s lines: the row title, "waiting 7h" or "2h ago", the owner's initials, and the row's
    /// folder with `~` for the home folder, lined up, without trailing spaces.
    public static func listLines(_ entries: [TicketListEntry], now: Date, homeFolder: String) -> [String]
    /// `canopy ticket show`: the header, the messages as plain text, the problems, the draft, the notes, and the fix
    /// rows.
    public static func show(_ result: TicketShowResult, now: Date, homeFolder: String) -> String
}
```

- `TicketListEntry` and `TicketShowResult` are defined in Task 10's `TicketMethods.swift`; this task defines them there first, as:

```swift
public struct TicketListEntry: Sendable, Equatable, Codable {
    public var ticket: TicketSummary
    /// The ticket's row, or null.
    public var row: PluginRow?
}

public struct TicketShowResult: Sendable, Equatable, Codable {
    public var ticket: TicketDetail
    /// Milliseconds since the epoch.
    public var fetchedAt: Int64
    /// Why this copy may be old, with how old it is, when ticket-manager could not be reached.
    public var stale: String?
    public var row: PluginRow?
    /// The worktree rows linked to the ticket.
    public var fixRows: [Row]
}
```

- The show text:

```
ticket-0853-sameergoyal · open · sameergoyal · owner HI · waiting 7h
Discord: https://discord.com/channels/1100000000000000000/1300000000000000853
Row: ~/.canopy/plugins/tickets/0853-sameergoyal

Messages
  Ticket Tool (bot) · 20 Sep 2026 at 16:33
    Welcome @Sameer Goyal! Support will be with you shortly.
  Sameer Goyal · 20 Sep 2026 at 16:34
    My automations stopped posting since yesterday.
    screenshot.png (47 KB) https://cdn.discordapp.com/…
  …
  Anish · in thread Shadowban check · 21 Sep 2026 at 01:00
    Checked the shadowban flag, it is clear.

Problems
  open · Automations stopped posting · bug
    - No posts since yesterday
    - Started after the account review
  resolved · Finding the automation export · how-to
    - Asked where the export lives

Draft · ok · 6h ago
  Hi Sameer, the posting worker skipped your accounts after a review flag. …

Notes
  hindie@example.com · 5h ago
    Root cause: the posting worker skips accounts flagged for review.

Fix rows
  fix/shadowban-check · solis-v1 · ~/.canopy/worktrees/solis-v1/fix-shadowban-check
```

- [ ] **Step 1: Write the failing tests**

```swift
import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

struct MessageGroupTests {
    let detail = try! APIFixture.decode(TicketDetail.self, "ticket-detail")

    func message(_ id: String, _ author: String, at seconds: Int64, thread: MessageThread? = nil) -> TicketMessage {
        TicketMessage(
            id: id, discordUrl: nil,
            author: MessageAuthor(username: author, displayName: nil, avatarUrl: nil, role: .customer, isBot: false),
            text: id, mentions: [], attachments: [], postedAt: seconds * 1000, thread: thread)
    }

    @Test func oneAuthorWithinSevenMinutesSharesAHeader() {
        let groups = MessageGroup.groups([
            message("1", "sam", at: 0), message("2", "sam", at: 400), message("3", "sam", at: 830),
            message("4", "ann", at: 840), message("5", "sam", at: 850),
        ])
        #expect(groups.map { $0.messages.map(\.id) } == [["1", "2"], ["3"], ["4"], ["5"]])
    }

    @Test func aThreadStartsAGroupAndSaysSo() {
        let groups = MessageGroup.groups(detail.messages)
        #expect(groups.map(\.threadLabel) == [nil, nil, nil, "in a thread", "in thread Shadowban check", nil])
    }

    @Test func messageTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(MessageTime.text(now.addingTimeInterval(-60), now: now, calendar: calendar, locale: locale).hasPrefix("Today at "))
        #expect(MessageTime.text(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale).hasPrefix("Yesterday at "))
        #expect(!MessageTime.text(now.addingTimeInterval(-864_000), now: now, calendar: calendar, locale: locale).contains("day at"))
    }

    @Test func attachmentsKnowTheirKindSizeAndExpiry() {
        let image = detail.messages[1].attachments[0]
        let csv = detail.messages[5].attachments[0]
        #expect(image.kind == .image && csv.kind == .file)
        #expect(image.sizeText == "47 KB" && csv.sizeText == "1 KB")
        let now = Date(timeIntervalSince1970: 0x6700_0000)
        var signed = image
        signed.url = "https://cdn.discordapp.com/a/b/c.png?ex=66ff0000&is=66fe0000&hm=abc"
        #expect(signed.isExpired(now: now))
        signed.url = "https://cdn.discordapp.com/a/b/c.png?ex=67100000&is=66fe0000&hm=abc"
        #expect(!signed.isExpired(now: now))
        #expect(!image.isExpired(now: now))
    }
}
```

```swift
struct TicketTextTests {
    let now = Date(timeIntervalSince1970: 1_790_030_000)

    @Test func listLinesLineUp() throws {
        let open = try APIFixture.decode(TicketList.self, "tickets-open").tickets
        let row = PluginRow(plugin: "tickets", item: open[2].id, title: "0853-sameergoyal", path: "/Users/me/.canopy/plugins/tickets/0853-sameergoyal")
        let entries = TicketListing.list(open, TicketListQuery(), me: nil).map { TicketListEntry(ticket: $0, row: $0.id == row.item ? row : nil) }
        #expect(TicketText.listLines(entries, now: now, homeFolder: "/Users/me") == [
            "0853-sameergoyal     waiting 7h  HI  ~/.canopy/plugins/tickets/0853-sameergoyal",
            "0850-quietcustomer   1h ago",
            "0849-babamachine     2h ago      AN",
        ])
    }

    @Test func showPrintsEverySection() throws {
        let detail = try APIFixture.decode(TicketDetail.self, "ticket-detail")
        let fix = Row(repoPath: "/r/solis-v1", path: "/Users/me/.canopy/worktrees/solis-v1/fix-shadowban-check", branch: "fix/shadowban-check", head: nil, rowClass: .canopy)
        let result = TicketShowResult(ticket: detail, fetchedAt: 1_790_029_000_000, stale: nil, row: nil, fixRows: [fix])
        let text = TicketText.show(result, now: now, homeFolder: "/Users/me")
        #expect(text.hasPrefix("ticket-0853-sameergoyal · open · sameergoyal · owner HI · waiting 7h\n"))
        for part in [
            "\nMessages\n", "    Welcome @Sameer Goyal! Support will be with you shortly.\n",
            "    screenshot.png (47 KB) https://cdn.discordapp.com/attachments/1300000000000000853/1500000000000000002/screenshot.png\n",
            "  Anish · in thread Shadowban check · ", "    Checked the shadowban flag, it is clear.\n",
            "\nProblems\n  open · Automations stopped posting · bug\n    - No posts since yesterday\n",
            "\nDraft · ok · ", "\nNotes\n  hindie@example.com · ",
            "\nFix rows\n  fix/shadowban-check · ~/.canopy/worktrees/solis-v1/fix-shadowban-check",
        ] {
            #expect(text.contains(part), "\(part)")
        }
    }
}
```

The widths in `listLinesLineUp` are whatever `Table`-style padding gives: two spaces after the longest cell in each column; fix the expected strings to that rule when writing the test.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'MessageGroupTests|TicketTextTests'`
Expected: FAIL.

- [ ] **Step 3: Write the groups, attachments, and text**

Waiting time is `TicketAge.span(from: lastActivity, to: now)`, so it keeps counting between fetches.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'MessageGroupTests|TicketTextTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets Tests/CanopyTicketsTests
git commit -m "feat: message groups, attachments, and ticket text for the CLI"
```

## Task 9: A plugin's own fix for `plugin_off`

**Files:**
- Modify: `Sources/CanopyCore/Plugins/CanopyPlugin.swift`, `Sources/CanopyCore/Plugins/PluginHost.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/PluginHostTests.swift`

**Interfaces:**
- `CanopyPlugin` gains `func turnOnCommand(config: JSONValue) -> String`, defaulting to `canopy plugin enable <id>`, so `plugin_off` for Tickets says `canopy ticket connect <url>`, with the URL config.json holds when it has one.
- `WorkspaceError.pluginOff(String, id: String)` becomes `pluginOff(String, command: String)`, whose message is "<Name> is off. Run \`<command>\` to turn it on."

- [ ] **Step 1: Write the failing test**

`PluginHostTests.aPluginOffSaysHowToTurnItOnItsOwnWay`: a `TestPlugin` built with `turnOn: "canopy test connect"` fails `createRow` with `.pluginOff("Test", command: "canopy test connect")`, and the existing `aPluginWithNoSectionStaysOff` expects `.pluginOff("Test", command: "canopy plugin enable t")`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter PluginHostTests`
Expected: FAIL, the extra argument.

- [ ] **Step 3: Thread the command through**

`requireRunning` builds it from `plugin.turnOnCommand(config: sections[id] ?? .object([:]))`.

- [ ] **Step 4: Run the plugin tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginHostTests|PluginControlTests|FixturePluginTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: a plugin that is off says how to turn it on its own way"
```

## Task 10: The plugin, its store, connecting, and disconnecting

**Files:**
- Create: `Sources/CanopyTickets/Plugin/TicketSettings.swift`, `TicketMethods.swift`, `TicketStore.swift`, `TicketsPlugin.swift`, `TicketsPlugin+Fetching.swift`
- Create: `Tests/CanopyTicketsTests/Support/TicketsHarness.swift`
- Test: `Tests/CanopyTicketsTests/TicketsConnectTests.swift`

**Interfaces:**

```swift
/// The plugin's section of config.json.
public struct TicketSettings: Sendable, Equatable {
    public var url: URL
    public var web: String?
    public var run: String?
    /// Throws `.notStarted` without a usable `url`.
    public init(_ section: JSONValue) throws
    /// `https://` anywhere, `http://` only on this Mac, with a trailing `/` or `/api/v1` dropped.
    public static func url(_ text: String) throws -> URL
    /// The template must be an http or https URL holding `{id}`.
    public static func web(_ text: String) throws -> String
    /// The ticket's page in ticket-manager, from the template.
    public static func webURL(_ template: String, for ticket: TicketSummary) -> URL?
}

public enum TicketMethod {
    public static let plugin = "tickets"
    public static let connect = "tickets.connect"
    public static let disconnect = "tickets.disconnect"
    public static let list = "tickets.list"
    public static let new = "tickets.new"
    public static let show = "tickets.show"
    public static let select = "tickets.select"
    public static let remove = "tickets.remove"
    public static let all: Set<String>
    public static let readOnly: Set<String>  // list, show
}

public struct TicketConnectParams: Codable, Sendable { public var url: String; public var token: String; public var web: String? }
public struct TicketConnectResult: Codable, Sendable, Equatable { public var url: String; public var email: String; public var web: String? }
public struct TicketDisconnectParams: Codable, Sendable { public var force: Bool }
public struct TicketListParams: Codable, Sendable {
    public var target: TargetHint
    public var owner: TicketOwnerFilter
    public var waiting: Bool
    public var query: String?
    public var closed: Bool
}
public struct TicketRefParams: Codable, Sendable { public var target: TargetHint; public var reference: String? }
public struct TicketNewParams: Codable, Sendable {
    public var target: TargetHint; public var reference: String; public var run: String?; public var select: Bool
}
public struct TicketShowParams: Codable, Sendable {
    public var target: TargetHint; public var reference: String?; public var refresh: Bool; public var md: Bool
}
public struct TicketRemoveParams: Codable, Sendable { public var target: TargetHint; public var reference: String?; public var force: Bool }
// TicketListEntry and TicketShowResult as in Task 8.

/// What a ticket's panel shows, kept on the main actor for SwiftUI.
@MainActor
@Observable
public final class TicketStore {
    public nonisolated init()
    public private(set) var url: URL?
    public private(set) var web: String?
    public private(set) var me: String?
    public func ticket(_ id: String) -> TicketViewState
    /// The newest summary for the ticket, from its detail or the rows' refresh.
    public func summary(_ id: String) -> TicketSummary?
    public func webURL(for ticket: TicketSummary) -> URL?
}

public struct TicketViewState: Sendable, Equatable {
    public var detail: TicketDetail?
    public var fetchedAt: Date?
    /// The latest fetch's failure, until one succeeds.
    public var failure: TicketFailure?
    public var isFetching: Bool
    public var isMissing: Bool
}

public struct TicketFailure: Sendable, Equatable {
    public var code: String
    public var message: String
    public var at: Date
}

public actor TicketsPlugin: CanopyPlugin {
    public nonisolated let info: PluginInfo  // tickets, Tickets, "ticket"
    public nonisolated let filters: PluginFilters  // TicketListing.filters
    public nonisolated let methods: Set<String>  // TicketMethod.all
    public nonisolated let readOnlyMethods: Set<String>  // TicketMethod.readOnly
    public nonisolated let store: TicketStore
    public init(transport: any TicketTransport = URLSessionTicketTransport(), clock: any TicketClock = SystemTicketClock())
    /// Fetches the ticket now, as the panel's refresh button does. Failures land in the store.
    public func refresh(_ ticket: String) async
}
```

- `start` reads the settings, then the token from `context.secrets` under `token`, and keeps both; no token is `.notStarted("No token is saved. Run \`canopy ticket connect <url>\`.")`, and a Keychain failure is `.notStarted("The Keychain refused to read the token: <description>")`.
  It then starts the watcher and the loop as tasks of their own (Task 12), and returns without waiting on the network.
- `stop` cancels those tasks, forgets the token, the lists it fetched, and `me`, and empties the store.
  Everything fetched under a start that has since stopped is dropped: each start takes a new generation number, and results check it before they land.
- `status`: "connected as <email> to <url>, updated <ago>" while fetches succeed, "connected to <url>, not fetched yet" before the first, and "<failure message> Last updated <ago>." after a failure.
- `turnOnCommand(config:)`: `canopy ticket connect <url>`, with config's `url` when it has one.
- `tickets.connect`: checks the URL and the `web` template, asks `/api/v1/me` with the token, then saves the token, then `context.turnOn(with: ["url", "web"?])`.
  A rejected token, an unreachable URL, or a bad template saves nothing; a config.json that cannot be written puts back the token that was there before, or deletes the new one.
  When the plugin was already running with the same section, so it did not restart, the new token and email take over at once, and the warning and failures clear.
- `tickets.disconnect`: `context.turnOff(force:)` while on, whose `plugin_busy` stops it before anything is deleted, then deletes the token, and answers `{"disconnected": true}`.
- Every other `tickets.*` method fails with `.off` while the plugin is off, and `.notStarted` with the start's reason while it is on but not started.
- `TicketsHarness` starts a `PluginHost` with a `TicketsPlugin`, a `FakeTransport`, a `ManualClock`, a `MemorySecretStore`, and a `FolderMovingTrash` on a temporary home, with a minimal terminal engine, and gives `call(_ method:, _ params:)` through `host.call` with a target, `connect(token:)`, `setViewing`, and `select(path)`.

- [ ] **Step 1: Write the failing tests**

```swift
import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

@MainActor
struct TicketsConnectTests {
    @Test func connectChecksTheTokenSavesItAndTurnsTheSectionOn() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, config: #"{"minPaneColumns": 90}"#, serverToken: "good")

        let result = try await harness.connect(token: "good", web: "https://tm.example.com/t/{id}")

        #expect(result == TicketConnectResult(url: harness.url, email: "hindie@example.com", web: "https://tm.example.com/t/{id}"))
        #expect(try harness.secrets.read("token") == "good")
        #expect(try PluginConfig.sections(in: harness.home.configFile)["tickets"] == .object([
            "url": .string(harness.url), "web": "https://tm.example.com/t/{id}",
        ]))
        #expect(await harness.host.list().first { $0.id == "tickets" }?.on == true)
        #expect(await harness.store.me == "hindie@example.com")
    }

    @Test func aRejectedTokenSavesNothing() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "good")

        await #expect { try await harness.connect(token: "bad") } throws: { ($0 as? ControlError)?.code == "token_rejected" }
        #expect(try harness.secrets.read("token") == nil)
        #expect(try PluginConfig.sections(in: harness.home.configFile)["tickets"] == nil)
    }

    @Test func urlsMustBeHTTPSOrThisMac() throws {
        #expect(try TicketSettings.url("https://tm.convex.site/").absoluteString == "https://tm.convex.site")
        #expect(try TicketSettings.url("https://tm.convex.site/api/v1").absoluteString == "https://tm.convex.site")
        #expect(try TicketSettings.url("http://127.0.0.1:8123").absoluteString == "http://127.0.0.1:8123")
        #expect(throws: TicketError.self) { try TicketSettings.url("http://tm.convex.site") }
        #expect(throws: TicketError.self) { try TicketSettings.url("tm.convex.site") }
        #expect(throws: TicketError.self) { try TicketSettings.web("https://tm.example.com/tickets") }
    }

    @Test func connectingAgainWithTheSameURLUsesTheNewTokenAtOnce() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "one")
        _ = try await harness.connect(token: "one")
        await harness.transport.setToken("two")
        _ = try? await harness.call(TicketMethod.list, TicketListParams())
        #expect(await harness.section()?.warning?.contains("rejected") == true)

        _ = try await harness.connect(token: "two")

        #expect(await harness.section()?.warning == nil)
        let entries = try await harness.call(TicketMethod.list, TicketListParams()).decode([TicketListEntry].self)
        #expect(entries.count == 3)
        #expect(await harness.transport.tokens.last == "two")
    }

    @Test func offCommandsSayHowToConnect() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        await #expect { try await harness.call(TicketMethod.list, TicketListParams()) } throws: {
            let error = $0 as? ControlError
            return error?.code == "plugin_off" && error?.message.contains("canopy ticket connect <url>") == true
        }
        await #expect { try await harness.host.createRow("tickets", reference: "853", run: nil, select: false) } throws: {
            PluginHost.message($0).contains("canopy ticket connect")
        }
    }

    @Test func noTokenMeansItCannotStartAndSaysSo() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, config: #"{"plugins": {"tickets": {"url": "https://tm.convex.site"}}}"#, serverToken: "t")
        #expect(await harness.section()?.warning?.contains("No token is saved") == true)
        await #expect { try await harness.call(TicketMethod.list, TicketListParams()) } throws: {
            ($0 as? ControlError)?.code == "plugin_not_started"
        }
    }

    @Test func disconnectRefusesWhileProgramsRunAndDeletesNothing() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        _ = try await harness.connect(token: "t")
        let row = try await harness.newRow("853")
        harness.runBusyProgram(in: row)

        await #expect { try await harness.call(TicketMethod.disconnect, TicketDisconnectParams(force: false)) } throws: {
            ($0 as? ControlError)?.code == "plugin_busy"
        }
        #expect(try harness.secrets.read("token") == "t")

        _ = try await harness.call(TicketMethod.disconnect, TicketDisconnectParams(force: true))
        #expect(try harness.secrets.read("token") == nil)
        #expect(harness.terminals.tabs(inRow: row.path).isEmpty)
        _ = try await harness.connect(token: "t")
        #expect(await harness.host.workspace.snapshot.section("tickets")?.rows.map(\.path) == [row.path])
    }

    @Test func statusSaysWhoWhereAndWhen() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        _ = try await harness.connect(token: "t")
        _ = try await harness.call(TicketMethod.list, TicketListParams())
        harness.clock.advance(by: .seconds(20))
        #expect(await harness.host.list().first { $0.id == "tickets" }?.status == "connected as hindie@example.com to \(harness.url), updated 20 s ago")
    }
}
```

`harness.runBusyProgram(in:)` opens a tab with a pane whose foreground program the terminal store reports as busy, the way `PluginHostTests` does with `sleep 30`; the harness uses a bash-backed `ShellSettings` like CanopyCoreTests' fixture so a real `sleep` runs.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketsConnectTests`
Expected: FAIL.

- [ ] **Step 3: Write the settings, methods, store, and plugin lifecycle**

`TicketsPlugin` keeps `connection: Connection?` (settings, token, `TicketAPI`), `generation`, `me`, `lastSuccess`, `lastFailure`, `warningShown`, and `startFailure`.
Fetching goes through one `perform(_:)` in `TicketsPlugin+Fetching.swift` that runs a request, records a success or a failure with the clock's date, sets or clears the section's warning from `TicketError.warning`, and rethrows as `TicketError`.
`handle(_:context:)` converts every `TicketError` to its `controlError` before it leaves the plugin.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter TicketsConnectTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets Tests/CanopyTicketsTests
git commit -m "feat: the Tickets plugin connects with a token it keeps in the Keychain"
```

## Task 11: Tickets as plugin items, rows, and `tickets.*` commands

**Files:**
- Create: `Sources/CanopyTickets/Plugin/TicketsPlugin+Methods.swift`
- Modify: `Sources/CanopyTickets/Plugin/TicketsPlugin.swift`, `TicketsPlugin+Fetching.swift`
- Test: `Tests/CanopyTicketsTests/TicketsCommandTests.swift`

**Interfaces:**
- `items(matching:)`: open tickets, or closed and archived ones with the Closed toggle, fetched afresh when `query.fresh` and filtered from what was fetched otherwise, through `TicketListing.list` and `TicketListing.item`; Mine fetches `me` first when it is not known.
- `resolve`: `TicketReference`, then rows' tickets (by id, and by the title's number and customer) and open tickets afresh, then closed and archived ones fetched together; an id not among rows or fetched lists is asked for with `tickets?ids=`, and one ticket-manager does not know, or finds malformed, is `.notFound`.
  When the open list cannot be fetched and exactly one row's ticket matches, that row's ticket is the answer.
- `seed`: the summary from what was fetched, or `tickets?ids=`, giving the row title for both title and folder, and `run` from the settings.
- `fill`: fetches the detail and writes the files; when the fetch fails, it writes the copy it already has, and fails only without one.
- `pickerCommand(for:)`: `canopy ticket new <row title> --select`.
- `tickets.list`: `[TicketListEntry]` by `TicketListing.list`, each with its row; always fetched afresh.
- `tickets.new`: resolves, fails with `.hasRow` naming the row when the ticket has one (including `item_has_row` from a race, turned into it), and otherwise `context.createRow(for: id, run:, select:)`, answering `PluginRowCreated`.
- `tickets.show`: the ticket the reference names, or the target row's; the cached copy when it is under 30 seconds old and `refresh` is false, else a fetch; a fetch that fails with `.unreachable` or `.badResponse` while a copy is cached answers the copy with `stale` saying why and how old; `md` changes nothing here, the CLI prints `ticket.handover`.
- `tickets.select`: the row's ticket among rows alone, by id, title number, or customer; with no row matching, a full resolve that fails, or `.hasNoRow`.
- `tickets.remove`: the same lookup, then `context.removeRow(row, force:)`, answering `PluginRowRemoved`.
- A detail fetch for a ticket with rows writes each row's files, puts the detail in the store, updates the summary and the look, and a 404 marks the row missing.

- [ ] **Step 1: Write the failing tests**

```swift
import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

@MainActor
struct TicketsCommandTests {
    func connected(_ dir: TempDir, config: String? = nil) async throws -> TicketsHarness {
        let harness = try await TicketsHarness(dir, config: config, serverToken: "t")
        _ = try await harness.connect(token: "t")
        return harness
    }

    @Test func listFiltersSortsAndNamesRows() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")

        func numbers(_ params: TicketListParams) async throws -> [String] {
            try await harness.call(TicketMethod.list, params).decode([TicketListEntry].self).map(\.ticket.number)
        }
        #expect(try await numbers(TicketListParams()) == ["0853", "0850", "0849"])
        #expect(try await numbers(TicketListParams(owner: .mine)) == ["0853"])
        #expect(try await numbers(TicketListParams(owner: .unowned)) == ["0850"])
        #expect(try await numbers(TicketListParams(waiting: true)) == ["0853"])
        #expect(try await numbers(TicketListParams(query: "baba")) == ["0849"])
        #expect(try await numbers(TicketListParams(closed: true)) == ["0848", "0801"])
        let entries = try await harness.call(TicketMethod.list, TicketListParams()).decode([TicketListEntry].self)
        #expect(entries[0].row?.path == row.path && entries[1].row == nil)
    }

    @Test func newOpensAFilledRowAndRefusesASecond() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)

        let created = try await harness.call(TicketMethod.new, TicketNewParams(reference: "0853")).decode(PluginRowCreated.self)

        #expect(created.row.title == "0853-sameergoyal")
        #expect(created.row.path.hasSuffix("/plugins/tickets/0853-sameergoyal"))
        #expect(try String(contentsOfFile: created.row.path + "/ticket.md", encoding: .utf8).hasPrefix("# Handover: ticket-0853-sameergoyal"))
        #expect(FileManager.default.fileExists(atPath: created.row.path + "/ticket.json"))
        await #expect { try await harness.call(TicketMethod.new, TicketNewParams(reference: "853")) } throws: {
            let error = $0 as? ControlError
            return error?.code == "ticket_has_row" && error?.message.contains(created.row.path) == true
        }
    }

    @Test func theConfiguredRunStartsNewRows() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        try await harness.setConfig(["run": "echo from-config"])
        let created = try await harness.call(TicketMethod.new, TicketNewParams(reference: "849")).decode(PluginRowCreated.self)
        #expect(created.pane != nil)
    }

    @Test func referencesResolveNumbersNamesIdsAndClosedTickets() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        for reference in ["853", "#0853", "0853-sameergoyal", "ticket-0853-sameergoyal", "0000000000000000000010001tickets"] {
            #expect(try await harness.host.resolveLink(plugin: "tickets", reference: reference).item == "0000000000000000000010001tickets", "\(reference)")
        }
        #expect(try await harness.host.resolveLink(plugin: "tickets", reference: "closed-0848-shathrem").item == "0000000000000000000010004tickets")
        #expect(try await harness.host.resolveLink(plugin: "tickets", reference: "801").item == "0000000000000000000010005tickets")
        await #expect { try await harness.host.resolveLink(plugin: "tickets", reference: "999") } throws: {
            ($0 as? ControlError)?.code == "ticket_not_found"
        }
        await #expect { try await harness.host.resolveLink(plugin: "tickets", reference: "zzzz") } throws: {
            ($0 as? ControlError)?.code == "ticket_not_found"
        }
    }

    @Test func aNumberTwoTicketsShareIsAmbiguous() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        await harness.transport.addClosed(number: "0853", customer: "other", id: "0000000000000000000010009tickets")
        // Open tickets come first, so the closed one only counts once it has a row.
        #expect(try await harness.host.resolveLink(plugin: "tickets", reference: "853").item == "0000000000000000000010001tickets")
        try await harness.newRow("0853-other")
        await #expect { try await harness.host.resolveLink(plugin: "tickets", reference: "853") } throws: {
            let error = $0 as? ControlError
            return error?.code == "ticket_ambiguous" && error?.message.contains("0853-other") == true
        }
    }

    @Test func inATicketRowCommandsUseItsTicket() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")

        let shown = try await harness.call(TicketMethod.show, TicketShowParams(), in: row).decode(TicketShowResult.self)
        #expect(shown.ticket.ticket.number == "0853" && shown.row?.path == row.path)
        let selected = try await harness.call(TicketMethod.select, TicketRefParams(), in: row).decode(PluginRow.self)
        #expect(selected.path == row.path && harness.ui.selected.last == row.path)
    }

    @Test func showUsesAFreshCopyAndFetchesAnOldOne() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        _ = try await harness.newRow("853")
        let before = await harness.transport.requests.count
        _ = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853"))
        #expect(await harness.transport.requests.count == before)
        harness.clock.advance(by: .seconds(31))
        _ = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853"))
        #expect(await harness.transport.requests.count == before + 1)
        _ = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853", refresh: true))
        #expect(await harness.transport.requests.count == before + 2)
    }

    @Test func showFallsBackToTheCachedCopyWithItsAge() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        _ = try await harness.newRow("853")
        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        harness.clock.advance(by: .seconds(300))

        let shown = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853", refresh: true)).decode(TicketShowResult.self)
        #expect(shown.stale?.contains("5 min ago") == true)
        await #expect { try await harness.call(TicketMethod.list, TicketListParams()) } throws: {
            ($0 as? ControlError)?.code == "tickets_unreachable"
        }
        #expect(await harness.store.ticket(shown.ticket.ticket.id).failure?.code == "tickets_unreachable")

        await harness.transport.failEverything(nil)
        _ = try await harness.call(TicketMethod.show, TicketShowParams(reference: "853", refresh: true))
        #expect(await harness.store.ticket(shown.ticket.ticket.id).failure == nil)
    }

    @Test func selectAndRemoveWorkFromRowsAlone() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        await harness.transport.failEverything(URLError(.cannotConnectToHost))

        _ = try await harness.call(TicketMethod.select, TicketRefParams(reference: "853"))
        let removed = try await harness.call(TicketMethod.remove, TicketRemoveParams(reference: "0853-sameergoyal")).decode(PluginRowRemoved.self)
        #expect(removed.row.path == row.path && removed.trashedTo?.hasPrefix(dir.sub("trash")) == true)
    }

    @Test func selectingATicketWithoutARowSaysHowToOpenOne() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        await #expect { try await harness.call(TicketMethod.select, TicketRefParams(reference: "850")) } throws: {
            let error = $0 as? ControlError
            return error?.code == "ticket_has_no_row" && error?.message.contains("canopy ticket new 0850-quietcustomer") == true
        }
    }

    @Test func aTicketThatIsGoneShowsItsRowMissing() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        await harness.transport.set("/api/v1/tickets/\(row.item)", try .fixture(404, "error-not-found"))

        await #expect { try await harness.call(TicketMethod.show, TicketShowParams(reference: "853", refresh: true)) } throws: {
            ($0 as? ControlError)?.code == "ticket_not_found"
        }
        #expect(await harness.section()?.rows.first?.isMissing == true)
    }

    @Test func thePickerListsOpenOrClosedAndNarrowsWithoutFetching() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let items = { (text: String, choice: String, toggles: Set<String>, fresh: Bool) in
            try await harness.host.items("tickets", matching: PluginQuery(text: text, choice: choice, toggles: toggles, fresh: fresh)).map(\.title)
        }
        #expect(try await items("", "anyone", [], true) == ["0853-sameergoyal", "0850-quietcustomer", "0849-babamachine"])
        let before = await harness.transport.requests.count
        #expect(try await items("quiet", "anyone", [], false) == ["0850-quietcustomer"])
        #expect(try await items("", "mine", [], false) == ["0853-sameergoyal"])
        #expect(await harness.transport.requests.count == before)
        #expect(try await items("", "anyone", ["closed"], true) == ["0848-shathrem", "0801-oldco"])
        #expect(harness.plugin.pickerCommand(for: PluginItem(id: "x", title: "0853-sameergoyal")) == "canopy ticket new 0853-sameergoyal --select")
    }
}
```

`TicketListParams`, `TicketNewParams`, `TicketShowParams`, `TicketRefParams`, and `TicketRemoveParams` get initializers whose arguments all have defaults but `reference` on `TicketNewParams`, with `target` defaulting to `TargetHint()`.
`harness.call(_:_:in:)` puts `TargetHint(row: row.path)` in the params, as the CLI does from `CANOPY_ROW_PATH`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketsCommandTests`
Expected: FAIL.

- [ ] **Step 3: Write the methods**

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'TicketsCommandTests|TicketsConnectTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets Tests/CanopyTicketsTests
git commit -m "feat: ticket rows, references, and the tickets control methods"
```

## Task 12: Refreshing from what the window shows

**Files:**
- Create: `Sources/CanopyTickets/Plugin/TicketsPlugin+Refresh.swift`
- Modify: `Sources/CanopyTickets/Plugin/TicketsPlugin.swift`
- Test: `Tests/CanopyTicketsTests/TicketsRefreshTests.swift`

**Interfaces:**
- The watcher task reads `context.states()`: it keeps `RefreshSchedule.Watch` from `viewing.isWindowVisible`, the rows, and `selectedRow`, nudges the selected ticket when it changes and when `viewing.isFrontmost` turns true, forgets tickets that left, and wakes the loop.
- The loop task, after loading each row's `ticket.json` into the store and showing its look, and asking for `me` in the background: runs what `schedule.due` gives, then sleeps on the clock until `schedule.nextDue`, or an hour when nothing is due, and a wake cancels that sleep.
- The rows job asks `tickets?ids=` for every row's ticket but those known to be malformed, 50 at a time; a batch answered 400 is split in half and each half asked again, down to single ids, and an id answered 400 alone joins the malformed set, which a new start clears.
  It sets each row's look, missing for ids left out or malformed, puts the summaries in the store, and queues the detail of each row's ticket whose summary differs from its cached detail's.
- A ticket job fetches the detail as Task 11 does.
- Every job reports to the schedule when it starts and finishes, succeeded or not by `TicketError.backsOff`.

- [ ] **Step 1: Write the failing tests**

```swift
import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

@MainActor
struct TicketsRefreshTests {
    func connectedWithRows(_ dir: TempDir, _ references: [String]) async throws -> (TicketsHarness, [PluginRow]) {
        let harness = try await TicketsHarness(dir, serverToken: "t")
        _ = try await harness.connect(token: "t")
        var rows: [PluginRow] = []
        for reference in references { rows.append(try await harness.newRow(reference)) }
        await harness.transport.clearRequests()
        return (harness, rows)
    }

    func requests(_ harness: TicketsHarness) async -> [String] {
        await harness.transport.requests.map { $0.path + ($0.query.map { "?" + $0 } ?? "") }
    }

    @Test func rowsEveryMinuteAndTheSelectedTicketEveryHalfMinute() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        harness.setViewing(visible: true, frontmost: false)
        harness.select(rows[0].path)

        #expect(await eventually { await requests(harness).count == 2 })
        #expect(Set(await requests(harness)) == [
            "/api/v1/tickets?ids=\(rows[0].item),\(rows[1].item)", "/api/v1/tickets/\(rows[0].item)",
        ])
        await harness.settle()
        harness.clock.advance(by: .seconds(30))
        #expect(await eventually { await requests(harness).count == 3 })
        await harness.settle()
        harness.clock.advance(by: .seconds(30))
        #expect(await eventually { await requests(harness).count == 5 })
    }

    @Test func nothingIsFetchedWhileTheWindowIsHiddenAndOnceWhenItShows() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853"])
        harness.select(rows[0].path)
        harness.setViewing(visible: false, frontmost: false)
        await harness.settle()
        harness.clock.advance(by: .seconds(3600))
        await harness.settle()
        #expect(await requests(harness).isEmpty)

        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).count == 2 })
        await harness.settle()
        #expect(await requests(harness).count == 2)
    }

    @Test func selectingOrComingToTheFrontFetchesAtMostEveryFifteenSeconds() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        harness.setViewing(visible: true, frontmost: true)
        harness.select(rows[0].path)
        #expect(await eventually { await requests(harness).count == 2 })
        await harness.settle()

        harness.select(rows[1].path)
        #expect(await eventually { await requests(harness).last == "/api/v1/tickets/\(rows[1].item)" })
        harness.select(rows[0].path)
        await harness.settle()
        #expect(await requests(harness).filter { $0 == "/api/v1/tickets/\(rows[0].item)" }.count == 1)
        harness.clock.advance(by: .seconds(15))
        #expect(await eventually { await requests(harness).filter { $0 == "/api/v1/tickets/\(rows[0].item)" }.count == 2 })
    }

    @Test func failuresBackOffAndASuccessRestoresThePace() async throws {
        let dir = try TempDir()
        let (harness, _) = try await connectedWithRows(dir, ["853"])
        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).count == 1 })
        for (wait, total) in [(120, 2), (240, 3), (300, 4)] {
            await harness.settle()
            harness.clock.advance(by: .seconds(wait - 1))
            await harness.settle()
            #expect(await requests(harness).count == total - 1)
            harness.clock.advance(by: .seconds(1))
            #expect(await eventually { await requests(harness).count == total })
        }
        await harness.transport.failEverything(nil)
        await harness.settle()
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { await requests(harness).count == 5 })
        await harness.settle()
        harness.clock.advance(by: .seconds(60))
        #expect(await eventually { await requests(harness).count == 6 })
    }

    @Test func aMalformedIdShowsItsRowMissingAndTheOthersStillRefresh() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        let stray = try await harness.addRowByHand(item: "from-another-deployment", title: "0700-stray")
        await harness.transport.markMalformed("from-another-deployment")
        await harness.transport.clearRequests()
        harness.setViewing(visible: true, frontmost: false)

        #expect(await eventually { await harness.section()?.rows.first { $0.path == stray.path }?.isMissing == true })
        let section = await harness.section()
        #expect(section?.rows.filter(\.isMissing).map(\.path) == [stray.path])
        #expect(section?.rows.first { $0.path == rows[0].path }?.look.accessories.first?.kind == .dot)

        await harness.transport.clearRequests()
        await harness.settle()
        harness.clock.advance(by: .seconds(60))
        #expect(await eventually { await requests(harness).count == 1 })
        #expect(await requests(harness) == ["/api/v1/tickets?ids=\(rows[0].item),\(rows[1].item)"])
    }

    @Test func aTicketThatChangedOnTicketManagerIsFetchedForItsFiles() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853"])
        await harness.transport.bumpActivity(of: rows[0].item, to: 1_790_050_000_000)
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).contains("/api/v1/tickets/\(rows[0].item)") })
    }

    @Test func aRelaunchShowsCachedTicketsBeforeAnyFetch() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853"])
        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        let again = try await harness.restart()
        #expect(await eventually { await again.store.ticket(rows[0].item).detail?.ticket.number == "0853" })
        #expect(await again.section()?.rows.first?.look.label == "#0853")
    }
}
```

`harness.settle()` waits until the loop sleeps on the clock (`clock.sleepers` reaches the loop's one sleeper) and no request is in flight, so advancing time afterwards is deterministic.
`harness.addRowByHand(item:title:)` adds a `PluginRowEntry` straight to the workspace and makes its folder, as a `state.json` from another deployment would hold it.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketsRefreshTests`
Expected: FAIL.

- [ ] **Step 3: Write the watcher and the loop**

The loop sleeps in a child task it keeps as `sleeper`, and `wake()` cancels it; both run on the actor, so a wake that lands while jobs run is seen when the loop next reads the watch.

- [ ] **Step 4: Run every CanopyTickets test to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter CanopyTicketsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyTickets Tests/CanopyTicketsTests
git commit -m "feat: ticket rows refresh while the window can be seen, and back off after failures"
```

## Task 13: `canopy ticket`, `row new --ticket`, and the agent guide

**Files:**
- Create: `Sources/CanopyCLI/TicketCommand.swift`, `Sources/CanopyCLI/SecretPrompt.swift`
- Modify: `Sources/CanopyCLI/CanopyCLI.swift`, `RowCommand.swift`, `AgentGuide.swift`, `Client.swift`
- Test: `Tests/CanopyTicketsTests/TicketTextTests.swift` gains the guide's gate; the CLI itself is covered end to end in Task 16.

**Interfaces:**
- `Client.call(_:_:launchIfNeeded:wait:)` takes `enum ReplyWait { case usual, upTo(TimeInterval), forever }`; `term wait` moves to `.upTo`.
- `canopy ticket connect <url> [--web <template>]`: the token comes from `SecretPrompt.read(prompt: "Token for <url>: ")`, which uses `readpassphrase` with `RPP_REQUIRE_TTY` when stdin is a terminal and all of stdin, trimmed, otherwise; an empty token fails before anything is sent. Prints "Connected to <url> as <email>."
- `canopy ticket disconnect [--force]`: "Disconnected Tickets. Its rows stay for when you connect again."
- `canopy ticket list [--mine | --unowned] [--waiting] [--query <text>] [--closed]`: `TicketText.listLines`, or "No tickets."
- `canopy ticket new <ticket> [--run <cmd>] [--select]`: "Opened <title> in <path>.", "Running <cmd> in <pane>.", and on a fill error the error and exit 1, as `plugin new` does; it waits for the reply without a limit.
- `canopy ticket show [<ticket>] [--refresh] [--md]`: `TicketText.show`, or with `--md` the handover alone; a `stale` note goes to stderr as `note: <stale>`, and the command still exits 0.
- `canopy ticket select [<ticket>]`, `canopy ticket rm [<ticket>] [--force]`: "Selected <title>." and "Removed <title>. Its folder is in the Trash at <path>."
- Every ticket command sends `Client.hint()` as its target, and reading commands wait up to 90 seconds.
- `canopy row new ... --ticket <ticket>` sends `RowLinkParams(plugin: "tickets", reference: ticket)`; with `--no-link` it is a validation error.
- `canopy agent-guide` prints a Tickets section after Plugin rows when config.json turns the plugin on, read with `PluginConfig`; it never starts the app.

- [ ] **Step 1: Write the guide's gate test**

`TicketTextTests.theGuideShowsOnlyWhileTicketsIsOn`: `TicketsGuide.isOn(configFile:)` is false for no file, `{}`, and `{"plugins": {"tickets": {"enabled": false, "url": "u"}}}`, and true for `{"plugins": {"tickets": {"url": "u"}}}`, with `TicketsGuide` in CanopyTickets holding `text` and `isOn`.

- [ ] **Step 2: Run it to see it fail**

Run: `swift test $(scripts/test-flags.sh) --filter TicketTextTests`
Expected: FAIL.

- [ ] **Step 3: Write the commands and the guide**

The guide's section:

```
## Tickets

    canopy ticket list [--mine | --unowned] [--waiting] [--query <text>] [--closed]
    canopy ticket new <ticket> [--run <cmd>] [--select]
    canopy ticket show [<ticket>] [--refresh] [--md]
    canopy ticket select [<ticket>]
    canopy ticket rm [<ticket>] [--force]
    canopy row new <branch> --repo <repo> [--ticket <ticket>]

Tickets brings Discord support tickets in from ticket-manager. Each ticket you open is a row in the Tickets section,
with a folder under CANOPY_HOME/plugins/tickets/ and terminals like any row, which start in that folder.
ticket.md there is the ticket's handover block: the conversation, its problems, and what to investigate. Canopy
rewrites it when it fetches a newer copy, and `ticket show --md` prints the latest. ticket.json is the last response.

A <ticket> is 853, 0853, 0853-sameergoyal, ticket-0853-sameergoyal, closed-0853-sameergoyal, or a ticket-manager id.
A number looks at open tickets and rows first, then closed ones. In a ticket row, commands without a ticket use the
row's. `ticket new` fails with ticket_has_row, naming the row, when the ticket has one: `ticket select` it instead.

A fix belongs in a worktree row. `canopy row new` run in a ticket row's terminal links the new row to the ticket,
and so does `--ticket` anywhere. The ticket's panel lists linked rows as its fix rows.

Errors: plugin_off and token_rejected say to run `canopy ticket connect <url>`; tickets_unreachable means
ticket-manager did not answer, and `ticket show` then prints its cached copy with a note on stderr.

    canopy ticket list --mine --waiting
    canopy ticket new 853 --run 'claude "$(cat ticket.md)"'
    canopy row new fix/shadowban-check --repo solis-v1 --run 'claude "fix the shadowban check, see #0853"'
```

- [ ] **Step 4: Run the test, and build the CLI**

Run: `swift test $(scripts/test-flags.sh) --filter TicketTextTests && swift build --product canopy 2>&1 | grep -E "warning:|error:"`
Expected: PASS, and no build output lines.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/CanopyTicketsTests
git commit -m "feat: canopy ticket, row new --ticket, and a Tickets section in the agent guide"
```

## Task 14: Connecting and disconnecting in the window

**Files:**
- Create: `Sources/CanopyApp/Plugins/Tickets/ConnectTicketsSheet.swift`
- Modify: `Sources/CanopyApp/Plugins/BuiltInPlugins.swift`, `PluginSectionView.swift`, `LinkedRowsView.swift`, `Sidebar/SidebarView.swift`, `CanopyApp.swift`, `RootView.swift`, `AppModel.swift`

**Interfaces:**

```swift
/// A built-in plugin, the panel it draws beside a row's terminals, how the window turns it on, and what it adds to its
/// section's `…` menu.
@MainActor
struct BuiltInPlugin {
    let plugin: any CanopyPlugin
    let panel: (PluginRow) -> AnyView
    /// Offered in the sidebar's `+` menu and the File menu while the plugin is off, such as "Connect Tickets…".
    var setup: PluginSetup?
    var menuActions: [PluginMenuAction] = []
}

struct PluginSetup {
    let title: String
    let sheet: () -> AnyView
}

/// An item in a plugin section's `…` menu that asks first, such as Disconnect.
struct PluginMenuAction: Identifiable {
    let id: String
    let title: String
    let confirmTitle: String
    let confirmMessage: String
    let confirmButton: String
    let run: @MainActor (AppModel) async throws -> Void
}
```

- `AppModel` gains `setupSheet: PluginSetupRequest?`, `pendingPluginAction: PendingPluginAction?`, and `confirm(_:)`, which runs the action and toasts its error.
- `ConnectTicketsSheet`: the URL, a `SecureField` for the token, the optional ticket-manager page, a note on making a token with `npx convex run --prod api/apiTokens:create '{"email": "<email>", "label": "canopy"}'`, the error in red, the footer's `canopy ticket connect <url>`, and Cancel and Connect; Connect sends `tickets.connect` through `plugins.call`, the same method the CLI sends.
- Disconnect confirms with "Disconnect Tickets?" and "Canopy turns Tickets off and deletes its token from the Keychain. Your ticket rows stay for when you connect again.", adding the busy terminals when programs run, and sends `tickets.disconnect` with `force: true`.
- `LinkedRowsView` takes `title` and `emptyHint`, and the Tickets panel passes "Fix rows" and "`canopy row new` in this row's terminal, or with `--ticket <ticket>`, makes a fix row linked to this ticket."
- A dev build launched with `CANOPY_OPENED_URLS=<file>` appends each URL the window opens to that file instead of opening it, through the environment's `openURL`, so UI checks can check links without a browser.

- [ ] **Step 1: Build the views and wiring**

- [ ] **Step 2: Build with no warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:" ; test ${PIPESTATUS[0]} -eq 0`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/CanopyApp
git commit -m "feat: Connect Tickets and Disconnect in the window"
```

## Task 15: The ticket panel

**Files:**
- Create: `Sources/CanopyApp/Plugins/Tickets/TicketPanel.swift`, `TicketHeader.swift`, `TicketMessagesView.swift`, `DiscordTextView.swift`, `AttachmentViews.swift`, `RemoteImage.swift`, `TicketSectionsView.swift`
- Modify: `Sources/CanopyApp/Plugins/BuiltInPlugins.swift`

**Interfaces:**
- `TicketPanel(row: PluginRow, tickets: TicketsPlugin)` reads `tickets.store` only.
- From top to bottom, all within the base's panel column:
  - `TicketHeader`: the channel name, then the status tag, the customer, the owner's initials, and "waiting 7h" in orange; then Discord and ticket-manager buttons, the latter showing how to set `web` in a popover when there is none.
  - A banner under the header when the latest fetch failed, saying what went wrong and when the panel was last updated, or when ticket-manager no longer has the ticket, with Remove Row.
  - One scroll view: the message groups, then Problems, Draft with Copy, Notes when there are any, and Fix rows.
  - `TicketFooter`: "Updated 20 s ago" from a `TimelineView` every 5 seconds, and a refresh button that becomes a spinner while fetching.
- Message groups: a 28-point avatar (the author's image, or initials on a color from the username), the name in semibold with a "BOT" tag for bots and staff names in the accent color, the time, and the thread label; each message's blocks from `DiscordMarkdown`, drawn by `DiscordTextView` as `Text(AttributedString)` for paragraphs, a rounded monospaced box that wraps for code, and a bar at the leading edge for quotes; mentions tinted like Discord's.
- Attachments: images inline, fit to the width and at most 240 points tall, from `RemoteImage`; files as a paperclip, the name, and the size; an expired one, or an image that fails to load, as its name with "expired" that opens the message in Discord.
- `RemoteImage` loads with a shared ephemeral `URLSession`, caches decoded images and their sizes in an `NSCache`, and never loads while its view is off screen.
- Scrolling: `ScrollPosition` over a `scrollTargetLayout`, opening at the end of the conversation; `onScrollTargetVisibilityChange` tracks whether that end is in view; when new messages arrive, the panel follows them only while the end was in view, and otherwise keeps its place.
- Copy puts the draft's text on the pasteboard and shows "Copied" for 2 seconds.

- [ ] **Step 1: Build the panel**

- [ ] **Step 2: Build with no warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:" ; test ${PIPESTATUS[0]} -eq 0`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/CanopyApp
git commit -m "feat: the ticket panel beside a ticket row's terminals"
```

## Task 16: The stand-in ticket-manager, end-to-end cases, the UI fixture, and the spec

**Files:**
- Create: `scripts/ticket-manager-stand-in.py`
- Modify: `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md`, and `Resources/Info.plist.in` if needed

**Interfaces:**
- `scripts/ticket-manager-stand-in.py seed --fixtures <dir> --out <dir> [--ui]` writes a data folder: `me.json`, `tickets.json` with every summary, `details/<id>.json`, and with `--ui` more tickets for UI checks: a long conversation with every kind of markdown, mentions, custom emoji, a thread with and without a name, an image, an expired attachment, a file, code blocks, a bot, long problems, a long draft, two notes, and a closed ticket; `cdn/` holds the images, made from system pictures with `sips`.
- `scripts/ticket-manager-stand-in.py serve --data <dir> --token <token> [--not-staff-token <token>] [--port <n>] [--port-file <file>] [--log <file>] [--lifetime <seconds>]` serves `/api/v1/me`, `/api/v1/tickets?status=`, `/api/v1/tickets?ids=` (400 for more than 50, or an id that is not 32 lowercase letters and digits), and `/api/v1/tickets/<id>`, reading the data folder on every request; checks the bearer token (401 with `WWW-Authenticate: Bearer`, or 403 for the not-staff token); answers JSON 404 for other paths and methods; rewrites `https://cdn.discordapp.com/` to its own `/cdn/` so nothing reaches Discord; serves `/cdn/` from the data folder; logs each request line; and exits after its lifetime, 1800 seconds by default.
- `scripts/e2e.sh` gains a Tickets part, on the dev build launched with `CANOPY_TRASH_FOLDER`, against the stand-in:
  - `plugin list` lists tickets off, `ticket list` fails with `plugin_off` naming `canopy ticket connect`.
  - A wrong token piped to `ticket connect` fails with `token_rejected`, and no Keychain entry or config section exists afterwards.
  - The right token connects, writes `plugins.tickets.url`, makes the Keychain entry for this home alone, and the log has no token.
  - `plugin list` says "connected as hindie@example.com".
  - `ticket list` prints the spec's lines, and `--mine`, `--unowned`, `--waiting`, `--query`, and `--closed` narrow it.
  - `ticket new 853 --run ...` makes `plugins/tickets/0853-sameergoyal` with `ticket.md` and `ticket.json`, whose terminal sees `CANOPY_PLUGIN=tickets` and the ticket's id; a second `ticket new 0853` fails with `ticket_has_row`; `ticket new 999` with `ticket_not_found`.
  - `ticket show 853`, `--md`, and `--json`, and `ticket show --md` run in the row's folder.
  - `row new fix/shadowban --ticket 853` is linked, and `ticket show --json` lists it under `fixRows`.
  - config's `run` starts `ticket new 849`'s terminal.
  - With the stand-in stopped: `ticket list` fails with `tickets_unreachable`, `ticket show 853 --refresh` prints the cached copy and a note on stderr, and `plugin list` says it cannot reach it; the stand-in comes back on the same port.
  - With the stand-in answering a different token: `ticket list` fails with `token_rejected`, and `plugin list` shows the warning.
  - A ticket removed from the stand-in's data shows its row missing after `ticket show --refresh`.
  - `ticket select 853`, `ticket rm 853` moving the folder into the run's trash folder, and the fix row keeping its link.
  - `agent-guide` has the Tickets section, `ticket disconnect` turns it off, deletes the Keychain entry, and the guide drops the section.
  - The trap disconnects, and deletes the Keychain entry if the app is gone.
- The fixture part's `plugin list` check now expects tickets off beside the fixture.
- `scripts/ui-fixture.sh` seeds `--ui` data, starts the stand-in, launches with `CANOPY_OPENED_URLS=$work/opened-urls`, connects with `--web`, opens rows for 853, the long ticket, and the closed one, starts terminals in them, and makes a fix row with `--ticket`; `stop` disconnects first, which deletes the Keychain entry, then stops the app and the stand-in.

- [ ] **Step 1: Write the stand-in and try it by hand**

Run: `python3 scripts/ticket-manager-stand-in.py seed --fixtures Tests/CanopyTicketsTests/Fixtures/canopy-api --out "$tmp/tm" && python3 scripts/ticket-manager-stand-in.py serve --data "$tmp/tm" --token t --port-file "$tmp/port" --lifetime 60 &` then `curl -s -H 'Authorization: Bearer t' "http://127.0.0.1:$(cat $tmp/port)/api/v1/tickets?ids=0000000000000000000010004tickets,bad"`.
Expected: a JSON 400 `bad_request`, and the right shapes for the other routes.

- [ ] **Step 2: Add the e2e cases and run them**

Run: `make e2e`
Expected: `e2e passed`.
If App Transport Security refuses `http://127.0.0.1`, add `NSAppTransportSecurity` with `NSAllowsLocalNetworking` to `Resources/Info.plist.in`, which allows loopback and local names only.

- [ ] **Step 3: Amend the spec**

The spec records: the `web` template and `--web`; `http://` only on this Mac; `ticket disconnect --force`; the `bad_response`, `plugin_not_started`, `invalid_url`, `keychain_failed`, and `ticket_has_no_row` codes; `turnOnCommand` for `plugin_off`; malformed ids split out and shown missing; rows' tickets whose summary changed are fetched so `ticket.md` stays current; `ticket show`'s 30 seconds; channel mentions named only for the ticket and its threads; the panel opening at the end of the conversation; "Connect Tickets…" in the File menu too; redirects refused; and the picker's item title being the row title.

- [ ] **Step 4: Commit**

```bash
git add scripts docs Resources
git commit -m "test: Tickets end to end against a stand-in ticket-manager, and in the UI fixture"
```

## UI Checks

On a dev build from `scripts/ui-fixture.sh`, in dark and in light, with window shots only, clicking for real:

- Connect Tickets… from the `+` menu after `canopy ticket disconnect`: the sheet, a wrong token's error, and connecting.
- The picker: typing, Mine, Unowned, Anyone, Closed, picking a ticket, picking one marked "In row", and Escape.
- A ticket row with its panel and terminals: the header, grouped messages with avatars, markdown, mentions, custom emoji, an inline image, an expired attachment, a file, code blocks, a thread label, long messages wrapping, problems, the draft and Copy (checked with `pbpaste`), notes, and fix rows.
- The Discord and ticket-manager buttons, and an expired attachment, checked in `$work/opened-urls`.
- A linked fix row: its `#0853` chip, clicking it, and clicking the fix row in the panel.
- A closed ticket's row and panel.
- A new message added to the stand-in's data while scrolled to the end, and while scrolled up to the problems.
- The error banner after stopping the stand-in, and the footer's refresh.
- Disconnect from the section's `…` menu.

Each is checked with `canopy row list --json`, `canopy plugin list`, or `canopy ticket list` where it changes state.

## As Built

- Tasks ran in the order 1 to 14, then the stand-in and e2e cases from Task 16, then the panel (15), then the UI fixture and the spec, so the e2e run proved the plugin in a real dev build before the panel work.
- `tickets.list` landed with Task 10, whose tests read through it.
- Resolving references and finding a ticket's row live in `TicketsPlugin+Resolving.swift`.
- The plugin host refreshes its snapshot right after it adds or removes a plugin row, so `context.state` has the row once `createRow` or `removeRow` returns. `aPluginSeesItsRowsChangeAsSoonAsTheHostChangesThem` pins it.
- `Client.call` takes `wait: ReplyWait` (`.usual`, `.upTo`, `.forever`) in place of `waitingUpTo`.
- `me` is asked for with the rows' refresh, while the window can be seen, or when Mine needs it.
- The panel keeps following the conversation's end while images load above it, and stops only when the author scrolls away. UI checks found that, a doubled period after URLError's own, and a fix-row hint that broke `--ticket` across lines.
- App Transport Security allows the stand-in's `http://127.0.0.1` with no change to Info.plist.

## After Review

An independent reviewer (Opus) read `git diff origin/main...HEAD` with the spec, this plan, and the ledger's rulings, and ran the Tickets suites three times.
It found nothing critical. Each finding acted on, and what changed:

1. **A reconnect could bring back "rejected the token"**: a request still out on the old token recorded its 401 after connecting again with the same URL. Connecting now starts a new generation and restarts the refresh loop, so old requests record nothing. `aRequestInFlightOnTheOldTokenCannotBringTheWarningBack`.
2. **The image cache never evicted, kept failures, and had no size limit.** It is an `NSCache` capped at 128 MB, keyed by the address without Discord's signing query, failures are not kept, and a file over 20 MB is never decoded or kept.
3. **Refresh answers could land after a stop or restart**, filling the store again and marking rows missing on a plugin turned off, and a bisect under way could ask a new deployment about the old one's ids. `fetchSummaries`, `fetchBatch`, `fetchList`, and `refreshRows` check the generation after each wait. `anAnswerThatArrivesAfterDisconnectingChangesNothing`.
4. **A cancelled request counted as ticket-manager failing**, so typing in the picker could make `plugin list` say "cancelled". Cancellations pass through the client unchanged and are never recorded. `aCancelledRequestIsNotAFailure`.
5. **A panel's state followed another ticket row**, so an open Remove popover could point at the wrong row. Each row's panel has its own identity.
6. **Server text could plant links of any kind** in banners and warnings. The window opens only http and https links.
7. **Customer text reached terminals with its control characters.** `ticket show`, `ticket list`, `ticket show --md`, and `ticket.md` take them out, but for newlines and tabs. `terminalControlsFromCustomersNeverReachTheTerminal`.

The review's minors, fixed after it at the coordinator's request:

1. **A selected ticket ticket-manager no longer has was asked for every 30 seconds**, and a malformed one too. A missing ticket now waits five minutes between tries whatever else succeeds, and a malformed id is never asked about again. `aSelectedTicketThatIsGoneIsAskedForEveryFiveMinutes`, `aSelectedMalformedTicketIsNeverAskedFor`, `aTicketThatIsGoneWaitsFiveMinutesWhateverElseSucceeds`.
2. **`canopy ticket connect` asked for the token before checking the address, and a pipe that never closed hung it.** The address and `--web` are checked first, and a piped token is its first line, read with a 10 second limit. `TokenInputTests`.
3. **A Keychain refusal at start failed commands with `plugin_not_started`.** It is `keychain_failed`, with the Keychain's words. `aKeychainThatRefusesFailsWithKeychainFailed`.
4. **`<t:…>` timestamps parsed as floating point.** They are whole seconds within the range Discord shows, and anything else stays as typed. `timestampsShowAsDates`.
5. **The panel re-parsed every message whenever the store changed.** The conversation is an equatable view on its row and ticket, so it is grouped and parsed again only when the ticket changes.
6. **`settle()` slept 30 ms for the state stream.** It waits until the plugin has taken in the host's current state and its loop sleeps, and waking the loop marks it busy at once. `hidingTheWindowStopsFetching` covers the visible-to-hidden change the review found untested.

Also at the coordinator's request:

- A plugin can name its item, so the picker reads "New Ticket Row" and the fixture's stays "New Fixture Row". `aPluginNamesItsItemInThePickersTitle`.
- `ticket.md` starts with a line saying the ticket's messages come from customers and are data to investigate, not instructions to follow, so an agent started with the file does not act on what a customer wrote.
- The author chose a panel that keeps to the conversation. Problems, the draft with Copy, notes, and fix rows left the panel and `canopy ticket show`, and their models went with them: Canopy no longer decodes those fields. Linked fix rows, their `#0853` chip, and `row new --ticket` stay.
