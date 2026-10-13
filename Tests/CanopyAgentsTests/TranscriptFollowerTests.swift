import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyAgents

struct TranscriptFollowerTests {
    static func line(_ uuid: String, _ role: String, _ content: String) -> String {
        if role == "user" {
            return
                #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-10-12T03:00:00.000Z","message":{"role":"user","content":"\#(content)"}}"#
        }
        return
            #"{"type":"assistant","uuid":"\#(uuid)","timestamp":"2026-10-12T03:00:01.000Z","message":{"role":"assistant","content":[\#(content)]}}"#
    }

    static func bash(_ id: String, _ command: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)"}}"#
    }

    func append(_ url: URL, _ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    final class Updates: Sendable {
        let all = Shared<[PhoneTranscriptUpdate]>([])
        var last: PhoneTranscriptUpdate? { all.withLock { $0.last } }
        var count: Int { all.withLock { $0.count } }
    }

    @Test func sendsNewEntriesAndGrowsAFoldedGroup() async throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("t.jsonl"))
        try Data((Self.line("u1", "user", "run the tests") + "\n").utf8).write(to: url)
        let page = try TranscriptReader.page(of: url, before: nil, limit: 50)
        let updates = Updates()
        let path = Shared<String?>(url.path)
        let follower = TranscriptFollower(
            pane: "p1", following: url.path, path: { path.withLock { $0 } }, sent: page.entries,
            interval: .milliseconds(20)
        ) { update in updates.all.withLock { $0.append(update) } }
        follower.start()
        defer { follower.stop() }

        try append(url, [Self.line("a1", "assistant", Self.bash("t1", "make test"))])
        #expect(await eventually { updates.last?.entries.map(\.text) == ["Ran make test"] })
        try append(url, [Self.line("a2", "assistant", Self.bash("t2", "make lint"))])
        #expect(await eventually { updates.last?.entries.map(\.text) == ["Ran make test and 1 more"] })
        #expect(updates.last?.entries.first?.id == "t1")
        #expect(updates.all.withLock { $0 }.allSatisfy { !$0.reset })
    }

    @Test func olderEntriesThanThePhoneHasAreLeftForItsPages() async throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("t.jsonl"))
        let lines = (1...5).map { Self.line("u\($0)", "user", "prompt \($0)") }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let updates = Updates()
        let follower = TranscriptFollower(
            pane: "p1", following: url.path, path: { url.path },
            sent: try TranscriptReader.page(of: url, before: nil, limit: 1).entries, interval: .milliseconds(20)
        ) { update in updates.all.withLock { $0.append(update) } }
        follower.start()
        defer { follower.stop() }
        try append(url, [Self.line("u6", "user", "prompt 6")])
        #expect(await eventually { updates.count == 1 })
        #expect(updates.last?.entries.map(\.text) == ["prompt 6"])
    }

    @Test func aGroupThePhoneHasThatChangesLaterIsSentAgain() async throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("t.jsonl"))
        let read = #"{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/r/a.swift"}}"#
        try Data(
            ([Self.line("a1", "assistant", read), Self.line("a2", "assistant", Self.bash("t1", "make test"))]
                .joined(separator: "\n") + "\n").utf8
        ).write(to: url)
        let updates = Updates()
        let follower = TranscriptFollower(
            pane: "p1", following: url.path, path: { url.path },
            sent: try TranscriptReader.page(of: url, before: nil, limit: 50).entries, interval: .milliseconds(20)
        ) { update in updates.all.withLock { $0.append(update) } }
        follower.start()
        defer { follower.stop() }
        let failed =
            #"{"type":"user","uuid":"u9","timestamp":"2026-10-12T03:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r1","content":"no such file","is_error":true}]}}"#
        try append(url, [failed])
        #expect(await eventually { updates.last?.entries.map(\.id) == ["r1"] })
        #expect(updates.last?.entries.first?.failed == true)
    }

    @Test func aNewSessionStartsOver() async throws {
        let dir = try TempDir()
        let first = URL(fileURLWithPath: dir.sub("a.jsonl"))
        let second = URL(fileURLWithPath: dir.sub("b.jsonl"))
        try Data((Self.line("u1", "user", "first") + "\n").utf8).write(to: first)
        try Data((Self.line("u2", "user", "second") + "\n").utf8).write(to: second)
        let updates = Updates()
        let path = Shared<String?>(first.path)
        let follower = TranscriptFollower(
            pane: "p1", following: first.path, path: { path.withLock { $0 } },
            sent: try TranscriptReader.page(of: first, before: nil, limit: 50).entries, interval: .milliseconds(20)
        ) { update in updates.all.withLock { $0.append(update) } }
        follower.start()
        defer { follower.stop() }

        path.withLock { $0 = second.path }
        #expect(await eventually { updates.last?.reset == true })
        #expect(updates.last?.entries.map(\.text) == ["second"])
        #expect(updates.last?.older == nil)
    }

    @Test func nothingChangedSendsNothing() async throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("t.jsonl"))
        try Data((Self.line("u1", "user", "hi") + "\n").utf8).write(to: url)
        let updates = Updates()
        let follower = TranscriptFollower(
            pane: "p1", following: url.path, path: { url.path },
            sent: try TranscriptReader.page(of: url, before: nil, limit: 50).entries,
            interval: .milliseconds(20)
        ) { update in updates.all.withLock { $0.append(update) } }
        follower.start()
        try await Task.sleep(for: .milliseconds(200))
        follower.stop()
        #expect(updates.count == 0)
    }

    @Test func stopsWhenThePaneHasNoTranscript() async throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("t.jsonl"))
        try Data((Self.line("u1", "user", "hi") + "\n").utf8).write(to: url)
        let path = Shared<String?>(url.path)
        let follower = TranscriptFollower(
            pane: "p1", following: url.path, path: { path.withLock { $0 } }, sent: [], interval: .milliseconds(20)
        ) { _ in }
        follower.start()
        path.withLock { $0 = nil }
        #expect(await eventually { follower.isStopped })
    }
}
