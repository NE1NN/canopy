import Foundation

/// Appends activity events to one JSON Lines file per local day. Events are written one at a time on a queue of
/// their own, in the order they were recorded, so recording never waits for the disk.
public final class ActivityLog: Sendable {
    public let folder: URL
    /// False when config.json turns command logging off. `term.command` events are then dropped.
    public let logsCommands: Bool
    private let queue = DispatchQueue(label: "canopy.activity-log")

    public init(folder: URL, logsCommands: Bool = true) {
        self.folder = folder
        self.logsCommands = logsCommands
    }

    /// `date` stamps the event and picks the day's file. It is when `record` is called unless a test says otherwise.
    public func record(
        _ type: String, repo: String? = nil, row: String? = nil, path: String? = nil,
        source: ActivitySource = .current, data: [String: JSONValue] = [:], at date: Date = Date()
    ) {
        guard logsCommands || type != ActivityType.termCommand else { return }
        let event = ActivityEvent(date: date, type: type, repo: repo, row: row, path: path, source: source, data: data)
        let file = folder.appending(path: Self.fileName(for: date))
        queue.async { self.append(event, to: file) }
    }

    /// Returns once everything recorded so far is written.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Blocks until everything recorded so far is written, for quitting.
    public func flushNow() {
        queue.sync {}
    }

    /// Such as 2026-09-27.jsonl.
    static func fileName(for date: Date) -> String {
        let day = Calendar.localGregorian().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    private func append(_ event: ActivityEvent, to file: URL) {
        guard let line = try? event.jsonLine() else { return }
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
