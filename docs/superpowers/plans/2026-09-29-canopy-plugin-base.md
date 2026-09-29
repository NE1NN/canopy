# Canopy Plugin Base Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Canopy gains plugins that do nothing until `config.json` turns them on, rows that plugins own, worktree rows linked to a plugin's item, and the `canopy plugin` commands, with a fixture plugin that exercises all of it.

**Architecture:** `CanopyCore/Plugins` holds the `CanopyPlugin` interface and its value types, plugin config, the secret store, and `PluginHost`, a main-actor coordinator beside `RowLifecycle` that starts plugins, creates and removes their rows, and routes their control methods.
The `Workspace` actor keeps plugin rows and links in `state.json` and publishes each plugin's section in the same snapshot as the repos, so the sidebar, `⌘1` to `⌘9`, target resolution, and `canopy row list` all read one source.
The fixture plugin is its own library target, `CanopyFixturePlugin`, built only on CanopyCore's public API, the way the Tickets plugin will be.
CanopyApp draws the section, the picker sheet, and the detail area with a panel slot, and keeps the table from plugin id to panel view.

**Tech Stack:** Swift 6.2 in Swift 6 language mode, SwiftUI and AppKit, Swift Testing, the Security framework's generic passwords, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md` ("Plugin base", "Delivery" item 2, "Error handling", "Testing"), with the Tickets sections read for what the interface must support.
Sidebar conventions come from `docs/superpowers/specs/2026-09-28-canopy-row-groups-design.md`, and everything else from `docs/superpowers/specs/2026-09-27-canopy-design.md`.

## Global Constraints

- A plugin that is off adds nothing: no sidebar section, no rows in `row list`, no target resolution, no `start` call, no timers.
- Plugin row identity is its folder, `CANOPY_HOME/plugins/<plugin>/<folder name>`, with `-2`, `-3` appended if it exists, created with mode 0700.
- `state.json` gains a top-level `plugins` object: per plugin `rows` (`item`, `title`, `path`, in sidebar order), `links` (worktree row path to item), and `panelWidth`.
  An older `state.json` without `plugins` loads as having none, and a `plugins` value that cannot be read is dropped on its own.
- Pane variables in a plugin row: `CANOPY_ROW` is the row's title, `CANOPY_ROW_PATH` its folder, `CANOPY_PLUGIN` the plugin's id, `CANOPY_ITEM` the row's item, and `CANOPY_REPO` and `CANOPY_ROOT_PATH` are not set.
- Plugin rows have no setup or teardown.
- Removing a plugin row closes its terminals, asking first if any runs a program (`--force` skips), moves its folder to the Trash, forgets the row, and logs `plugin.row.removed`.
  Links to its item stay.
- A folder deleted outside Canopy is recreated and filled again at launch and before a terminal opens in it.
- `row.new` takes an optional `link` of a plugin and a reference.
  With none, the CLI sends `CANOPY_PLUGIN` and `CANOPY_ITEM` as the link when it runs in a plugin row.
  A reference the plugin cannot resolve fails the request before git runs.
- A link is saved under the plugin's `links`, keyed by the worktree row's path, and is dropped when that row goes away.
- The linked worktree row shows the item's short label before its PR badge while the item's plugin row exists, and clicking it selects the plugin row.
- Sections go below the repos in built-in order; the header is a tile with the plugin's symbol, its name, and its row count, which gives way on hover to `…` and `+`.
- A plugin row's line reads: the plugin's symbol, the title, the accessories, then the running or agent dot; hover shows the shortcut and an `x`.
- Plugin rows drag within their section only.
- `⌘1` to `⌘9` and the arrow keys take plugin rows after every repo's rows, in section order.
- The panel sits at the left of the detail area, 340 points wide by default, dragged between 260 points and half the detail area, with its width saved per plugin, and the top bar starts at its right edge.
- The picker is one sheet for every plugin: a search field, the plugin's filter chips, a list with a title, subtitle, accessories, and an "In row" mark, a spinner while items load, a plugin's error with its fix in place of the list, and the equivalent `canopy` command in the footer.
- `plugin.enable` and `plugin.disable` write the plugin's section of `config.json` through a temp file and an atomic rename, keeping every other key as it was; a write that fails changes nothing.
- At launch each built-in plugin whose section is present and does not say `"enabled": false` starts; a plugin whose `start` fails still shows its section and rows, with the failure as the section's warning.
- Secrets are generic passwords in the login Keychain, service `<bundle id>.plugins.<plugin id>`, account `<name>@<CANOPY_HOME>`, behind `SecretStore` with an in-memory store for tests.
- Activity events: `plugin.enabled` and `plugin.disabled` with `plugin`; `plugin.row.created` and `plugin.row.removed` with `plugin` and `item`; events about a plugin row leave `repo` out, set `row` to the title and `path` to the folder, and add `plugin` and `item` to `data`; `row.created` gains `link`.
- `plugin.list` and each plugin's reading methods join the methods `cli.call` leaves out, and a `token` param is never written to the activity log.
- Tests never touch the real Keychain, the network, or the user's Trash.
- The fixture plugin is on only in a dev build launched with `CANOPY_FIXTURE_PLUGIN=1`, and only while `config.json` turns it on.
- Swift 6 strict concurrency with no warnings, `swift format lint --strict` clean, and `Text(verbatim:)` for numbers and paths.
- Markdown: one sentence per line, no em dashes.

## Review Focus

1. Two requests for the same item at once, such as a double click in the picker while an agent runs `canopy plugin new`: exactly one row and one folder exist afterwards, and the other request fails with `item_has_row` naming it.
   `aSecondRowForTheSameItemFailsAndLeavesNoFolder` in Task 6 pins it.
2. A plugin row's folder deleted while its terminals run, then a new terminal opened in it: the folder comes back with the plugin's files before the shell starts, rather than the shell starting in the home folder.
   `aMissingFolderIsRecreatedBeforeATerminalOpens` in Task 6 and the e2e case in Task 13.
3. Turning a plugin off while an agent runs in one of its rows: it refuses without `--force`, and with it the terminals close, the rows and their saved layouts come back when the plugin is turned on again.
   `turningOffRefusesWhileProgramsRunUnlessForced` in Task 6 and `layoutsOfAnOffPluginWaitForItToComeBack` in Task 11.
4. A hand-edited `config.json` with unknown keys, a key order of its own, and no trailing newline: enabling a plugin changes only its section and keeps the rest byte for byte where it can; a file that is not JSON makes `plugin.enable` fail and nothing changes.
   `enableKeepsEveryOtherKeyAndItsOrder` and `aFileThatIsNotJSONIsLeftAlone` in Task 1.
5. `canopy row new` run in a plugin row whose item the plugin no longer knows: it fails before git runs, with the plugin's error, and `--no-link` gets the row made without a link.
   `anUnresolvableLinkFailsBeforeGitRuns` in Task 7 and `rowNewSendsTheLinkOfThePluginRowItRunsIn` in Task 8.

## File Structure

- Create `Sources/CanopyCore/Plugins/CanopyPlugin.swift`: the `CanopyPlugin` protocol, `PluginInfo`, `PluginFilter`, `PluginFilters`, `PluginQuery`, `PluginItem`, `PluginRowSeed`, `PluginCall`, and the protocol's defaults.
- Create `Sources/CanopyCore/Plugins/PluginRow.swift`: `PluginRow`, `PluginRowLook`, `PluginAccessory`, `PluginColor`, `PluginLink`, `PluginSection`, and `SidebarRow`.
- Create `Sources/CanopyCore/Plugins/PluginConfig.swift`: reading `plugins` from `config.json`, and `PluginConfigFile`, which writes one plugin's section.
- Create `Sources/CanopyCore/Support/JSONFile.swift`: the compare-and-rename JSON editor, moved out of `ClaudeSettingsFile`.
- Modify `Sources/CanopyCore/Agents/ClaudeHooks.swift`: `ClaudeSettingsFile` uses `JSONFile`.
- Create `Sources/CanopyCore/Plugins/SecretStore.swift`: `SecretStore`, `KeychainSecretStore`, `MemorySecretStore`, and `PluginSecrets`.
- Create `Sources/CanopyCore/Plugins/FolderTrash.swift`: `FolderTrash` and `SystemTrash`.
- Create `Sources/CanopyCore/Plugins/PluginState.swift`: `PluginEntry` and `PluginRowEntry` as `state.json` holds them.
- Modify `Sources/CanopyCore/State/AppState.swift`: `plugins`.
- Create `Sources/CanopyCore/Workspace/Workspace+Plugins.swift`: plugin rows, looks, warnings, sections, links, and panel widths in the workspace.
- Modify `Sources/CanopyCore/Workspace/Workspace.swift` and `WorkspaceSnapshot.swift`: the plugin sections in the snapshot, links on rows, and links reconciled on refresh.
- Modify `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift` and `Workspace+PullRequestRows.swift`: `createRow(... link:)`.
- Modify `Sources/CanopyCore/Rows/Row.swift`: `link`.
- Modify `Sources/CanopyCore/Terminal/TerminalIDs.swift`, `PaneEnvironment.swift`, `Pane.swift`, `TerminalStore.swift`: `PaneContext.Owner`, plugin row variables, and plugin row events.
- Modify `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`, `RowLifecycle+Ports.swift`, `Control/TermMethods.swift`, `Control/PortMethods.swift`: plugin rows' terminals and ports.
- Create `Sources/CanopyCore/Plugins/PluginContext.swift` and `Sources/CanopyCore/Plugins/PluginHost.swift`.
- Create `Sources/CanopyCore/Control/PluginMethods.swift`: `plugin.*` method names, params, and results.
- Modify `Sources/CanopyCore/Control/TargetResolver.swift`, `ControlMethods.swift`, `WorkspaceControlHandler.swift`, `Workspace/WorkspaceError.swift`.
- Modify `Sources/CanopyCore/Activity/ActivityEvent.swift` and `ActivityReader.swift`: the plugin events and their summaries.
- Create `Sources/CanopyCore/Plugins/PluginPicker.swift`: the picker sheet's state.
- Create `Sources/CanopyCore/Rows/PluginRowDrop.swift`: where a dragged plugin row lands.
- Create `Sources/CanopyFixturePlugin/FixturePlugin.swift` and `FixtureItems.swift`, and add the target in `Package.swift`.
- Create `Sources/CanopyCLI/PluginCommand.swift`; modify `CanopyCLI.swift`, `RowCommand.swift`, `TermCommand.swift`, `PortsCommand.swift`, `AgentGuide.swift`.
- Create `Sources/CanopyApp/Plugins/BuiltInPlugins.swift`, `PluginSectionView.swift`, `PluginRowViews.swift`, `PluginPickerSheet.swift`, `PluginDetailView.swift`, `LinkedRowsView.swift`, and `Fixture/FixturePanel.swift`.
- Modify `Sources/CanopyApp/AppModel.swift`, `CanopyApp.swift`, `RootView.swift`, `Sidebar/SidebarView.swift`, `Sidebar/RowDragAndDrop.swift`, `Sidebar/PortsPanel.swift`, `Terminal/RowTerminalsView.swift`, `Terminal/TopBarView.swift`.
- Modify `scripts/e2e.sh` and `scripts/ui-fixture.sh`.
- Modify `docs/superpowers/specs/2026-09-27-canopy-design.md` and `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md`.
- Tests in `Tests/CanopyCoreTests`: `PluginConfigTests`, `SecretStoreTests`, `PluginStateTests`, `PluginLinkTests`, `PluginTerminalTests`, `PluginHostTests`, `PluginControlTests`, `PluginPickerTests`, `FixturePluginTests`, `PluginRowDropTests`, and `Support/TestPlugin.swift`; `TargetResolverTests`, `ActivityReaderTests`, `ClaudeSettingsTests`, and `WorkspaceGroupTests` gain cases.

---

## Task 1: Plugin types, plugin config, and one JSON file editor

**Files:**
- Create: `Sources/CanopyCore/Plugins/CanopyPlugin.swift`, `Sources/CanopyCore/Plugins/PluginRow.swift`, `Sources/CanopyCore/Plugins/PluginConfig.swift`, `Sources/CanopyCore/Support/JSONFile.swift`
- Modify: `Sources/CanopyCore/Agents/ClaudeHooks.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/PluginConfigTests.swift`, `Tests/CanopyCoreTests/ClaudeSettingsTests.swift` (unchanged, must stay green)

**Interfaces:**
- Produces the value types every later task uses:

```swift
/// What names a plugin. Its id names its config section, its folder, its control methods, and its events.
public struct PluginInfo: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// An SF Symbol for its section's tile and its rows.
    public var symbol: String
}

public struct PluginFilter: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
}

/// The picker's chips. At most one choice narrows the list, such as Mine or Anyone. Each toggle that is on changes
/// which items are fetched, such as Closed.
public struct PluginFilters: Sendable, Equatable, Codable {
    public var choices: [PluginFilter]
    public var defaultChoice: String?
    public var toggles: [PluginFilter]
    public static let none: PluginFilters
}

public struct PluginQuery: Sendable, Equatable {
    public var text: String
    public var choice: String?
    public var toggles: Set<String>
    /// True when the picker opens or a toggle changes, so a plugin that keeps what it fetched fetches again.
    public var fresh: Bool
}

/// One of a plugin's items, as the picker and `canopy plugin items` list it.
public struct PluginItem: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var accessories: [PluginAccessory]
    /// The row the item already has, which the host fills in. Written as null when there is none.
    public var row: PluginRow?
}

/// A new row's title, fixed from then on, and the name its folder starts from.
public struct PluginRowSeed: Sendable, Equatable {
    public var title: String
    public var folderName: String
}

/// A control method call routed to a plugin.
public struct PluginCall: Sendable {
    public var method: String
    public var params: JSONValue
    /// Where the CLI ran, from the params' `target`.
    public var target: TargetHint
    /// The plugin's row the target points at, when the command ran in one or named one.
    public var row: PluginRow?
    public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T
}

public protocol CanopyPlugin: Sendable {
    var info: PluginInfo { get }
    var filters: PluginFilters { get }
    /// Control methods it answers, each its id and a dot first, such as `tickets.list`. They reach it while it is off,
    /// so a method such as `tickets.connect` can turn it on.
    var methods: Set<String> { get }
    /// Those of `methods` that only read, which the activity log leaves out.
    var readOnlyMethods: Set<String> { get }

    func start(_ context: PluginContext) async throws
    func stop(_ context: PluginContext) async
    /// One line for `canopy plugin list`, such as "connected as me@example.com, updated 20 s ago".
    func status(_ context: PluginContext) async -> String?
    func items(matching query: PluginQuery, context: PluginContext) async throws -> [PluginItem]
    /// The item an agent's reference names, such as `853` for a ticket's id.
    func resolve(_ reference: String, context: PluginContext) async throws -> String
    func seed(for item: String, context: PluginContext) async throws -> PluginRowSeed
    /// Writes the row's files into its folder, which exists when this is called.
    func fill(_ row: PluginRow, context: PluginContext) async throws
    /// The picker footer's command for an item, or nil for `canopy plugin new <id> <item> --select`.
    func pickerCommand(for item: PluginItem) -> String?
    func handle(_ call: PluginCall, context: PluginContext) async throws -> JSONValue
}
```

- Defaults in an extension: `filters` is `.none`, `methods` and `readOnlyMethods` are empty, `stop` does nothing, `status` is nil, `pickerCommand` is nil, and `handle` throws `unknown_method`.
- Row types, in `PluginRow.swift`:

```swift
public enum PluginColor: String, Sendable, Codable, CaseIterable {
    case gray, red, orange, yellow, green, blue, purple, accent
}

/// A mark the sidebar and the picker know how to draw. A plugin never draws into the sidebar itself.
public struct PluginAccessory: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case dot, tag, initials }
    public var kind: Kind
    /// The tag's text or the initials.
    public var text: String?
    public var color: PluginColor
    /// What it means, for hover and VoiceOver, such as "Customer waiting".
    public var help: String
    public static func dot(_ color: PluginColor, help: String) -> PluginAccessory
    public static func tag(_ text: String, help: String) -> PluginAccessory
    public static func initials(_ text: String, color: PluginColor, help: String) -> PluginAccessory
}

public struct PluginRowLook: Sendable, Equatable {
    /// Shown in place of the saved title, which CANOPY_ROW and the log keep using.
    public var title: String?
    /// Such as `#0853`, which linked worktree rows show.
    public var label: String?
    public var accessories: [PluginAccessory]
    /// The plugin no longer has the item.
    public var isMissing: Bool
    public static let plain: PluginRowLook
}

public struct PluginRow: Sendable, Equatable, Identifiable, Codable {
    public var plugin: String
    public var item: String
    public var title: String
    public var path: String
    public var look: PluginRowLook
    public var id: String { path }
    public var displayName: String { look.title ?? title }
    public var isMissing: Bool { look.isMissing }
}

/// A worktree row's tie to a plugin's item.
public struct PluginLink: Sendable, Equatable, Codable {
    public var plugin: String
    public var item: String
}
```

- `PluginRow` codes as `{"plugin", "item", "title", "path", "missing"}` plus `"label"` when it has one, so `row list --json` carries what the spec lists.
- Config, in `PluginConfig.swift`:

```swift
public enum PluginConfig {
    /// Each plugin's section of config.json's `plugins`. A missing file has none. Throws for a file that is not JSON.
    public static func sections(in file: URL) throws -> [String: JSONValue]
    /// On when the section is present and does not say `"enabled": false`.
    public static func isOn(_ section: JSONValue?) -> Bool
}

public struct PluginConfigFile: Sendable {
    public let url: URL
    /// Merges `fields` into the plugin's section, drops `"enabled": false`, and returns the section as written.
    public func enable(_ plugin: String, fields: [String: JSONValue]) throws -> JSONValue
    /// Sets `"enabled": false` in the plugin's section, keeping the rest of it.
    public func disable(_ plugin: String) throws -> JSONValue
}
```

- `JSONFile` (moved from `ClaudeSettingsFile`): `read() throws -> OrderedJSON`, and `update(_ transform: (OrderedJSON) throws -> OrderedJSON) throws -> Bool`, which writes beside the file, renames over it only if the file still holds what it read, follows symbolic links, keeps the file's permissions and trailing newline, and throws `JSONFileError.unreadable(reason)` or `.writeFailed(reason)`.
  `ClaudeSettingsFile` maps them to `settingsInvalid` and `settingsWriteFailed` as today, and `PluginConfigFile` to new `configInvalid(path, reason)` (`config_invalid`) and `configWriteFailed(path, reason)` (`config_write_failed`).
  A new file is written with mode 0600, since config.json sits in the private home folder.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PluginConfigTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct PluginConfigTests {
    @Test func aPluginIsOnWhenItsSectionIsThereAndNotDisabled() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try #"{"minPaneColumns": 90, "plugins": {"a": {}, "b": {"enabled": false, "url": "x"}, "c": {"enabled": true}}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let sections = try PluginConfig.sections(in: file)

        #expect(PluginConfig.isOn(sections["a"]))
        #expect(!PluginConfig.isOn(sections["b"]))
        #expect(PluginConfig.isOn(sections["c"]))
        #expect(!PluginConfig.isOn(sections["d"]))
    }

    @Test func noFileMeansNoPlugins() throws {
        let dir = try TempDir()
        #expect(try PluginConfig.sections(in: URL(fileURLWithPath: dir.sub("config.json"))).isEmpty)
    }

    @Test func enableKeepsEveryOtherKeyAndItsOrder() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        let original = """
            {
              "logCommands": false,
              "plugins": {
                "other": {"x": 1e2},
                "tickets": {"enabled": false, "run": "claude"}
              },
              "zeta": [1, 2]
            }
            """
        try original.write(to: file, atomically: true, encoding: .utf8)

        let section = try PluginConfigFile(url: file).enable("tickets", fields: ["url": "https://a.convex.site"])

        #expect(section == .object(["run": "claude", "url": "https://a.convex.site"]))
        #expect(
            try String(contentsOf: file, encoding: .utf8) == """
                {
                  "logCommands": false,
                  "plugins": {
                    "other": {
                      "x": 1e2
                    },
                    "tickets": {
                      "run": "claude",
                      "url": "https://a.convex.site"
                    }
                  },
                  "zeta": [
                    1,
                    2
                  ]
                }
                """)
    }

    @Test func disableKeepsTheRestOfTheSection() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try #"{"plugins": {"tickets": {"url": "u"}}}"#.write(to: file, atomically: true, encoding: .utf8)

        _ = try PluginConfigFile(url: file).disable("tickets")

        let sections = try PluginConfig.sections(in: file)
        #expect(sections["tickets"] == .object(["url": "u", "enabled": false]))
    }

    @Test func enablingMakesTheFileWhenThereIsNone() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))

        _ = try PluginConfigFile(url: file).enable("fixture", fields: [:])

        #expect(try PluginConfig.sections(in: file)["fixture"] == .object([:]))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func aFileThatIsNotJSONIsLeftAlone() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try "{not json".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: WorkspaceError.self) { try PluginConfigFile(url: file).enable("fixture", fields: [:]) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{not json")
    }

    @Test func aFolderThatCannotBeWrittenFailsWithTheFileSystemsMessage() throws {
        let dir = try TempDir()
        let folder = dir.sub("locked")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try #"{"a": 1}"#.write(toFile: folder + "/config.json", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }

        #expect {
            try PluginConfigFile(url: URL(fileURLWithPath: folder + "/config.json")).enable("fixture", fields: [:])
        } throws: { error in
            (error as? WorkspaceError)?.code == "config_write_failed"
        }
        #expect(try String(contentsOfFile: folder + "/config.json", encoding: .utf8) == #"{"a": 1}"#)
    }

    @Test func pluginRowsCodeWhatAgentsRead() throws {
        var row = PluginRow(plugin: "tickets", item: "k5", title: "0853-sam", path: "/h/plugins/tickets/0853-sam")
        row.look = PluginRowLook(label: "#0853", accessories: [.dot(.orange, help: "Waiting")])
        let json = try JSONValue.from(row)
        #expect(
            json == .object([
                "plugin": "tickets", "item": "k5", "title": "0853-sam", "path": "/h/plugins/tickets/0853-sam",
                "label": "#0853", "missing": false,
            ]))
        #expect(try json.decode(PluginRow.self).look.label == "#0853")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter PluginConfigTests`
Expected: FAIL, `PluginConfig` and `PluginRow` are not defined.

- [ ] **Step 3: Write the types and the editor**

`JSONFile` takes the body of `ClaudeSettingsFile.update`, `target`, `contents(of:)`, and `write(_:to:replacing:)` unchanged, parameterized by a `validate: (OrderedJSON) throws -> OrderedJSON` (the settings check for Claude Code, an object check for config.json) and a mode for new files.
`PluginConfigFile.enable` is `update { settings in var plugins = settings["plugins"] ?? .object([]); var section = plugins[plugin] ?? .object([]); for (key, value) in fields.sorted(by: key) { section[key] = OrderedJSON(value) }; section["enabled"] = nil; ... }`, where a section that is not an object is replaced by one.
`OrderedJSON` gains `init(_ value: JSONValue)` and `var value: JSONValue` for the conversion both ways.

- [ ] **Step 4: Run the tests to see them pass, with the Claude settings tests**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginConfigTests|ClaudeSettingsTests|ClaudeHookTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: plugin types and plugin config"
```

## Task 2: Secrets and the Trash behind interfaces

**Files:**
- Create: `Sources/CanopyCore/Plugins/SecretStore.swift`, `Sources/CanopyCore/Plugins/FolderTrash.swift`
- Test: `Tests/CanopyCoreTests/SecretStoreTests.swift`

**Interfaces:**

```swift
public protocol SecretStore: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    /// Deleting a secret that is not there succeeds.
    func delete(service: String, account: String) throws
}

public struct SecretStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int32
    /// The Keychain's own words, such as "The user name or passphrase you entered is not correct."
    public var description: String
}

/// Generic passwords in the login Keychain, readable only by this app's signature.
public struct KeychainSecretStore: SecretStore { public init() }

/// For tests and previews, which must never touch the Keychain.
public final class MemorySecretStore: SecretStore { public init() }

/// One plugin's secrets. The account names CANOPY_HOME, so a dev build and each test home never read another's.
public struct PluginSecrets: Sendable {
    public let service: String
    public init(store: any SecretStore, bundleID: String, plugin: String, home: CanopyHome)
    public func read(_ name: String) throws -> String?
    public func write(_ value: String, for name: String) throws
    public func delete(_ name: String) throws
    public func account(_ name: String) -> String
}

public protocol FolderTrash: Sendable {
    /// Moves the folder to the Trash and returns where it went.
    func trash(_ folder: URL) throws -> URL?
}

public struct SystemTrash: FolderTrash { public init() }
```

- `KeychainSecretStore` uses `SecItemCopyMatching`, `SecItemUpdate` then `SecItemAdd` on `errSecItemNotFound`, and `SecItemDelete`, with `kSecClassGenericPassword`, `kSecAttrService`, and `kSecAttrAccount`, and turns any other status into `SecretStoreError` with `SecCopyErrorMessageString`.
- `MemorySecretStore` holds a `Mutex<[String: String]>` keyed by service and account.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import CanopyCore

struct SecretStoreTests {
    @Test func secretsAreKeptPerPluginAndPerHome() throws {
        let store = MemorySecretStore()
        let dev = PluginSecrets(
            store: store, bundleID: "com.ne1nn.Canopy.dev", plugin: "tickets", home: CanopyHome(path: "/h/dev"))
        let other = PluginSecrets(
            store: store, bundleID: "com.ne1nn.Canopy.dev", plugin: "tickets", home: CanopyHome(path: "/h/other"))

        try dev.write("secret", for: "token")

        #expect(dev.service == "com.ne1nn.Canopy.dev.plugins.tickets")
        #expect(dev.account("token") == "token@/h/dev")
        #expect(try dev.read("token") == "secret")
        #expect(try other.read("token") == nil)
        try dev.delete("token")
        try dev.delete("token")
        #expect(try dev.read("token") == nil)
    }

    @Test func writingAgainReplacesTheSecret() throws {
        let secrets = PluginSecrets(
            store: MemorySecretStore(), bundleID: "b", plugin: "p", home: CanopyHome(path: "/h"))
        try secrets.write("one", for: "token")
        try secrets.write("two", for: "token")
        #expect(try secrets.read("token") == "two")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter SecretStoreTests`
Expected: FAIL, `MemorySecretStore` is not defined.

- [ ] **Step 3: Write the stores and the trash**

`SystemTrash.trash` is `var result: NSURL?; try FileManager.default.trashItem(at: folder, resultingItemURL: &result); return result as URL?`.
Tests get a `MovingTrash(into:)` in `Support/TestPlugin.swift` (Task 6), so the real Trash is never touched.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter SecretStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Plugins Tests/CanopyCoreTests/SecretStoreTests.swift
git commit -m "feat: a secret store for plugins, with the Keychain and one in memory"
```

## Task 3: Plugin rows in state.json and the snapshot

**Files:**
- Create: `Sources/CanopyCore/Plugins/PluginState.swift`, `Sources/CanopyCore/Workspace/Workspace+Plugins.swift`
- Modify: `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `Sources/CanopyCore/Workspace/WorkspaceSnapshot.swift`, `Sources/CanopyCore/Plugins/PluginRow.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/PluginStateTests.swift`, `Tests/CanopyCoreTests/WorkspaceGroupTests.swift` (visible rows)

**Interfaces:**

```swift
public struct PluginRowEntry: Codable, Sendable, Equatable {
    public var item: String
    public var title: String
    public var path: String
}

/// A plugin's part of state.json. It stays while the plugin is off, so turning it back on brings its rows back.
public struct PluginEntry: Codable, Sendable, Equatable {
    /// In sidebar order.
    public var rows: [PluginRowEntry]
    /// Items linked to worktree rows, keyed by the worktree row's path.
    public var links: [String: String]
    public var panelWidth: Double?
}

/// A plugin's section of the sidebar, as the snapshot carries it. Off plugins are listed too, with `isOn` false, so
/// their rows' saved layouts wait for them.
public struct PluginSection: Sendable, Equatable, Identifiable {
    public var info: PluginInfo
    public var isOn: Bool
    /// Why the plugin is not working, with the fix, as markdown.
    public var warning: String?
    public var rows: [PluginRow]
    public var panelWidth: Double?
    public var id: String { info.id }
}

/// A line of the sidebar that can be selected.
public enum SidebarRow: Sendable, Equatable, Identifiable, Codable {
    case worktree(Row)
    case plugin(PluginRow)
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var worktree: Row?
    public var pluginRow: PluginRow?
}
```

- `SidebarRow` codes as the row it holds, and decodes a `PluginRow` when the object has `"plugin"`.
- `AppState.plugins: [String: PluginEntry]`, decoded with `try?` as a whole and leniently per entry, and per row.
- `WorkspaceSnapshot` gains `plugins: [PluginSection]` and:

```swift
public var activePlugins: [PluginSection] { get }
/// Rows that get ⌘1 to ⌘9, in sidebar order: every repo's visible rows, then the rows of each plugin that is on.
public var visibleRows: [SidebarRow] { get }
public func steppingRow(from path: String?, offset: Int) -> SidebarRow?
/// A worktree row, or a row of a plugin that is on.
public func sidebarRow(path: String) -> SidebarRow?
/// A row of a plugin that is on.
public func pluginRow(path: String) -> PluginRow?
public func pluginRow(plugin: String, item: String) -> PluginRow?
public func section(_ plugin: String) -> PluginSection?
```

- `Workspace` gains, in `Workspace+Plugins.swift`:

```swift
public func registerPlugins(_ infos: [PluginInfo])
public func setPlugin(_ id: String, on: Bool)
public func setPluginWarning(_ id: String, _ warning: String?)
/// Replaces the looks of the plugin's rows at these paths. Paths that are not its rows are ignored.
public func setPluginLooks(_ looks: [String: PluginRowLook], plugin id: String)
/// Fails with `item_has_row` when the item already has a row.
public func addPluginRow(_ entry: PluginRowEntry, plugin id: String) throws -> PluginRow
public func removePluginRow(path: String) throws -> PluginRow
/// `.before` or `.after` another row of the same plugin. Returns whether it moved.
public func movePluginRow(path: String, to placement: RowPlacement) throws -> Bool
public func setPluginPanelWidth(_ width: Double, plugin id: String) throws
```

- New errors: `itemHasRow(item: String, row: String)` (`item_has_row`: "That item already has a row at <path>. Run \`canopy row select <path>\` to show it."), `pluginNotFound(String)` (`plugin_not_found`), `pluginOff(String, id: String)` (`plugin_off`: "<Name> is off. Run \`canopy plugin enable <id>\`."), and `notPluginRowAnchor(String)`, which reuses `invalid_anchor` with "--before and --after take another row of the same plugin".

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PluginStateTests.swift` covers:
- `anOlderStateWithoutPluginsLoads`: a `state.json` with only `version` and `repos` decodes with `plugins` empty, and one written back has an empty `plugins` object.
- `unknownPluginsAreKept`: an entry for a plugin no build has survives a load and a save.
- `anUnreadablePluginsValueIsDroppedAlone`: `"plugins": 7` loads the repos and drops only the plugins, and one bad row is dropped while the others load.
- `aPluginThatIsOffShowsNothing`: after `registerPlugins` and `addPluginRow`, the snapshot's section has the row, `activePlugins` is empty, and `sidebarRow(path:)` and `visibleRows` leave it out until `setPlugin(on: true)`.
- `rowsKeepTheirOrderAndLooks`: three rows added, the middle one moved `.before` the first, looks set for two, a look for a path that is not the plugin's ignored, and the order and looks read back; a relaunch keeps the order.
- `aSecondRowForTheSameItemIsRefused`: `addPluginRow` for an item that has a row throws `.itemHasRow(item:row:)` naming the first row.
- `movesOnlyWithinTheSection`: `.group`, `.ungrouped`, the row itself, and another plugin's row as anchors each throw.
- `removingForgetsTheRowButKeepsLinks`: `removePluginRow` returns the row, clears it if selected, and leaves `links` as they were.
- `panelWidthIsSavedPerPlugin`.

`WorkspaceGroupTests.visibleRowsSkipCollapsedGroups` gains a plugin section and checks `visibleRows` ends with its rows, and that `steppingRow` goes from the last repo row into the first plugin row and back.

```swift
@Test func aPluginThatIsOffShowsNothing() async throws {
    let dir = try TempDir()
    let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: Fixture.git)
    try await workspace.start()
    await workspace.registerPlugins([PluginInfo(id: "p", name: "P", symbol: "star")])
    let row = try await workspace.addPluginRow(
        PluginRowEntry(item: "i1", title: "one", path: dir.sub("home/plugins/p/one")), plugin: "p")

    var snapshot = await workspace.snapshot
    #expect(snapshot.plugins.map(\.rows) == [[row]])
    #expect(snapshot.activePlugins.isEmpty)
    #expect(snapshot.sidebarRow(path: row.path) == nil)
    #expect(snapshot.visibleRows.isEmpty)

    await workspace.setPlugin("p", on: true)
    snapshot = await workspace.snapshot
    #expect(snapshot.sidebarRow(path: row.path) == .plugin(row))
    #expect(snapshot.visibleRows == [.plugin(row)])
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginStateTests|WorkspaceGroupTests'`
Expected: FAIL, `registerPlugins` is not defined.

- [ ] **Step 3: Write the state and the workspace methods**

The workspace keeps `pluginInfos: [PluginInfo]`, `pluginsOn: Set<String>`, `pluginWarnings: [String: String]`, and `pluginLooks: [String: PluginRowLook]` in memory, and `state.plugins` on disk.
`snapshot` builds one `PluginSection` per registered plugin, in registered order, from `state.plugins[info.id]`, applying `pluginLooks[path] ?? .plain` to each row.
Every change that touches `state.plugins` saves and publishes; looks, warnings, and on or off only publish.
`visibleRows` becomes `repos.flatMap { $0.visibleRows.map(SidebarRow.worktree) } + activePlugins.flatMap { $0.rows.map(SidebarRow.plugin) }`, and `steppingRow` walks the same list, with the hidden-row rule for collapsed groups kept for worktree rows.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginStateTests|WorkspaceGroupTests|StateStoreTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: plugin rows in state.json and the workspace snapshot"
```

## Task 4: Links between worktree rows and plugin items

**Files:**
- Modify: `Sources/CanopyCore/Rows/Row.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `Workspace+RowLifecycle.swift`, `Workspace+PullRequestRows.swift`, `Workspace+Plugins.swift`, `WorkspaceSnapshot.swift`
- Test: `Tests/CanopyCoreTests/PluginLinkTests.swift`

**Interfaces:**
- `Row.link: PluginLink?`, coded as `"link"` and left out when nil, set in `snapshot` from every plugin's `links`, off plugins included.
- `createRow(repoPath:branch:base:existing:group:link:)` and `createRow(repoPath:pullRequest:branch:group:link:)` take `link: PluginLink?` (already resolved).
  The link is saved with the row's place in the repo, and `row.created` carries `"link": {"plugin", "item"}` in `data`.
- `WorkspaceSnapshot.linkedRows(plugin: String, item: String) -> [Row]`, in sidebar order.
- Links are reconciled on each refresh that git answers: a link whose path is under the repo's Canopy folder or in its adopted list, and is no longer one of its Canopy or adopted rows, is dropped.
  Un-adopting a row drops its link, and so does removing a repo.
  A missing repo, or a worktree list git fails to give, changes nothing.

- [ ] **Step 1: Write the failing tests**

- `aLinkedRowCarriesItsLinkAndLogsIt`: `createRow(... link: PluginLink(plugin: "p", item: "i1"))` returns a row with the link, `snapshot.linkedRows(plugin: "p", item: "i1")` lists it, `state.json` has `plugins.p.links[path] == "i1"`, and the `row.created` event's `data.link` is `{"plugin": "p", "item": "i1"}`.
- `aPullRequestRowCanBeLinkedToo`: through `LocalGitHub`, like `PullRequestRowTests`.
- `theLinkGoesWhenTheRowGoes`: removing the row with `removeRow`, and in a second case with plain `git worktree remove` and a refresh, drops the link.
- `aLinkOutlivesARelaunchUntilItsRowIsGone`: the row removed with plain git while the workspace is stopped loses its link on the next start's refresh.
- `aMissingRepoKeepsItsLinks`: the repo's folder moved away keeps the link.
- `unadoptingDropsTheLink`.
- `linksStayWhenThePluginRowGoes`: `removePluginRow` for the item leaves the link.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter PluginLinkTests`
Expected: FAIL, `createRow` has no `link` parameter.

- [ ] **Step 3: Thread the link through**

`addRow` takes `link: PluginLink?`, keeps it in `rowsBeingLinked[path]` beside `rowsJoiningGroups`, and saves it in `state.plugins[link.plugin].links[path]` in the same save that places the row.
`finishChanging` adds `data["link"]` to the `row.created` it logs when `rowsBeingLinked` has the path, then forgets it.
`refreshNow` calls `reconcileLinks(entry:managed:)` after the group reconcile, and saves when it dropped any.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginLinkTests|RowActivityTests|WorkspaceGroupTests|PullRequestRowTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: link worktree rows to a plugin's items"
```

## Task 5: Terminals and ports in plugin rows

**Files:**
- Modify: `Sources/CanopyCore/Terminal/TerminalIDs.swift`, `PaneEnvironment.swift`, `Pane.swift`, `TerminalStore.swift`, `Sources/CanopyCore/Rows/RowLifecycle+Terminals.swift`, `RowLifecycle+Ports.swift`, `Sources/CanopyCore/Control/TermMethods.swift`, `PortMethods.swift`
- Test: `Tests/CanopyCoreTests/PluginTerminalTests.swift`, `PaneEnvironmentTests.swift`, `TerminalActivityTests.swift`

**Interfaces:**

```swift
public struct PaneContext: Sendable, Equatable {
    public enum Owner: Sendable, Equatable {
        case repo(name: String, path: String)
        case plugin(id: String, item: String)
    }
    public var owner: Owner
    public var rowName: String
    public var rowPath: String
    public init(row: Row, repoName: String)
    public init(pluginRow: PluginRow)
    public init(_ row: SidebarRow, repoName: String)
    public var repoName: String? { get }
    public var repoPath: String? { get }
}
```

- `PaneEnvironment.build` sets `CANOPY_REPO` and `CANOPY_ROOT_PATH` for a repo owner, and `CANOPY_PLUGIN` and `CANOPY_ITEM` for a plugin owner.
- `Pane.record` leaves `repo` out for a plugin owner and adds `plugin` and `item` to `data`, so `term.*` and `agent.*` events follow the spec.
- `TerminalTab.repoPath` becomes optional; `closeRowsGone`, `closeRows(ofRepo:)`, `moveRows(ofRepo:to:)`, and `followRowNames` leave plugin rows alone.
- `RowLifecycle.newTerminal(_ context: PaneContext, _ params: TermNewParams)` replaces `newTerminal(_:repoName:_:)`.
- `TermInfo.repo` becomes `String?`, and `TermInfo` and `PortInfo` gain `plugin: String?`; both leave out the key they have no value for.
- `portGroups()` attributes ports to the rows of plugins that are on too, after the repos' rows.

- [ ] **Step 1: Write the failing tests**

- `PaneEnvironmentTests.aPluginRowsPanesKnowItsPluginAndItem`: the environment has `CANOPY_ROW`, `CANOPY_ROW_PATH`, `CANOPY_PLUGIN`, `CANOPY_ITEM`, and neither `CANOPY_REPO` nor `CANOPY_ROOT_PATH`, even when the app's own environment had them.
- `PluginTerminalTests.aShellInAPluginRowStartsInItsFolderWithItsVariables`: a real bash pane in a plugin context prints `$CANOPY_PLUGIN $CANOPY_ITEM ${CANOPY_REPO-unset} $PWD`.
- `PluginTerminalTests.eventsAboutAPluginRowNameItsPluginAndItem`: `term.opened` and `term.exited` for the pane have no `repo`, `row` is the title, `path` the folder, and `data` has `plugin` and `item`.
- `PluginTerminalTests.pluginRowsAreLeftAloneWhenReposChange`: `closeRowsGone` with a snapshot that has no plugin rows keeps the plugin row's tabs.
- `PluginTerminalTests.termListNamesThePluginNotARepo`: `terminalInfo` gives `repo == nil` and `plugin == "p"` for the pane, and its JSON has no `repo` key.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginTerminalTests|PaneEnvironmentTests'`
Expected: FAIL, `PaneContext(pluginRow:)` is not defined.

- [ ] **Step 3: Write the owner and its uses**

- [ ] **Step 4: Run the terminal tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginTerminalTests|PaneEnvironmentTests|TerminalActivityTests|TerminalStoreTests|CommandLoggingTests|PortAttributionTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: terminals and ports in plugin rows"
```

## Task 6: The plugin host and each plugin's context

**Files:**
- Create: `Sources/CanopyCore/Plugins/PluginContext.swift`, `Sources/CanopyCore/Plugins/PluginHost.swift`, `Tests/CanopyCoreTests/Support/TestPlugin.swift`
- Modify: `Sources/CanopyCore/Activity/ActivityEvent.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/PluginHostTests.swift`

**Interfaces:**

```swift
/// What the window shows, which plugins pace their refreshes by.
public struct PluginViewing: Sendable, Equatable {
    public var isWindowVisible: Bool
    public var isFrontmost: Bool
}

/// What a plugin watches: its rows, its row on screen, and whether the window can be seen.
public struct PluginState: Sendable, Equatable {
    public var isOn: Bool
    public var rows: [PluginRow]
    /// The plugin's row the window shows, if one is selected.
    public var selectedRow: PluginRow?
    public var viewing: PluginViewing
}

public struct PluginRowCreated: Sendable, Equatable, Codable {
    public var row: PluginRow
    /// The terminal started for `run`.
    public var pane: String?
    /// Why the plugin could not fill the folder. The row stays, and `run` is skipped.
    public var fillError: String?
}

public struct PluginRowRemoved: Sendable, Equatable, Codable {
    public var row: PluginRow
    /// Where the folder went in the Trash, or nil when it was already gone.
    public var trashedTo: String?
}

/// One plugin's way into Canopy, made once and kept while Canopy runs, on or off.
@MainActor
public final class PluginContext {
    public nonisolated let info: PluginInfo
    /// CANOPY_HOME/plugins/<id>, made with mode 0700 when first needed.
    public nonisolated let folder: URL
    public nonisolated let secrets: PluginSecrets
    public nonisolated let activity: ActivityLog
    /// Its section of config.json, an empty object while it has none.
    public var config: JSONValue { get }
    public var state: PluginState { get }
    /// The current state at once, then each change.
    public func states() -> AsyncStream<PluginState>
    public func setLooks(_ looks: [String: PluginRowLook]) async
    public func setWarning(_ warning: String?) async
    public func linkedRows(item: String) -> [Row]
    public func turnOn(with fields: [String: JSONValue]) async throws
    public func turnOff(force: Bool) async throws
    public func createRow(for reference: String, run: String?, select: Bool) async throws -> PluginRowCreated
    public func removeRow(_ row: PluginRow, force: Bool) async throws -> PluginRowRemoved
    public func select(_ row: PluginRow) async
}

public struct PluginListing: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var on: Bool
    public var status: String?
    public var warning: String?
    public var rows: Int
    public var filters: PluginFilters
}

@MainActor
public final class PluginHost {
    public nonisolated let workspace: Workspace
    public let terminals: TerminalStore
    public let plugins: [any CanopyPlugin]
    /// Selects rows for `select`, as the control API does. The app sets it.
    public var ui: (any ControlUIBridge)?
    /// Something worth a toast, such as a folder the plugin could not fill again.
    public var onNotice: (String) -> Void
    /// Called with the paths of rows about to close because their plugin turned off, so the app keeps their layouts.
    public var onClosingRows: ([String]) -> Void
    public var viewing: PluginViewing

    public init(
        workspace: Workspace, terminals: TerminalStore, plugins: [any CanopyPlugin], secrets: any SecretStore,
        bundleID: String, trash: any FolderTrash = SystemTrash())

    /// Registers the plugins, starts the ones config.json turns on, and recreates their rows' missing folders.
    public func start() async
    public func stop() async
    public func context(_ id: String) -> PluginContext?
    public func list() async -> [PluginListing]
    public func enable(_ id: String, with fields: [String: JSONValue] = [:]) async throws -> PluginListing
    public func disable(_ id: String, force: Bool) async throws -> PluginListing
    /// The plugin's items, each with the row it already has.
    public func items(_ id: String, matching query: PluginQuery) async throws -> [PluginItem]
    public func createRow(_ id: String, reference: String, run: String?, select: Bool) async throws -> PluginRowCreated
    public func removeRow(_ row: PluginRow, force: Bool) async throws -> PluginRowRemoved
    /// Makes the row's folder again and lets its plugin fill it, if the folder is gone.
    public func ensureFolder(_ row: PluginRow) async
    public func resolveLink(plugin: String, reference: String) async throws -> PluginLink
    public var readOnlyMethods: Set<String> { get }
    public func handles(_ method: String) -> Bool
    public func call(_ method: String, params: JSONValue, row: PluginRow?) async throws -> JSONValue
}
```

- New activity types: `plugin.enabled`, `plugin.disabled`, `plugin.row.created`, `plugin.row.removed`.
- New errors: `rowBusy(String, programs: [String])` (`row_busy`), `pluginBusy(String, id: String, programs: [String])` (`plugin_busy`), `trashFailed(String, reason: String)` (`trash_failed`), `folderFailed(String, reason: String)` (`folder_failed`).
- `Support/TestPlugin.swift` holds `actor TestPlugin: CanopyPlugin` with an item list, a start error, a fill error, a `stall` for fills, and a record of calls, and `struct MovingTrash: FolderTrash` that moves folders into a test folder.

Creating a row, in order:

1. The plugin must be known and on, else `plugin_not_found` or `plugin_off`.
2. `resolve` the reference, then refuse with `item_has_row` if the item has a row.
3. `seed` the item, which may fail with the plugin's error, so an unknown item creates nothing.
4. Make the folder: the seed's folder name with `/` and `:` made `-`, leading dots and spaces trimmed, `row` if nothing is left, and `-2`, `-3`, and so on while `mkdir` finds one there, with mode 0700.
5. `addPluginRow`, which refuses a second row for the item; the folder made in step 4 is removed then.
6. `fill`; a failure keeps the row and is returned as `fillError`.
7. Log `plugin.row.created`.
8. Select it when asked, then, unless the fill failed, open a tab in it and type `run`.

Removing a row: refuse with `row_busy` while one of its panes runs a program unless `force`, close its terminals, move its folder to the Trash if it is there, `removePluginRow`, log `plugin.row.removed`.

Turning on: write the section, mark the plugin on, `start` it, show a failure as the warning, recreate missing folders, and log `plugin.enabled` if it was off.
Enabling a plugin that is on restarts it with the new section and logs nothing.
Turning off: refuse with `plugin_busy` while a program runs in one of its rows unless `force`, write `"enabled": false`, tell `onClosingRows`, close the rows' terminals, `stop` it, mark it off, clear its warning, and log `plugin.disabled`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PluginHostTests.swift`, every test with a temporary home, `MemorySecretStore`, and `MovingTrash`:

- `aPluginWithNoSectionStaysOff`: no `start` call, `list()` says off, and the snapshot's `activePlugins` is empty.
- `aPluginInConfigStartsWithItsSection`: `{"plugins": {"t": {"x": 1}}}` starts it with `context.config == {"x": 1}`.
- `aPluginThatFailsToStartShowsItsRowsAndWhy`: its section is on with its rows, and the warning is the error's message.
- `createsARowFromTheSeedIntoItsOwnFolder`: the folder is `home/plugins/t/<name>` with mode 0700, filled, the row is last in the section, and `plugin.row.created` has no `repo`, `row` is the title, `path` the folder, and `data` is `{"plugin": "t", "item": "i1"}`.
- `anUnknownItemCreatesNothing`: `seed` throwing leaves no folder and no row.
- `aTakenFolderNameGetsASuffix`: two items seeding `same` get `same` and `same-2`, and a folder named `x/../y` stays inside the plugin's folder.
- `aSecondRowForTheSameItemFailsAndLeavesNoFolder`: two `createRow` calls for one item, the second while the first's `fill` stalls, give one row, one folder, and `item_has_row`.
- `aFillThatFailsKeepsTheRowAndSkipsRun`.
- `runStartsInANewTerminalInTheRow` and `selectIsPassedToTheUI`.
- `removingClosesTerminalsTrashesTheFolderAndLogs`: the tabs are gone, the folder is in the trash folder, the result says where, the row is gone, and `plugin.row.removed` is logged.
- `removingARowWithABusyTerminalAsksFirst`: a pane running `sleep 30` fails with `row_busy` naming `sleep`, and `force` removes it.
- `aMissingFolderIsRecreatedAtStart`: a row whose folder was deleted gets it back, filled, after `start`.
- `aMissingFolderIsRecreatedBeforeATerminalOpens`: `ensureFolder` makes and fills it.
- `enableWritesConfigStartsAndLogs` and `enablingAgainRestartsWithTheNewSection`.
- `turningOffRefusesWhileProgramsRunUnlessForced`: `plugin_busy`, then with `force` the terminals close, `onClosingRows` got their paths, `stop` ran, the section is off, `config.json` says `"enabled": false`, and `plugin.disabled` is logged.
- `aConfigThatCannotBeWrittenChangesNothing`.
- `theStateStreamFollowsRowsSelectionAndViewing`: the first value has the rows, then a new row, a selection of the plugin's row, and `viewing` each yield a new state, and a selection of a worktree row gives `selectedRow == nil`.
- `looksAndWarningsReachTheSnapshot`.
- `itemsSayWhichRowEachHas`.
- `methodsReachThePluginEvenWhileOff` and `aCallGetsTheRowItsTargetPointsAt`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter PluginHostTests`
Expected: FAIL, `PluginHost` is not defined.

- [ ] **Step 3: Write the context and the host**

The host subscribes to `workspace.updates()` in `start`, keeps the latest snapshot, and yields each plugin's `PluginState` to its context's subscribers when it changes.
`PluginContext` holds a weak reference to the host and forwards to it.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter PluginHostTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: the plugin host, which starts plugins and creates and removes their rows"
```

## Task 7: Plugin rows in the control API

**Files:**
- Create: `Sources/CanopyCore/Control/PluginMethods.swift`
- Modify: `Sources/CanopyCore/Control/TargetResolver.swift`, `ControlMethods.swift`, `WorkspaceControlHandler.swift`, `GroupMethods.swift`
- Test: `Tests/CanopyCoreTests/PluginControlTests.swift`, `TargetResolverTests.swift`, `ControlServerTests.swift` (the handler's new init)

**Interfaces:**

```swift
public enum PluginMethod {
    public static let list = "plugin.list"
    public static let enable = "plugin.enable"
    public static let disable = "plugin.disable"
    public static let items = "plugin.items"
    public static let new = "plugin.new"
}

public struct PluginRefParams: Codable, Sendable { public var plugin: String }
public struct PluginEnableParams: Codable, Sendable { public var plugin: String; public var fields: [String: JSONValue] }
public struct PluginDisableParams: Codable, Sendable { public var plugin: String; public var force: Bool }
/// `filters` are ids of the plugin's choices and toggles; at most one may be a choice.
public struct PluginItemsParams: Codable, Sendable {
    public var plugin: String; public var query: String?; public var filters: [String]
}
public struct PluginNewParams: Codable, Sendable {
    public var plugin: String; public var reference: String; public var run: String?; public var select: Bool
}

/// `row.new`'s link: a plugin and a reference it resolves.
public struct RowLinkParams: Codable, Sendable, Equatable { public var plugin: String; public var reference: String }
```

- `TargetResolver.sidebarRow(for:in:) throws -> SidebarRow`: an explicit path matches worktree rows, then rows of plugins that are on; a branch name matches worktree rows only; `CANOPY_ROW_PATH` and the folder the CLI runs in match both, the deepest folder winning.
- `WorkspaceControlHandler.init(rows: RowLifecycle, plugins: PluginHost, ui: any ControlUIBridge)`.
- `row.list` lists plugin rows after the repos' rows, unless `repo` is given, as `[SidebarRow]`.
- `row.select`, `row.remove`, and `row.move` take plugin rows; `RowRemoveResult` gains `trashedTo`, and its `row`, like `row.select`'s and `RowMoveResult`'s, is a `SidebarRow`.
- `row.remove` on a plugin row goes through `PluginHost.removeRow`, with `force`, and refuses `deleteBranch`.
- `row.move` on a plugin row takes only `before` and `after`, naming another row of the same plugin by path.
- `row.new` gains `link: RowLinkParams?`, resolved through the host before any git work.
- `term.list`, `term.new`, `ports.list`, and `ports.stop` resolve plugin rows; `term.new` ensures the folder first.
- `pr.show` on a plugin row fails with `no_pr_lookup`.
- Methods a plugin declares go to `PluginHost.call` with the target's plugin row.
- `cli.call` skips `ControlMethod.readOnly` plus `plugin.list`, `plugin.items`, and the plugins' read-only methods, and removes every `token` key in the params, at any depth, before logging.
- Reply timeouts: `plugin.new` waits without a limit, like `row.new`; `plugin.items` and `plugin.enable` 90 seconds.

- [ ] **Step 1: Write the failing tests**

`TargetResolverTests` gains a plugin section with a row at `/h/plugins/p/one`:
- `aPluginRowResolvesByPathEnvironmentAndFolder`.
- `aBranchNameNeverMatchesAPluginRow`.
- `aPluginThatIsOffResolvesNothing`.
- `aPluginRowIsNotARepo`: `repo(for: TargetHint(cwd: "/h/plugins/p/one"))` fails with `missing_target`.

`PluginControlTests`, through the in-process server with a `TestPlugin`:
- `listEnableAndDisableOverTheSocket`.
- `itemsTakeFiltersByIdAndRefuseUnknownOnes`: two choices fail with `bad_params`, and so does an unknown id.
- `newRowSelectAndRemoveAPluginRow`: `plugin.new` with `run` and `select`, `row.list` has it last with `plugin`, `item`, `title`, and `path`, `row.select` with its path selects it, and `row.remove` trashes it.
- `aSecondNewForTheItemNamesTheRow`: `item_has_row`.
- `rowListWithARepoLeavesPluginRowsOut`.
- `termNewAndListInAPluginRowFromItsFolder`: `term.new` with `cwd` inside the folder opens a pane there, and `term.list` names the plugin.
- `pluginRowsMoveOnlyBeforeOrAfterEachOther`.
- `anUnresolvableLinkFailsBeforeGitRuns`: `row.new` with a link the plugin refuses fails with its code and makes no worktree and no branch.
- `aLinkedRowNewLogsTheLink`.
- `pluginMethodsGetTheirTargetRow`.
- `readOnlyPluginMethodsAreNotLoggedAndTokensNeverAre`: `plugin.list` and the plugin's read-only method leave no `cli.call`, and a call with `{"token": "s3cret", "nested": {"token": "x"}}` is logged without either token.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginControlTests|TargetResolverTests'`
Expected: FAIL, `TargetResolver.sidebarRow` is not defined.

- [ ] **Step 3: Write the methods and the routing**

- [ ] **Step 4: Run the control tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginControlTests|TargetResolverTests|ControlServerTests|GroupControlTests|AgentControlTests|ControlProtocolTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: plugin rows and plugin methods in the control API"
```

## Task 8: `canopy plugin`, plugin rows in `canopy row`, and the agent guide

**Files:**
- Create: `Sources/CanopyCLI/PluginCommand.swift`
- Modify: `Sources/CanopyCLI/CanopyCLI.swift`, `RowCommand.swift`, `TermCommand.swift`, `PortsCommand.swift`, `AgentGuide.swift`, `Sources/CanopyCore/Activity/ActivityReader.swift`, `Sources/CanopyCore/Control/ControlMethods.swift`
- Test: `Tests/CanopyCoreTests/ActivityReaderTests.swift`, `Tests/CanopyCoreTests/PluginControlTests.swift`

**Interfaces:**
- `canopy plugin list`: `PLUGIN  ON  ROWS  STATUS`, with the warning on a line of its own under a plugin that has one, and "No plugins." when the build has none.
- `canopy plugin enable <plugin>` and `canopy plugin disable <plugin> [--force]`: "Turned on Fixture." and "Turned off Fixture.", with the warning if starting failed.
- `canopy plugin items <plugin> [--query <text>] [--filter <id>]...`: `ITEM  TITLE  DETAILS  ROW`, where ROW is the row's path or `-`.
- `canopy plugin new <plugin> <reference> [--run <cmd>] [--select]`: "Opened fx-2 in <path>.", then "Running <cmd> in <pane>.", and on a fill error the error on stderr and exit 1.
- `canopy row list` prints each plugin that is on and has rows after the repos' table: a blank line, then a table whose first header is the plugin's name in capitals, then ITEM and PATH.
  `--json` prints worktree and plugin rows in one array.
- `canopy row new` sends `link` from `CANOPY_PLUGIN` and `CANOPY_ITEM` when both are set, unless `--no-link`.
- `canopy row rm`, `select`, and `move` print a plugin row by its title, and `row rm` says where the folder went: "Removed fx-2. Its folder is in the Trash at <path>."
- `canopy log` summarizes `plugin.enabled` and `plugin.disabled` as the plugin's id, and `plugin.row.*` as `<plugin> <item>`, and `--type plugin` matches all four.
- The agent guide gains a "Plugin rows" section.

- [ ] **Step 1: Write the failing tests**

- `ActivityReaderTests.summarizesPluginEvents`.
- `PluginControlTests.rowNewSendsTheLinkOfThePluginRowItRunsIn` builds the CLI's params with `RowCommand.New.linkParams(environment:noLink:)` and checks both the link and `--no-link`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'ActivityReaderTests|PluginControlTests'`
Expected: FAIL.

- [ ] **Step 3: Write the commands**

- [ ] **Step 4: Run the tests to see them pass, and build the CLI**

Run: `swift test $(scripts/test-flags.sh) --filter 'ActivityReaderTests|PluginControlTests' && swift build --product canopy`
Expected: PASS, and the build has no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/CanopyCoreTests
git commit -m "feat: canopy plugin, and plugin rows in canopy row"
```

## Task 9: The fixture plugin

**Files:**
- Create: `Sources/CanopyFixturePlugin/FixturePlugin.swift`, `Sources/CanopyFixturePlugin/FixtureItems.swift`
- Modify: `Package.swift`
- Test: `Tests/CanopyCoreTests/FixturePluginTests.swift`

**Interfaces:**
- `public actor FixturePlugin: CanopyPlugin` with `public init()`, id `fixture`, name "Fixture", symbol `shippingbox`.
- Items: six made-up ones, `fx-1` to `fx-6`, with every accessory kind, two open ones sharing the folder name `same`, and two closed ones that only the Closed toggle lists.
- Filters: choices All (default) and Waiting, and a Closed toggle.
- References: an id such as `fx-2`, its number such as `2`, or its slug such as `beta`, in any case; anything else is `item_not_found`.
- Seed: title and folder name are the item's slug.
- Fill: writes `item.md` with the item's title and subtitle, rewritten only when it changes.
- Looks: label `#<number>`, the item's accessories, and missing for items the config's `missing` list or `fixture.missing` names.
- Config: `warning` becomes the section's warning, `failStart` makes `start` throw with that text, and `missing` lists items the fixture pretends are gone.
- Status: "<n> made-up items, <m> rows".
- Control methods: `fixture.remember` (`token`), `fixture.recall` (read-only), `fixture.forget`, `fixture.where` (read-only, the target's row), `fixture.warn` (`text` or none), and `fixture.missing` (`item`, `missing`).

- [ ] **Step 1: Write the failing tests**

- `listsItemsByChoiceToggleAndSearch`.
- `resolvesIdsNumbersAndSlugs`.
- `seedsAndFillsARow`.
- `setsEveryKindOfAccessoryAndALabel`.
- `showsItsConfigsWarningAndCanFailToStart`.
- `remembersATokenInItsSecrets`.
- `whereAnswersWithTheTargetsRow`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter FixturePluginTests`
Expected: FAIL, no module `CanopyFixturePlugin`.

- [ ] **Step 3: Write the fixture**

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter FixturePluginTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CanopyFixturePlugin Tests/CanopyCoreTests/FixturePluginTests.swift
git commit -m "feat: a fixture plugin that exercises the plugin base"
```

## Task 10: The picker's model, and where a dragged plugin row lands

**Files:**
- Create: `Sources/CanopyCore/Plugins/PluginPicker.swift`, `Sources/CanopyCore/Rows/PluginRowDrop.swift`
- Test: `Tests/CanopyCoreTests/PluginPickerTests.swift`, `Tests/CanopyCoreTests/PluginRowDropTests.swift`

**Interfaces:**

```swift
public enum PluginPickerAction: Sendable, Equatable {
    /// `canopy plugin new <plugin> <item> --select`, or the plugin's own command.
    case create(PluginItem)
    /// `canopy row select <path>`.
    case select(PluginRow)
}

@MainActor
@Observable
public final class PluginPicker {
    public init(
        plugin: PluginInfo, filters: PluginFilters,
        items: @escaping @Sendable (PluginQuery) async throws -> [PluginItem],
        command: @escaping @Sendable (PluginItem) -> String?)
    public var text: String
    public var choice: String?
    public private(set) var toggles: Set<String>
    public func setToggle(_ id: String, _ on: Bool)
    /// Nil while the first load runs.
    public var shownItems: [PluginItem]? { get }
    public var isLoading: Bool { get }
    /// The plugin's error, with its fix, in place of the list.
    public var error: String? { get }
    public var selectedItem: PluginItem? { get }
    public var selectedAction: PluginPickerAction? { get }
    public func load() async
    public func select(_ id: String?)
    public func moveSelection(by offset: Int)
    public func command(for action: PluginPickerAction) -> String
}

public struct PluginDropSlot: Sendable, Equatable {
    public var plugin: String
    public var path: String
    public var minY: Double
    public var maxY: Double
}

public enum PluginRowDrop {
    /// The upper half of another row of the same plugin puts the dragged row before it, the lower half after it.
    public static func target(dragging row: PluginRow, at y: Double, in slots: [PluginDropSlot]) -> RowDropTarget?
}
```

- The picker loads with `fresh` true when it opens and when a toggle changes, and false for text and choice changes.
  A newer query's answer always wins over an older one's, however they arrive.
  It keeps showing the last items while a new query loads, and selects the first item once text is typed.

- [ ] **Step 1: Write the failing tests**

- `PluginPickerTests.opensFreshAndNarrowsWithoutFetching`.
- `aTogglesChangeFetchesAgain`.
- `anOlderAnswerNeverReplacesANewerOne`.
- `showsAPluginsErrorInPlaceOfTheList`.
- `anItemWithARowSelectsIt`.
- `commandsSayWhatAPickDoes`: `canopy plugin new fixture fx-2 --select`, a plugin's own command, and `canopy row select '/h/plugins/fixture/my row'`.
- `PluginRowDropTests.dropsBeforeAndAfterRowsOfTheSamePlugin`, with another plugin's row and the dragged row itself refused.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginPickerTests|PluginRowDropTests'`
Expected: FAIL.

- [ ] **Step 3: Write the picker and the drop**

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test $(scripts/test-flags.sh) --filter 'PluginPickerTests|PluginRowDropTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore Tests/CanopyCoreTests
git commit -m "feat: the plugin picker's model, and dropping plugin rows"
```

## Task 11: Plugin sections in the sidebar

**Files:**
- Create: `Sources/CanopyApp/Plugins/BuiltInPlugins.swift`, `PluginSectionView.swift`, `PluginRowViews.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`, `CanopyApp.swift`, `Sidebar/SidebarView.swift`, `Sidebar/RowDragAndDrop.swift`, `Sidebar/PortsPanel.swift`
- Test: none in CanopyCore beyond what Tasks 3 to 10 cover; checked by clicking through (UI Checks)

**Interfaces:**

```swift
/// The app's one list of built-in plugins, each with the panel it draws for a row.
@MainActor
struct BuiltInPlugin {
    let plugin: any CanopyPlugin
    let panel: (PluginRow) -> AnyView
}

enum BuiltInPlugins {
    /// The fixture only in a dev build launched with CANOPY_FIXTURE_PLUGIN=1.
    @MainActor static func make(environment: [String: String]) -> [BuiltInPlugin]
}
```

- `AppModel` owns a `PluginHost`, starts it after the workspace and before layouts are restored, keeps `host.viewing` in step with the window, and passes it to `WorkspaceControlHandler`.
- `AppModel.selection: SidebarRow?`, `context(for: SidebarRow)`, and `shortcut(for: SidebarRow)`; tabs, splits, and focus act on the selection; selecting a plugin row ensures its folder before its first tab opens.
- Layouts of an off plugin's rows wait in `deferredTerminals`, and `onClosingRows` moves live ones there before they close.
- `PluginSectionView`: the header like `RepoHeaderView`, with a tile of the plugin's symbol, the warning under it, and the rows.
  Its `…` menu holds New Row… and Turn Off <Name>, which asks first while programs run.
- `PluginRowLineView`: symbol, title, accessories, the agent or running dot, and on hover the shortcut and an `x` that opens a remove popover; a missing item shows the "missing" tag with its `x` always shown.
- Plugin rows drag within their section, through `PluginRowDrop`.
- A worktree row with a link whose plugin row exists shows the label as a chip before its PR badge; clicking it selects the plugin row.
- The ports panel names a plugin row with the plugin's symbol.

- [ ] **Step 1: Build the views and wiring**

- [ ] **Step 2: Build with no warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:" ; test ${PIPESTATUS[0]} -eq 0`
Expected: no output.

- [ ] **Step 3: Check it in a dev build with the fixture**

Run: `make app && scripts/ui-fixture.sh dark` (after Task 13's fixture changes, or with a hand-written `config.json` until then).
Expected: the Fixture section under the repos, with its warning, rows with every accessory kind, and a linked row's chip.

- [ ] **Step 4: Commit**

```bash
git add Sources/CanopyApp
git commit -m "feat: plugin sections in the sidebar"
```

## Task 12: The detail area with its panel, and the picker sheet

**Files:**
- Create: `Sources/CanopyApp/Plugins/PluginDetailView.swift`, `PluginPickerSheet.swift`, `LinkedRowsView.swift`, `Fixture/FixturePanel.swift`
- Modify: `Sources/CanopyApp/RootView.swift`, `Terminal/RowTerminalsView.swift`, `Terminal/TopBarView.swift`, `AppModel.swift`

**Interfaces:**
- `PluginDetailView(row:)`: the panel column (a title bar strip naming the plugin, then the plugin's panel), a drag handle, and the terminals, as `RowTerminalsView` draws them.
- `AppModel.panelWidth(for plugin: String, detailWidth: Double) -> Double`: the live width while dragging, else the saved one, else 340, clamped to 260 and half the detail width.
- `RootView` offsets `TopBarView` by the panel's width for a plugin row, and the bar leaves the traffic lights' room only when no panel sits under them.
- `PluginPickerSheet(section:)`: the field, the chips, the list, the spinner, the error with its fix, the footer command, and Cancel and Create Row or Open Row.
- `LinkedRowsView(plugin:item:)`: the item's linked rows with their PR badges, for panels to show; clicking one selects it.
- `FixturePanel`: the item's title, subtitle, the row's folder, and `LinkedRowsView`.

- [ ] **Step 1: Build the views**

- [ ] **Step 2: Build with no warnings**

Run: `swift build 2>&1 | grep -E "warning:|error:" ; test ${PIPESTATUS[0]} -eq 0`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/CanopyApp
git commit -m "feat: the plugin panel beside a plugin row's terminals, and the plugin picker"
```

## Task 13: End-to-end cases, the UI fixture, and the specs

**Files:**
- Modify: `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `docs/superpowers/specs/2026-09-27-canopy-design.md`, `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md`

- `scripts/e2e.sh` gains a plugin part that launches the dev build itself with `CANOPY_FIXTURE_PLUGIN=1`:
  - `plugin list` says Fixture is off, `plugin enable fixture` turns it on and writes its section while keeping a key the script put in `config.json` first.
  - `plugin items fixture --query beta` finds `fx-2`, and `--filter waiting` narrows the list.
  - `plugin new fixture 2 --run ...` makes the row under `plugins/fixture/`, with `item.md`, and the command in its pane sees `CANOPY_PLUGIN`, `CANOPY_ITEM`, and no `CANOPY_REPO`.
  - A second `plugin new fixture fx-2` fails with `item_has_row`.
  - `row list --json` has the row with `plugin`, `item`, `title`, and `path`, and the text shows it under FIXTURE.
  - `term list` run in the row's folder names the row.
  - `row new feat/linked --repo demo` with `CANOPY_PLUGIN=fixture CANOPY_ITEM=fx-2` makes a linked row whose `row.created` event has the link, and an unknown item fails with no worktree made.
  - `row move` puts one plugin row before another.
  - The row's folder deleted by hand comes back with `item.md` when `term new` opens a terminal in it.
  - `fixture.remember` over the socket stores a token that `security find-generic-password` finds for this home, the log's `cli.call` has no token, and `fixture.forget` removes it.
  - `plugin disable fixture` refuses while a program runs, `--force` turns it off and `row list` hides the rows, and `plugin enable fixture` brings them back.
  - The rows come back after a relaunch.
  - `row rm <path>` moves the folder to the Trash, the script deletes the trashed copy, and the linked worktree row keeps its link.
  - `canopy log --type plugin` has every plugin event, and `agent-guide` mentions `canopy plugin`.
- `scripts/ui-fixture.sh` launches with `CANOPY_FIXTURE_PLUGIN=1` and a `config.json` turning the fixture on with a warning, makes fixture rows with terminals, and a web-app row linked to one of them.
- The main spec's sidebar, data folder, CLI table, and activity events point at the plugins spec, and the plugins spec records what building changed.

- [ ] **Step 1: Add the cases and run them**

Run: `make e2e`
Expected: `e2e passed`.

- [ ] **Step 2: Commit**

```bash
git add scripts docs
git commit -m "test: plugin cases end to end, and plugins in the UI fixture"
```

## UI Checks

On a dev build from `scripts/ui-fixture.sh`, in dark and in light, with window shots only:

- The section header, its hover `…` and `+`, and its warning.
- The picker: typing, each filter chip, picking an item, picking an item that has a row, and Escape.
- A plugin row with its panel and terminals, and the top bar starting at the panel's edge.
- Resizing the panel, its limits, and the width after a relaunch.
- Dragging a plugin row within its section, and refusing a drop on another section.
- Removing with `x`.
- `⌘1` to `⌘9` and the arrow keys reaching plugin rows.
- A linked worktree row's chip, and clicking it.

Each is checked with `canopy row list --json` and `canopy plugin list --json` where it changes state.

## After Review

To be filled in after the independent review.
