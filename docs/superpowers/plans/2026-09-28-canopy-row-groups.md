# Canopy Row Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a repo's rows be gathered into named groups that fold away in the sidebar, with every group action available to agents through `canopy group` and `canopy row move`.

**Architecture:** Groups live on each repo's entry in `state.json`, and `rowOrder` keeps only ungrouped rows, so each Canopy or adopted row sits in exactly one ordered list.
The rules (names, moves, the reconcile with git) are value-type methods on `RepoEntry`, and dropping a dragged row is a pure function over the sidebar's line frames, so both are tested without git or UI.
`Workspace` applies them, logs the events, and arranges each repo snapshot in sidebar order with each `Row` carrying its group's name, so the control API, the CLI, and the sidebar all read one arrangement.

**Tech Stack:** Swift 6.2, SwiftUI and AppKit on macOS 15, swift-argument-parser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`, approved with its eleven "Decisions to review" on 2026-09-28.
The main spec, `docs/superpowers/specs/2026-09-27-canopy-design.md`, covers what groups build on: "Sidebar order", "Sidebar rows", "Control API", and "Activity log".

## Global Constraints

- A group belongs to one repo, and a row can only join a group in its own repo.
- Order within a repo: the main row, the ungrouped rows, each group's header and its rows unless collapsed, then the other worktrees fold.
  A repo with no groups looks exactly as today.
- Names are trimmed of whitespace and newlines, must not be empty, must not hold a control character, and are unique per repo ignoring case.
  Lookups trim and ignore case.
  The stored name keeps its case.
- Membership is keyed by row path.
  Rows gone from git leave their group.
  Empty groups stay until deleted.
  A missing row stays in its group.
- `groups` and each group field decode with decodeIfPresent.
  An unreadable `groups` is dropped alone.
  `version` stays 1.
- A group that does not exist is an error, never created on the fly.
  Only `group new` and the UI's New Group create one.
- A move that changes nothing succeeds and logs no `row.moved`.
  Only a change of group logs `row.moved`.
  Deleting a group logs one `group.removed`.
- `⌘1` to `⌘9` and `↑`/`↓` follow the visible order, skipping rows in collapsed groups.
- Error codes: `invalid_group_name`, `group_exists`, `group_not_found`, `cannot_move_main`, `not_managed`, `invalid_anchor`, `bad_params`.
- Swift 6 language mode with strict concurrency, no warnings, and `make lint` clean after every task.
- UI checks use `scripts/ui-fixture.sh`, `scripts/ui.swift`, and `scripts/window-shot.swift` on a throwaway home.
  Never full-screen shots.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. **A refresh landing while `row new --group` runs git** must not show the new row among the ungrouped rows first, and must not log it twice.
   Pinned by `aRowCreatedIntoAGroupNeverShowsUngrouped` in Task 3, which stalls `git worktree add` and refreshes during it.
2. **A hand-edited `state.json`** with a path in two groups, a group without a name, two names differing only in case, or `groups` of the wrong type must load, keep repos and rows, and never show a row twice.
   Pinned by `groupsThatCannotBeTrustedAreCleanedOnLoad` and `anUnreadableGroupsListIsDroppedAlone` in Task 1.
3. **Dropping a row back where it came from**, onto itself, or on the main row when it is already first must change nothing and log nothing.
   Pinned by `dropsThatChangeNothingAreNoOps` in Task 5 and `movesThatChangeNothingLogNothing` in Task 2.
4. **`↑` and `↓` from a selected row hidden in a collapsed group** must continue from the group's place, not jump to the top or bottom of the sidebar.
   Pinned by `steppingFromAHiddenRowContinuesFromItsGroup` in Task 2.
5. **Deleting or renaming a group while `row new --group` for it runs** must still create the row, ungrouped, with a warning, rather than failing after the worktree exists.
   Pinned by `aGroupDeletedWhileItsRowIsCreatedLeavesTheRowUngrouped` in Task 3.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/CanopyCore/State/AppState.swift` | modify | `RepoEntry.groups` and its decoding |
| `Sources/CanopyCore/Rows/RowGroups.swift` | create | `RowGroup`, `GroupName`, `RowPlacement`, and `RepoEntry`'s group rules: add, rename, remove, move, reconcile |
| `Sources/CanopyCore/Rows/RowOrdering.swift` | delete | replaced by `RepoEntry.reconcile` |
| `Sources/CanopyCore/Rows/Row.swift` | modify | `Row.group` |
| `Sources/CanopyCore/Rows/RowDrop.swift` | create | `DropSlot`, `RowDropTarget`, and `RowDrop.target`, the pure drop resolution |
| `Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift` | modify | `GroupSnapshot`, `RepoSnapshot.groups`, `arranged(by:)`, visible rows, and stepping |
| `Sources/CanopyCore/Workspace/Workspace+Groups.swift` | create | group operations, moves, folding, revealing, and their events |
| `Sources/CanopyCore/Workspace/Workspace.swift` | modify | the reconcile on refresh, arranging snapshots |
| `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift` | modify | `createRow(group:)` |
| `Sources/CanopyCore/Workspace/WorkspaceError.swift` | modify | the new error cases |
| `Sources/CanopyCore/Activity/ActivityEvent.swift`, `ActivityReader.swift` | modify | event types and their `canopy log` text |
| `Sources/CanopyCore/Control/GroupMethods.swift` | create | `group.*` and `row.move` params and results |
| `Sources/CanopyCore/Control/ControlMethods.swift`, `WorkspaceControlHandler.swift` | modify | wiring, `row.new` `group`, read-only list |
| `Sources/CanopyCLI/GroupCommand.swift` | create | `canopy group list|new|rename|rm` |
| `Sources/CanopyCLI/RowCommand.swift`, `AgentGuide.swift`, `CanopyCLI.swift` | modify | `row move`, `row new --group`, the GROUP column, the Groups section |
| `Sources/CanopyApp/Sidebar/GroupViews.swift` | create | the group header, its menu, and the name and delete popovers |
| `Sources/CanopyApp/Sidebar/RowDragAndDrop.swift` | create | the row drag source, the list's drop delegate, and the indicator |
| `Sources/CanopyApp/Sidebar/SidebarView.swift`, `RowActionViews.swift`, `PortsPanel.swift` | modify | sections with groups, Move to Group, the sheet's picker, revealing from the ports panel |
| `Sources/CanopyApp/AppModel.swift` | modify | group actions, stepping, and the row being dragged |
| `Sources/CanopyApp/Style/Style.swift` | modify | the group indent |
| `Resources/Info.plist.in` | modify | declares the private row pasteboard type |
| `scripts/ui.swift`, `scripts/ui-fixture.sh`, `scripts/e2e.sh` | modify | right clicks and held drags, groups in the fixture, group cases |
| `scripts/window-shot.swift` | modify | `--all`, which shots the app's own menus and popovers too |
| `docs/superpowers/specs/*.md` | modify | pointers from the main spec's tables |

## Task 1: Group rules on the repo entry

**Files:** Create `Sources/CanopyCore/Rows/RowGroups.swift`.
Modify `AppState.swift`, `WorkspaceError.swift`.
Test `Tests/CanopyCoreTests/RowGroupTests.swift`, `StateStoreTests.swift`.

**Interfaces:**
- Produces `RowGroup` (`name: String`, `rows: [String]`, `collapsed: Bool`), `RepoEntry.groups: [RowGroup]`.
- Produces `GroupName.validated(_:) throws -> String` and `GroupName.key(_:) -> String`.
- Produces `RowPlacement`: `.group(String)`, `.ungrouped`, `.before(String)`, `.after(String)`, the last two holding row paths.
- Produces on `RepoEntry`: `groupIndex(named:) -> Int?`, `groupName(of:) -> String?`, `holds(_:) -> Bool`, and mutating `addGroup(_:repo:) throws -> RowGroup`, `renameGroup(_:to:repo:) throws -> RowGroup`, `removeGroup(_:repo:) throws -> RowGroup`, `move(_:to:repo:) throws -> Bool`, `reconcile(present:joining:) -> Bool`.
- Produces `WorkspaceError.invalidGroupName`, `.groupExists(String, repo:)`, `.groupNotFound(String, repo:)`, `.cannotMoveMain`, `.invalidAnchor(String)`.

Tests, all pure:

- `namesAreTrimmedAndMustHoldSomething`: `"  Review \n"` becomes `"Review"`, and `""`, `"   "`, `"a\tb"`, and `"a\nb"` throw `invalidGroupName`.
- `namesAreUniqueIgnoringCase`: adding `"review"` next to `"Review"` throws `groupExists("Review", repo:)`.
- `renamingToAnotherCaseOfItsOwnNameIsAllowed`, and renaming onto another group's name throws `groupExists`.
- `lookupsTrimAndIgnoreCase`: `groupIndex(named: " REVIEW ")` finds `"Review"`.
- `removingAGroupUngroupsItsRowsInOrder`: its rows go to the end of `rowOrder` in group order.
- `movesPlaceRowsWhereAsked`: into a group (end), out of one (end of `rowOrder`), before and after rows inside and outside groups, each moving the path out of its old list.
- `movesThatChangeNothingReturnFalse`: `.group` for its own group, `.ungrouped` for an ungrouped row, `.after` the row just above it.
- `movesRejectBadTargets`: a missing group throws `groupNotFound`, an anchor that is the row itself or not held throws `invalidAnchor`, and a row the entry does not hold throws `rowNotFound`.
- `reconcileFollowsGit`: gone paths leave groups and `rowOrder`, new paths join `rowOrder`, a new path in `joining` joins that group, empty groups stay, and nothing changed returns false.
- `aPathInTwoPlacesKeepsTheFirstGroup`.
- In `StateStoreTests`: `groupsRoundTrip`, `groupsThatCannotBeTrustedAreCleanedOnLoad` (a group with no name, one with a blank name, two names differing in case, and a path in two groups load as one clean group per name with each path once), and `anUnreadableGroupsListIsDroppedAlone` (`"groups": 7` keeps the repo, its `adopted` and `rowOrder`).

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/RowGroupTests.swift` (new):

```swift
import Testing

@testable import CanopyCore

struct RowGroupTests {
    /// Ungrouped rows a and b, "Review" holding c and d, and an empty "Later".
    func entry() -> RepoEntry {
        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: ["a", "b"])
        entry.groups = [RowGroup(name: "Review", rows: ["c", "d"]), RowGroup(name: "Later", collapsed: true)]
        return entry
    }

    /// Moves a row and says whether it moved, outside `#expect`, which cannot hold a mutating call.
    func moved(_ entry: inout RepoEntry, _ path: String, to placement: RowPlacement) throws -> Bool {
        try entry.move(path, to: placement, repo: "r")
    }

    @Test func namesAreTrimmedAndMustHoldSomething() throws {
        #expect(try GroupName.validated("  Review \n") == "Review")
        #expect(try GroupName.validated("Code review") == "Code review")
        for bad in ["", "   ", "\n", "a\tb", "a\nb", "a\u{7}b"] {
            #expect(throws: WorkspaceError.invalidGroupName(bad)) { try GroupName.validated(bad) }
        }
    }

    @Test func namesAreUniqueIgnoringCase() throws {
        var entry = entry()

        #expect(throws: WorkspaceError.groupExists("Review", repo: "r")) { try entry.addGroup(" review ", repo: "r") }
        #expect(throws: WorkspaceError.invalidGroupName(" ")) { try entry.addGroup(" ", repo: "r") }

        let added = try entry.addGroup(" Spikes ", repo: "r")
        #expect(added == RowGroup(name: "Spikes"))
        #expect(entry.groups.map(\.name) == ["Review", "Later", "Spikes"])
    }

    @Test func renamingToAnotherCaseOfItsOwnNameIsAllowed() throws {
        var entry = entry()

        let renamed = try entry.renameGroup("review", to: "REVIEW", repo: "r")
        #expect(renamed.name == "REVIEW")
        #expect(entry.groups.map(\.name) == ["REVIEW", "Later"])
        #expect(entry.groups[0].rows == ["c", "d"])

        #expect(throws: WorkspaceError.groupExists("Later", repo: "r")) {
            try entry.renameGroup("REVIEW", to: "later", repo: "r")
        }
        #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "r")) {
            try entry.renameGroup("Nope", to: "Other", repo: "r")
        }
        #expect(throws: WorkspaceError.invalidGroupName("")) { try entry.renameGroup("Later", to: "", repo: "r") }
    }

    @Test func lookupsTrimAndIgnoreCase() {
        let entry = entry()

        #expect(entry.groupIndex(named: " REVIEW ") == 0)
        #expect(entry.groupIndex(named: "later") == 1)
        #expect(entry.groupIndex(named: "Rev") == nil)
        #expect(entry.groupName(of: "d") == "Review")
        #expect(entry.groupName(of: "a") == nil)
        #expect(entry.holds("a") && entry.holds("d") && !entry.holds("z"))
    }

    @Test func removingAGroupUngroupsItsRowsInOrder() throws {
        var entry = entry()

        let removed = try entry.removeGroup("review", repo: "r")

        #expect(removed == RowGroup(name: "Review", rows: ["c", "d"]))
        #expect(entry.rowOrder == ["a", "b", "c", "d"])
        #expect(entry.groups.map(\.name) == ["Later"])
        #expect(throws: WorkspaceError.groupNotFound("Review", repo: "r")) {
            try entry.removeGroup("Review", repo: "r")
        }
    }

    @Test func movesPlaceRowsWhereAsked() throws {
        var entry = entry()

        #expect(try moved(&entry, "a", to: .group("later")))
        #expect(entry.rowOrder == ["b"])
        #expect(entry.groups[1].rows == ["a"])

        #expect(try moved(&entry, "b", to: .group("Review")))
        #expect(entry.rowOrder == [])
        #expect(entry.groups[0].rows == ["c", "d", "b"])

        #expect(try moved(&entry, "d", to: .ungrouped))
        #expect(entry.rowOrder == ["d"])
        #expect(entry.groups[0].rows == ["c", "b"])

        #expect(try moved(&entry, "a", to: .before("d")))
        #expect(entry.rowOrder == ["a", "d"])
        #expect(entry.groups[1].rows == [])

        #expect(try moved(&entry, "a", to: .after("c")))
        #expect(entry.rowOrder == ["d"])
        #expect(entry.groups[0].rows == ["c", "a", "b"])

        #expect(try moved(&entry, "b", to: .before("c")))
        #expect(entry.groups[0].rows == ["b", "c", "a"])

        #expect(try moved(&entry, "b", to: .after("a")))
        #expect(entry.groups[0].rows == ["c", "a", "b"])
    }

    @Test func movesThatChangeNothingReturnFalse() throws {
        var entry = entry()
        let before = entry

        #expect(try !moved(&entry, "c", to: .group("review")))
        #expect(try !moved(&entry, "d", to: .group("Review")))
        #expect(try !moved(&entry, "a", to: .ungrouped))
        #expect(try !moved(&entry, "b", to: .after("a")))
        #expect(try !moved(&entry, "a", to: .before("b")))
        #expect(try !moved(&entry, "d", to: .after("c")))
        #expect(entry == before)
    }

    @Test func movesRejectBadTargets() {
        var entry = entry()
        let before = entry

        #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "r")) {
            try entry.move("a", to: .group("Nope"), repo: "r")
        }
        #expect(throws: WorkspaceError.invalidAnchor("a")) { try entry.move("a", to: .before("a"), repo: "r") }
        #expect(throws: WorkspaceError.invalidAnchor("/r")) { try entry.move("a", to: .after("/r"), repo: "r") }
        #expect(throws: WorkspaceError.rowNotFound("z")) { try entry.move("z", to: .ungrouped, repo: "r") }
        #expect(entry == before)
    }

    @Test func reconcileFollowsGit() {
        var entry = entry()

        var changed = entry.reconcile(present: ["a", "b", "c", "d"])
        #expect(!changed)

        changed = entry.reconcile(present: ["a", "c", "e", "f"], joining: ["f": "later"])
        #expect(changed)
        #expect(entry.rowOrder == ["a", "e"])
        #expect(
            entry.groups == [
                RowGroup(name: "Review", rows: ["c"]), RowGroup(name: "Later", rows: ["f"], collapsed: true),
            ])

        changed = entry.reconcile(present: ["a", "e", "g"], joining: ["g": "Gone"])
        #expect(changed)
        #expect(entry.rowOrder == ["a", "e", "g"])
        #expect(entry.groups.map(\.rows) == [[], []])
    }

    @Test func aPathInTwoPlacesKeepsTheFirstGroup() {
        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: ["a", "b", "a"])
        entry.groups = [RowGroup(name: "One", rows: ["b", "c"]), RowGroup(name: "Two", rows: ["c", "b", "d", "d"])]

        let changed = entry.reconcile(present: ["a", "b", "c", "d"])

        #expect(changed)
        #expect(entry.rowOrder == ["a"])
        #expect(entry.groups.map(\.rows) == [["b", "c"], ["d"]])
    }
}
```

`Tests/CanopyCoreTests/StateStoreTests.swift`:

```diff
@@ -34,6 +34,51 @@ struct StateStoreTests {
         #expect(StateStore(url: url).load() == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r")])))
     }
 
+    @Test func groupsRoundTrip() throws {
+        let dir = try TempDir()
+        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
+        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: ["/a"])
+        entry.groups = [RowGroup(name: "Review", rows: ["/b", "/c"]), RowGroup(name: "Later", collapsed: true)]
+        let state = AppState(repos: [entry])
+
+        try store.save(state)
+
+        #expect(store.load() == .loaded(state))
+    }
+
+    @Test func groupsThatCannotBeTrustedAreCleanedOnLoad() throws {
+        let dir = try TempDir()
+        let url = URL(fileURLWithPath: dir.sub("state.json"))
+        try #"""
+        {"version": 1, "repos": [{"path": "/r", "dirName": "r", "rowOrder": ["/a", "/b"], "groups": [
+            {"rows": ["/x"]},
+            {"name": "  ", "rows": ["/y"]},
+            {"name": " Review ", "rows": ["/b", "/c", "/c"]},
+            {"name": "review", "rows": ["/d"], "collapsed": true},
+            {"name": "Later", "rows": ["/c", "/e"], "collapsed": true},
+            {"name": "Bad\nName", "rows": ["/f"]}
+        ]}]}
+        """#.write(to: url, atomically: true, encoding: .utf8)
+
+        var expected = RepoEntry(path: "/r", dirName: "r", rowOrder: ["/a"])
+        expected.groups = [
+            RowGroup(name: "Review", rows: ["/b", "/c"]), RowGroup(name: "Later", rows: ["/e"], collapsed: true),
+        ]
+        #expect(StateStore(url: url).load() == .loaded(AppState(repos: [expected])))
+    }
+
+    @Test func anUnreadableGroupsListIsDroppedAlone() throws {
+        let dir = try TempDir()
+        let url = URL(fileURLWithPath: dir.sub("state.json"))
+        try #"""
+        {"version": 1, "repos": [{"path": "/r", "dirName": "r", "adopted": ["/a"], "rowOrder": ["/a"], "groups": 7}]}
+        """#.write(to: url, atomically: true, encoding: .utf8)
+
+        #expect(
+            StateStore(url: url).load()
+                == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r", adopted: ["/a"], rowOrder: ["/a"])])))
+    }
+
     @Test func corruptFileIsBackedUp() throws {
         let dir = try TempDir()
         let url = URL(fileURLWithPath: dir.sub("state.json"))
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'RowGroup' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Rows/RowGroups.swift` (new):

```swift
import Foundation

/// A named set of a repo's rows that the sidebar can fold away. Rows are kept by path, in sidebar order.
public struct RowGroup: Codable, Sendable, Equatable {
    public var name: String
    public var rows: [String]
    public var collapsed: Bool

    public init(name: String, rows: [String] = [], collapsed: Bool = false) {
        self.name = name
        self.rows = rows
        self.collapsed = collapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        rows = try container.decodeIfPresent([String].self, forKey: .rows) ?? []
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

public enum GroupName {
    /// The name as stored: trimmed, not empty, and free of control characters such as newlines.
    public static func validated(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw WorkspaceError.invalidGroupName(raw) }
        return name
    }

    /// Names are unique within a repo ignoring case, and looked up the same way.
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Where a moved row goes. `before` and `after` name another row by path.
public enum RowPlacement: Sendable, Equatable {
    /// The end of a group.
    case group(String)
    /// The end of the ungrouped rows.
    case ungrouped
    case before(String)
    case after(String)
}

/// Each Canopy or adopted row of a repo sits in exactly one list: `rowOrder` for the ungrouped rows, or one group's.
extension RepoEntry {
    public func groupIndex(named name: String) -> Int? {
        let key = GroupName.key(name)
        return groups.firstIndex { GroupName.key($0.name) == key }
    }

    public func groupName(of path: String) -> String? {
        groups.first { $0.rows.contains(path) }?.name
    }

    public func holds(_ path: String) -> Bool {
        rowOrder.contains(path) || groups.contains { $0.rows.contains(path) }
    }

    @discardableResult
    mutating func addGroup(_ name: String, repo: String) throws -> RowGroup {
        let name = try GroupName.validated(name)
        if let existing = groupIndex(named: name) {
            throw WorkspaceError.groupExists(groups[existing].name, repo: repo)
        }
        groups.append(RowGroup(name: name))
        return groups[groups.count - 1]
    }

    @discardableResult
    mutating func renameGroup(_ name: String, to newName: String, repo: String) throws -> RowGroup {
        let index = try requireGroup(name, repo: repo)
        let newName = try GroupName.validated(newName)
        if let other = groupIndex(named: newName), other != index {
            throw WorkspaceError.groupExists(groups[other].name, repo: repo)
        }
        groups[index].name = newName
        return groups[index]
    }

    /// Deletes a group. Its rows go to the end of the ungrouped rows, in their order.
    @discardableResult
    mutating func removeGroup(_ name: String, repo: String) throws -> RowGroup {
        let removed = groups.remove(at: try requireGroup(name, repo: repo))
        rowOrder += removed.rows
        return removed
    }

    /// Returns whether the row moved. A move that would leave it where it is changes nothing.
    mutating func move(_ path: String, to placement: RowPlacement, repo: String) throws -> Bool {
        guard holds(path) else { throw WorkspaceError.rowNotFound(path) }
        var moved = self
        moved.take(path)
        switch placement {
        case .group(let name):
            let index = try requireGroup(name, repo: repo)
            guard !groups[index].rows.contains(path) else { return false }
            moved.groups[index].rows.append(path)
        case .ungrouped:
            guard !rowOrder.contains(path) else { return false }
            moved.rowOrder.append(path)
        case .before(let anchor), .after(let anchor):
            guard anchor != path, holds(anchor) else { throw WorkspaceError.invalidAnchor(anchor) }
            let offset = placement == .after(anchor) ? 1 : 0
            if let index = moved.rowOrder.firstIndex(of: anchor) {
                moved.rowOrder.insert(path, at: index + offset)
            } else if let group = moved.groups.firstIndex(where: { $0.rows.contains(anchor) }),
                let index = moved.groups[group].rows.firstIndex(of: anchor)
            {
                moved.groups[group].rows.insert(path, at: index + offset)
            }
        }
        guard moved != self else { return false }
        self = moved
        return true
    }

    /// Brings the lists in line with the repo's current Canopy and adopted rows, as git lists them. Rows that went away
    /// leave their list, and new rows go to the end of the group `joining` names for them, or else of `rowOrder`.
    /// Empty groups stay. Returns whether anything changed.
    mutating func reconcile(present: [String], joining: [String: String] = [:]) -> Bool {
        let original = self
        let isPresent = Set(present)
        var placed = Set<String>()
        for index in groups.indices {
            groups[index].rows = groups[index].rows.filter { isPresent.contains($0) && placed.insert($0).inserted }
        }
        rowOrder = rowOrder.filter { isPresent.contains($0) && placed.insert($0).inserted }
        for path in present where placed.insert(path).inserted {
            if let name = joining[path], let index = groupIndex(named: name) {
                groups[index].rows.append(path)
            } else {
                rowOrder.append(path)
            }
        }
        return self != original
    }

    /// Makes groups read from a file follow the rules: valid names unique ignoring case, and each path in one place,
    /// the first group that lists it.
    mutating func cleanGroups() {
        var names = Set<String>()
        var placed = Set<String>()
        groups = groups.compactMap { group in
            guard let name = try? GroupName.validated(group.name), names.insert(GroupName.key(name)).inserted else {
                return nil
            }
            return RowGroup(
                name: name, rows: group.rows.filter { placed.insert($0).inserted }, collapsed: group.collapsed)
        }
        rowOrder = rowOrder.filter { placed.insert($0).inserted }
    }

    private func requireGroup(_ name: String, repo: String) throws -> Int {
        guard let index = groupIndex(named: name) else {
            throw WorkspaceError.groupNotFound(name.trimmingCharacters(in: .whitespacesAndNewlines), repo: repo)
        }
        return index
    }

    private mutating func take(_ path: String) {
        rowOrder.removeAll { $0 == path }
        for index in groups.indices {
            groups[index].rows.removeAll { $0 == path }
        }
    }
}
```

`Sources/CanopyCore/State/AppState.swift`:

```diff
@@ -2,13 +2,18 @@ public struct RepoEntry: Codable, Sendable, Equatable {
     public var path: String
     public var dirName: String
     public var adopted: [String]
+    /// The ungrouped Canopy and adopted rows, in sidebar order. Grouped rows are in `groups`.
     public var rowOrder: [String]
+    public var groups: [RowGroup]
 
-    public init(path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = []) {
+    public init(
+        path: String, dirName: String, adopted: [String] = [], rowOrder: [String] = [], groups: [RowGroup] = []
+    ) {
         self.path = path
         self.dirName = dirName
         self.adopted = adopted
         self.rowOrder = rowOrder
+        self.groups = groups
     }
 
     public init(from decoder: any Decoder) throws {
@@ -17,6 +22,9 @@ public struct RepoEntry: Codable, Sendable, Equatable {
         dirName = try container.decode(String.self, forKey: .dirName)
         adopted = try container.decodeIfPresent([String].self, forKey: .adopted) ?? []
         rowOrder = try container.decodeIfPresent([String].self, forKey: .rowOrder) ?? []
+        // Groups that cannot be read are dropped on their own, so the repo and its rows still load.
+        groups = (try? container.decodeIfPresent([RowGroup].self, forKey: .groups)) ?? []
+        cleanGroups()
     }
 }
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -26,6 +26,11 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case ghFailed(String)
     case portNotFound(Int)
     case portInOtherRow(Int, row: String)
+    case invalidGroupName(String)
+    case groupExists(String, repo: String)
+    case groupNotFound(String, repo: String)
+    case cannotMoveMain
+    case invalidAnchor(String)
     case git(GitError)
 
     public var code: String {
@@ -57,6 +62,11 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .ghFailed: "gh_failed"
         case .portNotFound: "port_not_found"
         case .portInOtherRow: "port_in_other_row"
+        case .invalidGroupName: "invalid_group_name"
+        case .groupExists: "group_exists"
+        case .groupNotFound: "group_not_found"
+        case .cannotMoveMain: "cannot_move_main"
+        case .invalidAnchor: "invalid_anchor"
         case .git: "git_failed"
         }
     }
@@ -95,6 +105,12 @@ public enum WorkspaceError: Error, Sendable, Equatable {
             "No row's process listens on port \(port). Run `canopy ports --all`; Canopy only stops its rows' ports."
         case .portInOtherRow(let port, let row):
             "Port \(port) belongs to \(row), not to this row. Pass --row \(row), or --all to stop it anywhere."
+        case .invalidGroupName: "A group name cannot be empty or hold control characters such as a newline."
+        case .groupExists(let name, let repo): "\(repo) already has a group named \(name)."
+        case .groupNotFound(let name, let repo): "\(repo) has no group named \"\(name)\". Run `canopy group list`."
+        case .cannotMoveMain: "The main checkout always comes first and cannot join a group."
+        case .invalidAnchor(let name):
+            "--before and --after take another Canopy or adopted row of the same repo, and \(name) is not one."
         case .git(let error): error.description
         }
     }
```

- [ ] **Step 4: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 334 tests in 47 suites passed`, no lint findings, and no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests scripts
git commit -m "feat: group rules on the repo entry"
```

## Task 2: Groups in the workspace

**Files:** Create `Sources/CanopyCore/Workspace/Workspace+Groups.swift`.
Modify `Row.swift`, `WorkspaceSnapshot.swift`, `Workspace.swift`, `ActivityEvent.swift`, `ActivityReader.swift`.
Delete `RowOrdering.swift` and its tests in `RowModelTests.swift`.
Test `Tests/CanopyCoreTests/WorkspaceGroupTests.swift`, `ActivityReaderTests.swift`.

**Interfaces:**
- Consumes Task 1.
- Produces `Row.group: String?`, encoded as `"group"` and left out when nil.
- Produces `GroupSnapshot` (`name`, `collapsed`), `RepoSnapshot.groups`, `RepoSnapshot.arranged(by: RepoEntry) -> RepoSnapshot`, `RepoSnapshot.rows(inGroup:) -> [Row]`, `RepoSnapshot.visibleRows`, and `WorkspaceSnapshot.visibleRows` now skipping collapsed groups.
- Produces `WorkspaceSnapshot.steppingRow(from: String?, offset: Int) -> Row?` for `↑` and `↓`.
- Produces `GroupInfo` (`repo`, `repoPath`, `name`, `collapsed`, `rows: [Row]`) with `init(repo: RepoSnapshot, group: GroupSnapshot)`.
- Produces on `Workspace`: `createGroup(repoPath:name:) throws -> GroupInfo`, `renameGroup(repoPath:name:to:) throws -> GroupInfo`, `removeGroup(repoPath:name:) throws -> GroupInfo`, `setGroupCollapsed(repoPath:name:collapsed:) throws`, `moveRow(path:to:) throws -> MovedRow` (`row: Row`, `moved: Bool`, `from: String?`), `revealRow(path:) throws`, and `groups(repoPath:) -> [GroupInfo]`.
- Produces `RepoEntry.forget(_:)` and `RepoEntry.place(_:joining:)`, which `unadopt`, `removeRow`, and row creation use.
- Produces `ActivityType.groupCreated`, `.groupRenamed`, `.groupRemoved`, `.rowMoved`.

`RepoSnapshot.rows` keeps meaning the main row and every Canopy and adopted row, now in sidebar order: main, ungrouped, then each group's rows.
So counts, PR lookups, target resolution, and ports keep working unchanged, and the sidebar filters `rows` by `group`.
Group changes run no git, so each one mutates the entry, saves, rearranges the repo's snapshot from the rows git last gave, and publishes.

Tests:

- `newRowsJoinTheUngroupedRowsAndGroupsHoldTheirs`: snapshot order is main, ungrouped, then each group's rows, with `group` set on each.
- `groupsSurviveRelaunchAndBranchSwitches`: a row switched to another branch with plain git keeps its group, and a new `Workspace` on the same home shows the same arrangement.
- `rowsGoneFromGitLeaveTheirGroupButGroupsStay`: removing a grouped worktree with plain git empties its group, which stays.
- `aMissingRepoKeepsItsGroups`: a repo whose folder moved away lists its groups with no rows, and they come back with the folder.
- `unadoptingARowTakesItOutOfItsGroup`.
- `movingRowsFollowsTheRules`: every error code through `moveRow`, including `cannotMoveMain`, `notManaged` for an external row, and `invalidAnchor` for a row in another repo.
- `groupErrorsNameTheRepo`: `groupExists` and `groupNotFound` from each operation carry the repo's display name.
- `movesThatChangeNothingLogNothing` and `reordersLogNothing`, while a change of group logs `row.moved` with `from` and `to`, and its source.
- `groupEventsCarryTheRepo`: `group.created`, `group.renamed`, and `group.removed` with `repo`, `path`, `data`, and the source from `ActivitySource.current`, and a rename to the same name logs nothing.
- `arrangingPutsRowsInSidebarOrder`, including a row the entry does not place yet and a stale group name.
- `collapsedGroupsAreSkippedInTheVisibleOrder` across two repos.
- `steppingFromAHiddenRowContinuesFromItsGroup`: from a row in a collapsed group, `+1` is the first visible row after the group and `-1` the last visible row before it.
- `revealingARowUnfoldsItsGroupAndFoldingIsNotLogged`.
- In `ActivityReaderTests`: `groupEventsReadWell` for the four new lines of `canopy log` text.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ActivityReaderTests.swift`:

```diff
@@ -153,4 +153,17 @@ struct ActivityReaderTests {
                 ]) == #"row.new {"branch":"bad name"} failed: invalid_branch"#)
         #expect(ActivityEvent(date: date, type: "x", source: .ui).localTime == "2026-09-28 14:02:00")
     }
+
+    @Test func groupEventsReadWell() {
+        let summary = { (type: String, data: [String: JSONValue]) in
+            ActivityEvent(date: Self.date(28, 14, 2), type: type, source: .cli, data: data).summary
+        }
+
+        #expect(summary("group.created", ["name": "Review"]) == "Review")
+        #expect(summary("group.renamed", ["from": "Review", "to": "Code review"]) == "Review -> Code review")
+        #expect(summary("group.removed", ["name": "Review", "rows": 2]) == "Review, 2 rows")
+        #expect(summary("group.removed", ["name": "Later", "rows": 1]) == "Later, 1 row")
+        #expect(summary("row.moved", ["from": .null, "to": "Review"]) == "none -> Review")
+        #expect(summary("row.moved", ["from": "Review", "to": .null]) == "Review -> none")
+    }
 }
```

`Tests/CanopyCoreTests/RowModelTests.swift`:

```diff
@@ -51,16 +51,22 @@ struct RowClassifierTests {
 }
 
 struct RowOrderingTests {
+    func reconciled(_ order: [String], present: [String]) -> [String] {
+        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: order)
+        _ = entry.reconcile(present: present)
+        return entry.rowOrder
+    }
+
     @Test func keepsOrderAndAppendsNewRows() {
-        #expect(RowOrdering.reconcile(order: ["b", "a"], present: ["a", "b", "c"]) == ["b", "a", "c"])
+        #expect(reconciled(["b", "a"], present: ["a", "b", "c"]) == ["b", "a", "c"])
     }
 
     @Test func dropsRowsThatAreGone() {
-        #expect(RowOrdering.reconcile(order: ["a", "b"], present: ["b"]) == ["b"])
+        #expect(reconciled(["a", "b"], present: ["b"]) == ["b"])
     }
 
     @Test func removesDuplicates() {
-        #expect(RowOrdering.reconcile(order: ["a", "a"], present: ["a"]) == ["a"])
+        #expect(reconciled(["a", "a"], present: ["a"]) == ["a"])
     }
 }
```

`Tests/CanopyCoreTests/WorkspaceGroupTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

struct WorkspaceGroupTests {
    /// A workspace with the demo repo and a Canopy row for each branch. Returns the rows' paths by branch.
    func setUp(_ dir: TempDir, branches: [String] = []) async throws -> (Workspace, String, [String: String]) {
        let repo = try await Fixture.repo(in: dir)
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        var paths: [String: String] = [:]
        for branch in branches {
            paths[branch] = try await workspace.createRow(repoPath: repo, branch: branch).row.path
        }
        return (workspace, repo, paths)
    }

    func arrangement(_ workspace: Workspace) async -> [String] {
        await workspace.snapshot.repos.first?.rows.map { row in
            row.group.map { "\($0)/\(row.displayName)" } ?? row.displayName
        }
            ?? []
    }

    @Test func newRowsJoinTheUngroupedRowsAndGroupsHoldTheirs() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b", "feat/c"])

        let created = try await workspace.createGroup(repoPath: repo, name: " Review ")
        #expect(created == GroupInfo(repo: "demo", repoPath: repo, name: "Review", collapsed: false, rows: []))
        _ = try await workspace.moveRow(path: try #require(paths["feat/b"]), to: .group("review"))
        _ = try await workspace.moveRow(path: try #require(paths["feat/a"]), to: .group("Review"))
        _ = try await workspace.createRow(repoPath: repo, branch: "feat/d")

        #expect(await arrangement(workspace) == ["main", "feat/c", "feat/d", "Review/feat/b", "Review/feat/a"])
        #expect(await workspace.snapshot.repos.first?.groups == [GroupSnapshot(name: "Review", collapsed: false)])
        let groups = await workspace.groups(repoPath: repo)
        #expect(groups.map(\.name) == ["Review"])
        #expect(groups.first?.rows.map(\.branch) == ["feat/b", "feat/a"])
    }

    @Test func groupsSurviveRelaunchAndBranchSwitches() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        let path = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: path, to: .group("Review"))
        try await workspace.setGroupCollapsed(repoPath: repo, name: "review", collapsed: true)

        try await Fixture.git.run(["switch", "--quiet", "-c", "feat/renamed"], in: path)
        await workspace.refresh(repoPath: repo)
        #expect(await arrangement(workspace) == ["main", "feat/b", "Review/feat/renamed"])
        await workspace.stop()

        let relaunched = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
        try await relaunched.start()
        #expect(await arrangement(relaunched) == ["main", "feat/b", "Review/feat/renamed"])
        #expect(await relaunched.snapshot.repos.first?.groups == [GroupSnapshot(name: "Review", collapsed: true)])
    }

    @Test func rowsGoneFromGitLeaveTheirGroupButGroupsStay() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a"])
        let path = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: path, to: .group("Review"))

        try await Fixture.git.run(["worktree", "remove", path], in: repo)
        await workspace.refresh(repoPath: repo)

        #expect(await arrangement(workspace) == ["main"])
        #expect(await workspace.groups(repoPath: repo).map(\.name) == ["Review"])
        try await Fixture.git.run(["worktree", "add", "--quiet", path, "feat/a"], in: repo)
        await workspace.refresh(repoPath: repo)
        #expect(await arrangement(workspace) == ["main", "feat/a"])
    }

    @Test func aMissingRepoKeepsItsGroups() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: try #require(paths["feat/a"]), to: .group("Review"))

        try FileManager.default.moveItem(atPath: repo, toPath: dir.sub("moved"))
        await workspace.refresh(repoPath: repo)
        let missing = try #require(await workspace.snapshot.repo(path: repo))
        #expect(missing.isMissing && missing.rows.isEmpty)
        #expect(missing.groups == [GroupSnapshot(name: "Review", collapsed: false)])

        try FileManager.default.moveItem(atPath: dir.sub("moved"), toPath: repo)
        await workspace.refresh(repoPath: repo)
        #expect(await arrangement(workspace) == ["main", "Review/feat/a"])
    }

    @Test func unadoptingARowTakesItOutOfItsGroup() async throws {
        let dir = try TempDir()
        let (workspace, repo, _) = try await setUp(dir)
        let path = dir.sub("elsewhere")
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: path)
        await workspace.refresh(repoPath: repo)
        _ = try await workspace.adopt(path: path)
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: path, to: .group("Review"))
        #expect(await arrangement(workspace) == ["main", "Review/feat/other"])

        try await workspace.unadopt(path: path)
        #expect(await arrangement(workspace) == ["main"])

        _ = try await workspace.adopt(path: path)
        #expect(await arrangement(workspace) == ["main", "feat/other"])
    }

    @Test func movingRowsFollowsTheRules() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a"])
        let path = try #require(paths["feat/a"])
        try await Fixture.worktree(repo: repo, branch: "feat/other", at: dir.sub("elsewhere"))
        let otherRepo = try await Fixture.repo(in: dir, name: "other")
        try await workspace.addRepo(path: otherRepo)
        let otherRow = try await workspace.createRow(repoPath: otherRepo, branch: "feat/x").row.path

        await #expect(throws: WorkspaceError.cannotMoveMain) {
            try await workspace.moveRow(path: repo, to: .ungrouped)
        }
        await #expect(throws: WorkspaceError.notManaged(dir.sub("elsewhere"))) {
            try await workspace.moveRow(path: dir.sub("elsewhere"), to: .ungrouped)
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.moveRow(path: path, to: .group("Nope"))
        }
        await #expect(throws: WorkspaceError.invalidAnchor(otherRow)) {
            try await workspace.moveRow(path: path, to: .before(otherRow))
        }
        await #expect(throws: WorkspaceError.invalidAnchor(repo)) {
            try await workspace.moveRow(path: path, to: .after(repo))
        }
        await #expect(throws: WorkspaceError.rowNotFound(dir.sub("nowhere"))) {
            try await workspace.moveRow(path: dir.sub("nowhere"), to: .ungrouped)
        }
    }

    @Test func movesThatChangeNothingLogNothing() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        let a = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")

        let moved = try await ActivitySource.$current.withValue(.cli) {
            try await workspace.moveRow(path: a, to: .group("Review"))
        }
        let again = try await workspace.moveRow(path: a, to: .group("review"))
        let stayed = try await workspace.moveRow(path: try #require(paths["feat/b"]), to: .ungrouped)

        #expect(moved.moved && moved.row.group == "Review")
        #expect(!again.moved && again.row.group == "Review")
        #expect(!stayed.moved)
        let events = await logged(workspace, "row")
        #expect(events.map(\.type) == ["row.created", "row.created", "row.moved"])
        #expect(events.last?.data == ["from": .null, "to": "Review"])
        #expect(events.last?.source == .cli)
        #expect(events.last?.path == a && events.last?.row == "feat/a" && events.last?.repo == "demo")
    }

    @Test func reordersLogNothing() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b", "feat/c", "feat/d"])
        let path = { (branch: String) in try #require(paths[branch]) }
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: try path("feat/b"), to: .group("Review"))
        _ = try await workspace.moveRow(path: try path("feat/c"), to: .group("Review"))

        #expect(try await workspace.moveRow(path: try path("feat/c"), to: .before(try path("feat/b"))).moved)
        #expect(try await workspace.moveRow(path: try path("feat/d"), to: .before(try path("feat/a"))).moved)
        #expect(await arrangement(workspace) == ["main", "feat/d", "feat/a", "Review/feat/c", "Review/feat/b"])
        #expect(try await workspace.moveRow(path: try path("feat/a"), to: .after(try path("feat/c"))).moved)
        #expect(await arrangement(workspace) == ["main", "feat/d", "Review/feat/c", "Review/feat/a", "Review/feat/b"])
        #expect(try await workspace.moveRow(path: try path("feat/a"), to: .ungrouped).moved)

        let moves = await logged(workspace, "row").filter { $0.type == "row.moved" }
        #expect(moves.map(\.row) == ["feat/b", "feat/c", "feat/a", "feat/a"])
        #expect(
            moves.map(\.data) == [
                ["from": .null, "to": "Review"], ["from": .null, "to": "Review"], ["from": .null, "to": "Review"],
                ["from": "Review", "to": .null],
            ])
    }

    @Test func groupEventsCarryTheRepo() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        try await ActivitySource.$current.withValue(.cli) {
            try await workspace.createGroup(repoPath: repo, name: "Review")
        }
        _ = try await workspace.moveRow(path: try #require(paths["feat/a"]), to: .group("Review"))
        _ = try await workspace.moveRow(path: try #require(paths["feat/b"]), to: .group("Review"))
        let same = try await workspace.renameGroup(repoPath: repo, name: "review", to: "Review")
        let renamed = try await workspace.renameGroup(repoPath: repo, name: "review", to: "Code review")
        let removed = try await workspace.removeGroup(repoPath: repo, name: "CODE REVIEW")

        #expect(same.name == "Review")
        #expect(renamed.name == "Code review" && renamed.rows.map(\.branch) == ["feat/a", "feat/b"])
        #expect(removed.name == "Code review" && removed.rows.map(\.branch) == ["feat/a", "feat/b"])
        #expect(await arrangement(workspace) == ["main", "feat/a", "feat/b"])
        let events = await logged(workspace, "group")
        #expect(events.map(\.type) == ["group.created", "group.renamed", "group.removed"])
        #expect(
            events.map(\.data) == [
                ["name": "Review"], ["from": "Review", "to": "Code review"],
                [
                    "name": "Code review", "rows": 2,
                ],
            ])
        #expect(events.map(\.source) == [.cli, .ui, .ui])
        #expect(events.allSatisfy { $0.repo == "demo" && $0.path == repo && $0.row == nil })
        #expect(await logged(workspace, "row").filter { $0.type == "row.moved" }.count == 2)
    }

    @Test func groupErrorsNameTheRepo() async throws {
        let dir = try TempDir()
        let (workspace, repo, _) = try await setUp(dir)
        try await workspace.createGroup(repoPath: repo, name: "Review")

        await #expect(throws: WorkspaceError.groupExists("Review", repo: "demo")) {
            try await workspace.createGroup(repoPath: repo, name: "REVIEW")
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.removeGroup(repoPath: repo, name: "Nope")
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.renameGroup(repoPath: repo, name: "Nope", to: "Other")
        }
        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
            try await workspace.setGroupCollapsed(repoPath: repo, name: "Nope", collapsed: true)
        }
        await #expect(throws: WorkspaceError.repoNotFound(dir.sub("nope"))) {
            try await workspace.createGroup(repoPath: dir.sub("nope"), name: "Review")
        }
    }

    @Test func revealingARowUnfoldsItsGroupAndFoldingIsNotLogged() async throws {
        let dir = try TempDir()
        let (workspace, repo, paths) = try await setUp(dir, branches: ["feat/a", "feat/b"])
        let a = try #require(paths["feat/a"])
        try await workspace.createGroup(repoPath: repo, name: "Review")
        _ = try await workspace.moveRow(path: a, to: .group("Review"))
        try await workspace.setGroupCollapsed(repoPath: repo, name: "Review", collapsed: true)
        #expect(await workspace.snapshot.visibleRows.map(\.displayName) == ["main", "feat/b"])

        try await workspace.revealRow(path: try #require(paths["feat/b"]))
        #expect(await workspace.snapshot.repos.first?.groups.first?.collapsed == true)
        try await workspace.revealRow(path: a)
        #expect(await workspace.snapshot.repos.first?.groups.first?.collapsed == false)
        #expect(await workspace.snapshot.visibleRows.map(\.displayName) == ["main", "feat/b", "feat/a"])

        let events = await logged(workspace, "group", "row").map(\.type)
        #expect(events == ["row.created", "row.created", "group.created", "row.moved"])
    }
}

/// The sidebar order and keyboard stepping, on snapshots built by hand.
struct GroupSnapshotTests {
    static func row(_ repo: String, _ name: String, group: String? = nil, main: Bool = false) -> Row {
        var row = Row(
            repoPath: "/\(repo)", path: main ? "/\(repo)" : "/\(repo)/\(name)", branch: name, head: nil,
            rowClass: main ? .main : .canopy)
        row.group = group
        return row
    }

    /// web: main, a, then Review (b, c) collapsed and Later (d). api: main, e, then Hidden (f) collapsed.
    static let snapshot = WorkspaceSnapshot(repos: [
        RepoSnapshot(
            path: "/web", name: "web",
            rows: [
                row("web", "main", main: true), row("web", "a"), row("web", "b", group: "Review"),
                row("web", "c", group: "Review"), row("web", "d", group: "Later"),
            ],
            groups: [GroupSnapshot(name: "Review", collapsed: true), GroupSnapshot(name: "Later", collapsed: false)]),
        RepoSnapshot(
            path: "/api", name: "api",
            rows: [row("api", "main", main: true), row("api", "e"), row("api", "f", group: "Hidden")],
            groups: [GroupSnapshot(name: "Hidden", collapsed: true)]),
    ])

    @Test func arrangingPutsRowsInSidebarOrder() {
        var entry = RepoEntry(path: "/web", dirName: "web", rowOrder: ["/web/a"])
        entry.groups = [RowGroup(name: "Review", rows: ["/web/c", "/web/b"], collapsed: true)]
        let raw = RepoSnapshot(
            path: "/web", name: "web",
            rows: [
                Self.row("web", "b", group: "Stale"), Self.row("web", "main", main: true), Self.row("web", "c"),
                Self.row("web", "new"), Self.row("web", "a"),
            ])

        let arranged = raw.arranged(by: entry)

        #expect(arranged.rows.map(\.displayName) == ["main", "a", "new", "c", "b"])
        #expect(arranged.rows.map(\.group) == [nil, nil, nil, "Review", "Review"])
        #expect(arranged.groups == [GroupSnapshot(name: "Review", collapsed: true)])
        #expect(arranged.rows(inGroup: "Review").map(\.displayName) == ["c", "b"])
    }

    @Test func collapsedGroupsAreSkippedInTheVisibleOrder() {
        #expect(Self.snapshot.visibleRows.map(\.path) == ["/web", "/web/a", "/web/d", "/api", "/api/e"])
        #expect(Self.snapshot.repos[0].visibleRows.map(\.displayName) == ["main", "a", "d"])
    }

    @Test func steppingFromAHiddenRowContinuesFromItsGroup() {
        let snapshot = Self.snapshot

        #expect(snapshot.steppingRow(from: "/web/b", offset: 1)?.path == "/web/d")
        #expect(snapshot.steppingRow(from: "/web/c", offset: -1)?.path == "/web/a")
        #expect(snapshot.steppingRow(from: "/api/f", offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/api/f", offset: 1) == nil)
        #expect(snapshot.steppingRow(from: "/web/a", offset: 1)?.path == "/web/d")
        #expect(snapshot.steppingRow(from: "/web/d", offset: -1)?.path == "/web/a")
        #expect(snapshot.steppingRow(from: "/api/e", offset: 1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/web", offset: -1)?.path == "/web")
        #expect(snapshot.steppingRow(from: nil, offset: 1)?.path == "/web")
        #expect(snapshot.steppingRow(from: nil, offset: -1)?.path == "/api/e")
        #expect(snapshot.steppingRow(from: "/elsewhere", offset: 1)?.path == "/web")
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'GroupSnapshot' in scope` and `value of type 'Row' has no member 'group'`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Activity/ActivityEvent.swift`:

```diff
@@ -20,6 +20,10 @@ public enum ActivityType {
     public static let rowAdopted = "row.adopted"
     public static let rowRemoved = "row.removed"
     public static let rowBranchChanged = "row.branch_changed"
+    public static let rowMoved = "row.moved"
+    public static let groupCreated = "group.created"
+    public static let groupRenamed = "group.renamed"
+    public static let groupRemoved = "group.removed"
     public static let prOpened = "pr.opened"
     public static let prStateChanged = "pr.state_changed"
     public static let termOpened = "term.opened"
```

`Sources/CanopyCore/Activity/ActivityReader.swift`:

```diff
@@ -137,6 +137,15 @@ extension ActivityEvent {
             return text("class") ?? ""
         case ActivityType.rowBranchChanged:
             return "\(text("from") ?? "detached") -> \(text("to") ?? "detached")"
+        case ActivityType.rowMoved:
+            return "\(text("from") ?? "none") -> \(text("to") ?? "none")"
+        case ActivityType.groupCreated:
+            return text("name") ?? ""
+        case ActivityType.groupRenamed:
+            return "\(text("from") ?? "") -> \(text("to") ?? "")"
+        case ActivityType.groupRemoved:
+            let rows = number("rows") ?? 0
+            return "\(text("name") ?? ""), \(rows) \(rows == 1 ? "row" : "rows")"
         case ActivityType.prOpened:
             return "#\(number("number") ?? 0) \(text("state") ?? ""): \(text("title") ?? "") \(text("url") ?? "")"
         case ActivityType.prStateChanged:
```

`Sources/CanopyCore/Rows/Row.swift`:

```diff
@@ -29,6 +29,8 @@ public struct Row: Sendable, Equatable, Identifiable, Codable {
     public var isMissing: Bool
     /// Looked up only for Canopy and adopted rows on a branch.
     public var pullRequest: PullRequest?
+    /// The name of the group holding the row, nil while it is ungrouped.
+    public var group: String?
 
     public var id: String { path }
 
@@ -62,5 +64,6 @@ public struct Row: Sendable, Equatable, Identifiable, Codable {
         case externalTag = "tag"
         case isMissing = "missing"
         case pullRequest = "pr"
+        case group
     }
 }
```

`Sources/CanopyCore/Rows/RowGroups.swift`:

```diff
@@ -93,7 +93,7 @@ extension RepoEntry {
     mutating func move(_ path: String, to placement: RowPlacement, repo: String) throws -> Bool {
         guard holds(path) else { throw WorkspaceError.rowNotFound(path) }
         var moved = self
-        moved.take(path)
+        moved.forget(path)
         switch placement {
         case .group(let name):
             let index = try requireGroup(name, repo: repo)
@@ -161,7 +161,8 @@ extension RepoEntry {
         return index
     }
 
-    private mutating func take(_ path: String) {
+    /// Takes a row out of whichever list holds it.
+    mutating func forget(_ path: String) {
         rowOrder.removeAll { $0 == path }
         for index in groups.indices {
             groups[index].rows.removeAll { $0 == path }
```

Delete `Sources/CanopyCore/Rows/RowOrdering.swift`.

`Sources/CanopyCore/Workspace/Workspace+Groups.swift` (new):

```swift
import Foundation

/// A group with its rows, as `canopy group` prints it.
public struct GroupInfo: Codable, Sendable, Equatable {
    public var repo: String
    public var repoPath: String
    public var name: String
    public var collapsed: Bool
    public var rows: [Row]

    public init(repo: String, repoPath: String, name: String, collapsed: Bool, rows: [Row]) {
        self.repo = repo
        self.repoPath = repoPath
        self.name = name
        self.collapsed = collapsed
        self.rows = rows
    }

    public init(repo: RepoSnapshot, group: GroupSnapshot) {
        self.init(
            repo: repo.name, repoPath: repo.path, name: group.name, collapsed: group.collapsed,
            rows: repo.rows(inGroup: group.name))
    }
}

public struct MovedRow: Sendable, Equatable {
    public var row: Row
    /// False when the row was already where it was asked to go.
    public var moved: Bool
}

/// Groups only arrange the sidebar, so changing them runs no git: each change edits the repo's entry, saves it, and
/// rearranges the rows git last listed.
extension Workspace {
    public func groups(repoPath: String) -> [GroupInfo] {
        guard let repo = snapshot.repo(path: repoPath) else { return [] }
        return repo.groups.map { GroupInfo(repo: repo, group: $0) }
    }

    @discardableResult
    public func createGroup(repoPath: String, name: String) throws -> GroupInfo {
        let created = try changeEntry(repoPath: repoPath) { entry, repo in try entry.addGroup(name, repo: repo) }
        recordGroup(ActivityType.groupCreated, repoPath: repoPath, data: ["name": .string(created.name)])
        return try groupInfo(repoPath: repoPath, name: created.name)
    }

    @discardableResult
    public func renameGroup(repoPath: String, name: String, to newName: String) throws -> GroupInfo {
        let (from, to) = try changeEntry(repoPath: repoPath) { entry, repo in
            let from = entry.groupIndex(named: name).map { entry.groups[$0].name }
            return (from, try entry.renameGroup(name, to: newName, repo: repo).name)
        }
        if let from, from != to {
            recordGroup(
                ActivityType.groupRenamed, repoPath: repoPath, data: ["from": .string(from), "to": .string(to)])
        }
        return try groupInfo(repoPath: repoPath, name: to)
    }

    /// Deletes a group, moving its rows to the end of the ungrouped rows. Returns the group as it was.
    @discardableResult
    public func removeGroup(repoPath: String, name: String) throws -> GroupInfo {
        let removed = try groupInfo(repoPath: repoPath, name: name)
        try changeEntry(repoPath: repoPath) { entry, repo in _ = try entry.removeGroup(name, repo: repo) }
        recordGroup(
            ActivityType.groupRemoved, repoPath: repoPath,
            data: ["name": .string(removed.name), "rows": .number(Double(removed.rows.count))])
        return removed
    }

    /// Folding is how the sidebar looks, so it is saved but not logged.
    public func setGroupCollapsed(repoPath: String, name: String, collapsed: Bool) throws {
        try changeEntry(repoPath: repoPath) { entry, repo in
            guard let index = entry.groupIndex(named: name) else {
                throw WorkspaceError.groupNotFound(name.trimmingCharacters(in: .whitespacesAndNewlines), repo: repo)
            }
            entry.groups[index].collapsed = collapsed
        }
    }

    /// Unfolds the group holding a row, so selecting the row shows it.
    public func revealRow(path: String) throws {
        guard let row = snapshot.row(path: path), let group = row.group,
            snapshot.repo(path: row.repoPath)?.groups.first(where: { $0.name == group })?.collapsed == true
        else { return }
        try setGroupCollapsed(repoPath: row.repoPath, name: group, collapsed: false)
    }

    /// Moves a Canopy or adopted row within its repo. Only a change of group is logged, as `row.moved`.
    public func moveRow(path: String, to placement: RowPlacement) throws -> MovedRow {
        guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
        switch row.rowClass {
        case .main: throw WorkspaceError.cannotMoveMain
        case .external: throw WorkspaceError.notManaged(path)
        case .canopy, .adopted: break
        }
        let from = row.group
        let moved = try changeEntry(repoPath: row.repoPath) { entry, repo in
            try entry.move(path, to: placement, repo: repo)
        }
        let current = snapshot.row(path: path) ?? row
        if current.group != from {
            record(
                ActivityType.rowMoved, current,
                data: ["from": from.map(JSONValue.string) ?? .null, "to": current.group.map(JSONValue.string) ?? .null])
        }
        return MovedRow(row: current, moved: moved)
    }

    /// Applies `change` to the repo's entry, and saves and republishes it if the entry changed.
    @discardableResult
    func changeEntry<T>(repoPath: String, _ change: (inout RepoEntry, String) throws -> T) throws -> T {
        let index = try entryIndex(repoPath: repoPath)
        var entry = state.repos[index]
        let result = try change(&entry, snapshot.repo(path: repoPath)?.name ?? entry.dirName)
        guard entry != state.repos[index] else { return result }
        state.repos[index] = entry
        try save()
        rearrange(repoPath: repoPath)
        publish()
        return result
    }

    func rearrange(repoPath: String) {
        guard let entry = state.repos.first(where: { $0.path == repoPath }), let repo = repoSnapshots[repoPath] else {
            return
        }
        repoSnapshots[repoPath] = repo.arranged(by: entry)
    }

    private func groupInfo(repoPath: String, name: String) throws -> GroupInfo {
        let repoName = snapshot.repo(path: repoPath)?.name ?? ""
        guard let repo = snapshot.repo(path: repoPath) else { throw WorkspaceError.repoNotFound(repoPath) }
        let key = GroupName.key(name)
        guard let group = repo.groups.first(where: { $0.id == key }) else {
            throw WorkspaceError.groupNotFound(name.trimmingCharacters(in: .whitespacesAndNewlines), repo: repoName)
        }
        return GroupInfo(repo: repo, group: group)
    }

    private func recordGroup(_ type: String, repoPath: String, data: [String: JSONValue]) {
        activity.record(type, repo: snapshot.repo(path: repoPath)?.name, path: repoPath, data: data)
    }
}
```

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`:

```diff
@@ -105,7 +105,7 @@ extension Workspace {
             warnings.append("git worktree add reported an error, but the worktree was created: \(error)")
         }
 
-        if let current = try? entryIndex(repoPath: repoPath), !state.repos[current].rowOrder.contains(path) {
+        if let current = try? entryIndex(repoPath: repoPath), !state.repos[current].holds(path) {
             state.repos[current].rowOrder.append(path)
             try save()
         }
@@ -141,7 +141,7 @@ extension Workspace {
                 throw WorkspaceError.git(error)
             }
             if let index = try? entryIndex(repoPath: row.repoPath) {
-                state.repos[index].rowOrder.removeAll { $0 == path }
+                state.repos[index].forget(path)
             }
             if state.selectedRowPath == path {
                 state.selectedRowPath = nil
```

`Sources/CanopyCore/Workspace/Workspace.swift`:

```diff
@@ -208,7 +208,7 @@ public actor Workspace {
         }
         let row = snapshot.row(path: path)
         state.repos[index].adopted.removeAll { $0 == path }
-        state.repos[index].rowOrder.removeAll { $0 == path }
+        state.repos[index].forget(path)
         if state.selectedRowPath == path {
             state.selectedRowPath = nil
         }
@@ -298,7 +298,7 @@ public actor Workspace {
     private func refreshNow(repoPath: String) async {
         guard let entry = state.repos.first(where: { $0.path == repoPath }) else { return }
         guard FileManager.default.fileExists(atPath: entry.path) else {
-            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", isMissing: true)
+            repoSnapshots[entry.path] = RepoSnapshot(path: entry.path, name: "", isMissing: true).arranged(by: entry)
             publish()
             return
         }
@@ -320,7 +320,8 @@ public actor Workspace {
         let worktrees = WorktreeListParser.parse(output)
         // git follows a folder that moves after it started in it, and reports where the folder went.
         guard worktrees.first.map({ Paths.canonical($0.path) }) == current.path else {
-            repoSnapshots[current.path] = RepoSnapshot(path: current.path, name: "", isMissing: true)
+            repoSnapshots[current.path] = RepoSnapshot(path: current.path, name: "", isMissing: true).arranged(
+                by: current)
             publish()
             return
         }
@@ -332,18 +333,17 @@ public actor Workspace {
         )
         recordRowChanges(repoPath: current.path, rows: rows)
         let managed = rows.filter { $0.rowClass == .canopy || $0.rowClass == .adopted }
-        let order = RowOrdering.reconcile(order: current.rowOrder, present: managed.map(\.path))
-        if order != current.rowOrder {
-            state.repos[index].rowOrder = order
+        var reconciled = current
+        if reconciled.reconcile(present: managed.map(\.path)) {
+            state.repos[index] = reconciled
             try? save()
         }
-        let managedByPath = Dictionary(managed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
         repoSnapshots[current.path] = RepoSnapshot(
             path: current.path,
             name: "",
-            rows: rows.filter { $0.rowClass == .main } + order.compactMap { managedByPath[$0] },
+            rows: rows.filter { $0.rowClass != .external },
             external: rows.filter { $0.rowClass == .external }
-        )
+        ).arranged(by: reconciled)
         publish()
         if prBranchesRequested[current.path] != pullRequestBranches(repoPath: current.path) {
             _ = queuePullRequestRefresh(repoPath: current.path)
```

`Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift`:

```diff
@@ -1,8 +1,22 @@
+public struct GroupSnapshot: Sendable, Equatable, Identifiable {
+    public var name: String
+    public var collapsed: Bool
+
+    public init(name: String, collapsed: Bool) {
+        self.name = name
+        self.collapsed = collapsed
+    }
+
+    public var id: String { GroupName.key(name) }
+}
+
 public struct RepoSnapshot: Sendable, Equatable, Identifiable {
     public var path: String
     public var name: String
-    /// The main row first, then Canopy and adopted rows in saved order.
+    /// The main row, then the Canopy and adopted rows in sidebar order: the ungrouped ones, then each group's.
     public var rows: [Row]
+    /// The repo's groups in sidebar order, empty ones included. Each row names its group.
+    public var groups: [GroupSnapshot]
     /// Worktrees made by other tools, shown collapsed.
     public var external: [Row]
     public var isMissing: Bool
@@ -16,6 +30,7 @@ public struct RepoSnapshot: Sendable, Equatable, Identifiable {
         path: String,
         name: String,
         rows: [Row] = [],
+        groups: [GroupSnapshot] = [],
         external: [Row] = [],
         isMissing: Bool = false,
         error: String? = nil
@@ -23,12 +38,43 @@ public struct RepoSnapshot: Sendable, Equatable, Identifiable {
         self.path = path
         self.name = name
         self.rows = rows
+        self.groups = groups
         self.external = external
         self.isMissing = isMissing
         self.error = error
     }
 
     public var allRows: [Row] { rows + external }
+
+    public func rows(inGroup name: String) -> [Row] {
+        rows.filter { $0.group == name }
+    }
+
+    /// The rows the sidebar shows: all but those in collapsed groups and other tools' worktrees.
+    public var visibleRows: [Row] {
+        let collapsed = Set(groups.filter(\.collapsed).map(\.name))
+        return rows.filter { $0.group.map { !collapsed.contains($0) } ?? true }
+    }
+
+    /// The same rows in sidebar order for `entry`: the main row, the ungrouped rows, then each group's rows, each
+    /// row naming its group. A row the entry does not place yet stays among the ungrouped rows.
+    public func arranged(by entry: RepoEntry) -> RepoSnapshot {
+        var unplaced = Dictionary(
+            rows.filter { $0.rowClass != .main }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
+        func take(_ path: String, into group: String?) -> Row? {
+            guard var row = unplaced.removeValue(forKey: path) else { return nil }
+            row.group = group
+            return row
+        }
+        var ordered = rows.filter { $0.rowClass == .main }
+        ordered += entry.rowOrder.compactMap { take($0, into: nil) }
+        let grouped = entry.groups.flatMap { group in group.rows.compactMap { take($0, into: group.name) } }
+        ordered += rows.compactMap { take($0.path, into: nil) }
+        var arranged = self
+        arranged.rows = ordered + grouped
+        arranged.groups = entry.groups.map { GroupSnapshot(name: $0.name, collapsed: $0.collapsed) }
+        return arranged
+    }
 }
 
 public struct WorkspaceSnapshot: Sendable, Equatable {
@@ -40,8 +86,30 @@ public struct WorkspaceSnapshot: Sendable, Equatable {
         self.selectedRowPath = selectedRowPath
     }
 
-    /// Rows that get ⌘1 to ⌘9, in sidebar order. External rows are excluded.
-    public var visibleRows: [Row] { repos.flatMap(\.rows) }
+    /// Rows that get ⌘1 to ⌘9, in sidebar order. Rows in collapsed groups and external rows are excluded.
+    public var visibleRows: [Row] { repos.flatMap(\.visibleRows) }
+
+    /// The row `↑` or `↓` picks. From a row hidden in a collapsed group, the next visible row after the group or the
+    /// last before it, and nil if there is none. From no row, or one the sidebar does not step through, the first
+    /// or the last.
+    public func steppingRow(from path: String?, offset: Int) -> Row? {
+        let visible = visibleRows
+        guard !visible.isEmpty else { return nil }
+        let all = repos.flatMap(\.rows)
+        guard let path, let position = all.firstIndex(where: { $0.path == path }) else {
+            return offset > 0 ? visible.first : visible.last
+        }
+        if let index = visible.firstIndex(where: { $0.path == path }) {
+            return visible[min(max(index + offset, 0), visible.count - 1)]
+        }
+        let shown = Set(visible.map(\.path))
+        if offset > 0 {
+            let after = all[(position + 1)...].filter { shown.contains($0.path) }
+            return after.isEmpty ? nil : after[min(offset - 1, after.count - 1)]
+        }
+        let before = all[..<position].filter { shown.contains($0.path) }
+        return before.isEmpty ? nil : before[max(before.count + offset, 0)]
+    }
 
     public func row(path: String) -> Row? {
         repos.lazy.flatMap(\.allRows).first { $0.path == path }
```

- [ ] **Step 4: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 349 tests in 49 suites passed`, no lint findings, and no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests scripts
git commit -m "feat: groups in the workspace"
```

## Task 3: Creating a row into a group

**Files:** Modify `Workspace+RowLifecycle.swift`, `Workspace.swift`.
Test `WorkspaceGroupTests.swift`.

**Interfaces:**
- Consumes Tasks 1 and 2.
- Produces `Workspace.createRow(repoPath:branch:base:group:)`, where `group` defaults to nil.

The group is looked up inside the repo's git queue before any git runs, so a missing group creates nothing.
Its path goes into `rowsJoiningGroups` before `git worktree add`, so a refresh that lists the half-made worktree reconciles it straight into the group.
Once `createRowNow` has returned, which logged `row.created`, `createRow` removes the path from `rowsJoiningGroups` and logs `row.moved` from null to the group.
If the group went away meanwhile, the row is ungrouped and `CreatedRow.warnings` says so.

Tests:

- `aRowCreatedIntoAGroupNeverShowsUngrouped`: a git wrapper stalls `worktree add` until the test has refreshed the repo, no snapshot a subscriber sees shows the row ungrouped, and the log reads `row.created` then `row.moved`.
  Dropping the `joining:` argument from the refresh makes it fail, which was checked.
- `aMissingGroupCreatesNothing`: `groupNotFound`, and no worktree folder, branch, or event.
- `aGroupDeletedWhileItsRowIsCreatedLeavesTheRowUngrouped`: the stalled git lets the test delete the group, and the row ends up ungrouped with a warning.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/WorkspaceGroupTests.swift`:

```diff
@@ -259,6 +259,92 @@ struct WorkspaceGroupTests {
     }
 }
 
+struct GroupRowCreationTests {
+    /// A workspace whose `git worktree add` waits, once the worktree exists, until the test creates `go`.
+    func stalledSetUp(_ dir: TempDir) async throws -> (Workspace, String) {
+        let repo = try await Fixture.repo(in: dir)
+        let git = try Fixture.git(
+            in: dir,
+            before: """
+                if [ "$1" = worktree ] && [ "$2" = add ]; then
+                    /usr/bin/git "$@"; code=$?
+                    touch '\(dir.sub("added"))'
+                    while [ ! -e '\(dir.sub("go"))' ]; do sleep 0.05; done
+                    exit $code
+                fi
+                """)
+        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git)
+        try await workspace.start()
+        try await workspace.addRepo(path: repo)
+        try await workspace.createGroup(repoPath: repo, name: "Review")
+        return (workspace, repo)
+    }
+
+    @Test func aRowCreatedIntoAGroupNeverShowsUngrouped() async throws {
+        let dir = try TempDir()
+        let (workspace, repo) = try await stalledSetUp(dir)
+        let path = dir.sub("home/worktrees/demo/feat-a")
+        let updates = await workspace.updates()
+        let watcher = Task {
+            var groups: [String?] = []
+            for await snapshot in updates {
+                if let row = snapshot.row(path: path) { groups.append(row.group) }
+                if groups.count > 0, FileManager.default.fileExists(atPath: dir.sub("done")) { break }
+            }
+            return groups
+        }
+
+        let creating = Task { try await workspace.createRow(repoPath: repo, branch: "feat/a", group: "review") }
+        #expect(await eventually { FileManager.default.fileExists(atPath: dir.sub("added")) })
+        await workspace.refresh(repoPath: repo)
+        #expect(await workspace.snapshot.row(path: path)?.group == "Review")
+        FileManager.default.createFile(atPath: dir.sub("go"), contents: nil)
+        let created = try await creating.value
+        FileManager.default.createFile(atPath: dir.sub("done"), contents: nil)
+        try await workspace.setGroupCollapsed(repoPath: repo, name: "Review", collapsed: true)
+
+        #expect(created.row.group == "Review" && created.warnings.isEmpty)
+        let seen = await watcher.value
+        #expect(!seen.isEmpty && seen.allSatisfy { $0 == "Review" })
+        let events = await logged(workspace, "row")
+        #expect(events.map(\.type) == ["row.created", "row.moved"])
+        #expect(events.last?.data == ["from": .null, "to": "Review"])
+    }
+
+    @Test func aGroupDeletedWhileItsRowIsCreatedLeavesTheRowUngrouped() async throws {
+        let dir = try TempDir()
+        let (workspace, repo) = try await stalledSetUp(dir)
+
+        let creating = Task { try await workspace.createRow(repoPath: repo, branch: "feat/a", group: "Review") }
+        #expect(await eventually { FileManager.default.fileExists(atPath: dir.sub("added")) })
+        try await workspace.removeGroup(repoPath: repo, name: "Review")
+        FileManager.default.createFile(atPath: dir.sub("go"), contents: nil)
+        let created = try await creating.value
+
+        #expect(created.row.group == nil)
+        #expect(
+            created.warnings == ["Group Review went away while the row was being created, so the row is ungrouped."])
+        #expect(await workspace.snapshot.repos.first?.rows.map(\.displayName) == ["main", "feat/a"])
+        #expect(await logged(workspace, "row").map(\.type) == ["row.created"])
+    }
+
+    @Test func aMissingGroupCreatesNothing() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
+        try await workspace.start()
+        try await workspace.addRepo(path: repo)
+
+        await #expect(throws: WorkspaceError.groupNotFound("Nope", repo: "demo")) {
+            try await workspace.createRow(repoPath: repo, branch: "feat/a", group: " Nope ")
+        }
+
+        #expect(!FileManager.default.fileExists(atPath: dir.sub("home/worktrees/demo/feat-a")))
+        #expect(!(await Fixture.git.succeeds(["show-ref", "--verify", "--quiet", "refs/heads/feat/a"], in: repo)))
+        #expect(await logged(workspace, "row").isEmpty)
+    }
+}
+
 /// The sidebar order and keyboard stepping, on snapshots built by hand.
 struct GroupSnapshotTests {
     static func row(_ repo: String, _ name: String, group: String? = nil, main: Bool = false) -> Row {
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: the build fails with `extra argument 'group' in call`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Rows/RowGroups.swift`:

```diff
@@ -130,15 +130,22 @@ extension RepoEntry {
         }
         rowOrder = rowOrder.filter { isPresent.contains($0) && placed.insert($0).inserted }
         for path in present where placed.insert(path).inserted {
-            if let name = joining[path], let index = groupIndex(named: name) {
-                groups[index].rows.append(path)
-            } else {
-                rowOrder.append(path)
-            }
+            place(path, joining: joining[path])
         }
         return self != original
     }
 
+    /// Puts a row the entry does not hold yet at the end of its group, or of the ungrouped rows if it has none or the
+    /// group is gone.
+    mutating func place(_ path: String, joining group: String?) {
+        guard !holds(path) else { return }
+        if let group, let index = groupIndex(named: group) {
+            groups[index].rows.append(path)
+        } else {
+            rowOrder.append(path)
+        }
+    }
+
     /// Makes groups read from a file follow the rules: valid names unique ignoring case, and each path in one place,
     /// the first group that lists it.
     mutating func cleanGroups() {
```

`Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`:

```diff
@@ -14,11 +14,26 @@ extension Workspace {
     /// Creates a worktree for `branch` under CANOPY_HOME/worktrees/<repo>/.
     /// An existing local branch is checked out, a branch only on origin is tracked,
     /// and anything else is created from `base` (default: origin's default branch).
-    public func createRow(repoPath: String, branch: String, base: String? = nil) async throws -> CreatedRow {
+    /// With `group`, the row goes straight to the end of that group, which must exist.
+    public func createRow(
+        repoPath: String, branch: String, base: String? = nil, group: String? = nil
+    ) async throws -> CreatedRow {
         let requestedAt = ContinuousClock.now
-        return try await serialized(repoPath: repoPath) {
-            try await self.createRowNow(repoPath: repoPath, branch: branch, base: base, requestedAt: requestedAt)
+        var created = try await serialized(repoPath: repoPath) {
+            try await self.createRowNow(
+                repoPath: repoPath, branch: branch, base: base, group: group, requestedAt: requestedAt)
+        }
+        // After createRowNow, which logged the row's creation, so its move into the group is logged second.
+        if let group = rowsJoiningGroups.removeValue(forKey: created.row.path) {
+            created.row = snapshot.row(path: created.row.path) ?? created.row
+            if let joined = created.row.group {
+                record(ActivityType.rowMoved, created.row, data: ["from": .null, "to": .string(joined)])
+            } else {
+                created.warnings.append(
+                    "Group \(group) went away while the row was being created, so the row is ungrouped.")
+            }
         }
+        return created
     }
 
     /// Removes a Canopy row's worktree, or un-adopts an adopted row without touching its files.
@@ -35,11 +50,20 @@ extension Workspace {
         repoPath: String,
         branch: String,
         base: String?,
+        group: String?,
         requestedAt: ContinuousClock.Instant
     ) async throws -> CreatedRow {
         let index = try entryIndex(repoPath: repoPath)
         let dirName = state.repos[index].dirName
         var warnings: [String] = []
+        let joining = try group.map { name in
+            guard let groupIndex = state.repos[index].groupIndex(named: name) else {
+                throw WorkspaceError.groupNotFound(
+                    name.trimmingCharacters(in: .whitespacesAndNewlines),
+                    repo: snapshot.repo(path: repoPath)?.name ?? dirName)
+            }
+            return state.repos[index].groups[groupIndex].name
+        }
 
         guard FileManager.default.fileExists(atPath: repoPath) else {
             throw WorkspaceError.pathNotFound(repoPath)
@@ -91,6 +115,10 @@ extension Workspace {
         }
 
         let path = Paths.canonical(folder.path)
+        rowsJoiningGroups[path] = joining
+        // `createRow` takes the path back out once it has logged the move, unless creating the row fails.
+        var created = false
+        defer { if !created { rowsJoiningGroups[path] = nil } }
         changingRows[path] = .current
         defer { finishChanging([path], repoPath: repoPath) }
         do {
@@ -106,11 +134,12 @@ extension Workspace {
         }
 
         if let current = try? entryIndex(repoPath: repoPath), !state.repos[current].holds(path) {
-            state.repos[current].rowOrder.append(path)
+            state.repos[current].place(path, joining: joining)
             try save()
         }
         await refresh(repoPath: repoPath)
         guard let row = snapshot.row(path: path) else { throw WorkspaceError.rowNotFound(path) }
+        created = true
         return CreatedRow(row: row, warnings: warnings)
     }
```

`Sources/CanopyCore/Workspace/Workspace.swift`:

```diff
@@ -24,6 +24,9 @@ public actor Workspace {
     /// Rows Canopy is creating, removing, or pruning, with who asked. git can list a row halfway through a change, so
     /// refreshes leave these out of the comparison, and the operation logs how each one ended up.
     var changingRows: [String: ActivitySource] = [:]
+    /// Rows being created into a group, by path, so a refresh that lists one before its creation finishes puts it
+    /// straight into the group.
+    var rowsJoiningGroups: [String: String] = [:]
 
     let github: GitHubCLI
     let prTiming: PRTiming
@@ -334,7 +337,7 @@ public actor Workspace {
         recordRowChanges(repoPath: current.path, rows: rows)
         let managed = rows.filter { $0.rowClass == .canopy || $0.rowClass == .adopted }
         var reconciled = current
-        if reconciled.reconcile(present: managed.map(\.path)) {
+        if reconciled.reconcile(present: managed.map(\.path), joining: rowsJoiningGroups) {
             state.repos[index] = reconciled
             try? save()
         }
```

- [ ] **Step 4: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 352 tests in 50 suites passed`, no lint findings, and no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests scripts
git commit -m "feat: create a row straight into a group"
```

## Task 4: `canopy group` and `canopy row move`

**Files:** Create `Sources/CanopyCore/Control/GroupMethods.swift`, `Sources/CanopyCLI/GroupCommand.swift`.
Modify `ControlMethods.swift`, `WorkspaceControlHandler.swift`, `RowCommand.swift`, `AgentGuide.swift`, `CanopyCLI.swift`, `scripts/e2e.sh`.
Test `Tests/CanopyCoreTests/GroupControlTests.swift`.

**Interfaces:**
- Consumes Tasks 2 and 3.
- Produces `GroupMethod.list`, `.new`, `.rename`, `.remove`, and `ControlMethod.rowMove`.
- Produces `GroupListParams` (`repo`), `GroupParams` (`target`, `name`), `GroupRenameParams` (`target`, `name`, `newName`), `RowMoveParams` (`target`, `group`, `noGroup`, `before`, `after`) with `destinationCount`, `RowMoveResult` (`row`, `moved`, `from`), and `RowNewParams.group`.

`row.move` resolves its row with `TargetResolver.row`, and `before` or `after` with the same resolver scoped to the row's repo, so a branch in another repo is `invalid_anchor` rather than ambiguous.
`RowMoveResult` adds `moved` and `from` to the row the spec names, so the CLI can say "already in Review" and "out of Review" without a second request, and `row move --json` still prints only the row.
`row select` and `row new --select` unfold a collapsed group through `Workspace.revealRow` before telling the UI.

Tests, through the in-process server:

- `groupsFlowOverTheSocket`: new, `row.new` with a group, `row.move`, rename, list, `row.list`'s groups, remove, `group_exists`, `invalid_group_name`, `missing_target`, and `group.list` left out of `cli.call`.
- `rowMoveTakesExactlyOneDestination`: none and two give `bad_params`, and the main row gives `cannot_move_main`.
- `rowMoveResolvesAnchorsInTheRowsRepo`: a branch in both repos resolves in the moved row's, and another repo's row, the main row, the row itself, and another repo's path are `invalid_anchor`, while a branch nowhere is `row_not_found`.
- `rowNewWithAMissingGroupFails` with `group_not_found` and no worktree.
- `selectingAHiddenRowUnfoldsItsGroup`.

`scripts/e2e.sh` gains a step after "listing" that drives every command with a real app, checks the GROUP column and `"group"`, both errors, that `group rm` leaves the worktree, that `canopy log --type group` shows the events, and, just before the app is stopped for the last step, that groups come back after a relaunch.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/GroupControlTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

struct GroupControlTests {
    let base = ControlServerTests()

    func send(_ client: ControlClient, _ method: String, _ params: JSONValue) async throws -> ControlResponse {
        try await offPool { try client.send(ControlRequest(method: method, params: params)) }
    }

    @Test func groupsFlowOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let demo = TargetHint(repo: "demo")
        let a = try await base.call(
            client, ControlMethod.rowNew, RowNewParams(target: demo, branch: "feat/a"), as: RowNewResult.self
        ).row

        let created = try await base.call(
            client, GroupMethod.new, GroupParams(target: demo, name: " Review "), as: GroupInfo.self)
        #expect(created == GroupInfo(repo: "demo", repoPath: repo, name: "Review", collapsed: false, rows: []))
        let b = try await base.call(
            client, ControlMethod.rowNew, RowNewParams(target: demo, branch: "feat/b", group: "review"),
            as: RowNewResult.self
        ).row
        #expect(b.group == "Review")
        let moved = try await base.call(
            client, ControlMethod.rowMove, RowMoveParams(target: TargetHint(row: a.path), group: "REVIEW"),
            as: RowMoveResult.self)
        #expect(moved.moved && moved.row.group == "Review" && moved.from == nil)
        let renamed = try await base.call(
            client, GroupMethod.rename, GroupRenameParams(target: demo, name: "review", newName: "Code review"),
            as: GroupInfo.self)
        #expect(renamed.name == "Code review")

        let listed = try await base.call(client, GroupMethod.list, GroupListParams(), as: [GroupInfo].self)
        #expect(listed.map(\.name) == ["Code review"])
        #expect(listed.first?.rows.map(\.branch) == ["feat/b", "feat/a"])
        let rows = try await base.call(client, ControlMethod.rowList, RowListParams(), as: [Row].self)
        #expect(rows.map(\.group) == [nil, "Code review", "Code review"])

        let removed = try await base.call(
            client, GroupMethod.remove, GroupParams(target: TargetHint(cwd: b.path), name: "code review"),
            as: GroupInfo.self)
        #expect(removed.rows.map(\.branch) == ["feat/b", "feat/a"])
        #expect(
            try await base.call(client, GroupMethod.list, GroupListParams(repo: "demo"), as: [GroupInfo].self).isEmpty)

        let taken = try await send(
            client, GroupMethod.new, .from(GroupParams(target: demo, name: "Later")))
        #expect(taken.error == nil)
        let duplicate = try await send(client, GroupMethod.new, .from(GroupParams(target: demo, name: "LATER")))
        #expect(duplicate.error?.code == "group_exists")
        let blank = try await send(client, GroupMethod.new, .from(GroupParams(target: demo, name: "  ")))
        #expect(blank.error?.code == "invalid_group_name")
        let untargeted = try await send(client, GroupMethod.new, .object(["name": "X"]))
        #expect(untargeted.error?.code == "missing_target")

        let methods = await logged(workspace, "cli").compactMap { event -> String? in
            if case .string(let method) = event.data["method"] { method } else { nil }
        }
        #expect(!methods.contains(GroupMethod.list))
        #expect(
            methods.filter { $0.hasPrefix("group.") } == [
                "group.new", "group.rename", "group.remove", "group.new", "group.new", "group.new", "group.new",
            ])
    }

    @Test func rowMoveTakesExactlyOneDestination() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = JSONValue.object(["target": .object(["repo": "demo", "row": "main"])])

        let none = try await send(client, ControlMethod.rowMove, target)
        #expect(none.error?.code == "bad_params")
        let two = try await send(
            client, ControlMethod.rowMove,
            .object(["target": .object(["repo": "demo", "row": "main"]), "group": "X", "noGroup": true]))
        #expect(two.error?.code == "bad_params")
        let main = try await send(
            client, ControlMethod.rowMove,
            .object(["target": .object(["repo": "demo", "row": "main"]), "noGroup": true]))
        #expect(main.error?.code == "cannot_move_main")
    }

    @Test func rowMoveResolvesAnchorsInTheRowsRepo() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let other = try await Fixture.repo(in: dir, name: "other")
        let (workspace, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        for path in [repo, other] {
            _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: path), as: RepoInfo.self)
        }
        for (name, branch) in [("demo", "feat/a"), ("demo", "feat/same"), ("other", "feat/same"), ("other", "feat/c")] {
            _ = try await base.call(
                client, ControlMethod.rowNew, RowNewParams(target: TargetHint(repo: name), branch: branch),
                as: RowNewResult.self)
        }
        func move(after anchor: String) async throws -> ControlResponse {
            try await send(
                client, ControlMethod.rowMove,
                .from(RowMoveParams(target: TargetHint(repo: "demo", row: "feat/a"), after: anchor)))
        }

        let moved = try await move(after: "feat/same")
        #expect(moved.error == nil)
        #expect(await workspace.snapshot.repo(path: repo)?.rows.map(\.displayName) == ["main", "feat/same", "feat/a"])
        #expect(try await move(after: "feat/c").error?.code == "invalid_anchor")
        #expect(try await move(after: "main").error?.code == "invalid_anchor")
        #expect(try await move(after: "feat/a").error?.code == "invalid_anchor")
        #expect(try await move(after: other).error?.code == "invalid_anchor")
        #expect(try await move(after: "feat/nope").error?.code == "row_not_found")
    }

    @Test func rowNewWithAMissingGroupFails() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)

        let response = try await send(
            client, ControlMethod.rowNew,
            .from(RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/a", group: "Nope")))

        #expect(response.error == ControlError(WorkspaceError.groupNotFound("Nope", repo: "demo")))
        #expect(!FileManager.default.fileExists(atPath: dir.sub("home/worktrees/demo/feat-a")))
    }

    @Test func selectingAHiddenRowUnfoldsItsGroup() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, ui) = try await base.startServer(dir)
        defer { server.stop() }
        _ = try await base.call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        try await workspace.createGroup(repoPath: repo, name: "Review")
        let row = try await base.call(
            client, ControlMethod.rowNew,
            RowNewParams(target: TargetHint(repo: "demo"), branch: "feat/a", group: "Review"),
            as: RowNewResult.self
        ).row
        try await workspace.setGroupCollapsed(repoPath: repo, name: "Review", collapsed: true)

        _ = try await base.call(
            client, ControlMethod.rowSelect, RowRefParams(target: TargetHint(row: row.path)), as: Row.self)

        #expect(await workspace.snapshot.repo(path: repo)?.groups.first?.collapsed == false)
        #expect(ui.selected.withLock { $0 } == [row.path])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'GroupMethod' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCLI/AgentGuide.swift`:

```diff
@@ -35,6 +35,20 @@ struct AgentGuide: ParsableCommand {
         Setup tab, waits for them, then types `--run` into a new terminal. If setup fails, the row stays, the
         command is not run, and `row new` exits 1. `row rm` runs teardown first, then removes the worktree.
 
+        ## Groups
+
+            canopy group list [--repo <name>]             groups and their rows
+            canopy group new <name>                       an empty group, after the repo's others
+            canopy group rename <name> <new-name>
+            canopy group rm <name>                        its rows become ungrouped; no worktree is touched
+            canopy row move [<row>] (--group <name> | --no-group | --before <row> | --after <row>)
+            canopy row new <branch> --group <name>        create the row straight into a group
+
+        A group belongs to one repo and only arranges the sidebar, where it can fold away. Names match ignoring
+        case. A group that does not exist is an error (group_not_found), never created for you, so make it first
+        with `group new`. `row move --group` is safe to repeat: a row already in the group stays where it is.
+        `row list` shows each row's group, and `row list --json` carries it as "group".
+
         ## Terminals
 
             canopy term list [--all]                      ID, row, tab, process, title, and folder
@@ -89,6 +103,12 @@ struct AgentGuide: ParsableCommand {
 
             canopy log --since 1h --type term.command --json | jq '.[] | select(.data.exit != 0) | .data.cmd'
 
+        Keep your review rows together, and list them:
+
+            canopy group new Review
+            canopy row new feat/checkout --group Review --run claude
+            canopy row list --json | jq -r '.[] | select(.group == "Review") | .branch'
+
         Clean up when the work is merged:
 
             canopy row rm fix/login-redirect --delete-branch
```

`Sources/CanopyCLI/CanopyCLI.swift`:

```diff
@@ -9,8 +9,8 @@ struct CanopyCLI: AsyncParsableCommand {
         abstract: "Drive Canopy from the command line.",
         version: CanopyVersion.current,
         subcommands: [
-            Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, PortsCommand.self, PRCommand.self,
-            LogCommand.self, AgentGuide.self,
+            Status.self, RepoCommand.self, RowCommand.self, GroupCommand.self, TermCommand.self, PortsCommand.self,
+            PRCommand.self, LogCommand.self, AgentGuide.self,
         ]
     )
 }
```

`Sources/CanopyCLI/GroupCommand.swift` (new):

```swift
import ArgumentParser
import CanopyCore
import Foundation

struct GroupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Gather a repo's rows into named groups that fold away in the sidebar.",
        discussion: """
            A group belongs to one repo and only arranges the sidebar: deleting one never touches a worktree. \
            Names are matched ignoring case. Put rows in a group with `canopy row move --group` or \
            `canopy row new --group`.
            """,
        subcommands: [List.self, New.self, Rename.self, Remove.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List groups and their rows, in every repo or in one.")

        @Option(help: "Only this repo (name or path).")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(GroupMethod.list, GroupListParams(repo: repo.map(Client.absolutePathIfRelative)))
            try client.print(result) {
                let groups = try result.decode([GroupInfo].self)
                return Table.render(
                    ["GROUP", "REPO", "ROWS"],
                    groups.map { group in
                        [
                            group.name, group.repo,
                            group.rows.isEmpty ? "-" : group.rows.map(\.displayName).joined(separator: ", "),
                        ]
                    }
                )
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an empty group after the repo's other groups.")

        @Argument(help: "The group's name, unique in its repo ignoring case.")
        var name: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(GroupMethod.new, GroupParams(target: Client.hint(repo: repo), name: name))
            try client.print(result) {
                let group = try result.decode(GroupInfo.self)
                return "Created group \(group.name) in \(group.repo)."
            }
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a group.")

        @Argument(help: "The group's current name.")
        var name: String
        @Argument(help: "Its new name.")
        var newName: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                GroupMethod.rename, GroupRenameParams(target: Client.hint(repo: repo), name: name, newName: newName))
            try client.print(result) {
                let group = try result.decode(GroupInfo.self)
                return "Renamed \(name.trimmingCharacters(in: .whitespacesAndNewlines)) to \(group.name)."
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Delete a group. Its rows move to the end of the ungrouped rows, and no worktree is touched."
        )

        @Argument(help: "The group's name.")
        var name: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(GroupMethod.remove, GroupParams(target: Client.hint(repo: repo), name: name))
            try client.print(result) {
                let group = try result.decode(GroupInfo.self)
                switch group.rows.count {
                case 0: return "Deleted group \(group.name)."
                case 1: return "Deleted group \(group.name). Its row is ungrouped."
                default: return "Deleted group \(group.name). Its \(group.rows.count) rows are ungrouped."
                }
            }
        }
    }
}
```

`Sources/CanopyCLI/RowCommand.swift`:

```diff
@@ -6,7 +6,7 @@ struct RowCommand: AsyncParsableCommand {
     static let configuration = CommandConfiguration(
         commandName: "row",
         abstract: "Create, remove, and list rows (worktrees).",
-        subcommands: [List.self, New.self, Remove.self, Select.self, Adopt.self]
+        subcommands: [List.self, New.self, Remove.self, Select.self, Adopt.self, Move.self]
     )
 
     struct List: AsyncParsableCommand {
@@ -27,10 +27,10 @@ struct RowCommand: AsyncParsableCommand {
             try client.print(result) {
                 let rows = try result.decode([Row].self)
                 return Table.render(
-                    ["BRANCH", "CLASS", "PATH"],
+                    ["BRANCH", "GROUP", "CLASS", "PATH"],
                     rows.map { row in
                         let rowClass = row.externalTag.map { "\(row.rowClass.rawValue):\($0.rawValue)" }
-                        return [row.displayName, rowClass ?? row.rowClass.rawValue, row.path]
+                        return [row.displayName, row.group ?? "-", rowClass ?? row.rowClass.rawValue, row.path]
                     }
                 )
             }
@@ -61,6 +61,8 @@ struct RowCommand: AsyncParsableCommand {
         var noSetup = false
         @Flag(help: "Switch the Canopy window to the new row.")
         var select = false
+        @Option(help: "Put the row at the end of this group of the repo, which must exist.")
+        var group: String?
         @OptionGroup var output: OutputOptions
 
         func run() async throws {
@@ -69,7 +71,7 @@ struct RowCommand: AsyncParsableCommand {
                 ControlMethod.rowNew,
                 RowNewParams(
                     target: Client.hint(repo: repo), branch: branch, base: base, select: select, setup: !noSetup,
-                    run: command)
+                    run: command, group: group)
             )
             let created = try result.decode(RowNewResult.self)
             for warning in created.warnings {
@@ -148,6 +150,63 @@ struct RowCommand: AsyncParsableCommand {
         }
     }
 
+    struct Move: AsyncParsableCommand {
+        static let configuration = CommandConfiguration(
+            abstract: "Move a row into a group, out of one, or next to another row of its repo.",
+            discussion: """
+                Pass exactly one of --group, --no-group, --before, and --after. A move that would leave the row \
+                where it is changes nothing, so `--group` is safe to repeat: it never reorders a row already in \
+                that group.
+                """
+        )
+
+        @Argument(help: "Branch or path. Defaults to the row you are in.")
+        var row: String?
+        @Option(help: "Repo name or path, when the branch exists in several repos.")
+        var repo: String?
+        @Option(help: "Put the row at the end of this group, which must exist.")
+        var group: String?
+        @Flag(name: .customLong("no-group"), help: "Put the row at the end of the ungrouped rows.")
+        var noGroup = false
+        @Option(help: "Put the row just before this row of the same repo (branch or path).")
+        var before: String?
+        @Option(help: "Put the row just after this row of the same repo (branch or path).")
+        var after: String?
+        @OptionGroup var output: OutputOptions
+
+        func validate() throws {
+            let destinations = [group != nil, noGroup, before != nil, after != nil].filter { $0 }.count
+            guard destinations == 1 else {
+                throw ValidationError("Pass exactly one of --group, --no-group, --before, and --after.")
+            }
+        }
+
+        func run() async throws {
+            let client = Client(json: output.json)
+            let result = client.call(
+                ControlMethod.rowMove,
+                RowMoveParams(
+                    target: Client.hint(repo: repo, row: row), group: group, noGroup: noGroup,
+                    before: before.map(Client.absolutePathIfRelative), after: after.map(Client.absolutePathIfRelative))
+            )
+            let moved = try result.decode(RowMoveResult.self)
+            try client.print(try .from(moved.row)) { summary(of: moved) }
+        }
+
+        private func summary(of moved: RowMoveResult) -> String {
+            let name = moved.row.displayName
+            if let before, moved.moved { return "Moved \(name) before \(before)." }
+            if let after, moved.moved { return "Moved \(name) after \(after)." }
+            switch (moved.moved, moved.row.group, moved.from) {
+            case (true, let to?, _): return "Moved \(name) to \(to)."
+            case (true, nil, let from?): return "Moved \(name) out of \(from)."
+            case (false, let group?, _) where self.group != nil: return "\(name) is already in \(group)."
+            case (false, nil, _) where noGroup: return "\(name) is not in a group."
+            default: return "\(name) is already there."
+            }
+        }
+    }
+
     struct Adopt: AsyncParsableCommand {
         static let configuration = CommandConfiguration(
             abstract: "Show a worktree made by another tool as a regular row."
```

`Sources/CanopyCore/Control/ControlMethods.swift`:

```diff
@@ -10,11 +10,12 @@ public enum ControlMethod {
     public static let rowRemove = "row.remove"
     public static let rowSelect = "row.select"
     public static let rowAdopt = "row.adopt"
+    public static let rowMove = "row.move"
     public static let prShow = "pr.show"
 
     /// Methods that only read, which the activity log leaves out: agents poll some of them every few seconds.
     public static let readOnly: Set<String> = [
-        status, repoList, rowList, prShow, TermMethod.list, TermMethod.read, PortMethod.list,
+        status, repoList, rowList, prShow, TermMethod.list, TermMethod.read, PortMethod.list, GroupMethod.list,
     ]
 
     /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo, so they
@@ -126,10 +127,12 @@ public struct RowNewParams: Codable, Sendable {
     public var setup: Bool
     /// A command to type into a new terminal once setup succeeds.
     public var run: String?
+    /// A group of the repo to put the row in, which must exist.
+    public var group: String?
 
     public init(
         target: TargetHint = TargetHint(), branch: String, base: String? = nil, select: Bool = false,
-        setup: Bool = true, run: String? = nil
+        setup: Bool = true, run: String? = nil, group: String? = nil
     ) {
         self.target = target
         self.branch = branch
@@ -137,6 +140,7 @@ public struct RowNewParams: Codable, Sendable {
         self.select = select
         self.setup = setup
         self.run = run
+        self.group = group
     }
 
     public init(from decoder: any Decoder) throws {
@@ -147,6 +151,7 @@ public struct RowNewParams: Codable, Sendable {
         select = try container.decodeIfPresent(Bool.self, forKey: .select) ?? false
         setup = try container.decodeIfPresent(Bool.self, forKey: .setup) ?? true
         run = try container.decodeIfPresent(String.self, forKey: .run)
+        group = try container.decodeIfPresent(String.self, forKey: .group)
     }
 }
```

`Sources/CanopyCore/Control/GroupMethods.swift` (new):

```swift
import Foundation

public enum GroupMethod {
    public static let list = "group.list"
    public static let new = "group.new"
    public static let rename = "group.rename"
    public static let remove = "group.remove"
}

public struct GroupListParams: Codable, Sendable {
    /// Limits the list to one repo. Lists every repo's groups when nil.
    public var repo: String?

    public init(repo: String? = nil) {
        self.repo = repo
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
    }
}

/// A group of the resolved repo, for `group.new` and `group.remove`.
public struct GroupParams: Codable, Sendable {
    public var target: TargetHint
    public var name: String

    public init(target: TargetHint = TargetHint(), name: String) {
        self.target = target
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        name = try container.decode(String.self, forKey: .name)
    }
}

public struct GroupRenameParams: Codable, Sendable {
    public var target: TargetHint
    public var name: String
    public var newName: String

    public init(target: TargetHint = TargetHint(), name: String, newName: String) {
        self.target = target
        self.name = name
        self.newName = newName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        name = try container.decode(String.self, forKey: .name)
        newName = try container.decode(String.self, forKey: .newName)
    }
}

/// Exactly one of `group`, `noGroup`, `before`, and `after` says where the row goes.
public struct RowMoveParams: Codable, Sendable {
    public var target: TargetHint
    /// The end of this group.
    public var group: String?
    /// The end of the ungrouped rows.
    public var noGroup: Bool
    /// Just before this row of the same repo, a branch or a path.
    public var before: String?
    /// Just after this row of the same repo, a branch or a path.
    public var after: String?

    public init(
        target: TargetHint = TargetHint(), group: String? = nil, noGroup: Bool = false, before: String? = nil,
        after: String? = nil
    ) {
        self.target = target
        self.group = group
        self.noGroup = noGroup
        self.before = before
        self.after = after
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        group = try container.decodeIfPresent(String.self, forKey: .group)
        noGroup = try container.decodeIfPresent(Bool.self, forKey: .noGroup) ?? false
        before = try container.decodeIfPresent(String.self, forKey: .before)
        after = try container.decodeIfPresent(String.self, forKey: .after)
    }

    /// How many destinations were given, which must be one.
    public var destinationCount: Int {
        [group != nil, noGroup, before != nil, after != nil].filter { $0 }.count
    }
}

public struct RowMoveResult: Codable, Sendable {
    public var row: Row
    /// False when the row was already where it was asked to go.
    public var moved: Bool
    /// The group the row was in before, nil if it was ungrouped.
    public var from: String?
}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`:

```diff
@@ -99,7 +99,8 @@ public struct WorkspaceControlHandler: Sendable {
         case ControlMethod.rowNew:
             let params = try request.decodeParams(RowNewParams.self)
             let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
-            let created = try await workspace.createRow(repoPath: repo.path, branch: params.branch, base: params.base)
+            let created = try await workspace.createRow(
+                repoPath: repo.path, branch: params.branch, base: params.base, group: params.group)
             let preparing = await rows.prepare(created.row, repoName: repo.name, setup: params.setup, run: params.run)
             if params.select {
                 await select(created.row.path)
@@ -128,6 +129,51 @@ public struct WorkspaceControlHandler: Sendable {
             let params = try request.decodeParams(RowAdoptParams.self)
             return try .from(try await workspace.adopt(path: params.path))
 
+        case ControlMethod.rowMove:
+            let params = try request.decodeParams(RowMoveParams.self)
+            guard params.destinationCount == 1 else {
+                throw ControlError(
+                    code: "bad_params", message: "row.move takes exactly one of group, noGroup, before, and after.")
+            }
+            let snapshot = await workspace.snapshot
+            let row = try TargetResolver.row(for: params.target, in: snapshot)
+            let placement: RowPlacement =
+                if let group = params.group {
+                    .group(group)
+                } else if let before = params.before {
+                    .before(try anchor(before, besides: row, in: snapshot))
+                } else if let after = params.after {
+                    .after(try anchor(after, besides: row, in: snapshot))
+                } else {
+                    .ungrouped
+                }
+            let moved = try await workspace.moveRow(path: row.path, to: placement)
+            return try .from(RowMoveResult(row: moved.row, moved: moved.moved, from: moved.from))
+
+        case GroupMethod.list:
+            let params = try request.decodeParams(GroupListParams.self)
+            let snapshot = await workspace.snapshot
+            let repos =
+                try params.repo.map { [try TargetResolver.repo(for: TargetHint(repo: $0), in: snapshot)] }
+                ?? snapshot.repos
+            return try .from(repos.flatMap { repo in repo.groups.map { GroupInfo(repo: repo, group: $0) } })
+
+        case GroupMethod.new:
+            let params = try request.decodeParams(GroupParams.self)
+            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
+            return try .from(try await workspace.createGroup(repoPath: repo.path, name: params.name))
+
+        case GroupMethod.rename:
+            let params = try request.decodeParams(GroupRenameParams.self)
+            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
+            return try .from(
+                try await workspace.renameGroup(repoPath: repo.path, name: params.name, to: params.newName))
+
+        case GroupMethod.remove:
+            let params = try request.decodeParams(GroupParams.self)
+            let repo = try TargetResolver.repo(for: params.target, in: await workspace.snapshot)
+            return try .from(try await workspace.removeGroup(repoPath: repo.path, name: params.name))
+
         case ControlMethod.prShow:
             let params = try request.decodeParams(PRShowParams.self)
             let snapshot = await workspace.snapshot
@@ -199,7 +245,25 @@ public struct WorkspaceControlHandler: Sendable {
         }
     }
 
+    /// The row `--before` or `--after` names, looked up among the moved row's repo, so a branch that also exists
+    /// in another repo is not ambiguous. It must be another Canopy or adopted row of that repo.
+    private func anchor(_ name: String, besides row: Row, in snapshot: WorkspaceSnapshot) throws -> String {
+        let found: Row
+        do {
+            found = try TargetResolver.row(for: TargetHint(repo: row.repoPath, row: name), in: snapshot)
+        } catch WorkspaceError.rowNotFound {
+            let elsewhere = snapshot.repos.contains { $0.allRows.contains { $0.branch == name } }
+            throw elsewhere ? WorkspaceError.invalidAnchor(name) : WorkspaceError.rowNotFound(name)
+        }
+        guard found.repoPath == row.repoPath, found.path != row.path,
+            found.rowClass == .canopy || found.rowClass == .adopted
+        else { throw WorkspaceError.invalidAnchor(name) }
+        return found.path
+    }
+
+    /// A row hidden in a collapsed group unfolds first, so the sidebar shows what is selected.
     private func select(_ path: String) async {
+        try? await workspace.revealRow(path: path)
         try? await workspace.setSelectedRow(path: path)
         await ui.selectRow(path: path)
     }
```

`Sources/CanopyCore/Workspace/Workspace+Groups.swift`:

```diff
@@ -27,6 +27,8 @@ public struct MovedRow: Sendable, Equatable {
     public var row: Row
     /// False when the row was already where it was asked to go.
     public var moved: Bool
+    /// The group the row was in before, nil if it was ungrouped.
+    public var from: String?
 }
 
 /// Groups only arrange the sidebar, so changing them runs no git: each change edits the repo's entry, saves it, and
@@ -104,7 +106,7 @@ extension Workspace {
                 ActivityType.rowMoved, current,
                 data: ["from": from.map(JSONValue.string) ?? .null, "to": current.group.map(JSONValue.string) ?? .null])
         }
-        return MovedRow(row: current, moved: moved)
+        return MovedRow(row: current, moved: moved, from: from)
     }
 
     /// Applies `change` to the repo's entry, and saves and republishes it if the entry changed.
```

`scripts/e2e.sh`:

```diff
@@ -74,6 +74,49 @@ sleep 1
 swift scripts/window-shot.swift "$(app_pid)" "$shots/rows.png"
 echo "saved $shots/rows.png"
 
+step "canopy group and canopy row move arrange rows"
+group_of() {
+    "$cli" row list --repo demo --json |
+        /usr/bin/python3 -c 'import json, sys; print({r["branch"]: r.get("group") for r in json.load(sys.stdin)}[sys.argv[1]])' "$1"
+}
+"$cli" group new Review --repo demo >/dev/null
+"$cli" row new feat/grouped --repo demo --group review >/dev/null
+"$cli" row list --repo demo | grep -Eq '^feat/grouped +Review +canopy ' || fail "row list has no GROUP column"
+[[ "$(group_of feat/grouped)" == Review ]] || fail "row new --group did not put the row in the group"
+"$cli" row move feat/plain --repo demo --group Review >/dev/null
+"$cli" row move feat/plain --repo demo --before feat/grouped | grep -qx "Moved feat/plain before feat/grouped." ||
+    fail "row move --before said something else"
+"$cli" group list --repo demo --json | /usr/bin/python3 -c '
+import json, sys
+groups = json.load(sys.stdin)
+assert [(g["name"], [r["branch"] for r in g["rows"]]) for g in groups] == [("Review", ["feat/plain", "feat/grouped"])], groups
+' || fail "group list has the wrong rows"
+"$cli" row move feat/plain --repo demo --group REVIEW | grep -qx "feat/plain is already in Review." ||
+    fail "repeating row move --group was not a no-op"
+"$cli" row move feat/plain --repo demo --no-group | grep -qx "Moved feat/plain out of Review." ||
+    fail "row move --no-group said something else"
+[[ "$(group_of feat/plain)" == None ]] || fail "feat/plain is still grouped"
+if "$cli" row new feat/nogroup --repo demo --group Nope --json > "$work/nogroup.json" 2>/dev/null; then
+    fail "expected failure"
+fi
+grep -q '"group_not_found"' "$work/nogroup.json" || fail "missing group_not_found"
+[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-nogroup" ]] || fail "a missing group still created the row"
+if "$cli" group new " REVIEW " --repo demo --json > "$work/taken.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"group_exists"' "$work/taken.json" || fail "missing group_exists"
+if "$cli" row move feat/grouped --repo demo --json > /dev/null 2>&1; then fail "row move without a destination"; fi
+"$cli" group rename review "Code review" --repo demo | grep -qx "Renamed review to Code review." ||
+    fail "group rename said something else"
+"$cli" group rm "code REVIEW" --repo demo | grep -qx "Deleted group Code review. Its row is ungrouped." ||
+    fail "group rm said something else"
+[[ -d "$CANOPY_HOME/worktrees/demo/feat-grouped" ]] || fail "group rm touched a worktree"
+[[ "$(group_of feat/grouped)" == None ]] || fail "group rm left the row grouped"
+"$cli" log --type group | grep -q "Code review, 1 row" || fail "canopy log is missing group.removed"
+"$cli" log --type row.moved | grep -q "none -> Review" || fail "canopy log is missing row.moved"
+"$cli" agent-guide | grep -q "canopy group new" || fail "agent-guide is missing groups"
+# Kept for the relaunch check at the end.
+"$cli" group new Kept --repo demo >/dev/null
+"$cli" row move feat/grouped --repo demo --group Kept >/dev/null
+
 step "canopy row rm removes the worktree and branch"
 "$cli" row rm feat/e2e --repo demo --delete-branch
 [[ ! -d "$CANOPY_HOME/worktrees/demo/feat-e2e" ]] || fail "worktree folder still exists"
@@ -257,13 +300,25 @@ if CANOPY_APP=/nonexistent CANOPY_HOME="$work/nobody" "$cli" row list --json > "
 fi
 grep -q '"app_unavailable"' "$work/err2.json" || fail "no JSON error when the app cannot be launched"
 
+stop_app() {
+    kill "$(app_pid)"
+    for _ in $(seq 1 50); do
+        [[ -z "$(app_pid)" ]] && break
+        sleep 0.1
+    done
+    [[ -z "$(app_pid)" ]] || fail "the app did not quit"
+}
+
+step "groups come back after a relaunch"
+stop_app
+"$cli" group list --repo demo --json | /usr/bin/python3 -c '
+import json, sys
+groups = json.load(sys.stdin)
+assert [(g["name"], [r["branch"] for r in g["rows"]]) for g in groups] == [("Kept", ["feat/grouped"])], groups
+' || fail "groups did not survive a relaunch"
+
 step "canopy log works while Canopy is not running"
-kill "$(app_pid)"
-for _ in $(seq 1 50); do
-    [[ -z "$(app_pid)" ]] && break
-    sleep 0.1
-done
-[[ -z "$(app_pid)" ]] || fail "the app did not quit"
+stop_app
 "$cli" log --type repo.added | grep -q demo || fail "canopy log needs the app"
 [[ -z "$(app_pid)" ]] || fail "canopy log launched the app"
```

- [ ] **Step 4: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 357 tests in 51 suites passed`, no lint findings, and no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests scripts
git commit -m "feat: canopy group and canopy row move"
```

## Task 5: Where a dragged row lands

**Files:** Create `Sources/CanopyCore/Rows/RowDrop.swift`.
Test `Tests/CanopyCoreTests/RowDropTests.swift`.

**Interfaces:**
- Consumes `RowPlacement` from Task 1.
- Produces `DropSlot` (`repoPath`, `kind`: `.main(path)`, `.row(path, group: String?)`, `.header(String)`, `minY`, `maxY`), `RowDropTarget` (`placement`, `indicator`: `.header(String)`, `.above(path)`, `.below(path)`), and `RowDrop.target(dragging: Row, at y: Double, in slots: [DropSlot]) -> RowDropTarget?`.

Tests:

- `headersTakeTheRowAtTheirEnd`, collapsed or not.
- `rowHalvesPlaceBeforeOrAfter`, in and out of groups.
- `theMainRowMeansFirstAmongTheUngroupedRows`: `.before` the first ungrouped row that is not the dragged one, or `.ungrouped` when there is none.
- `otherReposAndGapsAreNotTargets`, and the dragged row itself is not one.
- `dropsThatChangeNothingAreNoOps`: applying each target to a `RepoEntry` with `move` returns false where the row already is.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/RowDropTests.swift` (new):

```swift
import Testing

@testable import CanopyCore

struct RowDropTests {
    static func row(_ path: String, repo: String = "/web") -> Row {
        Row(repoPath: repo, path: path, branch: path, head: nil, rowClass: .canopy)
    }

    /// web: main, a, the Review header with b and c, and the collapsed Later header. api: main and e.
    static let slots: [DropSlot] = [
        DropSlot(repoPath: "/web", kind: .main("/web"), minY: 0, maxY: 26),
        DropSlot(repoPath: "/web", kind: .row("/web/a", group: nil), minY: 26, maxY: 52),
        DropSlot(repoPath: "/web", kind: .header("Review"), minY: 52, maxY: 78),
        DropSlot(repoPath: "/web", kind: .row("/web/b", group: "Review"), minY: 78, maxY: 104),
        DropSlot(repoPath: "/web", kind: .row("/web/c", group: "Review"), minY: 104, maxY: 130),
        DropSlot(repoPath: "/web", kind: .header("Later"), minY: 130, maxY: 156),
        DropSlot(repoPath: "/api", kind: .main("/api"), minY: 170, maxY: 196),
        DropSlot(repoPath: "/api", kind: .row("/api/e", group: nil), minY: 196, maxY: 222),
    ]

    func target(_ path: String, at y: Double) -> RowDropTarget? {
        RowDrop.target(dragging: Self.row(path), at: y, in: Self.slots)
    }

    @Test func headersTakeTheRowAtTheirEnd() {
        #expect(target("/web/a", at: 60) == RowDropTarget(placement: .group("Review"), indicator: .header("Review")))
        #expect(target("/web/b", at: 77.9) == RowDropTarget(placement: .group("Review"), indicator: .header("Review")))
        #expect(target("/web/a", at: 140) == RowDropTarget(placement: .group("Later"), indicator: .header("Later")))
    }

    @Test func rowHalvesPlaceBeforeOrAfter() {
        #expect(target("/web/a", at: 80) == RowDropTarget(placement: .before("/web/b"), indicator: .above("/web/b")))
        #expect(target("/web/a", at: 100) == RowDropTarget(placement: .after("/web/b"), indicator: .below("/web/b")))
        #expect(target("/web/c", at: 30) == RowDropTarget(placement: .before("/web/a"), indicator: .above("/web/a")))
        #expect(target("/web/c", at: 51) == RowDropTarget(placement: .after("/web/a"), indicator: .below("/web/a")))
    }

    @Test func theMainRowMeansFirstAmongTheUngroupedRows() {
        #expect(target("/web/b", at: 10) == RowDropTarget(placement: .before("/web/a"), indicator: .below("/web")))
        #expect(target("/web/a", at: 10) == RowDropTarget(placement: .ungrouped, indicator: .below("/web")))
    }

    @Test func otherReposAndGapsAreNotTargets() {
        #expect(target("/web/a", at: 30) == nil)
        #expect(target("/web/a", at: 160) == nil)
        #expect(target("/web/a", at: 180) == nil)
        #expect(target("/web/a", at: 200) == nil)
        #expect(target("/web/a", at: -1) == nil)
        #expect(target("/web/a", at: 222) == nil)
    }

    @Test func dropsThatChangeNothingAreNoOps() throws {
        var entry = RepoEntry(path: "/web", dirName: "web", rowOrder: ["/web/a"])
        entry.groups = [RowGroup(name: "Review", rows: ["/web/b", "/web/c"]), RowGroup(name: "Later")]
        let before = entry
        let drops: [(String, Double)] = [("/web/a", 10), ("/web/b", 60), ("/web/c", 100), ("/web/b", 110)]

        for (path, y) in drops {
            let placement = try #require(target(path, at: y)).placement
            let moved = try entry.move(path, to: placement, repo: "web")
            #expect(!moved, "\(path) at \(y)")
        }
        #expect(entry == before)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: the build fails with `cannot find 'DropSlot' in scope`.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Rows/RowDrop.swift` (new):

```swift
/// One line of the sidebar, as a dragged row sees it, with its extent down the list.
public struct DropSlot: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The repo's main row, by path.
        case main(String)
        /// A Canopy or adopted row, by path, and its group.
        case row(String, group: String?)
        /// A group's header, by the group's name.
        case header(String)
    }

    public var repoPath: String
    public var kind: Kind
    public var minY: Double
    public var maxY: Double

    public init(repoPath: String, kind: Kind, minY: Double, maxY: Double) {
        self.repoPath = repoPath
        self.kind = kind
        self.minY = minY
        self.maxY = maxY
    }
}

/// Where a dropped row goes, and how the sidebar shows it while the row hovers there.
public struct RowDropTarget: Sendable, Equatable {
    public enum Indicator: Sendable, Equatable {
        /// The group's header takes the accent fill.
        case header(String)
        /// A line above the row with this path.
        case above(String)
        /// A line below the row with this path.
        case below(String)
    }

    public var placement: RowPlacement
    public var indicator: Indicator

    public init(placement: RowPlacement, indicator: Indicator) {
        self.placement = placement
        self.indicator = indicator
    }
}

public enum RowDrop {
    /// A group header takes the row at its end. A row's upper half puts the dragged row before it and its lower half
    /// after it. The main row puts it first among the ungrouped rows. Nothing else, including another repo and the
    /// dragged row itself, is a target.
    public static func target(dragging row: Row, at y: Double, in slots: [DropSlot]) -> RowDropTarget? {
        guard let slot = slots.first(where: { $0.minY <= y && y < $0.maxY }), slot.repoPath == row.repoPath else {
            return nil
        }
        switch slot.kind {
        case .header(let name):
            return RowDropTarget(placement: .group(name), indicator: .header(name))
        case .main(let path):
            let firstUngrouped = slots.lazy.compactMap { other -> String? in
                guard other.repoPath == row.repoPath, case .row(let path, nil) = other.kind, path != row.path else {
                    return nil
                }
                return path
            }.first
            return RowDropTarget(placement: firstUngrouped.map { .before($0) } ?? .ungrouped, indicator: .below(path))
        case .row(let path, _):
            guard path != row.path else { return nil }
            return y < (slot.minY + slot.maxY) / 2
                ? RowDropTarget(placement: .before(path), indicator: .above(path))
                : RowDropTarget(placement: .after(path), indicator: .below(path))
        }
    }
}
```

- [ ] **Step 4: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 362 tests in 52 suites passed`, no lint findings, and no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests scripts
git commit -m "feat: where a dragged row lands"
```

## Task 6: Groups in the sidebar

**Files:** Create `Sources/CanopyApp/Sidebar/GroupViews.swift`.
Modify `SidebarView.swift`, `RowActionViews.swift`, `PortsPanel.swift`, `AppModel.swift`, `scripts/ui-fixture.sh`.

**Interfaces:**
- Consumes Tasks 2 and 3.
- Produces `AppModel.createGroup(in:name:) async -> String?`, `createGroup(named:moving:) async -> String?`, `renameGroup(_:in:to:) async -> String?`, `removeGroup(_:in:)`, `setCollapsed(_:_:in:)`, `move(_:to:)`, and `createRow(in:branch:base:group:)`.
- Produces `AppModel.reveal(_ path: String)`, which selects a row and unfolds its group, and `scrollRequest`, which the list scrolls to.
- Produces `MoreMenu`, the `…` button the repo and group headers share, and `GroupNamePopover`.
- Produces `ui rightclick`, `ui down`, `ui drag-to`, and `ui up`, and `window-shot.swift --all`, which draws the app's own windows with ScreenCaptureKit, since `screencapture -l` cannot take menu windows.

Each repo section shows the ungrouped rows, then a `GroupHeaderView` per group with its rows indented one step, all filtered from `repo.rows` by `group`.
The header is a button that folds the group, with the count giving way to `…` and `+` on hover.
The name popover serves New Group… on the repo and in Move to Group, and Rename… on a group, and shows each error under its field.
Delete Group… asks first in a popover when the group has rows, and deletes an empty one at once.
VoiceOver reads a header as one button with its name, row count, and fold, and a grouped row's label adds its group.
The New Row sheet opens from a `NewRowRequest` carrying the repo and the group, and shows a Group picker when the repo has groups.
`↑` and `↓` use `steppingRow`, and the ports panel's branch headings call `reveal`.

The fixture gains a "Review" group in web-app holding feat/checkout-redesign and feat/onboarding-flow, and a "Later" group holding a new chore/bump-deps row, and refreshes PRs once its remotes are set.
Grouped rows indent their content 24 points, so their marks sit under the group's name, while their hover and selection fills keep the full width.
A row created from the sheet into a collapsed group unfolds it, since the sheet selects the new row.

Checks, each with posted events and confirmed with the CLI where it changes state:
- clicking Later's header folds it, and `feat/rate-limits` then shows `⌘6`, skipping the hidden row;
- hovering a header swaps its count for `…` and `+`;
- folding the group holding the selected row gives its header the selection, and `↓` from there goes to the next visible row;
- Move to Group lists the groups with a check on the current one, then No Group and New Group…, and picking Later moves the row and logs `row.moved` from `ui`;
- New Group… from the repo's `…` shows `group_exists` under the field for "review", then creates "Spikes";
- Delete Group… on a group with rows asks first;
- a group's `+` opens the sheet on that group, and the row lands in it;
- the ports panel's branch heading and `canopy row select` both unfold a folded group.

- [ ] **Step 1: Build it**

`Sources/CanopyApp/AppModel.swift`:

```diff
@@ -124,15 +124,13 @@ final class AppModel {
         selectedRowPath = rows[number - 1].path
     }
 
-    /// ↑ and ↓ in the sidebar. From no selection, down picks the first row and up the last.
+    /// ↑ and ↓ in the sidebar. From no selection, down picks the first row and up the last. From a row hidden in a
+    /// collapsed group, they go on from the group's place.
     func selectRow(offset: Int) {
-        let rows = snapshot.visibleRows
-        guard !rows.isEmpty else { return }
-        let index =
-            rows.firstIndex { $0.path == selectedRowPath }.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
+        guard let row = snapshot.steppingRow(from: selectedRowPath, offset: offset) else { return }
         isSteppingRows = true
         defer { isSteppingRows = false }
-        selectedRowPath = rows[min(max(index, 0), rows.count - 1)].path
+        selectedRowPath = row.path
     }
 
     /// Once the sidebar lets go of the keyboard, rows selected later hand it to their terminal again.
@@ -149,17 +147,43 @@ final class AppModel {
         Task { await workspace.refreshAll() }
     }
 
-    /// Selects a row once the snapshot has it, so a row created a moment ago gets its terminal.
+    /// Selects a row once the snapshot has it, so a row created a moment ago gets its terminal. The control API has
+    /// already unfolded a group hiding it.
     func select(_ path: String) async {
         apply(await workspace.snapshot)
         selectedRowPath = path
+        scrollRequest = ScrollRequest(path: path)
     }
 
+    /// Selects a row from outside the list, as the ports panel does, unfolding a group that hides it.
+    func reveal(_ path: String) {
+        selectedRowPath = path
+        Task {
+            do {
+                try await workspace.revealRow(path: path)
+            } catch {
+                show(error)
+            }
+            await select(path)
+        }
+    }
+
+    struct ScrollRequest: Equatable {
+        let path: String
+        let id = UUID()
+    }
+
+    /// A row the sidebar should scroll to even though the selection did not change.
+    private(set) var scrollRequest: ScrollRequest?
+
     /// Creates a row, starts its setup, and selects it. Returns an error message for the sheet to show, or nil.
-    func createRow(in repo: RepoSnapshot, branch: String, base: String?) async -> String? {
+    func createRow(in repo: RepoSnapshot, branch: String, base: String?, group: String? = nil) async -> String? {
         do {
-            let created = try await workspace.createRow(repoPath: repo.path, branch: branch, base: base)
+            let created = try await workspace.createRow(
+                repoPath: repo.path, branch: branch, base: base, group: group)
             let preparing = rows.prepare(created.row, repoName: repo.name, setup: true, run: nil)
+            // A row created into a collapsed group unfolds it, since the new row is selected.
+            try? await workspace.revealRow(path: created.row.path)
             await select(created.row.path)
             if let warning = created.warnings.first {
                 show(warning)
@@ -202,6 +226,47 @@ final class AppModel {
         }
     }
 
+    // MARK: Groups
+
+    /// Returns an error message for the name popover to show, or nil.
+    func createGroup(in repo: RepoSnapshot, name: String) async -> String? {
+        await message { try await $0.createGroup(repoPath: repo.path, name: name) }
+    }
+
+    /// The row menu's New Group…: makes the group, then moves the row into it.
+    func createGroup(named name: String, moving row: Row) async -> String? {
+        await message { workspace in
+            let group = try await workspace.createGroup(repoPath: row.repoPath, name: name)
+            _ = try await workspace.moveRow(path: row.path, to: .group(group.name))
+        }
+    }
+
+    func renameGroup(_ group: GroupSnapshot, in repo: RepoSnapshot, to name: String) async -> String? {
+        await message { try await $0.renameGroup(repoPath: repo.path, name: group.name, to: name) }
+    }
+
+    func removeGroup(_ group: GroupSnapshot, in repo: RepoSnapshot) {
+        perform { try await $0.removeGroup(repoPath: repo.path, name: group.name) }
+    }
+
+    func setCollapsed(_ group: GroupSnapshot, _ collapsed: Bool, in repo: RepoSnapshot) {
+        perform { try await $0.setGroupCollapsed(repoPath: repo.path, name: group.name, collapsed: collapsed) }
+    }
+
+    /// Move to Group and drops. A failure shows in a toast.
+    func move(_ row: Row, to placement: RowPlacement) {
+        perform { _ = try await $0.moveRow(path: row.path, to: placement) }
+    }
+
+    private func message(_ action: @escaping @Sendable (Workspace) async throws -> Void) async -> String? {
+        do {
+            try await action(workspace)
+            return nil
+        } catch {
+            return (error as? WorkspaceError)?.message ?? "\(error)"
+        }
+    }
+
     // MARK: Ports
 
     /// Nil until the first scan, so the panel never says nothing is listening before it has looked.
```

`Sources/CanopyApp/Sidebar/GroupViews.swift` (new):

```swift
import CanopyCore
import SwiftUI

/// A group's header: a chevron that folds it, its name, and its row count, which gives way to `…` and `+` on hover.
struct GroupHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let group: GroupSnapshot
    let count: Int
    let isFocused: Bool
    var isDropTarget = false
    let onNewRow: () -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false

    /// A collapsed group shows the selection for the row it hides, so the sidebar always says where the window is.
    private var holdsSelection: Bool {
        group.collapsed && model.selectedRow.map { $0.repoPath == repo.path && $0.group == group.name } == true
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(group.name)
                .font(Style.body.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if isHovering || isRenaming || isConfirmingDelete {
                MoreMenu(help: "More for \(group.name)") {
                    GroupMenuItems(rename: { isRenaming = true }, delete: requestDelete)
                }
                IconButton(title: "New Row in \(group.name)…", systemImage: "plus", action: onNewRow)
            } else {
                Text(verbatim: "\(count)")
                    .font(Style.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: Style.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .help(group.name)
        .contextMenu { GroupMenuItems(rename: { isRenaming = true }, delete: requestDelete) }
        .popover(isPresented: $isRenaming, arrowEdge: .trailing) {
            GroupNamePopover(
                title: "Rename \(group.name)", actionTitle: "Rename", name: group.name, isPresented: $isRenaming
            ) { name in
                await model.renameGroup(group, in: repo, to: name)
            }
        }
        .popover(isPresented: $isConfirmingDelete, arrowEdge: .trailing) {
            DeleteGroupPopover(group: group, count: count, isPresented: $isConfirmingDelete) {
                model.removeGroup(group, in: repo)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), group, \(count == 1 ? "1 row" : "\(count) rows")")
        .accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private var fill: Color {
        if isDropTarget { return Style.focusedSelectionFill }
        if holdsSelection { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { model.setCollapsed(group, !group.collapsed, in: repo) }
    }

    /// An empty group goes at once. One with rows asks first.
    private func requestDelete() {
        if count == 0 {
            model.removeGroup(group, in: repo)
        } else {
            isConfirmingDelete = true
        }
    }
}

struct GroupMenuItems: View {
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Rename…", action: rename)
        Button("Delete Group…", action: delete)
    }
}

/// Names a new group or renames one. A name the rules refuse shows why under the field and keeps the popover open.
struct GroupNamePopover: View {
    let title: String
    let actionTitle: String
    @State var name: String
    @Binding var isPresented: Bool
    /// Returns an error message to show, or nil once done.
    let commit: (String) async -> String?
    @State private var error: String?
    @State private var isWorking = false

    init(
        title: String, actionTitle: String, name: String = "", isPresented: Binding<Bool>,
        commit: @escaping (String) async -> String?
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self._name = State(initialValue: name)
        self._isPresented = isPresented
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
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
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(14)
        .frame(width: 260)
        // The popover inherits the sidebar row's one-line limit.
        .lineLimit(nil)
    }

    private func save() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            error = await commit(name)
            isWorking = false
            if error == nil {
                isPresented = false
            }
        }
    }
}

struct DeleteGroupPopover: View {
    let group: GroupSnapshot
    let count: Int
    @Binding var isPresented: Bool
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \(group.name)?")
                .font(.headline)
            Text(
                count == 1
                    ? "Its row moves out of the group. No worktree is touched."
                    : "Its \(count) rows move out of the group. No worktree is touched."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    isPresented = false
                    delete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .lineLimit(nil)
    }
}

/// A row's context menu: Prune for a missing row, and Move to Group for Canopy and adopted rows.
struct RowMenuItems: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let onNewGroup: () -> Void

    private var repo: RepoSnapshot? { model.snapshot.repo(path: row.repoPath) }

    var body: some View {
        if row.isMissing, let repo {
            Button("Prune Missing Worktrees") { model.prune(repo) }
        }
        if row.rowClass == .canopy || row.rowClass == .adopted {
            Menu("Move to Group") {
                ForEach(repo?.groups ?? []) { group in
                    // Picking the row's own group, the checked one, changes nothing.
                    Toggle(
                        group.name,
                        isOn: Binding(
                            get: { row.group == group.name }, set: { _ in model.move(row, to: .group(group.name)) }))
                }
                if row.group != nil {
                    Divider()
                    Button("No Group") { model.move(row, to: .ungrouped) }
                }
                if repo?.groups.isEmpty == false {
                    Divider()
                }
                Button("New Group…", action: onNewGroup)
            }
        }
    }
}

/// A borderless `…` button that opens a menu, as in the repo and group headers.
struct MoreMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
```

`Sources/CanopyApp/Sidebar/PortsPanel.swift`:

```diff
@@ -62,7 +62,7 @@ struct PortGroupView: View {
         VStack(alignment: .leading, spacing: 1) {
             HStack(spacing: 8) {
                 Button {
-                    model.selectedRowPath = group.rowPath
+                    model.reveal(group.rowPath)
                 } label: {
                     HStack(spacing: 8) {
                         Group {
```

`Sources/CanopyApp/Sidebar/RowActionViews.swift`:

```diff
@@ -5,6 +5,7 @@ struct NewRowSheet: View {
     @Environment(AppModel.self) private var model
     @Environment(\.dismiss) private var dismiss
     let repo: RepoSnapshot
+    @State var group: String?
     @State private var branch = ""
     @State private var base = ""
     @State private var isCreating = false
@@ -17,6 +18,15 @@ struct NewRowSheet: View {
             Form {
                 TextField("Branch", text: $branch, prompt: Text("feat/my-change"))
                 TextField("Start from", text: $base, prompt: Text("origin's default branch"))
+                if !repo.groups.isEmpty {
+                    Picker("Group", selection: $group) {
+                        Text("No Group").tag(String?.none)
+                        Divider()
+                        ForEach(repo.groups) { group in
+                            Text(group.name).tag(Optional(group.name))
+                        }
+                    }
+                }
             }
             .formStyle(.columns)
             .disabled(isCreating)
@@ -51,7 +61,8 @@ struct NewRowSheet: View {
         error = nil
         let base = base.trimmingCharacters(in: .whitespaces)
         Task {
-            error = await model.createRow(in: repo, branch: trimmedBranch, base: base.isEmpty ? nil : base)
+            error = await model.createRow(
+                in: repo, branch: trimmedBranch, base: base.isEmpty ? nil : base, group: group)
             isCreating = false
             if error == nil {
                 dismiss()
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```diff
@@ -4,7 +4,7 @@ import SwiftUI
 /// Repos and their rows, drawn by Canopy rather than a `List` so hover, selection, and density follow `Style`.
 struct SidebarView: View {
     @Environment(AppModel.self) private var model
-    @State private var newRowRepo: RepoSnapshot?
+    @State private var newRow: NewRowRequest?
     /// Repos whose other worktrees are shown.
     @State private var expanded: Set<String> = []
     @FocusState private var isFocused: Bool
@@ -22,8 +22,8 @@ struct SidebarView: View {
                     .padding(.bottom, 8)
             }
         }
-        .sheet(item: $newRowRepo) { repo in
-            NewRowSheet(repo: repo)
+        .sheet(item: $newRow) { request in
+            NewRowSheet(repo: request.repo, group: request.group)
         }
     }
 
@@ -35,6 +35,11 @@ struct SidebarView: View {
                     guard let path = model.selectedRowPath else { return }
                     withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path) }
                 }
+                // A row picked again from the ports panel or the CLI, perhaps just unfolded, scrolls into view too.
+                .onChange(of: model.scrollRequest) {
+                    guard let path = model.scrollRequest?.path else { return }
+                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path) }
+                }
         }
     }
 
@@ -55,7 +60,7 @@ struct SidebarView: View {
                             get: { expanded.contains(repo.path) },
                             set: { if $0 { expanded.insert(repo.path) } else { expanded.remove(repo.path) } }),
                         isFocused: isFocused,
-                        onNewRow: { newRowRepo = repo }
+                        onNewRow: { newRow = NewRowRequest(repo: repo, group: $0) }
                     )
                 }
             }
@@ -93,29 +98,43 @@ struct SidebarView: View {
     }
 }
 
-/// A repo's header, its PR warning, its rows, and its other worktrees.
+/// What the New Row sheet opens on: a repo, and the group a group's `+` picked.
+struct NewRowRequest: Identifiable {
+    let repo: RepoSnapshot
+    let group: String?
+
+    var id: String { repo.path }
+}
+
+/// A repo's header, its PR warning, its ungrouped rows, its groups, and its other worktrees.
 struct RepoSection: View {
     @Environment(AppModel.self) private var model
     let repo: RepoSnapshot
     @Binding var isExpanded: Bool
     let isFocused: Bool
-    let onNewRow: () -> Void
+    /// Opens the New Row sheet, on a group or on none.
+    let onNewRow: (String?) -> Void
 
     var body: some View {
         VStack(alignment: .leading, spacing: 0) {
-            RepoHeaderView(repo: repo, onNewRow: onNewRow)
+            RepoHeaderView(repo: repo, onNewRow: { onNewRow(nil) })
             if let warning = repo.pullRequestWarning {
                 RepoWarningView(text: warning)
             }
-            ForEach(repo.rows) { row in
-                RowLineView(
-                    row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
-                    shortcut: model.shortcut(for: row), removable: row.rowClass != .main
-                )
-                .id(row.path)
-                .contextMenu {
-                    if row.isMissing {
-                        Button("Prune Missing Worktrees") { model.prune(repo) }
+            ForEach(repo.rows.filter { $0.group == nil }) { row in
+                line(for: row)
+            }
+            // A missing repo shows no rows, so it shows no groups either.
+            if !repo.isMissing {
+                ForEach(repo.groups) { group in
+                    let rows = repo.rows(inGroup: group.name)
+                    GroupHeaderView(
+                        repo: repo, group: group, count: rows.count, isFocused: isFocused,
+                        onNewRow: { onNewRow(group.name) })
+                    if !group.collapsed {
+                        ForEach(rows) { row in
+                            line(for: row, indent: Style.groupIndent)
+                        }
                     }
                 }
             }
@@ -134,6 +153,14 @@ struct RepoSection: View {
         }
         .padding(.top, 4)
     }
+
+    private func line(for row: Row, indent: Double = 0) -> some View {
+        RowLineView(
+            row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
+            shortcut: model.shortcut(for: row), removable: row.rowClass != .main, indent: indent
+        )
+        .id(row.path)
+    }
 }
 
 struct RepoHeaderView: View {
@@ -141,6 +168,7 @@ struct RepoHeaderView: View {
     let repo: RepoSnapshot
     let onNewRow: () -> Void
     @State private var isHovering = false
+    @State private var isNamingGroup = false
 
     var body: some View {
         HStack(spacing: 8) {
@@ -164,9 +192,9 @@ struct RepoHeaderView: View {
                 Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
                     .controlSize(.small)
                     .help("Find where \(repo.name) moved")
-                RepoMenu(repo: repo, onNewRow: onNewRow)
-            } else if isHovering {
-                RepoMenu(repo: repo, onNewRow: onNewRow)
+                RepoMenu(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true })
+            } else if isHovering || isNamingGroup {
+                RepoMenu(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true })
                 IconButton(title: "New Row in \(repo.name)…", systemImage: "plus", action: onNewRow)
             } else {
                 Text(verbatim: "\(repo.rows.count)")
@@ -183,7 +211,13 @@ struct RepoHeaderView: View {
         .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
         .contentShape(Rectangle())
         .onHover { isHovering = $0 }
-        .contextMenu { RepoMenuItems(repo: repo, onNewRow: onNewRow) }
+        .contextMenu { RepoMenuItems(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true }) }
+        .popover(isPresented: $isNamingGroup, arrowEdge: .trailing) {
+            GroupNamePopover(title: "New Group in \(repo.name)", actionTitle: "Create", isPresented: $isNamingGroup) {
+                name in
+                await model.createGroup(in: repo, name: name)
+            }
+        }
     }
 }
 
@@ -191,24 +225,12 @@ struct RepoHeaderView: View {
 struct RepoMenu: View {
     let repo: RepoSnapshot
     let onNewRow: () -> Void
-    @State private var isHovering = false
+    let onNewGroup: () -> Void
 
     var body: some View {
-        Menu {
-            RepoMenuItems(repo: repo, onNewRow: onNewRow)
-        } label: {
-            Image(systemName: "ellipsis")
-                .font(.system(size: 12, weight: .medium))
+        MoreMenu(help: "More for \(repo.name)") {
+            RepoMenuItems(repo: repo, onNewRow: onNewRow, onNewGroup: onNewGroup)
         }
-        .menuStyle(.button)
-        .buttonStyle(.plain)
-        .menuIndicator(.hidden)
-        .frame(width: 22, height: 22)
-        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
-        .foregroundStyle(isHovering ? .primary : .secondary)
-        .onHover { isHovering = $0 }
-        .help("More for \(repo.name)")
-        .accessibilityLabel("More for \(repo.name)")
     }
 }
 
@@ -216,12 +238,14 @@ struct RepoMenuItems: View {
     @Environment(AppModel.self) private var model
     let repo: RepoSnapshot
     let onNewRow: () -> Void
+    let onNewGroup: () -> Void
 
     var body: some View {
         if repo.isMissing {
             Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
         } else {
             Button("New Row…", action: onNewRow)
+            Button("New Group…", action: onNewGroup)
         }
         Divider()
         Button("Remove Repo from Canopy") { model.removeRepo(repo) }
@@ -235,8 +259,11 @@ struct RowLineView: View {
     let isFocused: Bool
     let shortcut: Int?
     let removable: Bool
+    /// How far a row sits in from its repo's other rows, as inside a group.
+    var indent = 0.0
     @State private var isHovering = false
     @State private var isConfirmingRemove = false
+    @State private var isNamingGroup = false
 
     private var isRunning: Bool { model.terminals.isRunningProgram(inRow: row.path) }
 
@@ -287,12 +314,18 @@ struct RowLineView: View {
                 }
             }
         }
-        .padding(.leading, 7)
+        .padding(.leading, 7 + indent)
         .padding(.trailing, 5)
         .frame(height: Style.rowHeight)
         .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
         .contentShape(Rectangle())
         .onTapGesture { model.selectedRowPath = row.path }
+        .contextMenu { RowMenuItems(row: row, onNewGroup: { isNamingGroup = true }) }
+        .popover(isPresented: $isNamingGroup, arrowEdge: .trailing) {
+            GroupNamePopover(title: "New Group", actionTitle: "Create and Move", isPresented: $isNamingGroup) { name in
+                await model.createGroup(named: name, moving: row)
+            }
+        }
         .onHover { isHovering = $0 }
         // The PR number slides left as the shortcut and remove button come in.
         .animation(.easeOut(duration: 0.12), value: isHovering)
@@ -310,6 +343,7 @@ struct RowLineView: View {
 
     private var accessibilityLabel: String {
         var parts = [row.displayName]
+        if let group = row.group { parts.append("in \(group)") }
         if let tag = row.externalTag { parts.append("from \(tag.label)") }
         if let pr = row.pullRequest { parts.append("pull request \(pr.number), \(pr.state.label)") }
         if isRunning { parts.append("running a program") }
```

`Sources/CanopyApp/Style/Style.swift`:

```diff
@@ -15,6 +15,8 @@ enum Style {
     static let row = Font.system(size: 13)
 
     static let rowHeight = 26.0
+    /// How far a group's rows sit in, so their marks line up under the group's name.
+    static let groupIndent = 24.0
     static let headerHeight = 28.0
     /// The window toolbar's height, so the tabs line up with the traffic lights.
     static let topBarHeight = 52.0
```

`scripts/ui-fixture.sh`:

```diff
@@ -1,7 +1,7 @@
 #!/usr/bin/env bash
 # Opens the dev build on a throwaway home that has something in every part of the window, for UI checks and shots:
-# three repos, rows with open, draft, merged, and closed PRs, other worktrees, running programs, listening ports,
-# and a split tab. Nothing outside the throwaway folder is touched.
+# three repos, rows with open, draft, merged, and closed PRs, two groups, other worktrees, running programs,
+# listening ports, and a split tab. Nothing outside the throwaway folder is touched.
 #
 #   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
 #   scripts/ui-fixture.sh stop           quit it and delete its folder
@@ -84,12 +84,20 @@ for repo in web-app api-server docs; do "$cli" repo add "$work/$repo" >/dev/null
 "$cli" row new feat/onboarding-flow --repo web-app >/dev/null
 "$cli" row new fix/login-redirect --repo web-app >/dev/null
 "$cli" row new feat/checkout-redesign --repo web-app >/dev/null
+"$cli" row new chore/bump-deps --repo web-app >/dev/null
 "$cli" row new feat/rate-limits --repo api-server >/dev/null
+"$cli" group new Review --repo web-app >/dev/null
+"$cli" group new Later --repo web-app >/dev/null
+"$cli" row move feat/checkout-redesign --repo web-app --group Review >/dev/null
+"$cli" row move feat/onboarding-flow --repo web-app --group Review >/dev/null
+"$cli" row move chore/bump-deps --repo web-app --group Later >/dev/null
 git -C "$work/web-app" worktree add -q -b hotfix/cart-total "$work/elsewhere/cart-total"
 git -C "$work/web-app" worktree add -q -b spike/new-parser "$work/elsewhere/new-parser"
 # Remotes come after the rows, so creating the rows does not fetch. The stand-in gh answers for them.
 git -C "$work/web-app" remote add origin https://github.com/acme/web-app.git
 git -C "$work/api-server" remote add origin https://github.com/acme/api-server.git
+"$cli" pr feat/checkout-redesign --repo web-app --refresh >/dev/null
+"$cli" pr feat/rate-limits --repo api-server --refresh >/dev/null || true
 "$cli" row select feat/checkout-redesign --repo web-app >/dev/null
 sleep 1
```

`scripts/ui.swift`:

```diff
@@ -7,7 +7,11 @@
 //   ui type <pid> <text>
 //   ui move <pid> <x> <y>                   points from the window's top-left, as in a window shot divided by 2
 //   ui click <pid> <x> <y> [count]
+//   ui rightclick <pid> <x> <y>             opens a context menu
 //   ui drag <pid> <x1> <y1> <x2> <y2>
+//   ui down <pid> <x> <y>                   press the button and keep it held, for a shot in the middle of a drag
+//   ui drag-to <pid> <x> <y>                move there with the button held, from wherever the pointer is
+//   ui up <pid> <x> <y>                     let go there
 //   ui scroll <pid> <x> <y> <lines>         positive lines scroll up, into the scrollback
 //
 // Keys and text go to the app alone. Pointer events go through the system, so they refuse to run unless the app is
@@ -63,8 +67,8 @@ func post(_ event: CGEvent) {
     usleep(15_000)
 }
 
-func mouse(_ type: CGEventType, at point: CGPoint, clickCount: Int64 = 1) {
-    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
+func mouse(_ type: CGEventType, at point: CGPoint, clickCount: Int64 = 1, button: CGMouseButton = .left) {
+    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
     event.setIntegerValueField(.mouseEventClickState, value: clickCount)
     event.post(tap: .cghidEventTap)
     usleep(20_000)
@@ -121,6 +125,30 @@ case "click":
         mouse(.leftMouseDown, at: point, clickCount: Int64(click))
         mouse(.leftMouseUp, at: point, clickCount: Int64(click))
     }
+case "rightclick":
+    requireFrontmost()
+    let point = windowPoint(2)
+    mouse(.mouseMoved, at: point)
+    mouse(.rightMouseDown, at: point, button: .right)
+    mouse(.rightMouseUp, at: point, button: .right)
+case "down":
+    requireFrontmost()
+    let point = windowPoint(2)
+    mouse(.mouseMoved, at: point)
+    mouse(.leftMouseDown, at: point)
+case "drag-to":
+    requireFrontmost()
+    let from = CGEvent(source: nil)?.location ?? windowPoint(2)
+    let to = windowPoint(2)
+    for step in 1...20 {
+        let t = Double(step) / 20
+        mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
+    }
+case "up":
+    requireFrontmost()
+    let point = windowPoint(2)
+    mouse(.leftMouseDragged, at: point)
+    mouse(.leftMouseUp, at: point)
 case "drag":
     requireFrontmost()
     let from = windowPoint(2)
```

`scripts/window-shot.swift`:

```diff
@@ -1,32 +1,66 @@
-// Captures the main window of a process, even when it is behind other apps or not yet shown. Usage: swift scripts/window-shot.swift <pid> <out.png>
+// Captures the main window of a process, even when it is behind other apps or not yet shown.
+//
+//   swift scripts/window-shot.swift <pid> <out.png>         the main window alone
+//   swift scripts/window-shot.swift <pid> <out.png> --all   the main window with the app's own menus and popovers,
+//                                                          drawn over it, and nothing of any other app
 import CoreGraphics
 import Foundation
+import ImageIO
+import ScreenCaptureKit
+import UniformTypeIdentifiers
 
 let pid = Int32(CommandLine.arguments[1])!
 let output = CommandLine.arguments[2]
-let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
+let withMenus = CommandLine.arguments.dropFirst(3).contains("--all")
 
-// A frontmost app's menu bar strip is also a layer-0 window it owns, so take the largest.
-func area(_ window: [String: Any]) -> Double {
+func bounds(_ window: [String: Any]) -> CGRect {
     let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
-    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
+    return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
+}
+
+func capture(_ number: Int, to path: String) -> Int32 {
+    let capture = Process()
+    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
+    capture.arguments = ["-x", "-o", "-l", String(number), path]
+    try? capture.run()
+    capture.waitUntilExit()
+    return capture.terminationStatus
 }
 
+let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
+let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
+
+// A frontmost app's menu bar strip is also a layer-0 window it owns, so take the largest.
 guard
-    let window =
-        windows
-        .filter({
-            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
-        })
-        .max(by: { area($0) < area($1) }),
-    let number = window[kCGWindowNumber as String] as? Int
+    let main = owned.filter({ ($0[kCGWindowLayer as String] as? Int) == 0 })
+        .max(by: { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }),
+    let mainNumber = main[kCGWindowNumber as String] as? Int
 else {
     FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
     exit(1)
 }
-let capture = Process()
-capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
-capture.arguments = ["-x", "-o", "-l", String(number), output]
-try capture.run()
-capture.waitUntilExit()
-exit(capture.terminationStatus)
+guard withMenus else { exit(capture(mainNumber, to: output)) }
+
+// Menus and popovers are windows of their own that `screencapture -l` cannot take. ScreenCaptureKit draws the app's
+// on-screen windows alone, over the main window's rectangle, so no other app's window can appear.
+let frame = bounds(main)
+let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
+guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
+else {
+    FileHandle.standardError.write(Data("no display shows the window\n".utf8))
+    exit(1)
+}
+let own = content.windows.filter { $0.owningApplication?.processID == pid }
+let filter = SCContentFilter(display: display, including: own)
+let configuration = SCStreamConfiguration()
+configuration.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
+configuration.width = Int(frame.width * CGFloat(filter.pointPixelScale))
+configuration.height = Int(frame.height * CGFloat(filter.pointPixelScale))
+configuration.showsCursor = false
+let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
+guard
+    let destination = CGImageDestinationCreateWithURL(
+        URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
+else { exit(1) }
+CGImageDestinationAddImage(destination, image, nil)
+exit(CGImageDestinationFinalize(destination) ? 0 : 1)
```

- [ ] **Step 2: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 362 tests in 52 suites passed`, no lint findings, and no warnings.

- [ ] **Step 3: Check it in the dev app**

Run: `make app && swiftc -O -o build/ui scripts/ui.swift && scripts/ui-fixture.sh dark`, then the checks this task lists, with `build/ui` and `swift scripts/window-shot.swift <pid> <out.png> --all`, and again with `scripts/ui-fixture.sh light`.
Expected: each check below holds, in both appearances.

- [ ] **Step 4: Commit**

```bash
git add -A Sources scripts Resources
git commit -m "feat: groups in the sidebar"
```

## Task 7: Dragging rows

**Files:** Create `Sources/CanopyApp/Sidebar/RowDragAndDrop.swift`.
Modify `SidebarView.swift`, `AppModel.swift`, `Resources/Info.plist.in`.

**Interfaces:**
- Consumes `RowDrop` from Task 5 and `AppModel.move(_:to:)` from Task 6.
- Produces `UTType.canopyRow` (`com.ne1nn.canopy.row`, declared in `UTExportedTypeDeclarations` and offered with `.ownProcess` visibility), `AppModel.draggedRow`, `isDraggingRowOverList`, and `rowDropTarget`.

Canopy and adopted rows get `.onDrag` with the row's path under `UTType.canopyRow`, and set `model.draggedRow`.
The list holds one drop delegate, which reads every line's frame in the list's coordinate space, asks `RowDrop.target`, draws the indicator, and on drop calls `model.move`.
The dragged row dims while the drag is over the list and drops its hover hints, since hover stops updating during a drag, and the image that follows the pointer is a clean preview of its mark and name.
AppKit scrolls the list near its top and bottom edges during the drag by itself, so the delegate does not.

Checks, each with posted mouse events and confirmed with `canopy row list`:
- onto a header puts the row at the group's end, and the header takes the accent fill;
- the upper half of a grouped row puts the row before it, with an indented line;
- the lower half of an ungrouped row puts the row after it, with a flush line;
- the main row puts the row first among the ungrouped rows;
- another repo shows no indicator and moves nothing;
- the row itself moves nothing;
- holding the drag at the list's bottom and top edges scrolls it;
- each change of group logs one `row.moved` from `ui`.

- [ ] **Step 1: Build it**

`Resources/Info.plist.in`:

```diff
@@ -26,5 +26,18 @@
     <true/>
     <key>NSPrincipalClass</key>
     <string>NSApplication</string>
+    <key>UTExportedTypeDeclarations</key>
+    <array>
+        <dict>
+            <key>UTTypeIdentifier</key>
+            <string>com.ne1nn.canopy.row</string>
+            <key>UTTypeDescription</key>
+            <string>Canopy row</string>
+            <key>UTTypeConformsTo</key>
+            <array>
+                <string>public.data</string>
+            </array>
+        </dict>
+    </array>
 </dict>
 </plist>
```

`Sources/CanopyApp/AppModel.swift`:

```diff
@@ -253,6 +253,13 @@ final class AppModel {
         perform { try await $0.setGroupCollapsed(repoPath: repo.path, name: group.name, collapsed: collapsed) }
     }
 
+    /// The row being dragged in the sidebar, set when its drag starts, so drops only react to Canopy's own rows.
+    var draggedRow: Row?
+    /// Whether that drag is over the repo list, where the row dims in place.
+    var isDraggingRowOverList = false
+    /// Where the dragged row would land, which the list draws.
+    var rowDropTarget: RowDropTarget?
+
     /// Move to Group and drops. A failure shows in a toast.
     func move(_ row: Row, to placement: RowPlacement) {
         perform { _ = try await $0.moveRow(path: row.path, to: placement) }
```

`Sources/CanopyApp/Sidebar/RowDragAndDrop.swift` (new):

```swift
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A row being dragged within the sidebar. Only Canopy can read it, so a drop in another app does nothing.
    static let canopyRow = UTType(exportedAs: "com.ne1nn.canopy.row", conformingTo: .data)
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The repo list, where rows report their frames and drops are placed.
    static var rowList: NamedCoordinateSpace { .named("rowList") }
}

/// Every line a dragged row can land on, with its frame in the repo list.
struct DropSlotsKey: PreferenceKey {
    static let defaultValue: [DropSlot] = []

    static func reduce(value: inout [DropSlot], nextValue: () -> [DropSlot]) {
        value += nextValue()
    }
}

extension View {
    /// Reports this line's frame to the list's drop delegate.
    func dropSlot(repo: String, _ kind: DropSlot.Kind) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .rowList)
                Color.clear.preference(
                    key: DropSlotsKey.self,
                    value: [DropSlot(repoPath: repo, kind: kind, minY: frame.minY, maxY: frame.maxY)])
            }
        }
    }

    /// Lets a Canopy or adopted row be dragged within its repo. The main row and other tools' worktrees stay put.
    @ViewBuilder
    func rowDragSource(_ row: Row, model: AppModel) -> some View {
        if row.rowClass == .canopy || row.rowClass == .adopted {
            onDrag {
                model.draggedRow = row
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.canopyRow.identifier, visibility: .ownProcess
                ) { completion in
                    completion(Data(row.path.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                RowDragPreview(row: row)
            }
        } else {
            self
        }
    }
}

/// What follows the pointer: the row's mark and name, without the hover hints the row itself shows.
struct RowDragPreview: View {
    let row: Row

    var body: some View {
        HStack(spacing: 8) {
            RowMark(row: row)
                .frame(width: 16)
            Text(row.displayName)
                .font(Style.row)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: Style.rowHeight)
        .background(Style.selectionFill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
    }
}

/// Follows a dragged row over the repo list, showing where it would land, and moves it on drop.
struct RowDropDelegate: DropDelegate {
    let model: AppModel
    let slots: [DropSlot]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.canopyRow]) && model.draggedRow != nil
    }

    func dropEntered(info: DropInfo) {
        model.isDraggingRowOverList = true
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: model.rowDropTarget == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        model.isDraggingRowOverList = false
        model.rowDropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            model.isDraggingRowOverList = false
            model.rowDropTarget = nil
            model.draggedRow = nil
        }
        guard let row = model.draggedRow, let target = target(info) else { return false }
        model.move(row, to: target.placement)
        return true
    }

    private func update(_ info: DropInfo) {
        let target = target(info)
        if model.rowDropTarget != target {
            model.rowDropTarget = target
        }
    }

    private func target(_ info: DropInfo) -> RowDropTarget? {
        guard let row = model.draggedRow else { return nil }
        return RowDrop.target(dragging: row, at: info.location.y, in: slots.sorted { $0.minY < $1.minY })
    }
}

/// The line showing where a dragged row would land: accent colored, with a ring at its start, indented to the depth
/// the row would take.
struct RowDropIndicator: View {
    let target: RowDropTarget
    let slots: [DropSlot]

    var body: some View {
        if let (y, indent) = placement {
            GeometryReader { geometry in
                let leading = 7 + indent
                let width = max(geometry.size.width - leading - 4, 0)
                HStack(spacing: 0) {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
                .frame(width: width, height: 7)
                .position(x: leading + width / 2, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    /// Where the line goes down the list, and how far in it starts. A header shows the drop itself instead.
    private var placement: (Double, Double)? {
        let (path, below): (String, Bool)
        switch target.indicator {
        case .header: return nil
        case .above(let above): (path, below) = (above, false)
        case .below(let under): (path, below) = (under, true)
        }
        guard let slot = slots.first(where: { $0.kind.rowPath == path }) else { return nil }
        let indent = if case .row(_, group: _?) = slot.kind { Style.groupIndent } else { 0.0 }
        return (below ? slot.maxY : slot.minY, indent)
    }
}

extension DropSlot.Kind {
    var rowPath: String? {
        switch self {
        case .main(let path), .row(let path, _): path
        case .header: nil
        }
    }
}
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```diff
@@ -7,6 +7,8 @@ struct SidebarView: View {
     @State private var newRow: NewRowRequest?
     /// Repos whose other worktrees are shown.
     @State private var expanded: Set<String> = []
+    /// Where each line a dragged row can land sits in the list.
+    @State private var dropSlots: [DropSlot] = []
     @FocusState private var isFocused: Bool
 
     var body: some View {
@@ -64,6 +66,14 @@ struct SidebarView: View {
                     )
                 }
             }
+            .coordinateSpace(.rowList)
+            .onPreferenceChange(DropSlotsKey.self) { dropSlots = $0 }
+            .overlay(alignment: .topLeading) {
+                if let target = model.rowDropTarget {
+                    RowDropIndicator(target: target, slots: dropSlots)
+                }
+            }
+            .onDrop(of: [.canopyRow], delegate: RowDropDelegate(model: model, slots: dropSlots))
             .padding(.horizontal, 8)
             .padding(.bottom, 8)
             // Fills the column even with no repos, so the empty state gets the whole width.
@@ -130,7 +140,11 @@ struct RepoSection: View {
                     let rows = repo.rows(inGroup: group.name)
                     GroupHeaderView(
                         repo: repo, group: group, count: rows.count, isFocused: isFocused,
-                        onNewRow: { onNewRow(group.name) })
+                        isDropTarget: model.draggedRow?.repoPath == repo.path
+                            && model.rowDropTarget?.indicator == .header(group.name),
+                        onNewRow: { onNewRow(group.name) }
+                    )
+                    .dropSlot(repo: repo.path, .header(group.name))
                     if !group.collapsed {
                         ForEach(rows) { row in
                             line(for: row, indent: Style.groupIndent)
@@ -159,6 +173,7 @@ struct RepoSection: View {
             row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
             shortcut: model.shortcut(for: row), removable: row.rowClass != .main, indent: indent
         )
+        .dropSlot(repo: repo.path, row.rowClass == .main ? .main(row.path) : .row(row.path, group: row.group))
         .id(row.path)
     }
 }
@@ -267,6 +282,9 @@ struct RowLineView: View {
 
     private var isRunning: Bool { model.terminals.isRunningProgram(inRow: row.path) }
 
+    /// Hover stops updating during a drag, so the row being dragged drops its hover look itself.
+    private var isDragged: Bool { model.isDraggingRowOverList && model.draggedRow?.path == row.path }
+
     var body: some View {
         HStack(spacing: 8) {
             RowMark(row: row)
@@ -289,7 +307,7 @@ struct RowLineView: View {
             if let pr = row.pullRequest {
                 PullRequestNumber(pr: pr)
             }
-            if isHovering || isConfirmingRemove {
+            if (isHovering && !isDragged) || isConfirmingRemove {
                 if let shortcut {
                     Text(verbatim: "⌘\(shortcut)")
                         .font(Style.meta)
@@ -320,6 +338,9 @@ struct RowLineView: View {
         .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
         .contentShape(Rectangle())
         .onTapGesture { model.selectedRowPath = row.path }
+        .rowDragSource(row, model: model)
+        // The dragged row dims in place while its image follows the pointer over the list.
+        .opacity(isDragged ? 0.4 : 1)
         .contextMenu { RowMenuItems(row: row, onNewGroup: { isNamingGroup = true }) }
         .popover(isPresented: $isNamingGroup, arrowEdge: .trailing) {
             GroupNamePopover(title: "New Group", actionTitle: "Create and Move", isPresented: $isNamingGroup) { name in
@@ -338,7 +359,7 @@ struct RowLineView: View {
 
     private var fill: Color {
         if isSelected { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
-        return isHovering ? Style.hoverFill : .clear
+        return isHovering && !isDragged ? Style.hoverFill : .clear
     }
 
     private var accessibilityLabel: String {
```

- [ ] **Step 2: Run the suite, lint, and build**

Run: `make test && make lint && make build`
Expected: `✔ Test run with 362 tests in 52 suites passed`, no lint findings, and no warnings.

- [ ] **Step 3: Check it in the dev app**

Run: `make app && swiftc -O -o build/ui scripts/ui.swift && scripts/ui-fixture.sh dark`, then the checks this task lists, with `build/ui` and `swift scripts/window-shot.swift <pid> <out.png> --all`, and again with `scripts/ui-fixture.sh light`.
Expected: each check below holds, in both appearances.

- [ ] **Step 4: Commit**

```bash
git add -A Sources scripts Resources
git commit -m "feat: drag rows into and out of groups"
```

## Task 8: Point the main spec at groups

**Files:** Modify `docs/superpowers/specs/2026-09-27-canopy-design.md` and `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`.

The main spec's "Sidebar order", its command table, and its event table each gain a line pointing at the groups spec.
The groups spec's control table says `row.move` answers with the row and whether it moved.

- [ ] **Step 1: Edit both specs**

`docs/superpowers/specs/2026-09-27-canopy-design.md`:

```diff
@@ -160,6 +160,7 @@ Canopy and adopted rows follow, in the order Canopy first saw them, so new rows
 That order is saved in `state.json`.
 External rows sit in a collapsed "Other worktrees (N)" group at the bottom of the repo.
 Clicking an external row adopts it and selects it.
+Canopy and adopted rows can also be gathered into named groups after the ungrouped rows, as [Row groups](2026-09-28-canopy-row-groups-design.md) describes.
 
 ### Creating a row
 
@@ -500,6 +501,7 @@ Every command exits non-zero on failure.
 | `canopy row rm <branch> [--force] [--delete-branch]` | remove or un-adopt a row |
 | `canopy row select <branch>` | select a row in the UI |
 | `canopy row adopt <path>` | adopt an external worktree |
+| `canopy row move`, `canopy group list\|new\|rename\|rm` | arrange rows in groups, as [Row groups](2026-09-28-canopy-row-groups-design.md) describes |
 | `canopy term list [--all]` | list panes with ID, row, tab, title, folder, and foreground process |
 | `canopy term new [--tab <name> \| --new-tab] [--run <cmd>] [--title <t>]` | add a pane using the add rule and optionally run a command |
 | `canopy term send <id> <text> [--enter]` | write text to a pane, optionally followed by Enter |
@@ -551,6 +553,7 @@ Readers skip a trailing partial line and any line they cannot read.
 | `term.opened`, `term.exited` | a pane's shell starts, including a restart, or exits | `pane`, `code` |
 | `term.command` | a command finishes in a zsh pane | `pane`, `cmd`, `cwd`, `exit`, `durationMs` |
 | `cli.call` | a `canopy` request changes something | `method`, `params`, `error` when it failed |
+| `group.created`, `group.renamed`, `group.removed`, `row.moved` | groups change, as [Row groups](2026-09-28-canopy-row-groups-design.md) describes | |
 
 Row and PR changes are found by comparing each worktree list and each PR lookup with the one before.
 The first one after launching or adding a repo only sets the baseline, so what already existed is not logged.
```

`docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`:

```diff
@@ -275,7 +275,7 @@ With `--json`, `group list` prints an array of groups, and `group new`, `group r
 
 `rows` holds rows in the same form as `row list --json`.
 `group rm` prints the group as it was just before, with the rows it let go of.
-`row move --json` prints the moved row.
+`row move --json` prints the moved row alone.
 
 In text, the commands confirm what they did:
 
@@ -310,7 +310,7 @@ canopy row list --json | jq -r '.[] | select(.group == "Review") | .branch'
 | `group.new` | `target`, `name` | the group |
 | `group.rename` | `target`, `name`, `newName` | the group |
 | `group.remove` | `target`, `name` | the group as it was |
-| `row.move` | `target`, and exactly one of `group`, `noGroup: true`, `before`, `after` | the row |
+| `row.move` | `target`, and exactly one of `group`, `noGroup: true`, `before`, `after` | `row`, `moved`, false for a move that changed nothing, and `from`, the group it was in |
 | `row.new` | gains `group` | as before, its row carrying the group |
 
 `target` is the usual target hint.
```

- [ ] **Step 2: Commit**

```bash
git add docs
git commit -m "docs: point the main spec at row groups"
```

## Decisions Made While Building

Each is listed in the PR under "Decisions to review" too.

- `row.move` answers with the row, whether it moved, and the group it left, so the CLI can say "already in Review" and "out of Review" without a second request; `row move --json` prints the row alone, and the groups spec says so.
- An anchor branch that exists only in another repo is `invalid_anchor`; one that exists nowhere is `row_not_found`.
- A missing repo's snapshot still lists its groups with no rows, so `group list`, `rename`, and `rm` work on it; the sidebar shows none.
- `unadopt` and `removeRow` take the row out of its group themselves, rather than waiting for the next refresh.
- The no-op texts the spec does not give: "X is not in a group." for `--no-group`, and "X is already there." for `--before` and `--after`.
- A grouped row's selection and hover fills keep the full width, and only its content indents.
- Creating a row from the sheet into a collapsed group unfolds it.
- No code scrolls the list during a drag, since AppKit already does.

## After Review

An independent opus review found no blockers, two important issues, and eight minor ones.
One commit, `fix: address review of row groups`, fixes both important issues and six of the minors, each with a test that failed first where one can, and the branch is the reference for it:

- Renaming a group while `row new --group` for it ran gave a result that depended on timing, and warned that the group went away when it had only been renamed.
  `rowsJoiningGroups` now holds the repo and the group, a rename updates it, and the warning only shows when no group of that name is left.
  `aGroupRenamedWhileItsRowIsCreatedStillGetsTheRow` stalls git before and after the worktree exists, and `aRowTakenOutOfItsGroupWhileBeingCreatedGetsNoWarning` covers a row moved out meanwhile.
- Folding a group never animated, because `withAnimation` wrapped a call that only starts a task, and the new snapshot arrives later.
  The chevron and the repo's section now animate on the groups' change itself, which frames shot mid-fold in the dev app confirm.
- Deleting a group of a missing repo logged 0 rows, since the snapshot lists none; the count now comes from the saved group.
- One unreadable group in `state.json` dropped every group; each group now decodes on its own.
- Two groups whose names differed only in case in a hand-edited file lost the second one's rows to the ungrouped rows; they now merge into the first.
- `row new --group` with a missing group waited behind other git work in the repo before failing; it now checks first, and again once it is its turn.
- The group lookup is shared, and `groupInfo` reads the snapshot once.

Two minors stay:

- `group rename` prints the name as it was typed, such as "Renamed review to Code review." when the group was "Review".
- SwiftUI's `onDrag` gives no signal when a drag ends, so the dragged row stops dimming once the pointer leaves the list, and `draggedRow` stays set after a cancelled drag until the next drag replaces it.

A row moved out of its group while it is still being created logs its `row.moved` before its `row.created`, which only a move of a half-made row can cause.

### A flake that is not from this branch

Full `make test` runs failed about once in seven while other sessions built on the machine (load average 15 and up), always in the control socket tests, with "Canopy closed the connection before replying."
It also failed on the plan commit, which has `main`'s Swift.
Logging showed the client's `read` fails with `EBADF` on its own socket while the descriptor is still open: the client's `close` right after succeeds.
Tracing every `close` in Canopy's code and tests showed none touched that descriptor, and a stress test starting and stopping 300 listeners beside 600 requests failed none.
It is written up for a separate fix.
