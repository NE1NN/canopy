import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

struct ClaudeSessionsTests {
    @Test func listsAFoldersConversationsNewestFirstWithTitles() throws {
        let home = try TempDir()
        let folder = ClaudeProjects.root(home: home.path).appending(path: ClaudeProjects.folderName(for: "/w/row"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ id: String, _ lines: [Data], age: TimeInterval) throws {
            let url = folder.appending(path: id + ".jsonl")
            try lines.map { $0 + Data("\n".utf8) }.reduce(Data(), +).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        try write(
            "old", [ChatLines.prompt("<command-name>/clear</command-name>"), ChatLines.prompt("Fix the login\nmore")],
            age: 500)
        try write(
            "new", [Data(#"{"type":"custom-title","customTitle":"Phone pairing"}"#.utf8), ChatLines.prompt("hi")],
            age: 10)
        try write("empty", [ChatLines.say("no prompt here")], age: 1)

        let sessions = ClaudeSessions.list(folder: "/w/row", home: home.path)

        #expect(sessions.map(\.id) == ["new", "old"])
        #expect(sessions.map(\.title) == ["Phone pairing", "Fix the login"])
    }
}
