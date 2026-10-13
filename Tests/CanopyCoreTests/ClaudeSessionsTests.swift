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

    /// Claude Code names a conversation as it goes, far down a long transcript, and a first prompt can hold an image.
    @Test func readsTheNewestTitleFromTheEndAndAPromptPastALargeImage() throws {
        let home = try TempDir()
        let folder = ClaudeProjects.root(home: home.path).appending(path: ClaudeProjects.folderName(for: "/w/row"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filler = ChatLines.say(String(repeating: "x", count: 300 * 1024))
        let named = [
            ChatLines.prompt("Start"), filler, Data(#"{"type":"ai-title","aiTitle":"First idea"}"#.utf8), filler,
            Data(#"{"type":"ai-title","aiTitle":"Canopy plugins"}"#.utf8), ChatLines.say("done"),
        ]
        let image = String(repeating: "A", count: 600 * 1024)
        let pasted = Data(
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(image)"}},{"type":"text","text":"What is this?"}]}}"#
                .utf8)
        try named.map { $0 + Data("\n".utf8) }.reduce(Data(), +).write(to: folder.appending(path: "named.jsonl"))
        try (pasted + Data("\n".utf8)).write(to: folder.appending(path: "pasted.jsonl"))

        let titles = Dictionary(
            uniqueKeysWithValues: ClaudeSessions.list(folder: "/w/row", home: home.path).map { ($0.id, $0.title) })

        #expect(titles == ["named": "Canopy plugins", "pasted": "What is this?"])
    }
}
