import Foundation
import Testing

@testable import CanopyCore

/// Artifact publishes, shaped as Claude Code 2.1.296 writes them.
enum ArtifactLines {
    static let url = "https://claude.ai/artifact/RSfrJZmSpnffA7s42BZDwd"

    static func publish(_ id: String, file: String = "/tmp/scratch/board/index.html") -> Data {
        ChatLines.tool(id, "Artifact", ["file_path": .string(file), "icon": "phone"])
    }

    static func published(
        _ id: String, version: Int?, url: String = url, title: String = "Canopy Phone", audience: String = "owner"
    ) -> Data {
        var structured: [String: JSONValue] = [
            "url": .string(url), "artifact_id": "c5f0dd41-a8cf-4973-bed7-312a275e6f10", "title": .string(title),
            "audience": .string(audience), "updated": .bool(version.map { $0 > 1 } ?? false),
        ]
        if let version { structured["seq"] = .number(Double(version)) }
        let text = "Published /tmp/scratch/board/index.html at \(url) (Version \(version ?? 1), version id 1-a)"
        return ChatLines.line(
            "user",
            .array([.object(["type": "tool_result", "tool_use_id": .string(id), "content": .string(text)])]),
            extra: ["toolUseResult": .object(structured)])
    }
}

struct ChatArtifactTests {
    func artifacts(_ items: [ChatItem]) -> [ChatArtifact] {
        items.compactMap { if case .artifact(let artifact) = $0.content { artifact } else { nil } }
    }

    @Test func aPublishBecomesACardFilledInByItsResult() throws {
        var builder = ChatBuilder()
        builder.add(line: ArtifactLines.publish("a1"))

        let waiting = try #require(artifacts(builder.items).first)
        #expect(waiting.url == nil)
        #expect(waiting.title == "index")

        builder.add(line: ArtifactLines.published("a1", version: 3, audience: "anyone"))

        let card = try #require(artifacts(builder.items).first)
        #expect(card.url?.absoluteString == ArtifactLines.url)
        #expect(card.title == "Canopy Phone")
        #expect(card.version == 3)
        #expect(!card.isPrivate)
        #expect(card.thumbnailKey == "c5f0dd41-a8cf-4973-bed7-312a275e6f10-v3")
        #expect(builder.takePublished().map(\.version) == [3])
        #expect(builder.takePublished().isEmpty)
    }

    @Test func marksOlderVersionsReplaced() {
        var builder = ChatBuilder()
        for (id, version) in [("a1", 1), ("a2", 2)] {
            builder.add(line: ArtifactLines.publish(id))
            builder.add(line: ArtifactLines.published(id, version: version))
        }

        #expect(artifacts(builder.items).map(\.replacedBy) == [2, nil])

        // A page loaded later holds a newer version than any shown, as when the result counted from elsewhere.
        var older = ChatBuilder()
        older.add(line: ArtifactLines.publish("a0"))
        older.add(line: ArtifactLines.published("a0", version: 7))
        builder.prepend(older)

        #expect(artifacts(builder.items).map(\.version) == [7, 1, 2])
        #expect(artifacts(builder.items).map(\.replacedBy) == [nil, 7, 7])
    }

    @Test func countsVersionsWhenTheResultNamesNone() {
        var builder = ChatBuilder()
        for id in ["a1", "a2"] {
            builder.add(line: ArtifactLines.publish(id))
            builder.add(line: ArtifactLines.published(id, version: nil))
        }
        // An older Claude Code's text result alone still names the page and its version.
        builder.add(line: ArtifactLines.publish("b1"))
        builder.add(
            line: ChatLines.result(
                "b1", "Published b.html at https://claude.ai/artifact/Other1 (Version 9, version id 1)"))

        #expect(artifacts(builder.items).map(\.version) == [1, 2, 9])
        #expect(artifacts(builder.items).map(\.replacedBy) == [2, nil, nil])
        #expect(artifacts(builder.items).last?.url?.absoluteString == "https://claude.ai/artifact/Other1")
    }

    @Test func aFailedPublishStaysAToolLine() throws {
        var builder = ChatBuilder()
        builder.add(line: ArtifactLines.publish("a1"))
        builder.add(line: ChatLines.result("a1", "Publishing was refused", error: true))

        #expect(artifacts(builder.items).isEmpty)
        guard case .tools(let group)? = builder.items.last?.content else {
            Issue.record("no tool line in \(builder.items)")
            return
        }
        #expect(group.failed)
        #expect(builder.takePublished().isEmpty)
    }

    @Test func theToolsOtherActionsAreToolLines() {
        var builder = ChatBuilder()
        builder.add(line: ChatLines.tool("q1", "Artifact", ["action": "quickstart", "intent": "other"]))
        builder.add(line: ChatLines.tool("r1", "Artifact", ["action": "read", "url": .string(ArtifactLines.url)]))
        builder.add(
            line: ChatLines.tool(
                "u1", "Artifact", ["url": .string(ArtifactLines.url), "file_path": "/tmp/a.png", "asset": true]))

        #expect(artifacts(builder.items).isEmpty)
    }

    @Test func aPublishWhoseResultCameFirstStillMakesACard() {
        var builder = ChatBuilder()
        builder.add(line: ArtifactLines.published("a1", version: 4))
        var older = ChatBuilder()
        older.add(line: ArtifactLines.publish("a1"))
        builder.prepend(older)

        #expect(artifacts(builder.items).map(\.version) == [4])
    }

    @Test func thumbnailsAreKeptPerArtifactAndVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let thumbnails = ArtifactThumbnails(folder: folder)
        var builder = ChatBuilder()
        builder.add(line: ArtifactLines.publish("a1"))
        builder.add(line: ArtifactLines.published("a1", version: 2))
        let card = try #require(artifacts(builder.items).first)

        #expect(thumbnails.existing(for: card) == nil)
        try thumbnails.save(Data([1, 2, 3]), for: try #require(card.thumbnailKey))

        #expect(thumbnails.existing(for: card)?.lastPathComponent == "c5f0dd41-a8cf-4973-bed7-312a275e6f10-v2.png")
    }
}
