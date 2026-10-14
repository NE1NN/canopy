import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct ChatSessionTests {
    let home: TempDir
    let folder: TempDir

    init() throws {
        home = try TempDir()
        folder = try TempDir()
    }

    func session(
        id: String? = nil, trusted: Bool = true, environment: [String: String] = [:], granted: @escaping () -> Void = {}
    ) -> ChatSession {
        let home = home.path
        let folder = folder.path
        var isTrusted = trusted
        return ChatSession(
            model: "sonnet", mode: "default", sessionID: id, title: "",
            launcher: { model, mode, resume in
                var launch = FakeClaude.launch(home: home, folder: folder, environment: environment)
                launch.arguments =
                    ["python3", "-I", FakeClaude.script]
                    + ClaudeLaunch.arguments(model: model, mode: mode, resume: resume)
                return launch
            },
            transcript: { ClaudeProjects.transcript(session: $0, folder: folder, home: home) },
            trust: ChatTrust(
                isTrusted: { isTrusted },
                grant: {
                    isTrusted = true
                    granted()
                }))
    }

    /// Waits for things that need the stand-in Claude to have started, which takes longer on a loaded machine.
    func soon(_ condition: () async -> Bool) async -> Bool {
        await eventually(timeout: .seconds(60), condition)
    }

    func texts(_ chat: ChatSession) -> [String] {
        chat.items.compactMap {
            switch $0.content {
            case .prompt(let prompt): "You: " + prompt.text
            case .text(let text): text.markdown
            case .tools(let group): group.summary
            case .notice(let notice): "[\(notice)]"
            default: nil
            }
        }
    }

    @Test func startsOnTheFirstMessageAndStreamsTheReply() async throws {
        let chat = session()
        #expect(!chat.isRunning)

        chat.send("say hello there")

        #expect(chat.isWorking)
        #expect(chat.queued.map(\.prompt.text) == ["say hello there"])
        #expect(await soon { !chat.isWorking })
        #expect(texts(chat) == ["You: say hello there", "hello there"])
        #expect(chat.queued.isEmpty)
        #expect(chat.streaming == nil)
        #expect(chat.sessionID != nil)
        #expect(chat.lastTurn != nil)
        #expect(chat.contextWindow == 1_000_000)
        #expect(chat.contextTokens == 21003)
        #expect(chat.title == "say hello there")
        chat.close()
    }

    @Test func showsTextWhileItStreamsAtMostThirtyTimesASecond() async throws {
        let chat = session(environment: ["FAKE_CLAUDE_DELAY": "0.005"])

        chat.send("slow 200")

        #expect(await soon { !chat.isWorking })
        #expect(chat.streamingPublishCount >= 1)
        #expect(chat.streamingPublishCount < 200)
        #expect(chat.shortestStreamingGap.map { $0 >= ChatSession.streamingInterval } ?? true)
        #expect(chat.turnTokens == 200)
        chat.close()
    }

    @Test func asksPermissionAndAllows() async throws {
        let chat = session()

        chat.send("run ls -la")

        #expect(await soon { chat.permission != nil })
        let permission = try #require(chat.permission)
        #expect(permission.tool == "Bash")
        #expect(permission.subject == "ls -la")
        #expect(permission.description == "Run ls -la")
        #expect(permission.rule == "ls:*")
        chat.allow()
        #expect(chat.permission == nil)
        #expect(await soon { !chat.isWorking })
        #expect(texts(chat) == ["You: run ls -la", "Ran ls -la", "It ran."])
        chat.close()
    }

    @Test func deniesWithWhatToDoInstead() async throws {
        let chat = session()

        chat.send("run rm -rf build")
        #expect(await soon { chat.permission != nil })
        chat.send("Run the tests instead")

        #expect(chat.permission == nil)
        #expect(await soon { !chat.isWorking && chat.queued.isEmpty })
        #expect(
            texts(chat) == [
                "You: run rm -rf build", "Ran rm -rf build, declined", "I did not run it.",
                "You: Run the tests instead",
                "You said: Run the tests instead",
            ])
        chat.close()
    }

    @Test func denyingWithoutTextStopsTheTurn() async throws {
        let chat = session()

        chat.send("run rm -rf build")
        #expect(await soon { chat.permission != nil })
        chat.deny()

        #expect(await soon { !chat.isWorking })
        #expect(texts(chat).dropFirst().first == "Ran rm -rf build, declined")
        chat.close()
    }

    /// Questions come with the next milestone; until then Claude is told to ask in plain text.
    @Test func turnsDownQuestionsItCannotShowYet() async throws {
        let chat = session()

        chat.send("ask")

        #expect(await soon { !chat.isWorking })
        #expect(chat.permission == nil)
        guard case .question(let question)? = chat.items.last?.content else {
            Issue.record("no question in \(chat.items)")
            return
        }
        #expect(question.answer == "Declined")
        chat.close()
    }

    @Test func aMessageSentWhileWorkingWaitsForTheStep() async throws {
        let chat = session()

        chat.send("pause")
        #expect(await soon { chat.turnTokens > 0 })
        chat.send("say next")

        #expect(chat.queued.map(\.waitsForStep) == [true])
        #expect(await soon { chat.queued.isEmpty && !chat.isWorking })
        #expect(texts(chat).filter { $0.hasPrefix("You: ") } == ["You: pause", "You: say next"])
        chat.close()
    }

    /// Claude Code takes messages that queued up during a turn as one message.
    @Test func messagesTakenTogetherAllLeaveTheQueue() async throws {
        let chat = session()

        chat.send("pause 2")
        #expect(await soon { chat.turnTokens > 0 })
        chat.send("say one")
        chat.send("say two")
        #expect(chat.queued.count == 2)

        #expect(await soon { chat.queued.isEmpty && !chat.isWorking })
        #expect(texts(chat).filter { $0.hasPrefix("You: ") } == ["You: pause 2", "You: say one\nsay two"])
        chat.close()
    }

    /// Parallel subagents ask at once, and each request needs its own answer.
    @Test func answersPermissionsAskedTogetherOneByOne() async throws {
        let chat = session()

        chat.send("two")
        #expect(await soon { chat.pendingPermissions.count == 2 })
        #expect(chat.permission?.subject == "ls a")
        chat.allow()
        #expect(chat.permission?.subject == "ls b")
        chat.allow()

        #expect(await soon { !chat.isWorking })
        #expect(texts(chat).last == "Both answered.")
        chat.close()
    }

    @Test func stopDeniesEveryOpenPrompt() async throws {
        let chat = session()

        chat.send("two")
        #expect(await soon { chat.pendingPermissions.count == 2 })
        chat.interrupt()

        #expect(chat.pendingPermissions.isEmpty)
        #expect(await soon { !chat.isWorking })
        chat.close()
    }

    /// Claude Code acknowledges an interrupt but goes on waiting for an open permission prompt.
    @Test func stopDeniesAnOpenPrompt() async throws {
        let chat = session()

        chat.send("run make deploy")
        #expect(await soon { chat.permission != nil })
        chat.interrupt()

        #expect(chat.permission == nil)
        #expect(await soon { !chat.isWorking })
        #expect(texts(chat).contains("Ran make deploy, declined"))
        chat.close()
    }

    @Test func stopInterruptsTheTurn() async throws {
        let chat = session()

        chat.send("pause")
        #expect(await soon { chat.turnTokens > 0 })
        chat.interrupt()

        #expect(await soon { !chat.isWorking })
        #expect(texts(chat).last == "[Interrupted]")
        #expect(chat.streaming == nil)
        chat.close()
    }

    @Test func reportsAClaudeThatExits() async throws {
        let chat = session()
        var ended = 0
        chat.onEnded = { ended += 1 }

        chat.send("crash")

        #expect(await soon { chat.failure != nil })
        #expect(chat.failure == .exited(code: 1, errors: ["boom: something broke"]))
        #expect(!chat.isWorking)
        #expect(!chat.isRunning)
        #expect(ended == 1)
    }

    @Test func startsAgainWhereItLeftOff() async throws {
        let chat = session()
        chat.send("say first")
        #expect(await soon { !chat.isWorking })
        let first = chat.sessionID
        chat.send("crash")
        #expect(await soon { chat.failure != nil })

        chat.send("say second")

        #expect(chat.failure == nil)
        #expect(await soon { !chat.isWorking && texts(chat).last == "second" })
        #expect(chat.sessionID == first)
        chat.close()
    }

    @Test func refusesAClaudeCodeTooOld() async throws {
        let chat = session(environment: ["FAKE_CLAUDE_VERSION": "2.1.9"])

        chat.send("say hi")

        #expect(await soon { chat.failure != nil })
        #expect(chat.failure == .tooOld(version: "2.1.9"))
        #expect(await soon { !chat.isRunning })
    }

    @Test func comparesVersions() {
        #expect(ChatSession.isSupported("2.1.296"))
        #expect(ChatSession.isSupported("2.1.300"))
        #expect(ChatSession.isSupported("2.2.0"))
        #expect(ChatSession.isSupported("3.0"))
        #expect(!ChatSession.isSupported("2.1.295"))
        #expect(!ChatSession.isSupported("2.0.999"))
        #expect(!ChatSession.isSupported("garbage"))
    }

    @Test func clearStartsANewConversation() async throws {
        let chat = session()
        chat.send("say before")
        #expect(await soon { !chat.isWorking })
        let before = chat.sessionID

        chat.send("/clear")

        #expect(await soon { !chat.isWorking && chat.sessionID != before })
        #expect(!texts(chat).contains("before"))
        chat.close()
    }

    @Test func showsTheHistoryOfAResumedSessionWithoutStartingClaude() throws {
        let id = "11111111-2222-3333-4444-555555555555"
        try writeTranscript(id, lines: [ChatLines.prompt("old question"), ChatLines.say("old answer")])

        let chat = session(id: id)
        #expect(chat.items.isEmpty)

        chat.open()

        #expect(texts(chat) == ["You: old question", "old answer"])
        #expect(!chat.isRunning)
        #expect(chat.failure == nil)
        #expect(!chat.hasOlder)
    }

    @Test func resumesTheSessionWhenSentSomething() async throws {
        let id = "11111111-2222-3333-4444-555555555555"
        try writeTranscript(id, lines: [ChatLines.prompt("old question"), ChatLines.say("old answer")])
        let chat = session(id: id)

        chat.send("say new")

        #expect(await soon { !chat.isWorking })
        #expect(chat.sessionID == id)
        #expect(texts(chat) == ["You: old question", "old answer", "You: say new", "new"])
        chat.close()
    }

    @Test func loadsOlderMessagesOnRequest() async throws {
        let id = "11111111-2222-3333-4444-555555555555"
        try writeTranscript(
            id, lines: (0..<3000).map { ChatLines.say("message \($0) " + String(repeating: "x", count: 100)) })
        let chat = session(id: id)
        chat.open()
        let first = chat.items.count
        #expect(chat.hasOlder)
        #expect(first < 3000)

        while chat.hasOlder {
            chat.loadOlder()
            #expect(chat.isLoadingOlder)
            #expect(await soon { !chat.isLoadingOlder })
        }

        #expect(chat.items.count == 3000)
        #expect(chat.items.first.map(texts)?.first?.hasPrefix("message 0 ") == true)
    }

    @Test func saysWhenTheTranscriptIsGone() {
        let chat = session(id: "99999999-2222-3333-4444-555555555555")
        chat.open()

        #expect(chat.failure == .transcriptMissing)
        #expect(chat.items.isEmpty)
    }

    @Test func asksForTrustBeforeStarting() async throws {
        var granted = 0
        let chat = session(trusted: false, granted: { granted += 1 })
        chat.open()
        #expect(chat.needsTrust)

        chat.send("say hi")
        #expect(!chat.isRunning)
        #expect(chat.queued.isEmpty)

        try await chat.grantTrust()

        #expect(!chat.needsTrust)
        #expect(granted == 1)
        chat.send("say hi")
        #expect(await soon { !chat.isWorking })
        chat.close()
    }

    func writeTranscript(_ id: String, lines: [Data]) throws {
        let folder = ClaudeProjects.root(home: home.path).appending(path: ClaudeProjects.folderName(for: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data()
        for line in lines { data.append(line + Data("\n".utf8)) }
        try data.write(to: folder.appending(path: id + ".jsonl"))
    }
}

extension ChatItem {
    var plainText: String? {
        switch content {
        case .text(let text): text.markdown
        default: nil
        }
    }
}

extension ChatSessionTests {
    func texts(_ item: ChatItem) -> [String] {
        [item.plainText].compactMap { $0 }
    }
}
