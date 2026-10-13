import CanopyWire
import Foundation
import Synchronization
import Testing

@testable import CanopyPhone

@MainActor
struct NewTaskModelTests {
    let mac = FakeMac()
    let box = FakeMac.box()
    /// The connections' backoff.
    let sleeper = ManualSleeper()
    /// The waker's own waits.
    let waits = ManualSleeper()
    let defaults = UserDefaults(suiteName: "new-task-\(UUID().uuidString)")!

    @MainActor struct Setup {
        let servers: Servers
        let rows: RowsModel
        let model: NewTaskModel
        var macConnection: ServerConnection { servers.connections[0] }
        var boxConnection: ServerConnection { servers.connections[1] }
    }

    /// The Mac and a box, both paired and connected, with their repos in Rows, and `ec2` answering wakes.
    func setUp(ec2: FakeEC2 = FakeEC2([FakeEC2.pending])) async throws -> Setup {
        mac.state.withLock { state in
            state.agentCommand = "codex --yolo"
            state.rows = PhoneRowsResult(sections: [
                Self.repo("canopy"),
                PhoneRowsResult.Section(
                    name: "Tickets", isPlugin: true, rows: [PhoneRow(path: "/t/1", name: "#1", plugin: "Tickets")]),
                Self.repo("solis"),
            ])
        }
        box.state.withLock { state in
            state.wake = WakerTests.wake
            state.rows = PhoneRowsResult(sections: [Self.repo("solis")])
        }
        let servers = try await servers(mac, box, sleeper: sleeper)
        let rows = RowsModel(servers: servers)
        await rows.refresh()
        #expect(rows.hosts.allSatisfy { !$0.sections.isEmpty })
        let waker = Waker(http: ec2, endpoint: { URL(string: "https://ec2.\($0).test/")! }, sleep: waits.sleep)
        return Setup(
            servers: servers, rows: rows,
            model: NewTaskModel(servers: servers, rows: rows, waker: waker, defaults: defaults))
    }

    static func repo(_ name: String) -> PhoneRowsResult.Section {
        PhoneRowsResult.Section(
            name: name, isPlugin: false, rows: [PhoneRow(path: "/r/\(name)", name: "main", repo: name, isMain: true)])
    }

    func made(pane: String) -> @Sendable (ControlRequest) -> FakeMac.Reply {
        { request in
            let params = try? request.decodeParams(PhoneNewRowParams.self)
            let made = PhoneNewRowResult(path: "/w/\(params?.branch ?? "")", branch: params?.branch ?? "", pane: pane)
            return .result((try? .from(made)) ?? .null)
        }
    }

    func newRowRequests(_ fake: FakeMac) -> [PhoneNewRowParams] {
        fake.requests.filter { $0.method == PhoneMethod.newRow }.compactMap {
            try? $0.decodeParams(PhoneNewRowParams.self)
        }
    }

    @Test func helloCarriesTheAgentCommand() async throws {
        let setup = try await setUp()

        setup.model.serverID = setup.macConnection.id
        #expect(setup.model.agentCommand == "codex --yolo")
        setup.model.serverID = setup.boxConnection.id
        #expect(setup.model.agentCommand == nil)
    }

    @Test func whereListsTheLastServerFirst() async throws {
        let setup = try await setUp()
        box.on(PhoneMethod.newRow, made(pane: "b1"))
        let model = setup.model
        #expect(model.choices.map(\.id) == [setup.macConnection.id, setup.boxConnection.id])

        model.serverID = setup.boxConnection.id
        model.repo = "solis"
        model.branch = "fix/x"
        #expect(await model.start() != nil)

        #expect(model.choices.map(\.id) == [setup.boxConnection.id, setup.macConnection.id])
        model.serverID = nil
        model.open()
        #expect(model.serverID == setup.boxConnection.id)
    }

    @Test func aServerOutOfReachIsGreyedUnlessItWakes() async throws {
        let setup = try await setUp()

        mac.goAway()
        box.goAway()
        #expect(await eventually { setup.macConnection.isUnreachable && setup.boxConnection.isUnreachable })

        let choices = Dictionary(uniqueKeysWithValues: setup.model.choices.map { ($0.id, $0) })
        #expect(choices[setup.macConnection.id]?.isAvailable == false)
        #expect(choices[setup.boxConnection.id]?.isAvailable == true)
        #expect(choices[setup.boxConnection.id]?.wakesFirst == true)
        setup.model.open()
        #expect(setup.model.serverID == setup.boxConnection.id)
    }

    @Test func startSendsTheFieldsAndOpensThePane() async throws {
        let setup = try await setUp()
        mac.on(PhoneMethod.newRow, made(pane: "p9"))
        let model = setup.model
        model.serverID = setup.macConnection.id
        model.open()
        #expect(model.repo == "canopy")
        model.repo = "solis"
        model.branch = " feat/login "
        model.base = "  "
        model.brief = "Fix it's login\nwhole"

        let pane = await model.start()

        #expect(pane == PaneRef(server: setup.macConnection.id, pane: "p9"))
        #expect(
            newRowRequests(mac) == [
                PhoneNewRowParams(repo: "solis", branch: "feat/login", brief: "Fix it's login\nwhole")
            ]
        )
        #expect(model.branch.isEmpty && model.brief.isEmpty && model.repo == "solis")
        #expect(model.problem == nil && model.phase == .editing)
    }

    @Test func aRefusedBranchKeepsTheSheet() async throws {
        let setup = try await setUp()
        mac.on(PhoneMethod.newRow) { _ in .error("branch_checked_out") }
        let model = setup.model
        model.serverID = setup.macConnection.id
        model.open()
        model.branch = "main"
        model.brief = "go"

        #expect(await model.start() == nil)

        #expect(model.problem?.code == "branch_checked_out")
        #expect(model.branch == "main" && model.brief == "go")
        #expect(model.canStart)
    }

    @Test func startWakesABoxFirst() async throws {
        let box = box
        let setup = try await setUp(ec2: FakeEC2([FakeEC2.pending]) { box.comeBack() })
        box.on(PhoneMethod.newRow, made(pane: "b4"))
        box.goAway()
        #expect(await eventually { setup.boxConnection.isUnreachable })
        let model = setup.model
        model.serverID = setup.boxConnection.id
        model.open()
        model.branch = "feat/woken"

        let starting = Task { await model.start() }
        #expect(await eventually { model.phase == .waking })
        #expect(await eventually { setup.boxConnection.isConnected })
        await waits.wake()

        #expect(await starting.value == PaneRef(server: setup.boxConnection.id, pane: "b4"))
        #expect(newRowRequests(box).map(\.branch) == ["feat/woken"])
    }

    @Test func aFailedWakeMakesNoRow() async throws {
        let setup = try await setUp(
            ec2: FakeEC2([(401, FakeEC2.error("AuthFailure", "AWS was not able to validate the credentials."))]))
        box.goAway()
        #expect(await eventually { setup.boxConnection.isUnreachable })
        let model = setup.model
        model.serverID = setup.boxConnection.id
        model.open()
        model.branch = "feat/never"

        #expect(await model.start() == nil)

        #expect(model.problem?.title == "AWS refused hindie-box's wake key.")
        #expect(newRowRequests(box).isEmpty)
        #expect(model.branch == "feat/never")
    }

    @Test func anOlderServerSaysToUpdate() async throws {
        let setup = try await setUp()
        mac.on(PhoneMethod.newRow) { _ in .error("method_not_allowed") }
        let model = setup.model
        model.serverID = setup.macConnection.id
        model.open()
        model.branch = "x"

        #expect(await model.start() == nil)

        #expect(model.problem?.title == "Canopy on Studio can't start tasks from the phone.")
        #expect(model.problem?.detail == "Update Canopy there, then start the task again.")
    }

    @Test func reposComeFromRowsOrAreTyped() async throws {
        let setup = try await setUp()
        let model = setup.model

        model.serverID = setup.macConnection.id
        #expect(model.repos == ["canopy", "solis"])
        model.repo = "solis"
        model.serverID = setup.boxConnection.id
        model.chose()
        #expect(model.repo == "solis")

        model.serverID = "unknown"
        #expect(model.repos.isEmpty)
        #expect(!model.canStart)
    }
}
