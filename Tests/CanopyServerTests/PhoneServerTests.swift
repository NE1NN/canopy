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
}

struct PhoneServerTests {
    final class Harness: Sendable {
        let source = FakePhoneSource()
        let server: PhoneServer
        let recorded = Shared<[PhoneActivity]>([])

        init(_ dir: TempDir) {
            let recorded = recorded
            server = PhoneServer(
                source: source,
                settings: PhoneServerSettings(
                    registryFile: URL(fileURLWithPath: dir.sub("phones.json")), serverName: { "hindie-box" },
                    kind: PhoneServerKind.box, version: "1.2.3", port: 0, addresses: { ["127.0.0.1"] },
                    tailnetName: { nil },
                    closedReason: { "No tailnet address." }, record: { event in recorded.withLock { $0.append(event) } }
                ))
        }

        /// A phone that paired and said hello.
        func phone() async throws -> PhoneTestClient {
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
            return client
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
}
