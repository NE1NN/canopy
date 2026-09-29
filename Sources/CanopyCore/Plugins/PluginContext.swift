import Foundation

/// What the window shows, which plugins pace their refreshes by.
public struct PluginViewing: Sendable, Equatable {
    /// Some part of Canopy's window can be seen.
    public var isWindowVisible: Bool
    /// Canopy is the active app and its window can be seen.
    public var isFrontmost: Bool

    public init(isWindowVisible: Bool = false, isFrontmost: Bool = false) {
        self.isWindowVisible = isWindowVisible
        self.isFrontmost = isFrontmost
    }
}

/// What a plugin watches: its rows, its row on screen, and whether the window can be seen.
public struct PluginState: Sendable, Equatable {
    public var isOn: Bool
    /// In sidebar order.
    public var rows: [PluginRow]
    /// The plugin's row the window shows, if one of its rows is selected.
    public var selectedRow: PluginRow?
    public var viewing: PluginViewing

    public init(isOn: Bool, rows: [PluginRow], selectedRow: PluginRow?, viewing: PluginViewing) {
        self.isOn = isOn
        self.rows = rows
        self.selectedRow = selectedRow
        self.viewing = viewing
    }
}

/// One plugin's way into Canopy. The host makes one for each plugin when it starts, and keeps it while Canopy runs,
/// whether the plugin is on or off.
@MainActor
public final class PluginContext {
    public nonisolated let info: PluginInfo
    /// CANOPY_HOME/plugins/<id>, where the plugin's rows' folders go.
    public nonisolated let folder: URL
    public nonisolated let secrets: PluginSecrets
    public nonisolated let activity: ActivityLog
    private weak var host: PluginHost?
    private var subscribers: [UUID: AsyncStream<PluginState>.Continuation] = [:]

    init(info: PluginInfo, folder: URL, secrets: PluginSecrets, activity: ActivityLog, host: PluginHost) {
        self.info = info
        self.folder = folder
        self.secrets = secrets
        self.activity = activity
        self.host = host
    }

    /// Its section of config.json, an empty object while it has none.
    public var config: JSONValue {
        host?.section(info.id) ?? .object([:])
    }

    public var state: PluginState {
        host?.state(of: info.id) ?? PluginState(isOn: false, rows: [], selectedRow: nil, viewing: PluginViewing())
    }

    /// The state now, then each change, until the plugin stops listening.
    public func states() -> AsyncStream<PluginState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PluginState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        continuation.yield(state)
        return stream
    }

    /// Sets how the plugin's rows at these paths look. Its other rows keep their looks.
    public func setLooks(_ looks: [String: PluginRowLook]) async {
        await host?.workspace.setPluginLooks(looks, plugin: info.id)
    }

    /// Shows why the plugin is not working under its section's header, with the fix, as markdown. Nil clears it.
    public func setWarning(_ warning: String?) async {
        await host?.workspace.setPluginWarning(info.id, warning)
    }

    /// The worktree rows made for one of its items, in sidebar order.
    public func linkedRows(item: String) -> [Row] {
        host?.snapshot.linkedRows(plugin: info.id, item: item) ?? []
    }

    /// Does what `plugin.enable` does, for a command such as `tickets.connect`.
    public func turnOn(with fields: [String: JSONValue]) async throws {
        _ = try await requireHost().enable(info.id, with: fields)
    }

    /// Does what `plugin.disable` does, for a command such as `tickets.disconnect`.
    public func turnOff(force: Bool) async throws {
        _ = try await requireHost().disable(info.id, force: force)
    }

    public func createRow(for reference: String, run: String?, select: Bool) async throws -> PluginRowCreated {
        try await requireHost().createRow(info.id, reference: reference, run: run, select: select)
    }

    public func removeRow(_ row: PluginRow, force: Bool) async throws -> PluginRowRemoved {
        try await requireHost().removeRow(row, force: force)
    }

    public func select(_ row: PluginRow) async {
        await host?.select(row.path)
    }

    func publish(_ state: PluginState) {
        for subscriber in subscribers.values {
            subscriber.yield(state)
        }
    }

    func finish() {
        for subscriber in subscribers.values {
            subscriber.finish()
        }
        subscribers = [:]
    }

    private func requireHost() throws -> PluginHost {
        guard let host else { throw ControlError(code: "internal", message: "Canopy is shutting down.") }
        return host
    }
}
