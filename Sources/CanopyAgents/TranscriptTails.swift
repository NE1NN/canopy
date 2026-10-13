import CanopyWire
import Foundation
import Synchronization

/// The last entry of each transcript, read again only when the file's size changes, for the inbox's last lines.
public final class TranscriptTails: Sendable {
    private struct Tail: Sendable {
        var size: Int
        var entry: TranscriptEntry?
    }

    private let cache = Mutex<[String: Tail]>([:])

    public init() {}

    public func last(in path: String) -> TranscriptEntry? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
            _ = cache.withLock { $0.removeValue(forKey: path) }
            return nil
        }
        if let cached = cache.withLock({ $0[path] }), cached.size == size { return cached.entry }
        let entry = try? TranscriptReader.page(
            of: URL(fileURLWithPath: path), before: nil, limit: 1, maxSpan: 256 * 1024
        ).entries.last
        cache.withLock { $0[path] = Tail(size: size, entry: entry) }
        return entry
    }

    /// Forgets transcripts no pane names any more.
    public func keep(only paths: Set<String>) {
        cache.withLock { $0 = $0.filter { paths.contains($0.key) } }
    }
}
