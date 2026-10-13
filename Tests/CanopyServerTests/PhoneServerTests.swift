import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation
import Synchronization
import Testing

@testable import CanopyServer

/// Rows and panes a test scripts, as canopy-box or the Mac would serve them.
final class FakePhoneSource: PhoneSource {
    let inboxNow = Shared(PhoneInbox())
    let subscribers = Shared<[UUID: @Sendable (PhoneInbox) -> Void]>([:])
    let replies = Shared<[PhoneReplyParams]>([])
    let deliveries = Shared<[@Sendable () -> Void]>([])
    let answerError = Shared<ControlError?>(nil)
    let transcripts = Shared<[String: URL]>([:])
    let newRows = Shared<[(params: PhoneNewRowParams, line: String)]>([])
    let newRowError = Shared<ControlError?>(nil)

    func setInbox(_ inbox: PhoneInbox) {
        inboxNow.withLock { $0 = inbox }
        for send in subscribers.withLock({ Array($0.values) }) { send(inbox) }
    }

    func deliver() {
        for delivered in deliveries.withLock({ $0 }) { delivered() }
    }

    func inbox() async -> PhoneInbox { inboxNow.withLock { $0 } }

    func rows() async -> PhoneRowsResult {
        PhoneRowsResult(sections: [
            PhoneRowsResult.Section(name: "canopy", isPlugin: false, rows: inboxNow.withLock { $0.rows })
        ])
    }

    func subscribe(
        after lastSent: PhoneInbox, replacing previous: UUID?, _ send: @escaping @Sendable (PhoneInbox) -> Void
    ) async -> UUID {
        let id = UUID()
        subscribers.withLock { subscribers in
            if let previous { subscribers[previous] = nil }
            subscribers[id] = send
        }
        return id
    }

    func unsubscribe(_ id: UUID) async {
        subscribers.withLock { $0[id] = nil }
    }

    func transcriptURL(_ pane: String) async throws -> URL {
        guard let url = transcripts.withLock({ $0[pane] }) else {
            throw ControlError(code: "pane_not_found", message: "No pane \(pane).")
        }
        return url
    }

    func reply(_ params: PhoneReplyParams, delivered: @escaping @Sendable () -> Void) async throws {
        replies.withLock { $0.append(params) }
        deliveries.withLock { $0.append(delivered) }
    }

    func answer(_ params: PhoneAnswerParams) async throws {
        if let error = answerError.withLock({ $0 }) { throw error }
    }

    func keys(_ params: PhoneKeysParams) async throws {}

    func seen(_ params: PhonePaneParams) async throws {}

    func screen(_ params: PhonePaneParams, scrollback: Int?) async throws -> PhoneScreen {
        PhoneScreen(pane: params.pane, columns: 80, rows: 1, scrollback: nil, lines: ["$ "])
    }

    func newRow(_ params: PhoneNewRowParams, line: String) async throws -> PhoneNewRowResult {
        if let error = newRowError.withLock({ $0 }) { throw error }
        newRows.withLock { $0.append((params, line)) }
        return PhoneNewRowResult(path: "/box/\(params.branch)", branch: params.branch, pane: "b7")
    }
}

struct PhoneServerTests {
    final class Harness: Sendable {
        let source = FakePhoneSource()
        let server: PhoneServer
        let recorded = Shared<[PhoneActivity]>([])

        init(_ dir: TempDir, agentCommand: String = PhoneAgentCommand.standard, logsCommands: Bool = false) {
            let recorded = recorded
            server = PhoneServer(
                source: source,
                settings: PhoneServerSettings(
                    registryFile: URL(fileURLWithPath: dir.sub("phones.json")), serverName: { "hindie-box" },
                    kind: PhoneServerKind.box, agentCommand: { agentCommand }, version: "1.2.3", port: 0,
                    addresses: { ["127.0.0.1"] }, tailnetName: { nil }, closedReason: { "No tailnet address." },
                    logsCommands: { logsCommands }, record: { event in recorded.withLock { $0.append(event) } }))
        }

        /// A phone that paired and said hello.
        func phone() async throws -> PhoneTestClient {
            try await phoneAndGreeting().client
        }

        func phoneAndGreeting() async throws -> (client: PhoneTestClient, greeting: PhoneHelloResult) {
            await server.refresh()
            let port = try #require(await server.status().endpoints.first?.port)
            let code = await server.registry.newCode().code
            let client = try PhoneTestClient(port: port)
            let paired = try await offPool {
                try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: "iPhone")))
            }
            let pairing = try #require(paired.result).decode(PhonePairResult.self)
            #expect(pairing.kind == PhoneServerKind.box)
            let hello = try await offPool {
                try client.call(PhoneMethod.hello, try .from(PhoneHelloParams(token: pairing.token)))
            }
            let greeting = try #require(hello.result).decode(PhoneHelloResult.self)
            #expect(greeting.mac == "hindie-box" && greeting.kind == PhoneServerKind.box)
            return (client, greeting)
        }
    }

    static let waiting = PhoneInbox(rows: [
        PhoneRow(
            path: "/box/feat", name: "feat/x", repo: "canopy",
            agents: [PhoneAgent(pane: "b1", state: .waiting, since: 10)])
    ])

    /// The phone shows a box apart from a Mac, from the pairing link on.
    @Test func theBoxSaysItIsABox() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        defer { harness.server.stop() }
        await harness.server.refresh()

        let link = try #require(URL(string: try await harness.server.pair().link).flatMap(PairingLink.init(url:)))

        #expect(link.kind == PhoneServerKind.box)
        _ = try await harness.phone()
    }

    @Test func subscribingSendsTheInboxThenItsChanges() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        defer { harness.server.stop() }
        harness.source.setInbox(Self.waiting)
        let phone = try await harness.phone()

        let first = try await offPool { try phone.call(PhoneMethod.subscribe) }
        #expect(try #require(first.result).decode(PhoneInbox.self) == Self.waiting)
        _ = await eventually { harness.source.subscribers.withLock { !$0.isEmpty } }
        harness.source.setInbox(PhoneInbox())

        let event = try await offPool { try phone.next() }
        #expect(event?.event?.event == PhoneEvent.inbox)
        #expect(try event?.event?.data.decode(PhoneInbox.self) == PhoneInbox())
    }

    @Test func aReplyReachesTheSourceAndItsDeliveryReachesThePhone() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        defer { harness.server.stop() }
        let phone = try await harness.phone()

        let replied = try await offPool {
            try phone.call(PhoneMethod.reply, try .from(PhoneReplyParams(pane: "b1", text: "go on")))
        }
        #expect(replied.error == nil)
        #expect(harness.source.replies.withLock { $0 } == [PhoneReplyParams(pane: "b1", text: "go on")])
        harness.source.deliver()

        let delivered = try await offPool { try phone.next() }
        #expect(delivered?.event?.event == PhoneEvent.delivered)
        #expect(
            harness.recorded.withLock { $0 }.contains {
                if case .call(let data) = $0 { data["pane"] == .string("b1") } else { false }
            })
    }

    @Test func theSourcesErrorsReachThePhone() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        defer { harness.server.stop() }
        harness.source.answerError.withLock {
            $0 = ControlError(code: "prompt_gone", message: "That prompt moved on.")
        }
        let phone = try await harness.phone()

        let answered = try await offPool {
            try phone.call(
                PhoneMethod.answer,
                try .from(PhoneAnswerParams(pane: "b1", prompt: "p", answer: PhoneAnswer(allow: true))))
        }
        let transcript = try await offPool {
            try phone.call(PhoneMethod.transcript, try .from(PhoneTranscriptParams(pane: "b9", limit: 10)))
        }

        #expect(answered.error?.code == "prompt_gone")
        #expect(transcript.error?.code == "pane_not_found")
    }

    @Test func pairingAndRemovingAreRecorded() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        defer { harness.server.stop() }
        _ = try await harness.phone()

        _ = try await harness.server.remove(name: "iPhone")

        #expect(harness.recorded.withLock { $0 }.first == .paired(phone: "iPhone"))
        #expect(harness.recorded.withLock { $0 }.last == .removed(phone: "iPhone"))
    }

    @Test func aServerWithNoAddressSaysWhy() async throws {
        let dir = try TempDir()
        let server = PhoneServer(
            source: FakePhoneSource(),
            settings: PhoneServerSettings(
                registryFile: URL(fileURLWithPath: dir.sub("phones.json")), serverName: { "box" }, version: "1",
                port: 0,
                addresses: { [] }, tailnetName: { nil }, closedReason: { "No tailnet address." }, record: { _ in }))
        await server.refresh()

        let status = await server.status()
        #expect(!status.listening)
        #expect(status.problem == "No tailnet address.")
        await #expect(throws: ControlError.self) { try await server.pair() }
    }

    @Test func helloCarriesTheAgentCommand() async throws {
        let dir = try TempDir()
        let harness = Harness(dir, agentCommand: "codex --yolo")
        defer { harness.server.stop() }

        let greeting = try await harness.phoneAndGreeting().greeting

        #expect(greeting.agentCommand == "codex --yolo")
    }

    @Test func newRowRunsTheServersCommandWithTheBrief() async throws {
        let dir = try TempDir()
        let harness = Harness(dir, agentCommand: "codex --yolo")
        defer { harness.server.stop() }
        let phone = try await harness.phone()

        let made = try await offPool {
            try phone.call(
                PhoneMethod.newRow,
                try .from(PhoneNewRowParams(repo: " canopy ", branch: "fix/login ", base: " ", brief: "Fix the login."))
            )
        }

        #expect(try #require(made.result).decode(PhoneNewRowResult.self).pane == "b7")
        let asked = try #require(harness.source.newRows.withLock { $0.first })
        #expect(asked.params == PhoneNewRowParams(repo: "canopy", branch: "fix/login", brief: "Fix the login."))
        #expect(asked.line == "codex --yolo 'Fix the login.'")
    }

    @Test func aNewRowNeedsARepoAndABranch() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        defer { harness.server.stop() }
        let phone = try await harness.phone()

        let made = try await offPool {
            try phone.call(PhoneMethod.newRow, try .from(PhoneNewRowParams(repo: "canopy", branch: "  ", brief: "")))
        }

        #expect(made.error?.code == "bad_params")
        #expect(harness.source.newRows.withLock { $0.isEmpty })
    }

    @Test(arguments: [false, true])
    func newRowIsLoggedWithTheBriefOnlyWhenCommandsAre(_ logsCommands: Bool) async throws {
        let dir = try TempDir()
        let harness = Harness(dir, logsCommands: logsCommands)
        defer { harness.server.stop() }
        let phone = try await harness.phone()

        _ = try await offPool {
            try phone.call(
                PhoneMethod.newRow, try .from(PhoneNewRowParams(repo: "canopy", branch: "x", brief: "secret plan")))
        }

        let call = harness.recorded.withLock { $0 }.compactMap { event -> [String: JSONValue]? in
            if case .call(let data) = event { data } else { nil }
        }.first
        #expect(call?["method"] == .string(PhoneMethod.newRow))
        #expect(call?["pane"] == .string("b7"))
        #expect(call?["repo"] == .string("canopy"))
        #expect(call?["brief"] == (logsCommands ? .string("secret plan") : nil))
    }

    /// Whatever the brief holds reaches the agent as one argument, and none of it runs in the shell.
    @Test(arguments: [
        "plain", "it's here", #"say "hi""#, "$(touch pwned) and `touch pwned` and $HOME", "two\nlines", "a\\b ' ''",
        "!! and !$",
    ])
    func theBriefIsOneQuotedArgument(_ brief: String) async throws {
        let dir = try TempDir()
        let line = PhoneAgentCommand.line("printf '%s|' ", brief: brief)

        let result = try await Subprocess.runOffPool(
            "/bin/sh", ["-c", line], environment: ["PATH": "/usr/bin:/bin"], directory: dir.path,
            timeout: .seconds(10))

        #expect(String(decoding: result.stdout, as: UTF8.self) == brief + "|")
        #expect(!FileManager.default.fileExists(atPath: dir.sub("pwned")))
    }

    @Test func anEmptyBriefRunsTheCommandAlone() {
        #expect(PhoneAgentCommand.line("claude", brief: "") == "claude")
    }
}
