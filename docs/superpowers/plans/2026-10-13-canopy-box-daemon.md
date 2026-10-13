# Canopy on the box, Milestone 3a: canopy-box

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `canopy-box`, a static Linux program that owns a Canopy home's rows, tmux panes, and agent states on a host, answers hooks and the box's CLI, and serves the Mac on `box.sock`, tested on macOS and Linux against real git and tmux.

**Architecture:** Two new portable library targets and one executable.
`CanopyGit` holds git's runner for a local clone, the worktree list parser, branch slugs, and the branch rules `row new` uses, which the Mac's local and remote rows and `canopy-box` all call.
`CanopyBoxKit` holds the daemon: its files, its state and how it rebuilds it, tmux, rows, panes, agents, the box's CLI, and the server on `box.sock`.
`CanopyBox` is `canopy-box serve`, a thin `main` over `CanopyBoxKit`.
`make box` builds it for x86_64 and arm64 Linux as static musl binaries in a Docker image with Swift 6.4.1 and its static SDK.
Nothing on the Mac talks to `canopy-box` yet: Milestone 3b adds the Mac's link, the service, and `host upgrade`.

**Tech Stack:** Swift 6.4 (6.4.1 for the static build), Swift Testing, swift-argument-parser, tmux 3, git, Docker, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "canopy-box", "The Mac's link to the box" (the methods), "The CLI on the box", "Idle power-off", and Delivery item 3.

## Global Constraints

- No change in behaviour on the Mac: existing tests pass with moved files and imports only, and `make e2e` passes.
- The portable targets import only Foundation, Dispatch, Synchronization, swift-crypto, swift-argument-parser, and each other; libc through `#if canImport(Darwin)`, `Glibc`, or `Musl`.
- Swift 6 language mode, strict concurrency, no warnings on either platform.
- `canopy-box` keeps its files under `~/.canopy/<home id>/box/`, as the spec's table says, and uses tmux as `tmux -u -L canopy-<home id> -f ~/.canopy/<home id>/tmux.conf`.
- Box pane ids are `b<N>` from the daemon's own counter; adopted panes keep their `p<N>` names.
- Tests never touch `~/.canopy`, the author's tmux servers, or the hands-off repos: every test gets a temporary root, `TMUX_TMPDIR`, and a tmux server name of its own.
- Markdown: one sentence per line, no em dashes.
  Conventional commits, no trailers.

## Rulings carried from the spec

- Milestone 3 is two PRs, as the handover suggested.
  3a, this plan, is `canopy-box` with its own tests.
  3b is the Mac's side: installing the binary and its systemd unit, forwarding `box.sock`, `box.hello` versions, the Mac's rows and `HostMonitor` from `box.subscribe`, `host upgrade` and `--undo`, the relay script's switch to `box.sock`, the ports listing, and both e2e runs.
  3a alone ships something that runs and is tested but that nothing uses, so it cannot change what the author sees.
- The branch rules go in a target of their own, `CanopyGit`, rather than in `CanopyAgents` as the spec lists them: they have nothing to do with agents, and `canopy-box` needs git without the rest.
- The daemon's activity log comes with milestone 4, where its only spec'd entries (`phone.call`, `phone.paired`, `phone.removed`) start.
- The relay's framing (a request line, an acknowledgement, heartbeats, a reply) is what the box's CLI speaks on `box.sock`, beside the control protocol's lines, so 3b's relay only changes the socket it connects to, as the spec says.
  The daemon tells them apart by the line: a relay request has `args`, a control request has `method`.
- The box answers `row list --json` with its own row shape, `BoxRow`, rather than the Mac's `SidebarRow`, whose fields (groups, plugins, PRs, classes) mostly mean nothing on the box.
  `term list --json` keeps the Mac's `TermInfo`.
- `make box` builds with Swift 6.4.1 in Docker, since the static SDK is published for 6.4.1 only and the `swift` Docker images stop at 6.4.0.
  The image installs 6.4.1 with swiftly and the SDK by its checksum, which matched a good signature from the Swift signing key when this plan was written.

## Review Focus

1. A daemon restarted while its tmux sessions run must come back with every pane, its row, and its agent state, and a session it never saved must come back as a pane of the row whose folder holds it.
   Pinned by `aRestartKeepsPanesAndAgents` and `anUnknownSessionBecomesAPaneOfItsRow` in Task 6.
2. Text sent to a pane must arrive exactly as given, with quotes, newlines, a leading dash, and words tmux reads as key names, such as `Enter`.
   Pinned by `sentTextArrivesVerbatim` in Task 5.
3. A Mac-bound command must fail within the relay's acknowledgement wait when `app.sock` exists but nothing answers, and a hook must never go to the Mac.
   Pinned by `aSilentMacFailsWithinTheWait` and `hooksNeverLeaveTheBox` in Task 10.
4. A damaged or half-written `state.json` must not stop the daemon: it starts from git and tmux.
   Pinned by `aDamagedStateFileIsRebuilt` in Task 6.
5. The busy file must stop being touched as soon as no agent is working or background, so a stuck `waiting` agent never holds the box on.
   Pinned by `waitingAndDoneDoNotKeepTheBoxOn` in Task 9.

## File Structure

| Target | Files |
|---|---|
| `CanopyGit` | `GitError.swift` (from `CanopyCore/Git/GitRunner.swift`), `GitClone.swift` (new: a clone and how git runs in it), `Worktree.swift` (from Core), `BranchSlug.swift` (from Core), `BranchRules.swift` (new, from `Workspace+Branches.swift` and `Workspace+RowLifecycle.swift`) |
| `CanopyWire` | `CanopyVersion.swift` (from `CanopyHome.swift`), `Relay.swift` (`RelayRequest`, `RelayReply`, `RelayInput`, from `Hosts/Relay.swift`), `BoxProtocol.swift` (new) |
| `CanopyAgents` | `TermProtocol.swift` (`TermMethod`, `TermInfo`, the `Term*Params` and results, `AgentWaitTarget`, from Core) |
| `CanopySystem` | `UnixSocket.swift` (new: `UnixListener`, `UnixConnection`, `UnixSocketError`) |
| `CanopyBoxKit` | `BoxPaths.swift`, `BoxConfig.swift`, `BoxState.swift`, `Tmux.swift`, `BoxDaemon.swift` and extensions `+Rows`, `+Panes`, `+Agents`, `+Reconcile`, `+Adopt`, `BoxCommands.swift`, `MacRelay.swift`, `BoxServer.swift`, `HostLayout.swift` (the host's paths and a pane's variables, from `HostPaths` and `RemoteAttach.environment`) |
| `CanopyBox` | `main.swift` |
| Tests | `CanopyGitTests`, `CanopyBoxTests` (with a `BoxTestHome` helper: temporary root, git repo with an origin, tmux server), new cases in `CanopySystemTests`, `CanopyWireTests` |

Modified: `Package.swift`, `Makefile` (`box`, `linux`), `scripts/box-builder/Dockerfile` (new), `.github/workflows/ci.yml`, `Sources/CanopyCore/Exports.swift`, and the Core files that used the moved types.

---

### Task 1: Targets, the static build, and Linux tests with tmux

**Interfaces:**
- Produces: targets `CanopyGit`, `CanopyBoxKit`, `CanopyBox` (product `canopy-box`), `CanopyGitTests`, `CanopyBoxTests`; `make box` writes `build/box/x86_64/canopy-box` and `build/box/aarch64/canopy-box`.

Steps:

- [ ] `Package.swift` declares every package dependency on both platforms (swift-crypto, swift-argument-parser, SwiftTerm), so Linux and macOS resolve the same `Package.resolved`; Linux still declares only the portable targets.
  The portable targets gain `CanopyGit` (on `CanopySystem`), `CanopyBoxKit` (on `CanopyWire`, `CanopySystem`, `CanopyAgents`, `CanopyServer`, `CanopyGit`, `ArgumentParser`), `CanopyBox` (on `CanopyBoxKit`), and their tests.
  `CanopyBox/main.swift` handles `canopy-box version`, printing `CanopyVersion.current`, so the product links.
- [ ] `scripts/box-builder/Dockerfile`: `FROM swift:6.4`, bash as the shell, `tmux` and `git` from apt, swiftly, `swiftly install 6.4.1 --use`, and `swift sdk install <6.4.1 static-linux 0.1.0 URL> --checksum cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c`.
- [ ] `make box-builder` builds the image as `canopy-box-builder` when it is missing.
  `make box` runs `swift build -c release --swift-sdk <arch>-swift-linux-musl --product canopy-box --scratch-path .build/box` for both arches in it as this user, and copies each binary to `build/box/<arch>/canopy-box`.
  `make linux` runs its build and tests in that image, so tmux is there.
- [ ] CI's `linux` job installs `tmux` before testing and also builds `--product canopy-box`.
- [ ] Verify: `make build`, `make linux`, `make box`, then `docker run --rm --platform linux/amd64 -v $PWD/build/box/x86_64:/b ubuntu:24.04 /b/canopy-box version` prints the version, and `git status` shows no change to `Package.resolved`.
  Commit: `build: canopy-box target, a static Linux build, and tmux for Linux tests`.

### Task 2: CanopyGit and the branch rules

**Interfaces:**
- Produces:
  - `public struct GitClone: Sendable { path: String; init(path:run:); static func local(path:executable:environment:) ; func run(_:timeout:) async throws -> String; func succeeds(_:) async -> Bool; func succeedsOnHost(_:) async throws -> Bool }`, where `run` gets git's arguments without `-C`.
  - `public struct BranchRules: Sendable { init(clone: GitClone); func requireValidName(_:) async throws; func existingBranch(_:under:) async throws -> String?; func defaultBranch() async throws -> String?; func defaultBase(hasOrigin:) async throws -> String; func startPoint(_:hasOrigin:) async throws -> String; func compare(_:with:named:resetTo:) async -> BranchReport; func goneUpstreamWarning(_:) async -> String?; func choose(_ requested: String, base: String?, existing: Bool, hasOrigin: Bool, fetchFailure: String?) async throws -> BranchChoice }`.
  - `public struct BranchChoice { branch, source: BranchSource, start: String?, notes, warnings, fastForward: FastForward?; func worktreeArguments(folder:) -> [String] }`.
  - `BranchError`: `invalidBranch`, `invalidBase`, `branchNotFound(name, fetchFailure:)`, which Core maps to its `WorkspaceError` cases of the same names and messages.
  - `GitError`, `Worktree`, `WorktreeListParser`, `BranchSlug`, `BranchSource`, `BranchReport`, `FastForward` move here, public.

Steps:

- [ ] Move `GitError`, `Worktree.swift`, and `BranchSlug.swift` into `CanopyGit` and re-export it from Core; `make test` passes: commit `refactor: CanopyGit holds git's errors, worktree lists, and branch slugs`.
- [ ] Write `CanopyGitTests/BranchRulesTests.swift` against real repos (a bare origin, a clone with `origin/HEAD`), each failing to build first:
  `aLocalBranchIsCheckedOut`, `aBranchOnlyOnOriginIsTracked`, `anythingElseStartsFromOriginsDefaultBranch`, `existingFailsForANewBranch`, `aBranchOnlyBehindIsFastForwarded`, `aDivergedBranchWarnsAndStays`, `theBranchsOwnSpellingWins`, `aGoneUpstreamWarns`, `aBadNameAndABadBaseFail`, and `withoutOriginItStartsFromHead`.
- [ ] Implement `GitClone` and `BranchRules` from the Workspace code, then make `Workspace`'s local and remote `row new` call `choose` and `worktreeArguments`, mapping `BranchError` to `WorkspaceError`.
  The remote path gains the local path's gone-upstream warning; `RepoGit` goes.
- [ ] `make test` and `make linux` pass: commit `refactor: one set of branch rules for local rows, remote rows, and canopy-box`.

### Task 3: Wire types the box shares

**Interfaces:**
- Produces in `CanopyWire`: `CanopyVersion`, `RelayRequest`, `RelayReply`, `RelayInput`, and `BoxProtocol.swift`:
  - `BoxMethod`: `hello`, `configure`, `subscribe`, `rowNew`, `rowRemove`, `paneNew`, `paneClose`, `send`, `keys`, `read`, `wait`, `seen`, `prs`, `adopt`, `release`.
  - `BoxHelloResult { version, protocolVersion, homeID }`.
  - `BoxConfig { host: String, repos: [String: String], agentCommand: String?, phonePort: UInt16? }`.
  - `BoxRow { path, repo, branch, head, isMain, missing, pr: Int? }`.
  - `BoxPane { id, rowPath, folder, foreground, title, busy, agent: AgentState, unseen, backgroundTasks, transcriptPath, prompt: OpenPrompt?, since: Date, lastLine: String? }`.
  - `BoxSnapshot { rows: [BoxRow], panes: [BoxPane] }`, the `box.snapshot` event.
  - Params and results: `BoxRowNewParams { repo, branch, base, existing }` / `BoxRowNewResult { row, source, base, notes, warnings }`, `BoxRowRemoveParams { path, force, deleteBranch }` / `{ warnings }`, `BoxPaneNewParams { rowPath, command, title }` / `{ pane }`, `BoxPaneCloseParams { pane }`, `BoxKeysParams { pane, keys: [String] }`, `BoxSeenParams { pane }`, `BoxPRsParams { prs: [String: Int] }` by row path, `BoxAdoptParams { rows: [BoxAdoptedRow], panes: [BoxAdoptedPane], nextPane: Int }` / `BoxAdoptResult { rows, panes, missing: [String] }`, `BoxReleaseResult { rows, panes, nextPane }`.
- Produces in `CanopyAgents`: `TermProtocol.swift`, the `term.*` methods' types and `AgentWaitTarget` moved from Core.
- `BranchSource` moves to `CanopyWire` so `BoxRowNewResult` can carry it; `CanopyGit` uses it from there.

Steps:

- [ ] Move the types, with no change in their JSON, and re-export; `make test` passes.
- [ ] Write `CanopyWireTests/BoxProtocolTests.swift`: each type round-trips, a snapshot from a newer daemon with an unknown field still decodes, and `BoxPane` leaves out `prompt`, `transcriptPath`, and `lastLine` when nil.
- [ ] Commit: `feat: the box's wire types, with the relay's and term's moved where canopy-box can use them`.

### Task 4: Unix sockets on both platforms

**Interfaces:**
- Produces in `CanopySystem`:
  - `public final class UnixListener: Sendable { init(path:accept:) throws; func close() }`: makes the folder the user's alone (0700), refuses a path a live server answers on (`UnixSocketError.alreadyRunning`), replaces a stale socket file, binds 0600, and calls `accept` with each connection on its own thread.
  - `public final class UnixConnection: Sendable { static func connect(path:timeout:) throws -> UnixConnection; func readLine(deadline:) throws -> Data?; func write(_:deadline:) throws; func waitForHangUp(until:) -> Bool; func close() }`, waiting in `poll`, as `SocketStream` does, and never raising SIGPIPE.
  - `UnixSocketError`: `pathTooLong`, `folderNotPrivate`, `alreadyRunning`, `failed(errno:)`, `timedOut`, `closed`.

Steps:

- [ ] Write `CanopySystemTests/UnixSocketTests.swift`: `echoesLinesBothWays`, `servesManyConnectionsAtOnce`, `theFolderAndSocketAreTheUsersAlone`, `aStaleSocketFileIsReplaced`, `aLiveServerIsNotReplaced`, `aTooLongPathFails`, `aReadPastItsDeadlineTimesOut`, `writingToAClosedPeerFailsWithoutSignal`, and `closingStopsAcceptingAndRemovesTheFile`.
- [ ] Implement with `#if canImport(Darwin)` only where the platforms differ (`SO_NOSIGPIPE` against `MSG_NOSIGNAL`, `sun_path`'s size, `accept4` through `CSystemShims`).
- [ ] `make test` and `make linux` pass: commit `feat: Unix sockets for canopy-box on macOS and Linux`.

### Task 5: tmux

**Interfaces:**
- Produces in `CanopyBoxKit`:
  - `public struct Tmux: Sendable { init(server: String, config: String?, environment: [String: String]) }` with `newSession(_ name:, folder:, environment:, command:) async throws`, `hasSession(_:) async -> Bool`, `killSession(_:) async`, `panes() async throws -> [TmuxPane]`, `capture(_:lines:escapes:) async throws -> String`, `sendText(_:to:) async throws` (`send-keys -l --`), `sendBytes(_:to:) async throws` (`send-keys -H`), and `paste(_:to:) async throws` (`load-buffer` from stdin into a buffer named for the pane, `paste-buffer -p -d`).
  - `TmuxPane { session, pid: Int32, command, folder, title }`, from `list-panes -a -F` with tabs, read with `-u`.
  - `TmuxError.failed(arguments:, message:)`; `panes()` returns `[]` when no server runs.

Steps:

- [ ] Write `CanopyBoxTests/TmuxTests.swift` with a `TmuxServer` test helper (a unique `-L` name, a temporary `TMUX_TMPDIR`, killed at the end):
  `aSessionStartsInItsFolderWithItsVariables`, `panesListEachSessionsCommandAndFolder`, `noServerMeansNoPanes`, `sentTextArrivesVerbatim` (a line with `'`, `"`, `$HOME`, `-n`, and the word `Enter`, then `cat` shows it unchanged), `bytesArriveExactly` (Escape and Control-C go in as keys), `aPasteIsBracketedAndWhole`, `captureReadsTheScreenOrTheLastLines`, and `killingASessionEndsIt`.
- [ ] Implement over `Subprocess.run` on its own thread, with a 10 s timeout on each tmux call.
- [ ] `make test` and `make linux` pass: commit `feat: canopy-box drives tmux`.

### Task 6: The daemon's files and state, rebuilt from git and tmux

**Interfaces:**
- Produces:
  - `public struct BoxPaths { init(root: String, homeID: String) }`, where `root` is the folder holding `.canopy`, normally `$HOME`: `home` (`<root>/.canopy/<id>`), `folder` (`.../box`), `socket`, `stateFile`, `configFile`, `busyFile`, `pending` (`.../pending`), `appSocket` (`.../app.sock`), `tmuxConf`, `worktrees(repo:)` (`<root>/.canopy/worktrees/<repo>`).
  - `BoxState: Codable { rows: [StoredRow], panes: [StoredPane], nextPane: Int, prs: [String: Int] }`, with `StoredPane { id, rowPath, folder, agent: PaneAgent, lastInput: Date }`, written through a temporary file and a rename, mode 0600.
  - `PaneAgent: Codable` in `CanopyAgents`, keeping every field, including when it last changed.
  - `public actor BoxDaemon { init(paths:, tmux:, git: (String) -> GitClone, clock:) ; func start() async; func snapshot() -> BoxSnapshot; func changes() -> AsyncStream<BoxSnapshot> }`, and `func adopt(_:) -> BoxAdoptResult`, `func release() -> BoxReleaseResult`.
  - `HostLayout`: the tmux server name, the relay socket and CLI paths, and `paneEnvironment(pane:rowName:repoName:host:rowPath:clone:hostHome:homeID:)`, moved from `HostPaths` and `RemoteAttach.environment`, which Core now calls.

Steps:

- [ ] Write `CanopyBoxTests/BoxStateTests.swift` with `BoxTestHome` (a temporary root, an origin, a clone registered as `repo`, and a tmux server):
  `eachCloneIsItsReposMainRow`, `aRestartKeepsPanesAndAgents`, `anUnknownWorktreeUnderTheFolderBecomesARow`, `aWorktreeOutsideTheFolderIsLeftOut`, `aSavedRowWhoseWorktreeIsGoneIsMissing`, `anUnknownSessionBecomesAPaneOfItsRow`, `aSavedPaneWhoseSessionIsGoneIsDropped`, `aDamagedStateFileIsRebuilt`, `theStateFileIsTheUsersAlone`, `adoptTakesRowsPanesAndTheNextNumber` (a session not on the server lands in `missing`), and `releaseHandsEverythingBack`.
- [ ] Implement `BoxPaths`, `BoxState`, `BoxDaemon.start()` (load `config.json` and `state.json`, list each repo's worktrees, list sessions, reconcile, save), `adopt`, and `release`.
  Changes to state publish a new snapshot to every `changes()` stream, at most every 100 ms.
- [ ] `make test` and `make linux` pass: commit `feat: canopy-box keeps its rows and panes, and rebuilds them from git and tmux`.

### Task 7: Rows

**Interfaces:**
- Produces: `BoxDaemon.rowNew(_ params: BoxRowNewParams) async throws -> BoxRowNewResult`, `rowRemove(_:) async throws -> [String]`, `rows() -> [BoxRow]`, each in the clone's queue, so two at once never race in one clone.
  Errors are `ControlError`s with the Mac's codes and messages: `repo_not_found`, `invalid_branch`, `invalid_base`, `branch_not_found`, `branch_checked_out`, `worktree_dirty`, `cannot_remove_main`, `row_not_found`.

Steps:

- [ ] Write `CanopyBoxTests/BoxRowsTests.swift`: `aNewRowGoesUnderTheWorktreesFolder` (slug `feat-x`, then `feat-x-2` beside a stray folder), `aRowForTheMainBranchSaysTheMainRowHasIt`, `twoRowsAtOnceBothLand`, `removingADirtyRowNeedsForce`, `theMainRowCannotBeRemoved`, `aMissingRowIsPrunedOnRemove`, `deleteBranchDeletesIt`, and `anUnknownRepoFails`.
- [ ] Implement with `BranchRules.choose`, a fetch with `--prune` and a 60 s timeout whose failure becomes a warning, `git worktree add`, the fast-forward once the row has the branch, and a `rowNew` snapshot.
- [ ] `make test` and `make linux` pass: commit `feat: canopy-box makes and removes rows by the Mac's branch rules`.

### Task 8: Panes

**Interfaces:**
- Produces: `BoxDaemon.paneNew(_:) async throws -> String`, `paneClose(_:) async throws`, `send(pane:text:enter:) async throws`, `keys(_:) async throws`, `read(pane:lines:) async throws -> String`, `wait(panes:for:timeout:) async throws -> (String, AgentState)`, `panes() -> [BoxPane]`, and a poll every 2 s that fills each pane's foreground, title, folder, and whether a program holds its terminal.
  `paneNew` names a pane `b<N>`, starts its session in the row's folder with `HostLayout.paneEnvironment` for the configured host, and types its command, if any, once the shell is up.

Steps:

- [ ] Write `CanopyBoxTests/BoxPanesTests.swift`: `newPanesCountUpFromTheSavedNumber`, `aPaneGetsTheVariablesARemotePaneGets`, `aPaneWithACommandRunsIt`, `sendTypesTextThenReturnApart` (Return reaches the program in a separate read, 200 ms later), `keysGoInOneAtATime`, `readGivesTheScreenOrTheLastLines`, `closingAPaneKillsItsSession`, `aPaneWhoseSessionEndsLeaves`, `thePollFillsForegroundTitleAndBusy`, `waitReturnsAPaneAlreadyThere`, `waitIgnoresAStateFromBeforeInput`, `waitFailsWhenThePaneCloses`, and `waitTimesOut`, each failing with the Mac's message.
- [ ] Implement.
- [ ] `make test` and `make linux` pass: commit `feat: canopy-box opens, drives, and reads panes in tmux`.

### Task 9: Agents, kept reports, and the busy file

**Interfaces:**
- Produces: `BoxDaemon.report(pane:_ report: AgentReport) -> AgentState?`, `seen(pane:)`, `setPRs(_:)`, `replayPending() async`, and `busyTicks()`, a loop that touches `busy` every 30 s while any pane's agent is working or background.
  Text sent or keys pressed into a pane go through `PaneAgent.typed`, as on the Mac.

Steps:

- [ ] Write `CanopyBoxTests/BoxAgentsTests.swift`: `aHookMovesThePanesAgent`, `anOlderHookIsIgnored`, `escapeClearsAWorkingAgent`, `seenClearsTheGreen`, `keptReportsReplayOnStartAndGoAway`, `aKeptReportForAnUnknownPaneIsDropped`, `workingKeepsTheBoxOn` (the file's time moves), `backgroundKeepsTheBoxOn`, and `waitingAndDoneDoNotKeepTheBoxOn`.
- [ ] Implement, saving state after each change that `since` or the agent's state moves.
- [ ] `make test` and `make linux` pass: commit `feat: canopy-box follows its panes' agents and keeps the box on while they work`.

### Task 10: The box's CLI

**Interfaces:**
- Produces:
  - `BoxCommands.run(_ request: RelayRequest, on daemon: BoxDaemon) async -> RelayReply?`: nil for a command the Mac answers.
    The box answers `agent-hook`, `row new` without `--on` or with `--on <host>` and without `--pr`, `row list`, `row rm`, and `term list|send|read|wait` for box panes.
    It parses them with swift-argument-parser, with the Mac CLI's options, and prints the Mac CLI's text, or JSON with `--json`, and its error lines (`error: <message>`, or `{"error": ...}` with `--json`).
    A row or pane given by name that is not the box's goes to the Mac.
  - `MacRelay.forward(_ request: RelayRequest, appSocket: String) async -> RelayReply`: the request to `app.sock` as the relay sends it, passing back the reply after the Mac's acknowledgement and heartbeats; with no socket, no answer, or no acknowledgement within 10 s, "This needs Canopy on the Mac, which isn't connected." and status 1.
  - The relay framing on `box.sock`, in Task 11's server: a relay request gets `{"ack": true}` at once, a heartbeat every 15 s, then its reply.

Steps:

- [ ] Write `CanopyBoxTests/BoxCommandsTests.swift`: `agentHookReportsAndPrintsNothing`, `hooksNeverLeaveTheBox` (a hook with no daemon pane still answers status 0 and sends nothing to a listening `app.sock`), `rowNewPrintsWhatTheMacPrints`, `rowNewOnLocalGoesToTheMac`, `rowListListsTheBoxsRows`, `termSendToAMacPaneGoesToTheMac`, `termWaitAnswersFromTheBox`, `jsonFailuresPrintAnErrorObject`, `aSilentMacFailsWithinTheWait`, `noMacSocketFailsAtOnce`, and `theMacsReplyComesBackWhole` (stdout, stderr, status, through a fake `app.sock` that acknowledges and beats).
- [ ] Implement.
- [ ] `make test` and `make linux` pass: commit `feat: canopy-box answers the box's CLI and passes the rest to the Mac`.

### Task 11: The server and `canopy-box serve`

**Interfaces:**
- Produces:
  - `BoxServer(daemon:, paths:)` on `UnixListener`: control requests for every `BoxMethod`, with `box.subscribe` sending a `box.snapshot` event at once and on each change, at most every 100 ms; relay requests as Task 10 says.
  - `canopy-box serve --home-id <id> [--root <folder>]`: starts the daemon, replays kept reports, serves, polls, ticks, and exits 0 on SIGTERM or SIGINT, removing its socket.

Steps:

- [ ] Write `CanopyBoxTests/BoxServerTests.swift`, in process over a real socket: `helloSaysItsVersionAndHome`, `configureIsSavedAndUsed`, `subscribeSendsTheSnapshotThenChanges`, `snapshotsComeAtMostEvery100ms`, `aHookThroughTheSocketReachesSubscribers`, `aBadLineGetsBadRequest`, and `adoptThenReleaseRoundTrips`.
- [ ] Write `CanopyBoxTests/BoxProcessTests.swift`, running the built `canopy-box`: `serveAnswersHelloAndStopsOnSIGTERM` and `aSecondServeOnOneHomeRefusesToStart`.
- [ ] Implement.
- [ ] `make test`, `make linux`, and `make box` pass: commit `feat: canopy-box serve`.

## Verification

- `make lint`, `make build` with no warnings, `make test` three times, `make linux`, `make box`, and `make e2e`.
- The built x86_64 binary runs `version` and `serve` in `ubuntu:24.04` under emulation, with `tmux` installed there, and answers `box.hello` through its socket.
- An opus review of the whole branch, its findings fixed, and an After Review section here.
- CI's `check` and `linux` jobs pass.

## After Review

An opus review of the whole branch found no critical issues and seven important ones, each fixed with a test that failed first (`BoxReviewTests`):

- A pane or row being made could be dropped or taken twice by a poll or reconcile whose listing came from before it.
  Panes and rows being made are now skipped by listings, only things known before a listing can be dropped by it, and the appends replace by id.
  Pinned by `aPollThatListedBeforeAPaneWasMadeKeepsIt`, `aPollDuringAPanesMakingDoesNotTakeItTwice`, and `aRowBeingMadeIsNeitherDoubledNorMissing`, which pause tmux or git in the gap.
- `term wait b1 b1` trapped on a duplicate dictionary key and killed the daemon; ids are now deduplicated (`aRepeatedPaneInAWaitIsFine`).
- Socket writes blocked threads of Swift's pool for up to a minute when the Mac stopped reading, and a write that timed out left half a line on a connection that stayed open.
  Each connection now writes on a queue of its own, and a write that fails or times out closes the connection (`aWriterNeverBlocksAndDropsAPeerThatStopsReading`).
- An agent whose program was killed, with no `SessionEnd` hook, stayed working and held the box on for good.
  The poll now ends a pane's agent when its shell gets the terminal back, as the Mac does (`anAgentWhoseProgramEndedWithoutAHookStops`).
- `term send` over about 16 KB failed, as tmux refuses a command that long; longer text now goes in as an unbracketed paste (`longTextArrivesWhole`).
- `row rm` killed programs running in the row's panes without `--force`; it now refuses with the Mac's `row_busy` message (`removingARowWithAProgramRunningNeedsForce`).
  This replaces Task 7's ruling.
- Two homes' daemons on one host adopted each other's worktrees in the shared `~/.canopy/worktrees/<repo>/`.
  Box rows now go in `~/.canopy/<home id>/worktrees/<repo>/`, and only that folder is adopted from git; the spec says so (`anotherHomesWorktreesAreLeftAlone`).

The fix to the writer also needed the server to drain a connection's writes before closing it, which `answersWhatCameBeforeTheClientClosedItsSide` caught.

Deferred minors, for 3b, which reworks the server's link anyway:

- Relay framing at the server is tested only for ack then reply: heartbeats, a hang-up cancelling a call, and a hook finishing after one are not pinned.
- `hungUp` peeks without draining, so a client that sends after its request spins the call's thread.
- `UnixListener` spins on descriptor exhaustion, where the Mac's relay server sleeps 100 ms.
- `serve` reconciles and saves state before learning another daemon holds the socket; bind first.
- Calls are not cancelled when the Mac disconnects fully, so a `box.wait` holds its thread until its timeout.
- `paneNew` types its command at once, without waiting for the shell, and a typing failure leaves the pane with an error returned.
- Rows of a repo taken out of `config.json` cannot be removed.
- After `release()`, the poll takes main-row sessions back within 2 seconds; harmless only while the service stops at once.
- A huge `box.wait` timeout traps in `Duration.seconds`.
- `ProcessInfo.hostName` may resolve DNS on first use, on the actor.
- `read` reports every tmux failure as `pane_not_found`.
- `row list --json` prints `BoxRow` on the box and `SidebarRow` on the Mac (ruled in Task 10).
- Interrupts typed through the Mac's `tmux attach` never reach the box's key rules; 3b's input path decides how.
