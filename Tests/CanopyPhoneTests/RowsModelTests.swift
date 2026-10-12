import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct RowsModelTests {
    let mac = FakeMac()

    static let pr = PhonePR(number: 41, state: .open, title: "Drain", url: "https://github.com/x/y/pull/41")

    func serveRows(_ rows: [PhoneRow]) {
        var drain = Rows.drain
        drain.pr = Self.pr
        drain.agents = []
        let repo = rows.filter { $0.repo != nil }.map {
            $0.path == drain.path ? drain : PhoneRow(path: $0.path, name: $0.name, repo: $0.repo, isMain: $0.isMain)
        }
        let plugin = rows.filter { $0.plugin != nil }.map { PhoneRow(path: $0.path, name: $0.name, plugin: $0.plugin) }
        mac.state.withLock {
            $0.rows = PhoneRowsResult(sections: [
                .init(name: "canopy", isPlugin: false, rows: repo),
                .init(name: "tickets", isPlugin: true, rows: plugin),
            ])
        }
    }

    @Test func rowsCarryLiveAgentsFromTheInbox() async throws {
        serveRows(Rows.inbox.rows)
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = RowsModel(connection: connection)
        await model.refresh()
        let canopy = try #require(model.sections.first)
        #expect(
            canopy.rows.map(\.name) == [
                "main", "feat/ios-companion", "fix/port-scan-drain", "feat/port-labels", "fix/hand-checks",
            ])
        #expect(canopy.rows[2].pr == Self.pr)
        #expect(canopy.rows[2].dot == .done)
        #expect(canopy.rows[1].dot == .waiting)
        #expect(canopy.rows[4].dot == nil)
        #expect(model.sections.last?.rows.map(\.name) == ["#0853"])
        var inbox = Rows.inbox
        inbox.rows[1].agents[0].state = .working
        mac.setInbox(inbox)
        #expect(await eventually { model.sections.first?.rows[1].dot == .working })
    }

    @Test func aRowTheInboxGainsOrLosesRefreshesRows() async throws {
        serveRows(Rows.inbox.rows)
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = RowsModel(connection: connection)
        model.start()
        #expect(await eventually { model.sections.first?.rows.count == 5 })
        let added = PhoneRow(path: "/canopy-new", name: "feat/new", repo: "canopy")
        serveRows(Rows.inbox.rows + [added])
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [added]))
        #expect(await eventually { model.sections.first?.rows.last?.name == "feat/new" })
        #expect(mac.requests.filter { $0.method == PhoneMethod.rows }.count == 2)
        // A change in agents alone is laid over what Rows has, without asking again.
        var inbox = PhoneInbox(rows: Rows.inbox.rows + [added])
        inbox.rows[0].agents[0].state = .waiting
        mac.setInbox(inbox)
        #expect(await eventually { model.sections.first?.rows[0].dot == .waiting })
        #expect(mac.requests.filter { $0.method == PhoneMethod.rows }.count == 2)
        model.stop()
    }

    @Test func aFailedRefreshSaysWhy() async throws {
        mac.on(PhoneMethod.rows) { _ in .error("internal") }
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = RowsModel(connection: connection)
        await model.refresh()
        #expect(model.problem?.title == "internal message")
        #expect(!model.isLoading)
    }
}
