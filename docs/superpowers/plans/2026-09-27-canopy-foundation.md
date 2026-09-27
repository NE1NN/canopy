# Canopy Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship everything in Canopy that does not depend on the terminal engine: the project scaffold, the sidebar of repos and rows, and the `canopy` CLI that lets agents create and remove rows.

**Architecture:** One Swift package with a UI-free `CanopyCore` library, a SwiftUI app target, and a thin CLI target.
A `Workspace` actor in the core owns repos and rows, with git as the source of truth and FSEvents for live updates.
The CLI reaches the running app over a Unix socket that speaks newline-delimited JSON, and the app answers through the same `Workspace`.

**Tech Stack:** Swift 6.2 or later with strict concurrency, SwiftUI and AppKit on macOS 15 or later, Swift Testing, swift-argument-parser 1.5 or later, Network.framework, FSEvents, git, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`

## Global Constraints

- macOS 15.0 minimum: `platforms: [.macOS(.v15)]` and `LSMinimumSystemVersion` 15.0.
- `swift-tools-version: 6.2`, Swift 6 language mode, zero compiler warnings.
- Builds with Command Line Tools only and never requires Xcode.
- Run tests with `make test`, never bare `swift test`, because Command Line Tools keep Swift Testing outside the default search paths.
- `swift format lint --strict` passes with the repo's `.swift-format` (4-space indent, 120 columns).
- Bundle IDs are `com.ne1nn.Canopy` for release and `com.ne1nn.Canopy.dev` for dev builds, named "Canopy" and "Canopy Dev".
- `CANOPY_HOME` resolves from the `CANOPY_HOME` variable, then the bundle's `CanopyHome` Info.plist key, then `~/.canopy`. Dev builds use `~/.canopy-dev`.
- The `CANOPY_HOME` folder is mode 0700, and `state.json` and `canopy.sock` are mode 0600.
- Canopy never keeps its own list of worktrees. Git decides which exist.
- Canopy never runs `git worktree remove` on a worktree it did not create.
- The control protocol is version 1: one JSON object per line.
- Conventional commit prefixes (`feat`, `fix`, `chore`, `docs`, `test`, `refactor`), one PR per milestone, and the author reviews and squash-merges every PR. `main` is protected.
- Commit messages carry no AI co-author trailer. PR descriptions end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Markdown files put one sentence per line and never use em dashes.

## Review Focus

1. **Agents creating rows in parallel in one repo**, including branches whose folder names collide (`feat/a` and `feat-a`), should all succeed with distinct folders. Without a per-repo queue, git's lock files make about two runs in three fail. Pinned by `parallelCreatesInOneRepoAllSucceed` in Task 10.
2. **`CANOPY_HOME` reached through a symlink, or not created yet**, such as on first launch or via `/var` versus `/private/var`, must still classify Canopy-made rows as Canopy rows. Pinned by `canonicalResolvesExistingPrefixOfMissingPath` in Task 1 and `homeGivenThroughSymlinkStillClassifiesAsCanopy` in Task 10.
3. **Repo and worktree paths containing spaces** must be discovered, classified, and listed correctly. Pinned by `pathsWithSpacesWork` in Task 8.
4. **A deep `CANOPY_HOME` whose socket path exceeds the 104-byte macOS limit** must make the CLI fail with a clear message instead of crashing. Pinned by `socketPathOverTheLimitFailsClearly` in Task 12.
5. **Relative paths given to the CLI**, such as `canopy repo add .`, must resolve against the caller's folder, not the app's. Pinned by the "relative paths" step of `scripts/e2e.sh` in Task 15.

## Where This Plan Sits

The spec delivers ten PRs.
This plan covers the spike and PRs 2 to 4, none of which depend on the terminal engine:

- **Task 0**: the SwiftTerm spike. Throwaway, and never committed.
- **PR 2, `chore/scaffold`**: Tasks 1 to 3.
- **PR 3, `feat/rows-sidebar`**: Tasks 4 to 9.
- **PR 4, `feat/control-cli`**: Tasks 10 to 15.

PRs 5 to 10 each get their own plan when they are reached, written with the spike's findings in hand.
Row setup and teardown commands move from PR 4 to PR 5, because they run in a visible terminal tab and terminals arrive in PR 5.
The spec's delivery list reflects that.

## Every PR

- Start from the latest `main`: `git switch main && git pull --ff-only && git switch -c <branch>`.
- Before pushing, run `make lint && make build && make test`, and from PR 4 on also `make e2e`.
- Open the PR with `gh pr create`, stop, and wait for the author to review and merge before starting the next PR.

## File Structure

```
Package.swift                         targets: CanopyCore, CanopyApp, CanopyCLI (product "canopy"), CanopyCoreTests
Makefile                              build, test, lint, format, app, release, install, signing-cert, e2e
.swift-format                         formatter and linter settings
Resources/Info.plist.in               app Info.plist template filled in by bundle.sh
scripts/
  test-flags.sh                       Swift Testing search paths for Command Line Tools
  bundle.sh                           builds and signs "Canopy Dev.app" or "Canopy.app" in build/
  make-signing-cert.sh                one-time "Canopy Dev" code signing certificate
  window-shot.swift                   screenshots a process's window for visual checks
  e2e.sh                              drives a dev build through the CLI
Sources/CanopyCore/
  Support/Paths.swift                 canonical paths and containment
  Support/CanopyHome.swift            CANOPY_HOME resolution and derived paths, CanopyVersion
  Git/GitRunner.swift                 runs git, GitError
  Git/Worktree.swift                  Worktree model and `git worktree list --porcelain -z` parser
  Rows/Row.swift                      Row, RowClass, ExternalTag
  Rows/RowClassifier.swift            main, canopy, adopted, or external (tagged)
  Rows/RowOrdering.swift              first-seen order reconciliation
  Rows/BranchSlug.swift               branch name to folder name, collision suffixes
  Repos/RepoNaming.swift              display names and worktree folder names
  State/AppState.swift                what state.json holds
  State/StateStore.swift              atomic load and save, corrupt file backup
  Watch/DirectoryWatcher.swift        FSEvents wrapper
  Watch/GitEventFilter.swift          which git folder events can change the worktree list
  Workspace/Workspace.swift           the actor that owns repos and rows
  Workspace/Workspace+RowLifecycle.swift  create and remove rows
  Workspace/WorkspaceSnapshot.swift   immutable view of repos and rows for the UI and CLI
  Workspace/WorkspaceError.swift      errors with stable codes and user-facing messages
  Control/JSONValue.swift             untyped JSON for request params and results
  Control/ControlProtocol.swift       request, response, error, line codec
  Control/ControlMethods.swift        method names and typed params and results
  Control/TargetResolver.swift        resolves --repo and row arguments
  Control/ControlServer.swift         Unix socket server (Network.framework)
  Control/ControlClient.swift         blocking Unix socket client for the CLI
  Control/WorkspaceControlHandler.swift  maps methods to Workspace calls
Sources/CanopyApp/
  CanopyApp.swift                     app entry, Rows menu with ⌘1 to ⌘9
  AppModel.swift                      main-actor model the views observe
  RootView.swift                      split view, detail placeholder, toasts
  Sidebar/SidebarView.swift           repo sections, rows, other worktrees, add repo
  Sidebar/BranchGlyph.swift           git branch icon
  Sidebar/RowActionViews.swift        new row sheet, remove row popover
Sources/CanopyCLI/
  CanopyCLI.swift                     root command and `status`
  Client.swift                        request helper, app launcher, output
  RepoCommand.swift                   `canopy repo add|list|rm`
  RowCommand.swift                    `canopy row list|new|rm|select|adopt`
Tests/CanopyCoreTests/
  Support/TempDir.swift, Support/Fixtures.swift
  one test file per unit
```

---

## Task 0: SwiftTerm spike (throwaway, never committed)

This answers one question before anything is built on SwiftTerm: does it render heavy agent TUIs like Claude Code correctly and fast enough?
It lives outside the repo and is deleted afterwards.

**Files:**
- Create: `$TMPDIR/canopy-spike/Package.swift`
- Create: `$TMPDIR/canopy-spike/Sources/Spike/main.swift`

- [ ] **Step 1: Create the spike package**

```bash
mkdir -p "$TMPDIR/canopy-spike/Sources/Spike"
```

`$TMPDIR/canopy-spike/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(name: "Spike", dependencies: ["SwiftTerm"])
    ]
)
```

`$TMPDIR/canopy-spike/Sources/Spike/main.swift`:

```swift
import AppKit
import SwiftTerm

/// Throwaway: one SwiftTerm pane running a login shell, instrumented for the checks in the plan.
@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate, @preconcurrency LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminal: LocalProcessTerminalView!
    let dumpPath = FileManager.default.temporaryDirectory.appending(path: "canopy-spike-screen.txt").path

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        terminal = LocalProcessTerminalView(frame: frame)
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.optionAsMetaKey = true
        if ProcessInfo.processInfo.environment["SPIKE_METAL"] == "1" {
            do {
                try terminal.setUseMetal(true)
                print("renderer: metal")
            } catch {
                print("renderer: metal failed (\(error)), using CoreText")
            }
        } else {
            print("renderer: CoreText")
        }
        terminal.getTerminal().registerOscHandler(code: 6973) { bytes in
            print("OSC 6973 received: \(String(decoding: bytes, as: UTF8.self))")
        }
        window.contentView = terminal
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let folder = CommandLine.arguments.dropFirst().first ?? NSHomeDirectory()
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-zsh",
            currentDirectory: folder
        )
        print("shell pid: \(terminal.process.shellPid)")
        print("window: \(window.windowNumber)")
        print("screen dump every 5s: \(dumpPath)")
        scheduleInputs(Array(CommandLine.arguments.dropFirst(2)))
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { self.dumpScreen() }
        }
    }

    /// Each argument after the folder is typed 8 seconds after the previous one, then Return.
    /// "@resize 800x500" resizes the window instead of typing.
    func scheduleInputs(_ inputs: [String]) {
        for (index, input) in inputs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3 + index * 8)) {
                if input.hasPrefix("@resize ") {
                    let size = input.dropFirst("@resize ".count).split(separator: "x").compactMap { Double($0) }
                    self.window.setContentSize(NSSize(width: size[0], height: size[1]))
                    print("resized: \(input)")
                    return
                }
                self.terminal.send(txt: input)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                    self.terminal.send(txt: "\r")
                    print("typed: \(input)")
                }
            }
        }
    }

    func dumpScreen() {
        let buffer = terminal.getTerminal()
        let lines = (0..<buffer.rows).map { buffer.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        try? lines.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        print("size: \(newCols)x\(newRows)")
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title
        print("title: \(title)")
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        print("exited: \(exitCode.map(String.init) ?? "signal")")
    }
}

let app = NSApplication.shared
let delegate = SpikeDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

SwiftTerm's delegate protocol is not main-actor annotated, so the conformance needs `@preconcurrency` under Swift 6.
The terminal layer in PR 5 will need the same.

- [ ] **Step 2: Build**

Run: `cd "$TMPDIR/canopy-spike" && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Rendering with Claude Code**

Use a repo Claude Code already trusts, so no trust prompt swallows the scripted input.

Run: `swift run Spike ~/Projects/fastlane/solis-v1 "claude" "Explain the folder structure of this repo in detail" "@resize 820x520" "@resize 1200x760"`

The spike prints `shell pid:` and `window:`.
Take screenshots at about 20, 45, and 70 seconds with `screencapture -x -o -l <window> spike-<n>.png`.
Record any garbled cells, misaligned box drawing, a cursor in the wrong place, or stale lines after a resize.

- [ ] **Step 4: CPU while streaming**

During Step 3, run `top -l 6 -s 5 -pid <spike pid> -stats pid,cpu` and record the average CPU.

- [ ] **Step 5: Throughput**

Run: `swift run Spike "$TMPDIR" "time (seq 1 1000000)"`
After it finishes, read the `real` line from `$TMPDIR/canopy-spike-screen.txt`.
Pass: under 5 seconds.

- [ ] **Step 6: Screen reading and process ID**

Compare `$TMPDIR/canopy-spike-screen.txt` with a screenshot taken at the same moment. The lines must match.
Run `ps -o pid,ppid,comm -p <shell pid>` and expect `-zsh` whose parent is the spike.

- [ ] **Step 7: Custom OSC sequences**

Run: `swift run Spike "$TMPDIR" "printf '\\e]6973;hello\\a'"`
Expected on the spike's stdout: `OSC 6973 received: hello`

- [ ] **Step 8: Metal renderer**

Repeat Steps 3 and 4 with `SPIKE_METAL=1`.
Record whether it renders at all (Command Line Tools cannot precompile Metal shaders) and its CPU next to CoreText's.

- [ ] **Step 9: Report and decide**

Report to the author in chat: a table of each check with pass or fail, the screenshots, CPU numbers, and a recommendation.
SwiftTerm passes if Claude Code renders without corruption through both resizes, a million lines take under 5 seconds, the screen dump matches, and OSC 6973 arrives.
If it fails, stop here and propose a `docs` PR that amends the spec to libghostty before starting Task 1.
Then delete `$TMPDIR/canopy-spike`.

---

## PR 2: `chore/scaffold`

## Task 1: Package skeleton and `CANOPY_HOME`

**Files:**
- Create: `Package.swift`, `.gitignore`, `.swift-format`, `Makefile`, `scripts/test-flags.sh`
- Create: `Sources/CanopyCore/Support/Paths.swift`, `Sources/CanopyCore/Support/CanopyHome.swift`
- Create: `Sources/CanopyApp/CanopyApp.swift` (placeholder window), `Sources/CanopyCLI/CanopyCLI.swift` (version only)
- Test: `Tests/CanopyCoreTests/Support/TempDir.swift`, `Tests/CanopyCoreTests/CanopyHomeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Paths.canonical(_ path: String) -> String`, `Paths.isInside(_ path: String, _ root: String) -> Bool`, `Paths.homeDirectory: String`
  - `CanopyVersion.current: String`
  - `CanopyHome(root: URL)`, `CanopyHome(path: String)`, `CanopyHome.resolve(environment:bundleHome:) -> CanopyHome`
  - `CanopyHome.environmentKey`, `.infoPlistKey`, `.stateFile`, `.configFile`, `.worktreesRoot`, `.socketPath`, `.ensureExists() throws`
  - Test helper `TempDir` with `.path` (canonical) and `.sub(_:) -> String`

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --ff-only && git switch -c chore/scaffold
```

- [ ] **Step 2: Write the package, build files, and placeholders**

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CanopyApp", targets: ["CanopyApp"]),
        .executable(name: "canopy", targets: ["CanopyCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "CanopyCore"),
        .executableTarget(name: "CanopyApp", dependencies: ["CanopyCore"]),
        .executableTarget(
            name: "CanopyCLI",
            dependencies: [
                "CanopyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CanopyCoreTests", dependencies: ["CanopyCore"]),
    ]
)
```

`.gitignore`:

```gitignore
.build/
build/
.swiftpm/
*.xcodeproj
xcuserdata/
.DS_Store
```

`.swift-format`:

```json
{
    "version": 1,
    "lineLength": 120,
    "indentation": { "spaces": 4 },
    "maximumBlankLines": 1,
    "respectsExistingLineBreaks": true,
    "lineBreakBeforeEachArgument": false,
    "rules": {
        "AllPublicDeclarationsHaveDocumentation": false,
        "AlwaysUseLowerCamelCase": true,
        "NeverForceUnwrap": false,
        "NeverUseForceTry": false,
        "OrderedImports": true,
        "UseLetInEveryBoundCaseVariable": false,
        "ValidateDocumentationComments": false
    }
}
```

`Makefile` (recipe lines are indented with a tab):

```makefile
TEST_FLAGS := $(shell scripts/test-flags.sh)
SOURCES := Package.swift Sources Tests

.PHONY: build test lint format app release install signing-cert clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format --in-place --recursive $(SOURCES)

# Dev build: "Canopy Dev.app", data in ~/.canopy-dev.
app:
	scripts/bundle.sh debug dev

# Release build: "Canopy.app", data in ~/.canopy.
release:
	scripts/bundle.sh release release

install: release
	mkdir -p ~/Applications ~/.local/bin
	rm -rf ~/Applications/Canopy.app
	cp -R build/Canopy.app ~/Applications/Canopy.app
	ln -sf ~/Applications/Canopy.app/Contents/Resources/bin/canopy ~/.local/bin/canopy
	@case ":$$PATH:" in *":$$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to PATH to use canopy outside Canopy";; esac

signing-cert:
	scripts/make-signing-cert.sh

clean:
	rm -rf .build build
```

`scripts/test-flags.sh` (then `chmod +x scripts/test-flags.sh`):

```bash
#!/usr/bin/env bash
# Command Line Tools ship Swift Testing outside the default search paths. Xcode does not need this.
set -euo pipefail
developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    lib="$developer_dir/Library/Developer"
    echo "-Xswiftc -F -Xswiftc $lib/Frameworks -Xlinker -F -Xlinker $lib/Frameworks -Xlinker -rpath -Xlinker $lib/Frameworks -Xlinker -rpath -Xlinker $lib/usr/lib"
fi
```

`Sources/CanopyApp/CanopyApp.swift`:

```swift
import CanopyCore
import SwiftUI

@main
struct CanopyApp: App {
    var body: some Scene {
        Window("Canopy", id: "main") {
            Text("Canopy \(CanopyVersion.current)")
                .foregroundStyle(.secondary)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
```

`Sources/CanopyCLI/CanopyCLI.swift`:

```swift
import ArgumentParser
import CanopyCore

@main
struct CanopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canopy",
        abstract: "Drive Canopy from the command line.",
        version: CanopyVersion.current
    )
}
```

- [ ] **Step 3: Write the failing tests**

`Tests/CanopyCoreTests/Support/TempDir.swift`:

```swift
import Foundation

@testable import CanopyCore

/// A temporary folder that is deleted when the value is released. Paths are canonical.
final class TempDir: Sendable {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "canopy-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = Paths.canonical(url.path)
    }

    func sub(_ name: String) -> String {
        path + "/" + name
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}
```

`Tests/CanopyCoreTests/CanopyHomeTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct CanopyHomeTests {
    @Test func environmentWins() {
        let home = CanopyHome.resolve(environment: ["CANOPY_HOME": "/tmp/x"], bundleHome: "~/.canopy-dev")
        #expect(home.root.path == "/tmp/x")
    }

    @Test func bundleKeyIsSecond() {
        let home = CanopyHome.resolve(environment: [:], bundleHome: "~/.canopy-dev")
        #expect(home.root.path == NSHomeDirectory() + "/.canopy-dev")
    }

    @Test func defaultsToDotCanopy() {
        let home = CanopyHome.resolve(environment: [:], bundleHome: nil)
        #expect(home.root.path == NSHomeDirectory() + "/.canopy")
        #expect(home.socketPath == NSHomeDirectory() + "/.canopy/canopy.sock")
        #expect(home.worktreesRoot.path == NSHomeDirectory() + "/.canopy/worktrees")
    }

    @Test func ensureExistsCreatesPrivateFolder() throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let attributes = try FileManager.default.attributesOfItem(atPath: home.root.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect(FileManager.default.fileExists(atPath: home.worktreesRoot.path))
    }
}

struct PathsTests {
    @Test func canonicalResolvesPrivateSymlink() {
        #expect(Paths.canonical("/tmp") == "/private/tmp")
    }

    @Test func canonicalKeepsMissingPaths() {
        #expect(Paths.canonical("/nope/../nope/x") == "/nope/x")
    }

    @Test func canonicalResolvesExistingPrefixOfMissingPath() {
        #expect(Paths.canonical("/tmp/canopy-not-created-yet/a") == "/private/tmp/canopy-not-created-yet/a")
    }

    @Test func isInsideRespectsFolderBoundaries() {
        #expect(Paths.isInside("/a/b/c", "/a/b"))
        #expect(Paths.isInside("/a/b", "/a/b"))
        #expect(!Paths.isInside("/a/bc", "/a/b"))
    }
}
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'CanopyHome' in scope` and `cannot find 'Paths' in scope`.

- [ ] **Step 5: Implement**

`Sources/CanopyCore/Support/Paths.swift`:

```swift
import Foundation

public enum Paths {
    /// Resolves symlinks with realpath(3). Foundation's resolvingSymlinksInPath strips "/private",
    /// which would make paths from git and from FSEvents disagree. For a path that does not exist yet,
    /// the deepest existing folder is resolved and the rest appended, so it still compares equal later.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = realpath(expanded, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != expanded else { return expanded }
        let last = (expanded as NSString).lastPathComponent
        if last == "." { return canonical(parent) }
        if last == ".." { return (canonical(parent) as NSString).deletingLastPathComponent }
        return (canonical(parent) as NSString).appendingPathComponent(last)
    }

    public static func isInside(_ path: String, _ root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(prefix)
    }

    public static var homeDirectory: String {
        canonical(NSHomeDirectory())
    }
}
```

`Sources/CanopyCore/Support/CanopyHome.swift`:

```swift
import Foundation

public enum CanopyVersion {
    public static let current = "0.1.0"
}

public struct CanopyHome: Sendable, Equatable {
    public static let environmentKey = "CANOPY_HOME"
    public static let infoPlistKey = "CanopyHome"
    public static let defaultPath = "~/.canopy"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(path: String) {
        self.root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Order: the CANOPY_HOME variable, then the app bundle's CanopyHome key, then ~/.canopy.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHome: String? = nil
    ) -> CanopyHome {
        if let path = environment[environmentKey], !path.isEmpty {
            return CanopyHome(path: path)
        }
        if let bundleHome, !bundleHome.isEmpty {
            return CanopyHome(path: bundleHome)
        }
        return CanopyHome(path: defaultPath)
    }

    public var stateFile: URL { root.appending(path: "state.json") }
    public var configFile: URL { root.appending(path: "config.json") }
    public var worktreesRoot: URL { root.appending(path: "worktrees") }
    public var socketPath: String { root.appending(path: "canopy.sock").path }

    public func ensureExists() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try manager.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 6: Run the tests, lint, and the CLI**

Run: `make test`
Expected: `✔ Test run with 8 tests in 2 suites passed`

Run: `make lint`
Expected: no findings.

Run: `swift run canopy --version`
Expected: `0.1.0`

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved .gitignore .swift-format Makefile scripts/test-flags.sh Sources Tests
git commit -m "chore: add package skeleton and CANOPY_HOME resolution"
```

## Task 2: App bundle and signing

**Files:**
- Create: `Resources/Info.plist.in`, `scripts/bundle.sh`, `scripts/make-signing-cert.sh`

**Interfaces:**
- Consumes: `CanopyVersion.current` (read by `bundle.sh` from `CanopyHome.swift`), products `CanopyApp` and `canopy`.
- Produces: `make app` builds `build/Canopy Dev.app`, and `make release` builds `build/Canopy.app`. Both contain `Contents/MacOS/Canopy` and `Contents/Resources/bin/canopy`. `CANOPY_SIGN_IDENTITY=-` signs ad hoc.

- [ ] **Step 1: Write the Info.plist template**

`Resources/Info.plist.in`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Canopy</string>
    <key>CFBundleIdentifier</key>
    <string>@BUNDLE_ID@</string>
    <key>CFBundleName</key>
    <string>@APP_NAME@</string>
    <key>CFBundleDisplayName</key>
    <string>@APP_NAME@</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>@VERSION@</string>
    <key>CFBundleVersion</key>
    <string>@VERSION@</string>
    <key>CanopyHome</key>
    <string>@CANOPY_HOME@</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the bundle script**

`scripts/bundle.sh` (then `chmod +x scripts/bundle.sh`):

```bash
#!/usr/bin/env bash
# Builds Canopy and assembles a signed .app bundle in build/.
# Usage: scripts/bundle.sh <debug|release> <dev|release>
set -euo pipefail
cd "$(dirname "$0")/.."

configuration=${1:-debug}
flavor=${2:-dev}
identity=${CANOPY_SIGN_IDENTITY:-Canopy Dev}

case "$flavor" in
    dev) app_name="Canopy Dev"; bundle_id="com.ne1nn.Canopy.dev"; canopy_home="~/.canopy-dev" ;;
    release) app_name="Canopy"; bundle_id="com.ne1nn.Canopy"; canopy_home="~/.canopy" ;;
    *) echo "unknown flavor: $flavor" >&2; exit 2 ;;
esac

if [[ "$identity" != "-" ]] && ! security find-identity -v -p codesigning | grep -q "\"$identity\""; then
    echo "error: signing identity \"$identity\" not found. Run: make signing-cert" >&2
    echo "       (or CANOPY_SIGN_IDENTITY=- for an ad hoc signature)" >&2
    exit 1
fi

swift build -c "$configuration" --product CanopyApp
swift build -c "$configuration" --product canopy
bin=$(swift build -c "$configuration" --show-bin-path)
version=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/CanopyCore/Support/CanopyHome.swift)

app="build/$app_name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
cp "$bin/CanopyApp" "$app/Contents/MacOS/Canopy"
cp "$bin/canopy" "$app/Contents/Resources/bin/canopy"
sed -e "s|@APP_NAME@|$app_name|g" \
    -e "s|@BUNDLE_ID@|$bundle_id|g" \
    -e "s|@CANOPY_HOME@|$canopy_home|g" \
    -e "s|@VERSION@|$version|g" \
    Resources/Info.plist.in > "$app/Contents/Info.plist"

codesign --force --sign "$identity" --identifier "$bundle_id.cli" "$app/Contents/Resources/bin/canopy"
codesign --force --sign "$identity" --identifier "$bundle_id" "$app"
echo "built $app"
```

- [ ] **Step 3: Write the signing certificate script**

`scripts/make-signing-cert.sh` (then `chmod +x scripts/make-signing-cert.sh`):

```bash
#!/usr/bin/env bash
# Creates a self-signed code signing certificate named "Canopy Dev" in the login keychain.
# A stable identity keeps macOS privacy permissions across rebuilds. macOS asks for your
# password once to trust the certificate for code signing.
set -euo pipefail

name="Canopy Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
    echo "\"$name\" already exists."
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$name" -out "$work/cert.p12" -passout pass:canopy
security import "$work/cert.p12" -k "$keychain" -P canopy -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

security find-identity -v -p codesigning | grep "\"$name\""
```

- [ ] **Step 4: Check the missing-certificate error**

Run: `make app`
Expected, if the certificate does not exist yet: `error: signing identity "Canopy Dev" not found. Run: make signing-cert`

- [ ] **Step 5: Create the certificate**

macOS asks for the login password to trust the certificate, so ask the author to run it in their own terminal with `! make signing-cert`.
Expected: a line containing `"Canopy Dev"`.

- [ ] **Step 6: Build, inspect, and launch the bundle**

Run: `make app`
Expected: `built build/Canopy Dev.app`

Run: `codesign -dv --verbose=2 "build/Canopy Dev.app" 2>&1 | grep -E "Identifier|Authority"`
Expected: `Identifier=com.ne1nn.Canopy.dev` and `Authority=Canopy Dev`

Run: `plutil -p "build/Canopy Dev.app/Contents/Info.plist" | grep CanopyHome`
Expected: `"CanopyHome" => "~/.canopy-dev"`

Run: `open "build/Canopy Dev.app"`
Expected: a window titled Canopy that shows `Canopy 0.1.0`. Quit it afterwards.

- [ ] **Step 7: Commit**

```bash
git add Resources scripts/bundle.sh scripts/make-signing-cert.sh
git commit -m "chore: bundle and sign the app without Xcode"
```

## Task 3: CI, contributor docs, and the PR

**Files:**
- Create: `.github/workflows/ci.yml`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: `make lint`, `make build`, `make test`.
- Produces: a required status check named `check` on `main`.

- [ ] **Step 1: Write the workflow and docs**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  check:
    runs-on: macos-26
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v5
      - uses: actions/cache@v4
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
          restore-keys: spm-${{ runner.os }}-
      - run: swift --version
      - run: make lint
      - run: make build
      - run: make test
```

`CLAUDE.md`:

```markdown
# Canopy

Terminal-first git worktree manager for macOS, driven by AI agents through the `canopy` CLI.
The design lives in `docs/superpowers/specs/2026-09-27-canopy-design.md`.

## Commands

- `make build`, `make test`, `make lint`, `make format`
- `make app` builds `build/Canopy Dev.app` (data in `~/.canopy-dev`)
- `make e2e` drives a dev build through the CLI against a temporary `CANOPY_HOME`
- `make signing-cert` once per machine before `make app`

Use `make test`, not bare `swift test`: Command Line Tools need extra search paths for Swift Testing.

## Layout

- `Sources/CanopyCore`: all logic, no UI. Most tests target this.
- `Sources/CanopyApp`: SwiftUI and AppKit. Keep logic out of views.
- `Sources/CanopyCLI`: the `canopy` client. Talks to the app over `CANOPY_HOME/canopy.sock`.

## Conventions

- Swift 6 language mode with strict concurrency. No warnings.
- Conventional commit prefixes: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`.
- One PR per plan milestone, squash-merged after review.
- Markdown: one sentence per line. No em dashes.
```

`README.md`:

````markdown
# Canopy

A terminal-first git worktree manager for macOS.
Each worktree is a row in the sidebar, each row has tabs, and each tab holds a grid of terminals.
Agents drive it through the `canopy` CLI: create rows, open terminals, run commands, and read screens.

## Build

Requires macOS 15 or later and Swift 6.2 or later. Command Line Tools are enough; Xcode is not required.

```
make signing-cert   # once per machine
make app            # build/Canopy Dev.app
make install        # ~/Applications/Canopy.app and ~/.local/bin/canopy
```

## Develop

```
make test
make lint
```
````

- [ ] **Step 2: Commit and push**

```bash
git add .github CLAUDE.md README.md
git commit -m "chore: add CI and contributor docs"
git push -u origin chore/scaffold
```

- [ ] **Step 3: Open the PR and get CI green**

```bash
gh pr create --title "chore: package scaffold, app bundle, and CI" --body "$(cat <<'EOF'
## Summary

Sets up the Swift package, the no-Xcode build and signing flow, and CI.
The app is a placeholder window, and the CLI only prints its version.

## Testing

- `make test`: 8 tests pass.
- `make lint`: clean.
- `make app` builds and signs `build/Canopy Dev.app`, which launches.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

Expected: the `check` job passes.
If GitHub reports that the `macos-26` label does not exist, or the runner's Swift is older than 6.2, change `runs-on` to the newest macOS label GitHub lists, add a step that runs `sudo xcode-select -s /Applications/Xcode_26*.app` if needed, and push again.

- [ ] **Step 4: Require CI on `main`**

```bash
gh api -X PATCH repos/NE1NN/canopy/branches/main/protection/required_status_checks \
  -F strict=true -f 'contexts[]=check' 2>/dev/null \
|| gh api -X PUT repos/NE1NN/canopy/branches/main/protection --input - <<'EOF'
{"required_status_checks": {"strict": true, "contexts": ["check"]},
 "enforce_admins": true,
 "required_pull_request_reviews": {"required_approving_review_count": 0},
 "restrictions": null}
EOF
```

Expected: the response lists `"contexts": ["check"]`.

- [ ] **Step 5: Stop for review**

Tell the author the PR link and wait until it is merged.

---

## PR 3: `feat/rows-sidebar`

## Task 4: Run git and parse worktree lists

**Files:**
- Create: `Sources/CanopyCore/Git/GitRunner.swift`, `Sources/CanopyCore/Git/Worktree.swift`
- Test: `Tests/CanopyCoreTests/Support/Fixtures.swift`, `Tests/CanopyCoreTests/GitRunnerTests.swift`, `Tests/CanopyCoreTests/WorktreeListParserTests.swift`

**Interfaces:**
- Consumes: `Paths.canonical`, `TempDir`.
- Produces:
  - `GitRunner(executable: String = "/usr/bin/git")`, `run(_ arguments: [String], in directory: String?) async throws -> String`, `succeeds(_:in:) async -> Bool`
  - `GitError { arguments: [String], exitCode: Int32, stderr: String, description: String }`
  - `Worktree { path, head: String?, branch: String?, isBare, isDetached, isLocked, isPrunable }`
  - `WorktreeListParser.parse(_ output: String) -> [Worktree]`, where the first entry is the main worktree
  - Test helpers: `Fixture.repo(in: TempDir, name: String = "demo", origin: Bool = false) async throws -> String`, `Fixture.worktree(repo:branch:at:) async throws`, `eventually(timeout:_:) async -> Bool`

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --ff-only && git switch -c feat/rows-sidebar
```

- [ ] **Step 2: Write the failing tests**

`Tests/CanopyCoreTests/Support/Fixtures.swift`:

```swift
import Foundation

@testable import CanopyCore

enum Fixture {
    static let git = GitRunner()

    /// Creates `<dir>/<name>` with one commit on `main`. With `origin`, also creates a bare
    /// `<dir>/<name>-origin.git`, pushes to it, and sets origin/HEAD.
    @discardableResult
    static func repo(in dir: TempDir, name: String = "demo", origin: Bool = false) async throws -> String {
        let path = dir.sub(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "-b", "main"], in: path)
        try await git.run(["config", "user.email", "test@example.com"], in: path)
        try await git.run(["config", "user.name", "Test"], in: path)
        try await git.run(["commit", "--quiet", "--allow-empty", "-m", "init"], in: path)
        if origin {
            let bare = dir.sub("\(name)-origin.git")
            try await git.run(["init", "--quiet", "--bare", "-b", "main", bare])
            try await git.run(["remote", "add", "origin", bare], in: path)
            try await git.run(["push", "--quiet", "-u", "origin", "main"], in: path)
            try await git.run(["remote", "set-head", "origin", "main"], in: path)
        }
        return Paths.canonical(path)
    }

    static func worktree(repo: String, branch: String, at path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try await git.run(["worktree", "add", "--quiet", "-b", branch, path], in: repo)
    }
}

/// Polls until `condition` holds or the timeout passes. Returns whether it held.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
```

`Tests/CanopyCoreTests/GitRunnerTests.swift`:

```swift
import Testing

@testable import CanopyCore

struct GitRunnerTests {
    @Test func returnsStdout() async throws {
        let output = try await GitRunner().run(["--version"])
        #expect(output.hasPrefix("git version"))
    }

    @Test func throwsWithStderrOnFailure() async throws {
        let dir = try TempDir()
        do {
            try await GitRunner().run(["rev-parse", "HEAD"], in: dir.path)
            Issue.record("expected failure outside a repo")
        } catch let error as GitError {
            #expect(error.exitCode != 0)
            #expect(error.stderr.contains("not a git repository"))
        }
    }

    @Test func succeedsReportsExitStatus() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        #expect(await GitRunner().succeeds(["show-ref", "--verify", "--quiet", "refs/heads/main"], in: repo))
        #expect(!(await GitRunner().succeeds(["show-ref", "--verify", "--quiet", "refs/heads/nope"], in: repo)))
    }
}
```

`Tests/CanopyCoreTests/WorktreeListParserTests.swift`:

```swift
import Testing

@testable import CanopyCore

struct WorktreeListParserTests {
    @Test func parsesMainLinkedDetachedAndPrunable() {
        let output = [
            "worktree /r/main", "HEAD aaa", "branch refs/heads/main", "",
            "worktree /r/wt one", "HEAD bbb", "branch refs/heads/fix/login", "locked", "",
            "worktree /r/detached", "HEAD ccc", "detached", "",
            "worktree /r/gone", "HEAD ddd", "branch refs/heads/old",
            "prunable gitdir file points to non-existent location",
            "", "",
        ].joined(separator: "\0")

        let worktrees = WorktreeListParser.parse(output)

        #expect(
            worktrees == [
                Worktree(path: "/r/main", head: "aaa", branch: "main"),
                Worktree(path: "/r/wt one", head: "bbb", branch: "fix/login", isLocked: true),
                Worktree(path: "/r/detached", head: "ccc", isDetached: true),
                Worktree(path: "/r/gone", head: "ddd", branch: "old", isPrunable: true),
            ]
        )
    }

    @Test func parsesBareMain() {
        let output = ["worktree /r/bare.git", "bare", "", ""].joined(separator: "\0")
        #expect(WorktreeListParser.parse(output) == [Worktree(path: "/r/bare.git", isBare: true)])
    }

    @Test func emptyOutputHasNoWorktrees() {
        #expect(WorktreeListParser.parse("").isEmpty)
    }

    @Test func parsesRealGitOutput() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: dir.sub("wt"))

        let output = try await GitRunner().run(["worktree", "list", "--porcelain", "-z"], in: repo)
        let worktrees = WorktreeListParser.parse(output)

        #expect(worktrees.map(\.branch) == ["main", "feat/x"])
        #expect(Paths.canonical(worktrees[0].path) == repo)
    }
}
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'GitRunner' in scope`.

- [ ] **Step 4: Implement**

`Sources/CanopyCore/Git/GitRunner.swift`:

```swift
import Foundation
import Synchronization

public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String

    public var description: String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(exitCode)" : message
    }
}

public struct GitRunner: Sendable {
    public var executable: String

    public init(executable: String = "/usr/bin/git") {
        self.executable = executable
    }

    @discardableResult
    public func run(_ arguments: [String], in directory: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runBlocking(arguments, in: directory) })
            }
        }
    }

    /// Runs git and reports only whether it exited 0. For probes like `show-ref --verify`.
    public func succeeds(_ arguments: [String], in directory: String? = nil) async -> Bool {
        (try? await run(arguments, in: directory)) != nil
    }

    private func runBlocking(_ arguments: [String], in directory: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let errorData = Mutex(Data())
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorData.withLock { $0 }, as: UTF8.self)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
```

`Sources/CanopyCore/Git/Worktree.swift`:

```swift
public struct Worktree: Sendable, Equatable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(
        path: String,
        head: String? = nil,
        branch: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Parses `git worktree list --porcelain -z`. The first entry is always the main worktree.
public enum WorktreeListParser {
    public static func parse(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var current: Worktree?

        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let finished = current {
                    worktrees.append(finished)
                    current = nil
                }
                continue
            }
            let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""

            switch key {
            case "worktree":
                if let finished = current {
                    worktrees.append(finished)
                }
                current = Worktree(path: value)
            case "HEAD":
                current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "bare":
                current?.isBare = true
            case "detached":
                current?.isDetached = true
            case "locked":
                current?.isLocked = true
            case "prunable":
                current?.isPrunable = true
            default:
                break
            }
        }
        if let finished = current {
            worktrees.append(finished)
        }
        return worktrees
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `make test`
Expected: all tests pass, including `parsesRealGitOutput` and `throwsWithStderrOnFailure`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CanopyCore/Git Tests/CanopyCoreTests
git commit -m "feat: run git and parse worktree lists"
```

## Task 5: Rows, classification, order, and repo names

**Files:**
- Create: `Sources/CanopyCore/Rows/Row.swift`, `Sources/CanopyCore/Rows/RowClassifier.swift`, `Sources/CanopyCore/Rows/RowOrdering.swift`, `Sources/CanopyCore/Repos/RepoNaming.swift`
- Test: `Tests/CanopyCoreTests/RowModelTests.swift`

**Interfaces:**
- Consumes: `Worktree`, `Paths`.
- Produces:
  - `RowClass` (`main`, `canopy`, `adopted`, `external`), `ExternalTag` (`superset`, `conductor`, `other`) with `.label`
  - `Row { repoPath, path, branch, head, rowClass, externalTag, isMissing, id, displayName }`, which encodes `rowClass` as `class`, `externalTag` as `tag`, and `isMissing` as `missing`
  - `RowClassifier(canopyWorktreesRoot:homeDirectory:)` with `classify(path:isMain:adopted:) -> (RowClass, ExternalTag?)` and `rows(for:repoPath:adopted:fileExists:) -> [Row]`
  - `RowOrdering.reconcile(order:present:) -> [String]`
  - `RepoNaming.displayNames(for:) -> [String: String]`, `RepoNaming.dirName(for:taken:) -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/RowModelTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct RowClassifierTests {
    let classifier = RowClassifier(canopyWorktreesRoot: "/h/.canopy/worktrees", homeDirectory: "/h")

    @Test func mainWinsOverEverything() {
        #expect(classifier.classify(path: "/h/.canopy/worktrees/x", isMain: true, adopted: []) == (.main, nil))
    }

    @Test func canopyFolderIsCanopy() {
        #expect(
            classifier.classify(path: "/h/.canopy/worktrees/demo/fix-a", isMain: false, adopted: []) == (.canopy, nil))
    }

    @Test func adoptedPathIsAdopted() {
        let path = "/h/.superset/worktrees/demo/fix"
        #expect(classifier.classify(path: path, isMain: false, adopted: [path]) == (.adopted, nil))
    }

    @Test func externalPathsAreTagged() {
        #expect(
            classifier.classify(path: "/h/.superset/worktrees/d/x", isMain: false, adopted: []) == (
                .external, .superset
            ))
        #expect(
            classifier.classify(path: "/h/conductor/workspaces/d/x", isMain: false, adopted: []) == (
                .external, .conductor
            ))
        #expect(classifier.classify(path: "/elsewhere/x", isMain: false, adopted: []) == (.external, .other))
    }

    @Test func rowsSkipBareAndFlagMissing() {
        let worktrees = [
            Worktree(path: "/r/main", head: "a", branch: "main"),
            Worktree(path: "/h/.canopy/worktrees/demo/x", head: "b", branch: "x", isPrunable: true),
            Worktree(path: "/r/other", head: "c", branch: "y"),
        ]
        let rows = classifier.rows(for: worktrees, repoPath: "/r/main", adopted: [], fileExists: { $0 != "/r/other" })

        #expect(rows.map(\.rowClass) == [.main, .canopy, .external])
        #expect(rows.map(\.isMissing) == [false, true, true])
    }

    @Test func detachedRowShowsShortHash() {
        let row = Row(repoPath: "/r", path: "/r", branch: nil, head: "abcdef1234", rowClass: .main)
        #expect(row.displayName == "abcdef1")
    }
}

struct RowOrderingTests {
    @Test func keepsOrderAndAppendsNewRows() {
        #expect(RowOrdering.reconcile(order: ["b", "a"], present: ["a", "b", "c"]) == ["b", "a", "c"])
    }

    @Test func dropsRowsThatAreGone() {
        #expect(RowOrdering.reconcile(order: ["a", "b"], present: ["b"]) == ["b"])
    }

    @Test func removesDuplicates() {
        #expect(RowOrdering.reconcile(order: ["a", "a"], present: ["a"]) == ["a"])
    }
}

struct RepoNamingTests {
    @Test func usesFolderNames() {
        #expect(RepoNaming.displayNames(for: ["/a/web", "/b/api"]) == ["/a/web": "web", "/b/api": "api"])
    }

    @Test func disambiguatesDuplicatesWithParent() {
        #expect(
            RepoNaming.displayNames(for: ["/work/app", "/personal/app"])
                == ["/work/app": "work/app", "/personal/app": "personal/app"]
        )
    }

    @Test func dirNameAvoidsTakenNames() {
        #expect(RepoNaming.dirName(for: "/x/app", taken: ["app", "app-2"]) == "app-3")
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'RowClassifier' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Rows/Row.swift`:

```swift
public enum RowClass: String, Sendable, Codable {
    case main
    case canopy
    case adopted
    case external
}

public enum ExternalTag: String, Sendable, Codable {
    case superset
    case conductor
    case other

    public var label: String {
        switch self {
        case .superset: "Superset"
        case .conductor: "Conductor"
        case .other: "other"
        }
    }
}

public struct Row: Sendable, Equatable, Identifiable, Codable {
    public var repoPath: String
    public var path: String
    public var branch: String?
    public var head: String?
    public var rowClass: RowClass
    public var externalTag: ExternalTag?
    public var isMissing: Bool

    public var id: String { path }

    public var displayName: String {
        if let branch { return branch }
        if let head { return String(head.prefix(7)) }
        return "(unknown)"
    }

    public init(
        repoPath: String,
        path: String,
        branch: String?,
        head: String?,
        rowClass: RowClass,
        externalTag: ExternalTag? = nil,
        isMissing: Bool = false
    ) {
        self.repoPath = repoPath
        self.path = path
        self.branch = branch
        self.head = head
        self.rowClass = rowClass
        self.externalTag = externalTag
        self.isMissing = isMissing
    }

    enum CodingKeys: String, CodingKey {
        case repoPath, path, branch, head
        case rowClass = "class"
        case externalTag = "tag"
        case isMissing = "missing"
    }
}
```

`Sources/CanopyCore/Rows/RowClassifier.swift`:

```swift
public struct RowClassifier: Sendable {
    public var canopyWorktreesRoot: String
    public var homeDirectory: String

    public init(canopyWorktreesRoot: String, homeDirectory: String) {
        self.canopyWorktreesRoot = canopyWorktreesRoot
        self.homeDirectory = homeDirectory
    }

    public func classify(path: String, isMain: Bool, adopted: Set<String>) -> (RowClass, ExternalTag?) {
        if isMain { return (.main, nil) }
        if Paths.isInside(path, canopyWorktreesRoot) { return (.canopy, nil) }
        if adopted.contains(path) { return (.adopted, nil) }
        if Paths.isInside(path, homeDirectory + "/.superset") { return (.external, .superset) }
        if Paths.isInside(path, homeDirectory + "/conductor") { return (.external, .conductor) }
        return (.external, .other)
    }

    /// Turns parsed worktrees into rows. Bare entries are skipped; the first entry is the main checkout.
    public func rows(
        for worktrees: [Worktree],
        repoPath: String,
        adopted: Set<String>,
        fileExists: (String) -> Bool
    ) -> [Row] {
        worktrees.enumerated().compactMap { index, worktree in
            guard !worktree.isBare else { return nil }
            let path = Paths.canonical(worktree.path)
            let (rowClass, tag) = classify(path: path, isMain: index == 0, adopted: adopted)
            return Row(
                repoPath: repoPath,
                path: path,
                branch: worktree.branch,
                head: worktree.head,
                rowClass: rowClass,
                externalTag: tag,
                isMissing: worktree.isPrunable || !fileExists(path)
            )
        }
    }
}
```

`Sources/CanopyCore/Rows/RowOrdering.swift`:

```swift
public enum RowOrdering {
    /// Keeps the saved order for rows that still exist and appends newly seen rows in discovery order.
    public static func reconcile(order: [String], present: [String]) -> [String] {
        let presentSet = Set(present)
        var seen = Set<String>()
        var result: [String] = []
        for path in order + present where presentSet.contains(path) && !seen.contains(path) {
            result.append(path)
            seen.insert(path)
        }
        return result
    }
}
```

`Sources/CanopyCore/Repos/RepoNaming.swift`:

```swift
import Foundation

public enum RepoNaming {
    /// Folder names, with the parent folder prepended when two repos share a folder name.
    public static func displayNames(for paths: [String]) -> [String: String] {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        var result: [String: String] = [:]
        for (path, name) in zip(paths, names) {
            if counts[name, default: 0] > 1 {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                result[path] = "\(parent)/\(name)"
            } else {
                result[path] = name
            }
        }
        return result
    }

    /// A stable folder name under CANOPY_HOME/worktrees, unique among registered repos.
    public static func dirName(for path: String, taken: Set<String>) -> String {
        let base = URL(fileURLWithPath: path).lastPathComponent
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Rows Sources/CanopyCore/Repos Tests/CanopyCoreTests/RowModelTests.swift
git commit -m "feat: classify and order rows"
```

## Task 6: Persist state

**Files:**
- Create: `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/State/StateStore.swift`
- Test: `Tests/CanopyCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `RepoEntry { path, dirName, adopted: [String], rowOrder: [String] }`
  - `AppState { version, repos: [RepoEntry], selectedRowPath: String? }` with `AppState.currentVersion == 1`
  - `StateStore(url:)` with `load(now:) -> StateLoadResult` and `save(_:) throws`
  - `StateLoadResult` (`.fresh`, `.loaded`, `.recovered(_, backup:)`) with `.state`

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/StateStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct StateStoreTests {
    @Test func missingFileIsFresh() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        #expect(store.load() == .fresh(AppState()))
    }

    @Test func roundTripsAndIsPrivate() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        let state = AppState(
            repos: [RepoEntry(path: "/r", dirName: "r", adopted: ["/x"], rowOrder: ["/x"])],
            selectedRowPath: "/x"
        )

        try store.save(state)

        #expect(store.load() == .loaded(state))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.sub("state.json"))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func toleratesMissingOptionalFields() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 1, "repos": [{"path": "/r", "dirName": "r"}]}"#.write(
            to: url, atomically: true, encoding: .utf8)

        #expect(StateStore(url: url).load() == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r")])))
    }

    @Test func corruptFileIsBackedUp() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try "{not json".write(to: url, atomically: true, encoding: .utf8)

        let result = StateStore(url: url).load(now: Date(timeIntervalSince1970: 1_000))

        #expect(result == .recovered(AppState(), backup: URL(fileURLWithPath: dir.sub("state.json.broken-1000"))))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: dir.sub("state.json.broken-1000")))
    }

    @Test func newerVersionIsBackedUpRatherThanMisread() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 99, "repos": []}"#.write(to: url, atomically: true, encoding: .utf8)

        guard case .recovered = StateStore(url: url).load() else {
            Issue.record("expected recovery")
            return
        }
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'StateStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/State/AppState.swift`:

```swift
public struct RepoEntry: Codable, Sendable, Equatable {
    public var path: String
    public var dirName: String
    public var adopted: [String]
    public var rowOrder: [String]

    public init(path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = []) {
        self.path = path
        self.dirName = dirName
        self.adopted = adopted
        self.rowOrder = rowOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        dirName = try container.decode(String.self, forKey: .dirName)
        adopted = try container.decodeIfPresent([String].self, forKey: .adopted) ?? []
        rowOrder = try container.decodeIfPresent([String].self, forKey: .rowOrder) ?? []
    }
}

/// Everything Canopy persists. New fields must decode with decodeIfPresent so older files still load.
public struct AppState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var repos: [RepoEntry]
    public var selectedRowPath: String?

    public init(version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil) {
        self.version = version
        self.repos = repos
        self.selectedRowPath = selectedRowPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        repos = try container.decodeIfPresent([RepoEntry].self, forKey: .repos) ?? []
        selectedRowPath = try container.decodeIfPresent(String.self, forKey: .selectedRowPath)
    }
}
```

`Sources/CanopyCore/State/StateStore.swift`:

```swift
import Foundation

public enum StateLoadResult: Sendable, Equatable {
    case fresh(AppState)
    case loaded(AppState)
    case recovered(AppState, backup: URL)

    public var state: AppState {
        switch self {
        case .fresh(let state), .loaded(let state), .recovered(let state, _): state
        }
    }
}

public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load(now: Date = Date()) -> StateLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fresh(AppState())
        }
        if let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(AppState.self, from: data),
            state.version <= AppState.currentVersion
        {
            return .loaded(state)
        }
        let backup = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).broken-\(Int(now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return .recovered(AppState(), backup: backup)
    }

    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all tests pass, including `corruptFileIsBackedUp` and `newerVersionIsBackedUpRatherThanMisread`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/State Tests/CanopyCoreTests/StateStoreTests.swift
git commit -m "feat: persist state atomically with corrupt file recovery"
```

## Task 7: Watch git folders

**Files:**
- Create: `Sources/CanopyCore/Watch/DirectoryWatcher.swift`, `Sources/CanopyCore/Watch/GitEventFilter.swift`
- Test: `Tests/CanopyCoreTests/WatchTests.swift`

**Interfaces:**
- Consumes: `Paths.isInside`, `eventually`.
- Produces:
  - `DirectoryWatcher(paths: [String], latency: TimeInterval = 0.1, onChange: @Sendable ([String]) -> Void)`, which stops when released
  - `GitEventFilter.isRelevant(eventPath:gitDir:) -> Bool`

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WatchTests.swift`:

```swift
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct GitEventFilterTests {
    let gitDir = "/r/.git"

    @Test func headAndWorktreeChangesAreRelevant() {
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/HEAD", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/HEAD", gitDir: gitDir))
        #expect(GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/gitdir", gitDir: gitDir))
    }

    @Test func routineGitWritesAreNoise() {
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/index", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/objects/ab/cdef", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/index", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.git/worktrees/fix-a/logs/HEAD", gitDir: gitDir))
        #expect(!GitEventFilter.isRelevant(eventPath: "/r/.gitignore", gitDir: gitDir))
    }
}

final class EventLog: Sendable {
    let paths = Mutex<[String]>([])
}

struct DirectoryWatcherTests {
    @Test func reportsNewFiles() async throws {
        let dir = try TempDir()
        let log = EventLog()
        let watcher = DirectoryWatcher(paths: [dir.path]) { paths in
            log.paths.withLock { $0 += paths }
        }
        try await Task.sleep(for: .milliseconds(300))

        try "x".write(toFile: dir.sub("a.txt"), atomically: false, encoding: .utf8)

        let seen = await eventually { log.paths.withLock { $0 }.contains(dir.sub("a.txt")) }
        #expect(seen)
        _ = watcher
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'GitEventFilter' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Watch/DirectoryWatcher.swift`:

```swift
import CoreServices
import Foundation

/// Recursive FSEvents watch on a set of folders. Delivers file-level event paths on a private queue.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "canopy.directory-watcher")
    private let onChange: @Sendable ([String]) -> Void

    public init(paths: [String], latency: TimeInterval = 0.1, onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.onChange(Array(paths.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard
            let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
```

`Sources/CanopyCore/Watch/GitEventFilter.swift`:

```swift
/// Decides which file events inside a repo's git folder can change its worktree list.
/// Everything else (objects, index, logs, lock files) is noise from normal git use.
public enum GitEventFilter {
    public static func isRelevant(eventPath: String, gitDir: String) -> Bool {
        guard Paths.isInside(eventPath, gitDir), eventPath != gitDir else { return false }
        let relative = eventPath.dropFirst(gitDir.count).split(separator: "/").map(String.init)
        if relative == ["HEAD"] { return true }
        guard relative.first == "worktrees" else { return false }
        if relative.count <= 2 { return true }
        return relative.count == 3 && ["HEAD", "gitdir", "locked"].contains(relative[2])
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all tests pass, including `reportsNewFiles`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Watch Tests/CanopyCoreTests/WatchTests.swift
git commit -m "feat: watch git folders for worktree changes"
```

## Task 8: The Workspace actor

**Files:**
- Create: `Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`
- Test: `Tests/CanopyCoreTests/WorkspaceTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1 and 4 to 7.
- Produces:
  - `RepoSnapshot { path, name, rows, external, isMissing, error, allRows }`
  - `WorkspaceSnapshot { repos, selectedRowPath, visibleRows, row(path:), repo(path:) }`
  - `WorkspaceError` with `.code` and `.message`: `pathNotFound`, `notAGitRepo`, `bareRepo`, `repoNotFound`, `rowNotFound`, `git`
  - `actor Workspace(home: CanopyHome, git: GitRunner = GitRunner())` with:
    - `start() async throws`, `snapshot`, `updates() -> AsyncStream<WorkspaceSnapshot>`, `loadNotice`
    - `addRepo(path:) async throws -> RepoSnapshot`, `removeRepo(path:) throws`, `relocateRepo(path:to:) async throws`
    - `adopt(path:) async throws -> Row`, `unadopt(path:) async throws`, `setSelectedRow(path:) throws`, `prune(repoPath:) async throws`
    - `refresh(repoPath:) async`, `refreshAll() async`
  - Internal to the module, used by Task 10: `state`, `git`, `home`, `save()`, `publish()`, and `serialized(repoPath:_:)`, which runs git changes to one repo one at a time

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WorkspaceTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct WorkspaceTests {
    func makeWorkspace(_ dir: TempDir) async throws -> Workspace {
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")))
        try await workspace.start()
        return workspace
    }

    @Test func addRepoShowsMainRow() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)

        let added = try await workspace.addRepo(path: repo)

        #expect(added.name == "demo")
        #expect(added.rows.map(\.branch) == ["main"])
        #expect(added.rows.first?.rowClass == .main)
    }

    @Test func addRepoFromLinkedWorktreeRegistersMainCheckout() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: dir.sub("linked"))
        let workspace = try await makeWorkspace(dir)

        let added = try await workspace.addRepo(path: dir.sub("linked"))

        #expect(added.path == repo)
    }

    @Test func addRepoIsIdempotent() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)

        try await workspace.addRepo(path: repo)
        try await workspace.addRepo(path: repo)

        #expect(await workspace.snapshot.repos.count == 1)
    }

    @Test func addRepoRejectsNonRepos() async throws {
        let dir = try TempDir()
        let workspace = try await makeWorkspace(dir)

        await #expect(throws: WorkspaceError.pathNotFound(dir.sub("nope"))) {
            try await workspace.addRepo(path: dir.sub("nope"))
        }
        await #expect(throws: WorkspaceError.notAGitRepo(dir.path)) {
            try await workspace.addRepo(path: dir.path)
        }
    }

    @Test func pathsWithSpacesWork() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, name: "my repo")
        try await Fixture.worktree(repo: repo, branch: "feat/x", at: dir.sub("home/worktrees/my repo/feat x"))
        let workspace = try await makeWorkspace(dir)

        let added = try await workspace.addRepo(path: repo)

        #expect(added.name == "my repo")
        #expect(added.rows.map(\.branch) == ["main", "feat/x"])
        #expect(added.rows.last?.path == dir.sub("home/worktrees/my repo/feat x"))
    }

    @Test func worktreeCreatedWithPlainGitAppears() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try await Fixture.worktree(repo: repo, branch: "feat/agent", at: dir.sub("home/worktrees/demo/feat-agent"))

        let appeared = await eventually {
            await workspace.snapshot.repos.first?.rows.contains { $0.branch == "feat/agent" && $0.rowClass == .canopy }
                == true
        }
        #expect(appeared)
    }

    @Test func worktreesElsewhereAreExternalUntilAdopted() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: dir.sub("elsewhere"))
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        var repoSnapshot = try #require(await workspace.snapshot.repos.first)
        #expect(repoSnapshot.rows.map(\.branch) == ["main"])
        #expect(repoSnapshot.external.map(\.externalTag) == [.other])

        let adopted = try await workspace.adopt(path: dir.sub("elsewhere"))

        #expect(adopted.rowClass == .adopted)
        repoSnapshot = try #require(await workspace.snapshot.repos.first)
        #expect(repoSnapshot.rows.map(\.branch) == ["main", "feat/other"])
        #expect(repoSnapshot.external.isEmpty)
    }

    @Test func stateSurvivesRestart() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: dir.sub("elsewhere"))
        let first = try await makeWorkspace(dir)
        try await first.addRepo(path: repo)
        _ = try await first.adopt(path: dir.sub("elsewhere"))
        try await first.setSelectedRow(path: dir.sub("elsewhere"))

        let second = try await makeWorkspace(dir)

        let snapshot = await second.snapshot
        #expect(snapshot.repos.first?.rows.map(\.branch) == ["main", "feat/other"])
        #expect(snapshot.selectedRowPath == dir.sub("elsewhere"))
    }

    @Test func newRowsAppendToTheEnd() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        for branch in ["b", "a", "c"] {
            try await Fixture.worktree(repo: repo, branch: branch, at: dir.sub("home/worktrees/demo/\(branch)"))
            await workspace.refresh(repoPath: repo)
        }

        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main", "b", "a", "c"])
    }

    @Test func deletedWorktreeFolderShowsMissingAndPrunes() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        try await Fixture.worktree(repo: repo, branch: "gone", at: dir.sub("home/worktrees/demo/gone"))
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try FileManager.default.removeItem(atPath: dir.sub("home/worktrees/demo/gone"))
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.rows.last?.isMissing == true)

        try await workspace.prune(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main"])
    }

    @Test func missingRepoFolderIsFlagged() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)
        #expect(await workspace.snapshot.repos.first?.isMissing == true)

        try await workspace.relocateRepo(path: repo, to: dir.sub("moved"))
        let relocated = try #require(await workspace.snapshot.repos.first)
        #expect(relocated.path == dir.sub("moved"))
        #expect(!relocated.isMissing)
    }

    @Test func updatesStreamYieldsChanges() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        var iterator = await workspace.updates().makeAsyncIterator()

        #expect(await iterator.next()?.repos.isEmpty == true)
        try await workspace.addRepo(path: repo)
        var sawRepo = false
        while let snapshot = await iterator.next() {
            if snapshot.repos.first?.rows.isEmpty == false {
                sawRepo = true
                break
            }
        }
        #expect(sawRepo)
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'Workspace' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift`:

```swift
public struct RepoSnapshot: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    /// The main row first, then Canopy and adopted rows in saved order.
    public var rows: [Row]
    /// Worktrees made by other tools, shown collapsed.
    public var external: [Row]
    public var isMissing: Bool
    public var error: String?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        rows: [Row] = [],
        external: [Row] = [],
        isMissing: Bool = false,
        error: String? = nil
    ) {
        self.path = path
        self.name = name
        self.rows = rows
        self.external = external
        self.isMissing = isMissing
        self.error = error
    }

    public var allRows: [Row] { rows + external }
}

public struct WorkspaceSnapshot: Sendable, Equatable {
    public var repos: [RepoSnapshot]
    public var selectedRowPath: String?

    public init(repos: [RepoSnapshot] = [], selectedRowPath: String? = nil) {
        self.repos = repos
        self.selectedRowPath = selectedRowPath
    }

    /// Rows that get ⌘1 to ⌘9, in sidebar order. External rows are excluded.
    public var visibleRows: [Row] { repos.flatMap(\.rows) }

    public func row(path: String) -> Row? {
        repos.lazy.flatMap(\.allRows).first { $0.path == path }
    }

    public func repo(path: String) -> RepoSnapshot? {
        repos.first { $0.path == path }
    }
}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```swift
public enum WorkspaceError: Error, Sendable, Equatable {
    case pathNotFound(String)
    case notAGitRepo(String)
    case bareRepo(String)
    case repoNotFound(String)
    case rowNotFound(String)
    case git(GitError)

    public var code: String {
        switch self {
        case .pathNotFound: "path_not_found"
        case .notAGitRepo: "not_a_git_repo"
        case .bareRepo: "bare_repo"
        case .repoNotFound: "repo_not_found"
        case .rowNotFound: "row_not_found"
        case .git: "git_failed"
        }
    }

    public var message: String {
        switch self {
        case .pathNotFound(let path): "No such folder: \(path)"
        case .notAGitRepo(let path): "Not a git repository: \(path)"
        case .bareRepo(let path): "Bare repositories have no checkout to show: \(path)"
        case .repoNotFound(let name): "No registered repo matches \"\(name)\". Run `canopy repo list`."
        case .rowNotFound(let name): "No row matches \"\(name)\". Run `canopy row list`."
        case .git(let error): error.description
        }
    }
}
```

`Sources/CanopyCore/Workspace/Workspace.swift`:

```swift
import Foundation

/// Owns registered repos and their rows. Git is the source of truth for which worktrees exist;
/// the workspace only persists which repos are registered, adopted paths, and row order.
public actor Workspace {
    public nonisolated let home: CanopyHome
    let git: GitRunner
    let store: StateStore
    let classifier: RowClassifier
    var state = AppState()
    var repoSnapshots: [String: RepoSnapshot] = [:]
    var watchers: [String: DirectoryWatcher] = [:]
    var pendingRefreshes: [String: Task<Void, Never>] = [:]
    var gitQueues: [String: Task<Void, Never>] = [:]
    var subscribers: [UUID: AsyncStream<WorkspaceSnapshot>.Continuation] = [:]
    public private(set) var loadNotice: String?

    public init(home: CanopyHome, git: GitRunner = GitRunner()) {
        self.home = home
        self.git = git
        self.store = StateStore(url: home.stateFile)
        self.classifier = RowClassifier(
            canopyWorktreesRoot: Paths.canonical(home.worktreesRoot.path),
            homeDirectory: Paths.homeDirectory
        )
    }

    public func start() async throws {
        try home.ensureExists()
        let result = store.load()
        state = result.state
        if case .recovered(_, let backup) = result {
            loadNotice =
                "state.json could not be read. It was moved to \(backup.lastPathComponent) and Canopy started fresh."
        }
        for entry in state.repos {
            await watch(repoPath: entry.path)
        }
        await refreshAll()
    }

    public var snapshot: WorkspaceSnapshot {
        let names = RepoNaming.displayNames(for: state.repos.map(\.path))
        let repos = state.repos.map { entry in
            var repo = repoSnapshots[entry.path] ?? RepoSnapshot(path: entry.path, name: "")
            repo.name = names[entry.path] ?? entry.dirName
            return repo
        }
        return WorkspaceSnapshot(repos: repos, selectedRowPath: state.selectedRowPath)
    }

    /// Yields the current snapshot immediately, then every change.
    public func updates() -> AsyncStream<WorkspaceSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: WorkspaceSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    // MARK: Repos

    @discardableResult
    public func addRepo(path: String) async throws -> RepoSnapshot {
        let mainPath = try await mainCheckout(for: path)
        if state.repos.contains(where: { $0.path == mainPath }) {
            return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
        }
        let dirName = RepoNaming.dirName(for: mainPath, taken: Set(state.repos.map(\.dirName)))
        state.repos.append(RepoEntry(path: mainPath, dirName: dirName))
        try save()
        await watch(repoPath: mainPath)
        await refresh(repoPath: mainPath)
        return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
    }

    public func removeRepo(path: String) throws {
        guard let index = state.repos.firstIndex(where: { $0.path == path }) else {
            throw WorkspaceError.repoNotFound(path)
        }
        state.repos.remove(at: index)
        watchers[path] = nil
        pendingRefreshes.removeValue(forKey: path)?.cancel()
        repoSnapshots[path] = nil
        try save()
        publish()
    }

    /// Points a missing repo at its new location, keeping its adopted rows and order.
    public func relocateRepo(path: String, to newPath: String) async throws {
        guard let index = state.repos.firstIndex(where: { $0.path == path }) else {
            throw WorkspaceError.repoNotFound(path)
        }
        let mainPath = try await mainCheckout(for: newPath)
        _ = try? await git.run(["worktree", "repair"], in: mainPath)
        state.repos[index].path = mainPath
        watchers[path] = nil
        repoSnapshots[path] = nil
        try save()
        await watch(repoPath: mainPath)
        await refresh(repoPath: mainPath)
    }

    // MARK: Rows

    public func adopt(path: String) async throws -> Row {
        let canonical = Paths.canonical(path)
        if snapshot.row(path: canonical) == nil {
            await refreshAll()
        }
        guard let row = snapshot.row(path: canonical),
            let index = state.repos.firstIndex(where: { $0.path == row.repoPath })
        else {
            throw WorkspaceError.rowNotFound(path)
        }
        guard row.rowClass == .external else { return row }
        state.repos[index].adopted.append(canonical)
        try save()
        await refresh(repoPath: row.repoPath)
        return snapshot.row(path: canonical) ?? row
    }

    public func unadopt(path: String) async throws {
        guard let index = state.repos.firstIndex(where: { $0.adopted.contains(path) }) else {
            throw WorkspaceError.rowNotFound(path)
        }
        state.repos[index].adopted.removeAll { $0 == path }
        state.repos[index].rowOrder.removeAll { $0 == path }
        if state.selectedRowPath == path {
            state.selectedRowPath = nil
        }
        try save()
        await refresh(repoPath: state.repos[index].path)
    }

    public func setSelectedRow(path: String?) throws {
        guard state.selectedRowPath != path else { return }
        state.selectedRowPath = path
        try save()
        publish()
    }

    public func prune(repoPath: String) async throws {
        try await serialized(repoPath: repoPath) {
            do {
                try await self.git.run(["worktree", "prune"], in: repoPath)
            } catch let error as GitError {
                throw WorkspaceError.git(error)
            }
        }
        await refresh(repoPath: repoPath)
    }

    // MARK: Refreshing

    public func refreshAll() async {
        for path in state.repos.map(\.path) {
            await refresh(repoPath: path)
        }
    }

    public func refresh(repoPath: String) async {
        guard let entry = state.repos.first(where: { $0.path == repoPath }) else { return }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", isMissing: true)
            publish()
            return
        }
        let output: String
        do {
            output = try await git.run(["worktree", "list", "--porcelain", "-z"], in: entry.path)
        } catch {
            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", error: "\(error)")
            publish()
            return
        }
        // The await above let other calls run, so read the entry again before using it.
        guard let index = state.repos.firstIndex(where: { $0.path == repoPath }) else { return }
        let current = state.repos[index]
        let rows = classifier.rows(
            for: WorktreeListParser.parse(output),
            repoPath: current.path,
            adopted: Set(current.adopted),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        let managed = rows.filter { $0.rowClass == .canopy || $0.rowClass == .adopted }
        let order = RowOrdering.reconcile(order: current.rowOrder, present: managed.map(\.path))
        if order != current.rowOrder {
            state.repos[index].rowOrder = order
            try? save()
        }
        let managedByPath = Dictionary(managed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        repoSnapshots[current.path] = RepoSnapshot(
            path: current.path,
            name: "",
            rows: rows.filter { $0.rowClass == .main } + order.compactMap { managedByPath[$0] },
            external: rows.filter { $0.rowClass == .external }
        )
        publish()
    }

    // MARK: Internals

    func mainCheckout(for path: String) async throws -> String {
        let canonical = Paths.canonical(path)
        guard FileManager.default.fileExists(atPath: canonical) else {
            throw WorkspaceError.pathNotFound(path)
        }
        let output: String
        do {
            output = try await git.run(["worktree", "list", "--porcelain", "-z"], in: canonical)
        } catch {
            throw WorkspaceError.notAGitRepo(path)
        }
        guard let main = WorktreeListParser.parse(output).first else {
            throw WorkspaceError.notAGitRepo(path)
        }
        guard !main.isBare else { throw WorkspaceError.bareRepo(path) }
        return Paths.canonical(main.path)
    }

    /// Runs git changes to one repo one at a time. Git takes lock files on config and refs, so parallel
    /// agents adding worktrees to the same repo would otherwise fail on each other. Repos stay parallel.
    func serialized<T: Sendable>(
        repoPath: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = gitQueues[repoPath]
        let task = Task {
            await previous?.value
            return try await operation()
        }
        gitQueues[repoPath] = Task { _ = try? await task.value }
        return try await task.value
    }

    func save() throws {
        try store.save(state)
    }

    func publish() {
        let current = snapshot
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func watch(repoPath: String) async {
        guard
            let gitDir = try? await git.run(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                in: repoPath
            )
        else { return }
        let canonicalGitDir = Paths.canonical(gitDir.trimmingCharacters(in: .whitespacesAndNewlines))
        watchers[repoPath] = DirectoryWatcher(paths: [canonicalGitDir]) { [weak self] paths in
            guard paths.contains(where: { GitEventFilter.isRelevant(eventPath: $0, gitDir: canonicalGitDir) }) else {
                return
            }
            Task { await self?.scheduleRefresh(repoPath: repoPath) }
        }
    }

    private func scheduleRefresh(repoPath: String) {
        pendingRefreshes[repoPath]?.cancel()
        pendingRefreshes[repoPath] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.refresh(repoPath: repoPath)
        }
    }
}
```

- [ ] **Step 4: Run the tests three times**

Run: `for i in 1 2 3; do make test 2>&1 | grep -E "✘|Test run with"; done`
Expected: three passing runs. The watcher test must not flake.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Workspace Tests/CanopyCoreTests/WorkspaceTests.swift
git commit -m "feat: track repos and rows in a workspace actor"
```

## Task 9: The sidebar

**Files:**
- Create: `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/Sidebar/BranchGlyph.swift`, `scripts/window-shot.swift`
- Modify: `Sources/CanopyApp/CanopyApp.swift` (replace the placeholder)

**Interfaces:**
- Consumes: `Workspace`, `WorkspaceSnapshot`, `Row`, `RepoSnapshot`, `WorkspaceError`, `CanopyHome.resolve`.
- Produces:
  - `@MainActor @Observable final class AppModel` with `home`, `workspace`, `snapshot`, `toast`, `selectedRowPath`, `selectedRow`
    - `start()`, `shortcut(for:) -> Int?`, `selectRow(number:)`, `menuTitle(forRow:)`, `refresh()`
    - `addRepo(_:)`, `removeRepo(_:)`, `relocateRepo(_:to:)`, `prune(_:)`
    - `perform(_:)`, `show(_:)`
  - Views: `RootView`, `RowDetailView`, `ToastView`, `SidebarView`, `RepoHeaderView(repo:onLocate:)`, `RowLineView(row:shortcut:)`, `TagView`, `BranchGlyph`, `BranchIcon`
  - `swift scripts/window-shot.swift <pid> <out.png>`

This task is UI, so it is verified by running the app against real repos rather than by unit tests.

- [ ] **Step 1: Write the app model and views**

`Sources/CanopyApp/AppModel.swift`:

```swift
import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let home: CanopyHome
    let workspace: Workspace
    private(set) var snapshot = WorkspaceSnapshot()
    private(set) var toast: String?
    var selectedRowPath: String? {
        didSet {
            if selectedRowPath != oldValue { selectionChanged() }
        }
    }
    private var started = false
    private var toastTask: Task<Void, Never>?

    init(home: CanopyHome) {
        self.home = home
        self.workspace = Workspace(home: home)
    }

    var selectedRow: Row? {
        selectedRowPath.flatMap { snapshot.row(path: $0) }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await workspace.start()
        } catch {
            show(error)
            return
        }
        if let notice = await workspace.loadNotice {
            show(notice)
        }
        let updates = await workspace.updates()
        Task { [weak self] in
            for await snapshot in updates {
                self?.apply(snapshot)
            }
        }
    }

    // MARK: Rows

    /// ⌘1 to ⌘9, in sidebar order across repos.
    func shortcut(for row: Row) -> Int? {
        guard let index = snapshot.visibleRows.firstIndex(where: { $0.path == row.path }), index < 9 else {
            return nil
        }
        return index + 1
    }

    func selectRow(number: Int) {
        let rows = snapshot.visibleRows
        guard number >= 1, number <= rows.count else { return }
        selectedRowPath = rows[number - 1].path
    }

    func menuTitle(forRow number: Int) -> String {
        let rows = snapshot.visibleRows
        return number <= rows.count ? rows[number - 1].displayName : "Row \(number)"
    }

    func refresh() {
        Task { await workspace.refreshAll() }
    }

    // MARK: Repos

    func addRepo(_ url: URL) {
        perform { try await $0.addRepo(path: url.path) }
    }

    func removeRepo(_ repo: RepoSnapshot) {
        perform { try await $0.removeRepo(path: repo.path) }
    }

    func relocateRepo(_ repo: RepoSnapshot, to url: URL) {
        perform { try await $0.relocateRepo(path: repo.path, to: url.path) }
    }

    func prune(_ repo: RepoSnapshot) {
        perform { try await $0.prune(repoPath: repo.path) }
    }

    // MARK: Internals

    private func apply(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        if selectedRowPath == nil, let saved = snapshot.selectedRowPath, snapshot.row(path: saved) != nil {
            selectedRowPath = saved
        } else if let path = selectedRowPath, snapshot.row(path: path) == nil {
            selectedRowPath = nil
        }
    }

    private func selectionChanged() {
        let path = selectedRowPath
        if let path, snapshot.row(path: path)?.rowClass == .external {
            perform { _ = try await $0.adopt(path: path) }
        }
        perform { try await $0.setSelectedRow(path: path) }
    }

    func perform(_ action: @escaping @Sendable (Workspace) async throws -> Void) {
        Task {
            do {
                try await action(workspace)
            } catch {
                show(error)
            }
        }
    }

    func show(_ error: any Error) {
        show((error as? WorkspaceError)?.message ?? "\(error)")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
```

`Sources/CanopyApp/CanopyApp.swift` (replaces the placeholder):

```swift
import AppKit
import CanopyCore
import SwiftUI

@main
struct CanopyApp: App {
    @State private var model = AppModel(
        home: CanopyHome.resolve(
            bundleHome: Bundle.main.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
        )
    )

    var body: some Scene {
        Window("Canopy", id: "main") {
            RootView()
                .environment(model)
        }
        .commands {
            RowCommands(model: model)
        }
    }
}

struct RowCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Rows") {
            ForEach(1...9, id: \.self) { number in
                Button(model.menuTitle(forRow: number)) {
                    model.selectRow(number: number)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                .disabled(model.snapshot.visibleRows.count < number)
            }
        }
    }
}
```

`Sources/CanopyApp/RootView.swift`:

```swift
import AppKit
import CanopyCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            RowDetailView()
        }
        .frame(minWidth: 900, minHeight: 560)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

struct RowDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.selectedRow {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(row.displayName)
                } icon: {
                    BranchIcon()
                }
                .font(.title2)
                Text(row.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(row.displayName)
        } else {
            ContentUnavailableView(
                "No Row Selected",
                systemImage: "sidebar.left",
                description: Text("Pick a row in the sidebar, or add a repo to get started.")
            )
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```swift
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var folderRequest: FolderRequest?

    enum FolderRequest {
        case addRepo
        case locate(RepoSnapshot)
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRowPath) {
            ForEach(model.snapshot.repos) { repo in
                Section {
                    ForEach(repo.rows) { row in
                        RowLineView(row: row, shortcut: model.shortcut(for: row))
                            .tag(row.path)
                            .contextMenu {
                                if row.isMissing {
                                    Button("Prune Missing Worktrees") { model.prune(repo) }
                                }
                            }
                    }
                    if !repo.external.isEmpty {
                        DisclosureGroup("Other worktrees (\(repo.external.count))") {
                            ForEach(repo.external) { row in
                                RowLineView(row: row, shortcut: nil)
                                    .tag(row.path)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    RepoHeaderView(repo: repo) { folderRequest = .locate(repo) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.snapshot.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repos", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository to see its worktrees.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                folderRequest = .addRepo
            } label: {
                Label("Add Repo", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: Binding(get: { folderRequest != nil }, set: { if !$0 { folderRequest = nil } }),
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result, let request = folderRequest else { return }
            switch request {
            case .addRepo: model.addRepo(url)
            case .locate(let repo): model.relocateRepo(repo, to: url)
            }
        }
    }
}

struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onLocate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(repo.name)
            if repo.isMissing {
                TagView(text: "missing")
            }
            if let error = repo.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
        }
        .contextMenu {
            if repo.isMissing {
                Button("Locate…", action: onLocate)
            }
            Button("Remove Repo from Canopy") { model.removeRepo(repo) }
        }
    }
}

struct RowLineView: View {
    let row: Row
    let shortcut: Int?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            BranchIcon(color: row.isMissing ? .secondary : .green)
            Text(row.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isMissing ? .secondary : .primary)
            if let tag = row.externalTag {
                TagView(text: tag.label)
            }
            if row.isMissing {
                TagView(text: "missing")
            }
            Spacer(minLength: 4)
            if isHovering, let shortcut {
                Text("⌘\(shortcut)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(row.path)
    }
}

struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
```

`Sources/CanopyApp/Sidebar/BranchGlyph.swift`:

```swift
import SwiftUI

/// The git branch mark: a trunk with a commit at each end and a branch curving in from the right.
/// Drawn on a 24-point grid and scaled to the frame, so it stays crisp at any size.
struct BranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        var path = Path()
        path.move(to: CGPoint(x: 6, y: 3))
        path.addLine(to: CGPoint(x: 6, y: 15))
        path.addEllipse(in: CGRect(x: 15, y: 3, width: 6, height: 6))
        path.addEllipse(in: CGRect(x: 3, y: 15, width: 6, height: 6))
        path.move(to: CGPoint(x: 18, y: 9))
        path.addQuadCurve(to: CGPoint(x: 9, y: 18), control: CGPoint(x: 18, y: 18))
        return path.applying(transform)
    }
}

struct BranchIcon: View {
    var color: Color = .green

    var body: some View {
        BranchGlyph()
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 14)
    }
}
```

`scripts/window-shot.swift`:

```swift
// Captures the main window of a process, even when it is behind other apps or not yet shown. Usage: swift scripts/window-shot.swift <pid> <out.png>
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let output = CommandLine.arguments[2]
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
guard
    let window = windows.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
    }),
    let number = window[kCGWindowNumber as String] as? Int
else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
    exit(1)
}
let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-o", "-l", String(number), output]
try capture.run()
capture.waitUntilExit()
exit(capture.terminationStatus)
```

- [ ] **Step 2: Build without warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:"`
Expected: no output.

- [ ] **Step 3: Run against real repos with a scratch home**

Seed a scratch `CANOPY_HOME` with one of the author's real repos and a preselected Superset worktree, so the run exercises external rows and adopt-on-select without clicking.
Canopy only reads these repos. It writes nothing outside the scratch home.

```bash
make app
home=$(mktemp -d -t canopy-ui)/home && mkdir -p "$home"
repo=$(git -C ~/Projects/fastlane/solis-v1 rev-parse --show-toplevel)
pick=$(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree \(.*\/\.superset\/.*\)/\1/p' | head -1)
cat > "$home/state.json" <<EOF
{"version": 1, "repos": [{"path": "$repo", "dirName": "solis-v1"}], "selectedRowPath": "$pick"}
EOF
open -n --env CANOPY_HOME="$home" "build/Canopy Dev.app"
sleep 4
pid=$(pgrep -nf "build/Canopy Dev.app/Contents/MacOS/Canopy")
swift scripts/window-shot.swift "$pid" build/sidebar.png
cat "$home/state.json"
```

Expected in `state.json`: the Superset path appears under `adopted` and `rowOrder`.
Expected in `build/sidebar.png`:
- The `solis-v1` section shows `main` and then the adopted row, which is selected.
- A collapsed "Other worktrees (N)" line sits below them.
- Each row has the green branch glyph (a trunk with a curved branch), not a Y-shaped arrow.
- The detail pane shows the selected row's branch and path.

Then check by hand with the author, since this session cannot click:
- Hovering a row shows its `⌘N` hint.
- The Rows menu lists the first nine rows with ⌘1 to ⌘9.
- Expanding "Other worktrees" shows Superset and Conductor tags.

Quit the scratch instance with `kill "$pid"`.

- [ ] **Step 4: Lint, test, and commit**

```bash
make lint && make test
git add Sources/CanopyApp scripts/window-shot.swift
git commit -m "feat: show repos and rows in the sidebar"
```

- [ ] **Step 5: Push, open the PR, and stop for review**

```bash
git push -u origin feat/rows-sidebar
gh pr create --title "feat: show repos and rows in the sidebar" --body "$(cat <<'EOF'
## Summary

Canopy now shows registered repos and their worktrees.
Git decides which worktrees exist; Canopy classifies them as main, Canopy-made, adopted, or external.
External worktrees (Superset, Conductor, elsewhere) sit in a collapsed group and are adopted when selected.
A worktree created with plain git appears within a second through FSEvents.

## Testing

- `make test`: 47 tests pass, including real git repos, FSEvents, and paths with spaces.
- Ran the dev build against solis-v1 with a scratch `CANOPY_HOME`. Screenshot attached.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

Attach `build/sidebar.png` to the PR description or a comment, then wait for the author to merge.

---

## PR 4: `feat/control-cli`

## Task 10: Create and remove rows

**Files:**
- Create: `Sources/CanopyCore/Rows/BranchSlug.swift`, `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`
- Modify: `Sources/CanopyCore/Workspace/WorkspaceError.swift` (replace with the version below, which adds seven cases)
- Test: `Tests/CanopyCoreTests/BranchSlugTests.swift`, `Tests/CanopyCoreTests/RowLifecycleTests.swift`

**Interfaces:**
- Consumes: `Workspace` internals from Task 8 (`state`, `git`, `home`, `snapshot`, `save()`, `refresh(repoPath:)`, `unadopt(path:)`, `serialized(repoPath:_:)`).
- Produces:
  - `BranchSlug.slug(for:) -> String`, `BranchSlug.folder(for:in:exists:) -> URL`
  - `CreatedRow { row: Row, warnings: [String] }`
  - `Workspace.createRow(repoPath:branch:base:) async throws -> CreatedRow`
  - `Workspace.removeRow(path:force:deleteBranch:) async throws`
  - New `WorkspaceError` cases: `ambiguousRow(String, repos:)`, `missingTarget(flag:)`, `invalidBranch`, `branchCheckedOut`, `worktreeDirty`, `cannotRemoveMain`, `notManaged`

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --ff-only && git switch -c feat/control-cli
```

- [ ] **Step 2: Write the failing tests**

`Tests/CanopyCoreTests/BranchSlugTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct BranchSlugTests {
    @Test func replacesSlashes() {
        #expect(BranchSlug.slug(for: "fix/auth/login") == "fix-auth-login")
    }

    @Test func avoidsExistingFolders() {
        let parent = URL(fileURLWithPath: "/w")
        let taken: Set<String> = ["/w/fix-a", "/w/fix-a-2"]
        let folder = BranchSlug.folder(for: "fix/a", in: parent) { taken.contains($0.path) }
        #expect(folder.path == "/w/fix-a-3")
    }
}
```

`Tests/CanopyCoreTests/RowLifecycleTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct RowLifecycleTests {
    let git = GitRunner()

    /// The caller owns `dir`; releasing it deletes the folder mid-test.
    func setUp(_ dir: TempDir, origin: Bool = true) async throws -> (String, Workspace) {
        let repo = try await Fixture.repo(in: dir, origin: origin)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")))
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        return (repo, workspace)
    }

    @Test func createsNewBranchFromOriginDefault() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/new")

        #expect(created.row.path == dir.sub("home/worktrees/demo/feat-new"))
        #expect(created.row.rowClass == .canopy)
        #expect(created.warnings.isEmpty)
        let base = try await git.run(["rev-parse", "origin/main"], in: repo)
        let head = try await git.run(["rev-parse", "HEAD"], in: created.row.path)
        #expect(head == base)
        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main", "feat/new"])
    }

    @Test func homeGivenThroughSymlinkStillClassifiesAsCanopy() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        // TempDir paths start with /private/var; /var is a symlink to it. The home folder does not exist yet.
        let aliasedHome = dir.sub("home").replacingOccurrences(of: "/private/var/", with: "/var/")
        #expect(aliasedHome != dir.sub("home"))
        let workspace = Workspace(home: CanopyHome(path: aliasedHome))
        try await workspace.start()
        try await workspace.addRepo(path: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/aliased")

        #expect(created.row.rowClass == .canopy)
    }

    @Test func checksOutExistingLocalBranch() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/local"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/local")

        #expect(created.row.branch == "feat/local")
    }

    @Test func tracksBranchThatOnlyExistsOnOrigin() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await git.run(["branch", "feat/remote"], in: repo)
        try await git.run(["push", "--quiet", "origin", "feat/remote"], in: repo)
        try await git.run(["branch", "-D", "feat/remote"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/remote")

        let upstream = try await git.run(["rev-parse", "--abbrev-ref", "feat/remote@{upstream}"], in: created.row.path)
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/feat/remote")
    }

    @Test func worksWithoutOrigin() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir, origin: false)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/offline")

        #expect(created.row.branch == "feat/offline")
    }

    @Test func honorsExplicitBase() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await git.run(["commit", "--quiet", "--allow-empty", "-m", "second"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/based", base: "main")

        let expected = try await git.run(["rev-parse", "main"], in: repo)
        #expect(try await git.run(["rev-parse", "HEAD"], in: created.row.path) == expected)
    }

    @Test func rejectsInvalidAndCheckedOutBranches() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)

        await #expect(throws: WorkspaceError.invalidBranch("bad name")) {
            try await workspace.createRow(repoPath: repo, branch: "bad name")
        }
        await #expect(throws: WorkspaceError.branchCheckedOut("main")) {
            try await workspace.createRow(repoPath: repo, branch: "main")
        }
    }

    @Test func slugCollisionGetsSuffix() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try FileManager.default.createDirectory(
            atPath: dir.sub("home/worktrees/demo/feat-a"), withIntermediateDirectories: true)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/a")

        #expect(created.row.path == dir.sub("home/worktrees/demo/feat-a-2"))
    }

    @Test func parallelCreatesInOneRepoAllSucceed() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        for branch in ["feat/remote-a", "feat/remote-b"] {
            try await git.run(["branch", branch], in: repo)
            try await git.run(["push", "--quiet", "origin", branch], in: repo)
            try await git.run(["branch", "-D", branch], in: repo)
        }

        // Two branches share the folder slug "feat-a", and two need tracking config written.
        async let first = workspace.createRow(repoPath: repo, branch: "feat/a")
        async let second = workspace.createRow(repoPath: repo, branch: "feat-a")
        async let third = workspace.createRow(repoPath: repo, branch: "feat/remote-a")
        async let fourth = workspace.createRow(repoPath: repo, branch: "feat/remote-b")
        let created = try await [first, second, third, fourth]

        #expect(Set(created.map(\.row.path)).count == 4)
        #expect(created.allSatisfy { $0.warnings.isEmpty })
        #expect(await workspace.snapshot.repos.first?.rows.count == 5)
    }

    @Test func removesCleanRowAndOptionallyItsBranch() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        let created = try await workspace.createRow(repoPath: repo, branch: "feat/done")

        try await workspace.removeRow(path: created.row.path, deleteBranch: true)

        #expect(!FileManager.default.fileExists(atPath: created.row.path))
        #expect(!(await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/done"], in: repo)))
        #expect(await workspace.snapshot.repos.first?.rows.map(\.branch) == ["main"])
    }

    @Test func dirtyRowNeedsForce() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        let created = try await workspace.createRow(repoPath: repo, branch: "feat/dirty")
        try "x".write(toFile: created.row.path + "/new.txt", atomically: true, encoding: .utf8)

        await #expect(throws: WorkspaceError.worktreeDirty(created.row.path)) {
            try await workspace.removeRow(path: created.row.path)
        }
        try await workspace.removeRow(path: created.row.path, force: true)
        #expect(!FileManager.default.fileExists(atPath: created.row.path))
    }

    @Test func removingAdoptedRowOnlyUnadopts() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        _ = try await workspace.adopt(path: dir.sub("theirs"))

        try await workspace.removeRow(path: dir.sub("theirs"))

        #expect(FileManager.default.fileExists(atPath: dir.sub("theirs")))
        #expect(await workspace.snapshot.repos.first?.external.map(\.branch) == ["feat/theirs"])
    }

    @Test func mainAndExternalRowsCannotBeRemoved() async throws {
        let dir = try TempDir()
        let (repo, workspace) = try await setUp(dir)
        try await Fixture.worktree(repo: repo, branch: "feat/theirs", at: dir.sub("theirs"))
        await workspace.refresh(repoPath: repo)

        await #expect(throws: WorkspaceError.cannotRemoveMain) {
            try await workspace.removeRow(path: repo)
        }
        await #expect(throws: WorkspaceError.notManaged(dir.sub("theirs"))) {
            try await workspace.removeRow(path: dir.sub("theirs"))
        }
    }
}
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'BranchSlug' in scope` and `value of type 'Workspace' has no member 'createRow'`.

- [ ] **Step 4: Implement**

`Sources/CanopyCore/Rows/BranchSlug.swift`:

```swift
import Foundation

public enum BranchSlug {
    public static func slug(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// Picks `<parent>/<slug>`, adding -2, -3, ... until the folder does not exist.
    public static func folder(for branch: String, in parent: URL, exists: (URL) -> Bool) -> URL {
        let base = slug(for: branch)
        var candidate = parent.appending(path: base)
        var suffix = 2
        while exists(candidate) {
            candidate = parent.appending(path: "\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift` (full replacement):

```swift
public enum WorkspaceError: Error, Sendable, Equatable {
    case pathNotFound(String)
    case notAGitRepo(String)
    case bareRepo(String)
    case repoNotFound(String)
    case rowNotFound(String)
    case ambiguousRow(String, repos: [String])
    case missingTarget(flag: String)
    case invalidBranch(String)
    case branchCheckedOut(String)
    case worktreeDirty(String)
    case cannotRemoveMain
    case notManaged(String)
    case git(GitError)

    public var code: String {
        switch self {
        case .pathNotFound: "path_not_found"
        case .notAGitRepo: "not_a_git_repo"
        case .bareRepo: "bare_repo"
        case .repoNotFound: "repo_not_found"
        case .rowNotFound: "row_not_found"
        case .ambiguousRow: "ambiguous_row"
        case .missingTarget: "missing_target"
        case .invalidBranch: "invalid_branch"
        case .branchCheckedOut: "branch_checked_out"
        case .worktreeDirty: "worktree_dirty"
        case .cannotRemoveMain: "cannot_remove_main"
        case .notManaged: "not_managed"
        case .git: "git_failed"
        }
    }

    public var message: String {
        switch self {
        case .pathNotFound(let path): "No such folder: \(path)"
        case .notAGitRepo(let path): "Not a git repository: \(path)"
        case .bareRepo(let path): "Bare repositories have no checkout to show: \(path)"
        case .repoNotFound(let name): "No registered repo matches \"\(name)\". Run `canopy repo list`."
        case .rowNotFound(let name): "No row matches \"\(name)\". Run `canopy row list`."
        case .ambiguousRow(let name, let repos):
            "\"\(name)\" exists in several repos (\(repos.joined(separator: ", "))). Pass --repo."
        case .missingTarget(let flag): "Could not tell which one you mean. Pass \(flag)."
        case .invalidBranch(let name): "Not a valid branch name: \(name)"
        case .branchCheckedOut(let name): "Branch \(name) is already checked out in another worktree."
        case .worktreeDirty(let path): "\(path) has uncommitted changes. Pass --force to remove it anyway."
        case .cannotRemoveMain: "The main checkout cannot be removed."
        case .notManaged(let path): "\(path) belongs to another tool. Adopt it first."
        case .git(let error): error.description
        }
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`:

```swift
import Foundation

public struct CreatedRow: Sendable, Equatable {
    public var row: Row
    public var warnings: [String]
}

extension Workspace {
    /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/.
    /// An existing local branch is checked out, a branch only on origin is tracked,
    /// and anything else is created from `base` (default: origin's default branch).
    public func createRow(repoPath: String, branch: String, base: String? = nil) async throws -> CreatedRow {
        try await serialized(repoPath: repoPath) {
            try await self.createRowNow(repoPath: repoPath, branch: branch, base: base)
        }
    }

    /// Removes a Canopy row's worktree, or un-adopts an adopted row without touching its files.
    public func removeRow(path: String, force: Bool = false, deleteBranch: Bool = false) async throws {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        try await serialized(repoPath: row.repoPath) {
            try await self.removeRowNow(path: path, force: force, deleteBranch: deleteBranch)
        }
    }

    private func createRowNow(repoPath: String, branch: String, base: String?) async throws -> CreatedRow {
        let index = try entryIndex(repoPath: repoPath)
        let dirName = state.repos[index].dirName
        var warnings: [String] = []

        guard await git.succeeds(["check-ref-format", "--branch", branch], in: repoPath) else {
            throw WorkspaceError.invalidBranch(branch)
        }
        if snapshot.repo(path: repoPath)?.allRows.contains(where: { $0.branch == branch }) == true {
            throw WorkspaceError.branchCheckedOut(branch)
        }

        let hasOrigin = await git.succeeds(["remote", "get-url", "origin"], in: repoPath)
        if hasOrigin {
            do {
                try await git.run(["fetch", "--quiet", "origin"], in: repoPath)
            } catch {
                warnings.append("git fetch failed, so the row starts from local refs: \(error)")
            }
        }

        let parent = home.worktreesRoot.appending(path: dirName)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = BranchSlug.folder(for: branch, in: parent) { FileManager.default.fileExists(atPath: $0.path) }

        var arguments = ["worktree", "add"]
        if await git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoPath) {
            arguments += [folder.path, branch]
        } else if hasOrigin,
            await git.succeeds(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: repoPath)
        {
            arguments += ["--track", "-b", branch, folder.path, "origin/\(branch)"]
        } else {
            let start: String
            if let base {
                start = base
            } else {
                start = await defaultBase(repoPath: repoPath, hasOrigin: hasOrigin)
            }
            arguments += ["--no-track", "-b", branch, folder.path, start]
        }

        do {
            try await git.run(arguments, in: repoPath)
        } catch let error as GitError {
            if error.stderr.contains("already checked out") || error.stderr.contains("already used by worktree") {
                throw WorkspaceError.branchCheckedOut(branch)
            }
            throw WorkspaceError.git(error)
        }

        let path = Paths.canonical(folder.path)
        if let current = try? entryIndex(repoPath: repoPath), !state.repos[current].rowOrder.contains(path) {
            state.repos[current].rowOrder.append(path)
            try save()
        }
        await refresh(repoPath: repoPath)
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        return CreatedRow(row: row, warnings: warnings)
    }

    private func removeRowNow(path: String, force: Bool, deleteBranch: Bool) async throws {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        switch row.rowClass {
        case .main:
            throw WorkspaceError.cannotRemoveMain
        case .external:
            throw WorkspaceError.notManaged(path)
        case .adopted:
            try await unadopt(path: path)
        case .canopy:
            var arguments = ["worktree", "remove"]
            if force { arguments.append("--force") }
            arguments.append(path)
            do {
                try await git.run(arguments, in: row.repoPath)
            } catch let error as GitError {
                if error.stderr.contains("modified or untracked files") {
                    throw WorkspaceError.worktreeDirty(path)
                }
                throw WorkspaceError.git(error)
            }
            if deleteBranch, let branch = row.branch {
                do {
                    try await git.run(["branch", "-D", branch], in: row.repoPath)
                } catch let error as GitError {
                    throw WorkspaceError.git(error)
                }
            }
            if let index = try? entryIndex(repoPath: row.repoPath) {
                state.repos[index].rowOrder.removeAll { $0 == path }
            }
            if state.selectedRowPath == path {
                state.selectedRowPath = nil
            }
            try save()
            await refresh(repoPath: row.repoPath)
        }
    }

    func entryIndex(repoPath: String) throws -> Int {
        guard let index = state.repos.firstIndex(where: { $0.path == repoPath }) else {
            throw WorkspaceError.repoNotFound(repoPath)
        }
        return index
    }

    func defaultBase(repoPath: String, hasOrigin: Bool) async -> String {
        if hasOrigin,
            let head = try? await git.run(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repoPath)
        {
            return head.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "HEAD"
    }
}
```

- [ ] **Step 5: Run the tests three times**

Run: `for i in 1 2 3; do make test 2>&1 | grep -E "✘|Test run with"; done`
Expected: three passing runs. `parallelCreatesInOneRepoAllSucceed` must pass every time; it is the guard against git lock races.

- [ ] **Step 6: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: create and remove rows"
```

## Task 11: Control protocol and target resolution

**Files:**
- Create: `Sources/CanopyCore/Control/JSONValue.swift`, `Sources/CanopyCore/Control/ControlProtocol.swift`, `Sources/CanopyCore/Control/ControlMethods.swift`, `Sources/CanopyCore/Control/TargetResolver.swift`
- Test: `Tests/CanopyCoreTests/ControlProtocolTests.swift`, `Tests/CanopyCoreTests/TargetResolverTests.swift`

**Interfaces:**
- Consumes: `WorkspaceSnapshot`, `RepoSnapshot`, `Row`, `WorkspaceError`, `Paths`.
- Produces:
  - `JSONValue` with `.from(_:)` and `.decode(_:)`
  - `ControlRequest(method:params:id:v:)` with `decodeParams(_:)`, `ControlResponse.success(id:result:)`, `ControlResponse.failure(id:error:)`, `ControlError(code:message:)`, `ControlError(_: WorkspaceError)`
  - `ControlCodec.version == 1`, `encodeLine(_:)`, `decode(_:from:)`
  - `ControlMethod` names: `status`, `repo.add`, `repo.list`, `repo.remove`, `row.list`, `row.new`, `row.remove`, `row.select`, `row.adopt`
  - `TargetHint(repo:row:envRepo:envRowPath:cwd:)`
  - Params and results: `StatusResult`, `RepoInfo`, `RepoAddParams(path:)`, `RepoRemoveParams(repo:)`, `RowListParams(repo:all:)`, `RowNewParams(target:branch:base:select:)`, `RowNewResult`, `RowRefParams(target:)`, `RowRemoveParams(target:force:deleteBranch:)`, `RowAdoptParams(path:)`
  - `TargetResolver.repo(for:in:) throws -> RepoSnapshot`, `TargetResolver.row(for:in:) throws -> Row`

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlProtocolTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct JSONValueTests {
    @Test func roundTripsTypedValues() throws {
        let params = RowNewParams(target: TargetHint(repo: "web"), branch: "fix/a", base: nil, select: true)
        let decoded = try JSONValue.from(params).decode(RowNewParams.self)
        #expect(decoded.branch == "fix/a")
        #expect(decoded.select)
    }

    @Test func keepsIntegersIntegral() throws {
        let data = try JSONEncoder().encode(JSONValue.number(42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
    }

    @Test func encodedLinesHaveExactlyOneNewline() throws {
        let line = try ControlCodec.encodeLine(ControlRequest(method: "x", params: .string("a\nb"), id: "1"))
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
    }
}
```

`Tests/CanopyCoreTests/TargetResolverTests.swift`:

```swift
import Testing

@testable import CanopyCore

struct TargetResolverTests {
    static func row(_ repo: String, _ path: String, _ branch: String, _ rowClass: RowClass = .canopy) -> Row {
        Row(repoPath: repo, path: path, branch: branch, head: nil, rowClass: rowClass)
    }

    let snapshot = WorkspaceSnapshot(repos: [
        RepoSnapshot(
            path: "/src/web",
            name: "web",
            rows: [row("/src/web", "/src/web", "main", .main), row("/src/web", "/c/web/fix-a", "fix/a")],
            external: [row("/src/web", "/x/web-other", "other", .external)]
        ),
        RepoSnapshot(
            path: "/src/api",
            name: "api",
            rows: [row("/src/api", "/src/api", "main", .main), row("/src/api", "/c/api/fix-a", "fix/a")]
        ),
    ])

    @Test func explicitRepoByNameOrPath() throws {
        #expect(try TargetResolver.repo(for: TargetHint(repo: "api"), in: snapshot).path == "/src/api")
        #expect(try TargetResolver.repo(for: TargetHint(repo: "/src/web"), in: snapshot).path == "/src/web")
    }

    @Test func unknownExplicitRepoFails() {
        #expect(throws: WorkspaceError.repoNotFound("nope")) {
            try TargetResolver.repo(for: TargetHint(repo: "nope", envRepo: "web"), in: snapshot)
        }
    }

    @Test func repoFallsBackToEnvironmentThenCwd() throws {
        #expect(
            try TargetResolver.repo(for: TargetHint(envRepo: "api", cwd: "/c/web/fix-a"), in: snapshot).path
                == "/src/api")
        #expect(try TargetResolver.repo(for: TargetHint(cwd: "/c/web/fix-a/src/deep"), in: snapshot).path == "/src/web")
    }

    @Test func repoWithNoClueFails() {
        #expect(throws: WorkspaceError.missingTarget(flag: "--repo")) {
            try TargetResolver.repo(for: TargetHint(cwd: "/unrelated"), in: snapshot)
        }
    }

    @Test func branchIsScopedByResolvableRepo() throws {
        let row = try TargetResolver.row(for: TargetHint(row: "fix/a", envRepo: "api"), in: snapshot)
        #expect(row.path == "/c/api/fix-a")
    }

    @Test func branchInSeveralReposIsAmbiguous() {
        #expect(throws: WorkspaceError.ambiguousRow("fix/a", repos: ["web", "api"])) {
            try TargetResolver.row(for: TargetHint(row: "fix/a"), in: snapshot)
        }
    }

    @Test func rowByPathAndExternalRows() throws {
        #expect(try TargetResolver.row(for: TargetHint(row: "/c/web/fix-a"), in: snapshot).branch == "fix/a")
        #expect(try TargetResolver.row(for: TargetHint(repo: "web", row: "other"), in: snapshot).rowClass == .external)
    }

    @Test func rowFallsBackToEnvironmentThenCwd() throws {
        #expect(
            try TargetResolver.row(for: TargetHint(envRowPath: "/c/api/fix-a"), in: snapshot).repoPath == "/src/api")
        #expect(try TargetResolver.row(for: TargetHint(cwd: "/c/web/fix-a/lib"), in: snapshot).path == "/c/web/fix-a")
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'TargetResolver' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Control/JSONValue.swift`:

```swift
import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
```

`Sources/CanopyCore/Control/ControlProtocol.swift`:

```swift
import Foundation

public struct ControlError: Error, Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ error: WorkspaceError) {
        self.init(code: error.code, message: error.message)
    }
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil, id: String = UUID().uuidString, v: Int = ControlCodec.version)
    {
        self.v = v
        self.id = id
        self.method = method
        self.params = params
    }

    public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try (params ?? .object([:])).decode(type)
        } catch {
            throw ControlError(code: "bad_params", message: "Invalid params for \(method): \(error)")
        }
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var result: JSONValue?
    public var error: ControlError?

    public static func success(id: String, result: JSONValue) -> ControlResponse {
        ControlResponse(v: ControlCodec.version, id: id, result: result, error: nil)
    }

    public static func failure(id: String, error: ControlError) -> ControlResponse {
        ControlResponse(v: ControlCodec.version, id: id, result: nil, error: error)
    }
}

/// Newline-delimited JSON. Compact JSON never contains a raw newline, so one message is one line.
public enum ControlCodec {
    public static let version = 1

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
```

`Sources/CanopyCore/Control/ControlMethods.swift`:

```swift
public enum ControlMethod {
    public static let status = "status"
    public static let repoAdd = "repo.add"
    public static let repoList = "repo.list"
    public static let repoRemove = "repo.remove"
    public static let rowList = "row.list"
    public static let rowNew = "row.new"
    public static let rowRemove = "row.remove"
    public static let rowSelect = "row.select"
    public static let rowAdopt = "row.adopt"
}

/// What the CLI knows about where it runs. The app resolves it against registered repos.
public struct TargetHint: Codable, Sendable, Equatable {
    /// `--repo`: a repo display name or path.
    public var repo: String?
    /// A row argument: a branch name or a path.
    public var row: String?
    /// CANOPY_REPO from the environment.
    public var envRepo: String?
    /// CANOPY_ROW_PATH from the environment.
    public var envRowPath: String?
    public var cwd: String?

    public init(
        repo: String? = nil,
        row: String? = nil,
        envRepo: String? = nil,
        envRowPath: String? = nil,
        cwd: String? = nil
    ) {
        self.repo = repo
        self.row = row
        self.envRepo = envRepo
        self.envRowPath = envRowPath
        self.cwd = cwd
    }
}

public struct StatusResult: Codable, Sendable, Equatable {
    public var version: String
    public var home: String
    public var pid: Int32
}

public struct RepoInfo: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var rows: Int
    public var external: Int
    public var missing: Bool

    public init(_ repo: RepoSnapshot) {
        name = repo.name
        path = repo.path
        rows = repo.rows.count
        external = repo.external.count
        missing = repo.isMissing
    }
}

public struct RepoAddParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct RepoRemoveParams: Codable, Sendable {
    /// A repo display name or path.
    public var repo: String

    public init(repo: String) {
        self.repo = repo
    }
}

public struct RowListParams: Codable, Sendable {
    /// Limits the list to one repo. Lists every repo when nil.
    public var repo: String?
    /// Includes external worktrees.
    public var all: Bool

    public init(repo: String?, all: Bool) {
        self.repo = repo
        self.all = all
    }
}

public struct RowNewParams: Codable, Sendable {
    public var target: TargetHint
    public var branch: String
    public var base: String?
    public var select: Bool

    public init(target: TargetHint, branch: String, base: String?, select: Bool) {
        self.target = target
        self.branch = branch
        self.base = base
        self.select = select
    }
}

public struct RowNewResult: Codable, Sendable {
    public var row: Row
    public var warnings: [String]
}

public struct RowRefParams: Codable, Sendable {
    public var target: TargetHint

    public init(target: TargetHint) {
        self.target = target
    }
}

public struct RowRemoveParams: Codable, Sendable {
    public var target: TargetHint
    public var force: Bool
    public var deleteBranch: Bool

    public init(target: TargetHint, force: Bool, deleteBranch: Bool) {
        self.target = target
        self.force = force
        self.deleteBranch = deleteBranch
    }
}

public struct RowAdoptParams: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}
```

`Sources/CanopyCore/Control/TargetResolver.swift`:

```swift
/// Resolves `--repo` and row arguments. Order: explicit argument, then CANOPY_* variables,
/// then the worktree containing the current folder. Anything else is an error naming the flag.
public enum TargetResolver {
    public static func repo(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> RepoSnapshot {
        if let repo = try repoIfKnown(for: hint, in: snapshot) { return repo }
        throw WorkspaceError.missingTarget(flag: "--repo")
    }

    public static func row(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> Row {
        if let name = hint.row {
            if isPath(name) {
                guard let row = snapshot.row(path: Paths.canonical(name)) else {
                    throw WorkspaceError.rowNotFound(name)
                }
                return row
            }
            let scope = try repoIfKnown(
                for: TargetHint(repo: hint.repo, envRepo: hint.envRepo, envRowPath: hint.envRowPath, cwd: hint.cwd),
                in: snapshot)
            let candidates = (scope.map { [$0] } ?? snapshot.repos).flatMap { repo in
                repo.allRows.filter { $0.branch == name }.map { (repo.name, $0) }
            }
            switch candidates.count {
            case 0: throw WorkspaceError.rowNotFound(name)
            case 1: return candidates[0].1
            default: throw WorkspaceError.ambiguousRow(name, repos: candidates.map(\.0))
            }
        }
        if let path = hint.envRowPath, let row = snapshot.row(path: Paths.canonical(path)) {
            return row
        }
        if let cwd = hint.cwd, let row = deepestRow(containing: Paths.canonical(cwd), in: snapshot) {
            return row
        }
        throw WorkspaceError.missingTarget(flag: "a row argument")
    }

    static func repoIfKnown(for hint: TargetHint, in snapshot: WorkspaceSnapshot) throws -> RepoSnapshot? {
        if let name = hint.repo {
            guard let repo = match(repo: name, in: snapshot) else { throw WorkspaceError.repoNotFound(name) }
            return repo
        }
        if let row = hint.row, isPath(row), let found = snapshot.row(path: Paths.canonical(row)) {
            return snapshot.repo(path: found.repoPath)
        }
        if let name = hint.envRepo, let repo = match(repo: name, in: snapshot) {
            return repo
        }
        if let path = hint.envRowPath, let row = snapshot.row(path: Paths.canonical(path)) {
            return snapshot.repo(path: row.repoPath)
        }
        if let cwd = hint.cwd, let row = deepestRow(containing: Paths.canonical(cwd), in: snapshot) {
            return snapshot.repo(path: row.repoPath)
        }
        return nil
    }

    static func match(repo name: String, in snapshot: WorkspaceSnapshot) -> RepoSnapshot? {
        if isPath(name) {
            let path = Paths.canonical(name)
            return snapshot.repos.first { $0.path == path }
        }
        return snapshot.repos.first { $0.name == name }
    }

    static func deepestRow(containing path: String, in snapshot: WorkspaceSnapshot) -> Row? {
        snapshot.repos.flatMap(\.allRows)
            .filter { Paths.isInside(path, $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    static func isPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Control Tests/CanopyCoreTests
git commit -m "feat: define the control protocol and target resolution"
```

## Task 12: Control server, client, and handler

**Files:**
- Create: `Sources/CanopyCore/Control/ControlServer.swift`, `Sources/CanopyCore/Control/ControlClient.swift`, `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`
- Test: `Tests/CanopyCoreTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: Task 11's protocol types, `Workspace`.
- Produces:
  - `ControlServer(socketPath:handler:)` with `start() async throws` (socket mode 0600, replaces a stale socket, throws `.alreadyRunning` if live) and `stop()`
  - `ControlClient(socketPath:timeout:)` with `send(_:) throws -> ControlResponse`, `static canConnect(socketPath:) -> Bool`, `static connect(to:) throws -> Int32`
  - `ControlClientError` with `.isAppNotRunning` and `.socketPathTooLong`
  - `protocol ControlUIBridge: Sendable { func selectRow(path: String) async }`
  - `WorkspaceControlHandler(workspace:ui:)` with `handle(_:) async -> ControlResponse`

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlServerTests.swift`:

```swift
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

final class RecordingUI: ControlUIBridge {
    let selected = Mutex<[String]>([])

    func selectRow(path: String) async {
        selected.withLock { $0.append(path) }
    }
}

struct ControlServerTests {
    func startServer(_ dir: TempDir) async throws -> (Workspace, ControlServer, ControlClient, RecordingUI) {
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home)
        try await workspace.start()
        let ui = RecordingUI()
        let handler = WorkspaceControlHandler(workspace: workspace, ui: ui)
        let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
        try await server.start()
        return (workspace, server, ControlClient(socketPath: home.socketPath, timeout: 10), ui)
    }

    func call<T: Decodable>(_ client: ControlClient, _ method: String, _ params: some Encodable, as: T.Type) throws -> T
    {
        let response = try client.send(ControlRequest(method: method, params: try .from(params)))
        if let error = response.error { throw error }
        return try #require(response.result).decode(T.self)
    }

    @Test func socketIsPrivateAndRejectsSecondServer() async throws {
        let dir = try TempDir()
        let (_, server, _, _) = try await startServer(dir)
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: dir.sub("home/canopy.sock"))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let second = ControlServer(socketPath: dir.sub("home/canopy.sock")) { _ in .success(id: "", result: .null) }
        await #expect(throws: ControlServerError.alreadyRunning(dir.sub("home/canopy.sock"))) {
            try await second.start()
        }
    }

    @Test func replacesStaleSocketFile() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        FileManager.default.createFile(atPath: home.socketPath, contents: Data())

        let server = ControlServer(socketPath: home.socketPath) { .success(id: $0.id, result: .bool(true)) }
        try await server.start()
        defer { server.stop() }

        let response = try ControlClient(socketPath: home.socketPath).send(ControlRequest(method: "ping"))
        #expect(response.result == .bool(true))
    }

    @Test func repoAndRowFlowOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir, origin: true)
        let (_, server, client, ui) = try await startServer(dir)
        defer { server.stop() }

        let status = try call(client, ControlMethod.status, JSONValue.null, as: StatusResult.self)
        #expect(status.pid == ProcessInfo.processInfo.processIdentifier)

        let added = try call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        #expect(added.name == "demo")

        let created = try call(
            client,
            ControlMethod.rowNew,
            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/cli", base: nil, select: true),
            as: RowNewResult.self
        )
        #expect(created.row.branch == "feat/cli")
        #expect(ui.selected.withLock { $0 } == [created.row.path])

        let rows = try call(client, ControlMethod.rowList, RowListParams(repo: nil, all: false), as: [Row].self)
        #expect(rows.map(\.branch) == ["main", "feat/cli"])

        let removed = try call(
            client,
            ControlMethod.rowRemove,
            RowRemoveParams(
                target: TargetHint(envRepo: "demo", cwd: created.row.path), force: false, deleteBranch: true),
            as: Row.self
        )
        #expect(removed.path == created.row.path)
    }

    @Test func errorsCarryCodes() async throws {
        let dir = try TempDir()
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }

        let unknown = try client.send(ControlRequest(method: "nope"))
        #expect(unknown.error?.code == "unknown_method")

        let badVersion = try client.send(ControlRequest(method: ControlMethod.status, v: 99))
        #expect(badVersion.error?.code == "version_mismatch")

        let missingRepo = try client.send(
            ControlRequest(method: ControlMethod.repoAdd, params: try .from(RepoAddParams(path: dir.sub("nope")))))
        #expect(missingRepo.error?.code == "path_not_found")

        let badParams = try client.send(ControlRequest(method: ControlMethod.repoAdd, params: .string("x")))
        #expect(badParams.error?.code == "bad_params")
    }

    @Test func malformedLineGetsBadRequest() async throws {
        let dir = try TempDir()
        let (_, server, _, _) = try await startServer(dir)
        defer { server.stop() }

        let fd = try ControlClient.connect(to: dir.sub("home/canopy.sock"))
        defer { close(fd) }
        _ = "not json\n".withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        let response = try ControlCodec.decode(
            ControlResponse.self, from: Data(buffer[0..<max(count, 0)].prefix { $0 != 0x0A }))
        #expect(response.error?.code == "bad_request")
    }

    @Test func socketPathOverTheLimitFailsClearly() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/canopy.sock"
        #expect(throws: ControlClientError.socketPathTooLong(path)) {
            try ControlClient(socketPath: path).send(ControlRequest(method: ControlMethod.status))
        }
    }

    @Test func clientReportsAppNotRunning() {
        do {
            _ = try ControlClient(socketPath: "/tmp/canopy-definitely-missing.sock").send(
                ControlRequest(method: "status"))
            Issue.record("expected failure")
        } catch let error as ControlClientError {
            #expect(error.isAppNotRunning)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'ControlServer' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Control/ControlServer.swift`:

```swift
import Foundation
import Network
import Synchronization

public enum ControlServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path): "Another Canopy is already listening on \(path)."
        }
    }
}

/// Serves newline-delimited JSON requests on a Unix socket. Each connection may send many requests.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "canopy.control-server")
    private let listener: Mutex<NWListener?> = Mutex(nil)

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() async throws {
        if FileManager.default.fileExists(atPath: socketPath) {
            if ControlClient.canConnect(socketPath: socketPath) {
                throw ControlServerError.alreadyRunning(socketPath)
            }
            unlink(socketPath)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        let listener = try NWListener(using: parameters)
        let handler = self.handler
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            ControlConnection(connection: connection, queue: queue, handler: handler).start()
        }
        self.listener.withLock { $0 = listener }

        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        chmod(socketPath, 0o600)
    }

    public func stop() {
        listener.withLock {
            $0?.cancel()
            $0 = nil
        }
        unlink(socketPath)
    }
}

private final class ResumeOnce: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

private final class ControlConnection: Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: ControlServer.Handler
    private let buffer = Mutex(Data())

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping ControlServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        let lines = buffer.withLock { buffer -> [Data] in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
            return lines
        }
        for line in lines where !line.isEmpty {
            Task { await self.respond(to: line) }
        }
    }

    private func respond(to line: Data) async {
        let response: ControlResponse
        if let request = try? ControlCodec.decode(ControlRequest.self, from: line) {
            response = await handler(request)
        } else {
            response = .failure(id: "", error: ControlError(code: "bad_request", message: "Request is not valid JSON."))
        }
        guard let data = try? ControlCodec.encodeLine(response) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
```

`Sources/CanopyCore/Control/ControlClient.swift`:

```swift
import Foundation

public enum ControlClientError: Error, Equatable, CustomStringConvertible {
    case socketPathTooLong(String)
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case connectionClosed
    case timedOut

    public var isAppNotRunning: Bool {
        if case .connectFailed(let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }

    public var description: String {
        switch self {
        case .socketPathTooLong(let path): "Socket path is longer than macOS allows: \(path)"
        case .connectFailed(let code): "Could not connect to Canopy: \(String(cString: strerror(code)))"
        case .writeFailed(let code): "Could not send to Canopy: \(String(cString: strerror(code)))"
        case .connectionClosed: "Canopy closed the connection before replying."
        case .timedOut: "Canopy did not reply in time."
        }
    }
}

/// A blocking client for one request at a time. The CLI makes a single call per run.
public struct ControlClient: Sendable {
    public var socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 120) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public static func canConnect(socketPath: String) -> Bool {
        guard let fd = try? connect(to: socketPath) else { return false }
        close(fd)
        return true
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }

        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        let payload = try ControlCodec.encodeLine(request)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { throw ControlClientError.writeFailed(errno: errno) }
                offset += written
            }
        }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !received.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { throw ControlClientError.connectionClosed }
            if count < 0 {
                throw errno == EAGAIN ? ControlClientError.timedOut : ControlClientError.connectionClosed
            }
            received.append(contentsOf: chunk[0..<count])
        }
        let line = received.prefix { $0 != 0x0A }
        return try ControlCodec.decode(ControlResponse.self, from: Data(line))
    }

    static func connect(to path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlClientError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.connectFailed(errno: errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw ControlClientError.connectFailed(errno: code)
        }
        return fd
    }
}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`:

```swift
import Foundation

/// UI actions the control API can trigger. The app implements it on the main actor.
public protocol ControlUIBridge: Sendable {
    func selectRow(path: String) async
}

public struct WorkspaceControlHandler: Sendable {
    let workspace: Workspace
    let ui: any ControlUIBridge

    public init(workspace: Workspace, ui: any ControlUIBridge) {
        self.workspace = workspace
        self.ui = ui
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        guard request.v == ControlCodec.version else {
            return .failure(
                id: request.id,
                error: ControlError(
                    code: "version_mismatch",
                    message:
                        "The app speaks protocol v\(ControlCodec.version) but the CLI sent v\(request.v). Update the linked CLI."
                )
            )
        }
        do {
            return .success(id: request.id, result: try await result(for: request))
        } catch let error as WorkspaceError {
            return .failure(id: request.id, error: ControlError(error))
        } catch let error as ControlError {
            return .failure(id: request.id, error: error)
        } catch {
            return .failure(id: request.id, error: ControlError(code: "internal", message: "\(error)"))
        }
    }

    private func result(for request: ControlRequest) async throws -> JSONValue {
        switch request.method {
        case ControlMethod.status:
            return try .from(
                StatusResult(
                    version: CanopyVersion.current,
                    home: workspace.home.root.path,
                    pid: ProcessInfo.processInfo.processIdentifier
                )
            )

        case ControlMethod.repoAdd:
            let params = try request.decodeParams(RepoAddParams.self)
            return try .from(RepoInfo(try await workspace.addRepo(path: params.path)))

        case ControlMethod.repoList:
            return try .from(await workspace.snapshot.repos.map(RepoInfo.init))

        case ControlMethod.repoRemove:
            let params = try request.decodeParams(RepoRemoveParams.self)
            let repo = try TargetResolver.repo(for: TargetHint(repo: params.repo), in: await workspace.snapshot)
            try await workspace.removeRepo(path: repo.path)
            return try .from(RepoInfo(repo))

        case ControlMethod.rowList:
            let params = try request.decodeParams(RowListParams.self)
            let snapshot = await workspace.snapshot
            let repos =
                try params.repo.map { [try TargetResolver.repo(for: TargetHint(repo: $0), in: snapshot)] }
                ?? snapshot.repos
            return try .from(repos.flatMap { params.all ? $0.allRows : $0.rows })

        case ControlMethod.rowNew:
            let params = try request.decodeParams(RowNewParams.self)
            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
            let created = try await workspace.createRow(repoPath: repo.path, branch: params.branch, base: params.base)
            if params.select {
                await select(created.row.path)
            }
            return try .from(RowNewResult(row: created.row, warnings: created.warnings))

        case ControlMethod.rowRemove:
            let params = try request.decodeParams(RowRemoveParams.self)
            let row = try TargetResolver.row(for: params.target, in: await workspace.snapshot)
            try await workspace.removeRow(path: row.path, force: params.force, deleteBranch: params.deleteBranch)
            return try .from(row)

        case ControlMethod.rowSelect:
            let params = try request.decodeParams(RowRefParams.self)
            let row = try TargetResolver.row(for: params.target, in: await workspace.snapshot)
            await select(row.path)
            return try .from(row)

        case ControlMethod.rowAdopt:
            let params = try request.decodeParams(RowAdoptParams.self)
            return try .from(try await workspace.adopt(path: params.path))

        default:
            throw ControlError(code: "unknown_method", message: "Unknown method \(request.method)")
        }
    }

    private func select(_ path: String) async {
        try? await workspace.setSelectedRow(path: path)
        await ui.selectRow(path: path)
    }
}
```

- [ ] **Step 4: Run the tests three times**

Run: `for i in 1 2 3; do make test 2>&1 | grep -E "✘|Test run with"; done`
Expected: `✔ Test run with 80 tests in 16 suites passed` three times.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Control Tests/CanopyCoreTests/ControlServerTests.swift
git commit -m "feat: serve the control protocol on a Unix socket"
```

## Task 13: The `canopy` CLI

**Files:**
- Create: `Sources/CanopyCLI/Client.swift`, `Sources/CanopyCLI/RepoCommand.swift`, `Sources/CanopyCLI/RowCommand.swift`
- Modify: `Sources/CanopyCLI/CanopyCLI.swift` (replace)

**Interfaces:**
- Consumes: `ControlClient`, `ControlRequest`, `ControlMethod`, params and results from Task 11, `CanopyHome`.
- Produces:
  - `canopy status`
  - `canopy repo add|list|rm`
  - `canopy row list|new|rm|select|adopt`
  - All take `--json`, exit 1 on error, and print `{"error": {...}}` on stdout with `--json`.
  - Auto-launch: when the socket is absent, run `open -g -n --env CANOPY_HOME=<home> <enclosing .app>` and wait up to 10 seconds. `CANOPY_APP` overrides the app path.

The CLI is thin glue over tested core types, so it is verified by running it here and end to end in Task 15.

- [ ] **Step 1: Write the CLI**

`Sources/CanopyCLI/Client.swift`:

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct CLIError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print machine-readable JSON.")
    var json = false
}

/// Sends one request to the app, launching it first if it is not running.
struct Client {
    let home: CanopyHome
    let json: Bool

    init(json: Bool) {
        self.home = CanopyHome.resolve(bundleHome: AppLocator.bundleHome())
        self.json = json
    }

    func call(_ method: String, _ params: some Encodable, launchIfNeeded: Bool = true) throws -> JSONValue {
        let request = ControlRequest(method: method, params: try .from(params))
        let client = ControlClient(socketPath: home.socketPath)
        let response: ControlResponse
        do {
            response = try client.send(request)
        } catch let error as ControlClientError where error.isAppNotRunning && launchIfNeeded {
            try AppLocator.launch(home: home)
            response = try client.send(request)
        }
        if let error = response.error {
            fail(error)
        }
        return response.result ?? .null
    }

    /// Prints the raw result with --json, or the human summary otherwise.
    func print(_ result: JSONValue, human: () throws -> String) throws {
        if json {
            Swift.print(try Self.pretty(result))
        } else {
            Swift.print(try human())
        }
    }

    func fail(_ error: ControlError) -> Never {
        if json, let text = try? Self.pretty(.object(["error": try .from(error)])) {
            Swift.print(text)
        }
        FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
        Foundation.exit(1)
    }

    static func pretty(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Everything the app needs to resolve repo and row arguments the way the user meant them.
    static func hint(repo: String? = nil, row: String? = nil) -> TargetHint {
        let environment = ProcessInfo.processInfo.environment
        return TargetHint(
            repo: repo.map(absolutePathIfRelative),
            row: row.map(absolutePathIfRelative),
            envRepo: environment["CANOPY_REPO"],
            envRowPath: environment["CANOPY_ROW_PATH"],
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    /// The app runs in a different folder, so `.` and `../x` must be resolved here.
    static func absolutePathIfRelative(_ value: String) -> String {
        guard value.hasPrefix(".") else { return value }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    static func absolutePath(_ value: String) -> String {
        if value.hasPrefix("/") || value.hasPrefix("~") { return value }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }
}

enum AppLocator {
    /// The Canopy.app this CLI ships in, following the ~/.local/bin symlink. CANOPY_APP overrides it.
    static func appBundle() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CANOPY_APP"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func bundleHome() -> String? {
        guard let app = appBundle() else { return nil }
        return Bundle(url: app)?.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
    }

    static func launch(home: CanopyHome) throws {
        guard let app = appBundle() else {
            throw CLIError("Canopy is not running and Canopy.app was not found. Set CANOPY_APP to its path.")
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-n", "--env", "\(CanopyHome.environmentKey)=\(home.root.path)", app.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw CLIError("Could not launch \(app.path).")
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if ControlClient.canConnect(socketPath: home.socketPath) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLIError("Launched \(app.path) but it did not open \(home.socketPath) within 10 seconds.")
    }
}

enum Table {
    /// Left-aligned columns separated by two spaces.
    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { cells in
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }
}
```

`Sources/CanopyCLI/CanopyCLI.swift` (replaces the version-only root):

```swift
import ArgumentParser
import CanopyCore
import Foundation

@main
struct CanopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canopy",
        abstract: "Drive Canopy from the command line.",
        version: CanopyVersion.current,
        subcommands: [Status.self, RepoCommand.self, RowCommand.self]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether Canopy is running.")

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = Client(json: output.json)
        guard ControlClient.canConnect(socketPath: client.home.socketPath) else {
            if output.json {
                print(#"{"running": false}"#)
            } else {
                print("Canopy is not running (home: \(client.home.root.path)).")
            }
            throw ExitCode(1)
        }
        let result = try client.call(ControlMethod.status, JSONValue.null, launchIfNeeded: false)
        try client.print(result) {
            let status = try result.decode(StatusResult.self)
            return "Canopy \(status.version) is running (pid \(status.pid), home: \(status.home))."
        }
    }
}
```

`Sources/CanopyCLI/RepoCommand.swift`:

```swift
import ArgumentParser
import CanopyCore

struct RepoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Register and list repositories.",
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register a repository. Any worktree of it works.")

        @Argument(help: "Path to the repository or one of its worktrees.")
        var path: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(ControlMethod.repoAdd, RepoAddParams(path: Client.absolutePath(path)))
            try client.print(result) {
                let repo = try result.decode(RepoInfo.self)
                return "Added \(repo.name) (\(repo.path))."
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered repositories.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(ControlMethod.repoList, JSONValue.null)
            try client.print(result) {
                let repos = try result.decode([RepoInfo].self)
                return Table.render(
                    ["NAME", "ROWS", "OTHER", "PATH"],
                    repos.map {
                        [$0.name, "\($0.rows)", "\($0.external)", $0.missing ? "\($0.path) (missing)" : $0.path]
                    }
                )
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Unregister a repository. Files are not touched."
        )

        @Argument(help: "Repo name or path.")
        var repo: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(
                ControlMethod.repoRemove,
                RepoRemoveParams(repo: Client.absolutePathIfRelative(repo))
            )
            try client.print(result) { "Removed \(try result.decode(RepoInfo.self).name) from Canopy." }
        }
    }
}
```

`Sources/CanopyCLI/RowCommand.swift`:

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct RowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "row",
        abstract: "Create, remove, and list rows (worktrees).",
        subcommands: [List.self, New.self, Remove.self, Select.self, Adopt.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List rows in every repo, or in one.")

        @Option(help: "Only this repo (name or path).")
        var repo: String?
        @Flag(help: "Include worktrees made by other tools.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(
                ControlMethod.rowList,
                RowListParams(repo: repo.map(Client.absolutePathIfRelative), all: all)
            )
            try client.print(result) {
                let rows = try result.decode([Row].self)
                return Table.render(
                    ["BRANCH", "CLASS", "PATH"],
                    rows.map { row in
                        let rowClass = row.externalTag.map { "\(row.rowClass.rawValue):\($0.rawValue)" }
                        return [row.displayName, rowClass ?? row.rowClass.rawValue, row.path]
                    }
                )
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a row: a branch and a worktree under the Canopy folder.",
            discussion: """
                An existing local branch is checked out. A branch that only exists on origin is tracked. \
                Anything else is created from --from, which defaults to origin's default branch.
                """
        )

        @Argument(help: "Branch name, for example feat/login.")
        var branch: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @Option(name: .customLong("from"), help: "Start point for a new branch.")
        var base: String?
        @Flag(help: "Switch the Canopy window to the new row.")
        var select = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(
                ControlMethod.rowNew,
                RowNewParams(target: Client.hint(repo: repo), branch: branch, base: base, select: select)
            )
            let created = try result.decode(RowNewResult.self)
            for warning in created.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(result) { "Created \(created.row.displayName) at \(created.row.path)." }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a row's worktree, or hide an adopted row."
        )

        @Argument(help: "Branch or path. Defaults to the row you are in.")
        var row: String?
        @Option(help: "Repo name or path, when the branch exists in several repos.")
        var repo: String?
        @Flag(help: "Remove even with uncommitted changes.")
        var force = false
        @Flag(help: "Also delete the branch.")
        var deleteBranch = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(
                ControlMethod.rowRemove,
                RowRemoveParams(target: Client.hint(repo: repo, row: row), force: force, deleteBranch: deleteBranch)
            )
            try client.print(result) { "Removed \(try result.decode(Row.self).displayName)." }
        }
    }

    struct Select: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a row in the Canopy window.")

        @Argument(help: "Branch or path. Defaults to the row you are in.")
        var row: String?
        @Option(help: "Repo name or path, when the branch exists in several repos.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(
                ControlMethod.rowSelect, RowRefParams(target: Client.hint(repo: repo, row: row)))
            try client.print(result) { "Selected \(try result.decode(Row.self).displayName)." }
        }
    }

    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a worktree made by another tool as a regular row."
        )

        @Argument(help: "Path to the worktree.")
        var path: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = try client.call(ControlMethod.rowAdopt, RowAdoptParams(path: Client.absolutePath(path)))
            try client.print(result) { "Adopted \(try result.decode(Row.self).displayName)." }
        }
    }
}
```

- [ ] **Step 2: Check help and the not-running path**

Run: `swift run canopy row new --help`
Expected: usage lists `<branch>`, `--repo`, `--from`, `--select`, and `--json`.

Run: `CANOPY_HOME=$(mktemp -d -t canopy-cli)/home swift run canopy status; echo "exit $?"`
Expected: `Canopy is not running (home: ...)` and `exit 1`.

- [ ] **Step 3: Commit**

```bash
git add Sources/CanopyCLI
git commit -m "feat: add canopy repo and row commands"
```

## Task 14: Wire the app to the control API and add row actions

**Files:**
- Create: `Sources/CanopyApp/Sidebar/RowActionViews.swift`
- Modify (replace): `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`

**Interfaces:**
- Consumes: `ControlServer`, `WorkspaceControlHandler`, `ControlUIBridge`, `Workspace.createRow`, `Workspace.removeRow`.
- Produces:
  - `AppModel.shutdown()`, `AppModel.createRow(in:branch:base:) async -> String?`, `AppModel.removeRow(_:force:deleteBranch:) async -> RemoveOutcome`
  - `AppUIBridge`
  - `NewRowSheet(repo:)`, `RemoveRowPopover(row:isPresented:)`
  - `RowLineView(row:shortcut:removable:)`, `RepoHeaderView(repo:onNewRow:onLocate:)`

- [ ] **Step 1: Write the changes**

`Sources/CanopyApp/AppModel.swift` (full replacement):

```swift
import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let home: CanopyHome
    let workspace: Workspace
    private(set) var snapshot = WorkspaceSnapshot()
    private(set) var toast: String?
    var selectedRowPath: String? {
        didSet {
            if selectedRowPath != oldValue { selectionChanged() }
        }
    }
    private var started = false
    private var toastTask: Task<Void, Never>?
    private var server: ControlServer?

    init(home: CanopyHome) {
        self.home = home
        self.workspace = Workspace(home: home)
    }

    var selectedRow: Row? {
        selectedRowPath.flatMap { snapshot.row(path: $0) }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await workspace.start()
        } catch {
            show(error)
            return
        }
        if let notice = await workspace.loadNotice {
            show(notice)
        }
        let updates = await workspace.updates()
        Task { [weak self] in
            for await snapshot in updates {
                self?.apply(snapshot)
            }
        }
        await startControlServer()
    }

    func shutdown() {
        server?.stop()
        server = nil
    }

    private func startControlServer() async {
        let bridge = AppUIBridge { [weak self] path in self?.selectedRowPath = path }
        let handler = WorkspaceControlHandler(workspace: workspace, ui: bridge)
        let server = ControlServer(socketPath: home.socketPath) { await handler.handle($0) }
        do {
            try await server.start()
            self.server = server
        } catch {
            show("The canopy CLI is unavailable: \(error)")
        }
    }

    // MARK: Rows

    /// ⌘1 to ⌘9, in sidebar order across repos.
    func shortcut(for row: Row) -> Int? {
        guard let index = snapshot.visibleRows.firstIndex(where: { $0.path == row.path }), index < 9 else {
            return nil
        }
        return index + 1
    }

    func selectRow(number: Int) {
        let rows = snapshot.visibleRows
        guard number >= 1, number <= rows.count else { return }
        selectedRowPath = rows[number - 1].path
    }

    func menuTitle(forRow number: Int) -> String {
        let rows = snapshot.visibleRows
        return number <= rows.count ? rows[number - 1].displayName : "Row \(number)"
    }

    func refresh() {
        Task { await workspace.refreshAll() }
    }

    /// Creates a row and selects it. Returns an error message for the sheet to show, or nil.
    func createRow(in repo: RepoSnapshot, branch: String, base: String?) async -> String? {
        do {
            let created = try await workspace.createRow(repoPath: repo.path, branch: branch, base: base)
            selectedRowPath = created.row.path
            if let warning = created.warnings.first {
                show(warning)
            }
            return nil
        } catch {
            return (error as? WorkspaceError)?.message ?? "\(error)"
        }
    }

    enum RemoveOutcome {
        case removed
        case dirty
        case failed(String)
    }

    func removeRow(_ row: Row, force: Bool, deleteBranch: Bool) async -> RemoveOutcome {
        do {
            try await workspace.removeRow(path: row.path, force: force, deleteBranch: deleteBranch)
            return .removed
        } catch WorkspaceError.worktreeDirty {
            return .dirty
        } catch {
            return .failed((error as? WorkspaceError)?.message ?? "\(error)")
        }
    }

    // MARK: Repos

    func addRepo(_ url: URL) {
        perform { try await $0.addRepo(path: url.path) }
    }

    func removeRepo(_ repo: RepoSnapshot) {
        perform { try await $0.removeRepo(path: repo.path) }
    }

    func relocateRepo(_ repo: RepoSnapshot, to url: URL) {
        perform { try await $0.relocateRepo(path: repo.path, to: url.path) }
    }

    func prune(_ repo: RepoSnapshot) {
        perform { try await $0.prune(repoPath: repo.path) }
    }

    // MARK: Internals

    private func apply(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        if selectedRowPath == nil, let saved = snapshot.selectedRowPath, snapshot.row(path: saved) != nil {
            selectedRowPath = saved
        } else if let path = selectedRowPath, snapshot.row(path: path) == nil {
            selectedRowPath = nil
        }
    }

    private func selectionChanged() {
        let path = selectedRowPath
        if let path, snapshot.row(path: path)?.rowClass == .external {
            perform { _ = try await $0.adopt(path: path) }
        }
        perform { try await $0.setSelectedRow(path: path) }
    }

    func perform(_ action: @escaping @Sendable (Workspace) async throws -> Void) {
        Task {
            do {
                try await action(workspace)
            } catch {
                show(error)
            }
        }
    }

    func show(_ error: any Error) {
        show((error as? WorkspaceError)?.message ?? "\(error)")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

struct AppUIBridge: ControlUIBridge {
    let select: @MainActor @Sendable (String) -> Void

    func selectRow(path: String) async {
        await select(path)
    }
}
```

`Sources/CanopyApp/RootView.swift` (full replacement):

```swift
import AppKit
import CanopyCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            RowDetailView()
        }
        .frame(minWidth: 900, minHeight: 560)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.shutdown()
        }
    }
}

struct RowDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.selectedRow {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(row.displayName)
                } icon: {
                    BranchIcon()
                }
                .font(.title2)
                Text(row.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(row.displayName)
        } else {
            ContentUnavailableView(
                "No Row Selected",
                systemImage: "sidebar.left",
                description: Text("Pick a row in the sidebar, or add a repo to get started.")
            )
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}
```

`Sources/CanopyApp/Sidebar/SidebarView.swift` (full replacement):

```swift
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var folderRequest: FolderRequest?
    @State private var newRowRepo: RepoSnapshot?

    enum FolderRequest {
        case addRepo
        case locate(RepoSnapshot)
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRowPath) {
            ForEach(model.snapshot.repos) { repo in
                Section {
                    ForEach(repo.rows) { row in
                        RowLineView(row: row, shortcut: model.shortcut(for: row), removable: row.rowClass != .main)
                            .tag(row.path)
                            .contextMenu {
                                if row.isMissing {
                                    Button("Prune Missing Worktrees") { model.prune(repo) }
                                }
                            }
                    }
                    if !repo.external.isEmpty {
                        DisclosureGroup("Other worktrees (\(repo.external.count))") {
                            ForEach(repo.external) { row in
                                RowLineView(row: row, shortcut: nil, removable: false)
                                    .tag(row.path)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    RepoHeaderView(
                        repo: repo,
                        onNewRow: { newRowRepo = repo },
                        onLocate: { folderRequest = .locate(repo) }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.snapshot.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repos", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository to see its worktrees.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                folderRequest = .addRepo
            } label: {
                Label("Add Repo", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $newRowRepo) { repo in
            NewRowSheet(repo: repo)
        }
        .fileImporter(
            isPresented: Binding(get: { folderRequest != nil }, set: { if !$0 { folderRequest = nil } }),
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result, let request = folderRequest else { return }
            switch request {
            case .addRepo: model.addRepo(url)
            case .locate(let repo): model.relocateRepo(repo, to: url)
            }
        }
    }
}

struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    let onLocate: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(repo.name)
            if repo.isMissing {
                TagView(text: "missing")
            }
            if let error = repo.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
            Spacer(minLength: 4)
            if !repo.isMissing {
                Button(action: onNewRow) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New row in \(repo.name)")
                .opacity(isHovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if !repo.isMissing {
                Button("New Row…", action: onNewRow)
            }
            if repo.isMissing {
                Button("Locate…", action: onLocate)
            }
            Divider()
            Button("Remove Repo from Canopy") { model.removeRepo(repo) }
        }
    }
}

struct RowLineView: View {
    let row: Row
    let shortcut: Int?
    let removable: Bool
    @State private var isHovering = false
    @State private var isConfirmingRemove = false

    var body: some View {
        HStack(spacing: 6) {
            BranchIcon(color: row.isMissing ? .secondary : .green)
            Text(row.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isMissing ? .secondary : .primary)
            if let tag = row.externalTag {
                TagView(text: tag.label)
            }
            if row.isMissing {
                TagView(text: "missing")
            }
            Spacer(minLength: 4)
            if isHovering || isConfirmingRemove {
                if let shortcut {
                    Text("⌘\(shortcut)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if removable {
                    Button {
                        isConfirmingRemove = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(row.rowClass == .adopted ? "Hide from Canopy" : "Remove row")
                    .popover(isPresented: $isConfirmingRemove, arrowEdge: .trailing) {
                        RemoveRowPopover(row: row, isPresented: $isConfirmingRemove)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(row.path)
    }
}

struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
```

`Sources/CanopyApp/Sidebar/RowActionViews.swift`:

```swift
import CanopyCore
import SwiftUI

struct NewRowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: RepoSnapshot
    @State private var branch = ""
    @State private var base = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Row in \(repo.name)")
                .font(.headline)
            Form {
                TextField("Branch", text: $branch, prompt: Text("feat/my-change"))
                TextField("Start from", text: $base, prompt: Text("origin's default branch"))
            }
            .formStyle(.columns)
            .disabled(isCreating)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Row", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedBranch.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmedBranch: String {
        branch.trimmingCharacters(in: .whitespaces)
    }

    private func create() {
        isCreating = true
        error = nil
        let base = base.trimmingCharacters(in: .whitespaces)
        Task {
            error = await model.createRow(in: repo, branch: trimmedBranch, base: base.isEmpty ? nil : base)
            isCreating = false
            if error == nil {
                dismiss()
            }
        }
    }
}

struct RemoveRowPopover: View {
    @Environment(AppModel.self) private var model
    let row: Row
    @Binding var isPresented: Bool
    @State private var deleteBranch = false
    @State private var isDirty = false
    @State private var isWorking = false
    @State private var error: String?

    private var isAdopted: Bool { row.rowClass == .adopted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isAdopted ? "Hide \(row.displayName)?" : "Remove \(row.displayName)?")
                .font(.headline)
            Text(
                isAdopted
                    ? "The worktree stays where it is and moves back to Other worktrees."
                    : "This deletes the worktree folder."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !isAdopted, let branch = row.branch {
                Toggle("Also delete branch \(branch)", isOn: $deleteBranch)
            }
            if isDirty {
                Label("It has uncommitted changes.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(isDirty ? "Force Remove" : isAdopted ? "Hide" : "Remove", role: .destructive, action: remove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func remove() {
        isWorking = true
        error = nil
        Task {
            switch await model.removeRow(row, force: isDirty, deleteBranch: deleteBranch) {
            case .removed: isPresented = false
            case .dirty: isDirty = true
            case .failed(let message): error = message
            }
            isWorking = false
        }
    }
}
```

- [ ] **Step 2: Build without warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:"`
Expected: no output.

- [ ] **Step 3: Check the row actions by hand with the author**

This session cannot click, so ask the author to run `make app && open "build/Canopy Dev.app"` against a scratch repo and check:
- Hovering a repo header shows `+`. It opens "New Row in <repo>". Creating `feat/try` selects the new row.
- Hovering a Canopy row shows `⌘N` and `×`. `×` opens "Remove feat/try?" with "Also delete branch feat/try".
- With an untracked file in the row, Remove turns into "It has uncommitted changes." and "Force Remove".
- On an adopted row, `×` reads "Hide" and leaves the folder in place.
- The main row has no `×`.

- [ ] **Step 4: Commit**

```bash
git add Sources/CanopyApp
git commit -m "feat: serve the CLI from the app and add row actions to the sidebar"
```

## Task 15: End-to-end script and the PR

**Files:**
- Create: `scripts/e2e.sh`
- Modify (replace): `Makefile`, which adds the `e2e` target

**Interfaces:**
- Consumes: `make app`, `scripts/window-shot.swift`, the whole CLI.
- Produces: `make e2e`, which prints `e2e passed` and leaves `build/e2e/rows.png`.

- [ ] **Step 1: Write the script and Makefile target**

`scripts/e2e.sh` (then `chmod +x scripts/e2e.sh`):

```bash
#!/usr/bin/env bash
# Drives a dev build through the canopy CLI against a throwaway CANOPY_HOME.
# Leaves a screenshot in build/e2e/ for a visual check.
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
shots="$PWD/build/e2e"
work=$(mktemp -d -t canopy-e2e)
export CANOPY_HOME="$work/home"
mkdir -p "$shots"

app_pid() {
    "$cli" status --json 2>/dev/null | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("pid", ""))' || true
}

cleanup() {
    local pid
    pid=$(app_pid)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "fixture repo with an origin"
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/demo" 2>/dev/null
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
git -C "$work/demo" push -q origin main
git -C "$work/demo" remote set-head origin main

step "CLI launches the app and registers the repo"
"$cli" repo add "$work/demo" --json
[[ -n "$(app_pid)" ]] || fail "app did not start"

step "relative paths resolve against the caller's folder"
(cd "$work/demo" && "$cli" repo add . --json) | grep -q '"name" : "demo"' || fail "repo add . did not resolve"

step "canopy row new creates a branch and worktree"
"$cli" row new feat/e2e --repo demo --select --json
[[ -d "$CANOPY_HOME/worktrees/demo/feat-e2e" ]] || fail "worktree folder missing"

step "a worktree made with plain git shows up"
git -C "$work/demo" worktree add -q -b feat/plain "$CANOPY_HOME/worktrees/demo/feat-plain"
for _ in $(seq 1 30); do
    "$cli" row list --repo demo | grep -q feat/plain && break
    sleep 0.1
done
"$cli" row list --repo demo | grep -q feat/plain || fail "plain git worktree did not appear"

step "running inside a row resolves the repo from the folder"
(cd "$CANOPY_HOME/worktrees/demo/feat-plain" && "$cli" row new feat/from-cwd --json) >/dev/null

step "listing"
"$cli" row list

step "screenshot"
sleep 1
swift scripts/window-shot.swift "$(app_pid)" "$shots/rows.png"
echo "saved $shots/rows.png"

step "canopy row rm removes the worktree and branch"
"$cli" row rm feat/e2e --repo demo --delete-branch
[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-e2e" ]] || fail "worktree folder still exists"
if git -C "$work/demo" show-ref --verify --quiet refs/heads/feat/e2e; then fail "branch still exists"; fi

step "errors are machine-readable"
if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"

echo
echo "e2e passed"
```

`Makefile` (full replacement):

```makefile
TEST_FLAGS := $(shell scripts/test-flags.sh)
SOURCES := Package.swift Sources Tests

.PHONY: build test lint format app release install signing-cert e2e clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format --in-place --recursive $(SOURCES)

# Dev build: "Canopy Dev.app", data in ~/.canopy-dev.
app:
	scripts/bundle.sh debug dev

# Release build: "Canopy.app", data in ~/.canopy.
release:
	scripts/bundle.sh release release

install: release
	mkdir -p ~/Applications ~/.local/bin
	rm -rf ~/Applications/Canopy.app
	cp -R build/Canopy.app ~/Applications/Canopy.app
	ln -sf ~/Applications/Canopy.app/Contents/Resources/bin/canopy ~/.local/bin/canopy
	@case ":$$PATH:" in *":$$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to PATH to use canopy outside Canopy";; esac

signing-cert:
	scripts/make-signing-cert.sh

e2e: app
	scripts/e2e.sh

clean:
	rm -rf .build build
```

- [ ] **Step 2: Run it**

Run: `make e2e`
Expected: every `==>` step runs, and the last line is `e2e passed`.

Look at `build/e2e/rows.png`.
Expected: the `demo` section lists `main`, `feat/e2e` (selected), `feat/plain`, and `feat/from-cwd`, each with the green branch glyph.

- [ ] **Step 3: Full check and commit**

```bash
make lint && make test
git add scripts/e2e.sh Makefile
git commit -m "test: drive the app end to end through the CLI"
```

- [ ] **Step 4: Push, open the PR, and stop for review**

```bash
git push -u origin feat/control-cli
gh pr create --title "feat: canopy CLI for agents to create and remove rows" --body "$(cat <<'EOF'
## Summary

Agents can now drive Canopy.
The app serves a versioned JSON protocol on `CANOPY_HOME/canopy.sock`, and the new `canopy` CLI covers `status`, `repo add|list|rm`, and `row list|new|rm|select|adopt`.
The CLI launches Canopy in the background when it is not running.
Repo and row arguments default to where the command runs, so an agent inside a row can run `canopy row new fix/x` with no flags.
Git changes to one repo run one at a time, so parallel agents do not trip over git's lock files.
The sidebar gains a `+` per repo and a hover `×` per row.

## Testing

- `make test`: 80 tests pass, including a socket round trip and four parallel row creations.
- `make e2e`: drives a dev build through the CLI. Screenshot attached.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

Attach `build/e2e/rows.png`, then wait for the author to merge.
