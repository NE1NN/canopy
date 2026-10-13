import Foundation

/// A Claude Code conversation saved for a folder.
public struct ClaudeSessionInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var modified: Date
}

/// The conversations Claude Code keeps for a row's folder, for Resume in a chat.
public enum ClaudeSessions {
    /// How much of each transcript is read for its title.
    static let headBytes = 64 * 1024

    /// Newest first.
    public static func list(folder: String, home: String) -> [ClaudeSessionInfo] {
        let root = ClaudeProjects.root(home: home).appending(path: ClaudeProjects.folderName(for: folder))
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { file in
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let title = title(of: file) else { return nil }
            return ClaudeSessionInfo(
                id: file.deletingPathExtension().lastPathComponent, title: title, modified: modified ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Claude Code's own title for it, or else the first line of its first prompt. Nil for one with no prompt.
    static func title(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        var firstPrompt: String?
        for line in head.split(separator: 0x0A) {
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line)) else { continue }
            switch object["type"]?.text {
            case "custom-title": if let title = object["customTitle"]?.text, !title.isEmpty { return title }
            case "summary": if let title = object["summary"]?.text, !title.isEmpty { return title }
            default: break
            }
            if firstPrompt == nil, let record = TranscriptParser.Record(line: Data(line)), record.role == "user",
                let text = record.blocks.lazy.compactMap({ block -> String? in
                    if case .text(let text) = block { text } else { nil }
                }).first,
                TranscriptParser.Builder.notice(for: text) == nil
            {
                firstPrompt = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) }
            }
        }
        return firstPrompt
    }
}
