import Foundation

/// The last entry of each transcript, read again only when the file's size changes, for the inbox's last lines.
@MainActor
public final class TranscriptTails {
    private var cache: [String: (size: Int, entry: TranscriptEntry?)] = [:]

    public init() {}

    public func last(in path: String) -> TranscriptEntry? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
            cache[path] = nil
            return nil
        }
        if let cached = cache[path], cached.size == size { return cached.entry }
        let entry = try? TranscriptReader.page(of: URL(fileURLWithPath: path), before: nil, limit: 1).entries.last
        cache[path] = (size, entry)
        return entry
    }

    /// Forgets transcripts no pane names any more.
    public func keep(only paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }
}
