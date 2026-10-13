import CanopyWire
import Foundation
import Observation

/// One pane's conversation: its transcript as it grows, the reply box, and answers to its open prompt.
@MainActor @Observable
public final class ConversationModel {
    public enum Tab: Hashable, Sendable {
        case chat
        case terminal
    }

    /// A reply on its way, shown at the end of the chat until the transcript has it.
    public struct PendingReply: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case sending
            /// The Mac pasted it into the pane.
            case sent
            /// The agent took it as its next prompt.
            case delivered
        }

        public var text: String
        public var state: State
    }

    public let connection: MacConnection
    public let pane: String
    public private(set) var entries: [TranscriptEntry] = []
    /// The cursor for the next older page, or nil at the start of the conversation.
    public private(set) var older: Int?
    public private(set) var hasLoaded = false
    public private(set) var isLoadingOlder = false
    public var tab: Tab
    public var draft = ""
    public private(set) var pending: PendingReply?
    public private(set) var replyProblem: PhoneProblem?
    public private(set) var answerProblem: PhoneProblem?
    public private(set) var isAnswering = false
    /// The chosen options of each of the open prompt's questions, counted from 0.
    public private(set) var selections: [[Int]] = []
    public private(set) var paneGone = false
    /// The row and agent as last seen in the inbox, kept once the pane is gone.
    public private(set) var row: PhoneRow?
    public private(set) var lastAgent: PhoneAgent?

    private var isStarted = false
    /// Counts starts, so the observers of an earlier start end rather than run next to the new ones.
    private var starts = 0
    /// Counts the times the conversation was replaced whole, so an older page asked for before cannot join the new one.
    private(set) var epoch = 0
    /// Why the conversation could not be followed, other than the pane closing.
    public private(set) var transcriptProblem: PhoneProblem?
    /// The last older page failed; the next try goes on a tap.
    public private(set) var olderFailed = false
    private var following: Task<Void, Never>?
    /// Whether the stream's loop runs, which ends for good once the phone has no Mac.
    private(set) var isFollowing = false
    private var subscription: (client: PhoneClient, id: String)?
    private var selectionsPrompt: String?
    private var seenSince: Double?
    private var promptsBeforeReply: Set<String> = []

    public init(connection: MacConnection, pane: String) {
        self.connection = connection
        self.pane = pane
        let found = Self.find(pane, in: connection.inbox)
        row = found?.row
        lastAgent = found?.agent
        tab = found?.agent.kind != .chat && found?.agent.hasTranscript == false ? .terminal : .chat
    }

    /// A chat tab on the Mac, which has no terminal to show.
    public var isChat: Bool { (agent ?? lastAgent)?.kind == .chat }

    /// The agent as the inbox has it now, or nil once it left the inbox.
    public var agent: PhoneAgent? { Self.find(pane, in: connection.inbox)?.agent }

    public var hasTranscript: Bool { (agent ?? lastAgent)?.hasTranscript ?? false }

    /// What the open prompt asks, while the pane has one.
    public var prompt: OpenPrompt? { paneGone ? nil : agent?.prompt }

    /// Why Chat has nothing, when it cannot.
    public var chatNote: String? {
        if !hasTranscript {
            return "No conversation to show. Chat reads Claude Code's transcript, and this pane has none."
        }
        if let transcriptProblem, entries.isEmpty { return transcriptProblem.title }
        if hasLoaded, entries.isEmpty, pending == nil { return "Nothing said yet." }
        return nil
    }

    public var canSend: Bool {
        !paneGone && pending?.state != .sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        starts += 1
        let start = starts
        let active: @MainActor () -> Bool = { [weak self] in self?.isStarted == true && self?.starts == start }
        observe({ [weak self] in self?.agent }, while: active) { [weak self] agent in self?.agentChanged(agent) }
        observe({ [weak self] in self?.hasTranscript ?? false }, while: active) { [weak self] has in
            if has { self?.follow() }
        }
    }

    public func stop() {
        isStarted = false
        following?.cancel()
        following = nil
        unsubscribe()
    }

    // MARK: Following

    private func follow() {
        guard following == nil, !paneGone else { return }
        following = Task { await self.run() }
    }

    private func run() async {
        isFollowing = true
        defer { isFollowing = false }
        var generation = 0
        while !Task.isCancelled, !paneGone {
            do {
                let connected = try await connection.client(after: generation)
                generation = connected.generation
                let stream = try await connected.client.stream(
                    PhoneMethod.transcript, PhoneTranscriptParams(pane: pane, limit: 50, follow: true),
                    as: PhoneTranscriptResult.self)
                guard !Task.isCancelled else {
                    try? await connected.client.unsubscribe(stream.subscription)
                    return
                }
                subscription = (connected.client, stream.subscription)
                merge(stream.result)
                hasLoaded = true
                transcriptProblem = nil
                for await event in stream.events {
                    if let update = try? event.data.decode(PhoneTranscriptUpdate.self) { apply(update) }
                }
                subscription = nil
            } catch is MacConnection.NotPaired {
                return
            } catch let error as ControlError {
                if error.code == "pane_not_found" {
                    closePane()
                } else if error.code != "no_transcript" {
                    transcriptProblem = connection.problem(error)
                }
                hasLoaded = true
                return
            } catch {
                // The connection dropped or the stream was stopped: wait for the next connection.
                if Task.isCancelled { return }
            }
        }
    }

    private func unsubscribe() {
        guard let subscription else { return }
        self.subscription = nil
        Task { try? await subscription.client.unsubscribe(subscription.id) }
    }

    /// A fresh newest page, as on a new connection, joins what the phone has where the two meet.
    private func merge(_ page: PhoneTranscriptResult) {
        let known = Set(entries.map(\.id))
        guard let meeting = page.entries.firstIndex(where: { known.contains($0.id) }),
            let keep = entries.firstIndex(where: { $0.id == page.entries[meeting].id })
        else {
            // Nothing in common: the conversation is a new one, or moved on further than a page.
            entries = page.entries
            older = page.older
            epoch += 1
            notePrompts()
            return
        }
        if keep == 0 {
            // The page reaches back at least as far as the phone did, so its cursor is the one to keep.
            entries = page.entries
            if meeting > 0 { older = page.older }
        } else {
            entries = Array(entries[..<keep]) + page.entries[meeting...]
        }
        notePrompts()
    }

    private func apply(_ update: PhoneTranscriptUpdate) {
        if update.reset {
            entries = update.entries
            older = update.older
            epoch += 1
        } else {
            for entry in update.entries {
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index] = entry
                } else {
                    entries.append(entry)
                }
            }
        }
        notePrompts()
    }

    public func loadOlder() async {
        guard let older, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let asked = epoch
        do {
            let page = try await connection.liveClient().call(
                PhoneMethod.transcript, PhoneTranscriptParams(pane: pane, before: older, limit: 50),
                as: PhoneTranscriptResult.self)
            olderFailed = false
            guard epoch == asked else { return }
            let known = Set(entries.map(\.id))
            entries = page.entries.filter { !known.contains($0.id) } + entries
            self.older = page.older
        } catch {
            olderFailed = true
        }
    }

    // MARK: The inbox

    private static func find(_ pane: String, in inbox: PhoneInbox?) -> (row: PhoneRow, agent: PhoneAgent)? {
        for row in inbox?.rows ?? [] {
            if let agent = row.agents.first(where: { $0.pane == pane }) { return (row, agent) }
        }
        return nil
    }

    private func agentChanged(_ agent: PhoneAgent?) {
        if let found = Self.find(pane, in: connection.inbox) {
            row = found.row
            lastAgent = found.agent
        } else if connection.inbox != nil, connection.isConnected, !paneGone {
            Task { await checkPane() }
        }
        if let agent, agent.state == .done, agent.unseen, seenSince != agent.since {
            seenSince = agent.since
            Task {
                _ = try? await connection.liveClient().call(
                    PhoneMethod.seen, PhonePaneParams(pane: pane), as: PhonePaneParams.self)
            }
        }
        if agent?.prompt?.id != selectionsPrompt {
            resetSelections()
        }
    }

    /// The pane left the inbox: its agent ended, or the pane closed. Only the Mac can tell which.
    private func checkPane() async {
        do {
            _ = try await connection.liveClient().call(
                PhoneMethod.transcript, PhoneTranscriptParams(pane: pane, limit: 1), as: PhoneTranscriptResult.self)
        } catch let error as ControlError where error.code == "pane_not_found" {
            closePane()
        } catch {}
    }

    private func closePane() {
        guard !paneGone else { return }
        paneGone = true
        following?.cancel()
        following = nil
        unsubscribe()
    }

    // MARK: Replies

    public func send() async {
        let text = draft
        guard canSend else { return }
        replyProblem = nil
        promptsBeforeReply = Set(entries.filter { $0.kind == .prompt }.map(\.id))
        pending = PendingReply(text: text, state: .sending)
        do {
            let client = try connection.liveClient()
            let stream = try await client.stream(
                PhoneMethod.reply, PhoneReplyParams(pane: pane, text: text), as: PhoneReplyResult.self)
            if draft == text { draft = "" }
            pending?.state = .sent
            notePrompts()
            Task {
                for await event in stream.events where event.event == PhoneEvent.delivered {
                    if pending?.text == text, pending?.state == .sent { pending?.state = .delivered }
                    break
                }
                await client.forget(stream.subscription)
            }
        } catch {
            pending = nil
            replyProblem = connection.problem(error)
        }
    }

    /// The pending reply goes once the transcript shows the author's next prompt.
    private func notePrompts() {
        guard let pending, pending.state != .sending else { return }
        let sent = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let arrived = entries.contains { entry in
            entry.kind == .prompt && !promptsBeforeReply.contains(entry.id)
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == sent
        }
        if arrived { self.pending = nil }
    }

    public func dismissReplyProblem() {
        replyProblem = nil
    }

    // MARK: Answers

    private func resetSelections() {
        selectionsPrompt = agent?.prompt?.id
        selections = Array(repeating: [], count: agent?.prompt?.questions?.count ?? 0)
    }

    /// Picks an option. One question with one choice answers at once; otherwise each question needs a choice first.
    public func choose(question: Int, option: Int) async {
        guard let prompt, prompt.kind == .question, let questions = prompt.questions,
            questions.indices.contains(question), questions[question].options.indices.contains(option)
        else { return }
        if selectionsPrompt != prompt.id { resetSelections() }
        if questions.count == 1, !questions[0].multiSelect {
            await answer(prompt, PhoneAnswer(options: [[option]]))
            return
        }
        if questions[question].multiSelect {
            if let index = selections[question].firstIndex(of: option) {
                selections[question].remove(at: index)
            } else {
                selections[question].append(option)
                selections[question].sort()
            }
        } else {
            selections[question] = [option]
        }
    }

    public var canSubmitAnswers: Bool {
        guard let questions = prompt?.questions, !questions.isEmpty, selections.count == questions.count else {
            return false
        }
        return selections.allSatisfy { !$0.isEmpty }
    }

    public func submitAnswers() async {
        guard let prompt, canSubmitAnswers else { return }
        await answer(prompt, PhoneAnswer(options: selections))
    }

    /// Allow for a permission prompt, approve for a plan.
    public func allow() async {
        guard let prompt, prompt.kind == .permission || prompt.kind == .plan else { return }
        await answer(prompt, PhoneAnswer(allow: true))
    }

    /// Deny for a permission prompt, keep planning for a plan.
    public func deny() async {
        guard let prompt, prompt.kind == .permission || prompt.kind == .plan else { return }
        await answer(prompt, PhoneAnswer(allow: false))
    }

    private func answer(_ prompt: OpenPrompt, _ answer: PhoneAnswer) async {
        guard !isAnswering else { return }
        isAnswering = true
        answerProblem = nil
        defer { isAnswering = false }
        do {
            _ = try await connection.liveClient().call(
                PhoneMethod.answer, PhoneAnswerParams(pane: pane, prompt: prompt.id, answer: answer),
                as: PhonePaneParams.self)
        } catch {
            answerProblem = connection.problem(error)
            resetSelections()
        }
    }

    public func dismissAnswerProblem() {
        answerProblem = nil
    }
}
