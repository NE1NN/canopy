# Background Agent State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pane whose agent ended its turn while background work it started still runs shows a new background state, a slowly pulsing green ring, instead of done.

**Architecture:** `ClaudeHookMapping` maps a `Stop` with running shell or monitor tasks to a new `AgentState.background`, carrying each task's label in `AgentReport.backgroundTasks`.
`PaneAgent` keeps the labels while the pane is background, and everything that already reads the state (dots, sounds, `term list`, `term wait`, the activity log) learns the new case.
The app draws the ring with Core Animation, like the working dot, and every dot gains a tooltip naming its state.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI with AppKit layers, the `canopy` CLI (swift-argument-parser).

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-agent-state-design.md`, updated in this PR (States, Hook mapping, Sounds, Looks, CLI, Activity log, and Decisions to review 16 to 20).

## Global Constraints

- Swift 6 language mode with strict concurrency, no warnings.
- `make lint`, `make build` with 0 warnings, `make test` three clean runs on a quiet machine, `make e2e`.
- Markdown: one sentence per line, no em dashes.
- Conventional commit prefixes, no trailers.
- Tests never touch `~/.claude/settings.json` or the release app's socket.
- Never quit or kill the release Canopy; kill dev builds by pid only.

## How Claude Code reports background work

Captured from Claude Code 2.1.295 on 2026-10-09 with `claude -p --model haiku` in a throwaway folder whose Stop hook dumps stdin.

A background Bash command:

```json
{"hook_event_name": "Stop",
 "last_assistant_message": "The 40-second sleep is running in the background. I'll wait for it to finish and report the output.",
 "background_tasks": [{"id": "bybwi8u6r", "type": "shell", "status": "running",
   "description": "Sleep 40 seconds then print finished", "command": "sleep 40 && echo finished"}]}
```

A Monitor reports the same type, `shell`:

```json
{"background_tasks": [{"id": "bln3q9qxi", "type": "shell", "status": "running",
   "description": "Ticks from the 3x10s countdown loop", "command": "for i in 1 2 3; do sleep 10; echo tick $i; done"}],
 "last_assistant_message": "The monitor is running the loop. I'll wait for the ticks to arrive, then report when all three are in."}
```

Every hook across one background shell, in order:

```
SessionStart
UserPromptSubmit   the prompt
PreToolUse Bash
PostToolUse Bash
Stop               background_tasks: [the shell, running]
UserPromptSubmit   <task-notification> ... (the wake)
Stop               background_tasks: []
SessionEnd
```

So a pane goes working, background, working, done, and the done bell rings at the last `Stop`.

## Decisions

| Question | Choice | Why |
|---|---|---|
| Which tasks count | Every entry that is not `subagent` or `workflow`, whose `status` is `running` or missing | Monitor shows as `shell`; a kind Claude Code adds later still shows background rather than done. |
| Precedence on `Stop` | subagent or workflow, then question, then background, then done | A question needs the author whatever runs. Subagents already meant working. |
| Urgency | background < working < done < waiting | Background asks least of the author, and a dev server's ring must not hide a working agent in the same row. |
| Unseen form | None; the ring shows while the work runs | Seeing it does not end the work, and a dev server's ring is true for as long as it runs. |
| `term wait` | `--for background` added; `any` stays done or waiting | Coordinators wait with `any` or `done` to learn a row finished. |
| Keys | Never move a background pane | The agent is at its own input line; a submitted prompt reports working through its hook. |
| Sounds | None on background | The agent is not done; the done bell rings at the later `Stop`. |
| Repeat background | Updates the task labels, no change event | A Monitor wakes the agent on each output line, and its turns end background again. |
| Hover | Every dot gets `.help` and an accessibility label; background lists the task labels | The tooltip is the only way to see what the ring waits on. |
| Saved state | Nothing on disk holds `AgentState` | States live in memory; the relay keeps raw hook JSON on hosts, which the Mac maps afresh. |
| Remote rows | No change | Host hooks relay their stdin to the Mac's `canopy agent-hook`, which runs the same mapping. |

## Review Focus

1. A dev server started in the background: the row stays background for as long as it runs, and never rings.
2. `term wait --for done` (and the default `any`) on a background pane keeps waiting rather than returning.
3. A background pane whose agent exits (Control-C twice) clears to none, and a waiting `term wait` fails with `agent_stopped`.
4. A Monitor that wakes the agent on every line: the task labels stay current and nothing is logged twice.
5. A `Stop` whose `background_tasks` has a task with `status: "completed"` next to nothing running reads as done.

## File Structure

- `Sources/CanopyCore/Agents/PaneAgent.swift`: `AgentState.background`, `AgentReport.backgroundTasks`, `AgentDot.background` and its order, `PaneAgent.backgroundTasks`.
- `Sources/CanopyCore/Agents/ClaudeHookMapping.swift`: the `Stop` rule and task labels.
- `Sources/CanopyCore/Agents/BackgroundWork.swift` (new): the tooltip and label text, so it is tested in Core.
- `Sources/CanopyCore/Terminal/Pane.swift`: `tasks` in the activity event.
- `Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`: `AgentWaitTarget.background`, the background task labels for a tab, a row, and several rows.
- `Sources/CanopyCore/Control/TermMethods.swift`: `backgroundTasks` in `TermStateParams` and `TermInfo`.
- `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`: fills `TermInfo.backgroundTasks`.
- `Sources/CanopyCore/State/GlobalConfig.swift`: no sound for background.
- `Sources/CanopyCLI/TermCommand.swift`, `Sources/CanopyCLI/AgentGuide.swift`: the new state in help and the guide.
- `Sources/CanopyApp/Style/AgentDotView.swift`: the ring, tooltips, labels.
- `Sources/CanopyApp/Sidebar/*.swift`, `Sources/CanopyApp/Plugins/*.swift`, `Sources/CanopyApp/Terminal/*.swift`: pass task labels to the dots and row labels.
- `scripts/e2e.sh`, `scripts/ui-fixture.sh`: a background pane.

---

### Task 1: The state and the hook mapping

**Files:**
- Modify: `Sources/CanopyCore/Agents/PaneAgent.swift`
- Modify: `Sources/CanopyCore/Agents/ClaudeHookMapping.swift`
- Test: `Tests/CanopyCoreTests/ClaudeHookTests.swift`

**Interfaces:**
- Produces: `AgentState.background` (raw value `"background"`), `AgentReport.backgroundTasks: [String]` (init parameter `backgroundTasks: [String] = []`).

- [ ] **Step 1: Write the failing tests**

In `ClaudeHookTests`, `expected` gains `backgroundTasks: [String] = []`, passed through to `AgentReport`.
Replace the shell and monitor loop of `aTurnEndsDoneOnAQuestionOrStillWorking`, which expected done, with:

```swift
    @Test func aTurnThatEndsWithShellsRunningIsBackground() {
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "The 40-second sleep is running in the background. I'll wait for it to finish and report the output.", "background_tasks": [{"id": "bybwi8u6r", "type": "shell", "status": "running", "description": "Sleep 40 seconds then print finished", "command": "sleep 40 && echo finished"}]}"#
            )
                == expected(.background, "Stop", backgroundTasks: ["Sleep 40 seconds then print finished"]))
        // A label falls back to the command, then the type.
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "The server runs.", "background_tasks": [{"id": "t1", "type": "monitor", "status": "running", "description": " ", "command": "bun dev"}, {"id": "t2", "type": "remote_job"}]}"#
            )
                == expected(.background, "Stop", backgroundTasks: ["bun dev", "remote_job"]))
        // Finished tasks do not count.
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "All done.", "background_tasks": [{"id": "t1", "type": "shell", "status": "completed", "command": "npm test"}]}"#
            )
                == expected(.done, "Stop"))
    }

    @Test func aQuestionOrASubagentWinsOverShells() {
        let shell = #"{"id": "t1", "type": "shell", "status": "running", "command": "npm test"}"#
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Tests run. Should I push?", "background_tasks": [\#(shell)]}"#
            )
                == expected(.waiting, "Stop", question: true))
        #expect(
            report(
                #"{"session_id": "abc123", "hook_event_name": "Stop", "last_assistant_message": "Both run.", "background_tasks": [\#(shell), {"id": "t2", "type": "subagent", "status": "running"}]}"#
            )
                == expected(.working, "Stop"))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test FILTER=ClaudeHookTests` (or `swift test $(scripts/test-flags.sh) --filter ClaudeHookTests`).
Expected: compile failure, `background` is not a member of `AgentState`.

- [ ] **Step 3: Implement**

`PaneAgent.swift`:

```swift
public enum AgentState: String, Codable, Sendable, CaseIterable {
    case none
    case working
    case waiting
    case done
    /// The turn ended, but background work the agent started still runs, and the agent wakes when it ends.
    case background
}
```

`AgentReport` gains, with an init parameter `backgroundTasks: [String] = []` after `releases`:

```swift
    /// What still runs for a background report, by the labels `BackgroundWork` shows.
    public var backgroundTasks: [String]
```

`ClaudeHookMapping`, the `Stop` case and the task type:

```swift
        case "Stop":
            // Background subagents and workflows end on their own and wake the agent, so the turn is not over.
            if hook.backgroundTasks?.contains(where: \.isAgent) == true {
                return report(.working)
            }
            if let message = hook.lastAssistantMessage, endsOnQuestion(message) {
                return report(.waiting, question: true)
            }
            // Shells and monitors can run for good, like a dev server, so the turn is over but the agent will wake.
            let running = (hook.backgroundTasks ?? []).filter(\.isRunningWork)
            if !running.isEmpty {
                return report(.background, backgroundTasks: running.map(\.label))
            }
            return report(.done)
```

```swift
        struct BackgroundTask: Decodable {
            var type: String?
            var status: String?
            var description: String?
            var command: String?

            var isAgent: Bool { ["subagent", "workflow"].contains(type) }
            var isRunningWork: Bool { !isAgent && (status == nil || status == "running") }

            var label: String {
                [description, command, type].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "background task"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                status = try? container.decodeIfPresent(String.self, forKey: .status)
                description = try? container.decodeIfPresent(String.self, forKey: .description)
                command = try? container.decodeIfPresent(String.self, forKey: .command)
            }

            enum CodingKeys: String, CodingKey { case type, status, description, command }
        }
```

The local `report` helper gains `backgroundTasks: [String] = []` and passes it on.
Fix every `switch` over `AgentState` the compiler flags: `PaneAgent.dot` (Task 2), and `AgentSound.sound`, where `.background` plays `""` like working.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter ClaudeHookTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: Stop with running shells reports background"
```

### Task 2: Pane rules, dots, and the text

**Files:**
- Modify: `Sources/CanopyCore/Agents/PaneAgent.swift`
- Create: `Sources/CanopyCore/Agents/BackgroundWork.swift`
- Modify: `Sources/CanopyCore/Terminal/Pane.swift`
- Modify: `Sources/CanopyCore/Terminal/TerminalStore+Agents.swift`
- Test: `Tests/CanopyCoreTests/PaneAgentTests.swift`, `Tests/CanopyCoreTests/PaneAgentStateTests.swift`, `Tests/CanopyCoreTests/TerminalStoreAgentTests.swift`

**Interfaces:**
- Consumes: `AgentState.background`, `AgentReport.backgroundTasks`.
- Produces: `AgentDot.background`; `PaneAgent.backgroundTasks: [String]`; `TerminalTab.backgroundTasks: [String]`; `TerminalStore.backgroundTasks(inRow:) -> [String]` and `backgroundTasks(inRows:) -> [String]`; `BackgroundWork.summary(_ tasks: [String]) -> String` and `BackgroundWork.label(_ tasks: [String]) -> String`; `AgentWaitTarget.background`.

- [ ] **Step 1: Write the failing tests**

`PaneAgentTests`:

```swift
    @Test func aBackgroundTurnKeepsItsWorkUntilTheNextState() {
        var agent = PaneAgent()
        _ = agent.apply(AgentReport(state: .working), now: t(1))
        let change = agent.apply(AgentReport(state: .background, backgroundTasks: ["npm test", "bun dev"]), now: t(2))
        #expect(change == AgentChange(from: .working, to: .background, via: "term.state"))
        #expect(change?.alerts == false)
        #expect(agent.dot == .background)
        #expect(!agent.unseen)
        #expect(agent.backgroundTasks == ["npm test", "bun dev"])
        // A Monitor wakes the agent on each line, and its turn can end background again with less running.
        #expect(agent.apply(AgentReport(state: .background, backgroundTasks: ["bun dev"]), now: t(3)) == nil)
        #expect(agent.backgroundTasks == ["bun dev"])
        #expect(agent.seen() == false)
        #expect(agent.dot == .background)
        _ = agent.apply(AgentReport(state: .working), now: t(4))
        #expect(agent.backgroundTasks.isEmpty)
    }

    @Test func keysLeaveABackgroundPaneAlone() {
        var agent = PaneAgent()
        _ = agent.apply(AgentReport(state: .background, backgroundTasks: ["sleep 60"]), now: t(1))
        for key in ["\u{1b}", "\u{03}", "\r", "next step\r"] {
            #expect(agent.typed(Data(key.utf8), at: t(2)) == nil)
        }
        #expect(agent.state == .background)
        #expect(agent.ended(at: t(3)) == AgentChange(from: .background, to: .none, via: "exit"))
        #expect(agent.backgroundTasks.isEmpty)
    }
```

`theMostUrgentDotWins` becomes:

```swift
    @Test func theMostUrgentDotWins() {
        #expect([AgentDot.background, .working].max() == .working)
        #expect([AgentDot.working, .done, .background].max() == .done)
        #expect([AgentDot.done, .waiting, .working, .background].max() == .waiting)
    }
```

`eachStateHasAnActivityType` gains `#expect(ActivityType.agent(.background) == "agent.background")`.

A new `BackgroundWorkTests`:

```swift
struct BackgroundWorkTests {
    @Test func theTextNamesTheWork() {
        #expect(
            BackgroundWork.summary(["npm test"])
                == "Turn ended, waiting on background work: npm test. The agent wakes when it finishes.")
        #expect(
            BackgroundWork.summary(["npm test", "bun dev", "npm test"])
                == "Turn ended, waiting on background work: npm test, bun dev. The agent wakes as each finishes.")
        #expect(
            BackgroundWork.summary([])
                == "Turn ended, waiting on background work. The agent wakes when it finishes.")
        #expect(BackgroundWork.label(["npm test"]) == "Agent waiting on background work: npm test")
        #expect(BackgroundWork.label([]) == "Agent waiting on background work")
    }
}
```

`TerminalStoreAgentTests`:

```swift
    @Test func backgroundIsTheLeastUrgentDotAndListsItsWork() throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        var alerts: [AgentState] = []
        rows.terminals.onAgentAlert = { alerts.append($1) }

        rows.beside.report(AgentReport(state: .background, backgroundTasks: ["bun dev"]))
        rows.otherTab.report(AgentReport(state: .background, backgroundTasks: ["npm test"]))
        #expect(rows.firstTab.agentDot == .background)
        #expect(rows.firstTab.backgroundTasks == ["bun dev"])
        #expect(rows.terminals.backgroundTasks(inRow: rows.a) == ["bun dev", "npm test"])
        rows.focused.report(AgentReport(state: .working))
        #expect(rows.firstTab.agentDot == .working)
        #expect(rows.terminals.agentDot(inRows: [rows.a, rows.b]) == .working)
        #expect(rows.terminals.backgroundTasks(inRows: [rows.a, rows.b]) == ["bun dev", "npm test"])
        #expect(rows.terminals.backgroundTasks(inRow: rows.b).isEmpty)
        // Seeing a background pane keeps its ring, and becoming background plays nothing.
        rows.terminals.viewing = AgentViewing(rowPath: rows.a, isFrontmost: true)
        #expect(rows.otherTab.agent.dot == .background)
        #expect(alerts.isEmpty)
        rows.beside.report(AgentReport(state: .done))
        #expect(alerts == [.done])
    }

    @Test func aWaitForDoneOrAnyIgnoresBackground() async throws {
        let dir = try TempDir()
        let rows = try Rows(dir)
        defer { rows.terminals.closeAll() }
        rows.otherRow.report(AgentReport(state: .background, backgroundTasks: ["sleep 60"]))
        let (pane, state) = try await rows.terminals.waitForAgents(
            [rows.otherRow.id], for: .background, timeout: .seconds(5))
        #expect(pane === rows.otherRow && state == .background)

        for target in [AgentWaitTarget.done, .any] {
            let wait = Task {
                try await rows.terminals.waitForAgents([rows.otherRow.id], for: target, timeout: .seconds(20))
            }
            try await Task.sleep(for: .milliseconds(100))
            rows.otherRow.report(AgentReport(state: .background, backgroundTasks: ["sleep 30"]))
            rows.otherRow.report(AgentReport(state: .working))
            rows.otherRow.report(AgentReport(state: .done))
            #expect(try await wait.value.1 == .done)
            rows.otherRow.report(AgentReport(state: .background))
        }
    }
```

`PaneAgentStateTests.reportsChangeThePaneAndAreLogged` gains a background report between working and done, expecting `"agent.background"` with `"tasks": ["npm test"]` in its data.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PaneAgent|BackgroundWork|TerminalStoreAgent'`
Expected: compile failures on `AgentDot.background`, `backgroundTasks`, `BackgroundWork`.

- [ ] **Step 3: Implement**

`PaneAgent.swift`:

```swift
public enum AgentDot: Int, Comparable, Sendable {
    case background
    case working
    case done
    case waiting
    ...
}
```

```swift
    /// The labels of the work still running while the pane is background.
    public private(set) var backgroundTasks: [String] = []

    public var dot: AgentDot? {
        switch state {
        case .none: nil
        case .working: .working
        case .waiting: .waiting
        case .done: unseen ? .done : nil
        case .background: .background
        }
    }
```

In `apply`, after the session checks:

```swift
        guard let next = report.state else { return nil }
        if next == .background, state == .background {
            backgroundTasks = report.backgroundTasks
            return nil
        }
        guard next != state || next == .done else { return nil }
        waitsOnQuestion = next == .waiting && report.question
        backgroundTasks = next == .background ? report.backgroundTasks : []
        return change(...)
```

and `change(to:)` clears `backgroundTasks` when `next != .background`, so keys and exits clear it.

`BackgroundWork.swift`:

```swift
/// How Canopy names the work a background agent waits on, in tooltips and accessibility labels.
public enum BackgroundWork {
    /// "Turn ended, waiting on background work: npm test. The agent wakes when it finishes."
    public static func summary(_ tasks: [String]) -> String {
        let names = unique(tasks)
        let work = names.isEmpty ? "" : ": " + names.joined(separator: ", ")
        let wakes = names.count > 1 ? "The agent wakes as each finishes." : "The agent wakes when it finishes."
        return "Turn ended, waiting on background work\(work). \(wakes)"
    }

    /// The short form, for a row's accessibility label: "Agent waiting on background work: npm test".
    public static func label(_ tasks: [String]) -> String {
        let names = unique(tasks)
        return "Agent waiting on background work" + (names.isEmpty ? "" : ": " + names.joined(separator: ", "))
    }

    static func unique(_ tasks: [String]) -> [String] {
        var seen = Set<String>()
        return tasks.filter { seen.insert($0).inserted }
    }
}
```

`TerminalStore+Agents.swift`:

```swift
public enum AgentWaitTarget: String, Codable, Sendable, CaseIterable {
    case done
    case waiting
    /// A turn that ended with background work still running.
    case background
    /// Done or waiting. Background is left out, since coordinators wait to learn a row finished.
    case any

    public func matches(_ state: AgentState) -> Bool {
        switch self {
        case .done: state == .done
        case .waiting: state == .waiting
        case .background: state == .background
        case .any: state == .done || state == .waiting
        }
    }
}

extension TerminalTab {
    /// The work its background panes wait on.
    public var backgroundTasks: [String] {
        paneList.flatMap(\.agent.backgroundTasks)
    }
}

extension TerminalStore {
    public func backgroundTasks(inRow path: String) -> [String] {
        tabs(inRow: path).flatMap(\.backgroundTasks)
    }

    public func backgroundTasks(inRows paths: [String]) -> [String] {
        paths.flatMap(backgroundTasks(inRow:))
    }
}
```

`Pane.agentChanged` adds `data["tasks"] = .array(agent.backgroundTasks.map(JSONValue.string))` when `change.to == .background`.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PaneAgent|BackgroundWork|TerminalStoreAgent'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: panes keep a background state with its running work"
```

### Task 3: The control methods and the CLI

**Files:**
- Modify: `Sources/CanopyCore/Control/TermMethods.swift`
- Modify: `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`
- Modify: `Sources/CanopyCLI/TermCommand.swift`, `Sources/CanopyCLI/AgentGuide.swift`
- Modify: `scripts/e2e.sh`
- Test: `Tests/CanopyCoreTests/AgentControlTests.swift`, `Tests/CanopyCoreTests/ClaudeHookTests.swift`

**Interfaces:**
- Consumes: `AgentReport.backgroundTasks`, `PaneAgent.backgroundTasks`, `AgentWaitTarget.background`.
- Produces: `TermStateParams.backgroundTasks: [String]` (encoded only when not empty), `TermInfo.backgroundTasks: [String]?` (nil when empty).

- [ ] **Step 1: Write the failing tests**

`ClaudeHookTests`, through `AgentHook.request`, so what crosses the socket is checked:

```swift
    @Test func aBackgroundReportCarriesItsWorkToTheApp() throws {
        let input = #"{"session_id": "abc123", "hook_event_name": "Stop", "background_tasks": [{"type": "shell", "status": "running", "command": "npm test"}]}"#
        let hook = try #require(
            AgentHook.request(
                input: Data(input.utf8), environment: ["CANOPY_PANE": "p3", "CANOPY_HOME": "/tmp/h"], startedAt: started))
        let params = try hook.request.params.decode(TermStateParams.self)
        #expect(params.state == .background)
        #expect(params.report.backgroundTasks == ["npm test"])
        // An older app's params, without the field, still read.
        let old = try JSONValue.from(TermStateParams(pane: "p3", state: .done)).decode(TermStateParams.self)
        #expect(old.backgroundTasks.isEmpty)
    }
```

`AgentControlTests.agentStatesAreReportedListedAndWaitedOn` gains: a `term.state` with `"state": "background", "backgroundTasks": ["bun dev"]`; `term.list` showing `"agent": "background"` and `"backgroundTasks": ["bun dev"]` for that pane, and no `backgroundTasks` key for the others; `term.wait` with `"for": "background"` returning it.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'ClaudeHookTests|AgentControlTests'`
Expected: compile failure on `backgroundTasks`.

- [ ] **Step 3: Implement**

`TermStateParams` gains `public var backgroundTasks: [String]`, an init parameter after `releases` defaulting to `[]`, `decodeIfPresent(...) ?? []`, an `encode(to:)` that leaves it out when empty, and passes it both ways in `init(pane:_:)` and `report`.
`TermInfo` gains `public var backgroundTasks: [String]?`, set in `RowLifecycle+Terminals` as `pane.agent.backgroundTasks.isEmpty ? nil : pane.agent.backgroundTasks`.

`TermCommand`:
- `State` usage `<working|waiting|done|background|none>`, discussion adds "background when their turn ended but work they started still runs", and validation "The state must be working, waiting, done, background, or none."
- `Wait` `--for` help "done, waiting, background, or any (done or waiting)."

`AgentGuide`'s Agent state section:

```
    canopy term state [<id>] <working|waiting|done|background|none>   report an agent's state, your terminal's by default
    canopy term wait <id>... [--for done|waiting|background|any] [--timeout 30m]
```

and: "`term list` shows each terminal's agent state: working, waiting, done, background, or blank. Background means the agent's turn ended while work it started in the background still runs, such as a shell or a dev server; the agent wakes when it ends. `--for any` means done or waiting and never returns on background, so waiting on a row with a background dev server waits until it stops or the time runs out; pass `--for background` to learn that a turn ended with work still running."

`scripts/e2e.sh`, after the question step:

```bash
hook '{"session_id": "e2e", "hook_event_name": "UserPromptSubmit", "prompt": "run the tests"}'
hook '{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "Tests are running.", "background_tasks": [{"id": "b1", "type": "shell", "status": "running", "description": "Run the test suite", "command": "npm test"}]}'
[[ "$(agent_state)" == background ]] || fail "a turn ending with a shell running did not make the pane background"
"$cli" term list --repo demo --row feat/term --json | grep -q '"Run the test suite"' || fail "term list does not name the background work"
if "$cli" term wait "$agent" --for done --timeout 1s >/dev/null 2>&1; then fail "term wait --for done returned on background"; fi
"$cli" term wait "$agent" --for background --timeout 5s | grep -qx "$agent background" || fail "term wait --for background did not return"
```

The log check's expected types gain `"agent.working", "agent.background"` after the waiting step, and a check that `agent.background` carries `"tasks": ["Run the test suite"]`.
The guide check: `grep -q "for background" <<<"$("$cli" agent-guide)"`.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'ClaudeHookTests|AgentControlTests'`, then `make e2e`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: term state, list, wait, and the guide learn background"
```

### Task 4: The ring and the tooltips

**Files:**
- Modify: `Sources/CanopyApp/Style/AgentDotView.swift`
- Modify: `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/Sidebar/GroupViews.swift`, `Sources/CanopyApp/Plugins/PluginSectionView.swift`, `Sources/CanopyApp/Plugins/PluginRowViews.swift`, `Sources/CanopyApp/Terminal/TopBarView.swift`, `Sources/CanopyApp/Terminal/PaneView.swift`
- Modify: `scripts/ui-fixture.sh`

**Interfaces:**
- Consumes: `AgentDot.background`, `BackgroundWork.summary`, `BackgroundWork.label`, the store's `backgroundTasks` helpers.
- Produces: `AgentDotView(dot:size:tasks:)`; `AgentDot.label(tasks:)` (short) and `AgentDot.help(tasks:)` (tooltip).

The look, compared in light and dark window shots before picking:

| Option | Shape | Motion |
|---|---|---|
| A | green ring, 1.5 pt line, as wide as the other dots' halo, no fill | opacity 1 to 0.4, 1.5 s each way |
| B | the done dot, hollow, 6 pt with its halo | same |
| C | green dot at 50% with a ring | same |

The plan takes A, the author's pick, unless the shots show it reads as done; the After Review notes what the shots showed.

- [ ] **Step 1: The ring**

`AgentDotView` gains `var tasks: [String] = []`.
The background case draws `PulsingDot(style: .ring)` (or a still ring with Reduce Motion), and `PulsingDotView` takes a style: `.filled` (the working dot, accent, 0.8 s) or `.ring` (done green, a `CAShapeLayer` circle with a 1.5 pt line and no fill, 1.5 s).
The view sets `.help(dot.help(tasks: tasks))` and `.accessibilityLabel(dot.help(tasks: tasks))`.

```swift
extension AgentDot {
    /// The short form, for a row's or tab's own accessibility label.
    func label(tasks: [String]) -> String {
        switch self {
        case .working: "Agent working"
        case .waiting: "Agent waiting for you"
        case .done: "Agent done"
        case .background: BackgroundWork.label(tasks)
        }
    }

    /// The tooltip, which for background names the work it waits on.
    func help(tasks: [String]) -> String {
        self == .background ? BackgroundWork.summary(tasks) : label(tasks: tasks)
    }
}
```

- [ ] **Step 2: Pass the work everywhere a dot stands**

Sidebar rows, repo headers, group headers, plugin sections and plugin rows pass `model.terminals.backgroundTasks(inRow:)` or `(inRows:)` to `AgentDotView` and use `agentDot.label(tasks:)` in their accessibility labels in place of `agentDot.label.lowercased()`, lowercasing only its first letter.
The tab bar passes `tab.backgroundTasks`, and the pane header `pane.agent.backgroundTasks`.

- [ ] **Step 3: The fixture**

`scripts/ui-fixture.sh` reports background on one pane through `agent-hook` with a real `Stop` payload, so the tooltip has work to name, and puts a done row beside it:

```bash
printf '%s' '{"session_id": "fixture", "hook_event_name": "Stop", "last_assistant_message": "The dev server is up.", "background_tasks": [{"id": "b1", "type": "shell", "status": "running", "description": "Start the dev server", "command": "bun dev"}]}' |
    CANOPY_PANE="$(pane_in feat/search Terminal)" "$cli" agent-hook
```

- [ ] **Step 4: Build and look**

Run: `make build 2>&1 | grep -c "warning:"` (expect 0), then `scripts/ui-fixture.sh dark` and `scripts/ui-fixture.sh light`, window shots of the sidebar, the hover tooltip over the ring, a tab, and a pane header.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: a pulsing green ring for background agents, and dot tooltips"
```

### Task 5: End to end with real Claude Code

No code; the evidence goes in the PR.

- [ ] In a dev build from `scripts/ui-fixture.sh`, open a pane, start `claude --settings <temp settings with Canopy's hooks> --model haiku`, and ask it to run `sleep 60` in the background and end its turn.
- [ ] Window shots, light and dark: the row's ring, and the tooltip naming the sleep.
- [ ] After the sleep ends and the agent wakes, a shot of the done dot, and `canopy log --type agent` showing working, background, working, done.
- [ ] Ask it to start a dev server in the background (`python3 -m http.server`) and end its turn: the row stays background, and no bell.
- [ ] Remote rows: `scripts/e2e-hosts.sh` gains a background `Stop` through the relay, checked as `background` in `term list`.

## After Review

Filled in after the independent review.
