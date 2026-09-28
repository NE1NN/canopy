# Canopy Keeps the User's ZDOTDIR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Canopy terminal reads the same zsh startup files, in the same order, and ends with the same `ZDOTDIR`, as a new Terminal window, whether `ZDOTDIR` comes from the login session, from `~/.zshenv`, or from nowhere, and whatever launched Canopy.

**Architecture:** Terminals and setup scripts get `ZDOTDIR` as the login session has it, as a Terminal window would get it.
`ShellSettings.current` reads it once with `launchctl getenv` into its own `zdotdir` field, and `PaneEnvironment.build` sets it.
The app's own `ZDOTDIR` is never used, since it can come from whatever launched the app.
While command logging is on, `ShellSettings.interactiveShell` moves that value into `CANOPY_USER_ZDOTDIR` before pointing `ZDOTDIR` at the shim.
The shim puts it back, or unsets `ZDOTDIR` if there was none, and loads `.zshenv` from `${ZDOTDIR-$HOME}`, which is zsh's own rule.

**Tech Stack:** Swift 6.2, zsh 5.9, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Starting a shell" and "Command logging".

## Root Cause

An end-to-end run of the dev build, launched with a throwaway `HOME` and with `ZDOTDIR` pointing at a folder whose four startup files each leave a mark, showed this for a new terminal:

| | Plain `zsh -il` | Canopy terminal |
|---|---|---|
| Files read | `$ZDOTDIR/.zshenv`, `.zprofile`, `.zshrc`, `.zlogin` | `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zlogin` |
| `$ZDOTDIR` at the prompt | the folder | unset |

A setup script read `~/` too, though it never goes through the shim.
Two things drop the value:

1. `PaneEnvironment.build` keeps only the variables a macOS login session starts with, and `ZDOTDIR` is not one of them.
   So no terminal or setup script ever sees a `ZDOTDIR`, even with command logging off.
2. With command logging on, the shim runs `unset ZDOTDIR` and loads `$HOME/.zshenv`, so even a value that got through would be lost.

The same run confirmed that the other two cases already behave: a `ZDOTDIR` exported by `~/.zshenv` is followed, since the shim loads that file, and with no `ZDOTDIR` anywhere zsh reads `~/`.

zsh uses a `ZDOTDIR` that is set but empty as it is, so it looks for `/.zshrc` and never reads `~/`.
The shim follows the same rule with `${ZDOTDIR-$HOME}`, not `${ZDOTDIR:-$HOME}`.

### Where a terminal's ZDOTDIR should come from

The first version passed the app's own `ZDOTDIR` to terminals, and the review showed why that is wrong.
`canopy` starts the app with `open --env`, which hands it the caller's whole environment.
A common setup exports `ZDOTDIR` from `~/.zshenv`, so every shell has it, and a Canopy started from one of them would give its terminals that value.
zsh started with it skips `~/.zshenv`, and whatever lives only there, such as rustup's `. "$HOME/.cargo/env"`, is lost.
A Terminal window never has that problem: it gets its environment from the login session, where only `launchctl setenv` or `launchctl config user setenv` sets `ZDOTDIR`.
So terminals take `ZDOTDIR` from the login session, and never from the app's own environment.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings.
- `make lint` passes `swift format lint --strict`.
- The shim still uses `builtin` for every command it runs before the user's `.zshenv`, so no alias from `/etc/zshenv` can reach it.
- Nothing Canopy adds for the shim is left in the shell's environment: `CANOPY_COMMAND_TOKEN` and `CANOPY_USER_ZDOTDIR` are both unset.

## Review Focus

1. `ZDOTDIR` set to an empty string: zsh reads startup files from `/`, never `~/`, and Canopy must too.
   Pinned by `anEmptyZDOTDIRIsKeptAsZshKeepsIt` in Task 2.
2. Command logging off: the shell starts without the shim, and still reads `$ZDOTDIR`.
   Pinned by the `logsCommands: false` case of `aZDOTDIRFromTheLoginSessionIsKept` in Task 1.
3. Setup scripts and teardown scripts run `zsh -i -l -c` without the shim, and read `$ZDOTDIR` like a terminal.
   Pinned by `setupScriptsReadTheLoginSessionsZDOTDIR` in Task 1.
4. A `zsh` started inside a Canopy terminal reads the same files as the terminal: `ZDOTDIR` stays exported, and `CANOPY_USER_ZDOTDIR` is gone.
   Pinned by the `${(t)ZDOTDIR}`, `$(printenv ZDOTDIR)`, and `${CANOPY_USER_ZDOTDIR-none}` parts of the shared check in Tasks 1 and 2.
5. A `ZDOTDIR` with a space in its path.
   Pinned by the `z dot` folder the Task 1 tests use.

## Decisions to Review

- Terminals take `ZDOTDIR` from the login session, not from the app's own environment.
  A launcher's `ZDOTDIR`, such as the fixture folder `scripts/ui-fixture.sh` and `scripts/e2e.sh` launch the dev app with, no longer reaches terminals, just as it would not reach a Terminal window.
  The fixtures still use it for what they need, the app's own login PATH.
- `launchctl getenv` runs once, on the main thread, while the app starts, and takes 10 to 20 ms.
  If it fails or takes over 2 s, terminals get no `ZDOTDIR`, as before this change.
  Keeping the app's own value instead would bring back the bug above whenever `launchctl` failed.
- The other variables terminals keep, such as `SSH_AUTH_SOCK` and the locale, still come from whatever launched the app, as before this change.
  Taking them from the login session too is the same kind of fix, and is left for a follow-up.
  So is the app's own login PATH, which it works out with its own `ZDOTDIR`.

---

## Task 1: Terminals and setup scripts get the login session's ZDOTDIR

**Files:**
- Modify: `Sources/CanopyCore/Terminal/PaneEnvironment.swift`
- Modify: `Sources/CanopyCore/Terminal/ShellSettings.swift` (`zdotdir`, `current`, and `LoginShell`)
- Modify: `Tests/CanopyCoreTests/Support/FakeTerminal.swift` (`zshTerminals` takes the session's `ZDOTDIR`)
- Test: `Tests/CanopyCoreTests/PaneEnvironmentTests.swift`, `Tests/CanopyCoreTests/CommandLoggingTests.swift`

**Interfaces:**
- Produces: `ShellSettings.zdotdir: String?`, and `ShellSettings.current(home:cliDirectory:logsCommands:sessionVariable:)`, whose last parameter defaults to `LoginShell.sessionVariable`.
- Produces: `LoginShell.sessionVariable(_:launchctl:) -> String?`, whose `launchctl` defaults to `/bin/launchctl`.
- Produces: `Fixture.zshTerminals(_:files:logsCommands:zdotdir:)`, whose `zdotdir` stands for the login session's.
- Produces: `ZshCommandLoggingTests.startupFiles(in:)` and `ZshCommandLoggingTests.check`, used again in Task 2.

- [ ] **Step 1: Let the zsh fixture take the session's ZDOTDIR**

```swift
    static func zshTerminals(
        _ dir: TempDir, files: [String: String] = [:], logsCommands: Bool = true, zdotdir: String? = nil
    ) throws -> TerminalStore {
        ...
        settings.baseEnvironment = ["HOME": home, "USER": NSUserName()]
        settings.zdotdir = zdotdir
```

- [ ] **Step 2: Write the failing tests**

In `PaneEnvironmentTests.keepsLoginSessionVariablesAndDropsTheRest`, add `"ZDOTDIR": "/Users/me/.config/zsh"` to `base` and expect it dropped.
Then:

```swift
    @Test func terminalsGetTheLoginSessionsZDOTDIRNotTheAppsOwn() {
        // Like `canopy` run from a shell whose ~/.zshenv exports ZDOTDIR. A Terminal window would read that ~/.zshenv.
        var launched = settings(["HOME": "/Users/me", "ZDOTDIR": "/Users/me/.config/zsh"])
        let current = ShellSettings.current(
            home: CanopyHome(path: "/h/.canopy"), cliDirectory: nil, logsCommands: true,
            sessionVariable: { $0 == "ZDOTDIR" ? "/session/zsh" : nil })

        #expect(PaneEnvironment.build(settings: launched, context: context, pane: PaneID(1))["ZDOTDIR"] == nil)
        launched.zdotdir = "/session/zsh"
        #expect(
            PaneEnvironment.build(settings: launched, context: context, pane: PaneID(1))["ZDOTDIR"] == "/session/zsh")
        #expect(current.zdotdir == "/session/zsh")
    }

    @Test func asksLaunchctlForTheLoginSessionsValue() async throws {
        // echo prints its arguments and a newline, as launchctl prints a value the session has.
        let echoed = try await offPool { LoginShell.sessionVariable("ZDOTDIR", launchctl: "/bin/echo") }
        let silent = try await offPool { LoginShell.sessionVariable("ZDOTDIR", launchctl: "/usr/bin/true") }
        let failed = try await offPool { LoginShell.sessionVariable("ZDOTDIR", launchctl: "/usr/bin/false") }
        let unset = try await offPool { LoginShell.sessionVariable("CANOPY_NEVER_SET_\(UUID().uuidString)") }

        #expect(echoed == "getenv ZDOTDIR")
        #expect(silent == nil)
        #expect(failed == nil)
        #expect(unset == nil)
    }
```

In `ZshCommandLoggingTests`:

```swift
    /// The four startup files in `folder`, a path under HOME, each adding its own path to LOADED when zsh reads it.
    func startupFiles(in folder: String) -> [String: String] {
        let paths = [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { folder.isEmpty ? $0 : "\(folder)/\($0)" }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, #"LOADED+=" \#($0)""#) })
    }

    /// Which startup files ran, then ZDOTDIR's value, type, and value in the environment, what is left of Canopy's
    /// variables, and the history file macOS's /etc/zshrc picked.
    static let check =
        #"print -r -- "check:$LOADED:${ZDOTDIR-unset}:${(t)ZDOTDIR}:$(printenv ZDOTDIR):"#
        + #"${CANOPY_USER_ZDOTDIR-none}:${CANOPY_COMMAND_TOKEN-none}:$HISTFILE""#

    @Test(arguments: [false])
    func aZDOTDIRFromTheLoginSessionIsKept(logsCommands: Bool) async throws {
        let dir = try TempDir()
        let zdot = dir.sub("user-home/z dot")
        let terminals = try Fixture.zshTerminals(
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, logsCommands: logsCommands,
            zdotdir: zdot)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(
            await run(
                pane, Self.check, until: "check:\(loaded):\(zdot):scalar-export:\(zdot):none:none:\(zdot)/.zsh_history")
        )
        let logged: [JSONValue?] = logsCommands ? [.string(Self.check)] : []
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == logged })
    }

    @Test func setupScriptsReadTheLoginSessionsZDOTDIR() async throws {
        let dir = try TempDir()
        let zdot = dir.sub("user-home/z dot")
        let terminals = try Fixture.zshTerminals(
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, zdotdir: zdot)
        defer { terminals.closeAll() }
        let script = #"print -r -- "check:$LOADED:${ZDOTDIR-unset}""#
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(script)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(await eventually { pane.screen.text.contains("check:\(loaded):\(zdot)") })
    }
```

- [ ] **Step 3: Run them and watch them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PaneEnvironmentTests|ZshCommandLoggingTests'`
Expected: `ShellSettings` has no `zdotdir`, and `LoginShell` has no `sessionVariable`.
With those in place but not yet set in `PaneEnvironment.build`, the zsh tests read `~/` instead of `z dot/`.

- [ ] **Step 4: Take ZDOTDIR from the login session**

In `ShellSettings`, next to `baseEnvironment`, with a matching `zdotdir: String? = nil` parameter on `init`:

```swift
    /// ZDOTDIR as the login session has it, which a Terminal window gets. The app's own can come from whatever launched
    /// it, such as a shell whose ~/.zshenv exports it, and zsh started with that would skip ~/.zshenv.
    public var zdotdir: String?
```

```swift
    public static func current(
        home: CanopyHome, cliDirectory: String?, logsCommands: Bool,
        sessionVariable: (String) -> String? = { LoginShell.sessionVariable($0) }
    ) -> ShellSettings {
        ShellSettings(
            ...
            logsCommands: logsCommands,
            zdotdir: sessionVariable("ZDOTDIR")
        )
    }
```

```swift
    /// A variable as the login session has it, which `launchctl setenv` sets, or nil if it has none.
    public static func sessionVariable(_ name: String, launchctl: String = "/bin/launchctl") -> String? {
        let result = try? Subprocess.run(
            launchctl, ["getenv", name], environment: [:], directory: nil, timeout: .seconds(2))
        // launchctl prints nothing for a variable the session does not have, and the value and a newline for one it has.
        guard let result, !result.timedOut, result.status == 0, !result.stdout.isEmpty else { return nil }
        var value = String(decoding: result.stdout, as: UTF8.self)
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }
```

In `PaneEnvironment.build`, after the filtered environment gets `HOME` and `LANG`:

```swift
        environment["ZDOTDIR"] = settings.zdotdir
```

- [ ] **Step 5: Run the tests again**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git commit -m "fix: give terminals and setup scripts the login session's ZDOTDIR"
```

## Task 2: The shim puts the user's ZDOTDIR back

**Files:**
- Modify: `Sources/CanopyCore/Terminal/ShellSettings.swift` (`interactiveShell`)
- Modify: `Sources/CanopyCore/Terminal/ZshIntegration.swift`
- Test: `Tests/CanopyCoreTests/CommandLoggingTests.swift`

**Interfaces:**
- Consumes: `startupFiles(in:)` and `check` from Task 1.
- Produces: `CANOPY_USER_ZDOTDIR`, set by `interactiveShell` only when the environment had `ZDOTDIR`, and unset by the shim.

- [ ] **Step 1: Write the failing tests**

Run `aZDOTDIRFromTheLoginSessionIsKept` with command logging on too: `@Test(arguments: [false, true])`.

Rewrite `theUsersStartupFilesLoadAsUsual` with the shared check, so it also pins the order:

```swift
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
        ...
        let loaded = " .zshenv .zprofile .zshrc .zlogin"
        let home = dir.sub("user-home")
        #expect(await run(pane, Self.check, until: "check:\(loaded):unset:::none:none:\(home)/.zsh_history"))
```

Make `aZDOTDIRSetInTheUsersZshenvIsFollowed` check the files and the final `ZDOTDIR`, not just an alias:

```swift
        var files = startupFiles(in: "").merging(startupFiles(in: ".config/zsh")) { $1 }
        files[".zshenv", default: ""] += "\nexport ZDOTDIR=$HOME/.config/zsh"
        let terminals = try Fixture.zshTerminals(dir, files: files)
        ...
        let loaded = " .zshenv .config/zsh/.zprofile .config/zsh/.zshrc .config/zsh/.zlogin"
        let config = dir.sub("user-home/.config/zsh")
        #expect(
            await run(
                pane, Self.check,
                until: "check:\(loaded):\(config):scalar-export:\(config):none:none:\(config)/.zsh_history"))
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == [.string(Self.check)] })
```

Add the empty case, and an unreadable `.zshenv`, which zsh skips without a word:

```swift
    @Test func anUnreadableZshenvIsSkippedQuietlyAsZshSkipsIt() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
        defer { terminals.closeAll() }
        chmod(dir.sub("user-home/.zshenv"), 0)
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let home = dir.sub("user-home")
        #expect(
            await run(pane, Self.check, until: "check: .zprofile .zshrc .zlogin:unset:::none:none:\(home)/.zsh_history")
        )
        #expect(!pane.screen.text.contains("permission denied"))
    }

    @Test func anEmptyZDOTDIRIsKeptAsZshKeepsIt() async throws {
        // zsh reads startup files from a ZDOTDIR that is set, even to nothing, so from /, never from HOME.
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""), zdotdir: "")
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(
            await run(pane, Self.check, until: "check:::scalar-export::none:none:\(dir.sub("user-home"))/.zsh_history"))
    }
```

In `onlyZshShellsGetTheShim`, pass `["ZDOTDIR": "/z"]`, and expect bash's launch and the script's to keep that environment as it is, zsh's to carry `CANOPY_USER_ZDOTDIR == "/z"`, and a zsh launched without `ZDOTDIR` to have no `CANOPY_USER_ZDOTDIR`.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test $(scripts/test-flags.sh) --filter ZshCommandLoggingTests`
Expected: the `logsCommands: true` case reads `~/` and ends with `ZDOTDIR` unset, and `onlyZshShellsGetTheShim` finds no `CANOPY_USER_ZDOTDIR`.
The empty case fails too, since the shim unsets `ZDOTDIR`, and the unreadable case prints `permission denied`.

- [ ] **Step 3: Hand the user's ZDOTDIR to the shim**

```swift
        if reportsCommands, let commandToken, let folder = try? ZshIntegration.install(in: home) {
            // The shim puts the user's own ZDOTDIR back from here, or unsets it if there was none.
            environment["CANOPY_USER_ZDOTDIR"] = environment["ZDOTDIR"]
            environment["ZDOTDIR"] = folder
            environment["CANOPY_COMMAND_TOKEN"] = commandToken
        }
```

- [ ] **Step 4: Put it back in the shim**

```zsh
        builtin typeset -g _canopy_token=${CANOPY_COMMAND_TOKEN-}
        if [[ -n ${CANOPY_USER_ZDOTDIR+set} ]]; then
            builtin export ZDOTDIR="$CANOPY_USER_ZDOTDIR"
        else
            builtin unset ZDOTDIR
        fi
        builtin unset CANOPY_COMMAND_TOKEN CANOPY_USER_ZDOTDIR
        ...
        # zsh's own rules: a ZDOTDIR that is set, even to nothing, is used instead of HOME, and a file it cannot read
        # is skipped quietly.
        [[ -f ${ZDOTDIR-$HOME}/.zshenv && -r ${ZDOTDIR-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR-$HOME}/.zshenv"
```

Update the doc comments on `ZshIntegration` and in the shim's header to say it puts back the user's own `ZDOTDIR`.

- [ ] **Step 5: Run the tests again**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git commit -m "fix: put the user's own ZDOTDIR back in Canopy's zsh shim"
```

## Task 3: An end-to-end check, and the spec

**Files:**
- Modify: `scripts/e2e.sh`
- Modify: `docs/superpowers/specs/2026-09-27-canopy-design.md`

- [ ] **Step 1: Add an e2e step**

The clone steps launch the app with `ZDOTDIR="$work/zdot"`, whose `.zshrc` puts the stand-in `gh` on PATH.
A Terminal window would not get that value, so a Canopy terminal must not either, and its commands must still be logged:

```bash
step "terminals take ZDOTDIR from the login session, not from whatever launched Canopy, and still log commands"
# A Terminal window would not get the ZDOTDIR this app was launched with, whose .zshrc puts the stand-in gh on PATH.
# This guards against passing the app's own ZDOTDIR on. Testing the login session's would mean changing the Mac's.
check="[[ \${ZDOTDIR-} != '$work/zdot' && \${commands[gh]-} != '$work/bin/gh' ]] && echo zdotdir-\$((40 + 2))"
pane=$("$cli" term new --repo acme/app --row main --run "$check" --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
wait_for_text zdotdir-42 || fail "the terminal read the ZDOTDIR the app was launched with"
for _ in $(seq 1 50); do
    "$cli" log --type term.command | grep -q 'zdotdir-' && break
    sleep 0.1
done
"$cli" log --type term.command | grep -q 'zdotdir-' || fail "the terminal's command was not logged"
```

- [ ] **Step 2: Update the spec**

In "Starting a shell", say which of the app's variables terminals keep, and that `ZDOTDIR` comes from the login session.
Bring its table up to date with `PaneEnvironment.build`, which had drifted before this change: it was missing `SHELL`, `TERM_PROGRAM_VERSION`, `LANG`, and `CANOPY_ROOT_PATH`, and `PATH` is replaced, not prepended to.
In "Command logging", say that the shim puts back the user's `ZDOTDIR`, or unsets it, and loads `.zshenv` from `${ZDOTDIR-$HOME}`, and what happens when `/etc/zshenv` exports `ZDOTDIR`.

- [ ] **Step 3: Run `make e2e` and commit**

```bash
git commit -m "test: check terminals keep the login session's ZDOTDIR end to end"
```

## Task 4: The merge bar

- [ ] `make lint` and `make build` with 0 warnings.
- [ ] Three clean `make test` runs under the shared lock: `lockf -k /tmp/canopy-merge-bar.lock sh -c 'make test && make test && make test'`.
- [ ] `make e2e`.
- [ ] The scratchpad repro shows a Canopy terminal and a setup script reading the same files, in the same order, and ending with the same `ZDOTDIR` as a new Terminal window, for each way `ZDOTDIR` can reach the app.
- [ ] UI check: `scripts/ui-fixture.sh`, with a window shot.
- [ ] An independent opus reviewer on `git diff main...HEAD`, with findings fixed and listed under "After Review".
- [ ] CI `check` green.

## After Review

An independent opus reviewer read `git diff main...HEAD` with this plan and the spec, and ran zsh experiments of its own.
It confirmed that the shim matched plain zsh in every case it tried: no `ZDOTDIR`, an empty one, one with a space, `*`, `[a]`, `$`, `'`, `\`, a trailing `/`, a relative path, or a literal `~`, a non-exported one, and one whose `.zshenv` changes it again.
It also confirmed the shim held up under options and aliases `/etc/zshenv` could set, such as `sh_word_split`, `glob_subst`, `ksh_arrays`, `no_unset`, `err_exit`, and aliases for `export`, `unset`, and `source`.
Its findings, and what changed:

1. **Bug: a terminal's `ZDOTDIR` depended on how Canopy was launched.**
   The first version kept the app's own `ZDOTDIR`, and `canopy` starts the app with the caller's whole environment.
   With the common `export ZDOTDIR=$HOME/.config/zsh` in `~/.zshenv`, a Canopy started from a shell gave its terminals that value, so they skipped `~/.zshenv`, which `main` did not do.
   Fixed: `ShellSettings.current` takes `ZDOTDIR` from the login session with `launchctl getenv`, and ignores the app's own.
   New tests: `terminalsGetTheLoginSessionsZDOTDIRNotTheAppsOwn` and `asksLaunchctlForTheLoginSessionsValue`.
   The e2e step now checks that the `ZDOTDIR` the dev app was launched with does not reach its terminals, where it first checked the opposite.
   The repro now compares against a Terminal window, and a fourth case, the app launched from a shell whose `~/.zshenv` exported `ZDOTDIR`, reads the same files as one.
   See "Where a terminal's ZDOTDIR should come from" and "Decisions to Review".
2. **Risk: a `ZDOTDIR` exported by `/etc/zshenv` bypasses the shim.**
   Startup files still match plain zsh, but that shell's commands are not logged, and `CANOPY_COMMAND_TOKEN` and `CANOPY_USER_ZDOTDIR` stay in its environment.
   This was already true of the token before this change.
   Not changed; the spec's "Command logging" section now says so.
3. **The shim printed `permission denied` for an unreadable `.zshenv`,** where zsh skips it silently.
   It had the same check before this change.
   Fixed with `-f` and `-r`, pinned by `anUnreadableZshenvIsSkippedQuietlyAsZshSkipsIt`.
4. **The shared check could not tell exported from not exported for an empty value.**
   It now prints `${(t)ZDOTDIR}` too, and every case expects `scalar-export`.
5. **Docs that no longer matched:** the `baseEnvironment` and `PaneEnvironment.inherited` comments, a doubled "and" in the spec, and three places where this plan had drifted from the code.
   All fixed; the tasks above now show the final code.
6. **Inside the user's `.zshenv`, `$0` is the file's path and `ZSH_EVAL_CONTEXT` is `file:file`,** where plain zsh gives the shell's name and `file`, because the shim loads the file with `source`.
   This was already so before this change, and matching it would mean loading `.zshenv` inside a function, which would make its `typeset` calls local.
   Not changed.

The review found the tests independent of each other, and saw no false pass in the e2e step: the typed line echoes `$((40 + 2))`, and `zdotdir-42` is short enough not to wrap.

### Second round

A second opus reviewer read the branch after those fixes, with the same brief.
It found no bugs, agreed that the login session is the right source, and found no case where this branch does worse than `main`.
It checked by experiment that `open --env` hands the app the caller's `ZDOTDIR`, `SSH_AUTH_SOCK`, and `LC_ALL`, that `launchctl getenv` inside that app still answers with the session's values, and that a Ghostty window started from the Dock has no `ZDOTDIR`.
Its findings, and what changed:

1. **The other variables terminals keep still come from whatever launched the app,** such as an SSH agent forwarded into the shell that ran `canopy`, or `LC_ALL=C` from a Makefile.
   This is so on `main` too.
   Not changed; listed as a follow-up in "Decisions to Review", with the app's own login PATH.
2. **A failed `launchctl` call drops `ZDOTDIR`,** where the app's own value would be right for an app started from the Dock.
   Not changed: the app's own value is wrong whenever `canopy` started the app, and a failure leaves things as on `main`.
   See "Decisions to Review".
3. **The e2e step also passes on `main`.**
   It guards against the first-round design, and a positive check would need the Mac's login session changed.
   Its comment now says so.
4. **Only `ShellSettings.current` made `baseEnvironment["ZDOTDIR"]` the session's,** so any other way of building `ShellSettings` would pass the launcher's value on again.
   Fixed: the session's value lives in its own `ShellSettings.zdotdir`, `PaneEnvironment.build` sets it, and `ZDOTDIR` is no longer in `inherited`.
   The zsh fixture takes `zdotdir:` instead of extra environment.
   A mutation check that drops the line in `PaneEnvironment.build` fails five tests.
5. **The only real `launchctl` test would also pass if `sessionVariable` always returned nil.**
   Fixed: `sessionVariable` takes the program to run, and `asksLaunchctlForTheLoginSessionsValue` checks a value, no output, and a failure with real processes.
6. **Docs:** the start-up cost (10 to 20 ms, not about 20 ms), how the login session gets a `ZDOTDIR`, and the spec's claim that the kept variables are the login session's.
   Fixed, and the spec's table of terminal variables now matches `PaneEnvironment.build`, which it had drifted from before this change.
