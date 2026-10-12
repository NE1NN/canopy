import CanopyWire
import Foundation
import Synchronization
import Testing

@testable import CanopyPhone

@MainActor
struct ConversationModelTests {
    let mac = FakeMac()

    nonisolated static func entry(
        _ id: String, _ kind: TranscriptEntry.Kind = .text, _ text: String? = nil, at: Double = 1_000
    )
        -> TranscriptEntry
    {
        TranscriptEntry(id: id, kind: kind, text: text ?? "text \(id)", at: at)
    }

    static let question = OpenPrompt(
        id: "q1", kind: .question,
        questions: [
            PromptQuestion(
                question: "Tailscale or a tunnel?", options: [.init(label: "Tailscale"), .init(label: "Tunnel")])
        ])

    static func inbox(_ agent: PhoneAgent?) -> PhoneInbox {
        PhoneInbox(rows: [
            PhoneRow(path: "/c", name: "feat/ios-companion", repo: "canopy", agents: agent.map { [$0] } ?? [])
        ])
    }

    static let waiting = Rows.agent("p3", .waiting, prompt: question)

    /// Serves `newest` as the newest page with `older` before it, and records each request's subscription.
    func serveTranscript(newest: [TranscriptEntry], older: [TranscriptEntry] = []) {
        mac.on(PhoneMethod.transcript) { request in
            guard let params = try? request.decodeParams(PhoneTranscriptParams.self) else {
                return .error("bad_params")
            }
            let page =
                params.before == nil
                ? PhoneTranscriptResult(pane: params.pane, entries: newest, older: older.isEmpty ? nil : 500)
                : PhoneTranscriptResult(pane: params.pane, entries: older, older: nil)
            return .result((try? .from(page)) ?? .null)
        }
    }

    func follows() -> [ControlRequest] {
        mac.requests.filter {
            $0.method == PhoneMethod.transcript && ((try? $0.decodeParams(PhoneTranscriptParams.self).follow) ?? false)
        }
    }

    func model(_ agent: PhoneAgent = waiting) async throws -> ConversationModel {
        let connection = try await connected(to: mac, inbox: Self.inbox(agent))
        let model = ConversationModel(connection: connection, pane: agent.pane)
        model.start()
        return model
    }

    @Test func theFirstPageThenEntriesAddedAndGrownByID() async throws {
        serveTranscript(newest: [Self.entry("a", .prompt), Self.entry("b", .tools, "Read a.swift")])
        let model = try await model()
        #expect(await eventually { model.entries.map(\.id) == ["a", "b"] })
        let follow = try #require(follows().first)
        #expect(
            try follow.decodeParams(PhoneTranscriptParams.self)
                == PhoneTranscriptParams(pane: "p3", limit: 50, follow: true))
        mac.emit(
            PhoneEvent.transcript, subscription: follow.id,
            PhoneTranscriptUpdate(
                pane: "p3", entries: [Self.entry("b", .tools, "Read a.swift and 2 more"), Self.entry("c")]))
        #expect(await eventually { model.entries.map(\.id) == ["a", "b", "c"] })
        #expect(model.entries[1].text == "Read a.swift and 2 more")
    }

    @Test func aResetReplacesEverything() async throws {
        serveTranscript(newest: [Self.entry("a"), Self.entry("b")])
        let model = try await model()
        #expect(await eventually { model.entries.count == 2 })
        let follow = try #require(follows().first)
        mac.emit(
            PhoneEvent.transcript, subscription: follow.id,
            PhoneTranscriptUpdate(pane: "p3", entries: [Self.entry("x")], reset: true, older: 99))
        #expect(await eventually { model.entries.map(\.id) == ["x"] })
        #expect(model.older == 99)
    }

    @Test func olderPagesGoInFrontOnce() async throws {
        serveTranscript(
            newest: [Self.entry("c"), Self.entry("d")], older: [Self.entry("a"), Self.entry("b"), Self.entry("c")])
        let model = try await model()
        #expect(await eventually { model.older == 500 })
        await model.loadOlder()
        #expect(model.entries.map(\.id) == ["a", "b", "c", "d"])
        #expect(model.older == nil)
        await model.loadOlder()
        #expect(mac.requests.filter { $0.method == PhoneMethod.transcript }.count == 2)
    }

    @Test func aConversationFollowsAgainAfterTheMacComesBack() async throws {
        let served = Mutex([Self.entry("a"), Self.entry("b")])
        mac.on(PhoneMethod.transcript) { request in
            let page = PhoneTranscriptResult(pane: "p3", entries: served.withLock { $0 }, older: nil)
            return .result((try? .from(page)) ?? .null)
        }
        let sleeper = ManualSleeper()
        let connection = try await connected(to: mac, inbox: Self.inbox(Self.waiting), sleeper: sleeper)
        let model = ConversationModel(connection: connection, pane: "p3")
        model.start()
        #expect(await eventually { model.entries.map(\.id) == ["a", "b"] })
        // While away, b grew and c came.
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        served.withLock { $0 = [Self.entry("b", .text, "b, grown"), Self.entry("c")] }
        mac.comeBack()
        connection.foreground()
        #expect(await eventually { follows().count == 2 })
        #expect(await eventually { model.entries.map(\.id) == ["a", "b", "c"] })
        #expect(model.entries[1].text == "b, grown")
    }

    @Test func aReplyGoesSentThenDeliveredAndLeavesOnceTheTranscriptHasIt() async throws {
        serveTranscript(newest: [Self.entry("a")])
        mac.on(PhoneMethod.reply) { request in .result((try? .from(PhoneReplyResult(reply: request.id))) ?? .null) }
        let model = try await model(Rows.agent("p3", .done))
        #expect(await eventually { model.entries.count == 1 })
        model.draft = "Use Tailscale.\nKeep it private."
        await model.send()
        let reply = try #require(await mac.request(PhoneMethod.reply))
        #expect(
            try reply.decodeParams(PhoneReplyParams.self)
                == PhoneReplyParams(pane: "p3", text: "Use Tailscale.\nKeep it private."))
        #expect(model.draft == "")
        #expect(model.pending?.state == .sent)
        #expect(model.pending?.text == "Use Tailscale.\nKeep it private.")
        mac.emit(PhoneEvent.delivered, subscription: reply.id, PhoneDelivered(pane: "p3", reply: reply.id))
        #expect(await eventually { model.pending?.state == .delivered })
        let follow = try #require(follows().first)
        mac.emit(
            PhoneEvent.transcript, subscription: follow.id,
            PhoneTranscriptUpdate(pane: "p3", entries: [Self.entry("r", .prompt, "Use Tailscale.\nKeep it private.")]))
        #expect(await eventually { model.pending == nil })
    }

    @Test(arguments: ["prompt_open", "agent_not_running"])
    func aReplyThatFailsStaysInTheBox(_ code: String) async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.reply) { _ in .error(code) }
        let model = try await model(Rows.agent("p3", .done))
        model.draft = "Ship it"
        await model.send()
        #expect(model.draft == "Ship it")
        #expect(model.pending == nil)
        #expect(model.replyProblem?.code == code)
    }

    @Test func aReplyCutOffByADropStaysInTheBox() async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.reply) { _ in .silent }
        let model = try await model(Rows.agent("p3", .done))
        model.draft = "Ship it"
        let sending = Task { await model.send() }
        _ = await mac.request(PhoneMethod.reply)
        #expect(model.pending?.state == .sending)
        mac.goAway()
        await sending.value
        #expect(model.draft == "Ship it")
        #expect(model.pending == nil)
        #expect(model.replyProblem?.title == "Lost the connection to Studio.")
    }

    @Test func anEmptyReplySendsNothing() async throws {
        serveTranscript(newest: [])
        let model = try await model(Rows.agent("p3", .done))
        model.draft = "  \n "
        await model.send()
        #expect(!mac.requests.contains { $0.method == PhoneMethod.reply })
    }

    @Test func oneQuestionWithOneChoiceAnswersOnTap() async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.answer) { .result($0.params ?? .null) }
        let model = try await model()
        await model.choose(question: 0, option: 1)
        let answer = try #require(await mac.request(PhoneMethod.answer))
        #expect(
            try answer.decodeParams(PhoneAnswerParams.self)
                == PhoneAnswerParams(pane: "p3", prompt: "q1", answer: PhoneAnswer(options: [[1]])))
    }

    @Test func severalQuestionsAnswerOnceEachHasAChoice() async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.answer) { .result($0.params ?? .null) }
        let prompt = OpenPrompt(
            id: "q2", kind: .question,
            questions: [
                PromptQuestion(question: "Color?", options: [.init(label: "Red"), .init(label: "Blue")]),
                PromptQuestion(
                    question: "Fruit?", options: [.init(label: "Apple"), .init(label: "Plum"), .init(label: "Fig")],
                    multiSelect: true),
            ])
        let model = try await model(Rows.agent("p3", .waiting, prompt: prompt))
        await model.choose(question: 0, option: 0)
        await model.choose(question: 0, option: 1)
        #expect(!model.canSubmitAnswers)
        await model.choose(question: 1, option: 0)
        await model.choose(question: 1, option: 2)
        await model.choose(question: 1, option: 0)
        await model.choose(question: 1, option: 1)
        #expect(model.selections == [[1], [1, 2]])
        #expect(model.canSubmitAnswers)
        #expect(!mac.requests.contains { $0.method == PhoneMethod.answer })
        await model.submitAnswers()
        let answer = try #require(await mac.request(PhoneMethod.answer))
        #expect(try answer.decodeParams(PhoneAnswerParams.self).answer == PhoneAnswer(options: [[1], [1, 2]]))
    }

    @Test func aPromptThatMovedOnClearsTheChoicesAndSaysWhy() async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.answer) { _ in .error("prompt_gone") }
        let model = try await model()
        await model.choose(question: 0, option: 0)
        #expect(model.answerProblem?.title == "That prompt moved on before your answer reached it.")
        #expect(model.selections == [[]])
        #expect(!model.isAnswering)
    }

    @Test func allowAndDenyAnswerAPermissionOrAPlan() async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.answer) { .result($0.params ?? .null) }
        let model = try await model(Rows.agent("p3", .waiting, prompt: Rows.permission))
        await model.allow()
        await model.deny()
        let answers = try mac.requests.filter { $0.method == PhoneMethod.answer }.map {
            try $0.decodeParams(PhoneAnswerParams.self)
        }
        #expect(answers.map(\.answer) == [PhoneAnswer(allow: true), PhoneAnswer(allow: false)])
        #expect(answers.map(\.prompt) == ["prompt-1", "prompt-1"])
    }

    @Test func openingADoneAgentMarksItSeenAndSoDoesOneFinishingWhileOpen() async throws {
        serveTranscript(newest: [])
        mac.on(PhoneMethod.seen) { .result($0.params ?? .null) }
        _ = try await model(Rows.agent("p3", .done, since: 1_000, unseen: true))
        #expect(await eventually { mac.requests.filter { $0.method == PhoneMethod.seen }.count == 1 })
        mac.setInbox(Self.inbox(Rows.agent("p3", .done, since: 1_000, unseen: false)))
        mac.setInbox(Self.inbox(Rows.agent("p3", .working, since: 1_100)))
        mac.setInbox(Self.inbox(Rows.agent("p3", .done, since: 1_200, unseen: true)))
        #expect(await eventually { mac.requests.filter { $0.method == PhoneMethod.seen }.count == 2 })
        let seen = try #require(await mac.request(PhoneMethod.seen, number: 2))
        #expect(try seen.decodeParams(PhonePaneParams.self) == PhonePaneParams(pane: "p3"))
    }

    @Test func aPaneThatClosesKeepsWhatItShowedAndStopsFollowing() async throws {
        let gone = Mutex(false)
        mac.on(PhoneMethod.transcript) { request in
            if gone.withLock({ $0 }) { return .error("pane_not_found") }
            return .result(
                (try? .from(PhoneTranscriptResult(pane: "p3", entries: [Self.entry("a")], older: nil))) ?? .null)
        }
        let model = try await model()
        #expect(await eventually { model.entries.count == 1 })
        gone.withLock { $0 = true }
        mac.setInbox(Self.inbox(nil))
        #expect(await eventually { model.paneGone })
        #expect(model.entries.map(\.id) == ["a"])
        #expect(model.row?.name == "feat/ios-companion")
        #expect(await eventually { mac.requests.contains { $0.method == PhoneMethod.unsubscribe } })
    }

    @Test func anAgentThatEndsIsNotAPaneThatClosed() async throws {
        serveTranscript(newest: [Self.entry("a")])
        let model = try await model()
        #expect(await eventually { model.entries.count == 1 })
        mac.setInbox(Self.inbox(nil))
        _ = await eventually { mac.requests.filter { $0.method == PhoneMethod.transcript }.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.paneGone)
    }

    @Test func noTranscriptOpensTerminalAndChatSaysWhy() async throws {
        mac.on(PhoneMethod.transcript) { _ in .error("no_transcript") }
        let model = try await model(Rows.agent("p3", .working, transcript: false))
        #expect(model.tab == .terminal)
        #expect(!model.hasTranscript)
        try await Task.sleep(for: .milliseconds(50))
        #expect(follows().isEmpty)
        #expect(
            model.chatNote == "No conversation to show. Chat reads Claude Code's transcript, and this pane has none.")
    }

    @Test func stoppingUnsubscribes() async throws {
        serveTranscript(newest: [Self.entry("a")])
        let model = try await model()
        #expect(await eventually { model.entries.count == 1 })
        let follow = try #require(follows().first)
        model.stop()
        let unsubscribe = try #require(await mac.request(PhoneMethod.unsubscribe))
        #expect(try unsubscribe.decodeParams(PhoneUnsubscribeParams.self).subscription == follow.id)
    }
}
