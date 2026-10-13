# Canopy on the box, Milestone 7: New task from the phone

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the phone starts work: New task picks a server, a repo, a branch and a brief, and the server makes the row, starts its agent command with the brief in a new pane, and the phone opens that conversation.

**Architecture:** `phone.newRow` joins the methods a paired phone may call.
`PhoneServer` turns the brief into one shell-quoted argument after the server's agent command, and asks its `PhoneSource` to make the row and a pane running that line.
On the Mac, `MacPhoneSource` makes the row by `row new`'s rules through `RowLifecycle`, runs setup, and opens a tab running the line; on the box, `BoxPhoneSource` uses `BoxDaemon.rowNew` and `paneNew(command:)`.
Each server's agent command comes from the Mac's `config.json`: the Mac's own from `canopy phone agent`, a box's from `canopy host add --agent` or `canopy phone agent --on <host>`, sent in `box.configure`.
`phone.hello` carries the command, the phone keeps it with the server, and New task shows it read-only.

**Tech Stack:** Swift 6.4, Swift Testing, SwiftUI, XCUITest, tmux on the box.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "New task", "Servers", "Settings", "Security", "Testing", and Delivery item 7.

## Global Constraints

- The phone never chooses the program: it sends a brief, and the server's own agent command runs it.
- The brief is one argument, shell-quoted, whatever it holds: quotes, `$`, backticks, newlines.
- Every new wire field is optional; the protocol stays version 1, and a server without `phone.newRow` answers `method_not_allowed`, which the phone words as "update Canopy there".
- Nothing runs against hindie-box or AWS; the e2e uses the fake host and the fixture's devbox box.
- Swift 6 language mode, strict concurrency, no warnings; markdown one sentence per line, no em dashes; conventional commits, no trailers.

## Rulings

- The default agent command is `claude --model 'opus[1m]' --permission-mode bypassPermissions`, as `PhoneAgentCommand.standard` in `CanopyWire`, used by both servers when `config.json` names none.
- The Mac's command is `config.json`'s top-level `agentCommand`; a host's is `agentCommand` in its section under `hosts`.
  `canopy phone agent` prints the Mac's, `canopy phone agent "<command>"` sets it, `--default` removes it; `--on <host>` does the same for an upgraded host, as `phone pair --on` does, and `canopy host add <host> --agent "<command>"` sets it while adding.
  An upgraded host's link reconfigures the box when its command changes.
- The line a pane runs is the command, a space, and the brief quoted for POSIX shells with single quotes; an empty brief runs the command alone.
- On the Mac the row runs its setup first, as `row new` does, and the agent starts once setup succeeds; a failed setup answers `setup_failed` with the row named and where to look, and leaves the row.
  The new tab opens in the row without selecting it, so the Mac's window does not jump.
- On the box rows run no setup, as `row new` there already does.
- The activity log records `phone.newRow` with the phone, repo, branch, and pane; the brief only when `logCommands` is on, as replies.
- The phone's Where list is the paired servers, the last one started on first; a server out of reach is greyed, except a box with a wake key, which Start wakes first and then makes the row on.
- Repo choices are the server's repos from Rows, refreshed when the sheet opens; a server whose repos are not known yet, as a box that was off since the app started, takes a typed repo name.
- From is optional: empty means `row new`'s own choice, a branch that exists or origin's default branch.

## Review Focus

1. A brief with quotes, `$(...)`, backticks, and a newline reaches the agent as typed, and runs nothing in the shell.
   Pinned by `theBriefIsOneQuotedArgument` in Task 1 and the e2e brief in Task 3.
2. A branch already checked out elsewhere, or with a name git refuses, answers the server's error, and the sheet shows it with the fields kept.
   Pinned by `aRefusedBranchKeepsTheSheet` in Task 4.
3. Start on a box that is off wakes it, then makes the row; a failed wake shows the wake's failure and makes nothing.
   Pinned by `startWakesABoxFirst` and `aFailedWakeMakesNoRow` in Task 4.
4. A server older than this milestone answers `method_not_allowed`, and the sheet says to update Canopy there.
   Pinned by `anOlderServerSaysToUpdate` in Task 4.
5. A setup that fails on the Mac leaves the row, starts no agent, and says where to look.
   Pinned by `aFailedSetupStartsNoAgent` in Task 2.

---

### Task 1: `phone.newRow` on the wire and in the phone server

**Files:**
- Modify: `Sources/CanopyWire/PhoneProtocol.swift` (`PhoneMethod.newRow`, `PhoneNewRowParams`, `PhoneNewRowResult`, `PhoneHelloResult.agentCommand`, `PhoneAgentCommand`), `Sources/CanopyServer/PhoneSource.swift` (`newRow`, `PhoneServerSettings.agentCommand`), `Sources/CanopyServer/PhoneConnection.swift` (allowed methods, greeting), `Sources/CanopyServer/PhoneServer.swift`
- Test: `Tests/CanopyServerTests`, `Tests/CanopyWireTests`

- [ ] Tests: `theBriefIsOneQuotedArgument`, `anEmptyBriefRunsTheCommandAlone`, `newRowRunsTheServersCommandWithTheBrief`, `helloCarriesTheAgentCommand`, `newRowIsLoggedWithoutTheBrief`.
- [ ] Commit `feat: phones can ask a server for a new row running its agent command`.

### Task 2: The Mac serves `phone.newRow` and keeps agent commands

**Files:**
- Modify: `Sources/CanopyCore/State/GlobalConfig.swift` (`agentCommand`), `Sources/CanopyCore/Hosts/HostConfig.swift` (`HostEntry.agentCommand`), `Sources/CanopyCore/Workspace/Workspace+Box.swift` (`boxConfig(for:)`), `Sources/CanopyCore/Phone/MacPhoneSource.swift`, `Sources/CanopyCore/Phone/PhoneService.swift`, `Sources/CanopyCore/Control/*` (`phones.agent`), `Sources/CanopyServer/PhonesMethods.swift`, `Sources/CanopyCLI/PhoneCommand.swift`, `Sources/CanopyCLI/HostCommand.swift`, `Sources/CanopyApp/AppModel.swift`
- Create: `Sources/CanopyCore/Phone/PhoneNewRow.swift` (`RowLifecycle.phoneNewRow`), `Sources/CanopyCore/Phone/AgentCommands.swift` (`Workspace.agentCommand(_:)`)
- Test: `Tests/CanopyCoreTests/PhoneNewRowTests.swift`, `Tests/CanopyCLITests`

- [ ] Tests: `newRowMakesTheRowAndRunsTheLine`, `aFailedSetupStartsNoAgent`, `anUnknownRepoIsRefused`, `phoneAgentSetsAndClearsTheMacsCommand`, `hostAgentReachesTheBox`.
- [ ] Commit `feat: the Mac starts tasks from the phone, and canopy phone agent and host agent set what they run`.

### Task 3: The box serves `phone.newRow`

**Files:**
- Modify: `Sources/CanopyBoxKit/BoxPhoneSource.swift`, `Sources/CanopyBoxKit/BoxMain.swift` (the agent command for hello and new rows), `scripts/phone-client.py` (`new-row`), `scripts/e2e-hosts.sh`, `scripts/e2e-phone.sh`
- Test: `Tests/CanopyBoxKitTests/BoxPhoneSourceTests.swift`

- [ ] Tests: `newRowOnTheBoxMakesARowAndAPane`, `theBoxRunsTheCommandTheMacSet`.
- [ ] e2e: `phone.newRow` on the fake host's box and on the Mac, with a brief holding quotes and `$(...)`, checking the fake agent got it whole and the Mac shows the box's new row.
- [ ] Commit `feat: canopy-box starts tasks from the phone`.

### Task 4: The phone's New task

**Files:**
- Modify: `Sources/CanopyPhone/PairedServer.swift` (`agentCommand`), `Sources/CanopyPhone/ServerConnection.swift`, `Sources/CanopyPhone/PhoneApp.swift`
- Create: `Sources/CanopyPhone/NewTaskModel.swift`
- Test: `Tests/CanopyPhoneTests/NewTaskModelTests.swift`

- [ ] Tests: `whereListsTheLastServerFirst`, `aServerOutOfReachIsGreyedUnlessItWakes`, `startSendsTheFieldsAndOpensThePane`, `aRefusedBranchKeepsTheSheet`, `startWakesABoxFirst`, `aFailedWakeMakesNoRow`, `anOlderServerSaysToUpdate`, `reposComeFromRowsOrAreTyped`.
- [ ] Commit `feat: the phone starts a task on any paired server`.

### Task 5: The sheet, Settings, and the tour

**Files:**
- Create: `Apps/CanopyiOS/Canopy/NewTaskView.swift`
- Modify: `Apps/CanopyiOS/Canopy/InboxView.swift` (New task in the title bar), `Apps/CanopyiOS/Canopy/SettingsView.swift` (each server's agent command), `Apps/CanopyiOS/CanopyUITests/ScreenTour.swift`, `scripts/ios-shots.sh`

- [ ] The tour opens New task, starts a task on the fixture's box, lands in its conversation, and shoots the sheet and Settings in light and dark.
- [ ] Commit `feat: New task in the iPhone app`.

### Checks

`make lint`, `make build` with no warnings, `make test` three times clean, `make e2e`, `make linux`, the tour in light and dark, an opus review with its findings fixed below, and CI's `check`.
