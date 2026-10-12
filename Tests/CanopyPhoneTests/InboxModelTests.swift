import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct InboxModelTests {
    let mac = FakeMac()

    @Test func sectionsFollowPinsAndPinnedAgentsStayWithTheirRow() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        model.start()
        #expect(await eventually { model.sections.pinned.map(\.name) == ["main"] })
        #expect(model.sections.needsYou.map(\.row.name) == ["#0853", "feat/ios-companion"])
        #expect(model.sections.done.map(\.row.name) == ["fix/port-scan-drain"])
        #expect(model.sections.running.map(\.row.name) == ["feat/port-labels"])
        #expect(model.waitingCount == 2)
        #expect(model.agentCount == 5)
    }

    @Test func theFirstInboxPinsMainCheckoutsOnce() async throws {
        let defaults = freshDefaults()
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let pins = PinStore(defaults: defaults)
        let model = InboxModel(connection: connection, pins: pins)
        model.start()
        #expect(await eventually { pins.pins == ["/canopy"] })
        model.togglePin(Rows.main)
        #expect(pins.pins.isEmpty)
        // A later inbox, or a later launch, leaves the author's choice alone.
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [Rows.idle]))
        let relaunched = InboxModel(connection: connection, pins: PinStore(defaults: defaults))
        relaunched.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(PinStore(defaults: defaults).pins.isEmpty)
        #expect(relaunched.sections.pinned.isEmpty)
    }

    @Test func noAgentInAMainCheckoutPinsNothingYet() async throws {
        let idleMain = PhoneRow(path: "/canopy", name: "main", repo: "canopy", isMain: true)
        let connection = try await connected(to: mac, inbox: PhoneInbox(rows: [idleMain, Rows.labels]))
        let pins = PinStore(defaults: freshDefaults())
        let model = InboxModel(connection: connection, pins: pins)
        model.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(pins.pins.isEmpty)
        mac.setInbox(Rows.inbox)
        #expect(await eventually { pins.pins == ["/canopy"] })
    }

    @Test func pinningAnyRowPutsItOnTop() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        model.start()
        _ = await eventually { model.isPinned(Rows.main) }
        model.togglePin(Rows.drain)
        #expect(model.sections.pinned.map(\.name) == ["main", "fix/port-scan-drain"])
        #expect(model.sections.done.isEmpty)
    }

    @Test func allowAndDenyAnswerThePromptByItsID() async throws {
        mac.on(PhoneMethod.answer) { .result(($0.params ?? .null)) }
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        let item = try #require(model.sections.needsYou.first)
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
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        let item = try #require(model.sections.needsYou.first)
        await model.answer(item, allow: true)
        #expect(model.notice?.title == "That prompt moved on before your answer reached it.")
        #expect(model.sections.needsYou.first == item)
        model.dismissNotice()
        #expect(model.notice == nil)
    }

    @Test func anAnswerWhileTheMacIsOutOfReachSaysSo() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        let item = try #require(model.sections.needsYou.first)
        await model.answer(item, allow: true)
        #expect(model.notice?.title == "Can't reach Studio.")
        #expect(!mac.requests.contains { $0.method == PhoneMethod.answer })
    }

    @Test func theInboxIsStaleWhileTheMacIsOutOfReach() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        #expect(!model.isStale)
        let asOf = try #require(connection.inboxAsOf)
        mac.goAway()
        #expect(await eventually { model.isStale })
        #expect(model.asOf == asOf)
        #expect(model.sections.needsYou.count == 2)
    }

    @Test func labelsNamePluginsAndReposOnlyWhenThereAreSeveral() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection, pins: PinStore(defaults: freshDefaults()))
        #expect(model.label(for: Rows.ticket) == "ticket")
        #expect(model.label(for: Rows.companion) == nil)
        let other = PhoneRow(path: "/web", name: "main", repo: "web-app", isMain: true)
        mac.setInbox(PhoneInbox(rows: Rows.inbox.rows + [other]))
        #expect(await eventually { model.label(for: Rows.companion) == "canopy" })
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
