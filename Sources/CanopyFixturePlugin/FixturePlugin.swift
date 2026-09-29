import CanopyCore
import Foundation

/// A plugin with made-up items that exercises the whole plugin base: the picker's filters and search, references, rows
/// with every kind of accessory, a label for linked rows, a warning, missing items, secrets, and control methods. A dev
/// build lists it only when launched with CANOPY_FIXTURE_PLUGIN=1, and config.json turns it on like any plugin.
///
/// Its section of config.json may hold `warning`, shown under its header, `failStart`, which makes starting fail with
/// that message, and `missing`, a list of item ids it pretends are gone.
public actor FixturePlugin: CanopyPlugin {
    public nonisolated let info = PluginInfo(id: "fixture", name: "Fixture", symbol: "shippingbox")
    public nonisolated let filters = PluginFilters(
        choices: [PluginFilter(id: "all", title: "All"), PluginFilter(id: "waiting", title: "Waiting")],
        defaultChoice: "all", toggles: [PluginFilter(id: "closed", title: "Closed")])
    public nonisolated let methods: Set<String> = [
        "fixture.remember", "fixture.recall", "fixture.forget", "fixture.where", "fixture.warn", "fixture.missing",
    ]
    public nonisolated let readOnlyMethods: Set<String> = ["fixture.recall", "fixture.where"]

    private var missing: Set<String> = []
    private var watching: Task<Void, Never>?

    public init() {}

    public func start(_ context: PluginContext) async throws {
        let config = await context.config
        if case .string(let failure)? = config.field("failStart") {
            throw ControlError(code: "fixture_failed", message: failure)
        }
        if case .array(let ids)? = config.field("missing") {
            missing = Set(ids.compactMap { if case .string(let id) = $0 { id } else { nil } })
        }
        if case .string(let warning)? = config.field("warning") {
            await context.setWarning(warning)
        }
        let states = await context.states()
        watching = Task { [weak self] in
            for await state in states {
                await self?.showLooks(of: state.rows, context: context)
            }
        }
    }

    public func stop(_ context: PluginContext) async {
        watching?.cancel()
        watching = nil
    }

    public func status(_ context: PluginContext) async -> String? {
        let rows = await context.state.rows.count
        return "\(FixtureItem.all.count) made-up items, \(rows) \(rows == 1 ? "row" : "rows")"
    }

    /// Open items, or closed ones with the Closed toggle, waiting ones first.
    public func items(matching query: PluginQuery, context: PluginContext) async throws -> [PluginItem] {
        let closed = query.toggles.contains("closed")
        let search = SearchText(query.text)
        return FixtureItem.all
            .filter { $0.closed == closed && (query.choice != "waiting" || $0.waiting) }
            .filter { search.matches([$0.title, $0.slug, $0.id]) }
            .sorted { ($0.waiting ? 0 : 1, $0.number) < ($1.waiting ? 0 : 1, $1.number) }
            .map(\.pluginItem)
    }

    /// An id such as `fx-2`, a number such as `2` or `02`, or a slug such as `beta`, in any case.
    public func resolve(_ reference: String, context: PluginContext) async throws -> String {
        let text = reference.trimmingCharacters(in: .whitespaces).lowercased()
        let number = Int(text.hasPrefix("fx-") ? String(text.dropFirst(3)) : text)
        let matches = FixtureItem.all.filter { $0.number == number || $0.slug == text }
        switch matches.count {
        case 1: return matches[0].id
        case 0:
            throw ControlError(
                code: "item_not_found",
                message: "No fixture item matches \"\(reference)\". Run `canopy plugin items fixture`.")
        default:
            throw ControlError(
                code: "item_ambiguous",
                message: "\"\(reference)\" matches \(matches.map(\.id).joined(separator: " and ")). Pass one of those.")
        }
    }

    public func seed(for item: String, context: PluginContext) async throws -> PluginRowSeed {
        let found = try Self.item(item)
        return PluginRowSeed(title: found.slug, folderName: found.slug)
    }

    /// Writes `item.md`, only when it would change.
    public func fill(_ row: PluginRow, context: PluginContext) async throws {
        let file = row.path + "/item.md"
        let markdown = try Self.item(row.item).markdown
        guard (try? String(contentsOfFile: file, encoding: .utf8)) != markdown else { return }
        try markdown.write(toFile: file, atomically: true, encoding: .utf8)
    }

    public func handle(_ call: PluginCall, context: PluginContext) async throws -> JSONValue {
        switch call.method {
        case "fixture.remember":
            guard case .string(let token)? = call.params.field("token") else {
                throw ControlError(code: "bad_params", message: "Pass a token.")
            }
            try keychain { try context.secrets.write(token, for: "token") }
            return .object(["stored": true])
        case "fixture.recall":
            let token = try keychain { try context.secrets.read("token") }
            return .object(["token": token.map(JSONValue.string) ?? .null])
        case "fixture.forget":
            try keychain { try context.secrets.delete("token") }
            return .object(["forgotten": true])
        case "fixture.where":
            return .object([
                "item": call.row.map { .string($0.item) } ?? .null,
                "title": call.row.map { .string($0.title) } ?? .null,
            ])
        case "fixture.warn":
            let text: String? = if case .string(let text)? = call.params.field("text") { text } else { nil }
            await context.setWarning(text)
            return .object(["warning": text.map(JSONValue.string) ?? .null])
        case "fixture.missing":
            guard case .string(let item)? = call.params.field("item") else {
                throw ControlError(code: "bad_params", message: "Pass an item.")
            }
            if call.params.field("missing") == .bool(false) { missing.remove(item) } else { missing.insert(item) }
            await showLooks(of: await context.state.rows, context: context)
            return .object(["missing": .array(missing.sorted().map(JSONValue.string))])
        default:
            throw ControlError(code: "unknown_method", message: "Unknown method \(call.method)")
        }
    }

    private func showLooks(of rows: [PluginRow], context: PluginContext) async {
        var looks: [String: PluginRowLook] = [:]
        for row in rows {
            let item = FixtureItem.all.first { $0.id == row.item }
            let look = PluginRowLook(
                label: item.map { "#\($0.number)" }, accessories: item?.accessories ?? [],
                isMissing: item == nil || missing.contains(row.item))
            if row.look != look { looks[row.path] = look }
        }
        if !looks.isEmpty {
            await context.setLooks(looks)
        }
    }

    private static func item(_ id: String) throws -> FixtureItem {
        guard let item = FixtureItem.all.first(where: { $0.id == id }) else {
            throw ControlError(code: "item_not_found", message: "The fixture has no item \(id).")
        }
        return item
    }

    private func keychain<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SecretStoreError {
            throw ControlError(code: "keychain_failed", message: "The Keychain refused: \(error.description)")
        }
    }
}

extension JSONValue {
    fileprivate func field(_ key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }
}
