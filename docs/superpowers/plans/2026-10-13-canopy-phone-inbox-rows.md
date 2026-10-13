# Canopy on the box, Milestone 1: The Phone's Inbox and Rows

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iPhone app's Inbox becomes a list of notifications (agents waiting for the author, and done agents not yet read, with Mark read and Mark all read), and Rows shows each repo's main row as a large card above its other rows, each with its last line; pins go.

**Architecture:** The sorting stays in `CanopyWire`, so `PhoneInbox.sections` returns only Needs you and Done, and `PhoneRowsResult.Section` tells its main row from the others.
`InboxModel` in `CanopyPhone` drops pins and gains `markRead` and `markAllRead`, which send `phone.seen` and hide the item at once, until the Mac's next inbox agrees.
The views in `Apps/CanopyiOS` follow the mockup, and the screen tour walks the new screens.
Nothing on the Mac changes: `phone.seen` and `phone.rows` already do what this needs.

**Tech Stack:** Swift 6.4, SwiftUI and Observation for iOS 18, Swift Testing, XCTest UI tests, Xcode 27.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, sections "Inbox" and "Rows" under "The phone", and "Delivery" item 1.
**Mockups:** https://claude.ai/artifact/RSfrJZmSpnffA7s42BZDwd, "Inbox: notifications" and "Rows, grouped by host".

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings, in the package and in the Xcode project.
- `CanopyWire` imports only Foundation; `CanopyPhone` keeps its current imports.
- The phone speaks protocol 1 exactly as the Mac serves it today; no new methods or fields.
- Inbox items show their dot, row name, time, and last line, and never their host.
- Needs you lists waiting agents, the longest waiting first; Done lists done agents not yet seen, newest first.
- Working, background, and idle agents never appear in the Inbox.
- The tab's badge counts every item in the Inbox.
- Rows: each repo's name, then its main row as a large card, then its other rows with dot, PR number, and last line; plugin rows after the repos.
- Light and dark follow the system, with the existing `Theme` colors.
- Markdown: one sentence per line, no em dashes.
  Conventional commits, no trailers.

## Review Focus

1. Mark read while the Mac is out of reach must leave the item in Done and say "Can't reach <Mac>.", never hide it for good.
   Pinned by `markingReadWhileTheMacIsAwayKeepsTheItem` in Task 2.
2. An agent the author marked read that finishes again later (a new `since`) must come back to Done.
   Pinned by `anAgentThatFinishesAgainComesBack` in Task 2.
3. A done item marked read must not flash back while the Mac's next inbox, still showing it unseen, is on its way.
   Pinned by `markReadHidesTheItemAtOnce` in Task 2.
4. A repo with no main row in `phone.rows`, as a plugin's section, must list every row under its header and show no empty card.
   Pinned by `aSectionWithoutAMainRowListsEveryRow` in Task 1.
5. Two agents waiting since the same second must keep one order across inbox updates, so items do not swap places as the Mac resends.
   Pinned by `tiesKeepTheMacsOrder` in Task 1.

## File Structure

| File | Change |
|---|---|
| `Sources/CanopyWire/PhoneInbox.swift` | `Sections` becomes `needsYou` and `done`, with `count` and `isEmpty`; `sections` takes no pins; `runningCount`; `PhoneRowsResult.Section.main` and `others`; `waitingCount`, `agentCount`, `defaultPins` go |
| `Tests/CanopyWireTests/PhoneWireTests.swift` | the inbox and rows tests |
| `Sources/CanopyPhone/InboxModel.swift` | no pins, `markRead`, `markAllRead`, `badgeCount`, `runningCount` |
| `Sources/CanopyPhone/PinStore.swift` | deleted |
| `Sources/CanopyPhone/PhoneApp.swift` | no `pins`, no `inbox.start()` |
| `Tests/CanopyPhoneTests/InboxModelTests.swift` | pins tests go, mark read tests come |
| `Apps/CanopyiOS/Canopy/InboxView.swift` | Needs you, Done with Mark all read and swipe to Mark read, All caught up, no pins |
| `Apps/CanopyiOS/Canopy/RowsView.swift` | the Mac's header, repo labels, main cards, rows with last lines |
| `Apps/CanopyiOS/Canopy/RootView.swift` | the badge, and a tab selection so All caught up can open Rows |
| `Apps/CanopyiOS/CanopyUITests/ScreenTour.swift` | the new screens, Mark read, and All caught up |

---

### Task 1: The inbox's sections and the rows' main card, in CanopyWire

**Files:**
- Modify: `Sources/CanopyWire/PhoneInbox.swift` (the `PhoneInbox` body from `public struct Sections` to the end of `defaultPins`, and `PhoneRowsResult.Section`)
- Test: `Tests/CanopyWireTests/PhoneWireTests.swift` (`PhoneInboxTests`, and a new `PhoneRowsResultTests`)

**Interfaces:**
- Produces: `PhoneInbox.Sections { needsYou: [Item]; done: [Item]; count: Int; isEmpty: Bool }`, `PhoneInbox.sections: Sections` (a property), `PhoneInbox.runningCount: Int`, `PhoneRowsResult.Section.main: PhoneRow?`, `PhoneRowsResult.Section.others: [PhoneRow]`.
- Removes: `sections(pinned:)`, `waitingCount`, `agentCount`, `defaultPins`.

- [ ] **Step 1: Write the failing tests**

In `PhoneInboxTests`, replace `sortsAgentsByWhatTheyNeedNewestFirst`, `pinnedRowsLeaveTheSectionsAndKeepTheirOrder`, `countsWaitingAgentsPinnedOrNot`, and `firstLaunchPinsMainRowsWithAnAgent` with:

```swift
    @Test func theInboxHoldsOnlyWaitingAndUnreadDone() {
        let sections = Self.inbox.sections
        #expect(sections.needsYou.map(\.agent.pane) == ["p9", "p2", "p3"])
        #expect(sections.done.map(\.agent.pane) == ["p4"])
        #expect(sections.count == 4)
        #expect(!sections.isEmpty)
    }

    @Test func doneIsNewestFirst() {
        let inbox = PhoneInbox(rows: [
            Self.row("old", [Self.agent("p1", .done, unseen: true, since: 10)]),
            Self.row("new", [Self.agent("p2", .done, unseen: true, since: 30)]),
            Self.row("mid", [Self.agent("p3", .done, unseen: true, since: 20)]),
        ])
        #expect(inbox.sections.done.map(\.agent.pane) == ["p2", "p3", "p1"])
    }

    @Test func tiesKeepTheMacsOrder() {
        let inbox = PhoneInbox(rows: [
            Self.row("b", [Self.agent("p2", .waiting, since: 50)]),
            Self.row("a", [Self.agent("p1", .waiting, since: 50)]),
        ])
        #expect(inbox.sections.needsYou.map(\.agent.pane) == ["p2", "p1"])
    }

    @Test func runningAgentsAreCountedNotListed() {
        #expect(Self.inbox.runningCount == 3)
        #expect(PhoneInbox().sections.isEmpty)
    }
```

Add after `PhoneInboxTests`:

```swift
struct PhoneRowsResultTests {
    static let main = PhoneRow(path: "/w/main", name: "main", repo: "canopy", isMain: true)
    static let feature = PhoneRow(path: "/w/feat", name: "feat/x", repo: "canopy")
    static let fix = PhoneRow(path: "/w/fix", name: "fix/y", repo: "canopy")

    @Test func aRepoShowsItsMainRowApart() {
        let section = PhoneRowsResult.Section(name: "canopy", isPlugin: false, rows: [Self.feature, Self.main, Self.fix])
        #expect(section.main == Self.main)
        #expect(section.others.map(\.name) == ["feat/x", "fix/y"])
    }

    @Test func aSectionWithoutAMainRowListsEveryRow() {
        let ticket = PhoneRow(path: "/t/1", name: "#0853", plugin: "ticket")
        let section = PhoneRowsResult.Section(name: "ticket", isPlugin: true, rows: [ticket])
        #expect(section.main == nil)
        #expect(section.others == [ticket])
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `make test 2>&1 | grep -E "error:|PhoneInboxTests|PhoneRowsResultTests" | head -20`
Expected: build errors, `value of type 'PhoneInbox' has no member 'runningCount'` and `'Section' has no member 'main'`.

- [ ] **Step 3: Implement**

In `PhoneInbox`, replace everything from `public struct Sections` through the end of `defaultPins` with:

```swift
    public struct Sections: Sendable, Equatable {
        /// Waiting agents, the longest waiting first.
        public var needsYou: [Item]
        /// Done agents not yet seen, the newest first.
        public var done: [Item]

        public init(needsYou: [Item] = [], done: [Item] = []) {
            self.needsYou = needsYou
            self.done = done
        }

        /// What the tab's badge counts.
        public var count: Int { needsYou.count + done.count }
        public var isEmpty: Bool { count == 0 }
    }

    /// The Inbox: what wants the author. Sorting is stable, so agents with the same time keep the Mac's order.
    public var sections: Sections {
        let items = rows.flatMap { row in row.agents.map { Item(row: row, agent: $0) } }
        let waiting = items.enumerated().filter { $0.element.agent.state == .waiting }
            .sorted { ($0.element.agent.since, $0.offset) < ($1.element.agent.since, $1.offset) }
        let done = items.enumerated().filter { $0.element.agent.state == .done && $0.element.agent.unseen }
            .sorted { ($1.element.agent.since, $0.offset) < ($0.element.agent.since, $1.offset) }
        return Sections(needsYou: waiting.map(\.element), done: done.map(\.element))
    }

    /// Working and background agents, which the Inbox leaves to Rows.
    public var runningCount: Int {
        rows.flatMap(\.agents).filter { $0.state == .working || $0.state == .background }.count
    }
```

In `PhoneRowsResult.Section`, after `public var id: String`, add:

```swift
        /// The repo's own checkout, which Rows shows as a card above the others.
        public var main: PhoneRow? { rows.first(where: \.isMain) }

        /// Every row but the main one, in the server's order.
        public var others: [PhoneRow] { rows.filter { !$0.isMain } }
```

Update the doc comment on `PhoneInbox.Item` users nowhere else; `PhoneClient.waitingCount` is unrelated (it counts waiting calls) and stays.

- [ ] **Step 4: Run the tests to see them pass**

Run: `make test 2>&1 | grep -E "error:|✘|Test run with" | head -20`
Expected: `CanopyWireTests` passes.
`CanopyPhone` and the app no longer build against `sections(pinned:)`, and Task 2 fixes `CanopyPhone`.
If `make test` stops on that, run the wire tests alone: `swift test $(scripts/test-flags.sh) --filter "PhoneInboxTests|PhoneRowsResultTests"`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyWire/PhoneInbox.swift Tests/CanopyWireTests/PhoneWireTests.swift
git commit -m "feat: the phone's inbox holds only waiting and unread done agents"
```

### Task 2: Mark read, and no pins, in CanopyPhone

**Files:**
- Modify: `Sources/CanopyPhone/InboxModel.swift`
- Modify: `Sources/CanopyPhone/PhoneApp.swift`
- Delete: `Sources/CanopyPhone/PinStore.swift`
- Test: `Tests/CanopyPhoneTests/InboxModelTests.swift`

**Interfaces:**
- Consumes: `PhoneInbox.sections`, `PhoneInbox.runningCount` from Task 1; `MacConnection.liveClient() throws -> PhoneClient`, `MacConnection.problem(_:)`, `PhoneMethod.seen`, `PhonePaneParams(pane:)`.
- Produces: `InboxModel(connection:)` with `sections: PhoneInbox.Sections`, `badgeCount: Int`, `runningCount: Int`, `hasInbox`, `isStale`, `asOf`, `label(for:)`, `answer(_:allow:) async`, `markRead(_ item: PhoneInbox.Item) async`, `markAllRead() async`, `answering`, `notice`, `dismissNotice()`; `PhoneApp` without `pins`.

- [ ] **Step 1: Write the failing tests**

In `InboxModelTests`, delete `sectionsFollowPinsAndPinnedAgentsStayWithTheirRow`, `theFirstInboxPinsMainCheckoutsOnce`, `noAgentInAMainCheckoutPinsNothingYet`, and `pinningAnyRowPutsItOnTop`.
Replace every `InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))` with `InboxModel(connection: connection)`.
Add:

```swift
    @Test func theInboxHoldsWhatNeedsTheAuthor() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        #expect(model.sections.needsYou.map(\.row.name) == ["feat/ios-companion", "#0853"])
        #expect(model.sections.done.map(\.row.name) == ["fix/port-scan-drain"])
        #expect(model.badgeCount == 3)
        #expect(model.runningCount == 2)
    }

    @Test func markReadHidesTheItemAtOnce() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        let item = try #require(model.sections.done.first)
        await model.markRead(item)
        #expect(model.sections.done.isEmpty)
        #expect(model.badgeCount == 2)
        let seen = try #require(await mac.request(PhoneMethod.seen))
        #expect(try seen.decodeParams(PhonePaneParams.self) == PhonePaneParams(pane: "p4"))
        // The Mac resends its inbox before it has caught up: the item stays hidden.
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [Rows.idle]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.sections.done.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func markAllReadSendsSeenForEachDoneItem() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        let other = PhoneRow(
            path: "/canopy-other", name: "feat/other", repo: "canopy",
            agents: [Rows.agent("p6", .done, since: 1_200, unseen: true, line: "Merged.")])
        let connection = try await connected(to: mac, inbox: PhoneInbox(rows: Rows.inbox.rows + [other]))
        let model = InboxModel(connection: connection)
        #expect(model.sections.done.count == 2)
        await model.markAllRead()
        #expect(model.sections.done.isEmpty)
        let panes = try mac.requests.filter { $0.method == PhoneMethod.seen }
            .map { try $0.decodeParams(PhonePaneParams.self).pane }
        #expect(Set(panes) == ["p4", "p6"])
        #expect(model.sections.needsYou.count == 2)
    }

    @Test func markingReadWhileTheMacIsAwayKeepsTheItem() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        let item = try #require(model.sections.done.first)
        await model.markRead(item)
        #expect(model.sections.done == [item])
        #expect(model.notice?.title == "Can't reach Studio.")
        #expect(!mac.requests.contains { $0.method == PhoneMethod.seen })
    }

    @Test func anAgentThatFinishesAgainComesBack() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        await model.markRead(try #require(model.sections.done.first))
        #expect(model.sections.done.isEmpty)
        var drain = Rows.drain
        drain.agents = [Rows.agent("p4", .done, since: 2_000, unseen: true, line: "READY again")]
        mac.setInbox(PhoneInbox(rows: [Rows.main, Rows.companion, drain, Rows.labels, Rows.ticket]))
        #expect(await eventually { model.sections.done.map(\.agent.lastLine) == ["READY again"] })
    }
```

Keep `allowAndDenyAnswerThePromptByItsID`, `aPromptThatMovedOnSaysSo`, `anAnswerWhileTheMacIsOutOfReachSaysSo`, `theInboxIsStaleWhileTheMacIsOutOfReach`, and `labelsNamePluginsAndReposOnlyWhenThereAreSeveral` with the new initializer.
In `aPromptThatMovedOnSaysSo` and `allowAndDenyAnswerThePromptByItsID`, `model.sections.needsYou.first` is now `feat/ios-companion` (`p3`, waiting since 1,700, before the ticket's 1,800) which has no prompt; take the ticket's item instead: `try #require(model.sections.needsYou.first { $0.agent.prompt != nil })`, and expect `pane: "p2"` as before.
`aPromptThatMovedOnSaysSo`'s `#expect(model.sections.needsYou.first == item)` becomes `#expect(model.sections.needsYou.contains(item))`.
If `FakeMac` has no `request(_:)` that waits for the first request of a method, use `#expect(await eventually { mac.requests.contains { $0.method == PhoneMethod.seen } })` and then read it from `mac.requests`; `ConversationModelTests` uses `mac.request(PhoneMethod.seen, number: 2)`, so the helper exists.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter InboxModelTests 2>&1 | tail -20`
Expected: build errors: `extra argument 'pins'` gone, `value of type 'InboxModel' has no member 'markRead'`.

- [ ] **Step 3: Implement**

`Sources/CanopyPhone/InboxModel.swift` becomes:

```swift
import CanopyWire
import Foundation
import Observation

/// The Inbox: agents waiting for the author, and done agents not yet read.
@MainActor @Observable
public final class InboxModel {
    public let connection: MacConnection
    /// Panes whose answer is on its way.
    public private(set) var answering: Set<String> = []
    /// What went wrong with the last answer or mark read, until dismissed.
    public private(set) var notice: PhoneProblem?
    /// Done agents marked read here, by pane and when they finished, hidden until the Mac's inbox catches up.
    private var read: [String: Double] = [:]

    public init(connection: MacConnection) {
        self.connection = connection
    }

    private var inbox: PhoneInbox { connection.inbox ?? PhoneInbox() }

    public var sections: PhoneInbox.Sections {
        var sections = inbox.sections
        sections.done.removeAll { read[$0.agent.pane] == $0.agent.since }
        return sections
    }

    public var badgeCount: Int { sections.count }
    public var runningCount: Int { inbox.runningCount }
    public var hasInbox: Bool { connection.inbox != nil }

    /// The inbox is the last one the Mac sent before it went out of reach.
    public var isStale: Bool { connection.isUnreachable && connection.inbox != nil }
    public var asOf: Date? { connection.inboxAsOf }

    /// The small label after a row's name: its plugin's item, or its repo when the inbox spans several.
    public func label(for row: PhoneRow) -> String? {
        if let plugin = row.plugin { return plugin }
        let repos = Set(inbox.rows.compactMap(\.repo))
        return repos.count > 1 ? row.repo : nil
    }

    /// Allow or Deny for a permission prompt, straight from the list.
    public func answer(_ item: PhoneInbox.Item, allow: Bool) async {
        guard let prompt = item.agent.prompt else { return }
        let pane = item.agent.pane
        answering.insert(pane)
        defer { answering.remove(pane) }
        do {
            _ = try await connection.liveClient().call(
                PhoneMethod.answer, PhoneAnswerParams(pane: pane, prompt: prompt.id, answer: PhoneAnswer(allow: allow)),
                as: PhonePaneParams.self)
            notice = nil
        } catch {
            notice = connection.problem(error)
        }
    }

    /// Marks a done agent read, here and on the Mac, as opening it does.
    public func markRead(_ item: PhoneInbox.Item) async {
        await markRead([item])
    }

    public func markAllRead() async {
        await markRead(sections.done)
    }

    /// Each item is read once the Mac takes it, so one that fails comes back alone.
    private func markRead(_ items: [PhoneInbox.Item]) async {
        for item in items { read[item.agent.pane] = item.agent.since }
        let client: PhoneClient
        do {
            client = try connection.liveClient()
        } catch {
            unread(items)
            notice = connection.problem(error)
            return
        }
        var problem: PhoneProblem?
        for item in items {
            do {
                _ = try await client.call(
                    PhoneMethod.seen, PhonePaneParams(pane: item.agent.pane), as: PhonePaneParams.self)
            } catch let error as ControlError where error.code == "pane_not_found" {
                // The pane closed, so its agent leaves the inbox anyway.
            } catch {
                unread([item])
                problem = connection.problem(error)
            }
        }
        notice = problem
    }

    private func unread(_ items: [PhoneInbox.Item]) {
        for item in items where read[item.agent.pane] == item.agent.since {
            read[item.agent.pane] = nil
        }
    }

    public func dismissNotice() {
        notice = nil
    }
}
```

Delete `Sources/CanopyPhone/PinStore.swift`.
In `PhoneApp`, remove `public let pins: PinStore`, `pins = PinStore(defaults: defaults)`, and `inbox.start()`, and build the inbox with `inbox = InboxModel(connection: connection)`.
`defaults` is still used by `AppLock`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter "InboxModelTests|PhoneAppTests|ConversationModelTests" 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/CanopyPhone Tests/CanopyPhoneTests
git commit -m "feat: mark done agents read from the phone's inbox, and pins go"
```

### Task 3: The Inbox and Rows screens

**Files:**
- Modify: `Apps/CanopyiOS/Canopy/InboxView.swift`
- Modify: `Apps/CanopyiOS/Canopy/RowsView.swift`
- Modify: `Apps/CanopyiOS/Canopy/RootView.swift`

**Interfaces:**
- Consumes: `InboxModel.sections`, `badgeCount`, `runningCount`, `markRead(_:)`, `markAllRead()` from Task 2; `PhoneRowsResult.Section.main`, `others` from Task 1.
- Produces: accessibility identifiers the tour uses: `item-<row name>` (unchanged), `mark-read-<row name>`, `mark-all-read`, `see-rows`, `caught-up`, `main-<repo>`, `row-<row name>` (unchanged), `host`.

- [ ] **Step 1: RootView's tab selection and badge**

```swift
struct RootView: View {
    @Environment(PhoneApp.self) private var app
    @State private var scene: UIWindowScene?
    @State private var lockWindow = LockWindow()
    @State private var tab = AppTab.inbox

    var body: some View {
        Group {
            if app.connection.paired == nil {
                PairingView()
            } else {
                TabView(selection: $tab) {
                    Tab("Inbox", systemImage: "tray", value: AppTab.inbox) {
                        InboxView()
                    }
                    .badge(app.inbox.badgeCount)
                    .accessibilityIdentifier("tab-inbox")
                    Tab("Rows", systemImage: "line.3.horizontal", value: AppTab.rows) {
                        RowsView()
                    }
                    .accessibilityIdentifier("tab-rows")
                }
                .environment(\.showRows, ShowRowsAction { tab = .rows })
            }
        }
        // the rest is unchanged
    }
}

enum AppTab: Hashable {
    case inbox, rows
}

/// Switches to the Rows tab, for the Inbox's All caught up.
struct ShowRowsAction {
    var show: @MainActor () -> Void

    @MainActor func callAsFunction() {
        show()
    }
}

extension EnvironmentValues {
    @Entry var showRows = ShowRowsAction {}
}
```

- [ ] **Step 2: The Inbox**

In `InboxView.body`, the `List` becomes:

```swift
            List {
                Section {
                } header: {
                    ConnectionLine()
                }
                InboxSection(title: "Needs you", items: model.sections.needsYou)
                DoneSection(items: model.sections.done)
            }
```

The empty overlay becomes:

```swift
                if model.hasInbox, model.sections.isEmpty {
                    CaughtUp(running: model.runningCount)
                } else if !model.hasInbox, app.connection.isUnreachable {
```

and keeps its second branch.
Add:

```swift
/// The empty Inbox: nothing waits, with how many agents still run and the way to them.
private struct CaughtUp: View {
    @Environment(\.showRows) private var showRows
    var running: Int

    var body: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle")
        } description: {
            Text(description)
        } actions: {
            Button("See rows") { showRows() }
                .buttonStyle(ChipStyle(kind: .tinted))
                .accessibilityIdentifier("see-rows")
        }
        .accessibilityIdentifier("caught-up")
    }

    private var description: String {
        let waiting = "Nothing is waiting for you."
        switch running {
        case 0: return waiting
        case 1: return waiting + "\n1 agent is running."
        default: return waiting + "\n\(running) agents are running."
        }
    }
}

/// Done agents, newest first, each read by opening it, swiping it, or Mark all read.
private struct DoneSection: View {
    @Environment(PhoneApp.self) private var app
    var items: [PhoneInbox.Item]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    InboxItemRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button("Mark read", systemImage: "checkmark") {
                                Task { await app.inbox.markRead(item) }
                            }
                            .tint(Theme.accent)
                            .accessibilityIdentifier("mark-read-\(item.row.name)")
                        }
                }
            } header: {
                HStack {
                    Text("Done")
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Mark all read") { Task { await app.inbox.markAllRead() } }
                        .textCase(nil)
                        .foregroundStyle(Theme.accent)
                        .disabled(app.inbox.isStale)
                        .accessibilityIdentifier("mark-all-read")
                }
                .font(.footnote)
            }
        }
    }
}
```

In `InboxItemRow`, remove the `.swipeActions(edge: .leading) { PinButton(row: item.row) }` modifier.
Delete `PinButton` and `PinnedRow`.
`RepoTile` stays, as Rows uses it.
`PhoneInbox.Sections.isEmpty` now comes from `CanopyWire`, so delete the `extension PhoneInbox.Sections` at the bottom of the file.
In `ConnectionLine.text`, the connected case becomes `return "\(app.connection.macName) connected"`, and `let agents = app.inbox.agentCount` goes.
`capitalizedFirst` stays, as `MainCard` uses it.
The banner for a notice already shows `model.notice`, so a failed Mark read shows there.

- [ ] **Step 3: Rows**

`RowsView`'s `List` becomes:

```swift
            List {
                Section {
                } header: {
                    HostLabel()
                }
                ForEach(model.sections) { section in
                    if section.isPlugin {
                        Section {
                            ForEach(section.rows) { RowLine(row: $0) }
                        } header: {
                            GroupLabel(title: section.name)
                        }
                    } else {
                        Section {
                            if let main = section.main { MainCard(row: main) }
                        } header: {
                            RepoLabel(name: section.name)
                        }
                        if !section.others.isEmpty {
                            Section {
                                ForEach(section.others) { RowLine(row: $0) }
                            }
                        }
                    }
                }
            }
```

Replace `RepoHeader` and `RowLine` with:

```swift
/// The Mac's name and whether it is connected, above its repos.
private struct HostLabel: View {
    @Environment(PhoneApp.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
            Text(app.connection.macName)
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status).textCase(nil)
        }
        .font(.footnote)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host")
    }

    private var color: Color {
        switch app.connection.status {
        case .connected: Theme.green
        case .connecting: Theme.yellow
        case .unreachable: Color.secondary
        }
    }

    private var status: String {
        switch app.connection.status {
        case .connected: "connected"
        case .connecting: "connecting"
        case .unreachable:
            app.inbox.asOf.map { "as of \($0.formatted(date: .omitted, time: .shortened))" } ?? "out of reach"
        }
    }
}

private struct RepoLabel: View {
    var name: String

    var body: some View {
        HStack(spacing: 7) {
            RepoTile(name: name, dot: nil, size: 18)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .textCase(nil)
        .padding(.leading, -4)
    }
}

/// A repo's own checkout, larger than its other rows.
private struct MainCard: View {
    var row: PhoneRow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("main-\(row.repo ?? row.name)")
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentDotView(dot: row.dot)
        }
        .padding(.vertical, 4)
        .opens(row.lead?.pane)
    }

    private var line: String {
        guard let lead = row.lead else { return "No agent running" }
        return lead.lastLine ?? lead.state.phrase.capitalizedFirst
    }
}

private struct RowLine: View {
    var row: PhoneRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentDotView(dot: row.dot)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    RowName(row: row, label: nil, muted: row.lead == nil, weight: .medium)
                        .accessibilityIdentifier("row-\(row.name)")
                    Spacer(minLength: 8)
                    if let pr = row.pr {
                        PRChip(pr: pr)
                    }
                }
                if let line = row.lead?.lastLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opens(row.lead?.pane)
    }
}
```

The struct's doc comment becomes `/// Every row, by repo then plugin, with each repo's main row as a card above its others.`

- [ ] **Step 4: Build**

Run: `make ios 2>&1 | grep -E "warning:|error:|BUILD" | head -20`
Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Apps/CanopyiOS/Canopy
git commit -m "feat: the phone's Inbox shows notifications and Rows shows main cards"
```

### Task 4: The screen tour

**Files:**
- Modify: `Apps/CanopyiOS/CanopyUITests/ScreenTour.swift`

**Interfaces:**
- Consumes: the identifiers from Task 3, and `scripts/phone-fixture.sh`'s agents: `main` and `labels` working, `lost` in the background, `companion` waiting with a question, `ticket` waiting with a permission prompt, `drain` done, and `fix/hand-checks` with no agent.

- [ ] **Step 1: Walk the new screens**

Replace the wait for `pinned-main` after pairing with:

```swift
        XCTAssert(element("item-feat/ios-companion").waitForExistence(timeout: 10), "no waiting agent in the Inbox")
        XCTAssert(element("item-fix/port-scan-drain").exists, "the done agent is not in the Inbox")
        XCTAssertFalse(element("item-feat/port-labels").exists, "a working agent is in the Inbox")
        shot("inbox")
```

The Rows step becomes:

```swift
        app.tabBars.buttons["Rows"].tap()
        XCTAssert(element("main-canopy").waitForExistence(timeout: 10), "Rows has no main card")
        XCTAssert(element("row-fix/hand-checks").exists, "Rows has no idle row")
        XCTAssert(element("host").label.contains("connected"), "Rows does not say the Mac is connected")
        shot("rows")
        app.tabBars.buttons["Inbox"].tap()
```

After the Allow step's `shot("inbox-answered")`, add:

```swift
        // Read from the list: one by a swipe, then the rest at once, until nothing is left.
        let drain = element("item-fix/port-scan-drain")
        XCTAssert(drain.waitForExistence(timeout: 10), "the done agent left before it was read")
        drain.swipeLeft()
        app.buttons["mark-read-fix/port-scan-drain"].tap()
        XCTAssert(wait { !drain.exists }, "Mark read left the item")
        if app.buttons["mark-all-read"].exists { app.buttons["mark-all-read"].tap() }
        XCTAssert(element("caught-up").waitForExistence(timeout: 30), "the Inbox never emptied")
        shot("inbox-caught-up")
        app.buttons["see-rows"].tap()
        XCTAssert(element("main-canopy").waitForExistence(timeout: 5), "See rows did not open Rows")
        app.tabBars.buttons["Inbox"].tap()
```

After the relaunch's Unlock, replace the wait for `pinned-main` with `XCTAssert(app.staticTexts["connection"].waitForExistence(timeout: 15), "Unlock did not open the inbox")`.
Add the helper next to `text(_:)`:

```swift
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
```

The caught-up wait is 30 seconds because the companion agent goes on working after the reply, and the ticket's agent finishes its deploy and turns done before Mark all read can clear it; if the fixture's agents end in another state, read `scripts/fake-claude.py` and wait for the state they end in rather than lengthen the wait.

- [ ] **Step 2: Run the tour in light and dark**

Run: `make app && scripts/ios-shots.sh both`
Expected: the tour passes in both, `the Mac saw the tour's answer, reply, and Allow, each in its pane`, and `build/ios-shots/{light,dark}/` hold `02-inbox.png`, `03-rows.png`, and the new `inbox-caught-up` shot.
`phone.seen` is not a `phone.call` in the activity log, so the script's expected calls stay as they are; if the check fails on extra calls, the log does record it, and `seen` joins the expected list in `scripts/ios-shots.sh`.

- [ ] **Step 3: Check the shots**

Open each new shot next to the mockup: the Inbox has no Running section and no host on any item, Done's header has Mark all read on the right, All caught up names the running agents, Rows has the Mac's header, the canopy label, the main card, then rows with last lines, in light and dark.
Fix anything that does not match before committing.

- [ ] **Step 4: Commit**

```bash
git add Apps/CanopyiOS/CanopyUITests/ScreenTour.swift scripts/ios-shots.sh
git commit -m "test: the screen tour reads the inbox down to All caught up"
```

## Verification

- `make lint`, `make build` (0 warnings), `make test` three times with load below the core count.
- `make ios` (0 warnings) and `scripts/ios-shots.sh both` passing.
- `make e2e`.
- An independent opus review of `git diff origin/main...feat/box-server`, findings fixed, listed under "After Review" below.
- CI `check` green, then squash-merge.
- `make ios-install` puts it on the author's iPhone once merged; the author's pins are gone, which is expected.

## After Review

An independent opus review of `git diff origin/main...feat/box-server` found no critical problems and three important ones, all fixed:

1. All caught up said "Nothing is waiting for you" and counted running agents while the Mac was out of reach, which the phone cannot know.
   It now says "Nothing was waiting as of <time>." and dims with the stale list.
   Tests: `caughtUpCountsRunningAgentsWhileConnected`, `caughtUpOutOfReachSaysWhenItWasTrue`.
2. Mark all read rolled back every item when one `phone.seen` failed, including those the Mac had taken, and sent nothing after the failure.
   Each item is now read once the Mac takes it, a failure brings back only its own item, and `pane_not_found` counts as read, since that agent leaves anyway.
   Tests: `markAllReadKeepsWhatTheMacTookWhenAnotherFails`, `aPaneThatClosedCountsAsRead`.
3. The tour tapped Mark all read only if it happened to exist.
   It now waits for it, since the ticket's done agent is certain to be in Done by then, and taps it.

Also fixed from its minor list, as they showed on screen: swipe Mark read is disabled while the Mac is out of reach, as Mark all read is, so a swipe cannot add a second "Can't reach" banner; the repo label in Rows renders in the primary color; a tour message said the opposite of its failure.
Deferred: pruning the phone's read map, removing the old pin keys from UserDefaults, and an unreachable shot with items still listed.
