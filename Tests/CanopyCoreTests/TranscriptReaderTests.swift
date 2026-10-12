import Foundation
import Testing

@testable import CanopyCore

/// Transcripts recorded from Claude Code 2.1.296 with Haiku in a throwaway folder (`tools`, `prompts`), and lines
/// written by hand for what those runs did not produce (`edges`). Paths and names are scrubbed.
enum TranscriptFixture {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Transcripts"))
    }

    static func entries(_ name: String) throws -> [TranscriptEntry] {
        let lines = try Data(contentsOf: url(name)).split(separator: 0x0A).map { Data($0) }
        return TranscriptParser.entries(from: lines)
    }
}

struct TranscriptParserTests {
    @Test func foldsToolCallsOfOneKindAndSaysWhatFailed() throws {
        let entries = try TranscriptFixture.entries("tools")
        #expect(entries.map(\.kind) == [.prompt, .tools, .tools, .tools, .text])
        #expect(entries[0].text.hasPrefix("Read a.txt and b.txt, run 'echo hi'"))
        #expect(entries[1].text == "Read a.txt and 1 more")
        #expect(!entries[1].failed)
        #expect(entries[2].text == "Ran echo hi and 2 more, 1 failed")
        #expect(entries[2].failed)
        #expect(entries[3].text == "Edited b.txt")
        #expect(entries[4].text.hasPrefix("I read both files"))
    }

    @Test func keepsIDsAndTimes() throws {
        let entries = try TranscriptFixture.entries("tools")
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.allSatisfy { $0.at > 1_760_000_000 })
        #expect(entries.map(\.at) == entries.map(\.at).sorted())
    }

    @Test func questionsPlansAndDeclinedCalls() throws {
        let entries = try TranscriptFixture.entries("prompts")
        #expect(
            entries.map(\.kind) == [
                .prompt, .question, .text,
                .prompt, .tools, .notice,
                .prompt, .tools, .text,
                .prompt, .tools, .plan, .notice,
                .prompt, .question, .text,
                .prompt, .question, .text,
            ])
        let first = entries[1]
        #expect(first.text == "What should the new file be named?")
        #expect(first.questions?.first?.options.map(\.label) == ["c.txt", "d.txt"])
        #expect(first.answer == "d.txt")
        #expect(entries[4].text == "Ran touch d.txt && ls -l d.txt, declined")
        #expect(entries[4].failed)
        #expect(entries[5].text == "Interrupted")
        #expect(entries[7].text == "Ran touch e.txt && ls -l e.txt" && !entries[7].failed)
        #expect(entries[11].text.hasPrefix("# Add f.txt containing \"hello\""))
        #expect(entries[11].answer == "Declined")
        #expect(entries[14].questions?.count == 2)
        #expect(entries[14].answer == "Blue; Large")
        #expect(entries[17].questions?.first?.multiSelect == true)
        #expect(entries[17].answer == "Apple, Plum")
    }

    @Test func leavesOutWhatIsNotTheConversation() throws {
        let entries = try TranscriptFixture.entries("edges")
        #expect(
            entries.map(\.text) == [
                "/clear",
                "Look at the port scanner\n[image]",
                "Searched for proc_pidfdinfo and 1 more",
                "Read PortScanner.swift and 2 more",
                "Ran an agent: Find callers",
                "Edited 2 files",
                "Fetched developer.apple.com",
                "Updated the to-do list",
                "Used notion-search",
                "Background command \"make test\" completed (exit code 0)",
                "Tests pass.\n\nShould I open the PR?",
                "Interrupted",
                "The conversation was compacted",
            ])
        #expect(entries.map(\.kind).filter { $0 == .notice }.count == 4)
    }

    @Test func aQuestionStillWaitingHasNoAnswer() throws {
        let lines = try Data(contentsOf: TranscriptFixture.url("prompts")).split(separator: 0x0A).map { Data($0) }
        // Up to and including the AskUserQuestion call, before its answer.
        let asked = try #require(
            lines.firstIndex { String(decoding: $0, as: UTF8.self).contains(#""name":"AskUserQuestion""#) })
        let entries = TranscriptParser.entries(from: Array(lines[...asked]))
        #expect(entries.last?.kind == .question)
        #expect(entries.last?.answer == nil)
    }

    @Test func aRunningToolIsNotFailed() throws {
        let lines = try Data(contentsOf: TranscriptFixture.url("tools")).split(separator: 0x0A).map { Data($0) }
        let cat = try #require(
            lines.firstIndex { String(decoding: $0, as: UTF8.self).contains(#""command":"cat missing.txt""#) })
        let entries = TranscriptParser.entries(from: Array(lines[...cat]))
        #expect(entries.last?.text == "Ran echo hi and 2 more")
        #expect(entries.last?.failed == false)
    }
}

struct TranscriptReaderTests {
    /// A transcript of `count` prompts and answers, each line padded so pages span several reads.
    func longTranscript(_ dir: TempDir, count: Int) throws -> URL {
        var text = ""
        for index in 0..<count {
            let padding = String(repeating: "x", count: 3000)
            text +=
                #"{"type":"user","uuid":"u\#(index)","timestamp":"2026-10-12T03:00:00.000Z","message":{"role":"user","content":"prompt \#(index) \#(padding)"}}"#
                + "\n"
            text +=
                #"{"type":"assistant","uuid":"a\#(index)","timestamp":"2026-10-12T03:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(index)"}]}}"#
                + "\n"
        }
        let url = URL(fileURLWithPath: dir.sub("long.jsonl"))
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func pagesGoNewestFirstAndJoinUp() throws {
        let dir = try TempDir()
        let url = try longTranscript(dir, count: 300)
        var seen: [String] = []
        var cursor: Int?
        var pages = 0
        repeat {
            let page = try TranscriptReader.page(of: url, before: cursor, limit: 50)
            #expect(page.entries.count <= 50 || page.older == nil)
            seen = page.entries.map(\.id) + seen
            cursor = page.older
            pages += 1
        } while cursor != nil && pages < 100
        #expect(pages > 5)
        #expect(seen == (0..<300).flatMap { ["u\($0)", "a\($0)"] })
    }

    @Test func theFirstPageReadsOnlyTheEnd() throws {
        let dir = try TempDir()
        let url = try longTranscript(dir, count: 2000)
        let page = try TranscriptReader.page(of: url, before: nil, limit: 10)
        #expect(page.entries.map(\.id).suffix(2) == ["u1999", "a1999"])
        #expect(page.bytesRead < 200_000)
    }

    @Test func aMissingFileIsNoTranscript() throws {
        let dir = try TempDir()
        #expect(throws: TranscriptReader.Failure.missing) {
            try TranscriptReader.page(of: URL(fileURLWithPath: dir.sub("none.jsonl")), before: nil, limit: 10)
        }
    }

    @Test func aHalfWrittenLastLineWaits() throws {
        let dir = try TempDir()
        let url = try longTranscript(dir, count: 2)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","uuid":"half","message":{"role":"user","content":"pa"#.utf8))
        try handle.close()
        let page = try TranscriptReader.page(of: url, before: nil, limit: 10)
        #expect(page.entries.last?.id == "a1")
    }
}
