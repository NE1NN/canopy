# Collapse Repos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A repo's section in the sidebar folds away under its header, and so does a plugin's section, with the fold saved in `state.json` and a `canopy` command for every fold.

**Architecture:** Each repo entry and plugin entry in `state.json` gains `collapsed`.
The snapshot carries it on `RepoSnapshot` and `PluginSection`, and CanopyCore decides everything that follows from it: which rows get `⌘1` to `⌘9`, where `↑` and `↓` go, which header stands for a hidden selected row, and what selecting a hidden row unfolds.
One function, `WorkspaceSnapshot.folds(hiding:)`, names the folded headers hiding a row, and the headers, the reveal, and the selection fill all read it.
Views only draw: a repo or plugin header gets the group header's chevron, and its section shows nothing below the header while folded.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md` (Sidebar rows, amended in Task 6), with `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`, `docs/superpowers/specs/2026-09-28-canopy-agent-state-design.md`, and `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md`.
The feature request is the author's, from 2026-09-29: one repo has around 30 rows and buries every other repo below it.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings in `make build` or `swift build --build-tests $(scripts/test-flags.sh)`.
- `make lint` is `swift format lint --strict`.
- New `state.json` fields decode with a default, so older files load, and a field that cannot be read never drops the repo or plugin around it.
- `version` stays 1.
- Folding and unfolding are view state: they are saved but log no activity event of their own, only the `cli.call` any changing command logs.
- Every UI action has a `canopy` command, and repeating a fold command succeeds and changes nothing.
- Markdown: one sentence per line, no em dashes.
- Commits use conventional prefixes and no Co-Authored-By trailers.

## Review Focus

1. A repo and one of its groups both folded, with the selected row in that group: the repo header takes the selection fill, and selecting the row from outside unfolds both.
   Pinned in Task 1 (`foldsListTheRepoThenTheGroup`) and Task 2 (`revealingARowUnfoldsItsRepoAndGroup`).
2. A `state.json` whose repo has `"collapsed": "yes"` or no `collapsed` at all: the repo loads expanded, with its rows and groups.
   Pinned in Task 1 (`reposAndPluginsDecodeTheirFold`).
3. A plugin that is off keeps its fold, and a plugin id that does not exist fails `plugin collapse` with `plugin_not_found`.
   Pinned in Task 2 (`pluginFoldIsSavedAndUnknownPluginsFail`) and Task 3.
4. `↓` from a row hidden in a folded repo goes to the first row shown after the repo, which may be a plugin row, and `↑` to the last row shown before it.
   Pinned in Task 1 (`steppingFromAHiddenRowContinuesFromItsRepo`).
5. A row created with `row new --select` or `plugin new --select` into a folded repo or section unfolds it, and one created without `--select` leaves the fold alone.
   Pinned in Task 3 (`selectingOverTheSocketUnfolds`).

---

## File Structure

- `Sources/CanopyCore/State/AppState.swift`: `RepoEntry.collapsed`.
- `Sources/CanopyCore/Plugins/PluginState.swift`: `PluginEntry.collapsed`.
- `Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift`: `RepoSnapshot.collapsed`, the visible order, stepping.
- `Sources/CanopyCore/Rows/SidebarFold.swift` (new): `SidebarFold` and `WorkspaceSnapshot.folds(hiding:)`.
- `Sources/CanopyCore/Plugins/PluginRow.swift`: `PluginSection.collapsed`.
- `Sources/CanopyCore/Workspace/Workspace+Folding.swift` (new): `setRepoCollapsed`, `setPluginCollapsed`, and `revealRow`, which moves here from `Workspace+Groups.swift`.
- `Sources/CanopyCore/Workspace/Workspace+Groups.swift`: `setGroupCollapsed` returns the group.
- `Sources/CanopyCore/Control/ControlMethods.swift`, `GroupMethods.swift`, `PluginMethods.swift`, `WorkspaceControlHandler.swift`: the six fold methods, `collapsed` in `RepoInfo` and `PluginListing`.
- `Sources/CanopyCore/Plugins/PluginHost.swift`: `setCollapsed`, and `select` reveals.
- `Sources/CanopyCLI/RepoCommand.swift`, `GroupCommand.swift`, `PluginCommand.swift`, `AgentGuide.swift`: the commands and the guide.
- `Sources/CanopyApp/Style/Style.swift`: `DisclosureChevron`, shared by every fold.
- `Sources/CanopyApp/Sidebar/SidebarView.swift`, `GroupViews.swift`, `Plugins/PluginSectionView.swift`, `AppModel.swift`: the headers and sections.
- `scripts/e2e.sh`, `scripts/ui-fixture.sh`: CLI cases, and a fixture with a folded repo and group.
- The four specs.

---

### Task 1: The fold in state and snapshots

**Files:**
- Modify: `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/Plugins/PluginState.swift`, `Sources/CanopyCore/Plugins/PluginRow.swift`, `Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `Sources/CanopyCore/Workspace/Workspace+Plugins.swift`
- Create: `Sources/CanopyCore/Rows/SidebarFold.swift`
- Test: `Tests/CanopyCoreTests/StateStoreTests.swift`, `Tests/CanopyCoreTests/SidebarFoldTests.swift` (new)

**Interfaces:**
- Produces: `RepoEntry.collapsed: Bool`, `PluginEntry.collapsed: Bool`, `RepoSnapshot.collapsed: Bool`, `PluginSection.collapsed: Bool`, `enum SidebarFold { case repo(String), group(repoPath: String, name: String), plugin(String) }`, `WorkspaceSnapshot.folds(hiding path: String) -> [SidebarFold]`.

- [ ] **Step 1: Write the failing tests**

In `StateStoreTests`:

```swift
@Test func reposAndPluginsDecodeTheirFold() throws {
    let json = """
        {"version": 1, "repos": [
            {"path": "/a", "dirName": "a", "collapsed": true},
            {"path": "/b", "dirName": "b"},
            {"path": "/c", "dirName": "c", "collapsed": "yes", "rowOrder": ["/c/x"]}
        ], "plugins": {"fixture": {"rows": [], "collapsed": true}, "tickets": {"collapsed": 3}}}
        """
    let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))

    #expect(state.repos.map(\.collapsed) == [true, false, false])
    #expect(state.repos[2].rowOrder == ["/c/x"])
    #expect(state.plugins["fixture"]?.collapsed == true)
    #expect(state.plugins["tickets"]?.collapsed == false)
    let again = try JSONDecoder().decode(AppState.self, from: try JSONEncoder().encode(state))
    #expect(again == state)
}
```

In a new `SidebarFoldTests.swift`, built on `GroupSnapshotTests.snapshot` (web: main, a, Review (b, c) folded, Later (d); api: main, e, Hidden (f) folded):

```swift
struct SidebarFoldTests {
    static func section(_ id: String, collapsed: Bool = false, _ items: [String]) -> PluginSection {
        PluginSection(
            info: PluginInfo(id: id, name: id, symbol: "star"), isOn: true,
            rows: items.map { PluginRow(plugin: id, item: $0, title: $0, path: "/h/\(id)/\($0)") },
            collapsed: collapsed)
    }

    /// The group snapshot with web folded, and a plugin section after the repos.
    static var snapshot: WorkspaceSnapshot {
        var snapshot = GroupSnapshotTests.snapshot
        snapshot.repos[0].collapsed = true
        snapshot.repos[0].external = [GroupSnapshotTests.row("web", "ext")]
        snapshot.repos[0].external[0].rowClass = .external
        snapshot.plugins = [section("p", ["one"])]
        return snapshot
    }

    @Test func aFoldedRepoGivesNoRowANumber() {
        #expect(Self.snapshot.visibleRows.map(\.path) == ["/api", "/api/e", "/h/p/one"])
        #expect(Self.snapshot.repos[0].visibleRows.isEmpty)
    }

    @Test func aFoldedSectionGivesNoRowANumber() {
        var snapshot = Self.snapshot
        snapshot.plugins = [Self.section("p", collapsed: true, ["one"]), Self.section("q", ["two"])]
        #expect(snapshot.visibleRows.map(\.path) == ["/api", "/api/e", "/h/q/two"])
        #expect(snapshot.steppingRow(from: "/h/p/one", offset: 1)?.path == "/h/q/two")
        #expect(snapshot.steppingRow(from: "/h/p/one", offset: -1)?.path == "/api/e")
    }

    @Test func steppingFromAHiddenRowContinuesFromItsRepo() {
        var snapshot = Self.snapshot
        snapshot.repos.swapAt(0, 1)
        // api, then web folded, then the plugin.
        #expect(snapshot.steppingRow(from: "/web/a", offset: 1)?.path == "/h/p/one")
        #expect(snapshot.steppingRow(from: "/web/a", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/web", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/api/e", offset: 1)?.path == "/h/p/one")
        #expect(snapshot.steppingRow(from: "/h/p/one", offset: -1)?.path == "/api/e")
    }

    @Test func foldsListTheRepoThenTheGroup() {
        let snapshot = Self.snapshot
        #expect(snapshot.folds(hiding: "/web/b") == [.repo("/web"), .group(repoPath: "/web", name: "Review")])
        #expect(snapshot.folds(hiding: "/web/d") == [.repo("/web")])
        #expect(snapshot.folds(hiding: "/web") == [.repo("/web")])
        #expect(snapshot.folds(hiding: "/web/ext") == [.repo("/web")])
        #expect(snapshot.folds(hiding: "/api/f") == [.group(repoPath: "/api", name: "Hidden")])
        #expect(snapshot.folds(hiding: "/api/e").isEmpty)
        #expect(snapshot.folds(hiding: "/h/p/one").isEmpty)
        #expect(snapshot.folds(hiding: "/nowhere").isEmpty)
        var folded = snapshot
        folded.plugins[0].collapsed = true
        #expect(folded.folds(hiding: "/h/p/one") == [.plugin("p")])
    }
}
```

And in `WorkspaceGroupTests` (git test, real repo), that the snapshot carries the saved fold:

```swift
@Test func theSnapshotCarriesTheRepoFold() async throws {
    let dir = try TempDir()
    let repo = try await Fixture.repo(in: dir)
    var state = AppState(repos: [RepoEntry(path: repo, dirName: "demo", collapsed: true)])
    state.plugins = [:]
    try StateStore(url: CanopyHome(root: dir.url.appending(path: "home")).stateFile).save(state)
    let workspace = try await makeWorkspace(dir)
    #expect(await workspace.snapshot.repos.first?.collapsed == true)
}
```

(`makeWorkspace` and `Fixture.repo` are the file's existing helpers. Adjust the home path to match `makeWorkspace`'s.)

- [ ] **Step 2: Run them to see them fail**

Run: `make test FILTER=SidebarFoldTests` (or `swift test $(scripts/test-flags.sh) --filter SidebarFoldTests`).
Expected: compile errors, since `collapsed` and `folds(hiding:)` do not exist.

- [ ] **Step 3: Implement**

`RepoEntry` gains `public var collapsed: Bool`, an init parameter `collapsed: Bool = false`, and in `init(from:)`:

```swift
// A fold that cannot be read leaves the repo expanded rather than failing to load it.
collapsed = (try? container.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
```

`PluginEntry` gains the same field, init parameter, and decode line.

`RepoSnapshot` gains `public var collapsed: Bool` (init parameter `collapsed: Bool = false`), and:

```swift
/// The rows the sidebar shows: none while the repo is folded, and otherwise all but those in collapsed groups and
/// other tools' worktrees.
public var visibleRows: [Row] {
    guard !collapsed else { return [] }
    let collapsed = Set(groups.filter(\.collapsed).map(\.name))
    return rows.filter { $0.group.map { !collapsed.contains($0) } ?? true }
}
```

`PluginSection` gains `public var collapsed: Bool` with init parameter `collapsed: Bool = false`.

`WorkspaceSnapshot.visibleRows` leaves out folded sections' rows, while `steppingRow` keeps every row in its `all` list:

```swift
public var visibleRows: [SidebarRow] {
    repos.flatMap(\.visibleRows).map(SidebarRow.worktree)
        + activePlugins.filter { !$0.collapsed }.flatMap(\.rows).map(SidebarRow.plugin)
}
```

`Workspace.snapshot` sets `repo.collapsed = entry.collapsed` beside the name, and `pluginSections` passes `collapsed: entry.collapsed`.

New `Sources/CanopyCore/Rows/SidebarFold.swift`:

```swift
/// A header the sidebar folds, hiding the rows under it.
public enum SidebarFold: Sendable, Equatable {
    case repo(String)
    case group(repoPath: String, name: String)
    case plugin(String)
}

extension WorkspaceSnapshot {
    /// The folded headers hiding a row, outermost first: its repo, then its group, or its plugin's section. Empty for
    /// a row the sidebar shows, and for one it does not have.
    public func folds(hiding path: String) -> [SidebarFold] {
        if let row = row(path: path), let repo = repo(path: row.repoPath) {
            var folds: [SidebarFold] = repo.collapsed ? [.repo(repo.path)] : []
            if let group = row.group, repo.groups.contains(where: { $0.name == group && $0.collapsed }) {
                folds.append(.group(repoPath: repo.path, name: group))
            }
            return folds
        }
        if let row = pluginRow(path: path), section(row.plugin)?.collapsed == true {
            return [.plugin(row.plugin)]
        }
        return []
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'SidebarFoldTests|StateStoreTests|GroupSnapshotTests|WorkspaceGroupTests'`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: carry a repo's and a plugin section's fold in state and snapshots"
```

### Task 2: Folding and revealing in the workspace

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+Folding.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace+Groups.swift` (move `revealRow` out, `setGroupCollapsed` returns `GroupInfo`), `Sources/CanopyCore/Plugins/PluginHost.swift` (`select` reveals)
- Test: `Tests/CanopyCoreTests/WorkspaceFoldTests.swift` (new)

**Interfaces:**
- Consumes: Task 1's fields and `folds(hiding:)`.
- Produces: `Workspace.setRepoCollapsed(repoPath: String, collapsed: Bool) throws`, `Workspace.setPluginCollapsed(_ id: String, collapsed: Bool) throws`, `Workspace.revealRow(path: String) throws` (now for every fold), `Workspace.setGroupCollapsed(...) throws -> GroupInfo` (discardable).

- [ ] **Step 1: Write the failing tests**

```swift
struct WorkspaceFoldTests {
    @Test func aRepoFoldIsSavedAndLogsNothing() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let workspace = try await makeWorkspace(dir)
        try await workspace.addRepo(path: repo)

        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)
        try await workspace.setRepoCollapsed(repoPath: repo, collapsed: true)

        #expect(await workspace.snapshot.repo(path: repo)?.collapsed == true)
        await workspace.stop()
        let relaunched = try await makeWorkspace(dir)
        #expect(await relaunched.snapshot.repo(path: repo)?.collapsed == true)
        #expect(try events(in: dir).filter { $0.type != ActivityType.repoAdded }.isEmpty)
    }

    @Test func revealingARowUnfoldsItsRepoAndGroup() async throws {
        // A row in group Review of a folded repo, with Review folded too.
        ...
        try await workspace.revealRow(path: row.path)
        let snapshot = await workspace.snapshot
        #expect(snapshot.repo(path: repo)?.collapsed == false)
        #expect(snapshot.repo(path: repo)?.groups.first?.collapsed == false)
        #expect(snapshot.folds(hiding: row.path).isEmpty)
    }

    @Test func revealingAShownRowChangesNothing() async throws { ... }

    @Test func pluginFoldIsSavedAndUnknownPluginsFail() async throws {
        // registerPlugins([fixture info]), fold it, check the section and state.json, unfold,
        // then setPluginCollapsed("nope") throws WorkspaceError.pluginNotFound.
    }

    @Test func aMissingRepoCanFoldAndAnUnknownOneFails() async throws { ... }
}
```

The file's full tests are written against the helpers `makeWorkspace` and `Fixture.repo` already used by `WorkspaceGroupTests`, and an `events(in:)` helper that reads the activity folder with `ActivityReader`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter WorkspaceFoldTests`.
Expected: compile errors for `setRepoCollapsed` and `setPluginCollapsed`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Workspace/Workspace+Folding.swift`:

```swift
import Foundation

/// Folding is how the sidebar looks, so each fold is saved but not logged.
extension Workspace {
    public func setRepoCollapsed(repoPath: String, collapsed: Bool) throws {
        try changeEntry(repoPath: repoPath) { entry, _ in entry.collapsed = collapsed }
    }

    /// A plugin's fold is kept while it is off, like its rows.
    public func setPluginCollapsed(_ id: String, collapsed: Bool) throws {
        guard pluginInfos.contains(where: { $0.id == id }) else { throw WorkspaceError.pluginNotFound(id) }
        guard (state.plugins[id]?.collapsed ?? false) != collapsed else { return }
        state.plugins[id, default: PluginEntry()].collapsed = collapsed
        try save()
        publish()
    }

    /// Unfolds whatever hides a row, its repo and its group or its plugin's section, so selecting the row shows it.
    public func revealRow(path: String) throws {
        for fold in snapshot.folds(hiding: path) {
            switch fold {
            case .repo(let repoPath): try setRepoCollapsed(repoPath: repoPath, collapsed: false)
            case .group(let repoPath, let name): try setGroupCollapsed(repoPath: repoPath, name: name, collapsed: false)
            case .plugin(let id): try setPluginCollapsed(id, collapsed: false)
            }
        }
    }
}
```

`setGroupCollapsed` becomes `@discardableResult ... -> GroupInfo`, returning `try groupInfo(repoPath:name:)` after the change.
`PluginHost.select(_:)` calls `try? await workspace.revealRow(path: path)` before `setSelectedRow`, as `WorkspaceControlHandler.select` does.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'WorkspaceFoldTests|WorkspaceGroupTests|GroupControlTests|PluginHostTests'`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: fold repos and plugin sections, and unfold what hides a row being selected"
```

### Task 3: Control methods, the CLI, and the agent guide

**Files:**
- Modify: `Sources/CanopyCore/Control/ControlMethods.swift`, `GroupMethods.swift`, `PluginMethods.swift`, `WorkspaceControlHandler.swift`, `Sources/CanopyCore/Plugins/PluginHost.swift`, `Sources/CanopyCLI/RepoCommand.swift`, `GroupCommand.swift`, `PluginCommand.swift`, `AgentGuide.swift`
- Test: `Tests/CanopyCoreTests/FoldControlTests.swift` (new)

**Interfaces:**
- Consumes: Task 2's workspace methods.
- Produces: methods `repo.collapse`, `repo.expand` (params `RepoFoldParams { target: TargetHint }`, result `RepoInfo`), `group.collapse`, `group.expand` (`GroupParams`, result `GroupInfo`), `plugin.collapse`, `plugin.expand` (`PluginFoldParams { plugin: String }`, result `PluginListing`); `RepoInfo.collapsed`, `PluginListing.collapsed`; `PluginHost.setCollapsed(_ id: String, _ collapsed: Bool) async throws -> PluginListing`.

- [ ] **Step 1: Write the failing tests**

`FoldControlTests`, through the in-process server like `GroupControlTests`:

```swift
@Test func reposFoldOverTheSocket() async throws {
    // repo.collapse with TargetHint(repo: "demo") twice: each returns RepoInfo with collapsed true,
    // repo.list shows collapsed true, repo.expand returns collapsed false,
    // an unknown repo fails with repo_not_found, and no target at all with missing_target.
    // The workspace's activity has cli.call for each and no other event.
}

@Test func groupsFoldOverTheSocket() async throws {
    // group.collapse "review" returns GroupInfo(name: "Review", collapsed: true), repeat is fine,
    // group.expand returns collapsed false, a missing group fails with group_not_found.
}

@Test func pluginsFoldOverTheSocket() async throws {
    // With the fixture plugin registered: plugin.collapse returns a listing with collapsed true,
    // plugin.list shows it, plugin.expand clears it, and plugin.collapse "nope" fails with plugin_not_found.
}

@Test func selectingOverTheSocketUnfolds() async throws {
    // A folded repo: row.new with select false leaves it folded, row.new with select true unfolds it,
    // and row.select of a row in a folded repo unfolds it and reaches the UI bridge.
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter FoldControlTests`.
Expected: compile errors for the new method names and params.

- [ ] **Step 3: Implement the methods**

```swift
// ControlMethod
public static let repoCollapse = "repo.collapse"
public static let repoExpand = "repo.expand"

/// The repo to fold or unfold, resolved the usual way.
public struct RepoFoldParams: Codable, Sendable {
    public var target: TargetHint
    public init(target: TargetHint = TargetHint()) { self.target = target }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
    }
}
```

`GroupMethod.collapse = "group.collapse"` and `expand`, `PluginMethod.collapse = "plugin.collapse"` and `expand`, with `PluginFoldParams { plugin }`.
`RepoInfo` gains `collapsed = repo.collapsed`, and `PluginListing` gains `collapsed`, filled from `snapshot.section(id)?.collapsed`.

In `WorkspaceControlHandler.result(for:)`:

```swift
case ControlMethod.repoCollapse, ControlMethod.repoExpand:
    let params = try request.decodeParams(RepoFoldParams.self)
    let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
    try await workspace.setRepoCollapsed(
        repoPath: repo.path, collapsed: request.method == ControlMethod.repoCollapse)
    return try .from(RepoInfo(await workspace.snapshot.repo(path: repo.path) ?? repo))

case GroupMethod.collapse, GroupMethod.expand:
    let params = try request.decodeParams(GroupParams.self)
    let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
    return try .from(
        try await workspace.setGroupCollapsed(
            repoPath: repo.path, name: params.name, collapsed: request.method == GroupMethod.collapse))

case PluginMethod.collapse, PluginMethod.expand:
    let params = try request.decodeParams(PluginFoldParams.self)
    return try .from(
        try await plugins.setCollapsed(params.plugin, request.method == PluginMethod.collapse))
```

`PluginHost.setCollapsed` checks the plugin with `requirePlugin`, calls `workspace.setPluginCollapsed`, and returns `listing(plugin, in: await workspace.snapshot)`.

- [ ] **Step 4: The commands**

`canopy repo collapse [<repo>]` and `canopy repo expand [<repo>]`, where the repo defaults to the one you are in, printing `Collapsed web-app.` and `Expanded web-app.`.
`canopy group collapse <name> [--repo]` and `expand`, printing `Collapsed group Review in web-app.` and `Expanded group Review in web-app.`.
`canopy plugin collapse <plugin>` and `expand`, printing `Collapsed Fixture.` and `Expanded Fixture.`.
Each abstract says the command is safe to repeat.
`repo list --json` and `plugin list --json` carry `collapsed`, and the text tables are unchanged.

Each command in `RepoCommand` follows the file's pattern:

```swift
struct Collapse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fold a repo away in the sidebar. Safe to repeat.",
        discussion: "Its rows keep running and stay in `row list`, but get no ⌘1 to ⌘9 until it is expanded.")

    @Argument(help: "Repo name or path. Defaults to the repo you are in.")
    var repo: String?
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try fold(ControlMethod.repoCollapse, repo: repo, json: output.json) { "Collapsed \($0)." }
    }
}
```

with a file-private `fold` helper shared by `Collapse` and `Expand`.

- [ ] **Step 5: The agent guide**

The Repos part gains `canopy repo collapse [<repo>] | canopy repo expand [<repo>]` and one sentence: folding only hides rows in the sidebar, is safe to repeat, and shows as `collapsed` in `repo list --json`.
The Groups part gains `canopy group collapse <name> | canopy group expand <name>`, and the Plugins part `canopy plugin collapse <plugin> | canopy plugin expand <plugin>`.

- [ ] **Step 6: Run the tests to see them pass, then commit**

Run: `swift test $(scripts/test-flags.sh) --filter 'FoldControlTests|GroupControlTests|PluginControlTests|ControlServerTests'`.

```bash
git commit -am "feat: canopy repo, group, and plugin collapse and expand"
```

### Task 4: The sidebar

**Files:**
- Modify: `Sources/CanopyApp/Style/Style.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/Sidebar/GroupViews.swift`, `Sources/CanopyApp/Plugins/PluginSectionView.swift`, `Sources/CanopyApp/AppModel.swift`

**Interfaces:**
- Consumes: `RepoSnapshot.collapsed`, `PluginSection.collapsed`, `folds(hiding:)`, the workspace setters.
- Produces: `AppModel.setCollapsed(_ repo: RepoSnapshot, _ collapsed: Bool)`, `AppModel.setCollapsed(_ section: PluginSection, _ collapsed: Bool)`, `AppModel.selectionFold: SidebarFold?`, `DisclosureChevron`.

- [ ] **Step 1: One chevron for every fold**

```swift
/// The chevron of everything that folds in the sidebar: right while folded, down while open.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.easeOut(duration: 0.15), value: isExpanded)
            .foregroundStyle(.tertiary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}
```

`GroupHeaderView` and `OtherWorktreesToggle` use it in place of their own copies.

- [ ] **Step 2: AppModel**

```swift
/// The outermost folded header hiding the selected row, which draws the selection in its place.
var selectionFold: SidebarFold? {
    selectedRowPath.flatMap { snapshot.folds(hiding: $0).first }
}

func setCollapsed(_ repo: RepoSnapshot, _ collapsed: Bool) {
    perform { try await $0.setRepoCollapsed(repoPath: repo.path, collapsed: collapsed) }
}

func setCollapsed(_ section: PluginSection, _ collapsed: Bool) {
    perform { try await $0.setPluginCollapsed(section.id, collapsed: collapsed) }
}
```

`select(_:)` unfolds what hides the row before selecting it, so the picker's already-open rows and adopted rows unfold too, and `reveal(_:)` selects at once and then calls it:

```swift
func select(_ path: String) async {
    do {
        try await workspace.revealRow(path: path)
    } catch {
        show(error)
    }
    apply(await workspace.snapshot)
    selectedRowPath = path
    scrollRequest = ScrollRequest(path: path)
}

func reveal(_ path: String) {
    selectedRowPath = path
    Task { await select(path) }
}
```

`run(_:in:group:)` drops its own `revealRow` call, which `select` now makes.

- [ ] **Step 3: The repo header and section**

`RepoHeaderView` reads: the tile, the name, the chevron, then the missing tag and error mark, and on the right the agent dot (only while folded) and the count, which gives way to `…` and `+` on hover.
The chevron sits right after the name rather than in the mark column, which the tile holds, so the tile keeps lining up with the rows' marks.
Clicking the header anywhere but its buttons folds or unfolds the repo.
While folded and holding the selection (`model.selectionFold == .repo(repo.path)`), it draws the selection fill, accent-tinted while the sidebar has the keyboard.
VoiceOver reads one button: "web-app, repo, 7 rows", then the dot's label, with the value Collapsed or Expanded and an action that toggles.

`RepoSection` shows only the header while the repo is folded: no PR warning, rows, groups, or other worktrees.
It animates on `repo.collapsed` as it does on `repo.groups`.
`GroupHeaderView.holdsSelection` becomes `model.selectionFold == .group(repoPath: repo.path, name: group.name)`.

- [ ] **Step 4: The plugin header and section**

`PluginHeaderView` gets the same chevron after the name, click to fold, dot while folded, selection fill for `.plugin(section.id)`, and the VoiceOver button, "Tickets, plugin, 3 rows".
`PluginSectionView` shows only the header while folded.

- [ ] **Step 5: Build, lint, commit**

Run: `make build 2>&1 | grep -c 'warning:'` (expect 0) and `make lint`.

```bash
git commit -am "feat: fold a repo or a plugin's section from its header"
```

### Task 5: End-to-end cases and the UI fixture

**Files:**
- Modify: `scripts/e2e.sh`, `scripts/ui-fixture.sh`

- [ ] **Step 1: e2e**

A new step after the groups step, "canopy repo collapse folds a repo":

```bash
step "canopy repo collapse, group collapse, and their expand fold the sidebar"
collapsed_of() { "$cli" repo list --json | /usr/bin/python3 -c 'import json, sys; print({r["name"]: r["collapsed"] for r in json.load(sys.stdin)}[sys.argv[1]])' "$1"; }
[[ "$(collapsed_of demo)" == False ]] || fail "a new repo is collapsed"
"$cli" repo collapse demo | grep -qx "Collapsed demo." || fail "repo collapse said something else"
"$cli" repo collapse demo | grep -qx "Collapsed demo." || fail "repeating repo collapse failed"
[[ "$(collapsed_of demo)" == True ]] || fail "repo list --json does not show the fold"
"$cli" row list --repo demo | grep -q '^feat/grouped ' || fail "row list left out a folded repo's rows"
"$cli" row select feat/grouped --repo demo >/dev/null
[[ "$(collapsed_of demo)" == False ]] || fail "row select did not unfold the repo"
"$cli" group collapse kept --repo demo | grep -qx "Collapsed group Kept in demo." || fail "group collapse said something else"
... group expand, a missing group, repo collapse of an unknown repo (repo_not_found),
... and after "groups come back after a relaunch", repo collapsed again survives a relaunch.
```

The plugins step gains `plugin collapse fixture`, its `collapsed` in `plugin list --json`, `plugin new fixture 2 --select` unfolding it, and `plugin collapse nope` failing with `plugin_not_found`.
The agent-guide check gains `canopy repo collapse`.
`canopy log --type cli` shows the fold calls, and `canopy log` has no other event from them.

- [ ] **Step 2: The fixture**

`scripts/ui-fixture.sh` folds the Later group with `canopy group collapse Later --repo web-app`, which the comment there says no command did, and folds the `api-server` repo with `canopy repo collapse api-server`, so its header shows the working dot of `feat/rate-limits` while the ports panel still lists that row's port.

- [ ] **Step 3: Run and commit**

Run: `make e2e`.

```bash
git commit -am "test: end-to-end cases for folding, and a folded repo and group in the UI fixture"
```

### Task 6: Specs

**Files:**
- Modify: `docs/superpowers/specs/2026-09-27-canopy-design.md`, `2026-09-28-canopy-row-groups-design.md`, `2026-09-28-canopy-agent-state-design.md`, `2026-09-29-canopy-plugins-design.md`

- [ ] **Step 1: Main spec**

- Sidebar rows: a "Folding repos" part with the header's chevron, what folds, the dot and count, the selection fill, unfolding on selection from outside, `⌘1` to `⌘9` and the arrows, drops, VoiceOver, and the ports panel.
- Sidebar order: a folded repo shows only its header.
- Persistence: each repo's fold.
- Commands: `canopy repo collapse|expand`.
- The window layout sketch stays as it is.

- [ ] **Step 2: Row groups spec**

- Sidebar order: a folded repo hides its groups with its rows.
- Keyboard: the same rules for rows in folded repos and plugin sections.
- Decision 3 now says `canopy group collapse` and `expand` exist, and the CLI and control tables list them.
- The selection section: the outermost folded header holds the selection.

- [ ] **Step 3: Agent state and plugins specs**

- Agent state, Collapsed row groups: a folded repo's and a folded plugin section's header show the most urgent dot too.
- Plugins, Sidebar: a plugin's section folds like a repo's, with `canopy plugin collapse|expand`, and its fold is kept in its entry while it is off.

- [ ] **Step 4: Commit**

```bash
git commit -am "docs: folding repos and plugin sections in the specs"
```

### Task 7: UI checks and the merge bar

- [ ] Build `make app`, open `scripts/ui-fixture.sh dark`, and with `build/ui` click the chevron and the header of a repo, fold the repo holding the selection, press `↑`, `↓`, and hover rows for `⌘N` hints with a folded repo, fold a plugin section, pick a hidden row from the ports panel, and relaunch to see the folds kept.
- [ ] Window shots in dark and light, checking the chevron, dot, and count line up with the group headers'.
- [ ] `make lint`, `make build` and `swift build --build-tests $(scripts/test-flags.sh)` with 0 warnings, three `make test` runs under the shared lock, `make e2e`, on a branch rebased onto the current `origin/main`.
- [ ] An independent reviewer on `git diff origin/main...HEAD` with the specs and this plan, its findings fixed and listed under After Review below.
