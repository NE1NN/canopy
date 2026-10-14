import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

struct ChatEditTests {
    let patch: JSONValue = .object([
        "filePath": "/w/SavedTab.swift",
        "structuredPatch": .array([
            .object([
                "oldStart": 3, "oldLines": 2, "newStart": 3, "newLines": 3,
                "lines": .array([" case web(SavedWebPage)", "-case old", "+case chat(SavedChat)", "+case other"]),
            ])
        ]),
    ])

    @Test func readsAnEditsPatch() throws {
        let edit = try #require(ChatEdit(result: patch))

        #expect(edit.file == "/w/SavedTab.swift")
        #expect(
            edit.hunks == [
                ChatHunk(
                    oldStart: 3, newStart: 3,
                    lines: [" case web(SavedWebPage)", "-case old", "+case chat(SavedChat)", "+case other"])
            ])
        #expect(edit.added == 2)
        #expect(edit.removed == 1)
    }

    /// A Write that creates a file comes back with an empty patch and the file's content.
    @Test func aNewFileShowsItsContent() throws {
        let edit = try #require(
            ChatEdit(
                result: .object([
                    "type": "create", "filePath": "/w/n.swift", "content": "a\nb", "structuredPatch": .array([]),
                ])))
        #expect(edit.added == 2)
        #expect(ChatEdit(result: .object(["filePath": "/w/x", "structuredPatch": .array([])])) == nil)
    }

    @Test func proposesAnEditFromItsInput() throws {
        let edit = try #require(
            ChatEdit(
                proposed: "Edit",
                input: ["file_path": "/w/a.swift", "old_string": "let a = 1", "new_string": "let a = 2\nlet b = 3"]))
        #expect(edit.hunks.first?.lines == ["-let a = 1", "+let a = 2", "+let b = 3"])

        let write = try #require(
            ChatEdit(proposed: "Write", input: ["file_path": "/w/new.swift", "content": "one\ntwo"]))
        #expect(write.added == 2)
        #expect(write.removed == 0)
        #expect(ChatEdit(proposed: "Bash", input: ["command": "ls"]) == nil)
    }

    /// An edit is a card of its own, filled in from its result.
    @Test func anEditIsItsOwnItemWithItsPatch() throws {
        var builder = ChatBuilder()
        builder.add(
            line: ChatLines.tool(
                "e1", "Edit",
                ["file_path": "/w/SavedTab.swift", "old_string": "case old", "new_string": "case chat(SavedChat)"]))
        guard case .edit(let pending)? = builder.items.last?.content else {
            Issue.record("no edit item: \(builder.items)")
            return
        }
        #expect(pending.result == nil)
        #expect(pending.edit?.removed == 1)

        builder.add(
            line: ChatLines.line(
                "user", .array([.object(["type": "tool_result", "tool_use_id": "e1", "content": "ok"])]),
                extra: ["toolUseResult": patch]))

        guard case .edit(let done)? = builder.items.last?.content else {
            Issue.record("no edit item")
            return
        }
        #expect(done.result == "ok")
        #expect(done.edit?.added == 2)
        #expect(builder.items.count == 1)
    }
}
