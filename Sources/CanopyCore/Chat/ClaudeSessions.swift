import Foundation
import Synchronization

/// A Claude Code conversation saved for a folder.
public struct ClaudeSessionInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var modified: Date
}

/// The conversations Claude Code keeps for a row's folder, for Resume in a chat.
public enum ClaudeSessions {
    /// How much of each transcript's end is read for the newest title Claude Code or the author gave it.
    static let tailBytes = 128 * 1024
    /// How much of its start is read for the first prompt, and how far to go when that prompt holds a pasted image.
    static let headBytes = 64 * 1024
    static let longHeadBytes = 4 * 1024 * 1024

    /// Titles by file, kept while the file's date and size stay the same, so listing again reads only what changed.
    private static let cache = Mutex<[String: (modified: Date, size: Int, title: String?)]>([:])

    /// Newest first.
    public static func list(folder: String, home: String) -> [ClaudeSessionInfo] {
        let root = ClaudeProjects.root(home: home).appending(path: ClaudeProjects.folderName(for: folder))
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { file in
            let values = try? file.resourceValues(forKeys: keys)
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            let cached = cache.withLock { $0[file.path] }
            let title: String?
            if let cached, cached.modified == modified, cached.size == size {
                title = cached.title
            } else {
                title = Self.title(of: file, size: size)
                cache.withLock { $0[file.path] = (modified, size, title) }
            }
            guard let title else { return nil }
            return ClaudeSessionInfo(
                id: file.deletingPathExtension().lastPathComponent, title: title, modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// The newest title the author gave it, else Claude Code's, else the first line of its first prompt. Nil for one
    /// with no prompt, which has nothing to resume.
    static func title(of file: URL, size: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(0, size - tailBytes)))
        let tail = (try? handle.readToEnd()) ?? Data()
        try? handle.seek(toOffset: 0)
        var head = (try? handle.read(upToCount: headBytes)) ?? Data()
        for (type, key) in [("custom-title", "customTitle"), ("ai-title", "aiTitle"), ("summary", "summary")] {
            if let title = newest(type, key, in: tail) ?? newest(type, key, in: head) { return title }
        }
        if let prompt = firstPrompt(in: head) { return prompt }
        guard size > head.count else { return nil }
        head += (try? handle.read(upToCount: longHeadBytes - head.count)) ?? Data()
        return firstPrompt(in: head)
    }

    private static func firstPrompt(in data: Data) -> String? {
        for line in data.split(separator: 0x0A) where line.range(of: Data(#""user""#.utf8)) != nil {
            guard let record = TranscriptParser.Record(line: Data(line)), record.role == "user",
                let text = record.blocks.lazy.compactMap({ block -> String? in
                    if case .text(let text) = block { text } else { nil }
                }).first,
                TranscriptParser.Builder.notice(for: text) == nil,
                let first = text.split(whereSeparator: \.isNewline).first
            else { continue }
            return String(first.prefix(80))
        }
        return nil
    }

    /// The last record of `type` in `data` with a non-empty `key`, decoding only lines that name the type.
    private static func newest(_ type: String, _ key: String, in data: Data) -> String? {
        let marker = Data("\"\(type)\"".utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line)),
                object["type"]?.text == type, let title = object[key]?.text, !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }
}
