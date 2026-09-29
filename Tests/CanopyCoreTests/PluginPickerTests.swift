import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// Holds a stand-in plugin's answers until the test lets them go.
actor AnswerGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    var waiters: Int { waiting.count }
}

/// The queries a stand-in plugin was asked.
final class QueryLog: Sendable {
    private let queries = Mutex<[PluginQuery]>([])

    func append(_ query: PluginQuery) {
        queries.withLock { $0.append(query) }
    }

    var all: [PluginQuery] { queries.withLock { $0 } }
}

@MainActor
struct PluginPickerTests {
    nonisolated static let info = PluginInfo(id: "fixture", name: "Fixture", symbol: "shippingbox")
    nonisolated static let filters = PluginFilters(
        choices: [PluginFilter(id: "all", title: "All"), PluginFilter(id: "mine", title: "Mine")],
        defaultChoice: "all", toggles: [PluginFilter(id: "closed", title: "Closed")])
    nonisolated static let row = PluginRow(
        plugin: "fixture", item: "fx-2", title: "beta", path: "/h/plugins/fixture/my beta")
    nonisolated static let items = [
        PluginItem(id: "fx-1", title: "Alpha"), PluginItem(id: "fx-2", title: "Beta", row: row),
        PluginItem(id: "fx-3", title: "Gamma"),
    ]

    /// A picker over `items`, narrowed by the typed text, that records every query.
    func picker(
        items: [PluginItem] = items, command: @escaping @Sendable (PluginPickerAction) -> String? = { _ in nil },
        answer: (@Sendable (PluginQuery) async throws -> [PluginItem])? = nil
    ) -> (PluginPicker, QueryLog) {
        let queries = QueryLog()
        let picker = PluginPicker(
            plugin: Self.info, filters: Self.filters,
            items: { query in
                queries.append(query)
                if let answer { return try await answer(query) }
                return items.filter { query.text.isEmpty || $0.title.localizedCaseInsensitiveContains(query.text) }
            }, command: command)
        return (picker, queries)
    }

    @Test func opensFreshThenNarrowsWithoutFetchingAgain() async {
        let (picker, queries) = picker()
        #expect(picker.shownItems == nil)
        #expect(picker.choice == "all")

        await picker.load()
        #expect(picker.shownItems?.map(\.id) == ["fx-1", "fx-2", "fx-3"])
        #expect(picker.selectedItem == nil)

        picker.text = "gam"
        #expect(await eventually { picker.shownItems?.map(\.id) == ["fx-3"] })
        #expect(picker.selectedItem?.id == "fx-3")
        picker.choice = "mine"
        #expect(await eventually { queries.all.count == 3 })

        #expect(
            queries.all == [
                PluginQuery(text: "", choice: "all", fresh: true),
                PluginQuery(text: "gam", choice: "all", fresh: false),
                PluginQuery(text: "gam", choice: "mine", fresh: false),
            ])
    }

    @Test func aToggleChangeFetchesAgain() async {
        let (picker, queries) = picker()
        await picker.load()

        picker.setToggle("closed", true)
        #expect(await eventually { queries.all.count == 2 })
        picker.setToggle("closed", true)

        #expect(queries.all.last == PluginQuery(text: "", choice: "all", toggles: ["closed"], fresh: true))
        #expect(picker.toggles == ["closed"])
        #expect(queries.all.count == 2)
    }

    @Test func aToggleIsFetchedAfreshEvenWhenTypingFollowsAtOnce() async {
        let gate = AnswerGate()
        let (picker, queries) = picker(answer: { query in
            if query.toggles.contains("closed"), query.text.isEmpty { await gate.wait() }
            return Self.items
        })
        await picker.load()

        picker.setToggle("closed", true)
        #expect(await eventually { await gate.waiters == 1 })
        picker.text = "a"
        #expect(await eventually { queries.all.count == 3 })
        await gate.open()

        #expect(queries.all.last == PluginQuery(text: "a", choice: "all", toggles: ["closed"], fresh: true))
        picker.text = "ab"
        #expect(await eventually { queries.all.count == 4 })
        #expect(queries.all.last?.fresh == false)
    }

    @Test func anOlderAnswerNeverReplacesANewerOne() async {
        let gate = AnswerGate()
        let (picker, _) = picker(answer: { query in
            if query.text == "slow" { await gate.wait() }
            return [PluginItem(id: query.text, title: query.text)]
        })
        await picker.load()

        picker.text = "slow"
        #expect(await eventually { await gate.waiters == 1 })
        #expect(picker.isLoading)
        picker.text = "fast"
        #expect(await eventually { picker.shownItems?.map(\.id) == ["fast"] })
        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(picker.shownItems?.map(\.id) == ["fast"])
        #expect(!picker.isLoading)
    }

    @Test func keepsTheLastItemsWhileANewQueryLoads() async {
        let gate = AnswerGate()
        let (picker, _) = picker(answer: { query in
            if query.text == "slow" { await gate.wait() }
            return Self.items
        })
        await picker.load()

        picker.text = "slow"
        #expect(await eventually { await gate.waiters == 1 })

        #expect(picker.isLoading)
        #expect(picker.shownItems?.count == 3)
        await gate.open()
    }

    @Test func showsAPluginsErrorInPlaceOfTheList() async {
        let (picker, _) = picker(answer: { _ in
            throw ControlError(code: "tickets_unreachable", message: "ticket-manager did not answer. Try again.")
        })

        await picker.load()

        #expect(picker.error == "ticket-manager did not answer. Try again.")
        #expect(picker.shownItems == nil)
        #expect(picker.selectedAction == nil)
    }

    @Test func anItemWithARowSelectsItAndOthersMakeOne() async {
        let (picker, _) = picker()
        await picker.load()

        picker.select("fx-2")
        #expect(picker.selectedAction == .select(Self.row))
        picker.select("fx-1")
        #expect(picker.selectedAction == .create(Self.items[0]))
        picker.moveSelection(by: 5)
        #expect(picker.selectedItem?.id == "fx-3")
        picker.moveSelection(by: -5)
        #expect(picker.selectedItem?.id == "fx-1")
    }

    @Test func commandsSayWhatAPickDoes() {
        let (plain, _) = picker()
        let (own, _) = picker(command: { action in
            switch action {
            case .create(let item): "canopy ticket new \(item.id) --select"
            case .select(let row): "canopy ticket select \(row.item)"
            }
        })

        #expect(plain.command(for: .create(Self.items[0])) == "canopy plugin new fixture fx-1 --select")
        #expect(own.command(for: .create(Self.items[0])) == "canopy ticket new fx-1 --select")
        #expect(plain.command(for: .select(Self.row)) == "canopy row select '/h/plugins/fixture/my beta'")
        #expect(own.command(for: .select(Self.row)) == "canopy ticket select \(Self.row.item)")
    }
}

struct PluginRowDropTests {
    static func slot(_ plugin: String, _ path: String, _ minY: Double) -> PluginDropSlot {
        PluginDropSlot(plugin: plugin, path: path, minY: minY, maxY: minY + 26)
    }

    let slots = [slot("p", "/p/a", 0), slot("p", "/p/b", 26), slot("p", "/p/c", 52), slot("q", "/q/x", 78)]
    let dragged = PluginRow(plugin: "p", item: "1", title: "a", path: "/p/a")

    @Test func dropsBeforeAndAfterRowsOfTheSamePlugin() {
        #expect(
            PluginRowDrop.target(dragging: dragged, at: 30, in: slots)
                == RowDropTarget(placement: .before("/p/b"), indicator: .above("/p/b")))
        #expect(
            PluginRowDrop.target(dragging: dragged, at: 70, in: slots)
                == RowDropTarget(placement: .after("/p/c"), indicator: .below("/p/c")))
        #expect(PluginRowDrop.target(dragging: dragged, at: 10, in: slots) == nil)
        #expect(PluginRowDrop.target(dragging: dragged, at: 80, in: slots) == nil)
        #expect(PluginRowDrop.target(dragging: dragged, at: 500, in: slots) == nil)
    }
}
