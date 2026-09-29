import Foundation
import Observation

/// What picking an item in a plugin's picker does. Each is one `canopy` command, which `PluginPicker.command` spells
/// out.
public enum PluginPickerAction: Sendable, Equatable {
    /// `canopy plugin new <plugin> <item> --select`, or the plugin's own command.
    case create(PluginItem)
    /// `canopy row select <path>`, for an item that already has a row.
    case select(PluginRow)
}

/// The state of the sheet every plugin's `+` opens: the typed text, the filter chips, the items the plugin gave for
/// them, and which one is selected. It asks the plugin afresh when it opens and when a toggle changes, and otherwise
/// lets the plugin narrow what it already has.
@MainActor
@Observable
public final class PluginPicker {
    public let plugin: PluginInfo
    public let filters: PluginFilters

    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            selection = nil
            isSelectionPicked = false
            reload(fresh: false)
        }
    }
    public var choice: String? {
        didSet {
            if choice != oldValue { reload(fresh: false) }
        }
    }
    public private(set) var toggles: Set<String> = []
    /// True while the plugin has not answered the latest query.
    public private(set) var isLoading = false

    @ObservationIgnored private let source: @Sendable (PluginQuery) async throws -> [PluginItem]
    @ObservationIgnored private let customCommand: @Sendable (PluginItem) -> String?
    /// Nil until the plugin first answers.
    private var result: Result<[PluginItem], PickerError>?
    /// Changes before the sheet first loads are part of that first load.
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private var selection: String?
    @ObservationIgnored private var isSelectionPicked = false

    /// `items` asks the plugin, as `canopy plugin items` does. `command` is the plugin's own command for picking an
    /// item without a row, or nil for the generic one.
    public init(
        plugin: PluginInfo, filters: PluginFilters,
        items: @escaping @Sendable (PluginQuery) async throws -> [PluginItem],
        command: @escaping @Sendable (PluginItem) -> String?
    ) {
        self.plugin = plugin
        self.filters = filters
        self.source = items
        self.customCommand = command
        self.choice = filters.defaultChoice
    }

    public func setToggle(_ id: String, _ on: Bool) {
        guard toggles.contains(id) != on else { return }
        if on { toggles.insert(id) } else { toggles.remove(id) }
        reload(fresh: true)
    }

    /// The items, and the previous query's while a new one loads. Nil before the first answer, and when the plugin
    /// failed.
    public var shownItems: [PluginItem]? {
        if case .success(let items) = result { items } else { nil }
    }

    /// The plugin's error, with its fix, which the sheet shows in place of the list.
    public var error: String? {
        if case .failure(let error) = result { error.message } else { nil }
    }

    public var selectedItem: PluginItem? {
        selection.flatMap { id in shownItems?.first { $0.id == id } }
    }

    public var selectedAction: PluginPickerAction? {
        selectedItem.map { item in item.row.map(PluginPickerAction.select) ?? .create(item) }
    }

    /// Asks the plugin afresh, as when the sheet opens, and returns once it answers.
    public func load() async {
        hasLoaded = true
        loadTask?.cancel()
        await fetch(fresh: true)
    }

    public func select(_ id: String?) {
        selection = id
        isSelectionPicked = id != nil
    }

    /// Moves by `offset` items, stopping at the ends. With nothing selected, down picks the first and up the last.
    public func moveSelection(by offset: Int) {
        guard let items = shownItems, !items.isEmpty else { return }
        isSelectionPicked = true
        guard let index = items.firstIndex(where: { $0.id == selection }) else {
            selection = (offset > 0 ? items.first : items.last)?.id
            return
        }
        selection = items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// The `canopy` command that does what picking does, quoted for a shell.
    public func command(for action: PluginPickerAction) -> String {
        switch action {
        case .create(let item):
            customCommand(item)
                ?? (["canopy", "plugin", "new", plugin.id, item.id].map(NewRowAction.quoted) + ["--select"])
                .joined(separator: " ")
        case .select(let row): (["canopy", "row", "select", row.path].map(NewRowAction.quoted)).joined(separator: " ")
        }
    }

    private func reload(fresh: Bool) {
        guard hasLoaded else { return }
        loadTask?.cancel()
        loadTask = Task { await self.fetch(fresh: fresh) }
    }

    /// Only the latest query's answer is shown, whichever order the answers come in.
    private func fetch(fresh: Bool) async {
        generation += 1
        let mine = generation
        isLoading = true
        let query = PluginQuery(text: text, choice: choice, toggles: toggles, fresh: fresh)
        let answer: Result<[PluginItem], PickerError>
        do {
            answer = .success(try await source(query))
        } catch {
            answer = .failure(PickerError(error))
        }
        guard mine == generation else { return }
        result = answer
        isLoading = false
        settleSelection()
    }

    /// Keeps a picked item selected while it is listed. Otherwise the first item is selected once something is typed,
    /// and nothing before.
    private func settleSelection() {
        let items = shownItems ?? []
        if isSelectionPicked, let selection, items.contains(where: { $0.id == selection }) { return }
        isSelectionPicked = false
        selection = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : items.first?.id
    }
}

/// A plugin's error as the picker shows it.
struct PickerError: Error, Equatable {
    var message: String

    init(_ error: any Error) {
        message =
            switch error {
            case let error as ControlError: error.message
            case let error as WorkspaceError: error.message
            default: "\(error)"
            }
    }
}
