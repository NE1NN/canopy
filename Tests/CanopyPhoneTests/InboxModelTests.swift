import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct InboxModelTests {
    let mac = FakeMac()

    @Test func theInboxHoldsWhatNeedsTheAuthor() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        #expect(model.sections.needsYou.map(\.row.name) == ["feat/ios-companion", "#0853"])
        #expect(model.sections.done.map(\.row.name) == ["fix/port-scan-drain"])
        #expect(model.badgeCount == 3)
        #expect(model.runningCount == 2)
    }

    @Test func markReadHidesTheItemAtOnce() async throws {
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
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
        let other = PhoneRow(
            path: "/canopy-other", name: "feat/other", repo: "canopy",
            agents: [Rows.agent("p6", .done, since: 1_200, unseen: true, line: "Merged.")])
        let connection = try await connected(to: mac, inbox: PhoneInbox(rows: Rows.inbox.rows + [other]))
        let model = InboxModel(connection: connection)
        #expect(model.sections.done.count == 2)
        await model.markAllRead()
        #expect(model.sections.done.isEmpty)
        let panes = try mac.requests.filter { $0.method == PhoneMethod.seen }
            .map { try $0.decodeParams(PhonePaneParams.self).pane }
        #expect(Set(panes) == ["p4", "p6"])
        #expect(model.sections.needsYou.count == 2)
    }

    @Test func markingReadWhileTheMacIsAwayKeepsTheItem() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
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
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        await model.markRead(try #require(model.sections.done.first))
        #expect(model.sections.done.isEmpty)
        var drain = Rows.drain
        drain.agents = [Rows.agent("p4", .done, since: 2_000, unseen: true, line: "READY again")]
        mac.setInbox(PhoneInbox(rows: [Rows.main, Rows.companion, drain, Rows.labels, Rows.ticket]))
        #expect(await eventually { model.sections.done.map(\.agent.lastLine) == ["READY again"] })
    }

    @Test func allowAndDenyAnswerThePromptByItsID() async throws {
        mac.on(PhoneMethod.answer) { .result(($0.params ?? .null)) }
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
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
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        let item = try #require(model.sections.needsYou.first { $0.agent.prompt != nil })
        await model.answer(item, allow: true)
        #expect(model.notice?.title == "That prompt moved on before your answer reached it.")
        #expect(model.sections.needsYou.contains(item))
        model.dismissNotice()
        #expect(model.notice == nil)
    }

    @Test func anAnswerWhileTheMacIsOutOfReachSaysSo() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        let item = try #require(model.sections.needsYou.first { $0.agent.prompt != nil })
        await model.answer(item, allow: true)
        #expect(model.notice?.title == "Can't reach Studio.")
        #expect(!mac.requests.contains { $0.method == PhoneMethod.answer })
    }

    @Test func theInboxIsStaleWhileTheMacIsOutOfReach() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
        #expect(!model.isStale)
        let asOf = try #require(connection.inboxAsOf)
        mac.goAway()
        #expect(await eventually { model.isStale })
        #expect(model.asOf == asOf)
        #expect(model.sections.needsYou.count == 2)
    }

    @Test func labelsNamePluginsAndReposOnlyWhenThereAreSeveral() async throws {
        let connection = try await connected(to: mac, inbox: Rows.inbox)
        let model = InboxModel(connection: connection)
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
