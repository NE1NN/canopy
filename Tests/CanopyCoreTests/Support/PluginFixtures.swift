import Foundation

@testable import CanopyCore

/// Moves folders into a test's own folder, so tests never touch the user's Trash.
struct MovingTrash: FolderTrash {
    let folder: String

    init(into folder: String) {
        self.folder = folder
    }

    func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: folder).appending(path: "\(url.lastPathComponent)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// A plugin whose items, failures, and stalls a test picks, and which records what the host asked of it.
actor TestPlugin: CanopyPlugin {
    nonisolated let info: PluginInfo
    nonisolated let filters: PluginFilters
    nonisolated let methods: Set<String>
    nonisolated let readOnlyMethods: Set<String>
    private let items: [PluginItem]
    /// Folder names by item, for items whose folder is not named after their title.
    private let folders: [String: String]
    private let startError: String?
    private var fillError: String?
    private var stallFills = false
    private var stalled: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [String] = []
    private(set) var queries: [PluginQuery] = []
    private(set) var configs: [JSONValue] = []
    private(set) var handled: [PluginCall] = []
    private(set) var seenStates: [PluginState] = []

    init(
        id: String = "t", name: String = "Test", items: [String] = ["i1", "i2", "i3"], folders: [String: String] = [:],
        startError: String? = nil, fillError: String? = nil
    ) {
        info = PluginInfo(id: id, name: name, symbol: "star")
        filters = PluginFilters(
            choices: [PluginFilter(id: "all", title: "All"), PluginFilter(id: "mine", title: "Mine")],
            defaultChoice: "all", toggles: [PluginFilter(id: "closed", title: "Closed")])
        methods = ["\(id).echo", "\(id).peek", "\(id).fail"]
        readOnlyMethods = ["\(id).peek"]
        self.items = items.map { PluginItem(id: $0, title: "title-\($0)") }
        self.folders = folders
        self.startError = startError
        self.fillError = fillError
    }

    func start(_ context: PluginContext) async throws {
        calls.append("start")
        configs.append(await context.config)
        if let startError { throw ControlError(code: "test_failed", message: startError) }
    }

    func stop(_ context: PluginContext) async {
        calls.append("stop")
    }

    func status(_ context: PluginContext) async -> String? {
        "\(items.count) items"
    }

    func items(matching query: PluginQuery, context: PluginContext) async throws -> [PluginItem] {
        queries.append(query)
        return items.filter { query.text.isEmpty || $0.title.contains(query.text) }
    }

    func resolve(_ reference: String, context: PluginContext) async throws -> String {
        guard let item = items.first(where: { $0.id == reference || $0.title == reference }) else {
            throw ControlError(code: "item_not_found", message: "No item matches \(reference).")
        }
        return item.id
    }

    func seed(for item: String, context: PluginContext) async throws -> PluginRowSeed {
        calls.append("seed \(item)")
        guard let found = items.first(where: { $0.id == item }) else {
            throw ControlError(code: "item_not_found", message: "No item \(item).")
        }
        return PluginRowSeed(title: found.title, folderName: folders[item] ?? found.title)
    }

    func fill(_ row: PluginRow, context: PluginContext) async throws {
        calls.append("fill \(row.item)")
        if stallFills {
            await withCheckedContinuation { stalled.append($0) }
        }
        if let fillError { throw ControlError(code: "fill_failed", message: fillError) }
        try row.item.write(toFile: row.path + "/item.txt", atomically: true, encoding: .utf8)
    }

    nonisolated func pickerCommand(for item: PluginItem) -> String? {
        item.id == "i3" ? "canopy test open \(item.id)" : nil
    }

    func handle(_ call: PluginCall, context: PluginContext) async throws -> JSONValue {
        handled.append(call)
        if call.method == "\(info.id).fail" { throw ControlError(code: "test_failed", message: "It failed.") }
        return .object(["method": .string(call.method), "row": call.row.map { .string($0.item) } ?? .null])
    }

    /// Holds every fill from now on until `releaseFills`.
    func stallFillsFromNow() {
        stallFills = true
    }

    func releaseFills() {
        stallFills = false
        for continuation in stalled { continuation.resume() }
        stalled = []
    }

    var stalledFills: Int { stalled.count }

    func setFillError(_ error: String?) {
        fillError = error
    }

    /// Watches the plugin's states from start, the way a plugin that paces its refreshes would.
    func watch(_ context: PluginContext) async {
        for await state in await context.states() {
            seenStates.append(state)
        }
    }
}
