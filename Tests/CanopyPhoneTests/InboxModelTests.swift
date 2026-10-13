import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct InboxModelTests {
    let mac = FakeMac()
    static let other = PhoneRow(
        path: "/canopy-other", name: "feat/other", repo: "canopy",
        agents: [Rows.agent("p6", .done, since: 1_200, unseen: true, line: "Merged.")])

    @Test func theInboxHoldsWhatNeedsTheAuthor() async throws {
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        #expect(model.sections.needsYou.map(\.row.name) == ["feat/ios-companion", "#0853"])
        #expect(model.sections.done.map(\.row.name) == ["fix/port-scan-drain"])
        #expect(model.badgeCount == 3)
        #expect(model.runningCount == 2)
    }

    @Test func markReadHidesTheItemAtOnce() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        let item = try #require(model.sections.done.first)
        await model.markRead(item)
        #expect(model.sections.done.isEmpty)
        #expect(model.badgeCount == 2)
        let seen = try #require(await mac.request(PhoneMethod.seen))
        #expect(try seen.decodeParams(PhonePaneParams.self) == PhonePaneParams(pane: "p4"))
        // The Mac resends its inbox before it has caught up: the item stays hidden.
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [Rows.idle]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.sections.done.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func markAllReadSendsSeenForEachDoneItem() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [Self.other]))
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        #expect(model.sections.done.count == 2)
        await model.markAllRead()
        #expect(model.sections.done.isEmpty)
        let panes = try mac.requests.filter { $0.method == PhoneMethod.seen }
            .map { try $0.decodeParams(PhonePaneParams.self).pane }
        #expect(Set(panes) == ["p4", "p6"])
        #expect(model.sections.needsYou.count == 2)
    }

    @Test func markAllReadKeepsWhatTheMacTookWhenAnotherFails() async throws {
        mac.on(PhoneMethod.seen) { request in
            let pane = (try? request.decodeParams(PhonePaneParams.self))?.pane
            return pane == "p4" ? .error("internal") : .result(request.params ?? .null)
        }
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [Self.other]))
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        await model.markAllRead()
        #expect(model.sections.done.map(\.agent.pane) == ["p4"])
        #expect(model.notice != nil)
        let panes = try mac.requests.filter { $0.method == PhoneMethod.seen }
            .map { try $0.decodeParams(PhonePaneParams.self).pane }
        #expect(Set(panes) == ["p4", "p6"])
    }

    @Test func aPaneThatClosedCountsAsRead() async throws {
        mac.on(PhoneMethod.seen) { _ in .error("pane_not_found") }
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        await model.markRead(try #require(model.sections.done.first))
        #expect(model.sections.done.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func caughtUpCountsRunningAgentsWhileConnected() async throws {
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        #expect(model.caughtUpDetail == "Nothing is waiting for you.\n2 agents are running.")
        mac.setInbox(PhoneInbox(rows: [Rows.idle]))
        #expect(await eventually { model.caughtUpDetail == "Nothing is waiting for you." })
    }

    @Test func caughtUpOutOfReachSaysWhenItWasTrue() async throws {
        mac.setInbox(PhoneInbox(rows: [Rows.main, Rows.idle]))
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        mac.goAway()
        #expect(await eventually { model.isStale })
        #expect(model.caughtUpDetail.hasPrefix("Nothing was waiting as of "))
        #expect(!model.caughtUpDetail.contains("running"))
    }

    @Test func markingReadWhileTheMacIsAwayKeepsTheItem() async throws {
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        let item = try #require(model.sections.done.first)
        await model.markRead(item)
        #expect(model.sections.done == [item])
        #expect(model.notice?.title == "Can't reach Studio.")
        #expect(!mac.requests.contains { $0.method == PhoneMethod.seen })
    }

    @Test func anAgentThatFinishesAgainComesBack() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        await model.markRead(try #require(model.sections.done.first))
        #expect(model.sections.done.isEmpty)
        var drain = Rows.drain
        drain.agents = [Rows.agent("p4", .done, since: 2_000, unseen: true, line: "READY again")]
        mac.setInbox(PhoneInbox(rows: [Rows.main, Rows.companion, drain, Rows.labels, Rows.ticket]))
        #expect(await eventually { model.sections.done.map(\.agent.lastLine) == ["READY again"] })
    }

    @Test func allowAndDenyAnswerThePromptByItsID() async throws {
        mac.on(PhoneMethod.answer) { .result(($0.params ?? .null)) }
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        let item = try #require(model.sections.needsYou.first { $0.agent.prompt != nil })
        await model.answer(item, allow: true)
        await model.answer(item, allow: false)
        let answers = mac.requests.filter { $0.method == PhoneMethod.answer }
        #expect(
            try answers.map { try $0.decodeParams(PhoneAnswerParams.self) } == [
                PhoneAnswerParams(pane: "p2", prompt: "prompt-1", answer: PhoneAnswer(allow: true)),
                PhoneAnswerParams(pane: "p2", prompt: "prompt-1", answer: PhoneAnswer(allow: false)),
            ])
        #expect(model.notice == nil)
        #expect(model.answering.isEmpty)
    }

    @Test func aPromptThatMovedOnSaysSo() async throws {
        mac.on(PhoneMethod.answer) { _ in .error("prompt_gone") }
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        let item = try #require(model.sections.needsYou.first { $0.agent.prompt != nil })
        await model.answer(item, allow: true)
        #expect(model.notice?.title == "That prompt moved on before your answer reached it.")
        #expect(model.sections.needsYou.contains(item))
        model.dismissNotice()
        #expect(model.notice == nil)
    }

    @Test func anAnswerWhileTheMacIsOutOfReachSaysSo() async throws {
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        let item = try #require(model.sections.needsYou.first { $0.agent.prompt != nil })
        await model.answer(item, allow: true)
        #expect(model.notice?.title == "Can't reach Studio.")
        #expect(!mac.requests.contains { $0.method == PhoneMethod.answer })
    }

    @Test func theInboxIsStaleWhileTheMacIsOutOfReach() async throws {
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        #expect(!model.isStale)
        let asOf = try #require(connection.inboxAsOf)
        mac.goAway()
        #expect(await eventually { model.isStale })
        #expect(model.asOf == asOf)
        #expect(model.sections.needsYou.count == 2)
    }

    @Test func labelsNamePluginsAndReposOnlyWhenThereAreSeveral() async throws {
        mac.setInbox(Rows.inbox)
        let servers = try await servers(mac)
        let connection = try #require(servers.connections.first)
        let model = InboxModel(servers: servers)
        #expect(model.label(for: Rows.ticket) == "ticket")
        #expect(model.label(for: Rows.companion) == nil)
        let other = PhoneRow(path: "/web", name: "main", repo: "web-app", isMain: true)
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [other]))
        #expect(await eventually { model.label(for: Rows.companion) == "canopy" })
    }
}

@MainActor
struct InboxAcrossServersTests {
    let mac = FakeMac()
    let box = FakeMac.box()

    /// The box's `p3` and the Mac's `p3` are two agents, and each answer and seen goes to its own server.
    @Test func samePaneOnTwoServersStaysApart() async throws {
        mac.setInbox(Rows.inbox)
        box.setInbox(
            PhoneInbox(rows: [
                PhoneRow(
                    path: "/home/ubuntu/feat", name: "feat/box", repo: "solis-v1",
                    agents: [
                        Rows.agent("p3", .waiting, since: 1_750, prompt: Rows.permission),
                        Rows.agent("p4", .done, since: 1_150, unseen: true),
                    ])
            ]))
        for server in [mac, box] {
            server.on(PhoneMethod.answer) { .result($0.params ?? .null) }
            server.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        }
        let model = InboxModel(servers: try await servers(mac, box))
        #expect(model.sections.needsYou.map(\.row.name) == ["feat/ios-companion", "feat/box", "#0853"])
        #expect(Set(model.sections.needsYou.map(\.ref)).count == 3)

        let boxItem = try #require(model.sections.needsYou.first { $0.server.isBox })
        await model.answer(boxItem, allow: true)
        let boxDone = try #require(model.sections.done.first { $0.server.isBox })
        await model.markRead(boxDone)

        #expect(box.requests.filter { $0.method == PhoneMethod.answer }.count == 1)
        #expect(!mac.requests.contains { $0.method == PhoneMethod.answer })
        #expect(
            try box.requests.filter { $0.method == PhoneMethod.seen }.map {
                try $0.decodeParams(PhonePaneParams.self).pane
            } == ["p4"])
        #expect(!mac.requests.contains { $0.method == PhoneMethod.seen })
        // The Mac's own p4 is still unread.
        #expect(model.sections.done.map(\.row.name) == ["fix/port-scan-drain"])
    }

    @Test func theInboxMergesServersByTime() async throws {
        mac.setInbox(PhoneInbox(rows: [Rows.companion, Rows.drain]))
        box.setInbox(
            PhoneInbox(rows: [
                PhoneRow(
                    path: "/b1", name: "feat/early", repo: "solis-v1",
                    agents: [Rows.agent("b1", .waiting, since: 1_600)]),
                PhoneRow(
                    path: "/b2", name: "feat/same", repo: "solis-v1", agents: [Rows.agent("b2", .waiting, since: 1_700)]
                ),
                PhoneRow(
                    path: "/b3", name: "feat/late", repo: "solis-v1",
                    agents: [Rows.agent("b3", .done, since: 1_300, unseen: true)]),
            ]))
        let model = InboxModel(servers: try await servers(mac, box))

        // Equal times keep the pairing order: the Mac's companion before the box's.
        #expect(model.sections.needsYou.map(\.row.name) == ["feat/early", "feat/ios-companion", "feat/same"])
        #expect(model.sections.done.map(\.row.name) == ["feat/late", "fix/port-scan-drain"])
        #expect(model.badgeCount == 5)
    }

    @Test func oneServerOutOfReachLeavesTheOthers() async throws {
        mac.setInbox(PhoneInbox(rows: [Rows.companion]))
        box.setInbox(
            PhoneInbox(rows: [
                PhoneRow(
                    path: "/b1", name: "feat/box", repo: "solis-v1", agents: [Rows.agent("b1", .waiting, since: 1_600)])
            ]))
        let model = InboxModel(servers: try await servers(mac, box))

        box.goAway()

        #expect(await eventually { model.staleServers.map(\.name) == ["hindie-box"] })
        #expect(!model.isStale)
        #expect(model.sections.needsYou.map(\.row.name) == ["feat/box", "feat/ios-companion"])
        #expect(model.staleBanner?.title == "Can't reach hindie-box.")
        mac.goAway()
        #expect(await eventually { model.isStale })
        #expect(model.staleBanner?.title == "Can't reach Studio and hindie-box.")
    }

    @Test func theLineAboveTheInboxNamesWhatIsOutOfReach() async throws {
        mac.setInbox(Rows.inbox)
        box.setInbox(PhoneInbox())
        let model = InboxModel(servers: try await servers(mac, box))
        #expect(model.connectionLine == .init(state: .connected, text: "Studio and hindie-box connected"))

        box.goAway()
        #expect(await eventually { model.connectionLine == .init(state: .unreachable, text: "Can't reach hindie-box") })
        mac.goAway()
        #expect(await eventually { model.connectionLine.text.hasPrefix("As of ") })
    }

    @Test func theMacsCopyOfABoxRowIsLeftOut() async throws {
        var copy = PhoneRow(
            path: "/Users/h/.canopy/remote/hindie-box/feat", name: "feat/box", repo: "solis-v1",
            agents: [Rows.agent("p9", .waiting, since: 1_600)])
        copy.host = "hindie-box"
        mac.setInbox(PhoneInbox(rows: [Rows.companion, copy]))
        box.setInbox(
            PhoneInbox(rows: [
                PhoneRow(
                    path: "/b1", name: "feat/box", repo: "solis-v1", agents: [Rows.agent("b1", .waiting, since: 1_600)])
            ]))
        let servers = try await servers(mac, box)
        let model = InboxModel(servers: servers)

        #expect(
            model.sections.needsYou.map { "\($0.server.name) \($0.row.name)" } == [
                "hindie-box feat/box", "Studio feat/ios-companion",
            ])
        // Out of reach, the box still serves its own rows here, from what it last sent.
        box.goAway()
        #expect(await eventually { model.staleServers.count == 1 })
        #expect(model.sections.needsYou.count == 2)
        // Removed, the box leaves the Mac's copy to show.
        servers.remove(id: try #require(servers.connections.last).id)
        #expect(
            model.sections.needsYou.map { "\($0.server.name) \($0.row.name)" } == [
                "Studio feat/box", "Studio feat/ios-companion",
            ])
    }
}

struct RelativeTimeTests {
    @Test(
        arguments: [
            (0.0, "now"), (59.0, "now"), (60.0, "1m"), (899.0, "14m"), (3_600.0, "1h"), (82_800.0, "23h"),
            (86_400.0, "1d"), (777_600.0, "9d"), (-30.0, "now"),
        ] as [(Double, String)])
    func shortTimes(_ age: Double, _ text: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RelativeTime.short(since: 1_000_000 - age, now: now) == text)
    }
}
