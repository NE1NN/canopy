# Canopy on the box, Milestone 2: Portable Code

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The code `canopy-box` will share with the Mac (agent states from hooks, transcripts, answer keys, the phone server, subprocesses, and TCP) moves into modules that build and pass their tests on Linux, with no change in what the Mac app does.

**Architecture:** Three new library targets, each with only Foundation, Dispatch, Synchronization, and libc beneath it:
`CanopySystem` (subprocesses, the blocking-work thread, lines, and POSIX TCP), `CanopyAgents` (hook mapping, `PaneAgent`, transcripts, answer keys), and `CanopyServer` (the phone server, reaching rows and panes through a `PhoneSource` protocol).
`CanopyCore` depends on all three and re-exports them, so the app and CLI change no imports, and keeps the Mac's side: `MacPhoneSource` over `TerminalStore` and `WorkspaceSnapshot`, `NWPathMonitor`, and the Tailscale app's CLI.
On Linux, `Package.swift` declares only the portable targets, so `swift build` and `swift test` there build nothing that needs macOS.
`make linux` runs both in the `swift:6.4` image, and CI gains a `linux` job that does the same.

**Tech Stack:** Swift 6.4, Swift Testing, swift-crypto 3, Docker `swift:6.4`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-13-canopy-box-server-design.md`, "Shared code" and Delivery item 2.

## Global Constraints

- No change in behaviour on the Mac: every existing test passes unchanged except for moved files and imports, and `make e2e` and the phone's screen tour pass.
- The portable targets import only Foundation, Dispatch, Synchronization, `Crypto` (swift-crypto), CanopyWire, and each other; libc through `#if canImport(Darwin)`, `Glibc`, or `Musl`.
- Swift 6 language mode, strict concurrency, no warnings on either platform.
- `CanopyCore` re-exports the new modules with `@_exported import`, as it does `CanopyWire`.
- Markdown: one sentence per line, no em dashes.
  Conventional commits, no trailers.

## Rulings carried from the spec

- The spec names two modules; a third, `CanopySystem`, holds what both need from the operating system, so neither depends on the other for it.
- The branch rules `row new` uses stay in `CanopyCore` until milestone 3, where `canopy-box` first needs them; moving them now would mean abstracting `Workspace`'s git with nothing yet on the other side.
- `SocketStream` and the control socket's client and server stay on the Mac until milestone 3, for the same reason.

## Review Focus

1. A child process that exits before the Linux wait starts watching it must still be seen as exited, never waited on until the timeout.
   Pinned by `aChildThatExitsAtOnceIsNotWaitedOn` in Task 1.
2. A descriptor the parent has open must not leak into a child on Linux, which has no `POSIX_SPAWN_CLOEXEC_DEFAULT`.
   Pinned by `aChildInheritsNoDescriptors` in Task 1.
3. A phone that closes its side mid-line must get answers to what it sent before, then the connection closes, as with Network.framework.
   Pinned by `answersWhatCameBeforeThePhoneClosedItsSide` (existing, moved) in Task 4.
4. Binding the same address and port again right after the last listener closed must work, as `allowLocalEndpointReuse` did.
   Pinned by `bindsAgainAtOnceAfterClosing` in Task 3.
5. A write to a phone that stopped reading must not block other phones or the listener.
   Pinned by `aStalledReaderBlocksNoOtherConnection` in Task 3.

## File Structure

New targets and where their files come from:

| Target | Files |
|---|---|
| `CanopySystem` | `Subprocess.swift` (from `CanopyCore/Support`, with a Linux path), `OwnThread.swift` (public), `LineBuffer.swift` (from `CanopyCore/Control`, public), `TCP.swift` (new: `TCPListener`, `TCPConnection`, `TCPOptions`), `Libc.swift` (the platform's libc names) |
| `CanopyAgents` | `ClaudeHookMapping.swift` (without `AgentHook` and `AgentHookRequest`, which stay in `CanopyCore/Agents/AgentHook.swift`), `PaneAgent.swift`, `TranscriptParser.swift`, `TranscriptReader.swift`, `TranscriptFollower.swift`, `TranscriptTails.swift`, `PhoneAnswerKeys.swift` |
| `CanopyServer` | `PhoneRegistry.swift`, `PhoneConnection.swift`, `PhoneListener.swift`, `PhoneStreams.swift` (without `ScreenWatcher`), `PhoneService.swift` (the portable core), `PhoneSource.swift` (new), `PhoneEnvironment.swift` (new) |
| `CanopyCore` keeps | `Phone/MacPhoneSource.swift` (from `PhoneHub`, `PhonePanes`, `PhoneInboxBuilder`, `ScreenWatcher`), `Phone/MacPhoneEnvironment.swift` (the path monitor, `utun` addresses, the Tailscale CLI, the activity log) |
| Tests | `CanopySystemTests` (`SubprocessTests`, `TCPTests`, `LineBufferTests` if any), `CanopyAgentsTests` (`PaneAgentTests`, `AgentPromptTests` minus its `TermStateParams` part, `PhoneAnswerKeysTests`, `TranscriptReaderTests` with `Fixtures/Transcripts`, `TranscriptFollowerTests`, the mapping part of `ClaudeHookTests`), `CanopyServerTests` (`PhoneRegistryTests`, `PhoneListenerTests` with a portable test client, plus a `FakePhoneSource`) |

Modified: `Package.swift`, `Sources/CanopyCore/Exports.swift`, `Makefile` (`linux`), `.github/workflows/ci.yml` (`linux` job), `scripts/test-flags.sh` if the new test targets need it.

---

### Task 1: CanopySystem with subprocesses on Linux

**Interfaces:**
- Produces: `public enum Subprocess { static func run(_:_:environment:directory:timeout:stdin:handle:) throws -> SubprocessResult }`, `SubprocessResult`, `SubprocessError`, `SubprocessHandle`, `public func onOwnThread<T>(_:) async -> T`, `public struct LineBuffer`, as today but public and in `CanopySystem`.

Steps:

- [ ] Move `Support/Subprocess.swift`, `Support/OwnThread.swift`, and `Control/LineBuffer.swift` into `Sources/CanopySystem`, make what other modules use public, add the target and `CanopySystemTests`, move `SubprocessTests` there, and add `@_exported import CanopySystem` to `Exports.swift`.
  `make build` and `make test` pass with no other change: commit `refactor: CanopySystem holds subprocesses, lines, and the blocking-work thread`.
- [ ] Write the failing tests in `SubprocessTests`, which fail on Linux and pass on macOS:
  `aChildThatExitsAtOnceIsNotWaitedOn` (`/bin/true` with a 10 s timeout returns in under 1 s, not timed out),
  `aChildInheritsNoDescriptors` (open a file without `O_CLOEXEC`, run `/bin/sh -c 'ls /proc/self/fd 2>/dev/null || ls /dev/fd'`, and expect only 0, 1, 2, and the descriptor `ls` itself opens),
  `aTimeoutKillsTheChildsGroup` (existing, kept), and `exitStatusAndSignalAreReported` (`sh -c 'exit 3'` is 3, `sh -c 'kill -TERM $$'` is 143).
- [ ] Run them in Docker: `docker run --rm -v "$PWD":/src -w /src swift:6.4 swift test --filter CanopySystemTests`.
  Expected: build errors on `kqueue`, `posix_spawn_file_actions_t?`, `POSIX_SPAWN_CLOEXEC_DEFAULT`.
- [ ] Port `Subprocess` with `#if canImport(Darwin)` where the platforms differ:
  - Spawn attributes and file actions are `posix_spawn_file_actions_t()` and `posix_spawnattr_t()` values on Glibc and Musl, optionals on Darwin; one small wrapper type each hides it.
  - Linux has no `POSIX_SPAWN_CLOEXEC_DEFAULT`: temporary files are opened with `O_CLOEXEC` (`mkostemp`), and the file actions add `addclose` for every other descriptor `/proc/self/fd` lists at spawn time, above 2.
  - Waiting without reaping: Darwin keeps `kqueue` with `NOTE_EXIT`; Linux polls `waitid(P_PID, pid, &info, WEXITED | WNOHANG | WNOWAIT)` every 5 ms until it reports the child or the deadline passes, so a child that exited first is found at once.
- [ ] Run the tests in Docker and on the Mac: both pass.
  Commit: `feat: subprocesses run on Linux too`.

### Task 2: CanopyAgents

**Interfaces:**
- Produces: `ClaudeHookMapping`, `AgentReport`, `AgentChange`, `AgentPrompt`, `PaneAgent`, `TranscriptParser` (with `ToolKind` and its `short` public), `TranscriptReader` (with `Page`'s initializer public), `TranscriptFollower`, `TranscriptTails`, `PhoneAnswerKeys`, all public in `CanopyAgents`.
- Stays in `CanopyCore`: `AgentHook`, `AgentHookRequest` (they need `CanopyHome` and `TermStateParams`), in `Agents/AgentHook.swift`.

Steps:

- [ ] Move the files, split `AgentHook` out, make what `CanopyCore` uses public, add `@_exported import CanopyAgents`, and move the tests named in File Structure with `Fixtures/Transcripts` into `CanopyAgentsTests` (`resources: [.copy("Fixtures")]`).
- [ ] `make build` with 0 warnings and `make test`; then `docker run ... swift test --filter CanopyAgentsTests`.
  Expected: everything passes on both, since nothing in these files is Darwin-only.
  A Linux failure from Foundation differences (`ISO8601FormatStyle`, `NSString.lastPathComponent`, `URL.host()`) gets a test-first fix.
- [ ] Commit: `refactor: CanopyAgents holds agent states, transcripts, and answer keys, and builds on Linux`.

### Task 3: POSIX TCP

**Interfaces:**
- Produces in `CanopySystem`:
  - `public struct TCPOptions: Sendable { var keepalive: (idle: Int, interval: Int, count: Int)?; var reuseAddress: Bool }`
  - `public final class TCPListener: Sendable { init(address: String, port: UInt16, options: TCPOptions, queue: DispatchQueue, accept: @escaping @Sendable (TCPConnection) -> Void) throws; var port: UInt16 { get }; func close() }`, binding with `inet_pton` (IPv4 or IPv6), `SO_REUSEADDR`, `listen`, and a `DispatchSourceRead` that accepts.
  - `public final class TCPConnection: Sendable { var localAddress: String { get }; func receive(_ handler: @escaping @Sendable (Data?, (any Error)?) -> Void); func send(_ data: Data) async throws; func close() }`, where `receive` calls back with each chunk, `nil` at the other side's close, and an error on failure, until closed; sends leave in order on the connection's own serial queue, waiting in `poll` for room, so one phone that stops reading holds up only its own sends.
  - `public enum TCPError: Error { case invalidAddress(String), system(String, errno: Int32), closed }`.

Steps:

- [ ] Write `TCPTests` first:
  `listensOnAnyFreePort` (port 0 gives a port above 0), `echoesLinesBothWays`, `reportsTheOtherSidesClose`, `bindsAgainAtOnceAfterClosing` (same address and port, right after `close()`), `refusesAnAddressThatIsNotNumeric`, `appliesKeepalive` (reads back `SO_KEEPALIVE`, and `TCP_KEEPALIVE` on Darwin or `TCP_KEEPIDLE` on Linux), `aStalledReaderBlocksNoOtherConnection` (one client never reads while 8 MB is sent to it; a second client still echoes within 1 s), `bindsIPv6Loopback`.
- [ ] Run them on the Mac and in Docker: they fail to build.
- [ ] Implement `TCP.swift`.
- [ ] Both pass. Commit: `feat: POSIX TCP listener and connections in CanopySystem`.

### Task 4: CanopyServer over PhoneSource

**Interfaces:**
- Produces in `CanopyServer`:
  - `public protocol PhoneSource: Sendable` with: `func inbox() async -> PhoneInbox`, `func rows() async -> PhoneRowsResult`, `func changes() -> AsyncStream<Void>` (anything the inbox shows changed), `func agentEvents() -> AsyncStream<PhoneAgentEvent>` (prompted, closed, changed by pane, for `phone.delivered` and conversations), `func transcriptPath(pane: String) async throws -> String?`, `func reply(pane:text:) async throws`, `func answer(pane:prompt:answer:) async throws`, `func keys(pane:text:) async throws`, `func seen(pane:) async throws`, `func screen(pane:scrollback:) async throws -> PhoneScreen`, `func screenChanges(pane:) -> AsyncStream<PhoneScreen>`.
    Its errors are `ControlError`s with the codes the phone already reads (`pane_not_found`, `pane_exited`, `agent_not_running`, `prompt_open`, `prompt_gone`, `no_transcript`).
  - `public struct PhoneEnvironment: Sendable` with the registry's file URL, the server's name and version, `record: @Sendable (PhoneActivity) -> Void`, `logsCommands: @Sendable () -> Bool`, `tailnetName: @Sendable () async -> String?`, `addresses: @Sendable () -> [String]`, and `addressChanges: AsyncStream<Void>`.
  - `PhoneRegistry` (SHA-256 from `Crypto`), `PhoneGate`, `PhoneSession`, `PhoneConnection` (on `TCPConnection`), `PhoneListener` (on `TCPListener`, with the same `refresh`, `endpoints`, `disconnect`, `stop`, and 5 s bind deadline), and `PhoneService(source:environment:)` with the methods `CanopyCore` calls today.
- Produces in `CanopyCore`: `MacPhoneSource(terminals:snapshots:tails:)` (what `PhoneHub`, `PhonePanes`, `PhoneInboxBuilder`, and `ScreenWatcher` do now), and `MacPhoneEnvironment` (the `NWPathMonitor`, `TailscaleAddresses` on `utun`, `TailscaleStatus.dnsName`, the activity log, `CANOPY_PHONE_LISTEN` under `#if DEBUG`).

Steps:

- [ ] Move `PhoneRegistry` first, swapping `CryptoKit` for `Crypto`; `PhoneRegistryTests` move to `CanopyServerTests` and pass on both platforms.
  Commit: `refactor: the phone registry moves to CanopyServer, hashing with swift-crypto`.
- [ ] Move `PhoneConnection` and `PhoneListener` onto `TCPConnection` and `TCPListener`, with `PhoneListenerTests` moved and its test client on POSIX `connect` through the platform's libc; its `utun` and `lo0` checks stay in `CanopyCoreTests` with `TailscaleAddresses`.
  Every moved test passes unchanged on the Mac, then in Docker.
  Commit: `refactor: the phone listener runs on POSIX TCP`.
- [ ] Add `PhoneSource` and `PhoneEnvironment`, move the protocol work of `PhoneService` into `CanopyServer`, and build `MacPhoneSource` and `MacPhoneEnvironment` in `CanopyCore` from what `PhoneHub`, `PhonePanes`, `PhoneInboxBuilder`, `ScreenWatcher`, and `PhoneService` do now.
  `PhoneServiceTests`, `PhoneServicePaneTests`, `PhoneHubTests`, `PhoneInboxBuilderTests`, `PhonePanesTests`, and `PhonesControlTests` stay in `CanopyCoreTests` and pass unchanged but for construction.
  Add `CanopyServerTests/PhoneServiceSourceTests` against a `FakePhoneSource`: hello and pair, subscribe sends the inbox and a change sends it again, a reply reaches the source, `prompt_gone` from the source reaches the phone, `phone.delivered` follows the source's prompt event, and an unknown pane's transcript is `pane_not_found`.
  Commit: `refactor: the phone server runs on PhoneSource, so it no longer needs the Mac`.
- [ ] `make e2e`, and `scripts/ios-shots.sh light` against the dev build: both pass, since the phone sees no difference.

### Task 5: Linux in the package, the Makefile, and CI

Steps:

- [ ] `Package.swift`: under `#if os(Linux)`, the package declares `CanopyWire`, `CanopySystem`, `CanopyAgents`, `CanopyServer`, and their test targets only, with swift-crypto as its one dependency; on macOS it declares everything, as now, plus swift-crypto.
- [ ] `make linux` runs `docker run --rm -v "$PWD":/src -w /src swift:6.4 sh -c 'swift build -Xswiftc -warnings-as-errors && swift test'` with the build folder at `.build/linux`, so it never mixes with the Mac's.
- [ ] `.github/workflows/ci.yml` gains a `linux` job on `ubuntu-latest` in `container: swift:6.4` running the same two commands.
- [ ] `make linux` passes locally.
  Commit: `ci: build and test the portable modules on Linux`.

## Verification

- `make lint`, `make build` (0 warnings), `make test` three times, `make e2e`, `make ios`, `scripts/ios-shots.sh both`, `make linux`.
- An independent opus review of the branch, findings fixed under After Review.
- CI `check` and `linux` green, then squash-merge.

## After Review

An independent opus review of `git diff origin/main...feat/box-portable` found one critical and two important problems, all fixed:

1. Critical: a send that failed, as when a phone vanished and the connection reset, closed the TCP connection without telling its reader, so the phone's connection stayed open in the server, still counted as connected, and kept its screen and transcript streams polling.
   Network.framework had reported this through the connection's state.
   A failed send now tells the receive handler once, and the phone connection closes itself when a write throws.
   Test: `aFailedSendTellsTheReader`.
2. On Linux, sockets and temporary files were made close-on-exec only a moment after they were created, so a spawn on another thread could hand a listening socket to a child that outlived it, holding the port.
   A small C target, `CSystemShims`, gives `accept4` and `mkostemp`, which Swift's Glibc import leaves out, and sockets are made with `SOCK_CLOEXEC`.
3. No test showed a phone that closes its side mid-line still getting its answers.
   Test: `answersWhatCameBeforeThePhoneClosedItsSide`.

Also fixed from its minor list: an empty send returns rather than reading a nil buffer, a second close of a listener at the same moment returns, and the Linux CI job runs with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` as `make test` does.
Tests: `sendingNothingReturns`, `closingAListenerTwiceAtOnceReturns`.
Deferred: backing off when `accept` fails for want of descriptors, polling `WNOHANG` after a timeout's SIGKILL instead of a blocking wait under the handle's lock, and `pidfd_open` in place of the 5 ms poll.

While running the bar, `scripts/e2e-hosts.sh` failed twice in different steps, and both were races in the script: it read the remote pane's background work in a second read after the host's probe could clear it, and gave a fresh `python3` 10 s to listen where this Mac's endpoint security scanner can hold it longer.
Both are fixed, and the script passed three runs in a row.
