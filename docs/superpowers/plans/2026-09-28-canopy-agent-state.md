# Canopy Agent State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an agent in a Canopy terminal finishes, Canopy plays a sound and colors the row: green when it is done and unseen, yellow when it waits for the author, and a pulsing dot while it works.

**Architecture:** A pure `PaneAgent` value in `CanopyCore` holds each pane's agent state and every rule that changes it: reports, keys, exits, and the author seeing it.
`Pane` feeds it reports, typed keys, and exits, and `TerminalStore` decides what the author sees, when a sound is due, and what `canopy term wait` waits for.
Claude Code's hooks run `canopy agent-hook`, which maps the hook's JSON to a report and posts it as `term.state`, and `canopy hooks` edits Claude Code's settings file through an order-keeping JSON reader and writer.
The app draws the dots in the sidebar, the tab bar, pane headers, and collapsed group headers, plays the sounds, and offers the install once.

**Tech Stack:** Swift 6.2 with strict concurrency, SwiftUI and AppKit, Core Animation for the pulse, Swift Testing, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-agent-state-design.md`, approved by the author on 2026-09-28 with all 15 of its decisions.

## Global Constraints

- Tests, `make e2e`, and UI checks never read or write the real `~/.claude/settings.json`: every agent on the machine runs with it.
- Nothing in a test or script reports to the release app: `CANOPY_HOME` points at a temporary folder, and `CANOPY_PANE` and `CANOPY_CLI` are cleared.
- `canopy agent-hook` always exits 0 and prints nothing, and never launches the app.
- The hook command is exactly `[ -z "$CANOPY_CLI" ] || "$CANOPY_CLI" agent-hook >/dev/null 2>&1 || true`.
- `term.state` and `term.wait` stay out of `cli.call`.
- Default sounds are Glass for done and Ping for waiting.
- `--timeout` defaults to `30m` and `--for` to `any`.
- Swift 6 language mode, no warnings, `swift format lint --strict` clean.
- Markdown: one sentence per line, no em dashes.

## Review Focus

These are the inputs most likely to bite someone using this, with the test that pins each.

1. **A hook that closes its connection before the app reads the request.**
   Under load the app's `NWConnection` fails with ENETDOWN and drops the request, so a fire-and-forget hook loses reports.
   The hook waits for the reply for at most a second.
   Pinned by `ClaudeHookTests.postingWaitsAtMostASecondForTheApp`, which lost the request in 3 of 4 runs alongside the control tests before the fix.
2. **An agent that runs `claude -p` inside its own pane.**
   The nested session's turns must not move the pane.
   Pinned by `PaneAgentTests.aPaneListensToTheFirstSessionUntilItEnds` and the e2e step's `nested` report.
3. **A background subagent calling tools while the main agent waits on a question.**
   Its `PostToolUse` must not clear the yellow.
   Pinned by `ClaudeHookTests.promptsAndToolCallsMeanWorking`.
4. **`term send ... --enter` followed at once by `term wait`.**
   The done from before the prompt must not end the wait.
   Pinned by `TerminalStoreAgentTests.aStateFromBeforeTheLastInputWaitsForTheNextOne`.
5. **A settings file that is symlinked, hand-edited, not JSON, or rewritten by Claude Code mid-install.**
   Pinned by `ClaudeSettingsTests.aLinkedSettingsFileIsWrittenThrough`, `aFileThatIsNotAJSONObjectIsLeftAlone`, and `aFileChangedWhileWritingIsReadAgain`.

## Changes from the spec

Found while building; the spec was corrected where it said otherwise.

1. **The hook waits for the app's reply, for at most one second.**
   The spec said it would not wait at all, but the app can lose a request from a client that closed first (Review Focus 1).
   The spec's line now says so.
2. **`term.state` carries `question`, `takesOver`, and `releases`** rather than the app reading hook event names.
   The mapping from hook events stays in one table, `ClaudeHookMapping`, and the app only follows the flags.
3. **Keys sent with `canopy term send` log `source: cli`.**
   The spec said key changes are `ui`, but a key an agent sent is the CLI's doing, like every other event it causes.
4. **The pulse runs on a Core Animation layer.**
   A SwiftUI `PhaseAnimator` pulse kept the dev app at about 9% CPU with four agents working, against 0.3% idle.
   The layer animation, which the window server runs, measured 0.3 to 0.5%.
5. **The CLI passes `CLAUDE_CONFIG_DIR` to an app it launches**, so the install offer finds the same Claude Code settings as the caller, and `make e2e` keeps the offer off the real file.
6. **The UI fixture puts agents in every state** with `canopy term state`, gives the app its own `CLAUDE_CONFIG_DIR`, and with `UI_FIXTURE_HOOKS_OFFER=1` shows the install offer.

## Decisions to Review

The spec's 15 decisions were approved as written. These are new.

1. **Sounds play through `NSSound`,** at the system's output volume rather than its alert volume.
2. **A settings file `canopy hooks install` created stays as `{}` after an uninstall,** rather than being deleted.
3. **`TerminalTab.isRunningProgram` and `TerminalStore.isRunningProgram(inRow:)` are gone,** since no row or tab shows a running dot any more.
4. **A row group can only be folded in the window.**
   Row groups (PR 18) added no CLI command for it, so the UI check folds one with a click, and a follow-up could add `canopy group collapse`.

---

## Task 1: Agent states and the rules that change them

The state machine lives in a value type with no processes or windows, so every rule in the spec's "States" section is a unit test.

**Files:**
- Create: `Sources/CanopyCore/Agents/PaneAgent.swift`
- Modify: `Sources/CanopyCore/Activity/ActivityEvent.swift`
- Test: `Tests/CanopyCoreTests/PaneAgentTests.swift`

**Interfaces:**
- Produces: `AgentState` (`none`, `working`, `waiting`, `done`, raw values as on the wire), `AgentReport(state:session:event:at:question:takesOver:releases:)`, `AgentChange(from:to:via:session:)` with `alerts`, `AgentDot` (`working` < `done` < `waiting`), and `PaneAgent` with `state`, `unseen`, `session`, `waitsOnQuestion`, `since`, `lastInput`, `dot`, `isFresh`, `apply(_:now:)`, `typed(_:at:)`, `ended(at:)`, and `seen()`.
- Produces: `ActivityType.agent(_ state: AgentState) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PaneAgentTests.swift`, in full:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct PaneAgentTests {
    let start = Date(timeIntervalSince1970: 1_000)

    func time(_ seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    func hook(
        _ state: AgentState?, session: String = "s1", event: String = "Stop", at seconds: Double,
        question: Bool = false, takesOver: Bool = false, releases: Bool = false
    ) -> AgentReport {
        AgentReport(
            state: state, session: session, event: event, at: time(seconds), question: question,
            takesOver: takesOver, releases: releases)
    }

    @Test func aTurnGoesFromWorkingToDoneAndTheAuthorSeesIt() {
        var agent = PaneAgent()
        #expect(agent.state == .none)
        #expect(agent.dot == nil)

        let started = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        #expect(started == AgentChange(from: .none, to: .working, via: "UserPromptSubmit", session: "s1"))
        #expect(agent.dot == .working)
        #expect(started?.alerts == false)

        let finished = agent.apply(hook(.done, at: 2), now: time(2))
        #expect(finished == AgentChange(from: .working, to: .done, via: "Stop", session: "s1"))
        #expect(finished?.alerts == true)
        #expect(agent.unseen)
        #expect(agent.dot == .done)

        let firstLook = agent.seen()
        let secondLook = agent.seen()
        #expect(firstLook)
        #expect(!secondLook)
        #expect(agent.state == .done)
        #expect(agent.dot == nil)
    }

    @Test func seeingAWaitingPaneChangesNothing() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.waiting, event: "PermissionRequest", at: 1), now: time(1))
        let saw = agent.seen()
        #expect(!saw)
        #expect(agent.dot == .waiting)
    }

    @Test func theSameStateAgainChangesNothingExceptARepeatDone() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.waiting, event: "PermissionRequest", at: 1), now: time(1))
        #expect(agent.apply(hook(.waiting, event: "Notification", at: 2), now: time(2)) == nil)

        _ = agent.apply(hook(.done, at: 3), now: time(3))
        _ = agent.seen()
        let again = agent.apply(AgentReport(state: .done), now: time(4))
        #expect(again == AgentChange(from: .done, to: .done, via: "term.state", session: nil))
        #expect(agent.unseen)
    }

    @Test func aReportFromAHookThatStartedBeforeTheLastChangeIsStale() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        _ = agent.apply(hook(.done, at: 5), now: time(5))
        // A tool call's hook that started before the turn ended arrives late.
        #expect(agent.apply(hook(.working, event: "PostToolUse", at: 4), now: time(6)) == nil)
        #expect(agent.state == .done)

        // A report without a start time takes the time it arrives.
        #expect(agent.apply(AgentReport(state: .working), now: time(7)) != nil)
    }

    @Test func aPaneListensToTheFirstSessionUntilItEnds() {
        var agent = PaneAgent()
        _ = agent.apply(hook(nil, event: "SessionStart", at: 1), now: time(1))
        #expect(agent.session == "s1")
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 2), now: time(2))

        // A `claude -p` run inside the pane reports its own turn.
        #expect(agent.apply(hook(nil, session: "nested", event: "SessionStart", at: 3), now: time(3)) == nil)
        #expect(agent.apply(hook(.done, session: "nested", at: 4), now: time(4)) == nil)
        #expect(
            agent.apply(
                hook(AgentState.none, session: "nested", event: "SessionEnd", at: 5, releases: true), now: time(5))
                == nil)
        #expect(agent.state == .working)
        #expect(agent.session == "s1")

        let ended = agent.apply(hook(AgentState.none, event: "SessionEnd", at: 6, releases: true), now: time(6))
        #expect(ended == AgentChange(from: .working, to: .none, via: "SessionEnd", session: "s1"))
        #expect(agent.session == nil)

        _ = agent.apply(hook(.working, session: "s2", event: "UserPromptSubmit", at: 7), now: time(7))
        #expect(agent.session == "s2")
        #expect(agent.state == .working)
    }

    @Test func aSessionEndReleasesThePaneEvenWithNoStateToClear() {
        var agent = PaneAgent()
        _ = agent.apply(hook(nil, event: "SessionStart", at: 1), now: time(1))
        #expect(agent.apply(hook(AgentState.none, event: "SessionEnd", at: 2, releases: true), now: time(2)) == nil)
        #expect(agent.session == nil)
    }

    @Test func switchingConversationsInsideClaudeMovesThePane() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        _ = agent.apply(hook(nil, session: "s2", event: "SessionStart", at: 2, takesOver: true), now: time(2))
        #expect(agent.session == "s2")
        #expect(agent.apply(hook(.done, session: "s1", at: 3), now: time(3)) == nil)
        #expect(agent.apply(hook(.done, session: "s2", at: 4), now: time(4)) != nil)
    }

    @Test func reportsWithoutASessionAlwaysCount() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        #expect(agent.apply(AgentReport(state: AgentState.none), now: time(2)) != nil)
        #expect(agent.session == "s1")
    }

    @Test func escapeOrControlCInterruptsAWorkingPane() {
        for key in [Data([0x1B]), Data([0x03]), Data("\u{1b}[27u".utf8), Data("\u{1b}[99;5u".utf8)] {
            var agent = PaneAgent()
            _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
            #expect(agent.typed(Data("a".utf8), at: time(2)) == nil)
            // An arrow key starts with Escape but is not one.
            #expect(agent.typed(Data("\u{1b}[A".utf8), at: time(2)) == nil)
            #expect(agent.typed(key, at: time(3)) == AgentChange(from: .working, to: .none, via: "key", session: nil))
        }
    }

    @Test func keysAnswerAPromptButNotAQuestion() {
        var prompt = PaneAgent()
        _ = prompt.apply(hook(.waiting, event: "PermissionRequest", at: 1), now: time(1))
        #expect(prompt.typed(Data("\u{1b}[B".utf8), at: time(2)) == nil)
        #expect(prompt.typed(Data("\r".utf8), at: time(3)) == AgentChange(from: .waiting, to: .working, via: "key"))

        var dismissed = PaneAgent()
        _ = dismissed.apply(hook(.waiting, event: "PreToolUse", at: 1), now: time(1))
        #expect(dismissed.typed(Data([0x1B]), at: time(2))?.to == AgentState.none)

        var question = PaneAgent()
        _ = question.apply(hook(.waiting, at: 1, question: true), now: time(1))
        #expect(question.typed(Data("yes\r".utf8), at: time(2)) == nil)
        #expect(question.typed(Data([0x1B]), at: time(3)) == nil)
        #expect(question.state == .waiting)
        #expect(question.apply(hook(.working, event: "UserPromptSubmit", at: 4), now: time(4)) != nil)
    }

    @Test func aKeyChangeMakesEarlierHooksStale() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        _ = agent.typed(Data([0x03]), at: time(3))
        #expect(agent.apply(hook(.working, event: "PostToolUse", at: 2), now: time(4)) == nil)
        #expect(agent.state == .none)
        // A turn that goes on after the key reports working again.
        #expect(agent.apply(hook(.working, event: "PostToolUse", at: 5), now: time(5)) != nil)
    }

    @Test func anExitClearsTheStateAndReleasesTheSession() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.done, at: 1), now: time(1))
        #expect(agent.ended(at: time(2)) == AgentChange(from: .done, to: .none, via: "exit", session: nil))
        #expect(agent.session == nil)
        #expect(!agent.unseen)
        #expect(agent.ended(at: time(3)) == nil)
    }

    @Test func aStateIsFreshUntilThePaneGetsInput() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.done, at: 1), now: time(2))
        #expect(agent.isFresh)
        _ = agent.typed(Data("next step\r".utf8), at: time(3))
        #expect(!agent.isFresh)
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 4), now: time(4))
        _ = agent.apply(hook(.done, at: 5), now: time(5))
        #expect(agent.isFresh)
    }

    @Test func theMostUrgentDotWins() {
        #expect([AgentDot.working, .done, .waiting].max() == .waiting)
        #expect([AgentDot.working, .done].max() == .done)
    }

    @Test func eachStateHasAnActivityType() {
        #expect(ActivityType.agent(.working) == "agent.working")
        #expect(ActivityType.agent(.waiting) == "agent.waiting")
        #expect(ActivityType.agent(.done) == "agent.done")
        #expect(ActivityType.agent(.none) == "agent.cleared")
    }
}
```

A `.none` passed where an `AgentState?` is expected means nil, not the state, so the tests spell it `AgentState.none`; the compiler warns about the bare form.

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PaneAgentTests`
Expected: compile errors, `cannot find type 'AgentReport' in scope`.

- [ ] **Step 3: Write `PaneAgent`**

`Sources/CanopyCore/Agents/PaneAgent.swift`, in full:

```swift
import Foundation

/// What an agent in a pane is doing, as Claude Code's hooks or `canopy term state` report it.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    case none
    case working
    case waiting
    case done
}

/// One report of an agent's state.
public struct AgentReport: Sendable, Equatable {
    /// Nil for a report that only takes the pane for its session, as `SessionStart` does.
    public var state: AgentState?
    /// The Claude Code session that sent it. Reports without one always count.
    public var session: String?
    /// The hook event's name, such as `Stop`. Nil for `canopy term state`.
    public var event: String?
    /// When the hook process started. Nil takes the time the report arrives.
    public var at: Date?
    /// A turn ended on a question, so the agent waits at its own input line, where typing only drafts the answer.
    public var question: Bool
    /// The session replaces the one holding the pane, as when one `claude` resumes, clears, compacts, or forks.
    public var takesOver: Bool
    /// The session ends and lets go of the pane.
    public var releases: Bool

    public init(
        state: AgentState?, session: String? = nil, event: String? = nil, at: Date? = nil, question: Bool = false,
        takesOver: Bool = false, releases: Bool = false
    ) {
        self.state = state
        self.session = session
        self.event = event
        self.at = at
        self.question = question
        self.takesOver = takesOver
        self.releases = releases
    }
}

public struct AgentChange: Sendable, Equatable {
    public var from: AgentState
    public var to: AgentState
    /// What caused it: a hook event's name, `term.state`, `key`, or `exit`.
    public var via: String
    /// The session whose report caused it.
    public var session: String?

    public init(from: AgentState, to: AgentState, via: String, session: String? = nil) {
        self.from = from
        self.to = to
        self.via = via
        self.session = session
    }

    /// A finish or a need for the author, which plays a sound.
    public var alerts: Bool {
        to == .done || to == .waiting
    }
}

/// What stands for a pane's agent in the sidebar, the tab bar, and the pane header. Ordered by urgency, so the most
/// urgent of several is their `max()`.
public enum AgentDot: Int, Comparable, Sendable {
    case working
    case done
    case waiting

    public static func < (lhs: AgentDot, rhs: AgentDot) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A pane's agent state and the rules that change it. It knows nothing of processes or windows, so each rule can be
/// tested on its own.
public struct PaneAgent: Sendable, Equatable {
    public private(set) var state = AgentState.none
    /// Done and not yet seen by the author, which shows green.
    public private(set) var unseen = false
    /// The Claude Code session the pane listens to.
    public private(set) var session: String?
    /// Waiting at the agent's own input line after a question, rather than on a prompt that keys answer.
    public private(set) var waitsOnQuestion = false
    /// When Canopy saw the pane reach its state.
    public private(set) var since = Date.distantPast
    /// When something was last typed or sent into the pane.
    public private(set) var lastInput = Date.distantPast
    /// When the last change happened, by the clock of whatever caused it. Hooks that started earlier are stale.
    private var changedAt = Date.distantPast

    public init() {}

    public var dot: AgentDot? {
        switch state {
        case .none: nil
        case .working: .working
        case .waiting: .waiting
        case .done: unseen ? .done : nil
        }
    }

    /// Whether the pane reached its state after its last input. A done from before a new prompt is stale.
    public var isFresh: Bool {
        lastInput <= since
    }

    /// Applies a report, returning the change, or nil when it was ignored or changed nothing.
    /// A done on a done pane is a new finish, for agents that report only their finishes.
    public mutating func apply(_ report: AgentReport, now: Date) -> AgentChange? {
        let at = report.at ?? now
        guard at >= changedAt else { return nil }
        if let reporter = report.session {
            if session == nil || report.takesOver {
                session = reporter
            } else if session != reporter {
                return nil
            }
        }
        defer {
            if report.releases { session = nil }
        }
        guard let next = report.state, next != state || next == .done else { return nil }
        waitsOnQuestion = next == .waiting && report.question
        return change(to: next, via: report.event ?? "term.state", session: report.session, at: at, now: now)
    }

    /// Keys typed into the pane, or text sent with `canopy term send`. Claude Code runs no hook for an interrupt or a
    /// dismissed prompt, so Escape and Control-C clear the state, and Return answers a prompt.
    public mutating func typed(_ data: Data, at: Date) -> AgentChange? {
        lastInput = max(lastInput, at)
        let interrupts = Self.interruptKeys.contains(data)
        switch state {
        case .working where interrupts:
            return change(to: .none, via: "key", session: nil, at: at, now: at)
        case .waiting where !waitsOnQuestion && interrupts:
            return change(to: .none, via: "key", session: nil, at: at, now: at)
        case .waiting where !waitsOnQuestion && data.contains(0x0D):
            return change(to: .working, via: "key", session: nil, at: at, now: at)
        default:
            return nil
        }
    }

    /// The agent's program exited, or the pane closed. The session lets go of the pane.
    public mutating func ended(at: Date) -> AgentChange? {
        session = nil
        guard state != .none else { return nil }
        return change(to: .none, via: "exit", session: nil, at: at, now: at)
    }

    /// The author saw the pane. Returns whether a green dot went away.
    public mutating func seen() -> Bool {
        guard unseen else { return false }
        unseen = false
        return true
    }

    private mutating func change(to next: AgentState, via: String, session: String?, at: Date, now: Date)
        -> AgentChange
    {
        let change = AgentChange(from: state, to: next, via: via, session: session)
        state = next
        unseen = next == .done
        if next != .waiting { waitsOnQuestion = false }
        since = now
        changedAt = at
        return change
    }

    /// Escape and Control-C as a terminal sends them, plainly or in the kitty keyboard protocol's form.
    static let interruptKeys: Set<Data> = [
        Data([0x1B]), Data([0x03]), Data("\u{1b}[27u".utf8), Data("\u{1b}[99;5u".utf8),
    ]
}
```

`Sources/CanopyCore/Activity/ActivityEvent.swift`:

```diff
@@ -30,6 +30,11 @@ public enum ActivityType {
     public static let termExited = "term.exited"
     public static let termCommand = "term.command"
     public static let cliCall = "cli.call"
+
+    /// `agent.working`, `agent.waiting`, and `agent.done`, or `agent.cleared` when the state goes to none.
+    public static func agent(_ state: AgentState) -> String {
+        state == .none ? "agent.cleared" : "agent.\(state.rawValue)"
+    }
 }
 
 extension Calendar {
```

- [ ] **Step 4: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PaneAgentTests`
Expected: 15 tests pass.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: agent states and the rules that change a pane's"
```

## Task 2: Panes keep their agent's state

`Pane` owns a `PaneAgent`, applies reports to it, feeds it what is typed or sent, clears it when the program or the shell exits, and logs each change.

**Files:**
- Modify: `Sources/CanopyCore/Terminal/Pane.swift`
- Test: `Tests/CanopyCoreTests/PaneAgentStateTests.swift`

**Interfaces:**
- Consumes: `PaneAgent`, `AgentReport`, `AgentChange`, `ActivityType.agent` from Task 1.
- Produces: `Pane.agent` (observable), `Pane.report(_:now:) -> AgentChange?`, `Pane.markSeen() -> Bool`, `Pane.onAgentChange: ((Pane, AgentChange) -> Void)?`, and `Pane.onClose: ((Pane) -> Void)?`, called before a closing pane's state clears.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PaneAgentStateTests.swift`, in full:

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PaneAgentStateTests {
    @Test func reportsChangeThePaneAndAreLogged() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        var changes: [AgentChange] = []
        pane.onAgentChange = { _, change in changes.append(change) }
        ActivitySource.$current.withValue(.cli) {
            _ = pane.report(AgentReport(state: .working, session: "s1", event: "UserPromptSubmit"))
            _ = pane.report(AgentReport(state: .done, session: "s1", event: "Stop"))
        }

        #expect(pane.agent.state == .done)
        #expect(pane.agent.unseen)
        #expect(changes.map(\.to) == [.working, .done])
        let events = await logged(terminals, "agent")
        #expect(events.map(\.type) == ["agent.working", "agent.done"])
        #expect(
            events.map(\.data) == [
                ["pane": "p1", "from": .null, "via": "UserPromptSubmit", "session": "s1"],
                ["pane": "p1", "from": "working", "via": "Stop", "session": "s1"],
            ])
        #expect(events.allSatisfy { $0.source == .cli && $0.row == "feat/x" && $0.path == dir.path })
    }

    @Test func typingAndSendingReachTheKeyRules() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
        #expect(await eventually { pane.foreground?.name == "bash" })

        _ = pane.report(AgentReport(state: .working))
        pane.screen.type("\u{1b}")
        #expect(pane.agent.state == .none)

        _ = pane.report(AgentReport(state: .waiting, event: "PermissionRequest"))
        pane.type("\r")
        #expect(pane.agent.state == .working)

        let events = await logged(terminals, "agent")
        #expect(events.map(\.type) == ["agent.working", "agent.cleared", "agent.waiting", "agent.working"])
        #expect(events.map { $0.data["via"] } == ["term.state", "key", "PermissionRequest", "key"])
        #expect(events[1].data["session"] == nil)
    }

    @Test func theProgramExitingClearsTheState() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
        #expect(await eventually { pane.foreground?.name == "bash" })

        await pane.run("sleep 2")
        #expect(
            await eventually {
                pane.refreshActivity()
                return pane.isRunningProgram
            })
        _ = pane.report(AgentReport(state: .done, session: "s1", event: "Stop"))
        #expect(pane.agent.state == .done)

        #expect(
            await eventually {
                pane.refreshActivity()
                return pane.agent.state == .none
            })
        #expect(pane.agent.session == nil)
        #expect(await logged(terminals, "agent").last?.data["via"] == "exit")
    }

    @Test func aStateWithoutAProgramStaysUntilReported() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
        #expect(await eventually { pane.foreground?.name == "bash" })

        _ = pane.report(AgentReport(state: .waiting))
        pane.refreshActivity()
        #expect(pane.agent.state == .waiting)
    }

    @Test func theShellExitingOrThePaneClosingClearsTheState() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let exiting = terminals.openTab(for: Fixture.context(dir.path)).focused
        _ = exiting.report(AgentReport(state: .done))
        await exiting.run("exit 0")
        #expect(await eventually { exiting.agent.state == .none })

        let closing = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })
        _ = closing.report(AgentReport(state: .working))
        var order: [String] = []
        closing.onClose = { _ in order.append("closed") }
        closing.onAgentChange = { _, change in order.append(change.to.rawValue) }
        terminals.closePane(closing.id)
        #expect(order == ["closed", "none"])
        #expect(closing.agent.state == .none)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PaneAgentStateTests`
Expected: compile errors, `value of type 'Pane' has no member 'agent'`.

- [ ] **Step 3: Give `Pane` its agent**

The shell coming back to the foreground is the busy-to-idle edge `refreshActivity` already sees, so that is where a program's exit clears the state.

`Sources/CanopyCore/Terminal/Pane.swift`:

```diff
@@ -33,6 +33,13 @@ public final class Pane: Identifiable {
     /// Reads the shell's command reports, while commands are logged.
     @ObservationIgnored private var commandMarks: CommandMarkScanner?
 
+    /// What the agent in it is doing, as its hooks or `canopy term state` report it.
+    public private(set) var agent = PaneAgent()
+    /// Called after each change to `agent`.
+    @ObservationIgnored public var onAgentChange: ((Pane, AgentChange) -> Void)?
+    /// Called when the pane closes for good, before its agent state clears.
+    @ObservationIgnored public var onClose: ((Pane) -> Void)?
+
     /// The folder the shell starts in, when restored into one other than the row's.
     public let startDirectory: String?
 
@@ -75,13 +82,29 @@ public final class Pane: Identifiable {
     public private(set) var isRunningProgram = false
 
     /// Reads the foreground process again. The app calls it every second for every pane, shown or not.
+    /// The shell coming back to the foreground means the agent's program exited, so its state clears.
     public func refreshActivity() {
         let busy = isBusy
         if busy != isRunningProgram {
             isRunningProgram = busy
+            if !busy { agentChanged(agent.ended(at: Date())) }
         }
     }
 
+    /// Applies a report of the agent's state. Returns the change, or nil when it was ignored or changed nothing.
+    @discardableResult
+    public func report(_ report: AgentReport, now: Date = Date()) -> AgentChange? {
+        let change = agent.apply(report, now: now)
+        agentChanged(change)
+        return change
+    }
+
+    /// The author saw the pane. Returns whether a green dot went away.
+    @discardableResult
+    public func markSeen() -> Bool {
+        agent.seen()
+    }
+
     /// Types `command` and Return once the shell's line editor is ready, so the shell does not echo it twice.
     /// Shells without a line editor never report ready, so it types anyway after `timeout`.
     public func run(_ command: String, timeout: Duration = .seconds(10)) async {
@@ -99,16 +122,16 @@ public final class Pane: Identifiable {
     @ObservationIgnored var returnPatience = Duration.seconds(2)
 
     /// Sends text as if typed, for `canopy term send`. An exited pane ignores it.
-    /// With `enter`, Return follows as a keystroke of its own, in a later read than the text and `returnPause` after
-    /// it, and this returns once Return is in. Programs such as Claude Code and Codex take text and a Return that
-    /// arrive together for a paste, where Return adds a new line instead of submitting.
     public func type(_ text: String, enter: Bool = false) async {
         guard case .running = status, let process else { return }
+        agentChanged(agent.typed(Data(text.utf8), at: Date()))
         guard enter else {
             process.write(text)
             return
         }
         await process.write(Data(text.utf8), then: Data("\r".utf8), pause: Self.returnPause, patience: returnPatience)
+        // Return reaches the key rules as the key of its own that the program gets.
+        agentChanged(agent.typed(Data("\r".utf8), at: Date()))
     }
 
     /// Starts a new shell in the same folder after the last one exited.
@@ -124,6 +147,7 @@ public final class Pane: Identifiable {
     public func close() {
         guard !isClosed else { return }
         isClosed = true
+        onClose?(self)
         process?.terminate()
         if case .running = status {
             processExited(Self.closedExitCode)
@@ -204,6 +228,7 @@ public final class Pane: Identifiable {
         switch status {
         case .running:
             process?.write(data)
+            agentChanged(agent.typed(data, at: Date()))
         case .exited:
             if data == Data("\r".utf8) { restart() }
         }
@@ -220,6 +245,18 @@ public final class Pane: Identifiable {
             data: data.merging(["pane": .string(id.description)]) { value, _ in value })
     }
 
+    private func agentChanged(_ change: AgentChange?) {
+        guard let change else { return }
+        var data: [String: JSONValue] = [
+            "from": change.from == .none ? .null : .string(change.from.rawValue), "via": .string(change.via),
+        ]
+        if let session = change.session {
+            data["session"] = .string(session)
+        }
+        record(ActivityType.agent(change.to), data)
+        onAgentChange?(self, change)
+    }
+
     private func processExited(_ code: Int32) {
         // A closed pane already reported its exit. An exit status that was on its way when it closed changes nothing.
         if isClosed, case .exited = status { return }
@@ -227,6 +264,7 @@ public final class Pane: Identifiable {
         status = .exited(code)
         isRunningProgram = false
         record(ActivityType.termExited, ["code": .number(Double(code))])
+        agentChanged(agent.ended(at: Date()))
         // Nothing reads input now, so hide the cursor. The soft reset in `restart` shows it again.
         emulator.feed(Data("\u{1b}[?25l".utf8))
         let waiters = exitWaiters
```

- [ ] **Step 4: Run the tests, with the pane and activity suites**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "PaneAgentStateTests|PaneTests|TerminalActivityTests|CommandLoggingTests"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: panes keep their agent's state, from reports, keys, and exits"
```

## Task 3: What the author sees, sounds, dots, and waits

`TerminalStore` knows which row and tab are on screen, so it applies the seen rule, decides when a sound is due, sums panes into row and tab dots, and serves `term wait`.

**Files:**
- Create: `Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`

**Interfaces:**
- Consumes: `Pane.onAgentChange`, `Pane.onClose`, `Pane.markSeen()` from Task 2.
- Produces: `AgentViewing(rowPath:isFrontmost:)`, `TerminalStore.viewing`, `TerminalStore.onAgentAlert: (Pane, AgentState) -> Void`, `TerminalTab.agentDot`, `TerminalStore.agentDot(inRow:)`, `isOnScreen(_:)`, `isFocused(_:)`, `observeAgents(_:) -> UUID`, `stopObservingAgents(_:)`, `AgentWaitTarget` (`done`, `waiting`, `any`), and `waitForAgents(_ ids: [PaneID], for:timeout:) async throws -> (Pane, AgentState)`.
- Produces: `WorkspaceError.waitTimeout([String], String)` (`wait_timeout`), `.paneClosed(String)` (`pane_closed`), and `.agentStopped(String)` (`agent_stopped`).

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`, in full:

```swift
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct TerminalStoreAgentTests {
    /// Two rows: `a` with two tabs, the first split in two, and `b` with one pane.
    @MainActor
    struct Rows {
        let terminals: TerminalStore
        let a: String
        let b: String
        let focused: Pane
        let beside: Pane
        let otherTab: Pane
        let otherRow: Pane
        let firstTab: TerminalTab

        init(_ dir: TempDir) throws {
            a = dir.sub("a")
            b = dir.sub("b")
            for path in [a, b] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            terminals = Fixture.terminals(dir)
            firstTab = terminals.openTab(for: Fixture.context(a))
            beside = terminals.addPane(for: Fixture.context(a), fits: { _ in true })
            focused = firstTab.paneList[0]
            terminals.focus(focused.id)
            otherTab = terminals.openTab(for: Fixture.context(a), select: false).focused
            otherRow = terminals.openTab(for: Fixture.context(b)).focused
        }
    }

    @Test func aPaneOnScreenIsSeenAtOnce() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)

        for pane in [rows.focused, rows.beside, rows.otherTab, rows.otherRow] {
            pane.report(AgentReport(state: .done))
        }
        #expect(!rows.focused.agent.unseen)
        #expect(!rows.beside.agent.unseen)
        #expect(rows.otherTab.agent.unseen)
        #expect(rows.otherRow.agent.unseen)

        rows.terminals.selectTab(rows.terminals.tabs(inRow: rows.a)[1].id, inRow: rows.a)
        #expect(!rows.otherTab.agent.unseen)
        rows.terminals.viewing.rowPath = rows.b
        #expect(!rows.otherRow.agent.unseen)
    }

    @Test func nothingIsSeenWhileCanopyIsNotFrontmost() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: false)

        rows.focused.report(AgentReport(state: .done))
        #expect(rows.focused.agent.unseen)
        rows.terminals.viewing.isFrontmost = true
        #expect(!rows.focused.agent.unseen)
    }

    @Test func aSoundPlaysUnlessTheAuthorIsFocusedOnThePane() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        var alerts: [(PaneID, AgentState)] = []
        rows.terminals.onAgentAlert = { alerts.append(($0.id, $1)) }
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)

        rows.focused.report(AgentReport(state: .done))
        rows.focused.report(AgentReport(state: .waiting))
        rows.beside.report(AgentReport(state: .working))
        rows.beside.report(AgentReport(state: .done))
        rows.otherTab.report(AgentReport(state: .waiting))
        rows.terminals.viewing.isFrontmost = false
        rows.focused.report(AgentReport(state: .done))

        #expect(alerts.map(\.0) == [rows.beside.id, rows.otherTab.id, rows.focused.id])
        #expect(alerts.map(\.1) == [.done, .waiting, .done])
    }

    @Test func rowsAndTabsShowTheirMostUrgentDot() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }

        #expect(rows.terminals.agentDot(inRow: rows.a) == nil)
        rows.focused.report(AgentReport(state: .working))
        #expect(rows.firstTab.agentDot == .working)
        rows.beside.report(AgentReport(state: .done))
        #expect(rows.firstTab.agentDot == .done)
        rows.otherTab.report(AgentReport(state: .waiting))
        #expect(rows.firstTab.agentDot == .done)
        #expect(rows.terminals.agentDot(inRow: rows.a) == .waiting)
        #expect(rows.terminals.agentDot(inRow: rows.b) == nil)

        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)
        #expect(rows.firstTab.agentDot == .working)
    }

    @Test func aWaitReturnsAtOnceForAFreshState() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.beside.report(AgentReport(state: .waiting))
        rows.otherRow.report(AgentReport(state: .done))

        let any = try await rows.terminals.waitForAgents(
            [rows.focused.id, rows.otherRow.id, rows.beside.id], for: .any, timeout: .seconds(5))
        #expect(any.0.id == rows.otherRow.id && any.1 == .done)
        let waiting = try await rows.terminals.waitForAgents([rows.beside.id], for: .waiting, timeout: .seconds(5))
        #expect(waiting.1 == .waiting)
    }

    @Test func aStateFromBeforeTheLastInputWaitsForTheNextOne() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        let pane = rows.otherRow
        pane.report(AgentReport(state: .done))
        pane.type("next step\r")

        let waiting = Task { try await rows.terminals.waitForAgents([pane.id], for: .done, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        pane.report(AgentReport(state: .working))
        pane.report(AgentReport(state: .waiting))
        pane.report(AgentReport(state: .done))
        let result = try await waiting.value
        #expect(result.0.id == pane.id && result.1 == .done)
    }

    @Test func aWaitEndsOnTimeoutCloseOrStop() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }

        await #expect(throws: WorkspaceError.waitTimeout(["p1"], "done or waiting")) {
            try await rows.terminals.waitForAgents([rows.focused.id], for: .any, timeout: .milliseconds(50))
        }
        await #expect(throws: WorkspaceError.paneNotFound("p99")) {
            try await rows.terminals.waitForAgents([PaneID(99)], for: .any, timeout: .seconds(5))
        }

        rows.otherTab.report(AgentReport(state: .working))
        let closing = Task {
            try await rows.terminals.waitForAgents([rows.otherTab.id], for: .done, timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        rows.terminals.closePane(rows.otherTab.id)
        await #expect(throws: WorkspaceError.paneClosed(rows.otherTab.id.description)) { try await closing.value }

        rows.beside.report(AgentReport(state: .working))
        let stopping = Task {
            try await rows.terminals.waitForAgents([rows.beside.id], for: .done, timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        rows.beside.type("\u{3}")
        await #expect(throws: WorkspaceError.agentStopped(rows.beside.id.description)) { try await stopping.value }
    }

    @Test func aPaneWithNoAgentCanStartOneDuringAWait() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        let pane = rows.otherRow

        let waiting = Task { try await rows.terminals.waitForAgents([pane.id], for: .done, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        pane.report(AgentReport(state: .working))
        pane.report(AgentReport(state: .done))
        #expect(try await waiting.value.1 == .done)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter TerminalStoreAgentTests`
Expected: compile errors, `cannot infer contextual base in reference to member 'any'`.

- [ ] **Step 3: Add the store's side**

`Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`, in full:

```swift
import Foundation

/// What the author has in front of them, which decides the panes they have seen and the one they are focused on.
public struct AgentViewing: Sendable, Equatable {
    /// The selected row.
    public var rowPath: String?
    /// Canopy is the active app and its window is visible.
    public var isFrontmost: Bool

    public init(rowPath: String? = nil, isFrontmost: Bool = false) {
        self.rowPath = rowPath
        self.isFrontmost = isFrontmost
    }
}

/// Which states `canopy term wait` waits for.
public enum AgentWaitTarget: String, Codable, Sendable, CaseIterable {
    case done
    case waiting
    /// Done or waiting.
    case any

    public func matches(_ state: AgentState) -> Bool {
        switch self {
        case .done: state == .done
        case .waiting: state == .waiting
        case .any: state == .done || state == .waiting
        }
    }

    var label: String {
        self == .any ? "done or waiting" : rawValue
    }
}

public enum AgentEvent {
    case changed(Pane, AgentChange)
    /// Sent before the pane's agent state clears.
    case closed(Pane)
}

extension TerminalTab {
    /// The most urgent of its panes' dots.
    public var agentDot: AgentDot? {
        paneList.compactMap(\.agent.dot).max()
    }
}

extension TerminalStore {
    /// The most urgent dot among the row's panes, in every tab.
    public func agentDot(inRow path: String) -> AgentDot? {
        tabs(inRow: path).compactMap(\.agentDot).max()
    }

    /// Whether the author sees the pane: Canopy is frontmost, and the pane is in the selected row's selected tab.
    public func isOnScreen(_ pane: Pane) -> Bool {
        guard viewing.isFrontmost, let (path, tab) = tab(containing: pane.id), path == viewing.rowPath else {
            return false
        }
        return selectedTab(inRow: path)?.id == tab.id
    }

    /// Whether the pane on screen is the one the author is focused on.
    public func isFocused(_ pane: Pane) -> Bool {
        isOnScreen(pane) && tab(containing: pane.id)?.1.focusedPaneID == pane.id
    }

    /// Clears the green of every pane the author now sees.
    func markSeenOnScreen() {
        guard viewing.isFrontmost, let path = viewing.rowPath, let tab = selectedTab(inRow: path) else { return }
        for pane in tab.paneList {
            pane.markSeen()
        }
    }

    func agentChanged(_ pane: Pane, _ change: AgentChange) {
        if change.to == .done, isOnScreen(pane) {
            pane.markSeen()
        }
        if change.alerts, !isFocused(pane) {
            onAgentAlert(pane, change.to)
        }
        notifyAgentObservers(.changed(pane, change))
    }

    /// Waits until one of the panes reaches the state, and returns the first that does, in the order given.
    /// A pane already there counts at once, unless it got input since.
    public func waitForAgents(_ ids: [PaneID], for target: AgentWaitTarget, timeout: Duration) async throws -> (
        Pane, AgentState
    ) {
        let panes = try ids.map { id in
            guard let pane = pane(id) else { throw WorkspaceError.paneNotFound(id.description) }
            return pane
        }
        if let ready = panes.first(where: { target.matches($0.agent.state) && $0.agent.isFresh }) {
            return (ready, ready.agent.state)
        }
        let watched = Set(ids)
        let wait = AgentWait()
        let observer = observeAgents { event in
            switch event {
            case .changed(let pane, let change) where watched.contains(pane.id):
                if target.matches(change.to) {
                    wait.finish(.success((pane, change.to)))
                } else if change.to == .none {
                    wait.finish(.failure(WorkspaceError.agentStopped(pane.id.description)))
                }
            case .closed(let pane) where watched.contains(pane.id):
                wait.finish(.failure(WorkspaceError.paneClosed(pane.id.description)))
            default:
                break
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            wait.finish(.failure(WorkspaceError.waitTimeout(ids.map(\.description), target.label)))
        }
        defer {
            stopObservingAgents(observer)
            timer.cancel()
        }
        return try await withCheckedThrowingContinuation { wait.start($0) }
    }
}

/// One `waitForAgents` call, which the first of an event and its timeout finishes.
@MainActor
private final class AgentWait {
    private var continuation: CheckedContinuation<(Pane, AgentState), any Error>?
    private var result: Result<(Pane, AgentState), any Error>?

    func start(_ continuation: CheckedContinuation<(Pane, AgentState), any Error>) {
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<(Pane, AgentState), any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
```

Selecting, opening, or closing a tab can bring a pane on screen, so each marks what is now seen.

`Sources/CanopyCore/Terminal/TerminalStore.swift`:

```diff
@@ -61,6 +61,13 @@ public final class TerminalStore {
     /// Rows seen in a snapshot while they had terminals, so a row created a moment ago is not mistaken for one
     /// that went away.
     @ObservationIgnored private var seenRows: Set<String> = []
+    /// What the author has in front of them. The app keeps it current.
+    @ObservationIgnored public var viewing = AgentViewing() {
+        didSet { markSeenOnScreen() }
+    }
+    /// Called when a pane's agent finishes or needs the author, unless the author is focused on that pane.
+    @ObservationIgnored public var onAgentAlert: (Pane, AgentState) -> Void = { _, _ in }
+    @ObservationIgnored private var agentObservers: [UUID: (AgentEvent) -> Void] = [:]
 
     public init(engine: any TerminalEngine, settings: ShellSettings, activity: ActivityLog? = nil) {
         self.engine = engine
@@ -129,6 +136,7 @@ public final class TerminalStore {
         if select || selectedTabByRow[context.rowPath] == nil {
             selectedTabByRow[context.rowPath] = tab.id
         }
+        markSeenOnScreen()
         onChange()
         return tab
     }
@@ -144,6 +152,7 @@ public final class TerminalStore {
     public func selectTab(_ id: TabID, inRow path: String) {
         guard tabs(inRow: path).contains(where: { $0.id == id }) else { return }
         selectedTabByRow[path] = id
+        markSeenOnScreen()
         onChange()
     }
 
@@ -177,6 +186,7 @@ public final class TerminalStore {
         } else if wasSelected {
             selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
         }
+        markSeenOnScreen()
         onChange()
     }
 
@@ -400,8 +410,30 @@ public final class TerminalStore {
 
     private func makePane(_ context: PaneContext, command: PaneCommand, directory: String?) -> Pane {
         defer { nextPane += 1 }
-        return Pane(
+        let pane = Pane(
             id: PaneID(nextPane), context: context, command: command, settings: settings,
             emulator: engine.makeEmulator(size: preferredSize), activity: activity, directory: directory)
+        pane.onAgentChange = { [weak self] in self?.agentChanged($0, $1) }
+        pane.onClose = { [weak self] in self?.notifyAgentObservers(.closed($0)) }
+        return pane
+    }
+
+    // MARK: Agents
+
+    /// Calls `handler` with every agent change and pane close until `stopObservingAgents`.
+    public func observeAgents(_ handler: @escaping (AgentEvent) -> Void) -> UUID {
+        let id = UUID()
+        agentObservers[id] = handler
+        return id
+    }
+
+    public func stopObservingAgents(_ id: UUID) {
+        agentObservers[id] = nil
+    }
+
+    func notifyAgentObservers(_ event: AgentEvent) {
+        for observer in agentObservers.values {
+            observer(event)
+        }
     }
 }
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -29,6 +29,9 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case paneNotFound(String)
     case paneBusy(String, program: String)
     case paneExited(String)
+    case waitTimeout([String], String)
+    case paneClosed(String)
+    case agentStopped(String)
     case noPullRequestLookup(String)
     case notOnGitHub(String)
     case ghUnavailable(String)
@@ -76,6 +79,9 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .paneNotFound: "pane_not_found"
         case .paneBusy: "pane_busy"
         case .paneExited: "pane_exited"
+        case .waitTimeout: "wait_timeout"
+        case .paneClosed: "pane_closed"
+        case .agentStopped: "agent_stopped"
         case .noPullRequestLookup: "no_pr_lookup"
         case .notOnGitHub: "not_github"
         case .ghUnavailable: "gh_unavailable"
@@ -144,6 +150,11 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .paneNotFound(let id): "No terminal \(id). Run `canopy term list --all`."
         case .paneBusy(let id, let program): "\(program) is still running in \(id). Pass --force to close it anyway."
         case .paneExited(let id): "The shell in \(id) has exited. Close it, or restart it from the window."
+        case .waitTimeout(let ids, let target):
+            "\(ids.joined(separator: ", ")) did not become \(target) before the timeout."
+        case .paneClosed(let id): "\(id) closed during the wait."
+        case .agentStopped(let id):
+            "The agent in \(id) stopped without finishing: it exited, was interrupted, or was set to none."
         case .noPullRequestLookup(let name):
             "Canopy only looks up PRs for its own and adopted rows on a branch, and \(name) is not one."
         case .notOnGitHub(let repo): "\(repo)'s origin is not on GitHub, so its rows have no PRs."
```

- [ ] **Step 4: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "TerminalStoreAgentTests|TerminalStoreTests|PaneAgent"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: the seen rule, alerts, dots, and waits for agent states"
```

## Task 4: `term.state`, `term.wait`, and the agent in `term.list`

**Files:**
- Create: `Sources/CanopyCore/Rows/RowLifecycle+Agents.swift`
- Modify: `Sources/CanopyCore/Control/TermMethods.swift`, `Sources/CanopyCore/Control/ControlMethods.swift`, `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`
- Test: `Tests/CanopyCoreTests/AgentControlTests.swift`

**Interfaces:**
- Consumes: `Pane.report`, `TerminalStore.waitForAgents`, `AgentWaitTarget` from Tasks 2 and 3.
- Produces: `TermMethod.state` (`term.state`), `TermMethod.wait` (`term.wait`), `TermStateParams(pane:state:session:event:at:question:takesOver:releases:)` and `TermStateParams(pane:_ report:)`, `TermStateResult(pane:state:)`, `TermWaitParams(panes:target:timeout:)` with `for` as the JSON key and `defaultTimeout` of 1800 seconds, `TermWaitResult(pane:state:)`, `TermInfo.agent`, `ControlMethod.notLogged`, `RowLifecycle.reportAgent(_:)`, and `RowLifecycle.waitForAgents(_:)`.

- [ ] **Step 1: Write the failing tests**

They extend `ControlServerTests` to reuse its server.
Panes log through the terminal store's own `ActivityLog`, which `logged(workspace, ...)` does not flush, so the event check polls.

`Tests/CanopyCoreTests/AgentControlTests.swift`, in full:

```swift
import Foundation
import Testing

@testable import CanopyCore

extension ControlServerTests {
    func error(_ client: ControlClient, _ method: String, _ params: JSONValue) async throws -> String? {
        try await offPool { try client.send(ControlRequest(method: method, params: params)) }.error?.code
    }

    @Test func agentStatesAreReportedListedAndWaitedOn() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")
        let pane = try await call(client, TermMethod.new, TermNewParams(target: target), as: TermNewResult.self).pane

        let working = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .working), as: TermStateResult.self)
        #expect(working == TermStateResult(pane: pane, state: .working))
        let listed = try await call(client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
        #expect(listed.map(\.agent) == [.working])

        // The first session to report takes the pane, and another session's reports are ignored.
        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .working, session: "s1"),
            as: TermStateResult.self)
        let ignored = try await call(
            client, TermMethod.state,
            TermStateParams(
                pane: pane, state: .done, session: "nested", event: "Stop", at: Date().timeIntervalSince1970),
            as: TermStateResult.self)
        #expect(ignored.state == .working)

        let waiting = Task {
            try await call(
                client, TermMethod.wait, TermWaitParams(panes: [pane], target: .any, timeout: 20),
                as: TermWaitResult.self)
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .done, session: "s1", event: "Stop"),
            as: TermStateResult.self)
        #expect(try await waiting.value == TermWaitResult(pane: pane, state: .done))

        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: AgentState.none), as: TermStateResult.self)
        let cleared = try await call(client, TermMethod.list, TermListParams(target: target), as: [TermInfo].self)
        #expect(cleared.map(\.agent) == [nil])
        let encoded = try JSONValue.from(cleared[0])
        if case .object(let fields) = encoded { #expect(fields["agent"] == nil) }

        // Panes log through the terminal store's own log, which this helper does not flush.
        #expect(await eventually { await logged(workspace, "agent").count == 3 })
        let events = await logged(workspace, "agent")
        #expect(events.map(\.type) == ["agent.working", "agent.done", "agent.cleared"])
        #expect(events.allSatisfy { $0.source == .cli })
    }

    @Test func agentRequestsFailWithCodes() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let pane = try await call(
            client, TermMethod.new, TermNewParams(target: TargetHint(repo: "demo", row: "main")),
            as: TermNewResult.self
        ).pane

        let id = JSONValue.string(pane)
        #expect(
            try await error(client, TermMethod.state, .object(["pane": "p999", "state": "done"])) == "pane_not_found")
        #expect(try await error(client, TermMethod.state, .object(["pane": id, "state": "busy"])) == "bad_params")
        #expect(try await error(client, TermMethod.state, .object(["pane": id])) == "bad_params")
        #expect(try await error(client, TermMethod.wait, .object(["panes": .array([]), "timeout": 1])) == "bad_params")
        #expect(
            try await error(client, TermMethod.wait, .object(["panes": .array([id]), "timeout": -1])) == "bad_params")
        #expect(
            try await error(client, TermMethod.wait, .object(["panes": .array([id]), "for": "idle"])) == "bad_params")
        #expect(try await error(client, TermMethod.wait, .object(["panes": .array(["p999"])])) == "pane_not_found")
        #expect(
            try await error(client, TermMethod.wait, .object(["panes": .array([id]), "timeout": .number(0.1)]))
                == "wait_timeout")
    }

    @Test func agentRequestsStayOutOfCLICalls() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let pane = try await call(
            client, TermMethod.new, TermNewParams(target: TargetHint(repo: "demo", row: "main")),
            as: TermNewResult.self
        ).pane

        _ = try await call(
            client, TermMethod.state, TermStateParams(pane: pane, state: .done), as: TermStateResult.self)
        _ = try await call(
            client, TermMethod.wait, TermWaitParams(panes: [pane]), as: TermWaitResult.self)

        let calls = await logged(workspace, "cli").map { $0.data["method"] }
        #expect(calls == ["repo.add", "term.new"])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ControlServerTests`
Expected: compile errors, `cannot find 'TermStateResult' in scope`.

- [ ] **Step 3: Add the methods**

`Sources/CanopyCore/Control/TermMethods.swift`:

```diff
@@ -1,9 +1,13 @@
+import Foundation
+
 public enum TermMethod {
     public static let list = "term.list"
     public static let new = "term.new"
     public static let send = "term.send"
     public static let read = "term.read"
     public static let close = "term.close"
+    public static let state = "term.state"
+    public static let wait = "term.wait"
 }
 
 /// One terminal as `canopy term list` shows it.
@@ -18,6 +22,8 @@ public struct TermInfo: Codable, Sendable, Equatable {
     /// The program in the foreground, such as `claude`, or the shell when it is idle.
     public var foreground: String?
     public var exited: Int32?
+    /// The agent's state, left out when it is none.
+    public var agent: AgentState?
 }
 
 public struct TermListParams: Codable, Sendable {
@@ -119,3 +125,96 @@ public struct TermCloseParams: Codable, Sendable {
         force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
     }
 }
+
+/// A report of a pane's agent state, from `canopy term state` or Claude Code's hooks through `canopy agent-hook`.
+public struct TermStateParams: Codable, Sendable {
+    public var pane: String
+    /// Nil only from a hook that takes the pane for its session without changing the state.
+    public var state: AgentState?
+    public var session: String?
+    /// The hook event's name.
+    public var event: String?
+    /// When the hook process started, in seconds since 1970.
+    public var at: Double?
+    public var question: Bool
+    public var takesOver: Bool
+    public var releases: Bool
+
+    public init(
+        pane: String, state: AgentState?, session: String? = nil, event: String? = nil, at: Double? = nil,
+        question: Bool = false, takesOver: Bool = false, releases: Bool = false
+    ) {
+        self.pane = pane
+        self.state = state
+        self.session = session
+        self.event = event
+        self.at = at
+        self.question = question
+        self.takesOver = takesOver
+        self.releases = releases
+    }
+
+    public init(pane: String, _ report: AgentReport) {
+        self.init(
+            pane: pane, state: report.state, session: report.session, event: report.event,
+            at: report.at?.timeIntervalSince1970, question: report.question, takesOver: report.takesOver,
+            releases: report.releases)
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        pane = try container.decode(String.self, forKey: .pane)
+        state = try container.decodeIfPresent(AgentState.self, forKey: .state)
+        session = try container.decodeIfPresent(String.self, forKey: .session)
+        event = try container.decodeIfPresent(String.self, forKey: .event)
+        at = try container.decodeIfPresent(Double.self, forKey: .at)
+        question = try container.decodeIfPresent(Bool.self, forKey: .question) ?? false
+        takesOver = try container.decodeIfPresent(Bool.self, forKey: .takesOver) ?? false
+        releases = try container.decodeIfPresent(Bool.self, forKey: .releases) ?? false
+    }
+
+    public var report: AgentReport {
+        AgentReport(
+            state: state, session: session, event: event, at: at.map(Date.init(timeIntervalSince1970:)),
+            question: question, takesOver: takesOver, releases: releases)
+    }
+}
+
+public struct TermStateResult: Codable, Sendable, Equatable {
+    public var pane: String
+    /// The state after the report, which is the state the pane kept when the report was ignored.
+    public var state: AgentState
+}
+
+public struct TermWaitParams: Codable, Sendable {
+    public var panes: [String]
+    public var target: AgentWaitTarget
+    /// Seconds.
+    public var timeout: Double
+
+    public static let defaultTimeout = 30.0 * 60
+
+    enum CodingKeys: String, CodingKey {
+        case panes
+        case target = "for"
+        case timeout
+    }
+
+    public init(panes: [String], target: AgentWaitTarget = .any, timeout: Double = TermWaitParams.defaultTimeout) {
+        self.panes = panes
+        self.target = target
+        self.timeout = timeout
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        panes = try container.decode([String].self, forKey: .panes)
+        target = try container.decodeIfPresent(AgentWaitTarget.self, forKey: .target) ?? .any
+        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? Self.defaultTimeout
+    }
+}
+
+public struct TermWaitResult: Codable, Sendable, Equatable {
+    public var pane: String
+    public var state: AgentState
+}
```

`Sources/CanopyCore/Rows/RowLifecycle+Agents.swift`, in full:

```swift
import Foundation

/// What `canopy term state` and `canopy term wait` do, on the main actor where terminals live.
extension RowLifecycle {
    public func reportAgent(_ params: TermStateParams) throws -> TermStateResult {
        guard params.state != nil || params.session != nil else {
            throw ControlError(code: "bad_params", message: "Pass a state: working, waiting, done, or none.")
        }
        let pane = try terminal(params.pane)
        pane.report(params.report)
        return TermStateResult(pane: params.pane, state: pane.agent.state)
    }

    public func waitForAgents(_ params: TermWaitParams) async throws -> TermWaitResult {
        guard !params.panes.isEmpty else {
            throw ControlError(code: "bad_params", message: "Name at least one terminal to wait for.")
        }
        guard params.timeout.isFinite, params.timeout >= 0 else {
            throw ControlError(code: "bad_params", message: "The timeout must be zero or more seconds.")
        }
        let ids = try params.panes.map { text in
            guard let id = PaneID(text) else { throw WorkspaceError.paneNotFound(text) }
            return id
        }
        let (pane, state) = try await terminals.waitForAgents(
            ids, for: params.target, timeout: .milliseconds(Int64(params.timeout * 1000)))
        return TermWaitResult(pane: pane.id.description, state: state)
    }
}
```

`Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`:

```diff
@@ -15,7 +15,8 @@ extension RowLifecycle {
                         pane: pane.id.description, repo: repoNames[pane.context.repoPath] ?? pane.context.repoName,
                         row: pane.context.rowName, rowPath: path, tab: tab.name, title: pane.title,
                         folder: pane.currentDirectory ?? pane.startDirectory ?? path,
-                        foreground: pane.foreground?.name, exited: exited)
+                        foreground: pane.foreground?.name, exited: exited,
+                        agent: pane.agent.state == .none ? nil : pane.agent.state)
                 }
             }
         }
@@ -53,7 +54,7 @@ extension RowLifecycle {
         terminals.closePane(pane.id)
     }
 
-    private func terminal(_ id: String) throws -> Pane {
+    func terminal(_ id: String) throws -> Pane {
         guard let paneID = PaneID(id), let pane = terminals.pane(paneID) else { throw WorkspaceError.paneNotFound(id) }
         return pane
     }
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`:

```diff
@@ -48,7 +48,7 @@ public struct WorkspaceControlHandler: Sendable {
     /// into terminals are left out while command logging is off, and so is text starting with a space, which zsh keeps
     /// out of history under hist_ignore_space.
     private func record(_ request: ControlRequest, _ response: ControlResponse) {
-        guard !ControlMethod.readOnly.contains(request.method) else { return }
+        guard !ControlMethod.notLogged.contains(request.method) else { return }
         var params = request.params ?? .object([:])
         if case .object(var fields) = params {
             for key in ["run", "text"] {
@@ -249,6 +249,12 @@ public struct WorkspaceControlHandler: Sendable {
             try await rows.closeTerminal(params)
             return .object(["pane": .string(params.pane)])
 
+        case TermMethod.state:
+            return try .from(try await rows.reportAgent(request.decodeParams(TermStateParams.self)))
+
+        case TermMethod.wait:
+            return try .from(try await rows.waitForAgents(request.decodeParams(TermWaitParams.self)))
+
         default:
             throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
         }
```

`Sources/CanopyCore/Control/ControlMethods.swift`:

```diff
@@ -16,17 +16,23 @@ public enum ControlMethod {
 
     /// Methods that only read, which the activity log leaves out: agents poll some of them every few seconds.
     public static let readOnly: Set<String> = [
-        status, repoList, rowList, prShow, TermMethod.list, TermMethod.read, PortMethod.list, GroupMethod.list,
+        status, repoList, rowList, prShow, TermMethod.list, TermMethod.read, TermMethod.wait, PortMethod.list,
+        GroupMethod.list,
     ]
 
+    /// Methods left out of `cli.call`: the read-only ones, and `term.state`, which hooks send on every tool call and
+    /// which records its own `agent.*` events.
+    public static let notLogged = readOnly.union([TermMethod.state])
+
     /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo, so they
     /// can take minutes. Creating and removing rows also wait for setup or teardown, which can run for as long as
     /// a build does and cannot be cancelled, so the CLI waits for them without a limit, and so does a clone, which
     /// takes as long as the repo is big. A PR lookup can queue behind one already asking GitHub, and each may take
-    /// 30 seconds. Other reads answer from memory.
+    /// 30 seconds. `term.wait` has its own timeout, which the CLI waits out. Other reads answer from memory.
     public static func replyTimeout(for method: String) -> TimeInterval? {
         if [rowNew, rowRemove, repoClone].contains(method) { return nil }
         if method == prShow { return 90 }
+        if method == TermMethod.wait { return nil }
         return [repoAdd, repoRemove, rowAdopt].contains(method) ? 900 : 30
     }
 }
```

- [ ] **Step 4: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "ControlServerTests|ControlProtocolTests"`
Expected: all pass, including `agentStatesAreReportedListedAndWaitedOn`, `agentRequestsFailWithCodes`, and `agentRequestsStayOutOfCLICalls`.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: term.state and term.wait, and the agent field in term.list"
```

## Task 5: Claude Code's hooks as reports

`ClaudeHookMapping` is the spec's hook table in code.
`AgentHook.request` builds what `canopy agent-hook` sends, and `ControlClient.post` sends it.

**Files:**
- Create: `Sources/CanopyCore/Agents/ClaudeHookMapping.swift`
- Modify: `Sources/CanopyCore/Control/ControlClient.swift`, `Sources/CanopyCore/Ports/ProcessTable.swift`, and the spec's line on what the hook waits for
- Test: `Tests/CanopyCoreTests/ClaudeHookTests.swift`

**Interfaces:**
- Consumes: `AgentReport` from Task 1, `TermStateParams(pane:_:)` from Task 4.
- Produces: `ClaudeHookMapping.report(from:startedAt:) -> AgentReport?`, `ClaudeHookMapping.endsOnQuestion(_:)`, `AgentHookRequest(socketPath:request:)`, `AgentHook.request(input:environment:startedAt:) -> AgentHookRequest?`, `ProcessTable.startTime(of:) -> Date?`, and `ControlClient.post(_:timeout:)`.

- [ ] **Step 1: Write the failing tests**

The payloads follow the examples in the hooks reference at code.claude.com/docs/en/hooks.

`Tests/CanopyCoreTests/ClaudeHookTests.swift`, in full:

````swift
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct ClaudeHookTests {
    let started = Date(timeIntervalSince1970: 2_000)

    func report(_ json: String) -> AgentReport? {
        ClaudeHookMapping.report(from: Data(json.utf8), startedAt: started)
    }

    func expected(
        _ state: AgentState?, _ event: String, question: Bool = false, takesOver: Bool = false,
        releases: Bool = false
    ) -> AgentReport {
        AgentReport(
            state: state, session: "abc123", event: event, at: started, question: question, takesOver: takesOver,
            releases: releases)
    }

    @Test func sessionsTakeAndLetGoOfThePane() {
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "SessionStart", "source": "startup"}"#)
                == expected(nil, "SessionStart"))
        for source in ["resume", "clear", "compact", "fork"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "SessionStart", "source": "\#(source)"}"#)
                    == expected(nil, "SessionStart", takesOver: true))
        }
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "SessionEnd", "reason": "clear"}"#)
                == expected(AgentState.none, "SessionEnd", releases: true))
    }

    @Test func promptsAndToolCallsMeanWorking() {
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "UserPromptSubmit", "prompt": "Write a function"}"#)
                == expected(.working, "UserPromptSubmit"))
        for event in ["PostToolUse", "PostToolUseFailure"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "\#(event)", "tool_name": "Bash"}"#)
                    == expected(.working, event))
            // A background subagent keeps calling tools while the main agent waits on a question.
            #expect(
                report(
                    #"{"session_id": "abc123", "hook_event_name": "\#(event)", "tool_name": "Bash", "agent_id": "def456"}"#
                )
                    == nil)
        }
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "ElicitationResult"}"#)
                == expected(.working, "ElicitationResult"))
    }

    @Test func questionsPermissionsAndDialogsMeanWaiting() {
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "PreToolUse", "tool_name": "\#(tool)"}"#)
                    == expected(.waiting, "PreToolUse"))
        }
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "PreToolUse", "tool_name": "Bash"}"#) == nil)
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "rm -rf node_modules"}}"#
            )
                == expected(.waiting, "PermissionRequest"))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "agent_id": "def456"}"#
            )
                == nil)
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "Notification", "notification_type": "\#(type)"}"#)
                    == expected(.waiting, "Notification"))
        }
        #expect(
            report(#"{"session_id": "abc123", "hook_event_name": "Elicitation"}"#) == expected(.waiting, "Elicitation"))
    }

    @Test func otherNotificationsAndEventsMapToNothing() {
        for type in ["idle_prompt", "auth_success", "elicitation_complete"] {
            #expect(
                report(#"{"session_id": "abc123", "hook_event_name": "Notification", "notification_type": "\#(type)"}"#)
                    == nil)
        }
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "SubagentStop", "agent_id": "def456"}"#) == nil)
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "SomeFutureEvent"}"#) == nil)
        #expect(report("not json") == nil)
        #expect(report("") == nil)
        #expect(report(#"["SessionStart"]"#) == nil)
    }

    @Test func aTurnEndsDoneOnAQuestionOrStillWorking() {
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "I've completed the refactoring.", "background_tasks": []}"#
            )
                == expected(.done, "Stop"))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Done.\n\nShould I push it?\n"}"#
            )
                == expected(.waiting, "Stop", question: true))
        #expect(report(#"{"session_id": "abc123", "hook_event_name": "Stop"}"#) == expected(.done, "Stop"))
        for type in ["subagent", "workflow"] {
            #expect(
                report(
                    #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Waiting on it.", "background_tasks": [{"id": "t1", "type": "\#(type)", "status": "running"}]}"#
                )
                    == expected(.working, "Stop"))
        }
        for type in ["shell", "monitor"] {
            #expect(
                report(
                    #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "The server runs.", "background_tasks": [{"id": "t1", "type": "\#(type)", "status": "running", "command": "bun dev"}]}"#
                )
                    == expected(.done, "Stop"))
        }
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "StopFailure", "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached?"}"#
            )
                == expected(.done, "StopFailure"))
    }

    @Test func theQuestionRuleReadsTheLastLine() {
        for message in [
            "Want me to go on?", "Should I proceed?**", "Is that right?\n\n", "(or should I skip it?)", "Push it? ",
            "Which one: `a` or `b`?`", "“Ready?”", "続けますか？", "First line\r\nSecond?",
        ] {
            #expect(ClaudeHookMapping.endsOnQuestion(message), "\(message)")
        }
        for message in [
            "Done.", "Should I? No, it is done.", "What next?\nNothing, it is merged.", "", "\n\n", "?\n```",
        ] {
            #expect(!ClaudeHookMapping.endsOnQuestion(message), "\(message)")
        }
    }

    @Test func theHookBuildsItsRequestOnlyInsideCanopy() throws {
        let input = Data(
            #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Done."}"#.utf8)
        let environment = ["CANOPY_PANE": "p12", "CANOPY_HOME": "/tmp/canopy-home"]

        let built = try #require(AgentHook.request(input: input, environment: environment, startedAt: started))
        #expect(built.socketPath == "/tmp/canopy-home/canopy.sock")
        #expect(built.request.method == TermMethod.state)
        let params = try #require(built.request.params).decode(TermStateParams.self)
        #expect(params.pane == "p12")
        #expect(params.report == expected(.done, "Stop"))

        #expect(AgentHook.request(input: input, environment: ["CANOPY_PANE": "p12"], startedAt: started) == nil)
        #expect(AgentHook.request(input: input, environment: ["CANOPY_HOME": "/tmp/x"], startedAt: started) == nil)
        #expect(
            AgentHook.request(
                input: input, environment: ["CANOPY_PANE": "", "CANOPY_HOME": "/tmp/x"], startedAt: started)
                == nil)
        #expect(AgentHook.request(input: Data("{}".utf8), environment: environment, startedAt: started) == nil)
    }

    @Test func aProcessStartTimeOrdersProcesses() throws {
        let own = try #require(ProcessTable.startTime(of: getpid()))
        #expect(own <= Date())
        #expect(own > Date().addingTimeInterval(-86_400))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let childStart = try #require(ProcessTable.startTime(of: child.processIdentifier))
        #expect(childStart > own)
        #expect(ProcessTable.startTime(of: 999_999) == nil)
    }

    @Test func postingWaitsAtMostASecondForTheApp() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let received = Mutex<[String]>([])
        let server = ControlServer(socketPath: home.socketPath) { request in
            received.withLock { $0.append(request.method) }
            if request.method == "slow" {
                try? await Task.sleep(for: .seconds(3))
            }
            return .success(id: request.id, result: .null)
        }
        try await server.start()
        defer { server.stop() }

        let socketPath = home.socketPath
        let clock = ContinuousClock()
        let fast = try await clock.measure {
            try await offPool { try ControlClient(socketPath: socketPath).post(ControlRequest(method: "term.state")) }
        }
        #expect(fast < .seconds(1))
        #expect(received.withLock { $0 } == ["term.state"])

        let slow = try await clock.measure {
            try await offPool { try ControlClient(socketPath: socketPath).post(ControlRequest(method: "slow")) }
        }
        #expect(slow >= .milliseconds(900) && slow < .seconds(2))
        #expect(received.withLock { $0 } == ["term.state", "slow"])
    }

    @Test func postingFailsFastWhenTheAppIsNotRunning() async throws {
        let dir = try TempDir()
        let socketPath = dir.sub("canopy.sock")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: ControlClientError.connectFailed(errno: ENOENT)) {
                try ControlClient(socketPath: socketPath).post(ControlRequest(method: "term.state"))
            }
        }
        #expect(elapsed < .seconds(1))
    }
}
````

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ClaudeHookTests`
Expected: compile errors, `cannot find 'AgentHook' in scope`.

- [ ] **Step 3: Write the mapping, the start time, and `post`**

`Sources/CanopyCore/Agents/ClaudeHookMapping.swift`, in full:

```swift
import Foundation

/// Turns what a Claude Code hook receives on stdin into a report of the agent's state.
public enum ClaudeHookMapping {
    /// The report for a hook's input, or nil for an event that says nothing about the pane.
    /// `startedAt` is when the hook process started, which orders reports that arrive out of order.
    public static func report(from input: Data, startedAt: Date?) -> AgentReport? {
        guard let hook = try? JSONDecoder().decode(HookInput.self, from: input) else { return nil }
        func report(
            _ state: AgentState?, question: Bool = false, takesOver: Bool = false, releases: Bool = false
        ) -> AgentReport {
            AgentReport(
                state: state, session: hook.sessionID, event: hook.event, at: startedAt, question: question,
                takesOver: takesOver, releases: releases)
        }
        let fromMainAgent = hook.agentID == nil
        switch hook.event {
        case "SessionStart":
            return report(nil, takesOver: (hook.source ?? "startup") != "startup")
        case "SessionEnd":
            return report(AgentState.none, releases: true)
        case "UserPromptSubmit", "ElicitationResult":
            return report(.working)
        case "PostToolUse", "PostToolUseFailure":
            return fromMainAgent ? report(.working) : nil
        case "PreToolUse":
            return ["AskUserQuestion", "ExitPlanMode"].contains(hook.toolName) ? report(.waiting) : nil
        case "PermissionRequest":
            return fromMainAgent ? report(.waiting) : nil
        case "Elicitation":
            return report(.waiting)
        case "Notification":
            switch hook.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return report(.waiting)
            case "agent_completed":
                return report(.done)
            default:
                return nil
            }
        case "Stop":
            // Background subagents and workflows end on their own and wake the agent, so the turn is not over.
            // Shell and monitor tasks can run for good, like a dev server, so they do not count.
            if hook.backgroundTasks?.contains(where: { ["subagent", "workflow"].contains($0.type) }) == true {
                return report(.working)
            }
            if let message = hook.lastAssistantMessage, endsOnQuestion(message) {
                return report(.waiting, question: true)
            }
            return report(.done)
        case "StopFailure":
            return report(.done)
        default:
            return nil
        }
    }

    /// Whether a message's last line that is not blank ends in a question mark, after closing marks such as `**`,
    /// `)`, and quotes.
    public static func endsOnQuestion(_ message: String) -> Bool {
        guard let line = message.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) })
        else { return false }
        var text = line
        while let last = text.last, last.isWhitespace || closingMarks.contains(last) {
            text = text.dropLast()
        }
        return text.last == "?" || text.last == "？"
    }

    static let closingMarks: Set<Character> = ["*", "_", "`", ")", "]", "\"", "'", "”", "’"]

    struct HookInput: Decodable {
        var event: String
        var sessionID: String?
        var agentID: String?
        var source: String?
        var toolName: String?
        var notificationType: String?
        var lastAssistantMessage: String?
        var backgroundTasks: [BackgroundTask]?

        struct BackgroundTask: Decodable {
            var type: String?
        }

        enum CodingKeys: String, CodingKey {
            case event = "hook_event_name"
            case sessionID = "session_id"
            case agentID = "agent_id"
            case source
            case toolName = "tool_name"
            case notificationType = "notification_type"
            case lastAssistantMessage = "last_assistant_message"
            case backgroundTasks = "background_tasks"
        }
    }
}

/// What `canopy agent-hook` sends, and where.
public struct AgentHookRequest: Sendable {
    public var socketPath: String
    public var request: ControlRequest
}

public enum AgentHook {
    /// The request for a hook's input, or nil outside a Canopy terminal or for an event that maps to nothing.
    public static func request(input: Data, environment: [String: String], startedAt: Date?) -> AgentHookRequest? {
        guard let pane = environment["CANOPY_PANE"], !pane.isEmpty,
            let home = environment[CanopyHome.environmentKey], !home.isEmpty,
            let report = ClaudeHookMapping.report(from: input, startedAt: startedAt),
            let params = try? JSONValue.from(TermStateParams(pane: pane, report))
        else { return nil }
        return AgentHookRequest(
            socketPath: CanopyHome(path: home).socketPath,
            request: ControlRequest(method: TermMethod.state, params: params))
    }
}
```

`Sources/CanopyCore/Ports/ProcessTable.swift`:

```diff
@@ -1,4 +1,5 @@
 import Darwin
+import Foundation
 
 /// Facts about a running process, read from the kernel.
 public enum ProcessTable {
@@ -20,6 +21,14 @@ public enum ProcessTable {
         return path.isEmpty ? nil : path
     }
 
+    /// When the process started, to the microsecond.
+    public static func startTime(of pid: pid_t) -> Date? {
+        var info = proc_bsdinfo()
+        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
+        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
+        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
+    }
+
     public static func name(of pid: pid_t) -> String? {
         var name = [CChar](repeating: 0, count: 256)
         guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
```

`post` first closed the socket right after writing.
Run with the control tests, the app lost the request in 3 of 4 runs: its connection failed with ENETDOWN before reading what the client had sent.
Waiting for the reply, with a one-second cap, fixed it in 5 of 5 runs.

`Sources/CanopyCore/Control/ControlClient.swift`:

```diff
@@ -49,16 +49,7 @@ public struct ControlClient: Sendable {
             setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
         }
 
-        let payload = try ControlCodec.encodeLine(request)
-        try payload.withUnsafeBytes { raw in
-            var offset = 0
-            while offset < raw.count {
-                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
-                if written < 0 && errno == EINTR { continue }
-                if written < 0 { throw ControlClientError.writeFailed(errno: errno) }
-                offset += written
-            }
-        }
+        try Self.write(try ControlCodec.encodeLine(request), to: fd)
 
         var received = Data()
         var chunk = [UInt8](repeating: 0, count: 65_536)
@@ -75,6 +66,36 @@ public struct ControlClient: Sendable {
         return try ControlCodec.decode(ControlResponse.self, from: Data(line))
     }
 
+    /// Sends a request whose reply does not matter, for hooks that must never hold up what runs them. It waits at
+    /// most `timeout` seconds for the reply, because the app can lose a request from a client that closed before
+    /// the app read it.
+    public func post(_ request: ControlRequest, timeout: TimeInterval = 1) throws {
+        let fd = try Self.connect(to: socketPath)
+        defer { close(fd) }
+        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
+        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
+        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
+        try Self.write(try ControlCodec.encodeLine(request), to: fd)
+        var chunk = [UInt8](repeating: 0, count: 4096)
+        while true {
+            let count = read(fd, &chunk, chunk.count)
+            if count < 0 && errno == EINTR { continue }
+            if count <= 0 || chunk[0..<count].contains(0x0A) { return }
+        }
+    }
+
+    static func write(_ data: Data, to fd: Int32) throws {
+        try data.withUnsafeBytes { raw in
+            var offset = 0
+            while offset < raw.count {
+                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
+                if written < 0 && errno == EINTR { continue }
+                if written < 0 { throw ControlClientError.writeFailed(errno: errno) }
+                offset += written
+            }
+        }
+    }
+
     static func connect(to path: String) throws -> Int32 {
         var address = sockaddr_un()
         address.sun_family = sa_family_t(AF_UNIX)
```

`docs/superpowers/specs/2026-09-28-canopy-agent-state-design.md`:

```diff
@@ -124,7 +124,8 @@ It does nothing, quietly, when:
 - the socket is missing or refuses the connection, as while the app is not running.
 
 It never launches the app.
-It writes the request and exits without waiting for the reply, and gives up if the socket has not accepted it within one second, so a busy app never holds Claude up.
+It waits for the app's reply for at most one second, so a busy app never holds Claude up for longer.
+It does wait that long, because the app can lose a request from a client that closed before the app read it.
 Hooks run with Claude Code's environment, which it inherited from the pane's shell, so they see the pane's variables.
 
 ### Hook mapping
```

- [ ] **Step 4: Run the tests, under load with the control tests**

Run: `for i in 1 2 3 4 5; do LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "ClaudeHookTests|ControlServerTests"; done`
Expected: every run passes.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: map Claude Code hooks to agent reports, and post them to the app"
```

## Task 6: Canopy's hooks in Claude Code's settings

`OrderedJSON` reads and writes JSON with its keys in order and its numbers as written, in `JSON.stringify(value, null, 2)` style, so a file Claude Code wrote comes back byte for byte.
`ClaudeHooks` adds and removes Canopy's handlers, and `ClaudeSettingsFile` finds, reads, and safely rewrites the file.

**Files:**
- Create: `Sources/CanopyCore/Agents/OrderedJSON.swift`, `Sources/CanopyCore/Agents/ClaudeHooks.swift`
- Modify: `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/ClaudeSettingsTests.swift`

**Interfaces:**
- Produces: `OrderedJSON` with `parse(_:)`, `formatted()`, `subscript(key:)` that adds, changes, and removes keys, and `validSettings()`; `OrderedJSONError(offset:reason:)`; `ClaudeHooks.command`, `ClaudeHooks.Status` (`installed`, `outdated`, `not_installed`), `status(of:)`, `installing(into:)`, and `uninstalling(from:)`; `ClaudeSettingsFile(url:)`, `resolve(explicit:environment:homeDirectory:)`, `configFolder(environment:homeDirectory:)`, `read()`, `status()`, `disablesAllHooks()`, `install() -> Bool`, `uninstall() -> Bool`, and `update(_:) -> Bool`; `WorkspaceError.settingsInvalid` (`settings_invalid`) and `.settingsWriteFailed` (`settings_write_failed`).

- [ ] **Step 1: Write the failing tests**

`Fixture.claudeSettings` is the only way tests get a settings file, and it records an issue if a path resolves to the real one.

`Tests/CanopyCoreTests/ClaudeSettingsTests.swift`, in full:

```swift
import Foundation
import Testing

@testable import CanopyCore

extension Fixture {
    /// A settings file in the temporary folder. Tests must never resolve the real one: every agent on the machine
    /// runs with it.
    static func claudeSettings(_ dir: TempDir, _ name: String = "claude/settings.json") -> ClaudeSettingsFile {
        let file = ClaudeSettingsFile.resolve(
            explicit: dir.sub(name), environment: [:], homeDirectory: dir.sub("user-home"))
        let real = NSHomeDirectory() + "/.claude/settings.json"
        if file.url.path == real || file.url.resolvingSymlinksInPath().path == real {
            Issue.record("A test resolved the real Claude Code settings file.")
            return ClaudeSettingsFile(url: URL(fileURLWithPath: dir.sub("refused.json")))
        }
        return file
    }
}

struct ClaudeSettingsTests {
    /// Settings as Claude Code writes them: JSON.stringify with two-space indentation.
    static let written = """
        {
          "model": "opus",
          "permissions": {
            "allow": [
              "Bash(git status)",
              "Read(//tmp/**)"
            ],
            "deny": []
          },
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say \\"done\\" && echo '✓ 完了'",
                    "timeout": 1.5
                  }
                ]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/bin/check\\tbash"
                  }
                ]
              }
            ]
          },
          "cleanupPeriodDays": 1e2,
          "feedbackSurveyState": {
            "lastShownTime": 1759000000000
          },
          "enabledPlugins": {},
          "statusLine": null,
          "includeCoAuthoredBy": false
        }

        """

    func write(_ text: String, to file: ClaudeSettingsFile) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    func text(_ file: ClaudeSettingsFile) throws -> String {
        String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
    }

    @Test func jsonComesBackTheWayItWasWritten() throws {
        let parsed = try OrderedJSON.parse(Data(Self.written.utf8))
        #expect(parsed.formatted() + "\n" == Self.written)
        #expect(parsed["model"] == .string("opus"))
        #expect(parsed["cleanupPeriodDays"] == .number("1e2"))

        let escapes = try OrderedJSON.parse(Data(#"{"a":"é😀\/\b\f\n\r\t\u0001\"\\","b":[],"c":{}}"#.utf8))
        #expect(escapes["a"] == .string("é😀/\u{8}\u{c}\n\r\t\u{1}\"\\"))
        #expect(
            escapes.formatted() == """
                {
                  "a": "é😀/\\b\\f\\n\\r\\t\\u0001\\"\\\\",
                  "b": [],
                  "c": {}
                }
                """)
    }

    @Test func invalidJSONIsRefused() {
        for text in [
            "", "{", #"{"a": 1,}"#, "{\"a\": 1} // note", "[1] 2", "{a: 1}", "tru", "01", "1.", "-", #"{"a":"\x"}"#,
            "\"unterminated",
        ] {
            #expect(throws: OrderedJSONError.self, "\(text)") { try OrderedJSON.parse(Data(text.utf8)) }
        }
    }

    @Test func installIntoAMissingFileCreatesItWithEveryHook() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)

        #expect(try file.status() == .notInstalled)
        #expect(try file.install())
        #expect(try file.status() == .installed)

        let settings = try OrderedJSON.parse(try Data(contentsOf: file.url))
        guard case .object(let events) = settings["hooks"] else {
            Issue.record("no hooks")
            return
        }
        #expect(
            events.map(\.key) == [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                "PostToolUseFailure", "Notification", "Elicitation", "ElicitationResult", "Stop", "StopFailure",
                "SessionEnd",
            ])
        let text = try text(file)
        #expect(text.hasSuffix("}\n"))
        #expect(
            text.contains(
                """
                    "PreToolUse": [
                      {
                        "matcher": "AskUserQuestion|ExitPlanMode",
                        "hooks": [
                          {
                            "type": "command",
                            "command": "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" agent-hook >/dev/null 2>&1 || true",
                            "async": true
                          }
                        ]
                      }
                    ],
                """))
        #expect(
            text.contains(
                """
                    "Stop": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" agent-hook >/dev/null 2>&1 || true",
                            "timeout": 5
                          }
                        ]
                      }
                    ],
                """))
        #expect(
            text.contains(
                """
                    "SessionEnd": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" agent-hook >/dev/null 2>&1 || true"
                          }
                        ]
                      }
                    ]
                """))
    }

    @Test func installKeepsEverythingElseAndUninstallGivesBackTheSameBytes() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write(Self.written, to: file)

        #expect(try file.install())
        let installed = try OrderedJSON.parse(try Data(contentsOf: file.url))
        #expect(installed["model"] == .string("opus"))
        guard case .object(let keys) = installed, case .object(let events) = installed["hooks"],
            case .array(let stop) = installed["hooks"]?["Stop"]
        else {
            Issue.record("no hooks")
            return
        }
        #expect(keys.map(\.key).first == "model")
        #expect(events.map(\.key).prefix(2) == ["Stop", "PreToolUse"])
        #expect(stop.count == 2)

        let before = try Data(contentsOf: file.url)
        #expect(try !file.install())
        #expect(try Data(contentsOf: file.url) == before)

        #expect(try file.uninstall())
        #expect(try text(file) == Self.written)
        #expect(try !file.uninstall())
        #expect(try file.status() == .notInstalled)
    }

    @Test func olderOrMissingCanopyHooksAreOutdatedAndReplaced() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write(
            """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "\\"$CANOPY_CLI\\" agent-hook"
                      },
                      {
                        "type": "command",
                        "command": "afplay /System/Library/Sounds/Hero.aiff"
                      }
                    ]
                  }
                ]
              }
            }
            """, to: file)
        #expect(try file.status() == .outdated)

        #expect(try file.install())
        #expect(try file.status() == .installed)
        let text = try text(file)
        #expect(!text.contains(#""\"$CANOPY_CLI\" agent-hook""#))
        #expect(text.contains("afplay"))

        // One hook taken out by hand makes the rest outdated.
        try file.update { settings in
            var settings = settings
            settings["hooks"]?["Elicitation"] = nil
            return settings
        }
        #expect(try file.status() == .outdated)
        #expect(try file.install())
        #expect(try file.status() == .installed)
    }

    @Test func aLinkedSettingsFileIsWrittenThrough() throws {
        let dir = try TempDir()
        let target = Fixture.claudeSettings(dir, "dotfiles/claude-settings.json")
        try write("{\n  \"model\": \"opus\"\n}\n", to: target)
        let link = Fixture.claudeSettings(dir, "claude/settings.json")
        try FileManager.default.createDirectory(
            at: link.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: target.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.url.path)

        #expect(try link.install())
        let attributes = try FileManager.default.attributesOfItem(atPath: link.url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try target.status() == .installed)
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: target.url.path)
        #expect(targetAttributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func aFileThatIsNotAJSONObjectIsLeftAlone() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        for text in ["{ \"model\": \"opus\", }", "[]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}"] {
            try write(text, to: file)
            #expect(throws: WorkspaceError.self) { try file.install() }
            #expect(try self.text(file) == text)
        }
        try write("[]", to: file)
        do {
            try file.install()
        } catch let error as WorkspaceError {
            #expect(error.code == "settings_invalid")
        }
    }

    @Test func aFileChangedWhileWritingIsReadAgain() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write("{\n  \"model\": \"opus\"\n}\n", to: file)
        var attempts = 0
        try file.update { settings in
            attempts += 1
            if attempts == 1 {
                // Claude Code saves a setting of its own at the same moment.
                try Data("{\n  \"model\": \"sonnet\"\n}\n".utf8).write(to: file.url)
            }
            return ClaudeHooks.installing(into: try settings.validSettings())
        }
        #expect(attempts == 2)
        let settings = try OrderedJSON.parse(try Data(contentsOf: file.url))
        #expect(settings["model"] == .string("sonnet"))
        #expect(ClaudeHooks.status(of: settings) == .installed)
    }

    @Test func disablingAllHooksIsNoticed() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write("{\n  \"disableAllHooks\": true\n}\n", to: file)
        #expect(try file.disablesAllHooks())
        try write("{\n  \"disableAllHooks\": false\n}\n", to: file)
        #expect(try !file.disablesAllHooks())
    }

    @Test func theFileIsFoundLikeClaudeCodeFindsIt() {
        let home = "/Users/someone"
        #expect(
            ClaudeSettingsFile.resolve(
                explicit: "/tmp/s.json", environment: ["CLAUDE_CONFIG_DIR": "/x"], homeDirectory: home
            )
            .url.path == "/tmp/s.json")
        #expect(
            ClaudeSettingsFile.resolve(
                explicit: nil, environment: ["CLAUDE_CONFIG_DIR": "/x/claude"], homeDirectory: home
            )
            .url.path == "/x/claude/settings.json")
        #expect(
            ClaudeSettingsFile.resolve(explicit: nil, environment: ["CLAUDE_CONFIG_DIR": ""], homeDirectory: home).url
                .path == "/Users/someone/.claude/settings.json")
        #expect(
            ClaudeSettingsFile.configFolder(environment: [:], homeDirectory: home).path == "/Users/someone/.claude")
        #expect(
            ClaudeSettingsFile.resolve(explicit: "~/s.json", environment: [:], homeDirectory: home).url.path
                == NSString(string: "~/s.json").expandingTildeInPath)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ClaudeSettingsTests`
Expected: compile errors, `cannot find 'ClaudeSettingsFile' in scope`.

- [ ] **Step 3: Write the JSON reader and writer, the hooks, and the file**

`Sources/CanopyCore/Agents/OrderedJSON.swift`, in full:

```swift
import Foundation

public struct OrderedJSONError: Error, Equatable, CustomStringConvertible {
    public var offset: Int
    public var reason: String

    public var description: String {
        "\(reason) at byte \(offset)"
    }
}

/// JSON that keeps its keys in order and its numbers as written, so a file can be edited and written back as it
/// was apart from the edit.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The number's text as written, such as `1e2`.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    /// An object's value for `key`. Setting nil removes the key, and setting a new key adds it at the end.
    public subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    members[index].value = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.offset == parser.bytes.count else { throw parser.error("Unexpected text after the JSON") }
        return value
    }

    /// Two-space indentation, as JavaScript's `JSON.stringify(value, null, 2)` writes it, without a final newline.
    public func formatted() -> String {
        var text = ""
        write(to: &text, indent: "")
        return text
    }

    private func write(to text: inout String, indent: String) {
        let inner = indent + "  "
        switch self {
        case .object(let members) where members.isEmpty:
            text += "{}"
        case .object(let members):
            text += "{\n"
            for (index, member) in members.enumerated() {
                text += inner + Self.quoted(member.key) + ": "
                member.value.write(to: &text, indent: inner)
                text += index == members.count - 1 ? "\n" : ",\n"
            }
            text += indent + "}"
        case .array(let items) where items.isEmpty:
            text += "[]"
        case .array(let items):
            text += "[\n"
            for (index, item) in items.enumerated() {
                text += inner
                item.write(to: &text, indent: inner)
                text += index == items.count - 1 ? "\n" : ",\n"
            }
            text += indent + "]"
        case .string(let string):
            text += Self.quoted(string)
        case .number(let number):
            text += number
        case .bool(let bool):
            text += bool ? "true" : "false"
        case .null:
            text += "null"
        }
    }

    /// Escapes the way `JSON.stringify` does: quotes, backslashes, and control characters only.
    static func quoted(_ string: String) -> String {
        var text = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\u{8}": text += "\\b"
            case "\u{c}": text += "\\f"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case let control where control.value < 0x20: text += String(format: "\\u%04x", control.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        func error(_ reason: String) -> OrderedJSONError {
            OrderedJSONError(offset: offset, reason: reason)
        }

        var current: UInt8? {
            offset < bytes.count ? bytes[offset] : nil
        }

        mutating func skipWhitespace() {
            while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
                offset += 1
            }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard current == byte else { throw error("Expected \(Character(UnicodeScalar(byte)))") }
            offset += 1
        }

        mutating func value() throws -> OrderedJSON {
            guard let byte = current else { throw error("Expected a value") }
            switch byte {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw error("Expected a value")
            }
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let expected = Array(word.utf8)
            guard bytes.count - offset >= expected.count, Array(bytes[offset..<offset + expected.count]) == expected
            else { throw error("Expected \(word)") }
            offset += expected.count
            return value
        }

        mutating func object() throws -> OrderedJSON {
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                offset += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw error("Expected a key") }
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                members.append(Member(key, try value()))
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    offset += 1
                    continue
                }
                try expect(UInt8(ascii: "}"))
                return .object(members)
            }
        }

        mutating func array() throws -> OrderedJSON {
            try expect(UInt8(ascii: "["))
            var items: [OrderedJSON] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                offset += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    offset += 1
                    continue
                }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var scalars = String.UnicodeScalarView()
            var start = offset
            func flush(upTo end: Int) throws {
                guard end > start else { return }
                guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else {
                    throw error("Invalid UTF-8")
                }
                scalars.append(contentsOf: text.unicodeScalars)
            }
            while let byte = current {
                switch byte {
                case UInt8(ascii: "\""):
                    try flush(upTo: offset)
                    offset += 1
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush(upTo: offset)
                    offset += 1
                    scalars.append(try escape())
                    start = offset
                case 0..<0x20:
                    throw error("Control character in a string")
                default:
                    offset += 1
                }
            }
            throw error("Unterminated string")
        }

        mutating func escape() throws -> UnicodeScalar {
            guard let byte = current else { throw error("Unterminated escape") }
            offset += 1
            switch byte {
            case UInt8(ascii: "\""): return "\""
            case UInt8(ascii: "\\"): return "\\"
            case UInt8(ascii: "/"): return "/"
            case UInt8(ascii: "b"): return "\u{8}"
            case UInt8(ascii: "f"): return "\u{c}"
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "u"):
                let high = try hex4()
                if (0xD800..<0xDC00).contains(high) {
                    try expect(UInt8(ascii: "\\"))
                    try expect(UInt8(ascii: "u"))
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low),
                        let scalar = UnicodeScalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
                    else { throw error("Invalid surrogate pair") }
                    return scalar
                }
                guard let scalar = UnicodeScalar(high) else { throw error("Invalid \\u escape") }
                return scalar
            default:
                throw error("Invalid escape")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - offset >= 4,
                let text = String(bytes: bytes[offset..<offset + 4], encoding: .ascii),
                let value = UInt32(text, radix: 16)
            else { throw error("Invalid \\u escape") }
            offset += 4
            return value
        }

        mutating func number() throws -> String {
            let start = offset
            func digits() -> Int {
                let from = offset
                while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                    offset += 1
                }
                return offset - from
            }
            if current == UInt8(ascii: "-") { offset += 1 }
            if current == UInt8(ascii: "0") {
                offset += 1
            } else if digits() == 0 {
                throw error("Invalid number")
            }
            if current == UInt8(ascii: ".") {
                offset += 1
                guard digits() > 0 else { throw error("Invalid number") }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                offset += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { offset += 1 }
                guard digits() > 0 else { throw error("Invalid number") }
            }
            if let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                throw error("Invalid number")
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
    }
}
```

`Sources/CanopyCore/Agents/ClaudeHooks.swift`, in full:

```swift
import Foundation

/// Canopy's hooks in a Claude Code settings file, which run `canopy agent-hook` from Canopy's terminals.
public enum ClaudeHooks {
    /// Runs the CLI of the Canopy that owns the terminal, and nothing outside Canopy. It never fails, so nothing shows
    /// in Claude's transcript.
    public static let command = #"[ -z "$CANOPY_CLI" ] || "$CANOPY_CLI" agent-hook >/dev/null 2>&1 || true"#

    public enum Status: String, Codable, Sendable {
        case installed
        /// Some of Canopy's hooks are missing or differ, as after an older Canopy installed them.
        case outdated
        case notInstalled = "not_installed"
    }

    enum Timing {
        /// Claude goes on without waiting.
        case background
        /// Claude waits, so the report arrives before a `claude -p` exits. The timeout only caps a hang.
        case inline
        /// Like inline, with no timeout of its own, so Claude Code keeps its short budget for `SessionEnd` hooks.
        case end
    }

    struct Entry {
        let event: String
        let matcher: String?
        let timing: Timing
    }

    static let entries = [
        Entry(event: "SessionStart", matcher: nil, timing: .background),
        Entry(event: "UserPromptSubmit", matcher: nil, timing: .background),
        Entry(event: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode", timing: .background),
        Entry(event: "PermissionRequest", matcher: nil, timing: .background),
        Entry(event: "PostToolUse", matcher: nil, timing: .background),
        Entry(event: "PostToolUseFailure", matcher: nil, timing: .background),
        Entry(
            event: "Notification",
            matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed",
            timing: .background),
        Entry(event: "Elicitation", matcher: nil, timing: .background),
        Entry(event: "ElicitationResult", matcher: nil, timing: .background),
        Entry(event: "Stop", matcher: nil, timing: .inline),
        Entry(event: "StopFailure", matcher: nil, timing: .inline),
        Entry(event: "SessionEnd", matcher: nil, timing: .end),
    ]

    static func handler(_ timing: Timing) -> OrderedJSON {
        var members = [OrderedJSON.Member("type", .string("command")), .init("command", .string(command))]
        switch timing {
        case .background: members.append(.init("async", .bool(true)))
        case .inline: members.append(.init("timeout", .number("5")))
        case .end: break
        }
        return .object(members)
    }

    static func group(_ entry: Entry) -> OrderedJSON {
        var group = OrderedJSON.object([])
        if let matcher = entry.matcher {
            group["matcher"] = .string(matcher)
        }
        group["hooks"] = .array([handler(entry.timing)])
        return group
    }

    /// A handler that runs `canopy agent-hook`, from this Canopy or an older one.
    static func isCanopy(_ handler: OrderedJSON) -> Bool {
        guard case .string(let command) = handler["command"] else { return false }
        return command.contains("CANOPY_CLI") && command.contains("agent-hook")
    }

    public static func status(of settings: OrderedJSON) -> Status {
        let groups = canopyGroups(in: settings)
        if groups.isEmpty { return .notInstalled }
        let wanted = entries.map { (event: $0.event, group: group($0)) }
        let matches =
            groups.count == wanted.count
            && wanted.allSatisfy { entry in groups.contains { $0.event == entry.event && $0.group == entry.group } }
        return matches ? .installed : .outdated
    }

    /// Adds Canopy's hooks after replacing any that differ. Settings that already have them come back unchanged.
    public static func installing(into settings: OrderedJSON) -> OrderedJSON {
        guard status(of: settings) != .installed else { return settings }
        var settings = uninstalling(from: settings)
        var hooks = settings["hooks"] ?? .object([])
        for entry in entries {
            var groups: [OrderedJSON] = []
            if case .array(let existing) = hooks[entry.event] { groups = existing }
            hooks[entry.event] = .array(groups + [group(entry)])
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Removes every Canopy handler, then the matcher groups, events, and `hooks` key that removing them emptied.
    public static func uninstalling(from settings: OrderedJSON) -> OrderedJSON {
        guard case .object(let events) = settings["hooks"] else { return settings }
        var kept: [OrderedJSON.Member] = []
        var removedAny = false
        for event in events {
            guard case .array(let groups) = event.value else {
                kept.append(event)
                continue
            }
            var keptGroups: [OrderedJSON] = []
            for group in groups {
                guard case .array(let handlers) = group["hooks"], handlers.contains(where: isCanopy) else {
                    keptGroups.append(group)
                    continue
                }
                removedAny = true
                let rest = handlers.filter { !isCanopy($0) }
                if !rest.isEmpty {
                    var group = group
                    group["hooks"] = .array(rest)
                    keptGroups.append(group)
                }
            }
            if !keptGroups.isEmpty || groups.isEmpty {
                kept.append(.init(event.key, .array(keptGroups)))
            }
        }
        guard removedAny else { return settings }
        var settings = settings
        settings["hooks"] = kept.isEmpty ? nil : .object(kept)
        return settings
    }

    /// Every matcher group holding a Canopy handler, with its event.
    static func canopyGroups(in settings: OrderedJSON) -> [(event: String, group: OrderedJSON)] {
        guard case .object(let events) = settings["hooks"] else { return [] }
        return events.flatMap { event -> [(event: String, group: OrderedJSON)] in
            guard case .array(let groups) = event.value else { return [] }
            return groups.compactMap { group in
                guard case .array(let handlers) = group["hooks"], handlers.contains(where: isCanopy) else {
                    return nil
                }
                return (event.key, group)
            }
        }
    }
}

extension OrderedJSON {
    /// The settings, if they have the shape Claude Code reads: an object, whose `hooks` is an object of events, each
    /// an array of matcher groups holding an array of handlers.
    public func validSettings() throws -> OrderedJSON {
        func invalid(_ reason: String) -> OrderedJSONError {
            OrderedJSONError(offset: 0, reason: reason)
        }
        guard case .object = self else { throw invalid("The settings are not a JSON object") }
        guard let hooks = self["hooks"] else { return self }
        guard case .object(let events) = hooks else { throw invalid("\"hooks\" is not an object") }
        for event in events {
            guard case .array(let groups) = event.value else { throw invalid("\"\(event.key)\" is not an array") }
            for group in groups {
                guard case .object = group else { throw invalid("A \"\(event.key)\" hook is not an object") }
                if let handlers = group["hooks"], case .array = handlers {
                    continue
                } else if group["hooks"] != nil {
                    throw invalid("A \"\(event.key)\" group's \"hooks\" is not an array")
                }
            }
        }
        return self
    }
}

/// Claude Code's user settings file, where Canopy's hooks go.
public struct ClaudeSettingsFile: Sendable {
    /// The file as named. It may be a symbolic link.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `explicit` when given, else `settings.json` in Claude Code's config folder, which is where Claude Code looks.
    public static func resolve(explicit: String?, environment: [String: String], homeDirectory: String)
        -> ClaudeSettingsFile
    {
        if let explicit, !explicit.isEmpty {
            return ClaudeSettingsFile(url: URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath))
        }
        return ClaudeSettingsFile(
            url: configFolder(environment: environment, homeDirectory: homeDirectory).appending(path: "settings.json"))
    }

    /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func configFolder(environment: [String: String], homeDirectory: String) -> URL {
        if let folder = environment["CLAUDE_CONFIG_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath)
        }
        return URL(fileURLWithPath: homeDirectory).appending(path: ".claude")
    }

    /// The settings, or an empty object when the file does not exist yet.
    public func read() throws -> OrderedJSON {
        try Self.parse(try contents(of: target), path: url.path)
    }

    public func status() throws -> ClaudeHooks.Status {
        ClaudeHooks.status(of: try read())
    }

    public func disablesAllHooks() throws -> Bool {
        try read()["disableAllHooks"] == .bool(true)
    }

    /// Returns whether the file changed.
    @discardableResult
    public func install() throws -> Bool {
        try update { ClaudeHooks.installing(into: $0) }
    }

    /// Returns whether the file changed.
    @discardableResult
    public func uninstall() throws -> Bool {
        try update { ClaudeHooks.uninstalling(from: $0) }
    }

    /// Rewrites the file with `transform`'s result, unless it changed nothing. A file changed by someone else while
    /// this ran is read again and transformed again. Returns whether the file changed.
    @discardableResult
    public func update(_ transform: (OrderedJSON) throws -> OrderedJSON) throws -> Bool {
        for _ in 0..<3 {
            let target = self.target
            let original = try contents(of: target)
            let settings = try Self.parse(original, path: url.path)
            let updated = try transform(settings)
            guard updated != settings else { return false }
            let newline = original.map { $0.last == 0x0A } ?? true
            let data = Data((updated.formatted() + (newline ? "\n" : "")).utf8)
            if try write(data, to: target, replacing: original) { return true }
        }
        throw WorkspaceError.settingsWriteFailed(url.path, reason: "it kept changing while Canopy wrote it")
    }

    /// The file the name points to, following symbolic links, so a linked file is written and the link stays.
    var target: URL {
        url.resolvingSymlinksInPath()
    }

    private func contents(of file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw WorkspaceError.settingsInvalid(url.path, reason: error.localizedDescription)
        }
    }

    private static func parse(_ data: Data?, path: String) throws -> OrderedJSON {
        guard let data else { return .object([]) }
        do {
            return try OrderedJSON.parse(data).validSettings()
        } catch let error as OrderedJSONError {
            throw WorkspaceError.settingsInvalid(path, reason: error.description)
        }
    }

    /// Writes beside the file and renames over it, unless the file no longer holds `original`. Returns whether it
    /// wrote.
    private func write(_ data: Data, to file: URL, replacing original: Data?) throws -> Bool {
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(file.lastPathComponent).canopy-\(UUID().uuidString.prefix(8))")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: temporary)
            let permissions = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
            try manager.setAttributes([.posixPermissions: permissions ?? 0o644], ofItemAtPath: temporary.path)
            guard try contents(of: file) == original else {
                try? manager.removeItem(at: temporary)
                return false
            }
            guard rename(temporary.path, file.path) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
            return true
        } catch let error as WorkspaceError {
            try? manager.removeItem(at: temporary)
            throw error
        } catch {
            try? manager.removeItem(at: temporary)
            throw WorkspaceError.settingsWriteFailed(url.path, reason: error.localizedDescription)
        }
    }
}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -32,6 +32,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case waitTimeout([String], String)
     case paneClosed(String)
     case agentStopped(String)
+    case settingsInvalid(String, reason: String)
+    case settingsWriteFailed(String, reason: String)
     case noPullRequestLookup(String)
     case notOnGitHub(String)
     case ghUnavailable(String)
@@ -82,6 +84,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .waitTimeout: "wait_timeout"
         case .paneClosed: "pane_closed"
         case .agentStopped: "agent_stopped"
+        case .settingsInvalid: "settings_invalid"
+        case .settingsWriteFailed: "settings_write_failed"
         case .noPullRequestLookup: "no_pr_lookup"
         case .notOnGitHub: "not_github"
         case .ghUnavailable: "gh_unavailable"
@@ -155,6 +159,9 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .paneClosed(let id): "\(id) closed during the wait."
         case .agentStopped(let id):
             "The agent in \(id) stopped without finishing: it exited, was interrupted, or was set to none."
+        case .settingsInvalid(let path, let reason):
+            "\(path) is not settings Claude Code can read (\(reason)). Nothing was changed."
+        case .settingsWriteFailed(let path, let reason): "Could not write \(path): \(reason). Nothing was changed."
         case .noPullRequestLookup(let name):
             "Canopy only looks up PRs for its own and adopted rows on a branch, and \(name) is not one."
         case .notOnGitHub(let repo): "\(repo)'s origin is not on GitHub, so its rows have no PRs."
```

- [ ] **Step 4: Run the tests, then break the code to see them catch it**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ClaudeSettingsTests`
Expected: 10 tests pass.

Each of these breaks at least one test: escaping `/` in `quoted`, keeping events that uninstall emptied, and skipping the re-read before the rename.
Copy each file aside before breaking it and copy it back after, never `git checkout` it.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: install and remove Canopy's hooks in Claude Code's settings"
```

## Task 7: The CLI

**Files:**
- Create: `Sources/CanopyCLI/HooksCommand.swift`, `Sources/CanopyCore/Support/TimeSpan.swift`
- Modify: `Sources/CanopyCLI/TermCommand.swift`, `Sources/CanopyCLI/CanopyCLI.swift`, `Sources/CanopyCLI/Client.swift`, `Sources/CanopyCLI/AgentGuide.swift`, `Sources/CanopyCore/Terminal/PaneEnvironment.swift`, `scripts/e2e.sh`
- Test: `Tests/CanopyCoreTests/TimeSpanTests.swift`, `Tests/CanopyCoreTests/PaneEnvironmentTests.swift`, and `make e2e`

**Interfaces:**
- Consumes: everything above.
- Produces: `canopy term state [<id>] <state>`, `canopy term wait <id>... [--for] [--timeout]`, `canopy hooks install|uninstall|status [--settings]`, the hidden `canopy agent-hook`, the AGENT column, the `CANOPY_CLI` pane variable, `TimeSpan.seconds(_:) -> Double?`, and `Client.call(_:_:launchIfNeeded:waitingUpTo:)`.

- [ ] **Step 1: Write the failing tests**

`Span` would clash with the standard library's `Span`, so the parser is `TimeSpan`.

`Tests/CanopyCoreTests/TimeSpanTests.swift`, in full:

```swift
import Testing

@testable import CanopyCore

struct TimeSpanTests {
    @Test func spansReadLikeTheLogsOnes() {
        #expect(TimeSpan.seconds("90s") == 90)
        #expect(TimeSpan.seconds("30m") == 1800)
        #expect(TimeSpan.seconds("2h") == 7200)
        #expect(TimeSpan.seconds("1d") == 86_400)
        #expect(TimeSpan.seconds("1w") == 604_800)
        #expect(TimeSpan.seconds("45") == 45)
        #expect(TimeSpan.seconds("0s") == 0)
        #expect(TimeSpan.seconds(" 5M ") == 300)
        for text in ["", "5x", "-1m", "1.5h", "m", "1234567s"] {
            #expect(TimeSpan.seconds(text) == nil, "\(text)")
        }
    }
}
```

`Tests/CanopyCoreTests/PaneEnvironmentTests.swift`:

```diff
@@ -46,9 +46,17 @@ struct PaneEnvironmentTests {
         #expect(environment["CANOPY_ROW_PATH"] == "/w/feat-x")
         #expect(environment["CANOPY_ROOT_PATH"] == "/r/demo")
         #expect(environment["CANOPY_PANE"] == "p12")
+        #expect(environment["CANOPY_CLI"] == "/App/Contents/Resources/bin/canopy")
         #expect(environment["HOME"] == NSHomeDirectory())
     }
 
+    @Test func aBuildWithoutItsCLILeavesItOut() {
+        var settings = settings([:])
+        settings.cliDirectory = nil
+        let environment = PaneEnvironment.build(settings: settings, context: context, pane: PaneID(12))
+        #expect(environment["CANOPY_CLI"] == nil)
+    }
+
     @Test func keepsTheAppsOwnLanguage() {
         let environment = PaneEnvironment.build(
             settings: settings(["LANG": "fr_FR.UTF-8"]), context: context, pane: PaneID(1))
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "TimeSpanTests|PaneEnvironmentTests"`
Expected: compile errors, `cannot find 'TimeSpan' in scope`.

- [ ] **Step 3: Add `TimeSpan` and `CANOPY_CLI`**

`Sources/CanopyCore/Support/TimeSpan.swift`, in full:

```swift
import Foundation

/// A length of time as `canopy log --since` writes one: a count and a unit of s, m, h, d, or w, such as `30m`.
/// A bare count is seconds.
public enum TimeSpan {
    public static func seconds(_ text: String) -> Double? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = lowered.wholeMatch(of: /(\d{1,6})([smhdw]?)/), let count = Double(match.1) else {
            return nil
        }
        let unit: Double =
            switch match.2 {
            case "m": 60
            case "h": 3600
            case "d": 86_400
            case "w": 604_800
            default: 1
            }
        return count * unit
    }
}
```

`Sources/CanopyCore/Terminal/PaneEnvironment.swift`:

```diff
@@ -26,6 +26,10 @@ public enum PaneEnvironment {
         environment["CANOPY_ROW_PATH"] = context.rowPath
         environment["CANOPY_ROOT_PATH"] = context.repoPath
         environment["CANOPY_PANE"] = pane.description
+        // Claude Code's hooks run this CLI, so each Canopy's terminals report to that Canopy.
+        if let cli = settings.cliDirectory {
+            environment["CANOPY_CLI"] = cli + "/canopy"
+        }
         return environment
     }
 }
```

- [ ] **Step 4: Add the commands**

`Sources/CanopyCLI/TermCommand.swift`:

```diff
@@ -6,7 +6,7 @@ struct TermCommand: AsyncParsableCommand {
     static let configuration = CommandConfiguration(
         commandName: "term",
         abstract: "Open, drive, and read terminals.",
-        subcommands: [List.self, New.self, Send.self, Read.self, Close.self]
+        subcommands: [List.self, New.self, Send.self, Read.self, Close.self, State.self, Wait.self]
     )
 
     struct RowOptions: ParsableArguments {
@@ -33,10 +33,12 @@ struct TermCommand: AsyncParsableCommand {
             try client.print(result) {
                 let panes = try result.decode([TermInfo].self)
                 return Table.render(
-                    ["ID", "ROW", "TAB", "PROCESS", "TITLE", "FOLDER"],
+                    ["ID", "ROW", "TAB", "PROCESS", "AGENT", "TITLE", "FOLDER"],
                     panes.map { pane in
                         let process = pane.exited.map { "exited (\($0))" } ?? pane.foreground ?? ""
-                        return [pane.pane, pane.row, pane.tab, process, pane.title, pane.folder]
+                        return [
+                            pane.pane, pane.row, pane.tab, process, pane.agent?.rawValue ?? "", pane.title, pane.folder,
+                        ]
                     }
                 )
             }
@@ -131,4 +133,81 @@ struct TermCommand: AsyncParsableCommand {
             try client.print(result) { "Closed \(id)." }
         }
     }
+
+    struct State: AsyncParsableCommand {
+        static let configuration = CommandConfiguration(
+            abstract: "Report an agent's state in a terminal, your own by default.",
+            usage: "canopy term state [<id>] <working|waiting|done|none> [--json]",
+            discussion: """
+                Agents that Claude Code's hooks do not cover report this way: working while they take a turn, \
+                waiting when they need you, done when they finish, and none when they stop.
+                """
+        )
+
+        @Argument(
+            help: ArgumentHelp("An optional terminal ID, such as p12, then the state.", valueName: "id-and-state"))
+        var values: [String]
+        @OptionGroup var output: OutputOptions
+
+        func validate() throws {
+            guard (1...2).contains(values.count) else { throw ValidationError("Pass a state, and optionally an ID.") }
+            guard AgentState(rawValue: values.last!) != nil else {
+                throw ValidationError("The state must be working, waiting, done, or none.")
+            }
+        }
+
+        func run() async throws {
+            let client = Client(json: output.json)
+            let pane =
+                values.count == 2
+                ? values[0] : ProcessInfo.processInfo.environment["CANOPY_PANE"].flatMap { $0.isEmpty ? nil : $0 }
+            guard let pane else {
+                client.fail(ControlError(WorkspaceError.missingTarget(flag: "a terminal ID")))
+            }
+            let result = client.call(
+                TermMethod.state, TermStateParams(pane: pane, state: AgentState(rawValue: values.last!)),
+                launchIfNeeded: false)
+            try client.print(result) {
+                let reported = try result.decode(TermStateResult.self)
+                return "\(reported.pane) \(reported.state.rawValue)"
+            }
+        }
+    }
+
+    struct Wait: AsyncParsableCommand {
+        static let configuration = CommandConfiguration(
+            abstract: "Wait until an agent in one of the terminals is done or waiting for you.",
+            discussion: """
+                A terminal already in the state counts at once, unless something was typed or sent into it since. \
+                It fails when the time runs out, when one of the terminals closes, or when its agent stops.
+                """
+        )
+
+        @Argument(help: "Terminal IDs, such as p12.")
+        var ids: [String]
+        @Option(name: .customLong("for"), help: ArgumentHelp("done, waiting, or any.", valueName: "state"))
+        var target = AgentWaitTarget.any
+        @Option(help: "How long to wait, such as 90s, 30m, or 2h.")
+        var timeout = "30m"
+        @OptionGroup var output: OutputOptions
+
+        func validate() throws {
+            if ids.isEmpty { throw ValidationError("Pass at least one terminal ID.") }
+            if TimeSpan.seconds(timeout) == nil { throw ValidationError("--timeout takes a span such as 90s or 30m.") }
+        }
+
+        func run() async throws {
+            let client = Client(json: output.json)
+            let seconds = TimeSpan.seconds(timeout) ?? TermWaitParams.defaultTimeout
+            let result = client.call(
+                TermMethod.wait, TermWaitParams(panes: ids, target: target, timeout: seconds), launchIfNeeded: false,
+                waitingUpTo: seconds + 10)
+            try client.print(result) {
+                let reached = try result.decode(TermWaitResult.self)
+                return "\(reached.pane) \(reached.state.rawValue)"
+            }
+        }
+    }
 }
+
+extension AgentWaitTarget: ExpressibleByArgument {}
```

`Sources/CanopyCLI/HooksCommand.swift`, in full:

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct HooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Add or remove the Claude Code hooks that tell Canopy what Claude is doing.",
        discussion: """
            The hooks go in Claude Code's user settings, ~/.claude/settings.json, or settings.json in \
            $CLAUDE_CONFIG_DIR. Other hooks there stay as they are.
            """,
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct Options: ParsableArguments {
        @Option(help: "The settings file to change instead of Claude Code's own.")
        var settings: String?
        @OptionGroup var output: OutputOptions

        var file: ClaudeSettingsFile {
            ClaudeSettingsFile.resolve(
                explicit: settings.map(Client.absolutePath), environment: ProcessInfo.processInfo.environment,
                homeDirectory: NSHomeDirectory())
        }

        /// Runs `work`, then prints the file's state, or the error.
        func report(_ work: (ClaudeSettingsFile) throws -> String) -> ClaudeHooks.Status {
            let client = Client(json: output.json)
            let file = self.file
            do {
                let message = try work(file)
                let status = try file.status()
                if try file.disablesAllHooks() {
                    FileHandle.standardError.write(
                        Data("warning: \(file.url.path) sets disableAllHooks, so Claude Code runs no hooks.\n".utf8))
                }
                try client.print(.object(["settings": .string(file.url.path), "state": .string(status.rawValue)])) {
                    message
                }
                return status
            } catch let error as WorkspaceError {
                client.fail(ControlError(error))
            } catch {
                client.fail(ControlError(code: "internal", message: "\(error)"))
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add Canopy's hooks, or bring older ones up to date.")

        @OptionGroup var options: Options

        func run() {
            _ = options.report { file in
                try file.install()
                    ? "Added Canopy's hooks to \(file.url.path)."
                    : "Canopy's hooks are already in \(file.url.path)."
            }
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove Canopy's hooks, and only those.")

        @OptionGroup var options: Options

        func run() {
            _ = options.report { file in
                try file.uninstall()
                    ? "Removed Canopy's hooks from \(file.url.path)."
                    : "\(file.url.path) has no Canopy hooks."
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say whether Canopy's hooks are installed. Exits 1 unless they are.")

        @OptionGroup var options: Options

        func run() throws {
            let status = options.report { file in
                switch try file.status() {
                case .installed: "Installed: Canopy's hooks are in \(file.url.path)."
                case .outdated:
                    "Outdated: some of Canopy's hooks in \(file.url.path) are missing or old. Run `canopy hooks install`."
                case .notInstalled: "Not installed: \(file.url.path) has no Canopy hooks. Run `canopy hooks install`."
                }
            }
            if status != .installed { throw ExitCode(1) }
        }
    }
}

/// What Claude Code's hooks run. It never prints, and always exits 0, so it can never disturb Claude.
struct AgentHookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-hook", abstract: "Report Claude Code's state to Canopy, for its hooks.",
        shouldDisplay: false)

    func run() {
        guard isatty(STDIN_FILENO) == 0, let input = try? FileHandle.standardInput.readToEnd(),
            let hook = AgentHook.request(
                input: input, environment: ProcessInfo.processInfo.environment,
                startedAt: ProcessTable.startTime(of: getpid()))
        else { return }
        try? ControlClient(socketPath: hook.socketPath).post(hook.request)
    }
}
```

`Sources/CanopyCLI/CanopyCLI.swift`:

```diff
@@ -10,7 +10,7 @@ struct CanopyCLI: AsyncParsableCommand {
         version: CanopyVersion.current,
         subcommands: [
             Status.self, RepoCommand.self, RowCommand.self, GroupCommand.self, TermCommand.self, PortsCommand.self,
-            PRCommand.self, LogCommand.self, AgentGuide.self,
+            PRCommand.self, LogCommand.self, HooksCommand.self, AgentGuide.self, AgentHookCommand.self,
         ]
     )
 }
```

`Sources/CanopyCLI/Client.swift`:

```diff
@@ -26,9 +26,12 @@ struct Client {
     }
 
     /// Every failure, whether it happens here or in the app, ends in `fail`, so `--json` always prints an error object.
-    func call(_ method: String, _ params: some Encodable, launchIfNeeded: Bool = true) -> JSONValue {
+    /// `waitingUpTo` replaces the method's usual wait for its reply, in seconds.
+    func call(
+        _ method: String, _ params: some Encodable, launchIfNeeded: Bool = true, waitingUpTo: TimeInterval? = nil
+    ) -> JSONValue {
         do {
-            return try send(method, params, launchIfNeeded: launchIfNeeded)
+            return try send(method, params, launchIfNeeded: launchIfNeeded, waitingUpTo: waitingUpTo)
         } catch let error as ControlError {
             fail(error)
         } catch let error as ControlClientError {
@@ -40,9 +43,12 @@ struct Client {
         }
     }
 
-    private func send(_ method: String, _ params: some Encodable, launchIfNeeded: Bool) throws -> JSONValue {
+    private func send(_ method: String, _ params: some Encodable, launchIfNeeded: Bool, waitingUpTo: TimeInterval?)
+        throws -> JSONValue
+    {
         let request = ControlRequest(method: method, params: try .from(params))
-        let client = ControlClient(socketPath: home.socketPath, timeout: ControlMethod.replyTimeout(for: method))
+        let client = ControlClient(
+            socketPath: home.socketPath, timeout: waitingUpTo ?? ControlMethod.replyTimeout(for: method))
         let response: ControlResponse
         do {
             response = try client.send(request)
@@ -140,9 +146,14 @@ enum AppLocator {
         guard let app = appBundle() else {
             throw CLIError("Canopy is not running and Canopy.app was not found. Set CANOPY_APP to its path.")
         }
+        var environment = ["\(CanopyHome.environmentKey)=\(home.root.path)"]
+        // The app offers to install Claude Code's hooks, in the settings of the Claude Code the caller uses.
+        if let claude = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !claude.isEmpty {
+            environment.append("CLAUDE_CONFIG_DIR=\(claude)")
+        }
         let open = Process()
         open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
-        open.arguments = ["-g", "-n", "--env", "\(CanopyHome.environmentKey)=\(home.root.path)", app.path]
+        open.arguments = ["-g", "-n"] + environment.flatMap { ["--env", $0] } + [app.path]
         try open.run()
         open.waitUntilExit()
         guard open.terminationStatus == 0 else {
```

`Sources/CanopyCLI/AgentGuide.swift`:

```diff
@@ -79,6 +79,24 @@ struct AgentGuide: ParsableCommand {
         Send to a program you just started once its prompt shows in `term read`: until it reads keys itself, the
         terminal hands it typed-ahead lines together with their Return.
 
+        ## Agent state
+
+            canopy term state [<id>] <working|waiting|done|none>   report an agent's state, your terminal's by default
+            canopy term wait <id>... [--for done|waiting|any] [--timeout 30m]
+                                                          wait until one of them is done or waiting for its user
+            canopy hooks install | uninstall | status     Claude Code hooks that report Claude's state on their own
+
+        `term list` shows each terminal's agent state: working, waiting, done, or blank. Claude Code reports its own
+        once `canopy hooks install` has added Canopy's hooks to ~/.claude/settings.json. Other agents report with
+        `term state`, for example Codex, from ~/.codex/config.toml:
+
+            notify = ["sh", "-c", "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" term state done", "codex-notify"]
+
+        `term wait` returns at once for a terminal already in the state, unless something was typed or sent into it
+        since then, so `term send ... --enter` followed by `term wait` waits for the next finish. It prints the
+        terminal and its state, such as `p12 done`, and fails with wait_timeout, pane_closed, or agent_stopped.
+        `term state` and `term wait` never start Canopy.
+
         ## Ports
 
             canopy ports [--all]                          what the row's processes listen on, or every row's
@@ -112,6 +130,7 @@ struct AgentGuide: ParsableCommand {
         Start a parallel agent on a fix in its own row, then check on it:
 
             pane=$(canopy row new fix/login-redirect --run 'claude "fix the login redirect, ticket FL-123"' --json | jq -r .pane)
+            canopy term wait "$pane" --timeout 1h
             canopy term read "$pane" --lines 40
 
         Review a pull request in its own row:
```

- [ ] **Step 5: Smoke-test the CLI on a throwaway home**

This shell's own `CANOPY_HOME` and `CANOPY_PANE` point at the release app, so the script clears them first.

```bash
T=$(mktemp -d -t cnp)
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH
export CANOPY_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude" CANOPY_APP=/nonexistent
C=.build/debug/canopy
$C hooks status; echo "exit $?"                     # Not installed, exit 1
$C hooks install --json                             # "state" : "installed"
$C hooks install; $C hooks uninstall; $C hooks uninstall
echo '{"session_id":"a","hook_event_name":"Stop"}' | CANOPY_PANE=p1 $C agent-hook; echo "exit $?"   # 0, silent
$C term state done --json; echo "exit $?"           # missing_target, exit 1
$C term wait p1 --timeout 5x; echo "exit $?"        # validation error, exit 64
echo '{"model":' > "$T/bad.json"; $C hooks install --settings "$T/bad.json"   # settings_invalid, file unchanged
rm -rf "$T"
```

- [ ] **Step 6: Add the e2e steps and run them**

The script now clears the pane variables it inherits and points `CLAUDE_CONFIG_DIR` at its own folder, so neither the release app nor the real settings file can be reached.

`scripts/e2e.sh`:

```diff
@@ -9,6 +9,9 @@ cli="$app/Contents/Resources/bin/canopy"
 shots="$PWD/build/e2e"
 work=$(mktemp -d -t canopy-e2e)
 export CANOPY_HOME="$work/home"
+# Nothing here may reach the Canopy this script runs in, or the Claude Code settings every agent here runs with.
+unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH
+export CLAUDE_CONFIG_DIR="$work/claude"
 mkdir -p "$shots"
 
 app_pid() {
@@ -272,6 +275,71 @@ if "$cli" ports --all --json | grep -q "\"port\" : $port,"; then fail "port $por
 "$cli" term close "$server" >/dev/null
 "$cli" agent-guide | grep -q "canopy ports stop" || fail "agent-guide is missing ports"
 
+step "Claude Code's hooks report into a pane, and agents wait on it"
+agent=$("$cli" term new --repo demo --row feat/term --json |
+    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
+hook() {
+    printf '%s' "$1" | CANOPY_PANE="$agent" "$cli" agent-hook > "$work/hook.out" 2>&1 || fail "agent-hook exited non-zero"
+    [[ ! -s "$work/hook.out" ]] || fail "agent-hook printed something"
+}
+agent_state() {
+    "$cli" term list --repo demo --row feat/term --json | /usr/bin/python3 -c \
+        "import json, sys; print(next(t.get('agent', 'none') for t in json.load(sys.stdin) if t['pane'] == '$agent'))"
+}
+hook '{"session_id": "e2e", "hook_event_name": "SessionStart", "source": "startup"}'
+hook '{"session_id": "e2e", "hook_event_name": "UserPromptSubmit", "prompt": "fix it"}'
+[[ "$(agent_state)" == working ]] || fail "UserPromptSubmit did not make the pane working"
+"$cli" term list --repo demo --row feat/term | grep "^$agent " | grep -q " working " || fail "term list has no AGENT column"
+hook '{"session_id": "nested", "hook_event_name": "Stop", "last_assistant_message": "Done."}'
+[[ "$(agent_state)" == working ]] || fail "another session's report moved the pane"
+"$cli" term wait "$agent" --for done --timeout 30s --json > "$work/wait.json" &
+waiter=$!
+sleep 1
+hook '{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "Fixed it, and the tests pass."}'
+wait "$waiter" || fail "term wait failed"
+grep -q '"state" : "done"' "$work/wait.json" || fail "term wait did not report done"
+hook '{"session_id": "e2e", "hook_event_name": "UserPromptSubmit", "prompt": "and the docs"}'
+hook '{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "Docs updated.\n\nShould I push it?"}'
+[[ "$(agent_state)" == waiting ]] || fail "a turn ending on a question did not make the pane waiting"
+"$cli" term state "$agent" none >/dev/null
+[[ "$(agent_state)" == none ]] || fail "term state none did not clear the pane"
+if "$cli" term wait "$agent" --timeout 1s --json > "$work/timeout.json" 2>/dev/null; then fail "expected a timeout"; fi
+grep -q '"wait_timeout"' "$work/timeout.json" || fail "missing wait_timeout"
+CANOPY_PANE="$agent" "$cli" term state done | grep -qx "$agent done" || fail "term state did not default to CANOPY_PANE"
+"$cli" log --type agent --json > "$work/agent-log.json"
+/usr/bin/python3 - "$work/agent-log.json" "$agent" <<'EOF' || fail "agent events are missing from the log"
+import json, sys
+events = [e for e in json.load(open(sys.argv[1])) if e["data"].get("pane") == sys.argv[2]]
+types = [e["type"] for e in events]
+want = ["agent.working", "agent.done", "agent.working", "agent.waiting", "agent.cleared", "agent.done"]
+if types != want:
+    sys.exit(f"got {types}")
+if any(e["source"] != "cli" for e in events):
+    sys.exit("agent events are not the CLI's")
+EOF
+if "$cli" log --type cli.call --json | grep -q '"term.state"'; then fail "term.state was logged as a CLI call"; fi
+printf '{"session_id": "x", "hook_event_name": "Stop"}' | CANOPY_PANE=p1 CANOPY_HOME="$work/nobody" "$cli" agent-hook ||
+    fail "agent-hook failed while its app was not running"
+[[ ! -e "$work/nobody" ]] || fail "agent-hook started an app"
+printf '{"session_id": "x", "hook_event_name": "Stop"}' | env -u CANOPY_PANE "$cli" agent-hook || fail "agent-hook failed outside Canopy"
+"$cli" term close "$agent" >/dev/null
+"$cli" agent-guide | grep -q "canopy term wait" || fail "agent-guide is missing term wait"
+
+step "canopy hooks adds its hooks to Claude Code's settings and takes only its own out"
+settings="$CLAUDE_CONFIG_DIR/settings.json"
+if "$cli" hooks status >/dev/null; then fail "hooks status succeeded before install"; fi
+mkdir -p "$CLAUDE_CONFIG_DIR"
+printf '{\n  "model": "opus"\n}\n' > "$settings"
+cp "$settings" "$work/settings.before"
+"$cli" hooks install --json | grep -q '"state" : "installed"' || fail "hooks install did not install"
+"$cli" hooks status >/dev/null || fail "hooks status failed after install"
+grep -q 'agent-hook' "$settings" || fail "the settings file has no agent-hook"
+"$cli" hooks uninstall >/dev/null
+cmp -s "$settings" "$work/settings.before" || fail "uninstall did not give back the settings file"
+"$cli" hooks install --settings "$work/other-settings.json" >/dev/null
+grep -q 'agent-hook' "$work/other-settings.json" || fail "hooks install --settings wrote elsewhere"
+"$cli" agent-guide | grep -q "canopy hooks install" || fail "agent-guide is missing canopy hooks"
+
 step "canopy pr says when a repo's origin is not on GitHub"
 if "$cli" pr feat/term --repo demo --json > "$work/pr-local.json" 2>/dev/null; then fail "expected failure"; fi
 grep -q '"not_github"' "$work/pr-local.json" || fail "missing not_github"
```

Run: `make e2e`
Expected: `e2e passed`, with the steps "Claude Code's hooks report into a pane, and agents wait on it" and "canopy hooks adds its hooks to Claude Code's settings and takes only its own out".

- [ ] **Step 7: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: canopy term state, term wait, hooks, and agent-hook"
```

## Task 8: Dots, sounds, and the install offer in the app

**Files:**
- Create: `Sources/CanopyApp/Style/AgentDotView.swift`, `Sources/CanopyApp/Sidebar/AgentSoundPlayer.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/Style/Style.swift`, `Sources/CanopyApp/Terminal/PaneView.swift`, `Sources/CanopyApp/Terminal/TopBarView.swift`, `Sources/CanopyCore/Agents/ClaudeHooks.swift`, `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/State/GlobalConfig.swift`, `Sources/CanopyCore/Terminal/TerminalStore.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `scripts/ui-fixture.sh`
- Test: `Tests/CanopyCoreTests/AgentAppSettingsTests.swift`, `Tests/CanopyCoreTests/PaneTests.swift`

**Interfaces:**
- Consumes: `TerminalStore.viewing`, `onAgentAlert`, `agentDot(inRow:)`, `TerminalTab.agentDot`, `PaneAgent.dot`, `ClaudeSettingsFile`.
- Produces: `GlobalConfig.agentSounds`, `agentDoneSound`, `agentWaitingSound`; `AgentSound.sound(for:in:)` and `fallback(for:)`; `AppState.agentHooksOffered`; `Workspace.agentHooksOffered` and `setAgentHooksOffered()`; `ClaudeHooksOffer.shouldOffer(alreadyOffered:settings:configFolder:)`; `AgentDotView(dot:size:)`; `Style.agentDone` and `Style.agentWaiting`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/AgentAppSettingsTests.swift`, in full:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct AgentAppSettingsTests {
    func config(_ json: String) throws -> GlobalConfig {
        try JSONDecoder().decode(GlobalConfig.self, from: Data(json.utf8))
    }

    @Test func soundsDefaultToGlassAndPing() throws {
        let defaults = try config("{}")
        #expect(AgentSound.sound(for: .done, in: defaults) == "Glass")
        #expect(AgentSound.sound(for: .waiting, in: defaults) == "Ping")
        #expect(AgentSound.sound(for: .working, in: defaults) == nil)
        #expect(AgentSound.sound(for: AgentState.none, in: defaults) == nil)
    }

    @Test func soundsCanBeChangedSilencedOrTurnedOff() throws {
        let chosen = try config(#"{"agentDoneSound": "Hero", "agentWaitingSound": "~/Sounds/ask.aiff"}"#)
        #expect(AgentSound.sound(for: .done, in: chosen) == "Hero")
        #expect(AgentSound.sound(for: .waiting, in: chosen) == "~/Sounds/ask.aiff")

        let silent = try config(#"{"agentWaitingSound": ""}"#)
        #expect(AgentSound.sound(for: .waiting, in: silent) == nil)
        #expect(AgentSound.sound(for: .done, in: silent) == "Glass")

        let off = try config(#"{"agentSounds": false}"#)
        #expect(AgentSound.sound(for: .done, in: off) == nil)
        #expect(AgentSound.sound(for: .waiting, in: off) == nil)

        #expect(AgentSound.fallback(for: .done) == "Glass")
        #expect(AgentSound.fallback(for: .waiting) == "Ping")
    }

    @Test func theOfferIsRememberedInStateJSON() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        var state = AppState()
        #expect(!state.agentHooksOffered)
        state.agentHooksOffered = true
        try store.save(state)
        #expect(store.load().state.agentHooksOffered)

        try #"{"version": 1}"#.write(to: URL(fileURLWithPath: dir.sub("state.json")), atomically: true, encoding: .utf8)
        #expect(!store.load().state.agentHooksOffered)
    }

    @Test func theWorkspaceRecordsTheOffer() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home, git: Fixture.git)
        try await workspace.start()
        #expect(await !workspace.agentHooksOffered)
        try await workspace.setAgentHooksOffered()
        #expect(await workspace.agentHooksOffered)
        #expect(StateStore(url: home.stateFile).load().state.agentHooksOffered)
    }

    @Test func theInstallIsOfferedOnceToClaudeCodeUsers() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("claude"))
        let settings = Fixture.claudeSettings(dir)

        // No Claude Code config folder: Claude Code is not used here.
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: true, settings: settings, configFolder: folder))

        try settings.install()
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))

        try Data("not json".utf8).write(to: settings.url)
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))
    }
}
```

Rows and tabs no longer show a running dot, so their running helpers go, and their test keeps only the pane's.

`Tests/CanopyCoreTests/PaneTests.swift`:

```diff
@@ -77,14 +77,11 @@ struct PaneTests {
         let dir = try TempDir()
         let terminals = Fixture.terminals(dir)
         defer { terminals.closeAll() }
-        let tab = terminals.openTab(for: Fixture.context(dir.path))
-        let pane = tab.focused
+        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused
         #expect(await eventually { pane.foreground?.name == "bash" })
 
         terminals.refreshActivity()
         #expect(!pane.isRunningProgram)
-        #expect(!tab.isRunningProgram)
-        #expect(!terminals.isRunningProgram(inRow: dir.path))
 
         await pane.run("sleep 30")
         #expect(
@@ -92,8 +89,6 @@ struct PaneTests {
                 terminals.refreshActivity()
                 return pane.isRunningProgram
             })
-        #expect(tab.isRunningProgram)
-        #expect(terminals.isRunningProgram(inRow: dir.path))
 
         await pane.type("\u{3}")
         #expect(
@@ -101,7 +96,6 @@ struct PaneTests {
                 terminals.refreshActivity()
                 return !pane.isRunningProgram
             })
-        #expect(!terminals.isRunningProgram(inRow: dir.path))
     }
 
     @Test func aScriptRunsUntilItExitsWithoutWaitingForARefresh() async throws {
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter AgentAppSettingsTests`
Expected: compile errors, `cannot find 'AgentSound' in scope`.

- [ ] **Step 3: Add the settings, the offered flag, and the offer rule**

`Sources/CanopyCore/State/GlobalConfig.swift`:

```diff
@@ -6,16 +6,34 @@ public struct GlobalConfig: Codable, Sendable, Equatable {
     public var minPaneColumns: Int
     /// Whether commands run in zsh terminals go into the activity log. Commands can contain secrets.
     public var logCommands: Bool
+    /// Whether a sound plays when an agent finishes or needs the author.
+    public var agentSounds: Bool
+    /// A system sound's name, such as Glass, or a sound file's path. Empty for silence.
+    public var agentDoneSound: String
+    public var agentWaitingSound: String
 
-    public init(minPaneColumns: Int = 80, logCommands: Bool = true) {
+    public init(
+        minPaneColumns: Int = 80, logCommands: Bool = true, agentSounds: Bool = true,
+        agentDoneSound: String = AgentSound.fallback(for: .done),
+        agentWaitingSound: String = AgentSound.fallback(for: .waiting)
+    ) {
         self.minPaneColumns = minPaneColumns
         self.logCommands = logCommands
+        self.agentSounds = agentSounds
+        self.agentDoneSound = agentDoneSound
+        self.agentWaitingSound = agentWaitingSound
     }
 
     public init(from decoder: any Decoder) throws {
         let container = try decoder.container(keyedBy: CodingKeys.self)
         minPaneColumns = max(try container.decodeIfPresent(Int.self, forKey: .minPaneColumns) ?? 80, 20)
         logCommands = try container.decodeIfPresent(Bool.self, forKey: .logCommands) ?? true
+        agentSounds = try container.decodeIfPresent(Bool.self, forKey: .agentSounds) ?? true
+        agentDoneSound =
+            try container.decodeIfPresent(String.self, forKey: .agentDoneSound) ?? AgentSound.fallback(for: .done)
+        agentWaitingSound =
+            try container.decodeIfPresent(String.self, forKey: .agentWaitingSound)
+            ?? AgentSound.fallback(for: .waiting)
     }
 
     public static func load(from url: URL) -> GlobalConfig {
@@ -25,3 +43,23 @@ public struct GlobalConfig: Codable, Sendable, Equatable {
         return config
     }
 }
+
+/// The sound that plays when a pane's agent becomes done or waiting.
+public enum AgentSound {
+    /// A system sound's name or a file's path, or nil for no sound.
+    public static func sound(for state: AgentState, in config: GlobalConfig) -> String? {
+        guard config.agentSounds else { return nil }
+        let sound =
+            switch state {
+            case .done: config.agentDoneSound
+            case .waiting: config.agentWaitingSound
+            case .working, .none: ""
+            }
+        return sound.isEmpty ? nil : sound
+    }
+
+    /// What plays by default, and in place of a sound that cannot be found.
+    public static func fallback(for state: AgentState) -> String {
+        state == .waiting ? "Ping" : "Glass"
+    }
+}
```

`Sources/CanopyCore/State/AppState.swift`:

```diff
@@ -69,6 +69,8 @@ public struct AppState: Codable, Sendable, Equatable {
     /// The next pane number, so a pane ID an agent kept never names a different terminal after a relaunch.
     public var nextPane = 1
     public var portsCollapsed = false
+    /// Whether Canopy has offered to install its Claude Code hooks, which it does once.
+    public var agentHooksOffered = false
 
     public init(
         version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil,
@@ -88,6 +90,7 @@ public struct AppState: Codable, Sendable, Equatable {
         // Layouts that cannot be read are dropped on their own, so repos and rows still load.
         nextPane = try container.decodeIfPresent(Int.self, forKey: .nextPane) ?? 1
         portsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .portsCollapsed) ?? false
+        agentHooksOffered = try container.decodeIfPresent(Bool.self, forKey: .agentHooksOffered) ?? false
         terminals = (try? container.decodeIfPresent([String: SavedRowTerminals].self, forKey: .terminals)) ?? [:]
     }
 }
```

`Sources/CanopyCore/Workspace/Workspace.swift`:

```diff
@@ -258,6 +258,16 @@ public actor Workspace {
         try save()
     }
 
+    public var agentHooksOffered: Bool {
+        state.agentHooksOffered
+    }
+
+    public func setAgentHooksOffered() throws {
+        guard !state.agentHooksOffered else { return }
+        state.agentHooksOffered = true
+        try save()
+    }
+
     public func setSelectedRow(path: String?) throws {
         guard state.selectedRowPath != path else { return }
         state.selectedRowPath = path
```

`Sources/CanopyCore/Agents/ClaudeHooks.swift`:

```diff
@@ -292,3 +292,14 @@ public struct ClaudeSettingsFile: Sendable {
         }
     }
 }
+
+/// Whether Canopy offers to install its hooks on launch: once, to people who use Claude Code, while the hooks are not
+/// installed and the settings can be read.
+public enum ClaudeHooksOffer {
+    public static func shouldOffer(alreadyOffered: Bool, settings: ClaudeSettingsFile, configFolder: URL) -> Bool {
+        guard !alreadyOffered, FileManager.default.fileExists(atPath: configFolder.path),
+            let status = try? settings.status()
+        else { return false }
+        return status != .installed
+    }
+}
```

`Sources/CanopyCore/Terminal/TerminalStore.swift`:

```diff
@@ -24,11 +24,6 @@ public final class TerminalTab: Identifiable {
         layout.leaves.compactMap { panes[$0] }
     }
 
-    /// Whether any of its panes was running a program at the last activity refresh.
-    public var isRunningProgram: Bool {
-        paneList.contains(where: \.isRunningProgram)
-    }
-
     /// The pane `⌘W` closes and typing goes to.
     public var focused: Pane {
         panes[focusedPaneID] ?? paneList[0]
@@ -114,11 +109,6 @@ public final class TerminalStore {
         }
     }
 
-    /// Whether any of the row's panes was running a program at the last activity refresh.
-    public func isRunningProgram(inRow path: String) -> Bool {
-        tabs(inRow: path).contains(where: \.isRunningProgram)
-    }
-
     // MARK: Tabs
 
     /// Opens a tab with one pane at the end of the row's tab bar and selects it.
```

- [ ] **Step 4: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "AgentAppSettingsTests|StateStoreTests|ActivityLogTests|PaneTests"`
Expected: all pass.

- [ ] **Step 5: Draw the dots**

The working pulse is a `CABasicAnimation` on a layer.
A SwiftUI `PhaseAnimator` pulse redrew the window every frame and kept the dev app at about 9% CPU with four agents working, where the layer measured 0.3 to 0.5%, the same as idle.

`Sources/CanopyApp/Style/AgentDotView.swift`, in full:

```swift
import AppKit
import CanopyCore
import SwiftUI

/// What a pane's agent is doing: the accent color pulsing while it works, yellow while it waits for the author, and
/// green once it is done, until the author sees it.
struct AgentDotView: View {
    let dot: AgentDot
    var size = 6.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dot == .working && !reduceMotion {
                PulsingDot(size: size)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color.opacity(0.22)).padding(-Self.halo))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(dot.label)
    }

    /// How far the soft ring reaches past the dot.
    static let halo = 2.5

    private var color: Color {
        switch dot {
        case .working: .accentColor
        case .waiting: Style.agentWaiting
        case .done: Style.agentDone
        }
    }
}

extension AgentDot {
    var label: String {
        switch self {
        case .working: "Agent working"
        case .waiting: "Agent waiting for you"
        case .done: "Agent done"
        }
    }
}

/// The working dot. Core Animation runs the pulse outside the app, where a SwiftUI animation would redraw the
/// window every frame for as long as an agent works.
private struct PulsingDot: NSViewRepresentable {
    let size: Double

    func makeNSView(context: Context) -> PulsingDotView {
        PulsingDotView(size: size)
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {}
}

private final class PulsingDotView: NSView {
    private let dot = CALayer()
    private let ring = CALayer()
    private let size: Double

    init(size: Double) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        let halo = AgentDotView.halo
        ring.frame = CGRect(x: -halo, y: -halo, width: size + 2 * halo, height: size + 2 * halo)
        ring.cornerRadius = ring.frame.width / 2
        dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        // A new accent color in System Settings.
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    @objc private func systemColorsChanged() {
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override var wantsUpdateLayer: Bool { true }

    /// Resolves the accent color for the current appearance, which a CGColor cannot follow by itself.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.controlAccentColor.cgColor
            ring.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        }
    }

    /// Core Animation drops a layer's animations when its view leaves the window, so each arrival starts the pulse.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
```

`Sources/CanopyApp/Style/Style.swift`:

```diff
@@ -43,6 +43,11 @@ enum Style {
     static let badgeFill = Color.adaptive(
         light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.075))
 
+    /// An agent that finished. The system's green, which sits apart from GitHub's open-PR green in the same row.
+    static let agentDone = Color(nsColor: .systemGreen)
+    /// An agent waiting for the author. The system's yellow, darkened in light mode to hold up on white.
+    static let agentWaiting = Color.adaptive(light: 0xD49A00, dark: 0xFFD60A)
+
     /// The hues a repo's tile can take, indexed by `RepoMark.hue`.
     static let tileHues: [Color] = [
         .adaptive(light: 0x5257D6, dark: 0x8B8FF8),
@@ -159,7 +164,7 @@ struct IconMenu<Items: View>: View {
     }
 }
 
-/// The accent dot that marks a program running in a row, tab, or pane.
+/// The accent dot that marks a program running in a pane.
 struct RunningDot: View {
     var size = 6.0
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```diff
@@ -283,7 +283,7 @@ struct RowLineView: View {
     @State private var isConfirmingRemove = false
     @State private var isNamingGroup = false
 
-    private var isRunning: Bool { model.terminals.isRunningProgram(inRow: row.path) }
+    private var agentDot: AgentDot? { model.terminals.agentDot(inRow: row.path) }
 
     /// Hover stops updating during a drag, so the row being dragged drops its hover look itself.
     private var isDragged: Bool { model.isDraggingRowOverList && model.draggedRow?.path == row.path }
@@ -304,8 +304,8 @@ struct RowLineView: View {
                 TagView(text: "missing")
             }
             Spacer(minLength: 4)
-            if isRunning {
-                RunningDot()
+            if let agentDot {
+                AgentDotView(dot: agentDot)
             }
             if let pr = row.pullRequest {
                 PullRequestNumber(pr: pr)
@@ -370,7 +370,7 @@ struct RowLineView: View {
         if let group = row.group { parts.append("in \(group)") }
         if let tag = row.externalTag { parts.append("from \(tag.label)") }
         if let pr = row.pullRequest { parts.append("pull request \(pr.number), \(pr.state.label)") }
-        if isRunning { parts.append("running a program") }
+        if let agentDot { parts.append(agentDot.label.lowercased()) }
         if row.isMissing { parts.append("missing") }
         return parts.joined(separator: ", ")
     }
```

`Sources/CanopyApp/Terminal/TopBarView.swift`:

```diff
@@ -148,7 +148,7 @@ struct TabItemView: View {
                 Text(tab.name)
                     .lineLimit(1)
             }
-            // The close button and the running dot share a slot, so hovering does not shift the tab.
+            // The close button and the agent dot share a slot, so hovering does not shift the tab.
             ZStack {
                 if isHovering {
                     Button(action: onClose) {
@@ -160,8 +160,8 @@ struct TabItemView: View {
                     .buttonStyle(.plain)
                     .foregroundStyle(.secondary)
                     .help("Close Tab")
-                } else if tab.isRunningProgram {
-                    RunningDot(size: 5)
+                } else if let dot = tab.agentDot {
+                    AgentDotView(dot: dot, size: 5)
                 }
             }
             .frame(width: 14, height: 14)
```

`Sources/CanopyApp/Terminal/PaneView.swift`:

```diff
@@ -93,7 +93,7 @@ struct PaneHeader: View {
     }
 }
 
-/// What a pane is doing: an idle shell, a running program, or an exit, with its code.
+/// What a pane is doing: its agent's state, an idle shell, a running program, or an exit, with its code.
 struct PaneStatusMark: View {
     let pane: Pane
     var size = 11.0
@@ -105,6 +105,8 @@ struct PaneStatusMark: View {
                 .font(.system(size: size))
                 .foregroundStyle(code == 0 ? .green : .red)
                 .accessibilityLabel(code == 0 ? "Exited" : "Exited with code \(code)")
+        case .running where pane.agent.dot != nil:
+            AgentDotView(dot: pane.agent.dot ?? .working)
         case .running where pane.isRunningProgram:
             RunningDot()
         case .running:
```

- [ ] **Step 6: Keep `viewing` current, play the sounds, and offer the install**

`Sources/CanopyApp/Sidebar/AgentSoundPlayer.swift`, in full:

```swift
import AppKit

/// Plays the sounds for agents finishing and waiting. A sound already playing is not started again, so several
/// agents finishing together play it once.
@MainActor
final class AgentSoundPlayer {
    private var sounds: [String: NSSound] = [:]

    /// `sound` is a system sound's name, such as Glass, or a sound file's path. One that cannot be found plays
    /// `fallback` instead.
    func play(_ sound: String, fallback: String) {
        guard let player = load(sound) ?? load(fallback), !player.isPlaying else { return }
        player.play()
    }

    private func load(_ sound: String) -> NSSound? {
        if let cached = sounds[sound] { return cached }
        let player =
            sound.contains("/")
            ? NSSound(contentsOfFile: (sound as NSString).expandingTildeInPath, byReference: true)
            : NSSound(named: NSSound.Name(sound))
        sounds[sound] = player
        return player
    }
}
```

`Sources/CanopyApp/AppModel.swift`:

```diff
@@ -18,6 +18,7 @@ final class AppModel {
             guard selectedRowPath != oldValue else { return }
             sidebarKeepsKeyboard = isSteppingRows
             selectionChanged()
+            updateViewing()
         }
     }
     /// True after ↑ or ↓ in the sidebar picked the row, so its terminal does not take the keyboard from the sidebar.
@@ -85,6 +86,8 @@ final class AppModel {
         }
         await startControlServer()
         startRefreshingWhileVisible()
+        startWatchingAgents()
+        await offerHooksIfNeeded()
     }
 
     func shutdown() {
@@ -365,6 +368,67 @@ final class AppModel {
         return Set(others.map(\.port)).sorted()
     }
 
+    // MARK: Agents
+
+    @ObservationIgnored private var activationObservers: [any NSObjectProtocol] = []
+    @ObservationIgnored private let sounds = AgentSoundPlayer()
+
+    /// Keeps the terminals told what the author has in front of them, and plays a sound when an agent finishes or
+    /// needs the author anywhere else.
+    private func startWatchingAgents() {
+        terminals.onAgentAlert = { [weak self] _, state in self?.playSound(for: state) }
+        let names = [
+            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
+            NSApplication.didChangeOcclusionStateNotification,
+        ]
+        activationObservers = names.map { name in
+            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
+                MainActor.assumeIsolated { self?.updateViewing() }
+            }
+        }
+        updateViewing()
+    }
+
+    private func updateViewing() {
+        let viewing = AgentViewing(
+            rowPath: selectedRowPath, isFrontmost: NSApp.isActive && NSApp.occlusionState.contains(.visible))
+        if terminals.viewing != viewing {
+            terminals.viewing = viewing
+        }
+    }
+
+    /// Reads config.json each time, so a changed sound applies without relaunching.
+    private func playSound(for state: AgentState) {
+        guard let sound = AgentSound.sound(for: state, in: GlobalConfig.load(from: home.configFile)) else { return }
+        sounds.play(sound, fallback: AgentSound.fallback(for: state))
+    }
+
+    /// The Claude Code settings file the launch offer would write, while the offer is on screen.
+    var hooksOffer: ClaudeSettingsFile?
+
+    /// Offers once per home to install Canopy's Claude Code hooks, to people who use Claude Code.
+    private func offerHooksIfNeeded() async {
+        let environment = ProcessInfo.processInfo.environment
+        let settings = ClaudeSettingsFile.resolve(
+            explicit: nil, environment: environment, homeDirectory: NSHomeDirectory())
+        let folder = ClaudeSettingsFile.configFolder(environment: environment, homeDirectory: NSHomeDirectory())
+        let offered = await workspace.agentHooksOffered
+        guard ClaudeHooksOffer.shouldOffer(alreadyOffered: offered, settings: settings, configFolder: folder) else {
+            return
+        }
+        hooksOffer = settings
+        perform { try await $0.setAgentHooksOffered() }
+    }
+
+    func installHooks(into settings: ClaudeSettingsFile) {
+        hooksOffer = nil
+        do {
+            try settings.install()
+        } catch {
+            show(error)
+        }
+    }
+
     // MARK: Terminals
 
     func context(for row: Row) -> PaneContext {
```

`Sources/CanopyApp/RootView.swift`:

```diff
@@ -55,6 +55,18 @@ struct RootView: View {
         } message: { pending in
             Text(pending.message)
         }
+        .alert(
+            "Show when Claude Code finishes?",
+            isPresented: Binding(get: { model.hooksOffer != nil }, set: { if !$0 { model.hooksOffer = nil } }),
+            presenting: model.hooksOffer
+        ) { settings in
+            Button("Add Hooks") { model.installHooks(into: settings) }
+            Button("Not Now", role: .cancel) {}
+        } message: { settings in
+            Text(
+                "Canopy can add hooks to \((settings.url.path as NSString).abbreviatingWithTildeInPath) so it knows when Claude Code in its terminals is working, done, or waiting for you. Your other hooks stay as they are, and `canopy hooks uninstall` takes Canopy's out."
+            )
+        }
         .alert(
             "Remove \(model.pendingRepoRemoval?.repo.name ?? "") from Canopy?",
             isPresented: Binding(
```

- [ ] **Step 7: Put agents in the UI fixture**

`scripts/ui-fixture.sh`:

```diff
@@ -1,7 +1,7 @@
 #!/usr/bin/env bash
 # Opens the dev build on a throwaway home that has something in every part of the window, for UI checks and shots:
 # three repos, rows with open, draft, merged, and closed PRs, two groups, other worktrees, running programs,
-# listening ports, and a split tab. Nothing outside the throwaway folder is touched.
+# listening ports, a split tab, and agents in every state. Nothing outside the throwaway folder is touched.
 #
 #   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
 #   scripts/ui-fixture.sh stop           quit it and delete its folder
@@ -10,6 +10,8 @@
 # a fixture ZDOTDIR. It clones acme/billing and acme/design-system from local bare repos in $work/remotes, and fails
 # like gh for any other repo. Writing "logged-out" to $work/bin/gh-mode makes it answer like a gh with no login, and
 # writing a number of seconds to $work/bin/clone-seconds makes clones show git's progress for that long.
+#
+# UI_FIXTURE_HOOKS_OFFER=1 gives it a Claude Code config folder of its own, so it offers to install its hooks.
 set -euo pipefail
 cd "$(dirname "$0")/.."
 app="$PWD/build/Canopy Dev.app"
@@ -38,6 +40,10 @@ fi
 # The socket path must stay under 104 bytes, so the home goes in a short temporary folder.
 work=$(mktemp -d -t cnp)
 export CANOPY_HOME="$work/home"
+# The app offers to install Claude Code's hooks, and must only ever find the fixture's settings.
+export CLAUDE_CONFIG_DIR="$work/claude"
+unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH
+if [[ "${UI_FIXTURE_HOOKS_OFFER:-}" == 1 ]]; then mkdir -p "$CLAUDE_CONFIG_DIR"; fi
 
 mkdir -p "$work/bin" "$work/zdot"
 cat > "$work/bin/gh" <<'GH'
@@ -159,8 +165,21 @@ first=$("$cli" term list --all --json | /usr/bin/python3 -c \
 "$cli" term new "${row[@]}" --tab "Terminal 2" --run "$plain" >/dev/null
 "$cli" term new --repo web-app --row feat/onboarding-flow --run "$plain; sleep 600" >/dev/null
 "$cli" term new --repo api-server --row feat/rate-limits --run "$plain; python3 -m http.server 8080" >/dev/null
+"$cli" term new --repo web-app --row fix/login-redirect --run "$plain" >/dev/null
 "$cli" row select feat/checkout-redesign --repo web-app >/dev/null
 
+# Agents in every state, reported the way agents without Claude Code's hooks report them.
+pane_in() {
+    "$cli" term list --all --json | /usr/bin/python3 -c \
+        'import json, sys; print([t["pane"] for t in json.load(sys.stdin) if t["row"] == sys.argv[1] and t["tab"] == sys.argv[2]][0])' \
+        "$1" "$2"
+}
+"$cli" term state "$first" working >/dev/null
+"$cli" term state "$(pane_in feat/checkout-redesign agent)" done >/dev/null
+"$cli" term state "$(pane_in feat/onboarding-flow Terminal)" working >/dev/null
+"$cli" term state "$(pane_in fix/login-redirect Terminal)" waiting >/dev/null
+"$cli" term state "$(pane_in feat/rate-limits Terminal)" working >/dev/null
+
 # shellcheck source=/dev/null
 source "$state"
 echo "pid $pid, CANOPY_HOME=$CANOPY_HOME"
```

- [ ] **Step 8: Build and commit**

Run: `swift build 2>&1 | grep -cE "warning:|error:"`
Expected: `0`.

```bash
make format && make lint
git add -A && git commit -m "feat: agent dots in the sidebar, tabs, and panes, with sounds and the hooks offer"
```

## Task 9: A collapsed group's dot

Row groups (PR 18) merged first, so this PR adds the collapsed group header's dot, as the spec says.

**Files:**
- Modify: `Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`, `Sources/CanopyApp/Sidebar/GroupViews.swift`, `scripts/ui-fixture.sh`
- Test: `Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`

**Interfaces:**
- Consumes: `TerminalStore.agentDot(inRow:)`, `RepoSnapshot.rows(inGroup:)`.
- Produces: `TerminalStore.agentDot(inRows:) -> AgentDot?`.

- [ ] **Step 1: Write the failing test**

`Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`:

```diff
@@ -104,6 +104,20 @@ struct TerminalStoreAgentTests {
         #expect(rows.firstTab.agentDot == .working)
     }
 
+    @Test func aGroupShowsTheMostUrgentDotOfItsRows() throws {
+        let dir = try TempDir()
+        let rows = try Rows(dir)
+        defer { rows.terminals.closeAll() }
+
+        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == nil)
+        rows.otherRow.report(AgentReport(state: .working))
+        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == .working)
+        rows.otherTab.report(AgentReport(state: .done))
+        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == .done)
+        #expect(rows.terminals.agentDot(inRows: [rows.b]) == .working)
+        #expect(rows.terminals.agentDot(inRows: []) == nil)
+    }
+
     @Test func aWaitReturnsAtOnceForAFreshState() async throws {
         let dir = try TempDir()
         let rows = try Rows(dir)
```

- [ ] **Step 2: Run it to see it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter aGroupShows`
Expected: `incorrect argument label in call (have 'inRows:', expected 'inRow:')`.

- [ ] **Step 3: Add the dot**

`Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`:

```diff
@@ -52,6 +52,11 @@ extension TerminalStore {
         tabs(inRow: path).compactMap(\.agentDot).max()
     }
 
+    /// The most urgent dot among several rows' panes, for a collapsed group.
+    public func agentDot(inRows paths: [String]) -> AgentDot? {
+        paths.compactMap(agentDot(inRow:)).max()
+    }
+
     /// Whether the author sees the pane: Canopy is frontmost, and the pane is in the selected row's selected tab.
     public func isOnScreen(_ pane: Pane) -> Bool {
         guard viewing.isFrontmost, let (path, tab) = tab(containing: pane.id), path == viewing.rowPath else {
```

`Sources/CanopyApp/Sidebar/GroupViews.swift`:

```diff
@@ -14,6 +14,12 @@ struct GroupHeaderView: View {
     @State private var isRenaming = false
     @State private var isConfirmingDelete = false
 
+    /// A collapsed group shows the most urgent agent dot among the rows it hides.
+    private var agentDot: AgentDot? {
+        guard group.collapsed else { return nil }
+        return model.terminals.agentDot(inRows: repo.rows(inGroup: group.name).map(\.path))
+    }
+
     /// A collapsed group shows the selection for the row it hides, so the sidebar always says where the window is.
     private var holdsSelection: Bool {
         group.collapsed && model.selectedRow.map { $0.repoPath == repo.path && $0.group == group.name } == true
@@ -33,6 +39,9 @@ struct GroupHeaderView: View {
                 .lineLimit(1)
                 .truncationMode(.tail)
             Spacer(minLength: 4)
+            if let agentDot {
+                AgentDotView(dot: agentDot)
+            }
             if isHovering || isRenaming || isConfirmingDelete {
                 IconMenu(title: "More for \(group.name)", systemImage: "ellipsis") {
                     GroupMenuItems(rename: { isRenaming = true }, delete: requestDelete)
@@ -68,7 +77,10 @@ struct GroupHeaderView: View {
             }
         }
         .accessibilityElement(children: .combine)
-        .accessibilityLabel("\(group.name), group, \(count == 1 ? "1 row" : "\(count) rows")")
+        .accessibilityLabel(
+            "\(group.name), group, \(count == 1 ? "1 row" : "\(count) rows")"
+                + (agentDot.map { ", \($0.label.lowercased())" } ?? "")
+        )
         .accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
         .accessibilityAddTraits(.isButton)
         .accessibilityAction { toggle() }
```

No command folds a group, so the fixture gives the Later group's row a done agent and the UI check folds it with a click.

`scripts/ui-fixture.sh`:

```diff
@@ -166,6 +166,7 @@ first=$("$cli" term list --all --json | /usr/bin/python3 -c \
 "$cli" term new --repo web-app --row feat/onboarding-flow --run "$plain; sleep 600" >/dev/null
 "$cli" term new --repo api-server --row feat/rate-limits --run "$plain; python3 -m http.server 8080" >/dev/null
 "$cli" term new --repo web-app --row fix/login-redirect --run "$plain" >/dev/null
+"$cli" term new --repo web-app --row chore/bump-deps --run "$plain" >/dev/null
 "$cli" row select feat/checkout-redesign --repo web-app >/dev/null
 
 # Agents in every state, reported the way agents without Claude Code's hooks report them.
@@ -179,6 +180,8 @@ pane_in() {
 "$cli" term state "$(pane_in feat/onboarding-flow Terminal)" working >/dev/null
 "$cli" term state "$(pane_in fix/login-redirect Terminal)" waiting >/dev/null
 "$cli" term state "$(pane_in feat/rate-limits Terminal)" working >/dev/null
+# Folding the Later group, which no command does, shows its done dot on the group's header.
+"$cli" term state "$(pane_in chore/bump-deps Terminal)" done >/dev/null
 
 # shellcheck source=/dev/null
 source "$state"
```

- [ ] **Step 4: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter TerminalStoreAgentTests`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
make format && make lint
git add -A && git commit -m "feat: a collapsed group's header shows its rows' agent dot"
```

## Checks

### Every commit on its own

Each commit was checked out alone and run through `make lint`, `swift build`, and the whole test suite.

| Commit | Lint | Warnings | Tests |
|---|---|---|---|
| docs: agent state design | clean | 0 | 432, one `ControlServerTests` flake from `main` (see After Review) |
| feat: agent states and the rules that change a pane's | clean | 0 | 447 pass |
| feat: panes keep their agent's state, from reports, keys, and exits | clean | 0 | 452 pass |
| feat: the seen rule, alerts, dots, and waits for agent states | clean | 0 | 460 pass |
| feat: term.state and term.wait, and the agent field in term.list | clean | 0 | 463 pass |
| feat: map Claude Code hooks to agent reports, and post them to the app | clean | 0 | 473 pass |
| feat: install and remove Canopy's hooks in Claude Code's settings | clean | 0 | 483 pass |
| feat: canopy term state, term wait, hooks, and agent-hook | clean | 0 | 485 pass |
| feat: agent dots in the sidebar, tabs, and panes, with sounds and the hooks offer | clean | 0 | 490 pass |
| feat: a collapsed group's header shows its rows' agent dot | clean | 0 | 491, the same flake once, then 2 clean runs |

### UI

`make app`, then `scripts/ui-fixture.sh dark` and `scripts/ui-fixture.sh light`, with window shots by `scripts/window-shot.swift`.
The fixture puts a done agent in the `agent` tab of `feat/checkout-redesign` (open PR #145), a working one in its first pane, waiting ones in `fix/login-redirect` (merged #139), working ones in `feat/onboarding-flow` (draft #142) and `feat/rate-limits`, and a done one in `chore/bump-deps` in the Later group.

- The green dot on `feat/checkout-redesign` sits beside the open PR's green `#145`, in its own slot, round with a halo, apart from the line glyph and the text, in both appearances.
  In light mode the system green is also clearly brighter than GitHub's darker open green.
- The yellow, darkened in light mode, holds up on the white sidebar.
- The tab bar shows the working pulse on `Terminal` and green on `agent`, and the pane header shows the pulse on the working pane.
- Clicking the `agent` tab with the app frontmost clears the green from the tab and the row, and the row falls back to the working dot of its other tab.
- Selecting `fix/login-redirect` shows yellow on the row, the tab, and the pane header, and it stays while the author looks.
- Pressing Escape in that waiting pane clears it, logged as `agent.cleared` with `via: key`.
- Folding the Later group with a click shows its row's green dot on the group header, beside the count, and beside `…` and `+` on hover.
- With `UI_FIXTURE_HOOKS_OFFER=1`, the install offer appears once, `state.json` records it, and Add Hooks writes the fixture's own settings file; the real `~/.claude/settings.json` kept its modification time.
- CPU of the dev app with four working dots on screen: about 9% with a SwiftUI pulse, 0.3 to 0.5% with the layer pulse, and 0.3% with none.

### Real Claude Code

Claude Code 2.1.283 ran in a pane of the dev fixture as `claude --settings "$work/claude/settings.json"`, with the fixture's own `CANOPY_HOME` and `CANOPY_CLI`, driven by `canopy term send`, on Haiku to keep it cheap.

| Step | States, from `canopy log --type agent` |
|---|---|
| a prompt | working (`UserPromptSubmit`), then done (`Stop`); `term wait` printed `p10 done` |
| `/model haiku` | no change, so local commands do not leave a pane working |
| a turn ending on "Is it raining where you are?" | waiting (`Stop`); typing a draft left it waiting, and Return with the answer went working, then done |
| a Bash command needing permission | waiting (`PermissionRequest`), working on Return (`key`), then done |
| `AskUserQuestion` | waiting (`PreToolUse`), working on Return, then done |
| Escape while it wrote | cleared (`key`), and no late hook put it back |
| `/clear`, then a prompt | the new session took the pane, and its turn went working, then done |
| `/exit` | cleared (`SessionEnd`) |
| `claude -p` | working, done, then cleared, so the inline `Stop` arrived before it exited |

Text and Return sent in one `term send --enter` land in Claude Code as a paste: a 31-character prompt was submitted, and a 120-character one sat in the input box.
The steps sent the text and then Return on its own.
The `fix/term-send-enter` row fixes `term send` itself, so this PR leaves it alone.

## After Review

An independent Opus reviewer read `git diff origin/main...HEAD` with the spec and this plan.
It found nothing high severity.
The fixes are in `fix: review findings for agent state`, each with a test.

1. **Terminal reports counted as typed input** (medium).
   Focus changes, mouse reports, and replies to terminal queries reach `Pane.input` like keys, so clicking into a finished pane made its done stale and a later `term wait` blocked.
   Fixed: `PaneAgent.isTerminalReport` leaves them out, and only keys and `term send` text move the input time.
   Tests: `whatTheTerminalSendsOnItsOwnIsNotAKey`, `focusAndMouseReportsDoNotMakeAStateStale`.
2. **Every keystroke redrew the dots** (low to medium).
   The input time lived in the observed `agent`.
   Fixed: it is `Pane.lastInput`, outside observation, and `Pane.agentIsFresh` reads it.
3. **A `term wait` whose client went away kept waiting** (medium).
   Fixed in part: the wait now ends with `CancellationError` when its task is cancelled, and the timeout is capped at a year.
   Not changed: the control server does not cancel a request when its client closes, because it cannot tell a killed client from one that half-closed and still wants the reply, which `halfClosedConnectionsStillGetTheirReply` relies on.
   An abandoned wait therefore holds one observer and one sleeping task until its timeout.
   Test: `aCancelledWaitEndsAndStopsWatching`.
4. **`agent_completed` meant done** (medium).
   It reports a background session finishing, so it could turn a pane green, with Glass, while its own agent waited on a prompt.
   Fixed: it maps to nothing, the hook matcher leaves it out, and the spec says why.
   Test: `otherNotificationsAndEventsMapToNothing`.
5. **One odd field dropped a whole hook event** (low).
   A `Stop` whose `background_tasks` changed shape would leave a pane working.
   Fixed: only `hook_event_name` must decode, and other fields read as missing when they do not fit.
   Test: `aFieldThatChangedShapeReadsAsMissing`.
6. **A huge timeout crashed the app** (low).
   `Int64(timeout * 1000)` trapped past 9.2e15 seconds from a raw socket client.
   Fixed with the one-year cap; test in `agentRequestsFailWithCodes`.
7. **An exit nobody saw kept its dot** (low).
   The state clears on the busy-to-idle edge, which no refresh sees while the window is hidden.
   Fixed: a report that arrives while a program runs sets the baseline at once.
   Test: `anExitWhileNoRefreshRanStillClearsTheState`.
8. **A repeated key in the settings file** (low).
   `OrderedJSON` read the first, where `JSON.parse` reads the last.
   Fixed; test `aRepeatedKeyIsReadAsItsLastOne`.
   Not changed: `status` compares handlers with their key order, so a file rewritten with sorted keys shows as outdated until the next install fixes it; and the rename keeps permissions but not extended attributes, ACLs, or hard links.
9. **Spec and code disagreed** (low).
   The spec now lists `term.state`'s `question`, `takesOver`, and `releases`, says keys sent with `term send` log `cli`, says every `hooks` command warns about `disableAllHooks`, and adds a risk: the author's own `PermissionRequest` or `Stop` hooks can change what Claude Code does after Canopy's hook reported.
10. **`term send --enter` was no longer atomic** (low).
    It no longer applies: the `term send` fix left this branch, since the `fix/term-send-enter` row fixes it more fully, with bracketed paste.

The whole suite then passed, 497 of 497.

**A flake from `main`.**
`ControlServerTests` fails about once in five full runs with "Canopy closed the connection before replying", in tests from `main` such as `repoCloneAnswersLikeRepoAddAndIsLogged` and in this branch's `agentRequestsFailWithCodes`.
With logging added, the client's `read` got EBADF (errno 9) on its socket, fd 448, during a `repo.clone` call, and the server logged no receive error.
So something in the test process closes the client's descriptor number while the client still uses it.
Nothing in `Sources` or the tests closes a descriptor twice: `Subprocess`, `InstanceLock`, `ActivityLog`, the pty's cancel handler, and the tests' own sockets each close once.
PR 10's spy interposed `close` only, and so would miss `close$NOCANCEL` and guarded closes inside system libraries.
The `fix/control-socket-flake` row is working on it, so this PR leaves it there.

**CI.**
The first CI run failed two of this branch's tests on the 3-CPU runner.
`postingWaitsAtMostASecondForTheApp` expected a reply within a second, and the two exit tests raced a `sleep 2` that the runner's slow shell could finish before a refresh saw it.
`test: hold the agent tests on a slow CI runner` ends `cat` with Control-D instead, and bounds only what the slow app does.
Both pass under `taskpolicy -b` with 14 `yes` hogs, and CI `check` passed after.

**Rebased onto #22.**
`term send --enter` now goes through `Pane.type(_:enter:) async`, which writes Return on its own after the text.
The pane reports the text to the key rules first, then Return once it is written, so a prompt that `term send <pane> 1 --enter` answers goes working on Return, and an answer typed at the agent's own input line still waits for the next prompt's hook.
Test: `returnFromTermSendAnswersAPromptOnceItIsIn`.
The per-commit checks above ran before this rebase; since then only the final commit was checked.

**Follow-up: a hook that closes before the reply can lose its request.**
Under load the app's `NWConnection` can fail with ENETDOWN before it reads a request from a client that already closed, and the request is lost.
`canopy agent-hook` waits up to a second for the reply, which narrows the window but does not close it: when the app takes longer than a second, a report can still be lost.
The fix belongs in the control server, which should read and handle whatever a client sent before it closed, and is left for its own PR.
