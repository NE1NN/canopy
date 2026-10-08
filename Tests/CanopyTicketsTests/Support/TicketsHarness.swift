import CanopyCore
import Foundation
import Synchronization

@testable import CanopyTickets

/// Records the rows the plugin host asks the window to select.
final class RecordingUI: ControlUIBridge {
    let selectedPaths = Mutex<[String]>([])

    var selected: [String] { selectedPaths.withLock { $0 } }

    func selectRow(path: String) async {
        selectedPaths.withLock { $0.append(path) }
    }
}

/// A Keychain that refuses every read, as a locked one does.
struct RefusingSecretStore: SecretStore {
    func read(service: String, account: String) throws -> String? {
        throw SecretStoreError(status: -25308, description: "User interaction is not allowed.")
    }
    func write(_ value: String, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

/// A terminal screen that keeps nothing, for panes whose output no test reads.
@MainActor
final class QuietEmulator: TerminalEmulator {
    var size = TerminalSize.standard
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalSize) -> Void)?
    var onTitle: ((String) -> Void)?
    var onOpenLink: ((String) -> Void)?
    func feed(_ data: Data) {}
    func screenText() -> String { "" }
    func recentText(lines: Int) -> String { "" }
}

struct QuietEngine: TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator {
        MainActor.assumeIsolated { QuietEmulator() }
    }
}

/// The Tickets plugin in a plugin host on a temporary home, with ticket-manager in memory, a clock the test moves, and
/// secrets that never reach the Keychain.
@MainActor
final class TicketsHarness {
    static let url = "https://tm.example.convex.site"

    let dir: TempDir
    let home: CanopyHome
    let transport: FakeTransport
    let clock: ManualClock
    let secretStore: any SecretStore
    let plugin: TicketsPlugin
    let workspace: Workspace
    let terminals: TerminalStore
    let host: PluginHost
    let ui = RecordingUI()

    var url: String { Self.url }
    var store: TicketStore { plugin.store }
    var secrets: PluginSecrets { PluginSecrets(store: secretStore, bundleID: "test", plugin: "tickets", home: home) }

    init(
        _ dir: TempDir, config: String? = nil, serverToken: String, transport: FakeTransport? = nil,
        clock: ManualClock? = nil, secretStore: (any SecretStore)? = nil
    ) async throws {
        self.dir = dir
        home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        if let config {
            try config.write(to: home.configFile, atomically: true, encoding: .utf8)
        }
        self.transport = transport ?? FakeTransport(token: serverToken)
        self.clock = clock ?? ManualClock()
        self.secretStore = secretStore ?? MemorySecretStore()
        plugin = TicketsPlugin(transport: self.transport, clock: self.clock)
        workspace = Workspace(home: home, git: GitRunner(environment: ["PATH": "/usr/bin:/bin"]))
        try await workspace.start()
        let userHome = dir.sub("user-home")
        try FileManager.default.createDirectory(atPath: userHome, withIntermediateDirectories: true)
        terminals = TerminalStore(
            engine: QuietEngine(),
            settings: ShellSettings(
                shell: "/bin/bash",
                baseEnvironment: ["HOME": userHome, "USER": NSUserName(), "BASH_SILENCE_DEPRECATION_WARNING": "1"],
                cliDirectory: nil, home: home))
        host = PluginHost(
            workspace: workspace, terminals: terminals, plugins: [plugin], secrets: self.secretStore,
            bundleID: "test", trash: FolderMovingTrash(into: dir.sub("trash")))
        host.ui = ui
        await host.start()
    }

    /// The same home, secrets, ticket-manager, and clock, in a new plugin and host, as after a relaunch.
    func restart() async throws -> TicketsHarness {
        terminals.closeAll()
        await host.stop()
        await workspace.stop()
        return try await TicketsHarness(
            dir, serverToken: "", transport: transport, clock: clock, secretStore: secretStore)
    }

    /// Closes every terminal the test opened.
    func close() {
        terminals.closeAll()
    }

    @discardableResult
    func connect(token: String, web: String? = nil) async throws -> TicketConnectResult {
        try await call(TicketMethod.connect, TicketConnectParams(url: url, token: token, web: web))
            .decode(TicketConnectResult.self)
    }

    /// Calls a `tickets.*` method as the control API would, from `row`'s terminal when given.
    func call(_ method: String, _ params: some Encodable, in row: PluginRow? = nil) async throws -> JSONValue {
        var value = try JSONValue.from(params)
        if let row, case .object(var fields) = value {
            fields["target"] = try JSONValue.from(TargetHint(row: row.path))
            value = .object(fields)
        }
        return try await host.call(method, params: value, target: TargetHint(row: row?.path), row: row)
    }

    func section() async -> PluginSection? {
        await workspace.snapshot.section("tickets")
    }

    @discardableResult
    func newRow(_ reference: String) async throws -> PluginRow {
        try await host.createRow("tickets", reference: reference, run: nil, select: false).row
    }

    /// A row as a state.json from another deployment could hold it, with its folder.
    @discardableResult
    func addRowByHand(item: String, title: String) async throws -> PluginRow {
        let path = Paths.canonical(home.pluginsRoot.path) + "/tickets/" + title
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try await workspace.addPluginRow(PluginRowEntry(item: item, title: title, path: path), plugin: "tickets")
    }

    /// Runs `sleep 30` in a new tab of the row, and returns once the pane counts as busy.
    func runBusyProgram(in row: PluginRow) async {
        let pane = terminals.openTab(for: PaneContext(pluginRow: row)).pane
        await pane.run("sleep 30")
        _ = await eventually { pane.isBusy }
    }

    func setViewing(visible: Bool, frontmost: Bool) {
        host.viewing = PluginViewing(isWindowVisible: visible, isFrontmost: frontmost)
    }

    /// Selects the row, and returns once the plugin host passes the selection on.
    func select(_ path: String) async {
        try? await workspace.setSelectedRow(path: path)
        _ = await eventually { self.host.context("tickets")?.state.selectedRow?.path == path }
    }

    func setConfig(_ fields: [String: JSONValue]) async throws {
        _ = try await host.enable("tickets", with: fields)
    }

    /// Waits until the plugin has taken in the host's latest state, has nothing in flight, and its refresh loop sleeps,
    /// so moving the clock afterwards is the only thing that wakes it.
    func settle() async {
        _ = await eventually {
            guard let state = self.host.context("tickets")?.state else { return true }
            return await self.plugin.hasSettled(on: state)
        }
    }
}
