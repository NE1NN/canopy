import Foundation

public enum GitReflog {
    /// Whether the newest entry in a reflog was written by `git push`. A remote-tracking branch also moves on every
    /// fetch and pull, which say nothing about a PR being opened.
    public static func lastEntryIsPush(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        // Entries are one line each, so the tail holds the newest whole.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let last = tail.split(separator: "\n").last else { return false }
        return last.split(separator: "\t", maxSplits: 1).last == "update by push"
    }
}
