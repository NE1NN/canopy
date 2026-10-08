# Remote Rows, Milestone 1, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A registered repo can have rows whose worktree lives on an ssh host, with terminals in tmux on that host that survive the Mac sleeping, waking a stopped host, idle detach, and PR badges.

**Architecture:** A remote row is identified by a stand-in folder on the Mac and saved in its repo's `state.json` entry, so every path-keyed part of Canopy works unchanged.
A `HostConnection` actor per host owns one ssh master, its states, waking, and idle detach, and everything that talks to the host goes through that master.
A remote pane runs the hidden `canopy remote-attach` command, which asks the app for an ssh command, runs it into a tmux session on the host, and asks the app what to do when it ends.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing, SwiftUI, OpenSSH multiplexing, tmux 3.0+, Python 3 on the host.

**Spec:** `docs/superpowers/specs/2026-10-08-canopy-remote-rows-design.md`

## How this plan is written

This repo writes each plan's code blocks from the commits that implement it (see the PR 5 workflow in the project's notes).
This version fixes the files, the interfaces between tasks, and the tests each task must pass.
Each task's code blocks are filled in from its commit once it lands, so the plan in the merged branch shows the real code.

## Global Constraints

- Swift 6 language mode, strict concurrency, zero warnings, `make lint` clean.
- `make test`, never bare `swift test`.
- Unix socket paths must be under 104 bytes, including the terminator.
- Remote paths never go through `Paths.canonical`: this Mac's `/home` is a symlink.
- Nothing in tests or e2e reaches `hindie-box`. Only `scripts/e2e-remote.sh` does.
- Never quit or kill the release Canopy. Dev builds are killed by pid only.
- Markdown: one sentence per line, no em dashes.
- Commits: conventional prefixes, no Co-Authored-By trailers.
- `config.json` writes go through a temp file and a rename, keeping every other key.
- An older `state.json` or `config.json` without the new keys loads unchanged.

## Review Focus

1. A host that drops mid-command (git over ssh, probe, kill-session): every caller must fail with `host_unreachable` and leave state as it was, never hang. Pinned by a test in Task 6 with a stand-in ssh that exits 255 halfway.
2. Relaunching Canopy while a remote claude runs must reattach to the same tmux session, not start a new shell. Pinned by a restore test in Task 7 and an e2e step in Task 10.
3. Two Canopy homes (release and a dev build) on one host must not see each other's sessions. Pinned by a home id test in Task 3 and an e2e step that lists the tmux server's sessions in Task 10.
4. A remote row's branch switched by an agent on the host, and a worktree removed on the host by hand. Pinned by listing tests in Task 6 (branch follows, row turns missing).
5. Typing into a detached or reconnecting pane must not be lost into the void silently: only Return reconnects, and other keys are ignored with the prompt still shown. Pinned by a `remote-attach` loop test in Task 7.

---

## File Structure

New in `Sources/CanopyCore/Hosts/`:

| File | Responsibility |
|---|---|
| `HostConfig.swift` | `HostEntry`, `HostsConfig`: the `hosts` section of `config.json`, reading and atomic writing |
| `HostID.swift` | the Mac home's id, a host's hash, control and forward socket paths |
| `SSHCommand.swift` | building ssh argument lists: master, exec, tty attach, `-O` controls; shell quoting for remote commands |
| `HostConnection.swift` | per-host actor: master process, states, wake, retries, last use, idle detach |
| `HostConnectionClock.swift` | the clock and process launcher seams `HostConnection` takes, with real implementations |
| `HostFiles.swift` | the `canopy-host` script and `tmux.conf` as strings, their version, and installing them |
| `HostProbe.swift` | decoding `canopy-host probe` output into per-session activity |
| `HostChecks.swift` | what `host add` checks and the errors it maps to |
| `RemoteRow.swift` | `RemoteRowEntry` (saved), stand-in folders, `remote.json` |
| `RemoteAttach.swift` | `host.attach` and `host.next` params and results, the tmux command for a pane |

New elsewhere:

| File | Responsibility |
|---|---|
| `Sources/CanopyCore/Workspace/Workspace+Hosts.swift` | hosts in the workspace: add, list, remove, connections by alias |
| `Sources/CanopyCore/Workspace/Workspace+RemoteRows.swift` | create, list, remove remote rows |
| `Sources/CanopyCore/Control/HostMethods.swift` | `host.*` method names and params |
| `Sources/CanopyCLI/HostCommand.swift` | `canopy host add/list/rm` |
| `Sources/CanopyCLI/RemoteAttachCommand.swift` | the hidden `canopy remote-attach` loop |
| `Sources/CanopyApp/Sidebar/RemoteMark.swift` | the server mark and host name after a remote row |
| `scripts/fake-ssh` | stand-in ssh for e2e and tests: runs commands locally under a fake host home |
| `scripts/e2e-remote.sh` | the same steps against a real host |

Modified:

| File | Change |
|---|---|
| `Rows/Row.swift` | `RowClass.remote`, `Row.host`, `Row.remotePath` |
| `State/AppState.swift` | `RepoEntry.remote`, `AppState.pendingSessionKills` |
| `Workspace/Workspace.swift` | refresh merges remote rows; reconcile keeps them |
| `Workspace/Workspace+RowLifecycle.swift`, `Workspace+Branches.swift` | branch helpers take a `RepoGit` so remote creation reuses them |
| `Git/GitRunner.swift` | an ssh transport |
| `Workspace/Workspace+PullRequests.swift` | remote branches join lookups; a head change looks the PR up again |
| `Terminal/TerminalIDs.swift` | `PaneContext.remote` |
| `Terminal/TerminalEmulator.swift` | `PaneCommand.remoteAttach` |
| `Terminal/Pane.swift` | remote session name, remote activity, `run` through send-keys |
| `Terminal/TerminalStore.swift` | make remote panes, save and restore their sessions, `ensureTab` for stand-ins |
| `State/SavedTerminals.swift` | `SavedPane.session` |
| `Rows/RowLifecycle.swift` | remote rows: no setup, removal through the workspace |
| `Control/WorkspaceControlHandler.swift`, `Control/ControlMethods.swift` | `row.new` `host`, `host.*` routing |
| `CanopyCLI/RowCommand.swift`, `CanopyCLI/AgentGuide.swift`, `CanopyCLI/CanopyCLI.swift` | `--on`, guide section, new commands |
| `CanopyApp/AppModel.swift` | host connections' probe loop, idle tracking, close kills sessions |
| `CanopyApp/Sidebar/NewRowSheet.swift`, sidebar row views | Where pop-up, remote mark |
| `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `Makefile` | fake host steps, a remote row in the fixture, tmux check |

---

### Task 1: Hosts config

**Files:**
- Create: `Sources/CanopyCore/Hosts/HostConfig.swift`
- Test: `Tests/CanopyCoreTests/HostConfigTests.swift`

**Interfaces:**
- Produces:
  - `public struct HostEntry: Codable, Sendable, Equatable { var repos: [String: String]; var wake: String?; var idleDetachMinutes: Int }`, where `idleDetachMinutes` defaults to 30 and a negative value reads as 30.
  - `public struct HostsConfig: Sendable, Equatable { var hosts: [String: HostEntry]; var warnings: [String] }`
  - `public static func HostsConfig.load(from file: URL) -> HostsConfig`, which leaves out a host whose section cannot be read and adds a warning naming it.
  - `public struct HostsConfigFile { init(url: URL); func save(_ alias: String, _ entry: HostEntry) throws; func remove(_ alias: String) throws }`, writing through `JSONFile.update`.
  - `HostEntry.clonePath(forRepo name: String, repoPaths: [String]) -> String?`, matching names the way the Tickets plugin's `repo` does.

- [ ] **Step 1: Write the failing tests**
  - a full section decodes; a missing `idleDetachMinutes` is 30; 0 stays 0;
  - one malformed host is skipped with a warning while another loads;
  - no `hosts` key, no file, and unreadable JSON each give no hosts;
  - `save` keeps `plugins` and unknown keys byte-for-byte in order, and `remove` drops only that host;
  - `clonePath` matches `solis-v1` exactly and `web-app` against a repo at `code/web-app`.
- [ ] **Step 2: Run them, expect compile failures**: `make test`
- [ ] **Step 3: Implement `HostConfig.swift`**
- [ ] **Step 4: `make test` passes, `make lint` clean**
- [ ] **Step 5: Commit** `feat: hosts section in config.json`

### Task 2: Remote rows in state and the snapshot

**Files:**
- Create: `Sources/CanopyCore/Hosts/RemoteRow.swift`
- Modify: `Rows/Row.swift`, `State/AppState.swift`, `Workspace/Workspace.swift`, `Workspace/WorkspaceSnapshot.swift`
- Test: `Tests/CanopyCoreTests/RemoteRowStateTests.swift`

**Interfaces:**
- Consumes: none.
- Produces:
  - `RowClass.remote`, `Row.host: String?`, `Row.remotePath: String?` (encoded as `host`, `remotePath`, omitted when nil).
  - `public struct RemoteRowEntry: Codable, Sendable, Equatable { var host: String; var path: String; var standIn: String; var branch: String?; var head: String?; var missing: Bool }`.
  - `RepoEntry.remote: [RemoteRowEntry]`, decoded leniently like `groups`.
  - `CanopyHome.remoteRoot` (`CANOPY_HOME/remote`), `RemoteRowEntry.makeStandIn() throws`, which creates the folder with mode 0700 and writes `remote.json`.
  - `Row(remote: RemoteRowEntry, repoPath: String)`.
  - In `refreshNow`, the snapshot's rows gain the entry's remote rows (class `.remote`, not missing unless the entry says so), `managed` includes their stand-ins, so `reconcile` keeps them in `rowOrder` and groups.
  - `Workspace.remoteRow(standIn:) -> RemoteRowEntry?` and `Workspace.remoteRow(host:path:) -> RemoteRowEntry?`.

- [ ] **Step 1: Write the failing tests**
  - an old `state.json` without `remote` loads with none;
  - a repo with a remote entry lists it after the main row, with class `remote`, `host`, and `remotePath`;
  - a refresh of the local repo (git lists only local worktrees) keeps the remote row in `rowOrder` and in its group;
  - `move` before and after a remote row, and into a group, works;
  - a stand-in deleted from disk is made again by `makeStandIn`, and `remote.json` names the host and path;
  - `holder(of:)` for a local branch ignores a remote row on the same branch.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `make test`, `make lint`**
- [ ] **Step 5: Commit** `feat: remote rows in state and the sidebar's snapshot`

### Task 3: Host ids, socket paths, ssh commands, git over ssh

**Files:**
- Create: `Sources/CanopyCore/Hosts/HostID.swift`, `Sources/CanopyCore/Hosts/SSHCommand.swift`
- Modify: `Sources/CanopyCore/Git/GitRunner.swift`
- Create: `scripts/fake-ssh`
- Test: `Tests/CanopyCoreTests/SSHCommandTests.swift`, `Tests/CanopyCoreTests/RemoteGitTests.swift`

**Interfaces:**
- Produces:
  - `public struct HomeID { static func of(home: CanopyHome, machine: String) -> String }`, 8 lowercase hex digits of SHA-256 of `"<machine>\n<home path>"`.
  - `public enum HostPaths { static func controlSocket(home:homeID:alias:) -> String; static func hostSocket(home:alias:) -> String; static func remotePaneSocket(uid:homeID:pane:) -> String; static func tmuxServer(homeID:) -> String }`; the first two fall back to `/tmp/canopy-<uid>/` when the home's path would make them 104 bytes or longer.
  - `public struct SSHCommand { var executable: String; var controlPath: String; var alias: String }` with `master() -> [String]`, `exec(_ remote: [String]) -> [String]`, `attach(_ remote: [String], forwards: [(remote: String, local: String)]) -> [String]`, `control(_ op: String) -> [String]`, and `static func shellQuoted(_ words: [String]) -> String`.
  - `SSHCommand.executable` is `/usr/bin/ssh` unless `CANOPY_SSH` names another, which only e2e and tests set.
  - `GitRunner.remote(_ ssh: SSHCommand, timeout: Duration?)`: `run(args, in: dir)` runs `git -C <dir> <args>` on the host through `ssh.exec`; an ssh exit of 255 becomes `GitError` with `hostUnreachable` set.
  - `scripts/fake-ssh`: takes the same options as ssh; `-M -N` writes the control socket path as a plain file and sleeps until killed; `-O check|exit|forward` act on that file; anything else runs the remote command with `sh -c` under `HOME=$FAKE_SSH_HOME`, after `cd $FAKE_SSH_HOME`; `-t` allocates nothing extra, since the pty is already the caller's; `-R remote:local` symlinks remote to local; `FAKE_SSH_DOWN=1` makes every call exit 255 with "Connection closed".

- [ ] **Step 1: Write the failing tests**
  - home ids differ for two homes and for two machines, and are stable;
  - control socket paths stay under 104 bytes for a home 200 characters long;
  - `shellQuoted` round-trips names with spaces, quotes, `$`, and newlines through `sh -c 'printf "%s\n" …'`;
  - `master()` has `-M -N -o ControlPersist=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -S <path>`; `exec` and `attach` use `-o ControlMaster=no`, `-S <path>`, and `--`; `attach` adds `-t` and `-R`;
  - `GitRunner.remote` through `scripts/fake-ssh` runs `rev-parse --show-toplevel` in a temp clone under the fake home;
  - `FAKE_SSH_DOWN=1` gives `hostUnreachable`.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `make test`, `make lint`**
- [ ] **Step 5: Commit** `feat: ssh commands and git over ssh`

### Task 4: Host connections

**Files:**
- Create: `Sources/CanopyCore/Hosts/HostConnection.swift`, `Sources/CanopyCore/Hosts/HostConnectionClock.swift`
- Test: `Tests/CanopyCoreTests/HostConnectionTests.swift`

**Interfaces:**
- Consumes: `SSHCommand`, `HostEntry`.
- Produces:
  - `public enum HostState: String, Codable, Sendable { case idle, connecting, waking, connected, unreachable, detached }`
  - `public actor HostConnection` with:
    - `init(alias:entry:ssh:launcher:clock:activity:)`
    - `func connect() async throws`: starts the master if needed, waking and retrying per the spec; throws `WorkspaceError.hostUnreachable(alias, reason)` after 5 minutes.
    - `var state: HostState`, `var lastError: String?`, `func states() -> AsyncStream<HostState>`
    - `func used()`: marks a use for the 10-minute stop.
    - `func panesActive(attached: Int, busy: Bool, lastInput: Date)`: what the app reports every probe, which drives idle detach.
    - `func detach()`: stops the master and sets `.detached`.
    - `func stop()`: stops the master for good, at quit.
    - `func run(_ remote: [String], stdin: Data?, timeout: Duration) async throws -> SubprocessResult`: one command through the master, after `connect()`.
  - `protocol HostProcessLauncher: Sendable { func startMaster(_ argv: [String]) -> HostMasterProcess; func run(_ argv: [String], stdin: Data?, timeout: Duration?) async -> SubprocessResult; func runWake(_ command: String) async -> SubprocessResult }`, with the real one using `Subprocess`, and wake run through the login shell like `GitEnvironment` builds its PATH.
  - `protocol HostClock: Sendable { var now: ContinuousClock.Instant { get }; func sleep(for: Duration) async throws }`, with `TestHostClock` in `Tests/CanopyCoreTests/Support/`.
  - Master readiness is `ssh -O check` succeeding, polled every 200 ms for 20 s.

- [ ] **Step 1: Write the failing tests** (fake launcher, test clock)
  - `connect` starts one master for two concurrent callers;
  - a master that fails runs `wake` once, retries every 10 s, connects when the launcher starts succeeding, and logs `host.woken` then `host.connected`;
  - a second failure within 2 minutes does not run `wake` again;
  - after 5 minutes of failures `connect` throws `hostUnreachable`, the state is `unreachable`, and `host.unreachable` is logged with ssh's message;
  - no `wake` configured: no wake, same retries;
  - 10 minutes with no `used()` and zero attached panes stops the master and goes `idle`;
  - attached panes, not busy, no input for `idleDetachMinutes`: `detach` happens and logs `host.detached`; busy or recent input resets the timer; `idleDetachMinutes` 0 never detaches;
  - a master that exits on its own goes back to `idle`, and the next `connect` starts a new one.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `make test`, `make lint`**
- [ ] **Step 5: Commit** `feat: one ssh master per host, with waking and idle detach`

### Task 5: Host files, checks, and `canopy host`

**Files:**
- Create: `Sources/CanopyCore/Hosts/HostFiles.swift`, `Sources/CanopyCore/Hosts/HostChecks.swift`, `Sources/CanopyCore/Hosts/HostProbe.swift`, `Sources/CanopyCore/Workspace/Workspace+Hosts.swift`, `Sources/CanopyCore/Control/HostMethods.swift`, `Sources/CanopyCLI/HostCommand.swift`
- Modify: `Control/WorkspaceControlHandler.swift`, `Control/ControlMethods.swift`, `CanopyCLI/CanopyCLI.swift`, `Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/HostFilesTests.swift`, `Tests/CanopyCoreTests/HostProbeTests.swift`, `Tests/CanopyCoreTests/HostControlTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces:
  - `HostFiles.script` (the `canopy-host` Python 3 source, with `probe` only in this milestone; `relay` and `replay` come in milestone 2), `HostFiles.tmuxConf`, `HostFiles.version` (`CanopyVersion.current` plus a content hash), and `HostFiles.installCommand() -> [String]`, a remote `sh -c` that writes both files under `~/.canopy`, links `~/.canopy/bin/canopy-host`, and writes `~/.canopy/files-version`.
  - `canopy-host probe --server <name>` prints one JSON object: `{"sessions": [{"name", "pid", "foreground", "busy", "folder", "title"}]}`, built from `tmux -L <name> list-panes -a -F` and `ps -A -o pid=,tpgid=,comm=`, so it runs on Linux and on the Mac fake host alike. No server prints `{"sessions": []}`.
  - `HostProbe.decode(_ data: Data) throws -> [String: SessionActivity]` keyed by session name, with `SessionActivity { busy: Bool; foreground: String?; folder: String?; title: String? }`.
  - `HostChecks.run(on: HostConnection, repos: [String: String]) async throws -> [String: String]`, resolving `~/` paths to absolute and failing with `host_unknown`, `host_unfit`, or `repo_not_found` as the spec's error table says.
  - Methods `host.add` (`HostAddParams { alias, repos: [String: String], wake: String?, idleDetachMinutes: Int? }`), `host.list`, `host.remove`, plus `HostInfo { alias, state, repos, rows, panes, error }`.
  - `Workspace.connection(for alias: String) -> HostConnection?`, made from config when first asked.
  - `host.add` also installs the files when the version on the host differs, which `connect()` repeats on each new master.
  - CLI: `canopy host add <alias> --repo <name>=<path>... [--wake <cmd>] [--idle-detach <min>] [--json]`, `canopy host list [--json]`, `canopy host rm <alias>`.
  - Activity: `host.added`, `host.removed`.
  - Writing Canopy's hooks into the host's Claude Code settings waits for milestone 2, which brings the relay they call.

- [ ] **Step 1: Write the failing tests**
  - `HostFiles.script` compiles with `python3 -m py_compile`, and `probe` against a tmux server started in the test on a private socket name lists a session, its folder, and `busy` true while `sleep 30` runs in it and false after; skipped with a note when tmux is missing;
  - `HostProbe.decode` reads the fixture output and an empty server;
  - `host.add` through the fake host: missing tmux (a PATH without it) fails `host_unfit` naming tmux; a clone path that is not git fails `repo_not_found`; an unregistered repo name fails `repo_not_found` listing the registered repos; success writes config, installs files, logs `host.added`;
  - `host.add` again updates repos without duplicating;
  - `host.remove` refuses while the host has rows, naming them;
  - `host.list` shows `idle` for a host nothing has used.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `make test`, `make lint`**
- [ ] **Step 5: Commit** `feat: canopy host add, list, and rm`

### Task 6: Creating, listing, and removing remote rows

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+RemoteRows.swift`
- Modify: `Workspace+RowLifecycle.swift`, `Workspace+Branches.swift`, `Workspace+PullRequests.swift`, `Workspace.swift`, `Rows/RowLifecycle.swift`, `Control/WorkspaceControlHandler.swift`, `CanopyCLI/RowCommand.swift`
- Test: `Tests/CanopyCoreTests/RemoteRowTests.swift`

**Interfaces:**
- Consumes: Tasks 2 to 5.
- Produces:
  - `struct RepoGit { var git: GitRunner; var path: String }`: `existingBranch`, `compare`, `goneUpstreamWarning`, `startPoint`, `isValidBranchName`, `defaultBranch`, and the fetch take one, so local and remote creation share the branch rules.
  - `Workspace.createRemoteRow(repoPath:host:branch:base:existing:group:) async throws -> CreatedRow`: fetch on the host, choose the branch as locally, `git worktree add` under `<host home>/.canopy/worktrees/<dirName>/<slug>` avoiding existing folders (checked with one `ls` through the master), fast-forward in the new worktree when only behind, make the stand-in, save the entry, and place it in the order or group.
  - A branch held by a remote row on the same host fails with `branch_checked_out`; a local row on that branch does not block.
  - `Workspace.refreshRemote(repoPath:host:)`: reads `git worktree list --porcelain -z` in the host's clone and updates branch, head, and missing for that host's rows, logging `row.branchChanged` with `host`; it runs after each remote change and every 30 s while the host is `connected`.
  - `Workspace.removeRemoteRow(standIn:force:deleteBranch:) async throws -> [String]`: dirty check, `worktree remove`, forget, stand-in to `FolderTrash`, optional branch delete; `host_unreachable` without `force`, and with `force` forgets the row and warns that the host's worktree stayed.
  - `RowLifecycle.prepare` skips setup for `.remote` rows and returns a note when the remote branch has `.canopy/config.json`; `RowLifecycle.remove` sends `.remote` rows to `removeRemoteRow` after closing their terminals.
  - `row.new` gains `host: String?`; `RowNewResult` and `row list --json` gain `host` and `remotePath`.
  - CLI: `canopy row new <branch> --on <host>`.
  - PR lookups include remote rows' branches, and a head or branch change found by `refreshRemote` queues a lookup.
  - Errors: `host_not_found`, `host_has_no_repo` (naming hosts that have it), `host_unreachable`.

- [ ] **Step 1: Write the failing tests** (fake host: a bare origin, the host's clone in the fake home, the local clone registered)
  - a new branch is made from origin's default branch on the host, the row appears with class `remote` and the stand-in, and `remote.json` is written;
  - an existing origin branch is tracked; an existing host-local branch only behind origin is fast-forwarded, with the note;
  - a branch held by another remote row on that host fails `branch_checked_out`; the same branch held by a local row succeeds;
  - `--group` places the row in the group;
  - `refreshRemote` after `git switch -c other` in the host worktree changes the row's branch and logs it;
  - `refreshRemote` after `git worktree remove` on the host marks the row missing;
  - a fake ssh that dies on the second call during `createRemoteRow` fails `host_unreachable` and saves no entry;
  - removing a dirty row fails `worktree_dirty`; with `--force` it goes and the stand-in is in the run's trash folder;
  - removing with the host down fails `host_unreachable`; with `--force` it forgets the row and warns;
  - PR branches for the repo include the remote row's branch.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement**, refactoring the branch helpers onto `RepoGit` first with the existing tests green.
- [ ] **Step 4: `make test`, `make lint`**
- [ ] **Step 5: Commit** `feat: remote rows made, listed, and removed over ssh`

### Task 7: Remote panes

**Files:**
- Create: `Sources/CanopyCore/Hosts/RemoteAttach.swift`, `Sources/CanopyCLI/RemoteAttachCommand.swift`
- Modify: `Terminal/TerminalIDs.swift`, `Terminal/TerminalEmulator.swift`, `Terminal/Pane.swift`, `Terminal/ShellSettings.swift`, `Terminal/TerminalStore.swift`, `State/SavedTerminals.swift`, `State/AppState.swift`, `Control/WorkspaceControlHandler.swift`, `Rows/RowLifecycle+Terminals.swift`
- Test: `Tests/CanopyCoreTests/RemotePaneTests.swift`, `Tests/CanopyCoreTests/RemoteAttachTests.swift`

**Interfaces:**
- Consumes: Tasks 3 to 6.
- Produces:
  - `PaneContext.remote: RemoteTarget?` with `RemoteTarget { host: String; path: String; clone: String }`, set from a `.remote` row.
  - `PaneCommand.remoteAttach`, which `ShellSettings` launches as `<cli> remote-attach` in the stand-in folder with the usual pane variables.
  - `Pane.remoteSession: String` (`p<number>` at creation, kept through restore), `Pane.remoteActivity: SessionActivity?` (set by the app from the probe), and `isBusy`, `currentDirectory`, and the title fallback reading it for remote panes.
  - `SavedPane.session: String?`; `restore` gives remote panes their saved session and folder.
  - `TerminalStore.ensureTab` opens a remote row's tab when its stand-in exists.
  - `host.attach` (`{pane}` to `{ready: {argv}}` or `{waiting: {message}}` after at most 5 s) and `host.next` (`{pane, status}` to `{action: "reconnect" | "end" | "waitForReturn", message}`), answered by the workspace control handler through the pane's host connection.
  - `RemoteAttach.tmuxCommand(homeID:session:folder:environment:) -> [String]`: `tmux -L canopy-<id> -f ~/.canopy/tmux.conf new-session -A -s <session> -c <folder>` with `-e` for each variable the spec's table lists, apart from the relay's two (milestone 2).
  - `canopy remote-attach`: calls `host.attach` until ready, printing each new waiting message dimmed; runs ssh as a child in the foreground; calls `host.next` with its exit status; on `waitForReturn` prints the message and reads the tty until Return, ignoring other input; loops.
  - `Pane.run(_:)` for remote panes waits for the session to show in the probe, then sends `tmux send-keys -t <session> -l <text>` and `Enter` through the master.
  - Closing a remote pane kills its session through the master; a kill that cannot reach the host is saved in `AppState.pendingSessionKills[alias]` and done on the next connect.

- [ ] **Step 1: Write the failing tests**
  - a remote row's new pane gets `PaneCommand.remoteAttach`, `remoteSession` `p<n>`, and the stand-in as its directory;
  - `saved()` then `restore` keeps the session name and the folder the probe last gave;
  - `isBusy` follows `remoteActivity.busy`; a probe that no longer lists the session clears it;
  - `tmuxCommand` quotes folders with spaces, and its environment has `CANOPY_ROW_PATH` as the remote path and no `CANOPY_HOME` or `ZDOTDIR`;
  - `host.next` maps exit 0 to `end`, 255 while the host is `detached` to `waitForReturn` with the detach message, 255 otherwise to `reconnect`, and an unreachable host to `waitForReturn` with ssh's message;
  - the attach loop, driven with a fake client and a fake tty, prints waiting messages once each, ignores keys other than Return while waiting, and reconnects on Return;
  - closing a pane while the host is down records a pending kill, and the next connect runs it.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `make test`, `make lint`**
- [ ] **Step 5: Commit** `feat: remote panes in tmux on the host`

### Task 8: The app drives hosts

**Files:**
- Modify: `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyCore/Rows/RowLifecycle+Agents.swift` (only if the agent clearing needs the remote busy flag)
- Test: `Tests/CanopyCoreTests/HostActivityTests.swift`

**Interfaces:**
- Consumes: Tasks 4, 5, 7.
- Produces:
  - `HostActivityTracker` in CanopyCore (pure, tested): given the host's panes (busy, lastInput) and probe results, reports `panesActive` values and which panes' `remoteActivity` changed.
  - In `AppModel`: a task per connected host that probes every 2 s, applies results to panes, reports `panesActive`, runs `refreshRemote` every 30 s, and runs pending session kills after each connect; the tasks stop when the host leaves `connected`.
  - At quit, `HostConnection.stop()` for every host, after terminals close, so sessions on hosts only detach.

- [ ] **Step 1: Write the failing tests** for `HostActivityTracker`: busy pane keeps activity, idle panes with old input report idle, a typed key resets, panes of other hosts are ignored.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement the tracker and wire it in `AppModel`**
- [ ] **Step 4: `make test`, `make lint`, `make build` with 0 warnings**
- [ ] **Step 5: Commit** `feat: the app probes hosts and detaches idle ones`

### Task 9: Window and agent guide

**Files:**
- Create: `Sources/CanopyApp/Sidebar/RemoteMark.swift`
- Modify: `Sources/CanopyApp/Sidebar/NewRowSheet.swift`, the sidebar row view for worktree rows, `Sources/CanopyCore/Rows/NewRowPicker.swift` (the command line with `--on`), `Sources/CanopyCLI/AgentGuide.swift`
- Test: `Tests/CanopyCoreTests/NewRowPickerTests.swift` (the `--on` command)

**Interfaces:**
- Consumes: Tasks 5, 6.
- Produces:
  - The server mark (`server.rack`, secondary color) and host name after a remote row's name; help text `On <host>: <remote path>`.
  - The New Row sheet's Where pop-up, shown only when some host has the repo, defaulting to the repo's last choice kept in `UserDefaults` under `newRow.where.<repo path>`, and the primary button's help showing `canopy row new … --on <host>`.
  - The agent guide's Remote Rows section.

- [ ] **Step 1: Write the failing picker test** for the `--on` command text.
- [ ] **Step 2: Run, expect failure**
- [ ] **Step 3: Implement the views and guide**
- [ ] **Step 4: `make test`, `make lint`, `make build`**
- [ ] **Step 5: UI check** with `scripts/ui-fixture.sh` light and dark: window shots of a remote row, its hover help, and the Where pop-up open
- [ ] **Step 6: Commit** `feat: remote rows in the sidebar and the New Row sheet`

### Task 10: End to end

**Files:**
- Modify: `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `Makefile`
- Create: `scripts/e2e-remote.sh`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `make e2e` checks for tmux and says `brew install tmux` when it is missing.
  - e2e steps on the fake host:
    - `host add` (and its failures);
    - `row new --on` with `--run 'echo remote-$((40 + 2))'` and waiting for `remote-42` in `term read`;
    - `term send` into the remote pane;
    - the tmux server's session named after the pane;
    - stopping the dev app and starting it again, then reading the same session's earlier output (reattached, not new);
    - `FAKE_SSH_DOWN=1` making the pane print the reconnecting message and recover when unset;
    - idle detach with `--idle-detach` set low through a dev-only seconds override `CANOPY_IDLE_DETACH_SECONDS`;
    - a release home and a second home on the same fake host not seeing each other's sessions;
    - `row rm` killing the session and moving the stand-in to the run's trash folder.
  - `scripts/ui-fixture.sh` adds a fake host with one remote row.
  - `scripts/e2e-remote.sh <alias>`: the same steps against a real host on a throwaway dev home and a throwaway branch `canopy-e2e/<timestamp>`, plus `claude --version` run in a remote pane, a pushed branch's PR badge when `--with-pr <repo>` is given, and waking with the host stopped when `--stop-first` is given. It removes its row and branch at the end.

- [ ] **Step 1: Write the e2e steps**
- [ ] **Step 2: `make e2e` passes**
- [ ] **Step 3: `scripts/e2e-remote.sh hindie-box` passes**
- [ ] **Step 4: Commit** `test: remote rows end to end`

### Task 11: Merge bar for the milestone

- [ ] `make lint`, `make build` with 0 warnings, `make test` three clean runs on a quiet machine (load under the core count).
- [ ] `make e2e` and `scripts/e2e-remote.sh hindie-box`.
- [ ] Hand-check on the real box with a dev build: a remote row of solis-v1, `claude --full` in it, close the lid (or kill the master), reopen and see the same session.
- [ ] An independent opus reviewer on `git diff main...HEAD` with the spec and this plan; fix findings with tests and add an After Review section here.
- [ ] Fill this plan's code blocks from the commits.
