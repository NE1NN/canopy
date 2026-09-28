# Canopy Keeps the User's ZDOTDIR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Canopy terminal reads the same zsh startup files, in the same order, and ends with the same `ZDOTDIR`, as a new Terminal window, whether `ZDOTDIR` comes from the login session, from `~/.zshenv`, or from nowhere, and whatever launched Canopy.

**Architecture:** Terminals and setup scripts get `ZDOTDIR` as the login session has it, which `ShellSettings.current` reads once with `launchctl getenv`, as a Terminal window would get it.
The app's own `ZDOTDIR` is not used, since it can come from whatever launched the app.
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
A Terminal window never has that problem: it gets its environment from the login session, where `ZDOTDIR` is only set by `launchctl setenv`.
So terminals take `ZDOTDIR` from the login session, like the other login-session variables they keep.

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
- `launchctl getenv` runs once, on the main thread, while the app starts, and takes about 20 ms.
  If it fails or takes over 2 s, terminals get no `ZDOTDIR`, as before this change.

---

## Task 1: Terminals and setup scripts get the login session's ZDOTDIR

**Files:**
- Modify: `Sources/CanopyCore/Terminal/PaneEnvironment.swift`
- Modify: `Sources/CanopyCore/Terminal/ShellSettings.swift` (`current` and `LoginShell`)
- Modify: `Tests/CanopyCoreTests/Support/FakeTerminal.swift` (`zshTerminals` takes extra environment)
- Test: `Tests/CanopyCoreTests/PaneEnvironmentTests.swift`, `Tests/CanopyCoreTests/CommandLoggingTests.swift`

**Interfaces:**
- Produces: `ShellSettings.current(home:cliDirectory:logsCommands:environment:sessionVariable:)`, whose last two parameters default to the process's environment and `LoginShell.sessionVariable`.
- Produces: `LoginShell.sessionVariable(_:) -> String?`.
- Produces: `Fixture.zshTerminals(_:files:logsCommands:environment:)`, whose `environment` is added to the app's environment, standing for the login session's `ZDOTDIR` after `current` put it there.
- Produces: `ZshCommandLoggingTests.startupFiles(in:)` and `ZshCommandLoggingTests.check`, used again in Task 2.

- [ ] **Step 1: Let the zsh fixture take the app's environment**

```swift
    static func zshTerminals(
        _ dir: TempDir, files: [String: String] = [:], logsCommands: Bool = true, environment: [String: String] = [:]
    ) throws -> TerminalStore {
        ...
        settings.baseEnvironment = ["HOME": home, "USER": NSUserName()].merging(environment) { $1 }
```

- [ ] **Step 2: Write the failing tests**

In `PaneEnvironmentTests.keepsLoginSessionVariablesAndDropsTheRest`, add `"ZDOTDIR": "/Users/me/.config/zsh"` to `base` and expect it kept.
Then:

```swift
    @Test func terminalsTakeZDOTDIRFromTheLoginSessionNotFromWhateverLaunchedTheApp() {
        // Like `canopy` run from a shell whose ~/.zshenv exports ZDOTDIR. A Terminal window would read that ~/.zshenv.
        let launcher = ["HOME": "/Users/me", "ZDOTDIR": "/Users/me/.config/zsh"]
        let home = CanopyHome(path: "/h/.canopy")

        let unset = ShellSettings.current(
            home: home, cliDirectory: nil, logsCommands: true, environment: launcher, sessionVariable: { _ in nil })
        let set = ShellSettings.current(
            home: home, cliDirectory: nil, logsCommands: true, environment: launcher,
            sessionVariable: { $0 == "ZDOTDIR" ? "/session/zsh" : nil })

        #expect(unset.baseEnvironment["ZDOTDIR"] == nil)
        #expect(set.baseEnvironment["ZDOTDIR"] == "/session/zsh")
        #expect(set.baseEnvironment["HOME"] == "/Users/me")
    }

    @Test func readsLaunchctlsAnswer() {
        #expect(LoginShell.sessionValue(launchctlOutput: Data()) == nil)
        #expect(LoginShell.sessionValue(launchctlOutput: Data("/Users/me/z dot\n".utf8)) == "/Users/me/z dot")
        #expect(LoginShell.sessionValue(launchctlOutput: Data("\n".utf8)) == "")
        #expect(LoginShell.sessionVariable("CANOPY_NEVER_SET_\(UUID().uuidString)") == nil)
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
            environment: ["ZDOTDIR": zdot])
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
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, environment: ["ZDOTDIR": zdot])
        defer { terminals.closeAll() }
        let script = #"print -r -- "check:$LOADED:${ZDOTDIR-unset}""#
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(script)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(await eventually { pane.screen.text.contains("check:\(loaded):\(zdot)") })
    }
```

- [ ] **Step 3: Run them and watch them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PaneEnvironmentTests|ZshCommandLoggingTests'`
Expected: `ShellSettings.current` has no `environment` or `sessionVariable` parameter, and `LoginShell` has no `sessionVariable` or `sessionValue`.
With those in place but `ZDOTDIR` still filtered out, the zsh tests read `~/` instead of `z dot/`.

- [ ] **Step 4: Keep ZDOTDIR, and take it from the login session**

```swift
    /// What a macOS login session starts with, and ZDOTDIR, which `ShellSettings.current` takes from the login session
    /// itself. Everything else in the app's environment came from whatever launched it, such as a Claude Code session
    /// running a dev build, and must not reach terminals.
    static let inherited: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "LC_CTYPE",
        "ZDOTDIR",
    ]
```

```swift
    public static func current(
        home: CanopyHome, cliDirectory: String?, logsCommands: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sessionVariable: (String) -> String? = LoginShell.sessionVariable
    ) -> ShellSettings {
        var environment = environment
        // A Terminal window gets ZDOTDIR from the login session. The app's own can come from whatever launched it,
        // such as a shell whose ~/.zshenv exports it, and zsh started with that would skip ~/.zshenv.
        environment["ZDOTDIR"] = sessionVariable("ZDOTDIR")
        return ShellSettings(
            shell: LoginShell.path(),
            baseEnvironment: environment,
            ...
```

```swift
    /// A variable as the login session has it, which `launchctl setenv` sets, or nil if it has none.
    public static func sessionVariable(_ name: String) -> String? {
        let result = try? Subprocess.run(
            "/bin/launchctl", ["getenv", name], environment: [:], directory: nil, timeout: .seconds(2))
        guard let result, !result.timedOut, result.status == 0 else { return nil }
        return sessionValue(launchctlOutput: result.stdout)
    }

    /// launchctl prints nothing for a variable the session does not have, and the value and a newline for one it has.
    static func sessionValue(launchctlOutput output: Data) -> String? {
        guard !output.isEmpty else { return nil }
        var value = String(decoding: output, as: UTF8.self)
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }
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
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""), environment: ["ZDOTDIR": ""])
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
   New tests: `terminalsTakeZDOTDIRFromTheLoginSessionNotFromWhateverLaunchedTheApp` and `readsLaunchctlsAnswer`.
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
