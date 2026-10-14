import Foundation

/// Where Claude Code keeps a folder's conversations: `~/.claude/projects/<folder>/<session>.jsonl`, with every
/// character of the folder's path that is not a letter or digit turned into `-`.
public enum ClaudeProjects {
    public static func folderName(for path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public static func root(home: String) -> URL {
        URL(fileURLWithPath: home).appending(path: ".claude/projects")
    }

    /// The session's transcript: in the folder's own place, or wherever under `projects` it is, as for a path Claude
    /// Code shortened. Nil if there is none.
    public static func transcript(session: String, folder: String, home: String) -> URL? {
        let root = root(home: home)
        let expected = root.appending(path: folderName(for: folder)).appending(path: session + ".jsonl")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.lazy.map { root.appending(path: $0).appending(path: session + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
