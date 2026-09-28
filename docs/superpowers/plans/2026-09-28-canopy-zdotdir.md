# Canopy Keeps the User's ZDOTDIR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Canopy terminal reads the same zsh startup files, in the same order, and ends with the same `ZDOTDIR`, as the same zsh started outside Canopy, whether `ZDOTDIR` comes from the app's environment, from `~/.zshenv`, or from nowhere.

**Architecture:** Terminals and setup scripts keep the app's `ZDOTDIR`, like the login-session variables they already keep.
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
   So no terminal or setup script ever sees the app's `ZDOTDIR`, even with command logging off.
2. With command logging on, the shim runs `unset ZDOTDIR` and loads `$HOME/.zshenv`, so even a value that got through would be lost.

The same run confirmed that the other two cases already behave: a `ZDOTDIR` exported by `~/.zshenv` is followed, since the shim loads that file, and with no `ZDOTDIR` anywhere zsh reads `~/`.

zsh uses a `ZDOTDIR` that is set but empty as it is, so it looks for `/.zshrc` and never reads `~/`.
The shim follows the same rule with `${ZDOTDIR-$HOME}`, not `${ZDOTDIR:-$HOME}`.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings.
- `make lint` passes `swift format lint --strict`.
- The shim still uses `builtin` for every command it runs before the user's `.zshenv`, so no alias from `/etc/zshenv` can reach it.
- Nothing Canopy adds for the shim is left in the shell's environment: `CANOPY_COMMAND_TOKEN` and `CANOPY_USER_ZDOTDIR` are both unset.

## Review Focus

1. `ZDOTDIR` set to an empty string: zsh reads startup files from `/`, never `~/`, and Canopy must too.
   Pinned by `anEmptyZDOTDIRIsKeptAsZshKeepsIt` in Task 2.
2. Command logging off: the shell starts without the shim, and still reads `$ZDOTDIR`.
   Pinned by the `logsCommands: false` case of `aZDOTDIRFromTheEnvironmentIsKept` in Task 1.
3. Setup scripts and teardown scripts run `zsh -i -l -c` without the shim, and read `$ZDOTDIR` like a terminal.
   Pinned by `setupScriptsReadTheAppsZDOTDIR` in Task 1.
4. A `zsh` started inside a Canopy terminal reads the same files as the terminal: `ZDOTDIR` stays exported, and `CANOPY_USER_ZDOTDIR` is gone.
   Pinned by the `$(printenv ZDOTDIR)` and `${CANOPY_USER_ZDOTDIR-none}` parts of the shared check in Task 2.
5. A `ZDOTDIR` with a space in its path.
   Pinned by the `z dot` folder the Task 1 and Task 2 tests use.

## Decisions to Review

- Terminals now keep the app's `ZDOTDIR`, which the old filter dropped.
  The filter exists so that variables from whatever launched the app, such as a Claude Code session running a dev build, do not reach terminals.
  `ZDOTDIR` is different: it only says where the user's zsh files are, and a zsh started next to Canopy would read the same value.
  When a dev build starts from a Canopy terminal, that terminal's `ZDOTDIR` is already the user's own, never the shim folder.

---

## Task 1: Terminals and setup scripts keep the app's ZDOTDIR

**Files:**
- Modify: `Sources/CanopyCore/Terminal/PaneEnvironment.swift`
- Modify: `Tests/CanopyCoreTests/Support/FakeTerminal.swift` (`zshTerminals` takes extra environment)
- Test: `Tests/CanopyCoreTests/PaneEnvironmentTests.swift`, `Tests/CanopyCoreTests/CommandLoggingTests.swift`

**Interfaces:**
- Produces: `Fixture.zshTerminals(_:files:logsCommands:environment:)`, whose `environment` is added to the app's environment.
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

In `ZshCommandLoggingTests`:

```swift
    /// The four startup files in `folder`, a path under HOME, each adding its own path to LOADED when zsh reads it.
    func startupFiles(in folder: String) -> [String: String] {
        let paths = [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { folder.isEmpty ? $0 : "\(folder)/\($0)" }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, #"LOADED+=" \#($0)""#) })
    }

    /// Which startup files ran, then ZDOTDIR in the shell and in its environment, what is left of Canopy's
    /// variables, and the history file macOS's /etc/zshrc picked.
    static let check =
        #"print -r -- "check:$LOADED:${ZDOTDIR-unset}:$(printenv ZDOTDIR):${CANOPY_USER_ZDOTDIR-none}:"#
        + #"${CANOPY_COMMAND_TOKEN-none}:$HISTFILE""#

    @Test(arguments: [false])
    func aZDOTDIRFromTheEnvironmentIsKept(logsCommands: Bool) async throws {
        let dir = try TempDir()
        let zdot = dir.sub("user-home/z dot")
        let terminals = try Fixture.zshTerminals(
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, logsCommands: logsCommands,
            environment: ["ZDOTDIR": zdot])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(await run(pane, Self.check, until: "check:\(loaded):\(zdot):\(zdot):none:none:\(zdot)/.zsh_history"))
        let logged: [JSONValue] = logsCommands ? [.string(Self.check)] : []
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == logged })
    }

    @Test func setupScriptsReadTheAppsZDOTDIR() async throws {
        let dir = try TempDir()
        let zdot = dir.sub("user-home/z dot")
        let terminals = try Fixture.zshTerminals(
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 },
            environment: ["ZDOTDIR": zdot])
        defer { terminals.closeAll() }
        let script = #"print -r -- "check:$LOADED:${ZDOTDIR-unset}""#
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(script)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(await eventually { pane.screen.text.contains("check:\(loaded):\(zdot)") })
    }
```

- [ ] **Step 3: Run them and watch them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PaneEnvironmentTests|ZshCommandLoggingTests'`
Expected: the three new expectations fail with `ZDOTDIR` missing, and the shells read `~/` instead of `z dot/`.

- [ ] **Step 4: Keep ZDOTDIR**

```swift
    /// What a macOS login session starts with, and the folder zsh reads its startup files from, which the user may
    /// set there. Everything else in the app's environment came from whatever launched it, such as a Claude Code
    /// session running a dev build, and must not reach terminals.
    static let inherited: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "LC_CTYPE",
        "ZDOTDIR",
    ]
```

- [ ] **Step 5: Run the tests again**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git commit -m "fix: keep the app's ZDOTDIR in terminals and setup scripts"
```

## Task 2: The shim puts the user's ZDOTDIR back

**Files:**
- Modify: `Sources/CanopyCore/Terminal/ShellSettings.swift`
- Modify: `Sources/CanopyCore/Terminal/ZshIntegration.swift`
- Test: `Tests/CanopyCoreTests/CommandLoggingTests.swift`

**Interfaces:**
- Consumes: `startupFiles(in:)` and `check` from Task 1.
- Produces: `CANOPY_USER_ZDOTDIR`, set by `interactiveShell` only when the environment had `ZDOTDIR`, and unset by the shim.

- [ ] **Step 1: Write the failing tests**

Run `aZDOTDIRFromTheEnvironmentIsKept` with command logging on too: `@Test(arguments: [false, true])`.

Rewrite `theUsersStartupFilesLoadAsUsual` with the shared check, so it also pins the order:

```swift
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
        ...
        let home = dir.sub("user-home")
        #expect(await run(pane, Self.check, until: "check: .zshenv .zprofile .zshrc .zlogin:unset::none:none:\(home)/.zsh_history"))
```

Make `aZDOTDIRSetInTheUsersZshenvIsFollowed` check the files and the final `ZDOTDIR`, not just an alias:

```swift
        var files = startupFiles(in: "").merging(startupFiles(in: ".config/zsh")) { $1 }
        files[".zshenv", default: ""] += "\nexport ZDOTDIR=$HOME/.config/zsh"
        ...
        let config = dir.sub("user-home/.config/zsh")
        let loaded = " .zshenv .config/zsh/.zprofile .config/zsh/.zshrc .config/zsh/.zlogin"
        #expect(await run(pane, Self.check, until: "check:\(loaded):\(config):\(config):none:none:\(config)/.zsh_history"))
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == [.string(Self.check)] })
```

Add the empty case:

```swift
    @Test func anEmptyZDOTDIRIsKeptAsZshKeepsIt() async throws {
        // zsh reads startup files from a ZDOTDIR that is set, even to nothing, so from /, never from HOME.
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""), environment: ["ZDOTDIR": ""])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(await run(pane, Self.check, until: "check::::none:none:\(dir.sub("user-home"))/.zsh_history"))
    }
```

In `onlyZshShellsGetTheShim`, pass `["ZDOTDIR": "/z"]` and expect zsh's launch to carry `CANOPY_USER_ZDOTDIR == "/z"`, and bash's and the script's to keep `ZDOTDIR == "/z"` with no `CANOPY_USER_ZDOTDIR`.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test $(scripts/test-flags.sh) --filter ZshCommandLoggingTests`
Expected: the `logsCommands: true` case reads `~/` and ends with `ZDOTDIR` unset, and `onlyZshShellsGetTheShim` finds no `CANOPY_USER_ZDOTDIR`.
The empty case fails too, since the shim unsets `ZDOTDIR`.

- [ ] **Step 3: Hand the user's ZDOTDIR to the shim**

```swift
        if reportsCommands, let commandToken, let folder = try? ZshIntegration.install(in: home) {
            // The shim puts it back, or unsets ZDOTDIR if there was none.
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
        # zsh's own rule: a ZDOTDIR that is set, even to nothing, is used instead of HOME.
        [[ -f ${ZDOTDIR-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR-$HOME}/.zshenv"
```

Update the doc comments on `ZshIntegration` and in the shim's header to say it puts back the `ZDOTDIR` Canopy started with.

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

The clone steps already launch the app with `ZDOTDIR="$work/zdot"`, whose `.zshrc` puts the stand-in `gh` on PATH.
After them, open a terminal and check that it sees the same `ZDOTDIR` and found `gh` through it:

```bash
step "terminals keep the ZDOTDIR Canopy started with"
pane=$("$cli" term new --repo acme/app --row main --run 'print -r -- "zd=$ZDOTDIR gh=${commands[gh]}"' --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
wait_for_text "zd=$work/zdot gh=$work/bin/gh" || fail "the terminal did not read $work/zdot"
```

- [ ] **Step 2: Update the spec**

In "Command logging", say that the shim puts back the `ZDOTDIR` Canopy started with, or unsets it, and loads `.zshenv` from there.
In "Starting a shell", say which of the app's variables terminals keep, `ZDOTDIR` among them.

- [ ] **Step 3: Run `make e2e` and commit**

```bash
git commit -m "test: check terminals keep the app's ZDOTDIR end to end"
```

## Task 4: The merge bar

- [ ] `make lint` and `make build` with 0 warnings.
- [ ] Three clean `make test` runs under the shared lock: `lockf -k /tmp/canopy-merge-bar.lock sh -c 'make test && make test && make test'`.
- [ ] `make e2e`.
- [ ] The scratchpad repro (plain zsh against a dev build, in all three cases, for a terminal and a setup script) shows the same files, order, and `ZDOTDIR`.
- [ ] UI check: `scripts/ui-fixture.sh` terminals now read the fixture's `ZDOTDIR`; shoot the window and check the panes look right.
- [ ] An independent opus reviewer on `git diff main...HEAD`, with findings fixed and listed under "After Review".
- [ ] CI `check` green.

## After Review
