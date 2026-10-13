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
        mac.setInbox(Rows.inbox)
        let model = RowsModel(servers: try await servers(mac))
        await model.refresh()
        let canopy = try #require(model.hosts.first?.sections.first)
        #expect(
            canopy.rows.map(\.name) == [
                "main", "feat/ios-companion", "fix/port-scan-drain", "feat/port-labels", "fix/hand-checks",
            ])
        #expect(canopy.rows[2].pr == Self.pr)
        #expect(canopy.rows[2].dot == .done)
        #expect(canopy.rows[1].dot == .waiting)
        #expect(canopy.rows[4].dot == nil)
        #expect(model.hosts.first?.sections.last?.rows.map(\.name) == ["#0853"])
        var inbox = Rows.inbox
        inbox.rows[1].agents[0].state = .working
        mac.setInbox(inbox)
        #expect(await eventually { model.hosts.first?.sections.first?.rows[1].dot == .working })
    }

    @Test func aRowTheInboxGainsOrLosesRefreshesRows() async throws {
        serveRows(Rows.inbox.rows)
        mac.setInbox(Rows.inbox)
        let model = RowsModel(servers: try await servers(mac))
        model.start()
        #expect(await eventually { model.hosts.first?.sections.first?.rows.count == 5 })
        let added = PhoneRow(path: "/canopy-new", name: "feat/new", repo: "canopy")
        serveRows(Rows.inbox.rows + [added])
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [added]))
        #expect(await eventually { model.hosts.first?.sections.first?.rows.last?.name == "feat/new" })
        #expect(mac.requests.filter { $0.method == PhoneMethod.rows }.count == 2)
        // A change in agents alone is laid over what Rows has, without asking again.
        var inbox = PhoneInbox(rows: Rows.inbox.rows + [added])
        inbox.rows[0].agents[0].state = .waiting
        mac.setInbox(inbox)
        #expect(await eventually { model.hosts.first?.sections.first?.rows[0].dot == .waiting })
        #expect(mac.requests.filter { $0.method == PhoneMethod.rows }.count == 2)
        model.stop()
    }

    @Test func rowsStartedAgainRefreshAgain() async throws {
        serveRows(Rows.inbox.rows)
        mac.setInbox(Rows.inbox)
        let model = RowsModel(servers: try await servers(mac))
        model.start()
        #expect(await eventually { model.hosts.first?.sections.first?.rows.count == 5 })
        model.stop()
        model.start()
        let added = PhoneRow(path: "/canopy-new", name: "feat/new", repo: "canopy")
        serveRows(Rows.inbox.rows + [added])
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [added]))

        #expect(await eventually { model.hosts.first?.sections.first?.rows.last?.name == "feat/new" })
        model.stop()
    }

    @Test func aFailedRefreshSaysWhy() async throws {
        mac.on(PhoneMethod.rows) { _ in .error("internal") }
        mac.setInbox(Rows.inbox)
        let model = RowsModel(servers: try await servers(mac))
        await model.refresh()
        #expect(model.hosts.first?.problem?.title == "internal message")
        #expect(!model.isLoading)
    }

    /// Each server's rows under its own host, in pairing order, and the Mac's copy of a box row only under the box.
    @Test func rowsGroupByServerInPairingOrder() async throws {
        let box = FakeMac.box()
        let boxRow = PhoneRow(
            path: "/home/ubuntu/feat", name: "feat/box", repo: "solis-v1",
            agents: [Rows.agent("b1", .waiting, since: 1_200)])
        var macCopy = boxRow
        macCopy.path = "/Users/h/.canopy/remote/hindie-box/feat"
        macCopy.host = "hindie-box"
        macCopy.agents = [Rows.agent("p9", .waiting, since: 1_200)]
        let macOnly = PhoneRow(path: "/Users/h/solis", name: "main", repo: "solis-v1", isMain: true)
        mac.state.withLock {
            $0.rows = PhoneRowsResult(sections: [
                .init(name: "canopy", isPlugin: false, rows: [Rows.main]),
                .init(name: "solis-v1", isPlugin: false, rows: [macOnly, macCopy]),
            ])
        }
        box.state.withLock {
            $0.rows = PhoneRowsResult(sections: [.init(name: "solis-v1", isPlugin: false, rows: [boxRow])])
        }
        let model = RowsModel(servers: try await servers(mac, box))

        await model.refresh()

        #expect(model.hosts.map(\.server.name) == ["Studio", "hindie-box"])
        #expect(model.hosts[0].sections.map { $0.rows.map(\.name) } == [["main"], ["main"]])
        #expect(model.hosts[1].sections.map { $0.rows.map(\.name) } == [["feat/box"]])
    }

    /// A section the Mac only has a box's rows in leaves with them.
    @Test func theMacsCopyOfABoxRowIsLeftOut() async throws {
        let box = FakeMac.box()
        var macCopy = PhoneRow(path: "/Users/h/.canopy/remote/hindie-box/feat", name: "feat/box", repo: "solis-v1")
        macCopy.host = "hindie-box"
        mac.state.withLock {
            $0.rows = PhoneRowsResult(sections: [.init(name: "solis-v1", isPlugin: false, rows: [macCopy])])
        }
        let alone = RowsModel(servers: try await servers(mac))
        await alone.refresh()
        #expect(alone.hosts.first?.sections.first?.rows.map(\.name) == ["feat/box"])

        let withBox = RowsModel(servers: try await servers(mac, box))
        await withBox.refresh()
        #expect(withBox.hosts.first?.sections.isEmpty == true)
    }

    @Test func aServerAddedLaterGetsItsRows() async throws {
        let box = FakeMac.box()
        box.state.withLock {
            $0.rows = PhoneRowsResult(sections: [.init(name: "solis-v1", isPlugin: false, rows: [Rows.idle])])
        }
        serveRows(Rows.inbox.rows)
        let servers = Servers(
            transport: FakeNetwork(mac, box), credentials: MemoryCredentialStore(mac.paired()), phoneName: "iPhone")
        servers.start()
        let model = RowsModel(servers: servers)
        model.start()
        #expect(await eventually { model.hosts.first?.sections.isEmpty == false })

        try await servers.pair(box.link)

        #expect(await eventually { model.hosts.last?.sections.first?.rows.map(\.name) == ["fix/hand-checks"] })
        model.stop()
    }

    /// The host out of reach keeps the rows it last sent, and the other's rows are as fresh as ever.
    @Test func oneServerOutOfReachKeepsItsRowsAndLeavesTheOthers() async throws {
        let box = FakeMac.box()
        box.state.withLock {
            $0.rows = PhoneRowsResult(sections: [.init(name: "solis-v1", isPlugin: false, rows: [Rows.idle])])
        }
        serveRows(Rows.inbox.rows)
        mac.setInbox(Rows.inbox)
        let model = RowsModel(servers: try await servers(mac, box))
        model.start()
        #expect(await eventually { model.hosts.allSatisfy { !$0.sections.isEmpty } })

        box.goAway()

        #expect(await eventually { model.hosts.last?.server.isUnreachable == true })
        #expect(model.hosts.last?.sections.first?.rows.map(\.name) == ["fix/hand-checks"])
        var inbox = Rows.inbox
        inbox.rows[1].agents[0].state = .working
        mac.setInbox(inbox)
        #expect(await eventually { model.hosts.first?.sections.first?.rows[1].dot == .working })
        model.stop()
    }
}
